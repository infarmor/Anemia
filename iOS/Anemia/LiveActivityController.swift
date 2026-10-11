import ActivityKit
import Foundation
import LoaderCore
import NetworkExtension
import Observation
import UIKit
import os

/// Runs the tunnel's Live Activity. Only the app can start or update one
/// (the tunnel extension sees no activities), so the app starts it as soon as
/// the tunnel starts connecting — iOS allows starts only from the foreground
/// app or from inside a LiveActivityIntent — and feeds it every 4 s. With
/// "Скорость в фоне" on, the BackgroundKeeper keeps the app running so the
/// feed goes on after the app leaves the screen.
///
/// One activity lives through the whole session: server switches and drops
/// update it (starting a new one from the background mostly isn't allowed),
/// and when the session ends it shows a summary for a few minutes.
///
/// The system redraws the island on every update, so an update goes out only
/// when something the user can see changed; the graph refreshes five times
/// less often than the numbers.
@MainActor
@Observable
final class LiveActivityController {
    typealias State = TunnelActivityAttributes.ContentState

    /// "Live Activity" in the app.
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            sync()
        }
    }

    /// "Скорость в фоне": keep the app running to keep the speed live.
    var updatesInBackground: Bool {
        didSet {
            UserDefaults.standard.set(updatesInBackground, forKey: Self.backgroundKey)
            sync()
        }
    }

    /// Settings → Anemia → Live Activities.
    private(set) var systemAllows = ActivityAuthorizationInfo().areActivitiesEnabled

    /// When the current session started, reconnects included; nil while
    /// nothing is connected. The widgets show it too.
    var sessionStart: Date? { session.connectedSince }

    /// A snapshot for the diagnostics screen: what the system did with the
    /// activity, and whether the feed and the silent audio are still alive.
    /// All of this used to go to os_log only, which helps after the island
    /// has already gone blank on a phone that isn't plugged into a Mac.
    var diagnostics: Diagnostics {
        Diagnostics(
            enabled: isEnabled,
            systemAllows: systemAllows,
            phase: shownPhase,
            activity: Activity<TunnelActivityAttributes>.activities.first.map(Self.info),
            feedRunning: feed != nil,
            updatesPerMinute: sendTimes.filter { Date().timeIntervalSince($0) < 60 }.count,
            lastSend: lastSent?.time,
            lastError: lastError,
            lastErrorAt: lastErrorAt,
            startBlocked: startHold != .none,
            keeperRunning: keeper.isRunning,
            keeperProducing: keeper.isProducing,
            keeperRestarts: keeper.restarts,
            keeperLastRestart: keeper.lastRestart
        )
    }

    struct Diagnostics {
        var enabled: Bool
        var systemAllows: Bool
        /// What the tunnel looks like to the activity; nil — no session.
        var phase: State.Phase?
        var activity: ActivityInfo?
        var feedRunning: Bool
        var updatesPerMinute: Int
        var lastSend: Date?
        var lastError: String?
        var lastErrorAt: Date?
        /// Старт активности заблокирован до следующего выхода на экран —
        /// единственный, кто объясняет пустой остров без ошибки ActivityKit
        /// (свайп состояние `.dismissed` ни во что не пишет).
        var startBlocked = false
        var keeperRunning: Bool
        /// Whether the silent stream is actually reaching the audio hardware.
        var keeperProducing: Bool
        var keeperRestarts: Int
        var keeperLastRestart: Date?
    }

    struct ActivityInfo {
        enum Presentation: String {
            case active = "живёт в острове"
            case stale = "помечена устаревшей"
            case ended = "завершена"
            case dismissed = "её убрали свайпом"
            case unknown = "неизвестно"
        }

        var presentation: Presentation
        /// When the system will call the content outdated.
        var staleAt: Date?
        /// What the island shows now. A gap with `Diagnostics.phase` that
        /// holds while the feed runs means the system isn't taking updates:
        /// `update` never reports failure.
        var shown: State.Phase
    }

    private static func info(_ activity: Activity<TunnelActivityAttributes>) -> ActivityInfo {
        let presentation: ActivityInfo.Presentation
        switch activity.activityState {
        case .active: presentation = .active
        case .stale: presentation = .stale
        case .ended: presentation = .ended
        case .dismissed: presentation = .dismissed
        // `.pending` exists only from iOS 26, so it can't be named here;
        // "something else" covers it and anything Apple adds later.
        default: presentation = .unknown
        }
        return ActivityInfo(presentation: presentation,
                            staleAt: activity.content.staleDate,
                            shown: activity.content.state.phase)
    }

    @ObservationIgnored private weak var tunnel: TunnelController?
    @ObservationIgnored private var server: ProxyServer?
    @ObservationIgnored private let keeper = BackgroundKeeper()
    @ObservationIgnored private var feed: Task<Void, Never>?
    @ObservationIgnored private var lastSent: (state: State, time: Date)?
    @ObservationIgnored private var session = Session()
    @ObservationIgnored private var graphTick = 0
    @ObservationIgnored private var searching = false
    @ObservationIgnored private var note: (text: String, until: Date)?
    /// An alert waiting for the next update, so it doesn't arrive as a second
    /// one in the same turn.
    @ObservationIgnored private var pendingAlert: AlertConfiguration?
    /// A server switch started by the app: the drop it causes isn't one.
    @ObservationIgnored private var switchingUntil: Date?
    @ObservationIgnored private var reconnectingSince: Date?
    @ObservationIgnored private var alertedThisDrop = false
    @ObservationIgnored private var lastAlert = Date.distantPast
    @ObservationIgnored private var isDemo = false
    /// The activity whose state we follow; nil once it's gone.
    @ObservationIgnored private var watched: String?
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    /// Поднимать активность можно только с переднего плана: после отказа
    /// ActivityKit и после того, как активность убрали свайпом, просить её
    /// заново при следующем выходе приложения на экран (так это и описано в
    /// README), а не каждые четыре секунды из фоновой ленты — фоновый старт
    /// чаще всего и не проходит, а бюджет обновлений при этом сгорает.
    /// Почему старт активности пока не просим. Два разных отказа путать
    /// нельзя: временный отказ ActivityKit нужно переспросить через минуту,
    /// а свайп человека — только когда он сам снова окажется на экране, иначе
    /// остров возвращался бы к нему каждые 60 секунд, сколько бы раз он его
    /// ни убирал.
    enum StartHold: Equatable {
        case none
        case refused(Date)
        case dismissed
    }
    @ObservationIgnored private var startHold: StartHold = .none
    /// When each update went out, the last minute of them.
    @ObservationIgnored private var sendTimes: [Date] = []
    private(set) var lastError: String?
    private(set) var lastErrorAt: Date?
    /// The phase the island shows. The diagnostics read this rather than ask
    /// `currentPhase()`, which moves the switch window along with it.
    @ObservationIgnored private var shownPhase: State.Phase?
    @ObservationIgnored private let log = Logger(subsystem: "Anemia", category: "activity")

    private static let enabledKey = "liveActivityEnabled"
    private static let backgroundKey = "liveActivityBackground"
    /// How long the summary stays after the session ends.
    private static let summaryTime: TimeInterval = 5 * 60
    /// The feed's period, and how many of its ticks a graph point waits for.
    static let feedInterval: TimeInterval = 4
    private static let graphTicks = 5
    /// How far ahead the activity is declared outdated, and how long an
    /// unchanged screen may go without a heartbeat. iOS suspends the app even
    /// with the silent stream running, so a short silence shouldn't restyle
    /// the island: the outdated state is for a feed that really stopped.
    private static let staleAfter: TimeInterval = 300
    private static let heartbeat: TimeInterval = 60
    /// Как часто просить старт, пока приложение на экране: отказ ActivityKit
    /// обычно временный (бюджет, 8-часовой лимит прошлой активности), и
    /// молча ждать следующего выхода на экран значило бы оставить остров
    /// пустым при открытом приложении.
    private static let startRetryWhileFront: TimeInterval = 60

    private struct Session {
        var connectedSince: Date?
        /// When the first connection attempt of this session began.
        var pendingSince = Date()
        /// Bytes of earlier tunnel runs within this session.
        var carriedReceived: Int64 = 0
        var carriedSent: Int64 = 0
        var run: (startedAt: Date, received: Int64, sent: Int64)?
        /// Every sample the feed takes.
        var down: [Int] = []
        var up: [Int] = []
        /// What the activity shows: refreshed every `graphTicks` ticks, so
        /// the island isn't redrawn for a graph nobody compares point by point.
        var shownDown: [Int] = []
        var shownUp: [Int] = []
        var latency: Int?

        var received: Int64 { carriedReceived + (run?.received ?? 0) }
        var sent: Int64 { carriedSent + (run?.sent ?? 0) }

        mutating func take(_ report: TunnelReport) {
            if let run, run.startedAt != report.startedAt {
                carriedReceived += run.received
                carriedSent += run.sent
                // Байты предыдущего прохода переезжают в итог сессии, а задержку
                // — нет: измерена она была другим выходом. У расширения новый
                // `Session` стартует с nil, и пока он сам не ответит, остров
                // показывал бы «42 мс» рядом с названием уже другого сервера — а
                // для AmneziaWG/WireGuard, где проба ICMP обычно молчит, это
                // длилось бы всю сессию.
                latency = nil
            }
            run = (report.startedAt, report.downloaded, report.uploaded)
            if let latency = report.latency { self.latency = latency }
        }

        mutating func sample(_ speed: (download: Double, upload: Double)) {
            down.append(Int(speed.download / 1000))
            up.append(Int(speed.upload / 1000))
            let limit = State.historyLength
            if down.count > limit { down.removeFirst(down.count - limit) }
            if up.count > limit { up.removeFirst(up.count - limit) }
        }

        mutating func commitGraph() {
            shownDown = down
            shownUp = up
        }
    }

    init(tunnel: TunnelController) {
        self.tunnel = tunnel
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        updatesInBackground = defaults.object(forKey: Self.backgroundKey) as? Bool ?? true
        Task { [weak self] in
            for await allowed in ActivityAuthorizationInfo().activityEnablementUpdates {
                self?.systemAllows = allowed
                self?.sync()
            }
        }
    }

    /// Call on every tunnel status or server change.
    func tunnelChanged(server: ProxyServer?) {
        if let server { self.server = server }
        if tunnel?.isBusy == true {
            switchingUntil = Date().addingTimeInterval(30)
        }
        sync()
    }

    /// The "Быстрее" round is on: the activity says so until `endSearch`.
    func beginSearch() {
        searching = true
        note = nil
        sync()
    }

    func endSearch(note text: String?) {
        searching = false
        if let text { note = (text, Date().addingTimeInterval(8)) }
        sync()
    }

    /// A line in place of the numbers for a few seconds, optionally lighting
    /// up the screen and the island.
    func show(note text: String, alert: Bool) {
        note = (text, Date().addingTimeInterval(10))
        // The alert rides the next update instead of going out as a second one
        // in the same turn: ActivityKit coalesces those, and the update that
        // survives is the one without the alert.
        if alert {
            pendingAlert = AlertConfiguration(title: "Anemia", body: "\(text)", sound: .default)
        }
        sync()
    }

    /// Приложение снова на экране: с переднего плана iOS опять разрешает
    /// поднять активность, так что блокировка после отказа или свайпа снимается
    /// здесь (см. README: «свайпнутую поднимает заново при следующем выходе
    /// приложения на экран»).
    func backInFront() {
        startHold = .none
        // Перечитывается здесь, а не в каждом `sync()`: ветка «система
        // запретила активности» разбирает сессию (`endAll()` + `session =
        // Session()`) и сжигает итог, поэтому одиночный ложный ответ
        // `liveactivitiesd` на фоне стирал бы живой сеанс. С переднего плана
        // такой каприз безвреден — там же и разрешение реально меняется.
        systemAllows = ActivityAuthorizationInfo().areActivitiesEnabled
        sync()
    }

    /// «На экране» — это переход в `.active`, а его может и не быть: сцена
    /// иногда рождается уже активной, и свайп или отказ ActivityKit случаются
    /// при открытой программе. Тогда раз в минуту, а не блокировка до конца
    /// процесса — иначе остров пустел навсегда, и ни одна кнопка его не
    /// возвращала.
    private func liftBlockIfNeeded() {
        guard case .refused(let at) = startHold else { return }
        // `.active`, а не `!= .background`: за шторкой или «Пунктом управления»
        // старт всё равно запрещён, и каждая такая минута только перемазывала
        // бы «Диагностику» безвредным отказом вместо настоящей причины.
        if UIApplication.shared.applicationState == .active,
           Date().timeIntervalSince(at) >= Self.startRetryWhileFront {
            startHold = .none
        }
    }

    func sync() {
        guard !isDemo else { return }
        liftBlockIfNeeded()
        guard isEnabled, systemAllows else {
            stopFeed()
            keeper.stop()
            endAll()
            session = Session()
            shownPhase = nil
            graphTick = 0
            pendingAlert = nil
            return
        }
        guard let phase = currentPhase() else {
            shownPhase = nil
            finish()
            return
        }
        begin(phase)
        track(phase)
        push(phase)
        // Лента и аудио работают, пока они разрешены: во время удержания `push`
        // в ActivityKit не стучится, а остановленная лента отняла бы единственный
        // оживитель (`onReport` `sync()` не зовёт — перечитать разрешение и
        // повторить просьбу было бы некому) и убила бы беззвучным аудио умное
        // переключение и автообновление подписок.
        startFeed()
        if updatesInBackground {
            keeper.start()
        } else {
            keeper.stop()
        }
    }

    /// Первая фаза новой сессии: `pendingSince` — отсчёт «до первого
    /// `.connected»`, и он обязан быть моментом начала подключения, а не
    /// моментом, когда контроллер создался или убрал прошлую сессию. Иначе
    /// кольцо часов и таймер показывают «2:04» там, где туннель ещё не поднялся.
    private func begin(_ phase: State.Phase) {
        if shownPhase == nil { session.pendingSince = Date() }
        shownPhase = phase
    }

    // MARK: - Phase

    private func currentPhase() -> State.Phase? {
        guard let tunnel, server != nil else { return nil }
        let now = Date()
        if tunnel.isBusy { switchingUntil = now.addingTimeInterval(30) }
        // A refused start (no permission, a bad configuration, Hysteria 1)
        // leaves that window standing: without this the island keeps saying
        // «Подключение…» for half a minute after the engine already answered
        // with an error, and then drops the session without a summary.
        if tunnel.lastError != nil, tunnel.status == .disconnected || tunnel.status == .invalid {
            switchingUntil = nil
        }
        // The user turned the tunnel off: the switch window left over from
        // the last server change doesn't hold the session open.
        if tunnel.stopRequested { switchingUntil = nil }
        let switching = (switchingUntil ?? .distantPast) > now
        // «Ищу быстрый сервер» тоже снимается по этой же кнопке: раунд идёт
        // минуты, и всё это время фаза была бы не nil — итог сессии не
        // наступал бы, беззвучное аудио и лента продолжали бы работать над
        // выключенным туннелем, а `finish()` потом замерил бы «в сети» по
        // всему окну простоя.
        if searching, !tunnel.stopRequested { return .searching }
        switch tunnel.status {
        case .connected:
            switchingUntil = nil
            return .connected
        case .connecting:
            return session.connectedSince != nil && !switching ? .reconnecting : .connecting
        case .reasserting:
            return .reconnecting
        case .disconnecting, .disconnected, .invalid:
            if switching { return .connecting }
            // Auto-reconnect: iOS brings it back, so the session goes on.
            if session.connectedSince != nil, tunnel.expectsReconnect { return .reconnecting }
            return nil
        @unknown default:
            return nil
        }
    }

    /// Session bookkeeping for the phase the tunnel is in.
    private func track(_ phase: State.Phase) {
        let now = Date()
        if phase == .connected, let tunnel {
            if session.connectedSince == nil {
                session.connectedSince = tunnel.report?.startedAt ?? now
            }
            if let report = tunnel.report { session.take(report) }
        }
        if phase == .reconnecting {
            if reconnectingSince == nil { reconnectingSince = now }
        } else {
            reconnectingSince = nil
            alertedThisDrop = false
        }
        if let note, note.until < now {
            self.note = nil
            // Отложенное уведомление живёт ровно столько, сколько его строка:
            // когда активности нет, `push` его не отправляет вовсе, и без этого
            // `pendingAlert` переживал и строку, и сессию — будил экран
            // словами «Сервер перестал отвечать» через часы, уже на другом
            // выходе.
            pendingAlert = nil
        }
    }

    // MARK: - Activity

    private func liveActivity() -> Activity<TunnelActivityAttributes>? {
        Activity<TunnelActivityAttributes>.activities.first { $0.activityState == .active || $0.activityState == .stale }
    }

    private func push(_ phase: State.Phase, force: Bool = false) {
        let state = makeState(phase: phase)
        let current = Activity<TunnelActivityAttributes>.activities
        // A summary from the previous session gives way to the new one.
        for activity in current where activity.activityState == .ended || activity.activityState == .dismissed {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        let live = current.filter { $0.activityState == .active || $0.activityState == .stale }
        if live.isEmpty, current.contains(where: {
            // iOS hasn't put the one we asked for on screen yet (`.pending`,
            // a state newer than the deployment target). Asking again would
            // stack a second activity on top of it.
            $0.activityState != .ended && $0.activityState != .dismissed
        }) { return }
        guard let activity = live.first else {
            // Просьба не превращается в цикл: после отказа ActivityKit, после
            // 8-часового лимита и после свайпа лента не стучится каждые четыре
            // секунды — фоновый старт обычно не проходит, а бюджет обновлений
            // сгорает. Право на новую попытку даёт следующий выход приложения
            // на экран (`backInFront`).
            if startHold == .none { request(state) }
            return
        }
        for extra in live.dropFirst() {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
        watch(activity)

        // A drop that lasts: light up the screen, once per drop and at most
        // every five minutes.
        if phase == .reconnecting, let since = reconnectingSince, !alertedThisDrop,
           Date().timeIntervalSince(since) >= 5, Date().timeIntervalSince(lastAlert) >= 300 {
            alertedThisDrop = true
            lastAlert = Date()
            let alert = AlertConfiguration(title: "Связь с сервером прервалась",
                                           body: "Anemia переподключается…", sound: .default)
            send(state, to: activity, alert: alert)
            return
        }
        // Only what the user would see change, plus a heartbeat so the
        // activity doesn't turn stale while the numbers hold.
        if !force, !changed(state) { return }
        send(state, to: activity)
    }

    /// Whether this state is worth redrawing the island for: what the views
    /// show, not the raw counters — a few kilobits of drift isn't.
    private func changed(_ state: State) -> Bool {
        guard let lastSent else { return true }
        if Date().timeIntervalSince(lastSent.time) >= Self.heartbeat { return true }
        return Self.signature(state) != Self.signature(lastSent.state)
    }

    private static func signature(_ state: State) -> String {
        "\(state.phase)|\(state.countryCode ?? "")|\(state.title)|\(state.subtitle)|\(state.note ?? "")"
            + "|\(ActivityStatus.text(state, isStale: false))"
            + "|\(Bytes.text(state.received))|\(Bytes.text(state.sent))|\(state.latency ?? -1)"
            + "|\(state.downHistory.last ?? -1)|\(state.downHistory.count)"
    }

    private func request(_ state: State) {
        do {
            let activity = try Activity.request(
                attributes: TunnelActivityAttributes(),
                content: ActivityContent(state: state, staleDate: .now.addingTimeInterval(Self.staleAfter))
            )
            lastSent = (state, Date())
            recordSend()
            lastError = nil
            lastErrorAt = nil
            startHold = .none
            watch(activity)
        } catch {
            // Typically: the app isn't in front. The next launch retries —
            // repeating it from the 4 s feed would only spend the update
            // budget on a start iOS keeps refusing.
            lastError = error.localizedDescription
            lastErrorAt = Date()
            startHold = .refused(Date())
            log.error("live activity: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func send(_ state: State, to activity: Activity<TunnelActivityAttributes>,
                      alert: AlertConfiguration? = nil) {
        lastSent = (state, Date())
        recordSend()
        let alert = alert ?? pendingAlert
        pendingAlert = nil
        let content = ActivityContent(state: state, staleDate: .now.addingTimeInterval(Self.staleAfter))
        Task { await activity.update(content, alertConfiguration: alert) }
    }

    /// The system never tells us an update was dropped — `update` doesn't
    /// throw — so the diagnostics compare these times with the content the
    /// activity holds.
    private func recordSend() {
        sendTimes.append(Date())
        if sendTimes.count > 120 { sendTimes.removeFirst(sendTimes.count - 120) }
    }

    /// Follows one activity's state. The system can mark the activity stale
    /// or the user can swipe it away, and the feed has to notice at once
    /// rather than keep pushing into something nobody renders.
    private func watch(_ activity: Activity<TunnelActivityAttributes>) {
        guard watched != activity.id else { return }
        unwatch()
        watched = activity.id
        stateTask = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard let self, !Task.isCancelled else { return }
                guard state != .active else { continue }
                self.log.notice("live activity: \(String(describing: state), privacy: .public)")
                self.lastSent = nil
                // Убрали свайпом — значит человек её не хотел: поднимаем заново
                // при следующем выходе на экран, а не моментом позже, пока
                // лента ещё крутится.
                if state == .dismissed {
                    self.startHold = .dismissed
                }
                self.sync()
            }
        }
    }

    private func unwatch() {
        stateTask?.cancel()
        stateTask = nil
        watched = nil
    }

    /// The session is over: its summary stays for a few minutes. An activity
    /// that never got connected just goes.
    private func finish() {
        stopFeed()
        keeper.stop()
        defer {
            session = Session()
            searching = false
            startHold = .none
            note = nil
            reconnectingSince = nil
            switchingUntil = nil
            alertedThisDrop = false
            graphTick = 0
            pendingAlert = nil
        }
        guard let activity = liveActivity() else { return }
        guard session.connectedSince != nil else {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
            return
        }
        var state = makeState(phase: .ended)
        state.endedAt = Date()
        if tunnel?.stopRequested != true {
            state.note = "Соединение прервалось"
        }
        let content = ActivityContent(state: state, staleDate: nil)
        Task { await activity.end(content, dismissalPolicy: .after(.now.addingTimeInterval(Self.summaryTime))) }
    }

    private func endAll() {
        unwatch()
        for activity in Activity<TunnelActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func makeState(phase: State.Phase) -> State {
        let attributes: (code: String?, title: String, subtitle: String) =
            server.map(Self.describe) ?? (code: nil, title: "Anemia", subtitle: "")
        let speed = phase == .connected ? tunnel?.speed : nil
        return State(
            phase: phase,
            countryCode: attributes.code,
            title: attributes.title,
            subtitle: attributes.subtitle,
            download: speed?.download ?? 0,
            upload: speed?.upload ?? 0,
            downHistory: session.shownDown,
            upHistory: session.shownUp,
            connectedSince: session.connectedSince ?? session.pendingSince,
            received: session.received,
            sent: session.sent,
            latency: session.latency,
            note: note.map(\.text)
        )
    }

    // MARK: - Feed

    private func startFeed() {
        guard feed == nil else { return }
        feed = Task { [weak self] in
            while !Task.isCancelled {
                // `try?` would swallow the cancellation error and run one more
                // tick after `stopFeed()` has already unwound the session —
                // enough to request a fresh activity for a session that ended.
                do { try await Task.sleep(for: .seconds(LiveActivityController.feedInterval)) }
                catch { return }
                self?.tick()
            }
        }
    }

    private func stopFeed() {
        feed?.cancel()
        feed = nil
        lastSent = nil
        unwatch()
    }

    /// Every 4 s: a graph point from TunnelController's polled speed, then
    /// whatever the island would show differently.
    private func tick() {
        guard !isDemo, isEnabled, systemAllows else { return }
        // Лента — единственный, кто ещё может вспомнить про старт: на
        // переднем плане `sync()` здесь не ожидается.
        liftBlockIfNeeded()
        guard let phase = currentPhase() else {
            shownPhase = nil
            finish()
            return
        }
        begin(phase)
        if phase == .connected, let speed = tunnel?.speed {
            session.sample(speed)
            graphTick += 1
            // Commit right away while the graph is still too short to draw,
            // then every few ticks: the island doesn't need it more often.
            if graphTick >= Self.graphTicks || session.shownDown.count < 2 {
                graphTick = 0
                session.commitGraph()
            }
        }
        track(phase)
        push(phase)
    }

    // MARK: - Server

    /// Country, title and subtitle for the activity.
    static func describe(_ server: ProxyServer) -> (code: String?, title: String, subtitle: String) {
        let code = Country.code(inServerName: server.name)
        let place = Country.place(inServerName: server.name)
        let title = code.map(Country.name) ?? (place.isEmpty ? server.name : place)
        var subtitle = server.shortKindLabel
        if code != nil, !place.isEmpty, place != title {
            subtitle = place + " · " + subtitle
        }
        return (code, title, subtitle)
    }

    #if targetEnvironment(simulator)
    /// `-demoLiveActivity`: a sample activity whose speed keeps changing, for
    /// checking the design and the background feed in the simulator, where
    /// the tunnel itself can't run. `-demoPhase reconnecting|searching|ended`
    /// shows another phase.
    func startDemo(phase: State.Phase = .connected) {
        isDemo = true
        endAll()
        var state = State(
            phase: phase == .ended ? .connected : phase, countryCode: "FR", title: "Франция",
            subtitle: "Париж · VLESS · Reality", download: 48_200_000, upload: 3_100_000,
            connectedSince: .now.addingTimeInterval(-4_324), received: 1_240_000_000, sent: 86_000_000, latency: 42
        )
        var down = 48_200.0
        var up = 3_100.0
        for _ in 0..<State.historyLength {
            down = min(max(down * Double.random(in: 0.8...1.22), 4_000), 120_000)
            up = min(max(up * Double.random(in: 0.8...1.22), 400), 12_000)
            state.downHistory.append(Int(down))
            state.upHistory.append(Int(up))
        }
        do {
            let activity = try Activity.request(attributes: TunnelActivityAttributes(),
                                                content: ActivityContent(state: state,
                                                                         staleDate: .now.addingTimeInterval(Self.staleAfter)))
            if phase == .ended {
                state.phase = .ended
                state.endedAt = .now
                state.note = "Соединение прервалось"
                Task { await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .default) }
                return
            }
        } catch {
            log.error("demo live activity: \(String(describing: error), privacy: .public)")
        }
        if updatesInBackground { keeper.start() }
        guard phase == .connected else { return }
        feed = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(LiveActivityController.feedInterval))
                tick += 1
                guard let activity = Activity<TunnelActivityAttributes>.activities.first else { continue }
                var next = activity.content.state
                down = min(max(down * Double.random(in: 0.75...1.3), 2_000), 300_000)
                up = min(max(up * Double.random(in: 0.75...1.3), 300), 50_000)
                next.download = down * 1000
                next.upload = up * 1000
                next.downHistory = Array((next.downHistory + [Int(down)]).suffix(State.historyLength))
                next.upHistory = Array((next.upHistory + [Int(up)]).suffix(State.historyLength))
                next.received += Int64(down * 250)
                next.sent += Int64(up * 250)
                self?.send(next, to: activity)
                self?.log.notice("demo tick \(tick, privacy: .public): \(Speed.text(down * 1000), privacy: .public)")
            }
        }
    }
    #endif
}
