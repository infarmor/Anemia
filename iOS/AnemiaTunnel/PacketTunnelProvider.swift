import Foundation
import LoaderCore
import Network
import NetworkExtension
import os

/// Runs the selected server through the Go engine: Xray-core for
/// VLESS/VMess/Trojan/Shadowsocks/Hysteria2, AmneziaWG for WireGuard-family
/// servers. The engine reads the utun descriptor directly, so this class never
/// touches `packetFlow`.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private struct Session {
        var engine = ""
        var serverName = ""
        var startedAt = Date()
        var error: String?
        var target: PingTarget?
        var masking: MaskingProfile = .balanced
        var latency: Int?
        var latencyMeasuredAt = Date.distantPast
        /// The app's last status request: latency is measured only while
        /// someone looks at it.
        var lastPolled = Date.distantPast
        var healthWanted = Date.distantPast
        var health: Int?
        var healthFailures = 0
        var healthCheckedAt = Date.distantPast
        /// AmneziaWG counters at the previous check.
        var lastTraffic: TrafficCounters?
        var network: NetworkKind?
    }

    private let log = Logger(subsystem: "Anemia", category: "tunnel")
    /// Ответ движка без части полей — это одна строка в лог за жизнь туннеля, а
    /// не по строке на каждый опрос статистики.
    private var statusKeysLogged = false
    private let session = OSAllocatedUnfairLock(initialState: Session?.none)
    private let pathQueue = DispatchQueue(label: "Anemia.path")
    private var pathMonitor: NWPathMonitor?
    private var monitorTask: Task<Void, Never>?

    private static let logDirectory = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Anemia", isDirectory: true)

    override func startTunnel(options: [String: NSObject]? = nil) async throws {
        let configuration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        guard let setup = TunnelSetup(providerConfiguration: configuration) else {
            throw TunnelPlan.Failure(message: "Нет настроек сервера — подключитесь из приложения Anemia.")
        }
        session.withLock {
            $0 = Session(serverName: setup.server.name, target: PingTarget(server: setup.server), masking: setup.masking)
        }
        do {
            try Engine.setLogDirectory(Self.logDirectory)
            Engine.setMemoryLimit(bytes: Self.goMemoryLimit())
            let plan = try TunnelPlan.make(setup, logFile: Self.logDirectory.appendingPathComponent("engine.log"))
            try await setTunnelNetworkSettings(plan.settings)
            guard let fd = Engine.tunnelFD else {
                throw TunnelPlan.Failure(message: "iOS не выдала дескриптор туннеля")
            }
            let engine: String
            switch plan.engine {
            case .xray(let json):
                try Engine.startXray(config: json, tunnelFD: fd)
                engine = "xray"
            case .awg(let uapi):
                try Engine.startAWG(uapi: uapi, tunnelFD: fd)
                engine = "awg"
            }
            let startedAt = Date()
            session.withLock { $0?.engine = engine; $0?.startedAt = startedAt }
            startPathMonitor()
            startMonitor()
            log.info("\(engine, privacy: .public) up")
        } catch {
            let message = error.localizedDescription
            log.error("start failed: \(message, privacy: .public)")
            // В отчёте — причина, а не вся Go-цепочка: «Не удалось подключиться»
            // умещается в две строки на 13 pt, а `infra/conf: … > unknown cipher
            // method` приносит туда путь в песочнице. Правило среза общее с
            // macOS и Android (`EngineLog.cause`, закреплён золотом).
            session.withLock { $0?.error = EngineLog.cause(from: message) }
            // iOS doesn't hand this error to the app. The app polls while
            // connecting; give it time to pick the message up.
            try? await Task.sleep(for: .seconds(3))
            throw error
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        pathMonitor?.cancel()
        pathMonitor = nil
        monitorTask?.cancel()
        monitorTask = nil
        Engine.stop()
        session.withLock { $0 = nil }
        log.info("stopped, reason \(reason.rawValue, privacy: .public)")
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let request = try? JSONDecoder().decode(TunnelRequest.self, from: messageData) else {
            completionHandler?(nil)
            return
        }
        switch request.command {
        case .status:
            if request.wantsHealth == true {
                session.withLock { $0?.healthWanted = Date() }
            }
            completionHandler?(report().flatMap { try? JSONEncoder().encode($0) })
        case .log:
            completionHandler?(try? JSONEncoder().encode(TunnelLog(text: Self.logTail())))
        case .ping:
            let targets = request.targets ?? []
            Task {
                let samples = await ServerPinger.run(targets)
                completionHandler?(try? JSONEncoder().encode(samples))
            }
        case .directAddress:
            Task {
                // This process's sockets skip the tunnel.
                let info = try? await LeakCheck.publicAddress()
                completionHandler?(info.flatMap { try? JSONEncoder().encode($0) })
            }
        case .probe:
            let items = request.probes ?? []
            DispatchQueue.global(qos: .userInitiated).async {
                // Every check runs its own engine instance next to the
                // tunnel's: one at a time when memory is short. Без лимита
                // (`size_t` приходит как -1) сравнение с 24 МБ дало бы
                // «памяти мало» — ровно наоборот к `goMemoryLimit` ниже.
                let raw = os_proc_available_memory()
                let concurrency = (raw <= 0 || raw > 24 << 20) ? 2 : 1
                let outcomes = EngineProbe.run(items, timeout: 6, concurrency: concurrency)
                completionHandler?(try? JSONEncoder().encode(outcomes))
            }
        }
    }

    // MARK: - Status

    private func report() -> TunnelReport? {
        let current = session.withLock { session -> Session? in
            session?.lastPolled = Date()
            return session
        }
        guard let current else { return nil }
        let status = Engine.status
        if let missing = status?.missingKeys, !missing.isEmpty, !statusKeysLogged {
            // `report()` runs on the stats timer: a schema mismatch is worth one
            // loud line, not one per second.
            statusKeysLogged = true
            let names = missing.sorted().joined(separator: ",")
            log.info("engine status is missing keys: \(names, privacy: .public)")
        }
        return TunnelReport(
            engine: current.engine,
            serverName: current.serverName,
            startedAt: current.startedAt,
            uploaded: status?.up ?? 0,
            downloaded: status?.down ?? 0,
            lastHandshake: (status?.handshake ?? 0) > 0
                ? Date(timeIntervalSince1970: TimeInterval(status?.handshake ?? 0)) : nil,
            latency: current.latency,
            health: current.health,
            // Замороженный счётчик — не доказательство: «2 отказа подряд» из
            // последнего замершего показания уводило бы туннель на соседний
            // сервер каждые три минуты, пока часы (или экран) не поедут назад.
            healthFailures: Self.healthSchedule.signalFresh(
                checkedAge: Date().timeIntervalSince(current.healthCheckedAt)
            ) ? current.healthFailures : nil,
            footprint: Self.footprint(),
            // `size_t` импортируется в Swift как `Int`, а `os_proc_available_memory()`
            // отвечает SIZE_MAX там, где лимита нет (`goMemoryLimit` ниже об этом
            // же). `UInt64(-1)` — это ловушка, и ловит она расширение на первом
            // же запросе статуса, а не на редком пути.
            available: UInt64(max(os_proc_available_memory(), 0)),
            engineVersion: Engine.version,
            error: current.error,
            network: current.network
        )
    }

    /// The engine log's last 64 KB, preceded by any Go crash report.
    private static func logTail() -> String {
        func tail(_ name: String, limit: Int) -> String? {
            guard let handle = try? FileHandle(forReadingFrom: logDirectory.appendingPathComponent(name)) else { return nil }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > UInt64(limit) ? size - UInt64(limit) : 0)
            guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        var text = ""
        if let crash = tail("crash.log", limit: 16_384) {
            text += "=== Сбой движка в прошлом запуске ===\n\(crash)\n=== Текущий лог ===\n"
        }
        return text + (tail("engine.log", limit: 65_536) ?? "Лог пуст.")
    }

    /// Go keeps its heap under this. The extension is killed at ~50 MB of
    /// footprint, Swift and Go together; leave room for the Swift side.
    private static func goMemoryLimit() -> Int64 {
        // `os_proc_available_memory()` answers SIZE_MAX where the process has no
        // limit, and `size_t` comes into Swift as `Int` — so that is -1 here.
        // Clamping in Double space keeps the `· 0.75` conversion from trapping;
        // "no limit" then has to land on the ceiling on purpose, because as a
        // plain negative it would fall through `max(..., 16 МБ)` onto the
        // *smallest* heap in the one case where the extension has the most room.
        let raw = os_proc_available_memory()
        let available = raw <= 0 ? 64_000_000.0 : min(Double(raw), 64_000_000)
        let limit = Int64(available * 0.75)
        return min(max(limit, 16 << 20), 40 << 20)
    }

    /// phys_footprint — the figure iOS compares with the extension's limit.
    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    // MARK: - Monitoring

    /// While the app polls: the server's ping once a minute (the list's
    /// method, from this process, whose sockets skip the tunnel), and — while
    /// the app asks for it — whether the tunnel carries traffic, every 30 s.
    private func startMonitor() {
        monitorTask?.cancel()
        monitorTask = Task.detached(priority: .utility) { [session] in
            while !Task.isCancelled {
                let now = Date()
                let current = session.withLock { $0 }
                if let current, now.timeIntervalSince(current.lastPolled) < 60 {
                    if let target = current.target, now.timeIntervalSince(current.latencyMeasuredAt) >= 60 {
                        let rtt = await ServerPinger.run([target], count: 1).first?.rtts.first ?? nil
                        session.withLock {
                            $0?.latency = rtt
                            $0?.latencyMeasuredAt = Date()
                        }
                    }
                    if Self.healthSchedule.healthDue(
                        watchedAge: now.timeIntervalSince(current.lastPolled),
                        wantedAge: now.timeIntervalSince(current.healthWanted),
                        checkedAge: now.timeIntervalSince(current.healthCheckedAt)
                    ) {
                        await Self.checkHealth(session: session, engine: current.engine)
                    }
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Xray: a real request through the running engine. AmneziaWG has no
    /// dialer to test with: sending for 30 s without hearing anything back
    /// counts as a failure instead, silence as nothing at all. The rules
    /// themselves live in `TunnelHealth` (LoaderCore) — the same text the
    /// Android port is compared against, and the only way either of them can
    /// be tested without a device.
    /// Частота и окна «за нами следят» — `HealthSchedule`, те же числа, что
    /// сверяет с Android золотой `health/run.golden.txt`.
    private static let healthSchedule = HealthSchedule()

    private static let healthRules = TunnelHealth()

    /// What a verdict does to the session: the report shows the measured
    /// number (which on xray can be a real, too-slow one), and the streak
    /// either grows or resets. Silence claims nothing and changes nothing.
    private static func apply(_ outcome: HealthOutcome, to current: inout Session) {
        // Арифметику ведёт `TunnelHealth.apply`: та же функция проходит золотой
        // `health/run.golden.txt` и на Android. Своей копией формулы iOS
        // держал телефон вне-покрытия того теста, которым сверяет пороги.
        let state = healthRules.apply(outcome,
                                      to: HealthState(health: current.health,
                                                      failures: current.healthFailures))
        current.health = state.health
        current.healthFailures = state.failures
    }

    private static func checkHealth(session: OSAllocatedUnfairLock<Session?>, engine: String) async {
        switch engine {
        case "xray":
            // Проверка висит до 8 с: на кооперативном пулу это стоило бы
            // монитору и остальным `Task.detached` в этом процессе.
            // Потолок на стороне Swift: `AnemiaCheckActive` может не вернуться
            // вовсе (известная дыра — `stopLocked` закрывает инстанс под
            // запросом), а продолжение, которое никогда не возобновят, вешает
            // этот цикл навсегда. Дальше `healthCheckedAt` не обновляется,
            // «свежесть» сигнала проходит, `healthFailures` уезжает в nil, и
            // умное переключение молча перестаёт существовать до конца сессии.
            let ms = await AsyncRace.withTimeout(seconds: 20, fallback: nil) {
                await EngineProbe.checkActiveDetached(timeout: 8)
            }
            // 20 с, а не 10: у самого Go контекст на 8 с, и любое окно меньше
            // «8 с + ожидание `mu`» превращало молчаливо живёщий туннель в
            // отказ на глазках Swift. Просрочка здесь — неизвестность, а не
            // неудача: её нельзя отдавать в `request(nil)`, иначе две такие
            // паузы подряд уводят с РАБОТАющего выхода.
            guard let ms else {
                session.withLock { state in
                    guard var current = state else { return }
                    current.healthCheckedAt = Date()
                    state = current
                }
                return
            }
            let outcome = healthRules.request(ms)
            session.withLock { state in
                guard var current = state else { return }
                apply(outcome, to: &current)
                current.healthCheckedAt = Date()
                state = current
            }
        case "awg":
            // Молчание движка — это не «проверка не состоялась, забываем время»:
            // `healthCheckedAt` не обновляется, и следующий проход попробует
            // снова через пять секунд, а не через полчаса.
            //
            // Но `status == nil` такого молчания не ловит: `AnemiaStatus`
            // отвечает всегда и всеми восемью ключами, даже когда движка нет
            // (`engine` — пустая строка), а `awgTraffic` превращает сорвавшийся
            // `IpcGet` в тройку нулей. Нуль, записанный базовой линией, стоит
            // дорого: следующая дельта равна уже накопленным байтам, а
            // `received > 0` в `TunnelHealth.counters` идёт первым условием —
            // ответ прочтётся как «проверка пройдена», полоса отказов обнулится,
            // и при AmneziaWG переключение не наступит никогда. Поэтому
            // показание засчитывается только когда его прислал работающий
            // движок и понёс оба счётчика — и этого, как показала Android-ветка
            // с тем же стражем, всё ещё мало: сорвавшийся `IpcGet` сохраняет и
            // `engine = "awg"`, и все восемь ключей, выдав вместо счётчиков нули.
            // Поэтому показание обязано быть ещё и живым (хотя бы один счётчик
            // ненулевой) и не отмотанным назад: за время жизни ранa накопленные
            // байты только растут.
            guard let status = Engine.status, status.engine == "awg",
                  !status.missingKeys.contains(where: { $0 == "up" || $0 == "down" }) else { return }
            let counters = TrafficCounters(up: status.up, down: status.down)
            session.withLock { state in
                guard var current = state else { return }
                // Раньше `defer`: базовая линия и время проверки не должны
                // сдвинуться по показанию, которое мы только что отвергли.
                if status.up == 0, status.down == 0 { return }
                if let previous = current.lastTraffic,
                   status.up < previous.up || status.down < previous.down { return }
                defer {
                    current.lastTraffic = counters
                    current.healthCheckedAt = Date()
                    state = current
                }
                apply(healthRules.counters(counters, previous: current.lastTraffic,
                                           latency: current.latency), to: &current)
            }
        default:
            break
        }
    }

    // MARK: - Network changes

    /// Wi-Fi ↔ cellular: AmneziaWG must rebind its sockets, or it keeps
    /// sending from an interface that is gone.
    private func startPathMonitor() {
        // iOS reuses this process across a restart of the tunnel: without
        // cancelling, every start leaves a monitor whose handler rebinds the
        // engine on each path change.
        pathMonitor?.cancel()
        let monitor = NWPathMonitor()
        let lastInterfaces = OSAllocatedUnfairLock<[String]?>(initialState: nil)
        let log = log
        let session = session
        monitor.pathUpdateHandler = { path in
            let kind: NetworkKind? = path.status != .satisfied ? nil
                : path.usesInterfaceType(.cellular) ? .cellular
                : path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) ? .wifi : nil
            session.withLock { $0?.network = kind }
            let interfaces = path.availableInterfaces.map(\.name)
            let previous = lastInterfaces.withLock { last in
                defer { last = interfaces }
                return last
            }
            guard let previous, previous != interfaces, path.status == .satisfied else { return }
            log.info("network changed: \(interfaces.joined(separator: ","), privacy: .public)")
            Engine.networkChanged()
        }
        monitor.start(queue: pathQueue)
        pathMonitor = monitor
    }
}
