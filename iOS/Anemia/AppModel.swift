import Foundation
import LoaderCore
import Observation
import UIKit
import WidgetKit

/// Everything the app runs, created once and wired together. Views get the
/// parts through the environment; intents — which iOS may run in a
/// background launch, before any view exists — reach them through `shared`.
@MainActor
final class AppModel {
    static let shared = AppModel()

    let tunnel = TunnelController()
    let store = ServerStore()
    let liveActivity: LiveActivityController
    let pings: PingController
    let actions: QuickActions
    let stats = TrafficStats()
    let speedTest = SpeedTest()
    let network = NetworkWatcher()
    let leaks: LeakChecker
    let alerts: SubscriptionAlerts
    private let autoSwitch: AutoSwitch
    private let widgets = WidgetBridge()

    private init() {
        liveActivity = LiveActivityController(tunnel: tunnel)
        pings = PingController(tunnel: tunnel)
        actions = QuickActions(tunnel: tunnel, store: store, pings: pings, liveActivity: liveActivity)
        autoSwitch = AutoSwitch(actions: actions, tunnel: tunnel, store: store, liveActivity: liveActivity)
        leaks = LeakChecker(tunnel: tunnel)
        alerts = SubscriptionAlerts(store: store)

        let tunnel = self.tunnel
        let store = self.store
        let liveActivity = self.liveActivity
        let widgets = self.widgets
        let autoSwitch = self.autoSwitch
        let actions = self.actions
        let stats = self.stats
        let network = self.network
        tunnel.onChange = { [weak tunnel, weak store, weak liveActivity] in
            guard let tunnel, let store, let liveActivity else { return }
            if !tunnel.isOn {
                stats.tunnelStopped()
                network.tunnelReported(nil)
            }
            let server = tunnel.activeServerID.flatMap { store.state.server(withID: $0) }
            liveActivity.tunnelChanged(server: server)
            widgets.update(tunnel: tunnel, server: server ?? store.selected, sessionStart: liveActivity.sessionStart)
        }
        let pings = self.pings
        tunnel.onReport = { [weak tunnel, weak store, weak liveActivity, weak pings] in
            guard let tunnel, let store, let liveActivity else { return }
            network.tunnelReported(tunnel.report?.network)
            autoSwitch.evaluate()
            if let report = tunnel.report, !report.engine.isEmpty {
                stats.take(report, server: tunnel.activeServerID.flatMap { store.state.server(withID: $0) })
            }
            if let report = tunnel.report, let id = tunnel.activeServerID, tunnel.status == .connected,
               report.latency != nil || report.health == -1 {
                pings?.record(latency: report.latency, for: id)
            }
            let server = tunnel.activeServerID.flatMap { store.state.server(withID: $0) }
            widgets.update(tunnel: tunnel, server: server, sessionStart: liveActivity.sessionStart)
        }
        tunnel.optionsProvider = { [weak store] in
            guard let store else { return TunnelController.Options() }
            return TunnelController.Options(
                masking: store.masking,
                splitTunnel: store.splitTunnel,
                autoReconnect: store.autoReconnect,
                killSwitch: store.killSwitch,
                adBlock: store.adBlock,
                hotspotThroughVPN: store.hotspotThroughVPN
            )
        }
        tunnel.wantsHealth = { [weak store] in store?.autoSwitch ?? false }
        tunnel.maskingProvider = { [weak store] server in store?.masking(for: server) }
        pings.maskingFor = { [weak store] server in store?.masking(for: server) ?? .balanced }
        pings.adaptsMasking = { [weak store] in store?.adaptiveMasking ?? false }
        pings.onLearnedMasking = { [weak store] server, profile in store?.learn(profile, for: server) }
        store.network = { [weak network] in network?.kind }
        // The speed test labels its own result: the tunnel can drop while it
        // runs, and then the bytes went out directly.
        speedTest.serverProvider = { [weak tunnel, weak store] in
            guard let tunnel, tunnel.status == .connected,
                  let id = tunnel.activeServerID, let server = store?.state.server(withID: id) else { return nil }
            return server.name
        }
        network.onChange = { [weak self] kind in self?.networkChanged(to: kind) }
        let alerts = self.alerts
        store.onInfoChange = { alerts.scheduleSoon() }
        // A deleted exit shouldn't keep carrying traffic while the interface
        // has moved on to another server: bring the session down too.
        store.onRemoved = { [weak tunnel, weak actions, weak pings, weak stats] ids in
            pings?.forget(ids)
            stats?.forgetServers(ids)
            guard let tunnel, let actions, tunnel.isOn,
                  let live = tunnel.activeServerID, ids.contains(live) else { return }
            Task { await actions.disconnect() }
        }

        // Loads in the background; ranking uses the heuristic until it's ready.
        _ = Kxc.shared

        AppActions.connect = { await actions.connectSelected(waitUntilConnected: true) }
        AppActions.disconnect = { await actions.disconnect() }
        AppActions.switchToFastest = { await actions.switchToFastest(reason: .liveActivity) }
    }

    /// "Маскировка под сеть": on the other kind of network the server may
    /// need the stronger masking that got it through there before. The
    /// tunnel moves to it right away instead of waiting for the checks to
    /// find the server blocked; weaker masking waits for the next start.
    private func networkChanged(to kind: NetworkKind) {
        guard store.adaptiveMasking, tunnel.status == .connected, !tunnel.isBusy, !actions.isSwitching,
              let id = tunnel.activeServerID, let server = store.state.server(withID: id),
              let active = tunnel.activeMasking
        else { return }
        let wanted = store.masking(for: server)
        guard wanted.strength > active.strength else { return }
        Task {
            await actions.connect(server, waitUntilConnected: true)
            liveActivity.show(note: "\(kind == .wifi ? "Wi‑Fi" : "Сотовая сеть"): маскировка «\(wanted.russianTitle)»",
                              alert: false)
        }
    }
}

/// Actions more than one place triggers: the main screen, the Live
/// Activity, widgets, Control Center, Siri and auto-switching.
@MainActor
@Observable
final class QuickActions {
    enum Reason {
        case manual
        case liveActivity
        /// The current server stopped carrying traffic.
        case unhealthy
    }

    private(set) var isSwitching = false

    @ObservationIgnored private let tunnel: TunnelController
    @ObservationIgnored private let store: ServerStore
    @ObservationIgnored private let pings: PingController
    @ObservationIgnored private let liveActivity: LiveActivityController

    init(tunnel: TunnelController, store: ServerStore, pings: PingController, liveActivity: LiveActivityController) {
        self.tunnel = tunnel
        self.store = store
        self.pings = pings
        self.liveActivity = liveActivity
    }

    /// Connects the selected server unless the VPN is already on. Intents
    /// wait for the tunnel, so the Live Activity they start sees it up.
    ///
    /// nil — попытка состоялась, иначе — почему нет. Раньше функция ничего не
    /// возвращала, и кнопка виджета с тумблером «Пункта управления» всегда
    /// отвечали «готово»: отказ (нет выбранного сервера, Hysteria 1, идёт
    /// переключение) оставался текстом внутри приложения, а тумблер —
    /// включённым.
    @discardableResult
    func connectSelected(waitUntilConnected: Bool) async -> String? {
        await tunnel.loadIfNeeded()
        // Пробуждение от виджета или пункта иконки доходит сюда при уже
        // работающем туннеле и выходило молча: смена статуса не происходит,
        // `sync()` сам собой не зовётся — приложение просыпалось, делало работу,
        // а остров оставался пустым.
        if tunnel.isOn {
            liveActivity.sync()
            return nil
        }
        guard let server = store.selected else {
            tunnel.showError("Сначала выберите сервер.")
            return "Сначала выберите сервер."
        }
        return await connect(server, waitUntilConnected: waitUntilConnected)
    }

    /// nil — старт состоялся либо начат и ещё поднимается; иначе — почему
    /// отказ. `connectSelected` отдаёт наружу ровно это.
    @discardableResult
    func connect(_ server: ProxyServer, waitUntilConnected: Bool) async -> String? {
        await tunnel.loadIfNeeded()
        // Refuse before the selection moves: a server this OS cannot run would
        // otherwise become the selected one while the tunnel keeps carrying
        // traffic through another, and the header would name an exit that
        // isn't in use.
        guard server.runsOnIOS else {
            tunnel.showError(TunnelController.unsupportedServerMessage)
            return TunnelController.unsupportedServerMessage
        }
        store.select(server.id)
        store.noteConnected(server)
        var cameUp = true
        await withBackgroundTime("connect") {
            await tunnel.connect(server)
            if waitUntilConnected {
                cameUp = await tunnel.waitForConnection(timeout: 20)
            }
        }
        // Судить по статусу сразу после `startVPNTunnel` нельзя: iOS не успевает
        // убрать конфигурацию из `.disconnected`, и тумблер «Пункта управления»
        // откатывался бы назад над туннелем, который поднялся секундой позже.
        // `tunnel.connect` очищает `lastError` в своём начале, так что висящий
        // там текст относится именно к этой попытке.
        if let error = tunnel.lastError {
            return error.components(separatedBy: "\n").first
        }
        // А после состоявшегося ожидания статус спрашивать можно: 20 секунд
        // прошло, и «не поднялся» — отказ, а не гонка за статусом.
        if waitUntilConnected, !cameUp, !tunnel.isOn { return "Туннель не поднялся" }
        return nil
    }

    func disconnect() async {
        await tunnel.loadIfNeeded()
        await withBackgroundTime("disconnect") {
            await tunnel.disconnect()
        }
    }

    /// Checks every server for real and moves to the best one: a running
    /// tunnel follows, a stopped one just gets the selection. Returns what
    /// happened, in words.
    @discardableResult
    func switchToFastest(reason: Reason) async -> String? {
        guard !isSwitching else { return nil }
        isSwitching = true
        defer { isSwitching = false }
        await tunnel.loadIfNeeded()
        let wasRunning = tunnel.isOn
        if wasRunning { liveActivity.beginSearch() }
        var outcome: String?
        await withBackgroundTime("fastest") {
            let servers = store.allServers
            let current = tunnel.activeServerID
            let currentServer = current.flatMap { store.state.server(withID: $0) }
            let maskingBefore = currentServer.map { store.masking(for: $0) }
            // Ranking on verdicts from an earlier round moves a working
            // tunnel onto a server that is also down, and reports "другие
            // тоже не отвечают" while they answer fine.
            if !(await pings.checkAll(servers)) {
                guard await pings.waitForRound() else {
                    outcome = "Проверка ещё идёт — итог покажет Live Activity"
                    return
                }
            }
            // «Включён ли VPN» спрашивается заново, а не берётся из замера до
            // проб: раунд на тридцати серверах идёт минуты, и за это время
            // успевает нажать «выключить» сам пользователь — в Пункте
            // управления, в «Настройках», здесь же в приложении. Прежний ответ
            // значил «поднять туннель против его кнопки»: `connect` сбрасывает
            // `stopRequested`, и автопереподключение возвращалось вместе с ним.
            //
            // Но `isOn` одно и «пользователь выключил», и «сессия умерла сама»
            // при выключенном автопереподключении: второе как раз и есть
            // случай умного переключения, и раньше оно поднимало туннель на
            // новом выходе. Различает их намерение — `stopRequested`.
            let running = tunnel.isOn || (wasRunning && !tunnel.stopRequested)
            // The server in use works again with stronger masking: stay on it.
            if reason == .unhealthy, running, let currentServer, case .works = pings.verdicts[currentServer.id],
               store.masking(for: currentServer) != maskingBefore {
                await tunnel.connect(currentServer)
                // Результат ожидания не выбрасывается: без него остров и Siri
                // сообщали «усилил маскировку» о туннеле, который так и не
                // поднялся, а полоса отказов на мёртвом выходе обнулилась бы.
                if await tunnel.waitForConnection(timeout: 20) {
                    outcome = "Сервер блокировали — усилил маскировку"
                } else {
                    outcome = "Усилил маскировку, но туннель не поднялся"
                }
                return
            }
            guard let best = pings.best(among: servers, excluding: reason == .unhealthy ? current : nil) else {
                outcome = reason == .unhealthy ? "Другие серверы тоже не отвечают" : "Ни один сервер не ответил"
                return
            }
            let name = LiveActivityController.describe(best).title
            if running, best.id == current {
                outcome = "Этот сервер и так самый быстрый"
                return
            }
            store.select(best.id)
            guard running else {
                outcome = "Выбран \(name)"
                return
            }
            store.noteConnected(best)
            await tunnel.connect(best)
            if await tunnel.waitForConnection(timeout: 20) {
                outcome = reason == .unhealthy ? "Сервер перестал отвечать — теперь \(name)" : "Переключился: \(name)"
            } else {
                // Тот же случай: выбор уже передвинут, и рапорт о переезде по
                // свежеподнявшемуся туннелю был бы неправдой.
                outcome = "Пробую \(name) — туннель ещё не поднялся"
            }
        }
        // Снимается по тому же признаку, по которому и ставился: поиск начинался
        // только при включённом туннеле, и «выключить» посреди раунда не может
        // оставить `searching` включённым навсегда.
        if wasRunning { liveActivity.endSearch(note: outcome) }
        return outcome
    }

    /// Asks iOS for time to finish if the app leaves the screen meanwhile.
    private func withBackgroundTime(_ name: String, _ work: () async -> Void) async {
        let held = BackgroundTask()
        held.adopt(UIApplication.shared.beginBackgroundTask(withName: name) { held.expire() })
        defer { held.finish() }
        await work()
    }

    /// The expiration handler is not optional: when iOS takes the time back and
    /// the app still holds the identifier, the next suspension ends the process
    /// with "background task failed". A whole probe sweep
    /// (`switchToFastest` → `pings.checkAll`) is far longer than the grant.
    private final class BackgroundTask: @unchecked Sendable {
        private let lock = NSLock()
        private var task: UIBackgroundTaskIdentifier = .invalid
        private var finished = false

        func adopt(_ id: UIBackgroundTaskIdentifier) {
            lock.lock()
            let late = finished
            if !late { task = id }
            lock.unlock()
            // The grant ended before we even got the identifier.
            if late { UIApplication.shared.endBackgroundTask(id) }
        }

        /// iOS took the time back. The work isn't cancelled — it just loses its
        /// protection, which is what the grant was for.
        func expire() { release() }

        func finish() { release() }

        private func release() {
            lock.lock()
            let id = task
            task = .invalid
            finished = true
            lock.unlock()
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
        }
    }
}

/// "Умное переключение": the tunnel extension checks every 30 s that the
/// tunnel carries traffic; after two failed checks in a row the app moves to
/// the best working server. Not too eagerly: a fresh session gets a minute,
/// and at most three switches happen per quarter of an hour.
@MainActor
final class AutoSwitch {
    private let actions: QuickActions
    private let tunnel: TunnelController
    private let store: ServerStore
    private let liveActivity: LiveActivityController
    private let policy = AutoSwitchPolicy()
    private var budget = SwitchBudget()
    /// Часы процесса: `Date` шагают вместе с ручной правкой времени и крупной
    /// сверкой NTP, а `SwitchBudget` и порог «минуту после подъёма не трогать»
    /// оперируют длинами. Шаг вперёд на Δ снимал и паузу между переключениями
    /// (возраст отметки вдруг больше 180 с), и весь бюджет (отметки старше окна
    /// исчезают), и выдержку сессии — три переезда по десяти секундному туннелю
    /// за один шаг. Шаг назад, наоборот, глушил переключение на Δ + 900 с.
    /// Часы, которые идут и во сне. `ProcessInfo.systemUptime` и
    /// `DispatchTime.now()` стоят, пока телефон спит, — а спит он именно тогда,
    /// когда туннель работает: пауза в 180 с и окно в 15 минут превращались в
    /// «время бодрствования», то есть защита опаздывала на всю длительность сна.
    /// `mach_continuous_time` — он же `elapsedRealtime` на Android, так что
    /// порог на обеих платформах значит одно и то же.
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()
    private var uptime: TimeInterval {
        let info = Self.timebase
        return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }
    /// Когда началось текущее `report.startedAt` по тем же часам.
    private var firstSeen: (startedAt: Date, uptime: TimeInterval)?

    init(actions: QuickActions, tunnel: TunnelController, store: ServerStore, liveActivity: LiveActivityController) {
        self.actions = actions
        self.tunnel = tunnel
        self.store = store
        self.liveActivity = liveActivity
    }

    /// With every fresh report from the extension. The thresholds themselves
    /// live in `AutoSwitchPolicy`, which the Android port mirrors and the
    /// `switchdue` golden pins.
    func evaluate() {
        guard let report = tunnel.report else { return }
        let seconds = uptime
        // Возраст сессии — тоже по монотонным часам, но отсчитываемый от момента,
        // когда это `startedAt` впервые увидел свет: сам он пришёл из расширения
        // как дата и под шаг часов подстраивается так же плохо. Цена — лишний
        // «минуту подожди» после перезапуска приложения посреди сессии; в эту
        // сторону ошибаться безопасно, в обратную — нет.
        if firstSeen?.startedAt != report.startedAt { firstSeen = (report.startedAt, uptime) }
        let sessionAge = uptime - (firstSeen?.uptime ?? uptime)
        // «Куда переключаться»: считаем только те выходы, которые iPhone способен
        // запустить (`best(among:)` иные отсекает), и прибавляем тот, что несёт
        // трафик прямо сейчас, даже если панель уже сняла его с выдачи — иначе
        // именно на таком сеансе переключение молча глохло.
        var runnableCandidates = store.allServers.filter(\.runsOnIOS).count
        if let live = tunnel.activeServerID, store.state.server(withID: live) == nil {
            runnableCandidates += 1
        }
        let verdict = policy.decide(
            enabled: store.autoSwitch,
            connected: tunnel.status == .connected,
            busy: tunnel.isBusy || actions.isSwitching,
            // Считать только те выходы, на которых iPhone способен ехать:
            // «куда переключаться» решает `best(among:)`, а он такие отсекает.
            // С панелью из одного рабочего VLESS и двенадцати Hysteria 1
            // формальное «серверов больше одного» заводило полную проверку
            // раунда ради ответа «другие тоже не отвечают», и слот бюджета
            // сгорал на попытке, которая не могла никуда переехать.
            // +1 на тот выход, который сейчас несёт трафик, даже если панель
            // уже сняла его с выдачи: без него «один кандидат + Hysteria 1»
            // читалось как «переключаться не на что», хотя второй сервер был.
            serverCount: runnableCandidates,
            healthFailures: report.healthFailures,
            sessionAge: sessionAge,
            recentSwitches: budget.ages(at: seconds)
        )
        guard verdict == .go else { return }
        budget.note(seconds)
        let before = tunnel.activeServerID
        Task {
            let outcome = await actions.switchToFastest(reason: .unhealthy)
            // Nothing started — another switch was already in flight. Such an
            // attempt used to spend one of the three slots the quarter allows,
            // so three collisions could mute auto-switching for 15 minutes
            // without anything having happened.
            guard let outcome else {
                budget.refund(seconds)
                return
            }
            if tunnel.activeServerID != before {
                liveActivity.show(note: outcome, alert: true)
            }
        }
    }
}

/// Keeps the Home Screen widget and the Control Center switch current.
@MainActor
final class WidgetBridge {
    private var last: WidgetSnapshot?

    func update(tunnel: TunnelController, server: ProxyServer?, sessionStart: Date?) {
        let described = server.map(LiveActivityController.describe)
        let snapshot = WidgetSnapshot(
            isOn: tunnel.isOn,
            connected: tunnel.status == .connected,
            countryCode: described?.code,
            title: described?.title ?? "Anemia",
            subtitle: described?.subtitle ?? "Сервер не выбран",
            connectedSince: tunnel.status == .connected ? (sessionStart ?? tunnel.report?.startedAt) : nil,
            latency: tunnel.report?.latency,
            received: tunnel.report?.downloaded ?? 0,
            sent: tunnel.report?.uploaded ?? 0,
            updatedAt: .now
        )
        HomeScreenActions.update(isOn: tunnel.isOn, server: described?.title)
        let changed = last.map {
            $0.isOn != snapshot.isOn || $0.connected != snapshot.connected || $0.title != snapshot.title
                || $0.subtitle != snapshot.subtitle || $0.connectedSince != snapshot.connectedSince
        } ?? true
        // The numbers alone: once a minute is plenty for a widget.
        guard changed || snapshot.updatedAt.timeIntervalSince(last?.updatedAt ?? .distantPast) > 60 else { return }
        last = snapshot
        SharedStore.write(snapshot)
        guard changed else { return }
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.status)
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadControls(ofKind: WidgetKinds.control)
        }
    }
}
