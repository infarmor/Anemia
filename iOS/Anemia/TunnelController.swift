import Foundation
import LoaderCore
// NetworkExtension isn't concurrency-audited; its connection objects are
// only touched on the main actor here.
@preconcurrency import NetworkExtension
import Observation
import os

/// One point of the traffic graph, bits per second.
struct TrafficPoint: Equatable {
    var down: Double
    var up: Double
}

/// Owns the app's VPN configuration and talks to the tunnel extension.
@MainActor
@Observable
final class TunnelController {
    private(set) var status: NEVPNStatus = .invalid
    /// The running tunnel's counters, refreshed while it is up.
    private(set) var report: TunnelReport? {
        didSet { updateSpeed(from: oldValue) }
    }
    /// Bits per second between the last two reports.
    private(set) var speed: (download: Double, upload: Double)?
    /// The session's speed, oldest first — the traffic graph.
    private(set) var history: [TrafficPoint] = []
    private(set) var lastError: String?
    private(set) var isBusy = false
    /// The server the configuration was last saved with.
    private(set) var activeServerID: UUID?
    /// …and the masking it runs with.
    private(set) var activeMasking: MaskingProfile?

    static let historyCapacity = 90

    /// The iOS engine has no Hysteria 1 client — and the answer to a server
    /// that can't run must be the same wherever it is refused.
    static let unsupportedServerMessage =
        "Hysteria 1 на iPhone не поддерживается — попросите у провайдера ссылку hysteria2 (hy2://)."

    /// Called after every status or server change. Wired directly rather
    /// than through views: in the background SwiftUI runs no onChange, yet
    /// the Live Activity must follow the tunnel.
    @ObservationIgnored var onChange: (() -> Void)?
    /// Called with every fresh report, every 2 s while connected.
    @ObservationIgnored var onReport: (() -> Void)?

    /// How the next start is configured; supplied by the app from its settings.
    struct Options {
        var masking: MaskingProfile = .balanced
        var splitTunnel = SplitTunnelRules(enabled: false)
        /// iOS brings the tunnel back by itself (on-demand).
        var autoReconnect = false
        /// Nothing leaves outside the tunnel (`includeAllNetworks`).
        var killSwitch = false
        /// AdGuard DNS instead of the regular resolvers.
        var adBlock = false
        /// Devices attached to the Personal Hotspot share the tunnel too
        /// (`enforceRoutes`).
        var hotspotThroughVPN = true
    }
    @ObservationIgnored var optionsProvider: () -> Options = { Options() }
    /// The masking a server connects with: what worked for it before, or
    /// the chosen profile.
    @ObservationIgnored var maskingProvider: (ProxyServer) -> MaskingProfile? = { _ in nil }
    /// Whether the extension should keep checking that the tunnel carries
    /// traffic (auto-switching is on).
    @ObservationIgnored var wantsHealth: () -> Bool = { false }

    @ObservationIgnored private var manager: NETunnelProviderManager?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var configurationTask: Task<Void, Never>?
    @ObservationIgnored private var loaded = false
    /// The user turned the VPN off: the drop that follows isn't one to wait out.
    @ObservationIgnored private(set) var stopRequested = false

    var isOn: Bool {
        switch status {
        case .connecting, .connected, .reasserting: true
        default: false
        }
    }

    /// iOS brings the tunnel back by itself after a drop.
    var expectsReconnect: Bool {
        manager?.isOnDemandEnabled == true && !stopRequested
    }

    /// Routing flags as iOS has them saved: read back from the configuration
    /// rather than from the app's settings, because these are exactly the two
    /// the system may refuse to honour — `includeAllNetworks` makes it ignore
    /// `enforceRoutes` altogether.
    var savedRouting: SavedRouting? {
        guard let configuration = manager?.protocolConfiguration as? NETunnelProviderProtocol
        else { return nil }
        return SavedRouting(killSwitch: configuration.includeAllNetworks,
                            enforcedRoutes: configuration.enforceRoutes,
                            localNetworksExcluded: configuration.excludeLocalNetworks)
    }

    struct SavedRouting: Equatable {
        var killSwitch: Bool
        var enforcedRoutes: Bool
        var localNetworksExcluded: Bool
    }

    /// Picks up the configuration saved by an earlier launch, if any.
    func load() async {
        do {
            manager = try await savedManager()
            let configuration = (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
            let setup = TunnelSetup(providerConfiguration: configuration)
            activeServerID = setup?.server.id
            activeMasking = setup?.masking
            watchStatus()
            // Only a load that got this far counts as loaded. A timeout or a
            // denied permission leaves no manager and no status subscription:
            // claiming `loaded` there made `loadIfNeeded()` never retry, and
            // the Siri intent reported "VPN выключен" for a question that was
            // never answered.
            loaded = true
        } catch {
            lastError = Self.describe(error)
        }
        watchConfiguration()
        onChange?()
    }

    /// For intents: the app may have been launched in the background, where
    /// no view has loaded anything yet.
    func loadIfNeeded() async {
        if !loaded { await load() }
    }

    /// Whether the configuration has been read from iOS. The first read waits
    /// on the "Allow VPN configurations" prompt, which a background launch
    /// cannot show — a caller with a time budget needs to tell "off" apart
    /// from "still don't know".
    var isLoaded: Bool { loaded }

    /// Starts the tunnel with `server`, restarting it if it already runs.
    func connect(_ server: ProxyServer) async {
        guard !isBusy else {
            // The row that called this has already moved the selection, so
            // dropping the start in silence left the whole interface naming
            // a server the tunnel never reached.
            showError("Переключаю сервер — подожди пару секунд")
            return
        }
        isBusy = true
        defer { isBusy = false }
        let previousServer = activeServerID
        let previousMasking = activeMasking
        lastError = nil
        stopRequested = false
        guard server.runsOnIOS else {
            lastError = Self.unsupportedServerMessage
            return
        }
        let options = optionsProvider()
        do {
            let manager = try await savedManager() ?? NETunnelProviderManager()
            let configuration = NETunnelProviderProtocol()
            configuration.providerBundleIdentifier = AppBundle.tunnelBundleID
            // Shown as the server in Settings → VPN.
            configuration.serverAddress = server.name
            let masking = maskingProvider(server) ?? options.masking
            configuration.providerConfiguration = TunnelSetup(
                server: server, masking: masking,
                splitTunnel: options.splitTunnel, adBlock: options.adBlock
            ).providerConfiguration
            configuration.includeAllNetworks = options.killSwitch
            // Включённые маршруты получают приоритет над таблицей маршрутизации
            // iOS и над «привязкой» сокетов к интерфейсу, которую делают
            // приложения. Без этого трафик устройств, подключённых к точке
            // доступа, идёт из ядра по своему пути мимо туннеля: `includedRoutes`
            // с дефолтом 0.0.0.0/0 их не забирает — таблица маршрутизации выше.
            // С включённым kill switch iOS этот флаг игнорирует:
            // `includeAllNetworks` и так забирает соединения в туннель.
            configuration.enforceRoutes = options.hotspotThroughVPN
            // AirDrop, принтеры и роутер остаются доступны в обоих режимах:
            // без `includeAllNetworks`/`enforceRoutes` этот флаг ничего и не
            // значит, а с ним — выводит локальные подсети из-под туннеля.
            configuration.excludeLocalNetworks = true
            manager.protocolConfiguration = configuration
            manager.localizedDescription = "Anemia"
            manager.isEnabled = true
            // On-demand stays off while switching: iOS would restart the old
            // session the moment it stops.
            manager.isOnDemandEnabled = false
            // The first save shows iOS's "add VPN configurations" prompt.
            try await manager.saveToPreferences()
            // A just-saved configuration can't start until it is loaded again.
            try await manager.loadFromPreferences()
            self.manager = manager
            activeServerID = server.id
            activeMasking = masking
            watchStatus()
            onChange?()

            if manager.connection.status != .disconnected, manager.connection.status != .invalid {
                // Switching servers: the extension reads its setup at start.
                manager.connection.stopVPNTunnel()
                await waitUntilDisconnected(manager.connection)
            }
            // Read again: the switch may have moved while the old session stopped.
            if optionsProvider().autoReconnect {
                manager.onDemandRules = [NEOnDemandRuleConnect()]
                manager.isOnDemandEnabled = true
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
            }
            // A stop the user asked for while this was still saving its
            // configuration wins — and on-demand goes back off with it, or
            // iOS would raise the tunnel the moment the network moves.
            if stopRequested {
                if manager.isOnDemandEnabled {
                    manager.isOnDemandEnabled = false
                    try? await manager.saveToPreferences()
                }
                // Nothing started, so nothing is running through this server:
                // the island and the widgets must not name it as the exit.
                activeServerID = previousServer
                activeMasking = previousMasking
                onChange?()
                return
            }
            try manager.connection.startVPNTunnel()
        } catch {
            lastError = Self.describe(error)
        }
    }

    func disconnect() async {
        stopRequested = true
        do {
            guard let manager = try await savedManager() else { return }
            adopt(manager)
            // adopt() reads the live status, and a tunnel that is still up
            // clears the flag — "someone started this, a later drop is a
            // drop". This stop is the user's, so put it back before it lands.
            stopRequested = true
            // With on-demand on, iOS would bring the tunnel straight back.
            if manager.isOnDemandEnabled {
                manager.isOnDemandEnabled = false
                try await manager.saveToPreferences()
            }
            manager.connection.stopVPNTunnel()
        } catch {
            lastError = Self.describe(error)
            manager?.connection.stopVPNTunnel()
        }
        onChange?()
    }

    /// "Автопереподключение" for the running tunnel, without restarting it.
    /// A stopped tunnel picks the setting up at its next start: on-demand
    /// enabled now would start it straight away.
    func setAutoReconnect(_ enabled: Bool) async {
        guard isOn, !isBusy else { return }
        do {
            guard let manager = try await savedManager(), manager.isOnDemandEnabled != enabled else { return }
            manager.onDemandRules = [NEOnDemandRuleConnect()]
            manager.isOnDemandEnabled = enabled
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            adopt(manager)
        } catch {
            lastError = Self.describe(error)
        }
    }

    /// Waits for the tunnel to come up; false when it didn't within `timeout`.
    func waitForConnection(timeout: TimeInterval) async -> Bool {
        let began = DispatchTime.now()
        while Self.since(began) < timeout {
            if status == .connected { return true }
            // iOS posts the status change when it feels like it: after a
            // server switch the cached value can still read "disconnected"
            // for a second or two, and calling that a failure makes the
            // widget and Siri report "не получилось" for a VPN that comes up
            // right after.
            if status == .disconnected || status == .invalid, !isBusy,
               Self.since(began) > 3 { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return status == .connected
    }

    /// Секунды по монотонным часам. `Date` шагает вместе с системными: шаг
    /// назад (перелёт через пояс, конец летнего времени, сверка по NTP)
    /// обрывал ожидание мгновенным «не получилось» для туннеля, который
    /// поднимался секундой позже, и ниже замораживал показания скорости.
    private static func since(_ since: DispatchTime) -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds &- since.uptimeNanoseconds) / 1_000_000_000
    }

    /// Real checks, run by the extension next to the tunnel.
    func probe(_ items: [EngineProbe.Item]) async -> [EngineProbe.Outcome]? {
        guard let reply = await send(TunnelRequest(command: .probe, probes: items), timeout: 150) else {
            return nil
        }
        return try? JSONDecoder().decode([EngineProbe.Outcome].self, from: reply)
    }

    func clearError() {
        lastError = nil
    }

    /// Settings → VPN can turn the tunnel off, and with it on-demand: pick
    /// that up, or a drop would look like one iOS is about to repair.
    private func watchConfiguration() {
        guard configurationTask == nil else { return }
        configurationTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .NEVPNConfigurationChange) {
                guard let self, !self.isBusy else { continue }
                if let fresh = try? await self.savedManager() {
                    self.adopt(fresh)
                }
                self.onChange?()
            }
        }
    }

    /// The configuration as saved right now. iOS Settings, the Live
    /// Activity's button or another launch may have changed it since it was
    /// last loaded, and saving an outdated copy fails.
    private func savedManager() async throws -> NETunnelProviderManager? {
        // The first read is what makes iOS ask "Allow Anemia to create
        // VPN configurations?" — and a background launch (a widget button,
        // Siri, the Control Center switch) has no screen to show that on. The
        // call then never returns, and with it the intent that waited on it.
        //
        // Bounded with a real deadline rather than a task-group race: the group
        // body waits for every child to unwind, and the load child is bridged
        // from a completion handler, so `cancelAll()` never reaches it — a
        // group-based "timeout" here returned only when the load itself
        // finished, i.e. it bounded nothing.
        enum Outcome: @unchecked Sendable {
            case loaded(NETunnelProviderManager?)
            case failure(any Error)
            case timeout
        }
        let outcome = await AsyncRace.withTimeout(seconds: 10, fallback: Outcome.timeout) {
            do { return Outcome.loaded(try await NETunnelProviderManager.loadAllFromPreferences().first) }
            catch { return Outcome.failure(error) }
        }
        switch outcome {
        case let .loaded(manager): return manager
        case let .failure(error): throw error
        case .timeout: throw LoadTimeout()
        }
    }

    private struct LoadTimeout: LocalizedError {
        var errorDescription: String? {
            "iOS не ответила на запрос списка VPN-профилей. Если Anemia спрашивает разрешение на создание VPN-подключений впервые — откройте приложение и подтвердите его."
        }
    }

    private func adopt(_ manager: NETunnelProviderManager) {
        guard manager !== self.manager else { return }
        self.manager = manager
        watchStatus()
    }

    /// Latency to `targets`, measured by the running extension (its sockets
    /// skip the tunnel). Nil when the tunnel isn't up or doesn't answer.
    func ping(_ targets: [PingTarget]) async -> [PingSample]? {
        guard let reply = await send(TunnelRequest(command: .ping, targets: targets), timeout: 60) else {
            return nil
        }
        return try? JSONDecoder().decode([PingSample].self, from: reply)
    }

    /// The provider's own address, measured by the extension outside the
    /// tunnel. Nil while the tunnel is down or doesn't answer.
    func directAddress() async -> LeakCheck.IPInfo? {
        guard let reply = await send(TunnelRequest(command: .directAddress), timeout: 15) else { return nil }
        return try? JSONDecoder().decode(LeakCheck.IPInfo.self, from: reply)
    }

    /// Shows a message in the app's error row.
    func showError(_ message: String) {
        lastError = message
    }

    /// The tail of the engine log, while the tunnel runs.
    func fetchLog() async -> String {
        guard let reply = await send(TunnelRequest(command: .log)),
              let log = try? JSONDecoder().decode(TunnelLog.self, from: reply)
        else { return "Лог доступен, пока туннель запущен." }
        return log.text
    }

    // MARK: - Status

    private func watchStatus() {
        statusTask?.cancel()
        guard let connection = manager?.connection else {
            status = .invalid
            return
        }
        statusTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .NEVPNStatusDidChange, object: connection) {
                self?.statusChanged(connection)
            }
        }
        statusChanged(connection)
    }

    private func statusChanged(_ connection: NEVPNConnection) {
        status = connection.status
        defer { onChange?() }
        switch status {
        case .connected:
            // Started by anyone — the app, Settings, on-demand: a later drop
            // is a drop again.
            stopRequested = false
            startPolling()
        case .connecting, .reasserting:
            startPolling()
        case .disconnected:
            stopPolling()
            history = []
            // Turned off in Settings → VPN rather than here: nothing set
            // stopRequested, and the island then called the user's own
            // "off" a dropped connection. The app never disables the
            // configuration — connect() only ever enables it.
            if manager?.isEnabled == false { stopRequested = true }
            // The extension's own message (picked up while connecting) says
            // more than iOS's generic one; keep it when there is one.
            guard lastError == nil else { return }
            connection.fetchLastDisconnectError { @Sendable [weak self] error in
                guard let error else { return }
                let text = TunnelController.describe(error)
                Task { @MainActor in
                    if self?.lastError == nil { self?.lastError = text }
                }
            }
        default:
            stopPolling()
        }
    }

    /// Fast while connecting — a failed start leaves its reason there for
    /// only a few seconds — and every 2 s once connected.
    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshReport()
                let interval: Duration = self.status == .connected ? .seconds(2) : .milliseconds(500)
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        report = nil
    }

    private func refreshReport() async {
        let request = TunnelRequest(command: .status, wantsHealth: wantsHealth() ? true : nil)
        guard let reply = await send(request),
              let fresh = try? JSONDecoder().decode(TunnelReport.self, from: reply)
        else { return }
        // A reply can land after the session stopped — the send doesn't watch
        // for cancellation. Writing it then leaves a dead session's numbers on
        // screen and pins the network type the tunnel saw, which the app then
        // trusts over its own path monitor.
        guard !Task.isCancelled, isOn else { return }
        report = fresh
        if let error = fresh.error { lastError = error }
        onReport?()
    }

    @ObservationIgnored private var reportTime: DispatchTime?
    /// Стенное время того же опроса — рядом с `reportTime`, чтобы заметить сон.
    @ObservationIgnored private var reportWall: Date?

    private func updateSpeed(from old: TunnelReport?) {
        let now = DispatchTime.now()
        let wall = Date()
        defer {
            reportTime = report == nil ? nil : now
            reportWall = report == nil ? nil : wall
        }
        guard let report, let old, let reportTime, old.startedAt == report.startedAt else {
            speed = nil
            return
        }
        // Расстояние между опросами — по монотонным часам. Системные идут
        // назад вместе с переводом времени и сверкой по NTP, и на длину такого
        // шага срабатывал ранний выход: цифры и график стояли на последнем
        // замере, пока байты текли. Шаг вперёд (после сна через летнее время,
        // из другого пояса) давал один образец, делённый на часы, то есть почти
        // ноль, и сглаживание тащило его несколько тиков.
        let seconds = Self.since(reportTime)
        guard seconds > 0.2 else { return }
        // Обратная сторона тех же часов: монотонные стоят, пока устройство
        // спит, а опрос на MainActor в это время не крутится — и первый образец
        // после пробуждения делил бы байты целого часа на пару секунд
        // проснувшегося процессора (сотни МБ/с вместо правдивых нулей). Если
        // стенных часов прошло заметно больше, чем монотонных, процесс не
        // работал, и этот замер — не про скорость.
        if let reportWall, wall.timeIntervalSince(reportWall) > seconds + 5 { return }
        let download = Double(max(report.downloaded - old.downloaded, 0)) * 8 / seconds
        let upload = Double(max(report.uploaded - old.uploaded, 0)) * 8 / seconds
        // Light smoothing: a burst still shows, the number doesn't jitter.
        let previous = speed ?? (download: download, upload: upload)
        let smoothed = (download: previous.download * 0.35 + download * 0.65,
                        upload: previous.upload * 0.35 + upload * 0.65)
        speed = smoothed
        history.append(TrafficPoint(down: smoothed.download, up: smoothed.upload))
        if history.count > Self.historyCapacity {
            history.removeFirst(history.count - Self.historyCapacity)
        }
    }

    private func waitUntilDisconnected(_ connection: NEVPNConnection) async {
        for _ in 0..<100 where connection.status != .disconnected {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// One request to the running extension; nil when it isn't running or
    /// doesn't answer in time.
    private func send(_ message: TunnelRequest, timeout: TimeInterval = 3) async -> Data? {
        guard let session = manager?.connection as? NETunnelProviderSession,
              [.connecting, .connected, .reasserting].contains(session.status),
              let request = try? JSONEncoder().encode(message)
        else { return nil }
        return await withCheckedContinuation { continuation in
            let answered = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Data?) -> Void = { data in
                let first = answered.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: data) }
            }
            do {
                try session.sendProviderMessage(request) { finish($0) }
            } catch {
                finish(nil)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    nonisolated static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var text = ns.localizedDescription
        if ns.localizedDescription.localizedCaseInsensitiveContains("permission denied") {
            text += "\nВ подписи нет права packet-tunnel-provider — проверьте сертификат в GBox."
        } else if ns.domain == NEVPNErrorDomain, ns.code == NEVPNError.Code.configurationInvalid.rawValue {
            text += "\niOS не приняла конфигурацию: возможно, расширение не подписано или его bundle ID изменился."
        } else if ns.domain == NEVPNErrorDomain, ns.code == NEVPNError.Code.configurationReadWriteFailed.rawValue {
            #if targetEnvironment(simulator)
            text += "\nВ симуляторе VPN не работает — это нормально, интерфейс править можно."
            #else
            text += "\niOS не дала доступ к VPN-конфигурациям: скорее всего, в подписи нет права packet-tunnel-provider."
            #endif
        }
        return text + "\n(\(ns.domain) \(ns.code))"
    }
}
