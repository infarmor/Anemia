import AppKit
import Foundation
import SwiftUI
import LoaderCore
import LoaderShared

/// One stats-loop sample: per-second speeds at poll time. Powers the
/// session sparkline under the mini-map.
struct TrafficSample: Equatable {
    let down: Int64
    let up: Int64
}

extension AppState {
    /// ~7.5 minutes at the headless 5 s cadence, ~3 at the 2 s UI cadence.
    static let trafficHistoryCapacity = 90
}

@MainActor
final class AppState: ObservableObject {

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected          // xray up; `tunnelActive` says if system-wide
        case error(String)

        var isBusy: Bool { self == .connecting }
    }

    // Persisted
    @Published var servers: [ProxyServer] = []
    @Published var subscriptions: [Subscription] = []
    @Published var selectedServerID: UUID?
    @Published var anti: AntiCensorshipOptions = .recommended
    @Published var killSwitchEnabled = false
    @Published var maskingProfile: MaskingProfile = .balanced

    // Runtime
    @Published private(set) var connection: ConnectionState = .disconnected
    @Published private(set) var tunnelActive = false
    @Published private(set) var logLines: [String] = []
    /// Bumped on every appended line. `logLines.count` saturates at the cap
    /// (append one, drop one), so observing the count stops firing exactly
    /// when the log is busiest — the revision always changes.
    @Published private(set) var logRevision = 0
    @Published var lastImportError: String?

    // Live traffic (cumulative bytes + per-second speed) and session start.
    @Published private(set) var uplinkTotal: Int64 = 0
    @Published private(set) var downlinkTotal: Int64 = 0
    @Published private(set) var uplinkSpeed: Int64 = 0
    @Published private(set) var downlinkSpeed: Int64 = 0
    @Published private(set) var connectedSince: Date?
    /// Rolling window of per-poll traffic samples (speeds, bytes/sec) — the
    /// session's sparkline. Appended by the stats loop, capped at
    /// `trafficHistoryCapacity`, cleared on disconnect.
    @Published private(set) var trafficHistory: [TrafficSample] = []

    // Server pinging + ML ranking.
    @Published var pings: [UUID: PingResult] = [:]
    @Published var autoConnectOnLaunch = false
    @Published var mlRankingEnabled = true
    /// Coexist mode: point the macOS system SOCKS proxy at the engine while
    /// connected (SOCKS-only), so browsers route through Anemia's foreign exit
    /// alongside another whole-device VPN. Needs the privileged helper.
    @Published var systemProxyEnabled = false
    /// Refresh subscriptions automatically (shortly after launch, then every
    /// 6 hours) so rotating/expiring server lists stay current without the
    /// manual button.
    @Published var subscriptionAutoRefresh = true
    /// Split tunneling: destinations that bypass the VPN (raw lines, persisted).
    @Published private(set) var splitTunnel = SplitTunnelRules()
    /// Whether the app is registered as a login item. Mirrors the system's
    /// SMAppService state, not the app's last intent — an external change
    /// (System Settings → Login Items) shows up on the next launch.
    @Published private(set) var launchAtLogin = false
    /// Why the last launch-at-login toggle attempt failed (Settings UI).
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var kxcDevice = "—"
    @Published private(set) var isPinging = false
    /// Real latency measured through the live tunnel (health check).
    @Published private(set) var proxyLatency: Int?
    /// Measured tunnel capacity (bytes/sec) from a one-shot download probe after
    /// connecting — real speed, distinct from the live-usage speed counters.
    @Published private(set) var proxyThroughput: Int64?
    /// Whether the last health checks actually reached the internet through the
    /// proxy. Turns false after repeated failures so the UI can say "connected
    /// but no route" instead of claiming a working tunnel that isn't — the
    /// engine can be up and the SOCKS port open while the upstream server is
    /// unreachable (dead server, or a conflicting system TUN eating the dial).
    @Published private(set) var proxyReachable = true
    /// The session lost its physical network and is holding — tunnel and
    /// kill switch kept armed — until a link returns (see holdForNetwork).
    @Published private(set) var waitingForNetwork = false
    /// Whether the privileged helper is installed. When true, connecting brings
    /// up the full system-wide tunnel; when false, the app runs SOCKS-only.
    @Published private(set) var helperInstalled = false
    /// Why the system tunnel is down while the engine runs (SOCKS-only mode):
    /// the helper's error from the last connect. Surfaced in the UI so a
    /// failed tunnel reads as a failure, not as a silent "Connected".
    @Published private(set) var systemTunnelError: String?
    /// Whether the system resolver currently points at the tunnel gateway. While
    /// set, lookups are answered inside the engine via proxied DoH — poisoned
    /// answers from the ISP resolver become impossible. Cleared before the
    /// tunnel goes away, or name resolution machine-wide would die.
    @Published private(set) var systemDNSActive = false
    /// True while an install/uninstall admin prompt is in flight.
    @Published private(set) var helperBusy = false
    /// Whether the installed helper matches the app's expected version. A stale
    /// helper (older XPC contract) must be updated before coexist mode works.
    @Published private(set) var helperCurrent = false
    /// The installed helper's own version (nil when unreachable).
    @Published private(set) var helperVersion: String?
    /// Network settings a previous session left in a state that can't work —
    /// a resolver on a tunnel address nothing holds, a loopback proxy nothing
    /// serves. Both survive reboots; found by a user-level scan at launch and
    /// after each disconnect, and offered as a one-click repair.
    @Published private(set) var networkIssues: [NetworkHealthScan.Issue] = []
    /// A network repair (helper XPC or admin prompt) is running.
    @Published private(set) var repairInProgress = false
    /// What the last repair changed (Settings → Network safety).
    @Published private(set) var lastRepairReport: String?
    /// kxc's live verdict, recomputed after every ping round (and when the
    /// model loads or the ML toggle flips). `recommendedServerID` is the
    /// best reachable server; `rankPosition` orders them; `qualityScore` is
    /// kxc's raw badness score per server (lower is better).
    @Published private(set) var recommendedServerID: UUID?
    @Published private(set) var rankPosition: [UUID: Int] = [:]
    @Published private(set) var qualityScore: [UUID: Double] = [:]
    /// Per-server dependability in [0, 1] (loss/jitter/trend), used to prefer a
    /// steady server over a fast-but-flaky one in auto-selection.
    @Published private(set) var stability: [UUID: Double] = [:]
    private var pingHistory: [UUID: [Float]] = [:]
    private let historyStore = HistoryStore(maxSamples: 256)
    private let probesPerRound = 5   // TLS handshakes are heavier than a TCP connect
    /// Servers pinged concurrently per round. Each does `probesPerRound`
    /// sequential handshakes; enough parallelism to finish a big subscription
    /// briskly, few enough not to spike CPU or self-congest the uplink.
    private let pingConcurrency = 6
    private let ranker: ServerRanker = CoreMLRanker()
    var rankerBackend: String { ranker.backend }
    /// In-flight user-initiated connect/disconnect. A new user command
    /// cancels the previous one, so rapid toggles / double-taps can never
    /// interleave a start with a teardown (the classic "already running" race).
    /// Whether we currently have the system SOCKS proxy pointed at the engine
    /// (so teardown/quit knows to restore it).
    private var systemProxyActive = false
    private var connectionTask: Task<Void, Never>?
    /// In-flight auto-reconnect (cancelled by a manual connect/disconnect).
    private var reconnectTask: Task<Void, Never>?
    /// Post-connect health check (cancelled on teardown so a stale result
    /// can't land after disconnect).
    private var healthTask: Task<Void, Never>?

    private let persistence: StatePersistence
    private let xray: XrayController
    /// WireGuard-family engine plumbing (AmneziaWG + plain WireGuard): the
    /// root work lives in the helper, this only validates/builds/trackes.
    private let awg = AWGController()
    /// Hysteria-family engine plumbing: the client binary runs as the user
    /// and serves a local SOCKS bridge that xray routes through.
    private let hysteria = HysteriaController()
    private let helper = HelperClient()
    /// True while the LIVE session is a WireGuard-family one (engine =
    /// amneziawg-go via the helper, not xray). Drives the stats and health
    /// loops, which poll completely different sources per engine kind.
    private var activeSessionIsWG = false
    /// The server the live (or connecting) session dials. The selection can
    /// move while connected — the server list selects without reconnecting —
    /// so everything about the running session (removing its server, its
    /// subscription entry vanishing, learning its masking, measuring its
    /// direct path under the tunnel) keys off this, never off the selection:
    /// deleting a merely *selected* server used to take the live session
    /// down, and masking was learned for the wrong server.
    private(set) var sessionServerID: UUID?
    var sessionServer: ProxyServer? { sessionServerID.flatMap { id in allServers.first { $0.id == id } } }
    /// Physical-network change detection → full reconnect (see handleNetworkChange).
    private lazy var networkWatcher = NetworkWatcher { [weak self] in
        self?.handleNetworkChange()
    }
    private let maxLogLines = 500
    private var statsTask: Task<Void, Never>?
    /// How many UI surfaces currently show live traffic stats (main window,
    /// menu-bar window). Drives the stats-poll cadence: each sample forks the
    /// whole `xray api` subprocess, so headless polling runs 2.5× slower.
    private var statsViewers = 0

    /// Register/unregister a stats-displaying view (RootView is the only one —
    /// the menu-bar window polls via the fast path when it is visible).
    func statsViewOpened() { statsViewers += 1 }
    func statsViewClosed() { statsViewers = max(0, statsViewers - 1) }

    /// When the health monitor last decided the proxy is unreachable (nil
    /// while reachable). Feeds the tunnel watchdog's dead-time measurement.
    private var proxyUnreachableSince: Date?
    /// Tunnel watchdog: a background safety net forcing a reconnect when the
    /// proxy has been unreachable for too long (see startTunnelWatchdog).
    private var watchdogTask: Task<Void, Never>?
    /// Polls for the link to return while a session is held (holdForNetwork).
    private var networkHoldTask: Task<Void, Never>?
    /// Auto-refresh loop for subscriptions (cancelled when the setting flips
    /// off or the last subscription is removed).
    private var subscriptionRefreshTask: Task<Void, Never>?

    // Auto-reconnect bookkeeping.
    private var intentionalStop = false
    /// Serializes connect/disconnect commands: every entry point bumps this
    /// and passes its snapshot into teardown, so a superseded command (rapid
    /// off→on toggle, network-change reconnect) can neither kill the
    /// successor's freshly started engine nor clobber the connection state
    /// from under it. XPC wrappers don't respond to cancellation, so a
    /// cancelled disconnect runs to completion — the generation check is the
    /// only thing that makes its late landing harmless.
    private var commandGeneration = 0
    /// Bumped by every connect() immediately before its `startTunnel` XPC.
    /// A superseded connect's orphan cleanup must not `stopTunnel` once a
    /// successor has begun tunneling: the helper executes XPCs in arrival
    /// order, so a late cleanup stop landing after the successor's start
    /// would kill the successor's fresh tunnel. The epoch tells the orphan
    /// whether anyone else has taken over tunneling since it began.
    private var tunnelEpoch = 0
    private var reconnectAttempts = 0
    private let maxReconnects = 3
    /// Recovery ladder state (reset once a connection proves stable, or on a
    /// manual connect/disconnect).
    ///  * `recoveryTried` — servers already attempted this recovery episode, so
    ///    failover rotates rather than looping on one.
    ///  * `escalatedProfile` — a stronger masking profile forced during recovery
    ///    (overrides the learned/global one until the episode resolves).
    ///  * `activeProfile` — the masking profile the current connection is using,
    ///    recorded so a stable connection can be learned for the server.
    private var recoveryTried: Set<UUID> = []
    private var escalatedProfile: MaskingProfile?
    private var activeProfile: MaskingProfile = .balanced
    /// Masking profile learned to keep each server (by identityKey) flowing.
    private var learnedMasking: [String: MaskingProfile] = [:]

    init(
        persistence: StatePersistence = StatePersistence(fileURL: StatePersistence.defaultURL()),
        xray: XrayController = XrayController()
    ) {
        self.persistence = persistence
        self.xray = xray

        xray.onLog = { [weak self] line in
            Task { @MainActor in self?.appendLog(line) }
        }
        // The hysteria engine's own log lines (QUIC errors, blocked dials)
        // belong in the same log — they are the only way a broken server
        // shows its failure reason.
        hysteria.onLog = { [weak self] line in
            Task { @MainActor in self?.appendLog(line) }
        }
        xray.onExit = { [weak self] status in
            Task { @MainActor in self?.handleXrayExit(status) }
        }
        load()
        // Restore per-server ping history for the temporal ranker.
        for (k, v) in historyStore.load() {
            if let id = UUID(uuidString: k) { pingHistory[id] = v }
        }

        // Re-rank the instant kxc finishes loading, so the recommendation
        // upgrades from the heuristic fallback to the neural model on its own.
        if let cml = ranker as? CoreMLRanker {
            cml.notifyWhenReady { [weak self] in
                Task { @MainActor in await self?.updateRanking() }
            }
        }
        // Surface a recommendation immediately from persisted history (scored
        // by the heuristic until kxc is ready — then the hook above refreshes).
        Task { [weak self] in await self?.updateRanking() }

        // On launch: auto-connect AFTER the leftover sweep, not alongside it.
        // A cold helper daemon makes the sweep's XPC round-trips slow enough
        // to land AFTER a fast auto-connect finished — and tear down the
        // fresh tunnel it just brought up (plus undo the DNS pin it set).
        let launchCleanup: Task<Void, Never>? = HelperInstaller.isInstalled
            ? Task { [weak self] in
                guard let self else { return }
                // Every connect/disconnect issued from here on moves this.
                let launchGeneration = self.commandGeneration
                _ = await self.helper.clearSystemProxy()
                _ = await self.helper.clearSystemDNS()
                // Each destructive step re-checks that no command got
                // underway meanwhile: a user clicking Connect within the
                // sweep's first seconds (cold-helper XPCs are slow) would
                // otherwise see their fresh tunnel killed by the leftover
                // sweep meant for a session that predates the launch. An
                // `isConnected` check missed exactly that window — a connect
                // still `.connecting` has its startTunnel in flight.
                guard self.commandGeneration == launchGeneration, self.connection == .disconnected else { return }
                if await self.helper.isTunnelUp() == true {
                    guard self.commandGeneration == launchGeneration, self.connection == .disconnected else { return }
                    _ = await self.helper.stopTunnel()
                    self.appendLog("cleared leftover system tunnel from a previous session")
                }
                self.rescanNetworkHealth()
                if self.autoConnectOnLaunch, !self.allServers.isEmpty,
                   self.commandGeneration == launchGeneration {
                    self.requestConnectFastest()
                }
            }
            : nil
        if launchCleanup == nil, autoConnectOnLaunch, !allServers.isEmpty {
            requestConnectFastest()
        }
        // Detect where CoreML places kxc, for the settings display.
        Task { [weak self] in await self?.refreshKxcInfo() }
        // Reflect whether the system-wide tunnel helper is installed.
        refreshHelperStatus()
        // Leftovers that keep the network broken (from an earlier session or
        // an earlier install) are surfaced for a one-click repair. With the
        // helper installed the scan runs after its launch cleanup instead.
        if launchCleanup == nil { rescanNetworkHealth() }
        // Tear the tunnel down on quit so the Mac is never left offline.
        AppTermination.handler = { [weak self] in self?.shutdownForTermination() }
        // Clicking a vpn:// / hysteria:// / amnezia:// link anywhere in the
        // system lands here — same pipeline as pasting into the import sheet.
        AppURLOpen.handler = { [weak self] raw in self?.importLink(raw) }
        // Detect the real country so auto-pick avoids a same-country (useless)
        // exit — the locale seed is unreliable.
        Task { [weak self] in await self?.detectHomeCountry() }
        // (The leftover sweep itself lives in the launch task above: it clears
        // a system proxy/DNS/tunnel a previous — possibly crashed — session
        // left behind, so apps aren't pointed at a dead SOCKS port and the
        // machine isn't blackholed by routes to a dead bridge.)
        // Physical-network watcher: a Wi-Fi↔Ethernet swap or wake from sleep
        // leaves the engine's interface-pinned server socket on a dead link —
        // reconnect instead of silently carrying a dead tunnel.
        networkWatcher.start()
        // Safety net for a wedged recovery: see startTunnelWatchdog.
        startTunnelWatchdog()
        // Keep ping history (and with it ranking/stability) fresh without
        // user action: see startMaintenancePings.
        startMaintenancePings()
        // Keep subscriptions current on launch (auto-refresh loop).
        startSubscriptionAutoRefresh()
        // Reflect the system's login-item state (registered from a previous
        // install, possibly while this toggle was off).
        launchAtLogin = LoginItem.isEnabled
    }

    /// A meaningful change on the physical network. While a session is held
    /// for a lost network, a returning link resumes it. While connected, a
    /// lost link starts the hold; any other change is first revalidated
    /// through the live session with a fast probe — a path change that
    /// doesn't touch the pinned link (docking a USB NIC, a flap the debounce
    /// couldn't hide) doesn't warrant tearing down a working tunnel. When the
    /// probe fails, the session is rebuilt on the same server, fail-closed
    /// (see recoverSession).
    private func handleNetworkChange() {
        guard !intentionalStop else { return }
        if waitingForNetwork {
            if networkWatcher.isOnline { resumeAfterNetworkHold() }
            return
        }
        guard isConnected else { return }
        guard networkWatcher.isOnline else {
            holdForNetwork()
            return
        }
        appendLog("network changed — revalidating tunnel")
        connectionTask?.cancel()
        connectionTask = Task { [weak self] in
            guard let self else { return }
            // WireGuard roams on its own and has no SOCKS inbound to probe:
            // ask the helper whether the engine and its utun survived.
            let stillAlive = self.activeSessionIsWG
                ? await self.helper.isTunnelUp()
                : await ProxyHealth.check(socksPort: self.xray.socksPort, timeout: 2) != nil
            guard !Task.isCancelled, self.isConnected, !self.intentionalStop else { return }
            if stillAlive {
                self.appendLog("network changed — tunnel still healthy, keeping connection")
                return
            }
            self.appendLog("network changed — tunnel dead, reconnecting")
            self.recoverSession()
        }
    }

    /// Rebuild the live session on the same server after the link under it
    /// changed: not the recovery ladder (the server and its masking are fine —
    /// only the network moved), but fail-closed like it. This used to run a
    /// full disconnect + connect, which dropped the kill switch and the tunnel
    /// for the whole re-dial: on a network change — joining a public Wi-Fi,
    /// exactly when protection matters — traffic went out unprotected. With
    /// the kill switch on, the tunnel and its pf rules now stay armed while
    /// the engine restarts, and the reconnect re-arms them.
    private func recoverSession() {
        reconnectTask?.cancel()
        connection = .connecting
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            let gen = self.commandGeneration &+ 1
            self.commandGeneration = gen
            let keepTunnel = self.killSwitchEnabled && self.tunnelActive
            await self.teardown(gen: gen, keepTunnel: keepTunnel)
            guard !Task.isCancelled, !self.intentionalStop, self.commandGeneration == gen else { return }
            await self.connect(isReconnect: true)
        }
    }

    /// The physical network is gone (Wi-Fi dropped, cable out, airplane mode).
    /// Recovering now only burns the ladder: every retry fails, the masking
    /// escalates for nothing, failover walks the server list and changes the
    /// user's selection, and the terminal teardown drops the kill switch — so
    /// the link came back UNPROTECTED. Hold instead: keep the tunnel and its
    /// fail-closed pf armed (nothing can leak without a network anyway) and
    /// resume the moment a link is back.
    private func holdForNetwork() {
        guard !waitingForNetwork else { return }
        waitingForNetwork = true
        healthTask?.cancel()
        healthTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        connection = .connecting
        appendLog("network lost — holding the session until a link returns")
        // The path monitor's change callback is debounced and compares keys,
        // so a quick down→up flap can come back without ever firing it. Poll
        // the live link state too; whichever notices first resumes.
        networkHoldTask?.cancel()
        networkHoldTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.waitingForNetwork {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, self.waitingForNetwork, !self.intentionalStop else { return }
                if self.networkWatcher.isOnline {
                    self.resumeAfterNetworkHold()
                    return
                }
            }
        }
    }

    private func resumeAfterNetworkHold() {
        guard waitingForNetwork else { return }
        waitingForNetwork = false
        networkHoldTask?.cancel()
        networkHoldTask = nil
        appendLog("network back — resuming the session")
        recoverSession()
    }

    // MARK: - Derived

    var allServers: [ProxyServer] { servers + subscriptions.flatMap { $0.servers } }
    var selectedServer: ProxyServer? { allServers.first { $0.id == selectedServerID } }
    var isConnected: Bool { connection == .connected }

    // MARK: - Persistence

    private func load() {
        let state = persistence.load()
        servers = state.servers
        subscriptions = state.subscriptions
        selectedServerID = state.selectedServerID
        anti = state.anti
        killSwitchEnabled = state.killSwitchEnabled
        maskingProfile = state.maskingProfile
        autoConnectOnLaunch = state.autoConnectOnLaunch
        mlRankingEnabled = state.mlRankingEnabled
        systemProxyEnabled = state.systemProxyEnabled
        subscriptionAutoRefresh = state.subscriptionAutoRefresh
        splitTunnel = state.splitTunnel
        learnedMasking = state.learnedMasking.reduce(into: [:]) { acc, kv in
            if let p = MaskingProfile(rawValue: kv.value) { acc[kv.key] = p }
        }
    }

    func persist() {
        let state = PersistedState(
            servers: servers,
            subscriptions: subscriptions,
            selectedServerID: selectedServerID,
            anti: anti,
            killSwitchEnabled: killSwitchEnabled,
            maskingProfile: maskingProfile,
            autoConnectOnLaunch: autoConnectOnLaunch,
            mlRankingEnabled: mlRankingEnabled,
            systemProxyEnabled: systemProxyEnabled,
            subscriptionAutoRefresh: subscriptionAutoRefresh,
            learnedMasking: learnedMasking.mapValues { $0.rawValue },
            splitTunnel: splitTunnel
        )
        do { try persistence.save(state) }
        catch { appendLog("persist error: \(error.localizedDescription)") }
    }

    /// Toggle auto-refresh; starts/stops the loop immediately.
    func setSubscriptionAutoRefresh(_ on: Bool) {
        subscriptionAutoRefresh = on
        persist()
        startSubscriptionAutoRefresh()
    }

    /// Session for subscription fetches: a shared default-configuration URL
    /// session's 60 s request timeout lets one wedged mirror stall a whole
    /// auto-refresh round (and, worse, the user-facing refresh) for a minute.
    /// Bounded per-request/resource timeouts turn a dead mirror into a fast
    /// failure the round can move past.
    private static let subscriptionSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    /// Register/unregister the app as a login item. The toggle follows the
    /// system's resulting state, so a failed registration flips back.
    func setLaunchAtLogin(_ on: Bool) {
        if let err = LoginItem.setEnabled(on) {
            launchAtLoginError = err
            appendLog("launch at login: \(err)")
        } else {
            launchAtLoginError = nil
        }
        launchAtLogin = LoginItem.isEnabled
    }

    func setKillSwitch(_ on: Bool) {
        killSwitchEnabled = on
        persist()
    }

    /// Apply a masking preset, preserving the user's Advanced tweaks
    /// (fingerprint, mux, TFO) — overwriting them wholesale made the Settings
    /// toggles silently flip back on every profile switch.
    func setMaskingProfile(_ profile: MaskingProfile) {
        maskingProfile = profile
        let old = anti
        anti = profile.options
        anti.fingerprint = old.fingerprint
        anti.muxEnabled = old.muxEnabled
        anti.muxConcurrency = old.muxConcurrency
        anti.tcpFastOpen = old.tcpFastOpen
        persist()
        // Masking is baked into the engine config at connect time — a live
        // connection keeps running the previous profile. Log it so the
        // "why didn't this do anything" question has an answer in the log.
        if isConnected {
            appendLog("masking → \(profile.title): applies on next connect")
        }
    }

    func setFingerprint(_ fingerprint: String) {
        anti.fingerprint = fingerprint
        persist()
    }

    /// Split-tunnel edits apply at the next connect — the engine config and the
    /// helper's routes are built then — which is said out loud while connected.
    func setSplitTunnel(enabled: Bool? = nil, entries: [String]? = nil) {
        if let enabled { splitTunnel.enabled = enabled }
        if let entries { splitTunnel.entries = entries }
        persist()
        if isConnected || connection == .connecting {
            appendLog("split tunneling changed — applies on the next connect")
        }
    }

    // MARK: - Server management

    func select(_ id: UUID) {
        // Ignore taps for a server that no longer exists (the classic path:
        // a row's delete button also fires the row's own select gesture, so
        // the deleted id arrives here — see ServersSheet/MenuContentView).
        // Persisting a dangling id would leave the UI on "No server selected"
        // until the next app launch.
        guard allServers.contains(where: { $0.id == id }) else { return }
        selectedServerID = id
        persist()
    }

    /// One-tap: select this server and connect (switching if already connected).
    func quickConnect(_ id: UUID) {
        guard allServers.contains(where: { $0.id == id }) else { return }
        selectedServerID = id
        persist()
        connectionTask?.cancel()
        connectionTask = Task {
            if isConnected || connection == .connecting { await disconnect() }
            guard !Task.isCancelled else { return }
            await connect()
        }
    }

    func importLink(_ raw: String) {
        lastImportError = nil
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // A pasted wg-quick conf (Amnezia/wg-quick export) — multi-line by
        // definition, so it must be tried before the line-splitting paths.
        if trimmed.contains("[Interface]") || trimmed.contains("[Peer]") {
            do {
                let server = try ShareLinkParser.parseConfigText(trimmed)
                servers.append(server)
                if selectedServerID == nil { selectedServerID = server.id }
                persist()
            } catch {
                lastImportError = "\(error)"
            }
            return
        }

        // One recognizable link keeps the exact single-link path (precise
        // error message); everything else — a multi-line paste or a base64
        // subscription blob — goes through the subscription parser, which
        // skips bad lines instead of failing the whole import.
        if lines.count == 1, Self.isShareLink(trimmed) {
            do {
                let server = try ShareLinkParser.parse(trimmed)
                servers.append(server)
                if selectedServerID == nil { selectedServerID = server.id }
                persist()
            } catch {
                lastImportError = "\(error)"
            }
            return
        }

        let result = SubscriptionParser.parse(trimmed)
        guard !result.servers.isEmpty else {
            lastImportError = result.failures.first.map { "\($0.error)" } ?? "Nothing to import"
            return
        }
        servers.append(contentsOf: result.servers)
        if selectedServerID == nil { selectedServerID = result.servers[0].id }
        persist()
        if !result.failures.isEmpty {
            appendLog("imported \(result.servers.count) links, skipped \(result.failures.count) bad line(s)")
        }
    }

    private static func isShareLink(_ line: String) -> Bool {
        let l = line.lowercased()
        return l.hasPrefix("vless://") || l.hasPrefix("vmess://")
            || l.hasPrefix("ss://") || l.hasPrefix("trojan://")
            || l.hasPrefix("amnezia://") || l.hasPrefix("awg://")
            || l.hasPrefix("wireguard://") || l.hasPrefix("wg://")
            || l.hasPrefix("hysteria://") || l.hasPrefix("hysteria2://")
            || l.hasPrefix("hy2://") || l.hasPrefix("vpn://")
    }

    /// Share links currently on the clipboard, if any — powers the paste
    /// suggestion chip in the import sheet.
    func clipboardShareLinks() -> [String]? {
        guard let text = NSPasteboard.general.string(forType: .string) else { return nil }
        let links = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { Self.isShareLink($0) }
        return links.isEmpty ? nil : links
    }

    /// Text staged for the import sheet by drag & drop — ImportView picks it
    /// up in onAppear and clears it.
    @Published var pendingImportText: String?

    func removeServer(_ id: UUID) {
        // Deleting the server the engine is actually connected to used to
        // reassign the selection while the session kept running the deleted
        // exit — the UI then presented a different server as the live
        // tunnel. Bring the session down too: the list and reality must not
        // disagree.
        let wasLiveSession = (isConnected || connection == .connecting) && id == sessionServerID
        servers.removeAll { $0.id == id }
        if selectedServerID == id { selectedServerID = allServers.first?.id }
        pruneHistory()
        persist()
        if wasLiveSession {
            appendLog("removed the server this session was using — disconnecting")
            connectionTask?.cancel()
            connectionTask = Task { [weak self] in await self?.disconnect() }
        }
    }

    func addSubscription(name: String, url: String) async {
        var sub = Subscription(name: name.isEmpty ? url : name, url: url)
        // A failed fetch must not append an empty (server-less) subscription:
        // it would persist, re-error on every 6-hour auto-refresh, and stack
        // up one empty entry per retry. The error is already surfaced via
        // lastImportError — drop the candidate instead.
        guard await refresh(&sub) else { return }
        subscriptions.append(sub)
        if selectedServerID == nil { selectedServerID = sub.servers.first?.id }
        persist()
        startSubscriptionAutoRefresh()
    }

    func refreshSubscription(_ id: UUID) async {
        guard let idx = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        var sub = subscriptions[idx]
        guard await refresh(&sub) else { return }
        subscriptions[idx] = sub
        persist()
    }

    /// Auto-refresh engine: wakes shortly after launch (giving the network and
    /// an auto-connect a moment to settle), then every 6 hours. Reports only
    /// actual changes — a subscription whose server list didn't move stays
    /// silent, so the log stays readable.
    private func startSubscriptionAutoRefresh() {
        if let t = subscriptionRefreshTask, !t.isCancelled {
            // Still needed? The loop re-checks both conditions every cycle
            // and exits on its own when the answer flips — don't cancel a
            // half-done refresh round (the old behavior restarted from the
            // 10 s delay on every add/remove, discarding work in flight).
            if subscriptionAutoRefresh, !subscriptions.isEmpty { return }
            t.cancel()
        }
        guard subscriptionAutoRefresh, !subscriptions.isEmpty else { return }
        subscriptionRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            while let self, !Task.isCancelled, self.subscriptionAutoRefresh, !self.subscriptions.isEmpty {
                await self.refreshAllSubscriptions()
                try? await Task.sleep(nanoseconds: 6 * 3_600_000_000_000)
            }
        }
    }

    /// Refresh every subscription and log the deltas. Keeps the selection
    /// valid if its server vanished from the list.
    func refreshAllSubscriptions() async {
        for sub in subscriptions {
            let before = Set(sub.servers.map(\.identityKey))
            await refreshSubscription(sub.id)
            guard let updated = subscriptions.first(where: { $0.id == sub.id }) else { continue }
            let after = Set(updated.servers.map(\.identityKey))
            let added = after.subtracting(before).count
            let removed = before.subtracting(after).count
            if added > 0 || removed > 0 {
                appendLog("subscription '\(updated.name)' updated: +\(added) −\(removed) (now \(after.count) servers)")
            }
        }
        // The selected server may have disappeared from a refreshed list —
        // reselect the best available so the menu's Connect stays valid. If
        // the engine was running that vanished exit, the session must come
        // down with it: the exit may well have been revoked server-side, and
        // the UI must not present a different server as the live tunnel.
        if let sel = selectedServerID, !allServers.contains(where: { $0.id == sel }) {
            selectedServerID = allServers.first?.id
            persist()
            appendLog("selected server is gone — switched to \(selectedServer.map(\.name) ?? "none")")
        }
        if isConnected || connection == .connecting,
           let live = sessionServerID, !allServers.contains(where: { $0.id == live }) {
            appendLog("the live session's server vanished from its subscription — disconnecting")
            connectionTask?.cancel()
            connectionTask = Task { [weak self] in await self?.disconnect() }
        }
        // A refresh that renamed links mints new UUIDs; the old servers' ping
        // histories would otherwise linger in the persisted store forever
        // (pruneHistory is otherwise only invoked by explicit removals).
        pruneHistory()
    }

    /// Fetch and parse a subscription. Returns false on failure (the
    /// candidate's servers are left untouched).
    @discardableResult
    private func refresh(_ sub: inout Subscription) async -> Bool {
        lastImportError = nil
        guard let url = URL(string: sub.url) else {
            lastImportError = "Bad subscription URL"; return false
        }
        do {
            let (data, response) = try await Self.subscriptionSession.data(from: url)
            // URLSession throws only on transport failures: a 403 for an
            // expired token or a 502 from a restarting panel arrives as data.
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                lastImportError = "Fetch failed: HTTP \(http.statusCode)"
                return false
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            let result = SubscriptionParser.parse(body)
            // An error page, a captive portal or a body of unusable lines is a
            // failed fetch, not "the provider lists no servers now": storing
            // the empty result wiped the saved list — and the vanished-server
            // check then dropped the live session — on every provider outage.
            guard !result.servers.isEmpty else {
                lastImportError = result.failures.first.map { "Subscription has no usable servers (\($0.error))" }
                    ?? "Subscription has no usable servers"
                return false
            }
            // Carry stable IDs across refreshes (link text is the identity):
            // the selected server survives an update and ping history doesn't
            // orphan.
            sub.servers = SubscriptionParser.carryingIDs(from: sub.servers, into: result.servers)
            sub.lastUpdated = Date()
            if !result.failures.isEmpty {
                appendLog("subscription '\(sub.name)': \(result.failures.count) links skipped")
            }
            return true
        } catch {
            lastImportError = "Fetch failed: \(error.localizedDescription)"
            return false
        }
    }

    func removeSubscription(_ id: UUID) {
        // Same honesty rule as removeServer: deleting the subscription whose
        // server the engine is running must end that session, not silently
        // reassign the selection under it.
        let wasLiveSession = (isConnected || connection == .connecting)
            && subscriptions.first(where: { $0.id == id })?
                .servers.contains { $0.id == sessionServerID } == true
        subscriptions.removeAll { $0.id == id }
        if selectedServer == nil { selectedServerID = allServers.first?.id }
        pruneHistory()
        persist()
        startSubscriptionAutoRefresh()
        if wasLiveSession {
            appendLog("removed the subscription this session was using — disconnecting")
            connectionTask?.cancel()
            connectionTask = Task { [weak self] in await self?.disconnect() }
        }
    }

    /// Drop ping history for servers that no longer exist so the persisted
    /// store can't grow without bound and stale entries never leak back in.
    private func pruneHistory() {
        let live = Set(allServers.map { $0.id })
        pingHistory = pingHistory.filter { live.contains($0.key) }
        // Collect first, then delete: mutating a dictionary while iterating
        // its keys view is a runtime crash (invalidated indices).
        let gonePings = pings.keys.filter { !live.contains($0) }
        for gone in gonePings { pings[gone] = nil }
        rankPosition = rankPosition.filter { live.contains($0.key) }
        qualityScore = qualityScore.filter { live.contains($0.key) }
        stability = stability.filter { live.contains($0.key) }
        if let rec = recommendedServerID, !live.contains(rec) { recommendedServerID = nil }
        // Masking profiles learned for identities that no longer exist are
        // dead weight — prune them with everything else (nothing else ever
        // removed from this map, so it grew without bound across refreshes).
        let liveKeys = Set(allServers.map { $0.identityKey })
        let before = learnedMasking.count
        learnedMasking = learnedMasking.filter { liveKeys.contains($0.key) }
        if learnedMasking.count != before { persist() }
        saveHistory()
        // Re-derive the recommendation from what remains.
        Task { [weak self] in await self?.updateRanking() }
    }

    // MARK: - Ping & ML ranking

    func setAutoConnectOnLaunch(_ on: Bool) {
        autoConnectOnLaunch = on
        persist()
    }

    /// Ping every server (`probesPerRound` probes each) and record latency +
    /// features. TLS/Reality servers are timed with a full TLS handshake;
    /// `security: none` servers with a plain TCP connect (a handshake probe
    /// would always fail them and drop them from ranking).
    ///
    /// Concurrency is capped at `pingConcurrency`: launching every server at
    /// once (the old behavior) fired N simultaneous TLS handshake bursts —
    /// a CPU spike on the local machine *and* self-congestion that skewed
    /// the very RTTs being measured, so a large subscription ranked its
    /// servers by how badly it had just saturated its own uplink.
    func pingAll() async {
        let servers = allServers
        guard !servers.isEmpty else { return }
        // Re-entrancy guard: a user-initiated Ping racing connectFastest's
        // ping round interleaves history appends and skews jitter/loss.
        guard !isPinging else { return }
        isPinging = true
        await probeServers(servers, probes: probesPerRound, showMeasuring: true)
        isPinging = false
    }

    /// One ping round over `targets` — the worker-pool core shared by the
    /// user-initiated full round and the quiet background maintenance round.
    ///
    /// Concurrency is capped at `pingConcurrency`: launching every server at
    /// once (the old behavior) fired N simultaneous TLS handshake bursts —
    /// a CPU spike on the local machine *and* self-congestion that skewed
    /// the very RTTs being measured, so a large subscription ranked its
    /// servers by how badly it had just saturated its own uplink.
    private func probeServers(_ targets: [ProxyServer], probes: Int, showMeasuring: Bool) async {
        guard !targets.isEmpty else { return }
        if showMeasuring {
            // One publish, not one per server: `pings` is @Published, so the old
            // per-entry loop fired N objectWillChange events (N SwiftUI invalidations)
            // just to flip every badge to "measuring". Mutating a local copy and
            // assigning once coalesces them into a single render.
            var measuring = pings
            for s in targets { measuring[s.id] = .measuring }
            pings = measuring
        }
        let n = probes
        // While the system tunnel is up, probe packets follow its /1 routes:
        // client → current exit → server. Only the connected server, whose
        // address carries a bypass route, is still measured on its own path.
        // Tunneled RTTs are shown but never stored: they biased ranking toward
        // the connected server and fed kxc a double-hop series as if it were
        // the server's own.
        let tunneled = tunnelActive
        let directServer = sessionServerID
        await withTaskGroup(of: (UUID, PingResult, [Float]).self) { group in
            var pending = targets.makeIterator()
            func enqueueNext() {
                guard let s = pending.next() else { return }
                let host = s.address, port = s.port, id = s.id
                let useTLS = s.security != .none
                // Probe with the name the engine itself dials (`sni ?? host`):
                // for CDN/Reality entries the link address is an IP or fronting
                // host, and presenting that as SNI gets the handshake rejected
                // by the CDN — a working server would read "dead".
                let sni = s.sni ?? s.host
                group.addTask {
                    // Early-abort a dead server after 2 misses: five 4 s
                    // timeouts per down server is what made a ping round
                    // crawl on real (partially dead) subscriptions.
                    let samples = await LatencyProbe.sample(
                        host: host, port: port, sni: sni, count: n, timeout: 4,
                        tls: useTLS, earlyAbortAfterFails: 2)
                    // Raw series for history: success = RTT, failed = -1.
                    let raw = samples.map { $0.map(Float.init) ?? -1 }
                    let ok = samples.compactMap { $0 }
                    let result: PingResult = ok.isEmpty
                        ? .failed
                        : .ms(Int((Double(ok.reduce(0, +)) / Double(ok.count)).rounded()))
                    return (id, result, raw)
                }
            }
            for _ in targets.prefix(pingConcurrency) { enqueueNext() }
            for await (id, result, raw) in group {
                // A cancelled round (view closed, user moved on) must stop
                // burning its budget: cancel the in-flight children — the
                // probe loop checks cancellation per sample and winds down.
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                pings[id] = result
                if !tunneled || id == directServer {
                    var h = pingHistory[id] ?? []
                    h.append(contentsOf: raw)
                    if h.count > 256 { h.removeFirst(h.count - 256) }
                    pingHistory[id] = h
                }
                enqueueNext()   // worker-pool: refill as results come in
            }
        }
        // A cancelled round (superseded by a connect) broke out mid-loop —
        // the servers it never reached stay stuck at .measuring forever
        // without this, reading as a ping round that never ends.
        if Task.isCancelled {
            for s in targets where pings[s.id] == .measuring { pings[s.id] = nil }
        }
        saveHistory()
        await updateRanking()
    }

    // MARK: - Background ping maintenance

    /// Background ping maintenance — keeps the ranking data alive without
    /// user action. The selected and recommended servers are probed every
    /// 3 minutes (3 probes): they are what the auto-selection and the
    /// stability bar read, so a server drifting upward (or starting to
    /// drop packets) must pull the recommendation *now*, not an hour from
    /// now. The rest of the list decays on a rare full sweep (every ~30 min,
    /// 2 probes) — enough that long-idle servers' histories don't go stale,
    /// far below the cadence that would burn battery or skew the link.
    /// Skipped entirely while a user-initiated round is running.
    private var maintenancePingTask: Task<Void, Never>?
    private var maintenanceRoundCounter = 0

    private func startMaintenancePings() {
        maintenancePingTask?.cancel()
        maintenancePingTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 180_000_000_000)
                guard !Task.isCancelled else { return }
                guard !self.isPinging else { continue }   // user round owns the link right now
                await self.maintenancePingRound()
            }
        }
    }

    private func maintenancePingRound() async {
        // Claim the same gate the user round uses: without it a user tap
        // (Ping / Connect-fastest) during the 30-minute sweep started a
        // second 6-handshake pool on the same uplink — the self-congestion
        // the pingConcurrency cap exists to prevent, skewing both rounds'
        // RTTs. Set + clear here makes isPinging cover BOTH round kinds, so
        // each side's guard defers to whoever started first.
        guard !isPinging else { return }
        isPinging = true
        defer { isPinging = false }
        // Under the system tunnel only the connected server is measured on its
        // own path (see probeServers): probing the rest would spend handshakes
        // on numbers that are never stored. The sweep waits for the tunnel to
        // come down.
        if tunnelActive {
            if let live = sessionServer { await probeServers([live], probes: 3, showMeasuring: false) }
            return
        }
        var targets: [ProxyServer] = []
        if let sel = selectedServer { targets.append(sel) }
        if let rec = recommendedServer, rec.id != selectedServerID { targets.append(rec) }

        maintenanceRoundCounter += 1
        if maintenanceRoundCounter >= 10 {
            // The rare sweep: everyone (maintenance targets included, at the
            // sweep's lighter probe count) so no history goes stale.
            maintenanceRoundCounter = 0
            await probeServers(allServers, probes: 2, showMeasuring: false)
        } else {
            await probeServers(targets, probes: 3, showMeasuring: false)
        }
    }

    /// History save throttle. Ping rounds now land on their own schedule —
    /// the user's rounds plus a background maintenance round every 3 minutes —
    /// and each save JSON-encodes every server's 256-sample series. Coalesce
    /// the churn: mark dirty and write at most once per minute (the first
    /// round after a gap writes immediately), then force a synchronous flush
    /// on disconnect and app termination so the file never trails a session
    /// event behind.
    private var historyDirty = false
    private var historyFlushScheduled = false
    private var lastHistorySave = Date.distantPast

    private func saveHistory(force: Bool = false) {
        historyDirty = true
        guard !force else { flushHistorySync(); return }
        let since = Date().timeIntervalSince(lastHistorySave)
        guard since < 60 else { flushHistorySync(); return }
        guard !historyFlushScheduled else { return }
        historyFlushScheduled = true
        let delay = UInt64(max(1, 60 - since) * 1_000_000_000)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self else { return }
            self.historyFlushScheduled = false
            self.flushHistory()
        }
    }

    /// Ordinary flush: encode off the main actor so a big history doesn't
    /// stall the UI; the store write itself is one small atomic file write.
    private func flushHistory() {
        guard historyDirty else { return }
        historyDirty = false
        lastHistorySave = Date()
        var dict: [String: [Float]] = [:]
        for (id, v) in pingHistory { dict[id.uuidString] = v }
        let store = historyStore
        Task.detached(priority: .utility) { store.save(dict) }
    }

    /// Synchronous flush for teardown/quit paths — a detached write can't be
    /// relied on once the process is exiting.
    private func flushHistorySync() {
        historyDirty = false
        historyFlushScheduled = false
        lastHistorySave = Date()
        var dict: [String: [Float]] = [:]
        for (id, v) in pingHistory { dict[id.uuidString] = v }
        historyStore.save(dict)
    }

    /// Coarse quality tier from kxc's badness score — reflects jitter, loss and
    /// a rising-latency trend, not just raw latency, so it can differ from the
    /// ping badge. `nil` until the server has been ranked.
    enum Quality: String { case excellent = "Excellent", good = "Good", fair = "Fair", poor = "Poor" }

    func qualityTier(_ id: UUID) -> Quality? {
        guard let s = qualityScore[id] else { return nil }
        // Calibrated for the kxc badness score over TLS-handshake latency (a full
        // round-trip, plus jitter/loss penalties): higher than a raw ICMP ping.
        switch s {
        case ..<120: return .excellent
        case ..<260: return .good
        case ..<450: return .fair
        default:     return .poor
        }
    }

    var recommendedServer: ProxyServer? { allServers.first { $0.id == recommendedServerID } }

    /// The user's REAL country (e.g. "RU"). The locale region is unreliable (it
    /// can be set to anywhere — this user's Mac reads "GR" while sitting in RU),
    /// so it's only the seed: `detectHomeCountry()` refines it by geolocating the
    /// physical-interface IP, bypassing any system TUN. A server exiting here
    /// can't bypass local censorship, so it's never the automatic pick.
    @Published private(set) var homeCountry: String? = Locale.current.region?.identifier

    /// ISO country code encoded in a server name's flag emoji (🇷🇺 → "RU"), or nil.
    func serverCountry(_ name: String) -> String? {
        let flags = name.unicodeScalars.filter { (0x1F1E6...0x1F1FF).contains($0.value) }
        guard flags.count >= 2 else { return nil }
        let letters = flags.prefix(2).compactMap { UnicodeScalar($0.value - 0x1F1E6 + 0x41).map(Character.init) }
        return letters.count == 2 ? String(letters) : nil
    }

    /// Whether this server's exit is outside the user's country (i.e. useful for
    /// circumvention). Unknown country → treated as usable, never hidden.
    func isForeignExit(_ id: UUID) -> Bool {
        guard let home = homeCountry,
              let name = allServers.first(where: { $0.id == id })?.name,
              let cc = serverCountry(name) else { return true }
        return cc.uppercased() != home.uppercased()
    }

    /// Whether this server exits inside Russia. Such a server can't bypass
    /// Russian censorship — it lands right back inside the same blocks — so the
    /// automatic picker excludes it outright, independently of the detected home
    /// country (which, behind a foreign VPN, may read as somewhere else).
    /// Manual selection is never restricted.
    func isRussianExit(_ id: UUID) -> Bool {
        guard let name = allServers.first(where: { $0.id == id })?.name,
              let cc = serverCountry(name) else { return false }
        return cc.uppercased() == "RU"
    }

    /// Detect the user's real country by geolocating the physical-interface IP
    /// (bypasses any system TUN, so it reports the true ISP location, not a
    /// proxy's exit). Refines `homeCountry` and re-ranks so auto-connect avoids a
    /// same-country exit. Best-effort: on failure the locale seed stands.
    func detectHomeCountry() async {
        guard let cc = await Self.geoCountryViaPhysicalInterface(), !cc.isEmpty else { return }
        guard cc.uppercased() != (homeCountry ?? "").uppercased() else { return }
        homeCountry = cc.uppercased()
        appendLog("home country detected: \(cc.uppercased()) — excluding same-country exits from auto-pick")
        await updateRanking()
    }

    nonisolated private static func geoCountryViaPhysicalInterface() async -> String? {
        guard let phys = PhysicalInterface.primary() else { return nil }
        return await Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            // HTTPS to Cloudflare (already our DoH provider) over the physical
            // NIC; returns a line "loc=RU". Bounded so it can't hang startup.
            p.arguments = ["--interface", phys, "-s", "--max-time", "5",
                           "https://www.cloudflare.com/cdn-cgi/trace"]
            let out = Pipe()
            let err = Pipe()
            err.fileHandleForReading.readabilityHandler = { h in h.readabilityHandler = nil }  // drain & drop
            p.standardOutput = out
            p.standardError = err
            do { try p.run() } catch { return nil }
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            out.fileHandleForReading.closeFile()
            for line in text.split(separator: "\n") where line.hasPrefix("loc=") {
                return String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            }
            return nil
        }.value
    }

    /// Score every reachable server and publish kxc's verdict (recommendation,
    /// rank order, per-server score). Runs after each ping round, when the model
    /// finishes loading, and when the ML toggle flips. Scoring runs concurrently
    /// off the main actor — ANE inference never blocks the UI or the tunnel path.
    func updateRanking() async {
        let mlEnabled = mlRankingEnabled
        let ranker = self.ranker
        let entries: [(id: UUID, features: ServerFeatures)] = allServers.compactMap { s in
            guard let h = pingHistory[s.id], h.contains(where: { $0 >= 0 }) else { return nil }
            return (s.id, ServerFeatures(history: h))
        }
        guard !entries.isEmpty else {
            recommendedServerID = nil; rankPosition = [:]; qualityScore = [:]; stability = [:]
            return
        }
        let scored: [(id: UUID, score: Double)] = await withTaskGroup(of: (Int, Double).self) { group in
            for (i, entry) in entries.enumerated() {
                group.addTask {
                    let score = mlEnabled
                        ? await ranker.score(entry.features)
                        : averagePingScore(entry.features.history)
                    return (i, score)
                }
            }
            var byIndex = [Int: Double](minimumCapacity: entries.count)
            for await (i, score) in group { byIndex[i] = score }
            return entries.enumerated().map {
                (id: $0.element.id, score: byIndex[$0.offset] ?? .greatestFiniteMagnitude)
            }
        }
        let ordered = scored.sorted { $0.score < $1.score }
        var pos: [UUID: Int] = [:]
        var q: [UUID: Double] = [:]
        for (idx, e) in ordered.enumerated() { pos[e.id] = idx; q[e.id] = e.score }
        rankPosition = pos
        qualityScore = q
        // Dependability, straight from each server's recent history (loss,
        // jitter, upward drift) — orthogonal to the badness score, which is
        // dominated by latency.
        var stab: [UUID: Double] = [:]
        for e in entries { stab[e.id] = stabilityScore(e.features) }
        stability = stab

        recommendedServerID = pickRecommended(ordered: ordered, stability: stab,
                                              current: recommendedServerID)
        // If the user hasn't chosen a server yet, adopt the model's pick so the
        // app is ready to connect to the best option out of the box.
        if selectedServerID == nil, let best = recommendedServerID {
            selectedServerID = best
            persist()
        }
    }

    /// Auto-selection policy: the most stable *and* best foreign, non-Russian
    /// exit. Reasoning, in order:
    ///   1. Never a Russian exit — it can't bypass Russian censorship.
    ///   2. Prefer a foreign exit over a same-country one (a home-country exit
    ///      lands back inside the local blocks). Unknown-country servers count
    ///      as foreign, so a bare-IP link is never hidden.
    ///   3. Among the eligible pool, prefer servers that clear a stability bar
    ///      (steady latency, few losses) and, within those, take the best-ranked
    ///      (lowest badness). A fast server that stalls is worse for real use
    ///      than a slightly slower one that never wobbles.
    ///   4. If nothing clears the bar, fall back to the best eligible server;
    ///      if the pool is empty (e.g. every server is Russian), the overall
    ///      best, so the app always has *some* pick.
    /// `ordered` is sorted best-first, so `.first` on any filtered slice is the
    /// best-ranked member of it.
    ///   5. Hysteresis: once a server is recommended, keep it while it stays
    ///      eligible and within a small margin of the challenger's score, so the
    ///      badge doesn't flap between near-ties on each ping round.
    private func pickRecommended(ordered: [(id: UUID, score: Double)],
                                 stability: [UUID: Double],
                                 current: UUID?) -> UUID? {
        let stableBar = 0.6
        let nonRussian = ordered.filter { !isRussianExit($0.id) }
        let foreign = nonRussian.filter { isForeignExit($0.id) }
        let pool = foreign.isEmpty ? nonRussian : foreign
        let steady = pool.filter { (stability[$0.id] ?? 0) >= stableBar }
        guard let challenger = steady.first ?? pool.first ?? ordered.first else { return nil }
        // Stick with the current pick if it's still eligible and no worse than
        // 12% (badness) behind the challenger — avoids churn on tiny wobbles.
        if let current, let cur = pool.first(where: { $0.id == current }),
           cur.score <= challenger.score * 1.12 {
            return current
        }
        return challenger.id
    }

    // MARK: - kxc (ML ranker) info

    var kxcName: String { CoreMLRanker.name }
    var kxcLoaded: Bool { (ranker as? CoreMLRanker)?.isLoaded ?? false }

    func setMLRanking(_ on: Bool) {
        mlRankingEnabled = on
        persist()
        // Re-rank immediately so the recommendation reflects the chosen scorer.
        Task { [weak self] in await self?.updateRanking() }
    }

    /// Query where CoreML actually places kxc (Neural Engine / GPU / CPU).
    func refreshKxcInfo() async {
        guard let r = ranker as? CoreMLRanker, let dev = await r.detectComputeDevice() else { return }
        kxcDevice = dev
    }

    // MARK: - Privileged helper (system-wide tunnel)

    func refreshHelperStatus() {
        helperInstalled = HelperInstaller.isInstalled
        Task { [weak self] in
            guard let self else { return }
            let version = await self.helper.version()
            self.helperVersion = version
            self.helperCurrent = version == LoaderHelperVersion
        }
    }

    /// Toggle coexist mode. Applies live: if connected in SOCKS-only mode, set
    /// or clear the system proxy immediately.
    func setSystemProxyEnabled(_ on: Bool) {
        systemProxyEnabled = on
        persist()
        guard isConnected, !tunnelActive, helperInstalled else { return }
        Task { [weak self] in
            guard let self else { return }
            if on {
                let r = await self.helper.setSystemProxy(port: self.xray.socksPort)
                // The XPC round-trip can straddle a disconnect (whose teardown
                // ran before the set landed) or a second toggle of this
                // setting. Commit the flag only if the world still matches;
                // otherwise compensate so the helper's override doesn't
                // outlive the session it was for.
                guard self.isConnected, !self.tunnelActive, self.systemProxyEnabled else {
                    if r.ok, !self.systemProxyActive { _ = await self.helper.clearSystemProxy() }
                    return
                }
                self.systemProxyActive = r.ok
            } else if self.systemProxyActive {
                _ = await self.helper.clearSystemProxy()
                self.systemProxyActive = false
            }
        }
    }

    /// Synchronous teardown for app termination (called from the AppDelegate).
    /// Stops the engine and, if the system tunnel is up, tells the helper to
    /// remove its routes + kill switch — so quitting the app ALWAYS restores
    /// connectivity, even if the tunnel was in a broken state. Without this,
    /// force-quitting while tunneled leaves the machine offline with no app to
    /// recover it.
    func shutdownForTermination() {
        intentionalStop = true
        // Kill the in-flight connect/reconnect work FIRST and move the
        // generation, so any of their XPC calls still straddling the quit
        // bail at their post-await guards instead of committing state over
        // the restores below (or re-arming routes after stopTunnelBlocking
        // returned).
        commandGeneration = commandGeneration &+ 1
        connectionTask?.cancel()
        connectionTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        healthTask?.cancel()
        statsTask?.cancel()
        watchdogTask?.cancel()
        networkHoldTask?.cancel()
        maintenancePingTask?.cancel()
        awg.endSession()
        hysteria.stop()
        flushHistorySync()
        xray.stop()
        // Restore unconditionally, not per flag: an XPC timeout (20 s) leaves
        // the flag false while the helper may still have applied the change,
        // so a flag-gated shutdown could leave routes/kill switch/resolver
        // armed against a dead app — i.e. the machine offline with nobody
        // left to recover it. The helper side is idempotent (tears down only
        // what exists; restores only what it backed up), so over-calling is
        // safe. DNS before proxy before tunnel — resolution first.
        //
        // These run over the CACHED helper connection, not the per-call
        // connections the *Blocking(static) variants open: per-connection
        // XPC ordering is FIFO, so a connect's setSystemDNS already sent on
        // this connection is processed by the helper BEFORE the quit's
        // clear — cross-connection order is unspecified and used to let the
        // late set re-pin the resolver after the restore landed.
        helper.clearSystemDNSOnConnectionBlocking()
        helper.clearSystemProxyOnConnectionBlocking()
        helper.stopTunnelOnConnectionBlocking()
    }

    /// Install the helper via a single admin prompt, then (if currently
    /// connected in SOCKS-only mode) reconnect so the system tunnel comes up.
    /// Returns a user-facing error, or nil on success/cancel.
    func installHelper() async -> String? {
        guard !helperBusy else { return nil }
        helperBusy = true
        defer { helperBusy = false }
        do {
            try await Task.detached(priority: .userInitiated) { try HelperInstaller.install() }.value
            refreshHelperStatus()
            appendLog("privileged helper installed — system-wide tunnel enabled")
            // Promote an active SOCKS-only session to the full tunnel.
            if isConnected, !tunnelActive {
                connectionTask?.cancel()
                connectionTask = Task { await disconnect(); await connect() }
            }
            return nil
        } catch let e as HelperInstaller.InstallError {
            if case .cancelled = e { return nil }
            appendLog("helper install failed: \(e.localizedDescription)")
            return e.localizedDescription
        } catch {
            appendLog("helper install failed: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    func uninstallHelper() async -> String? {
        guard !helperBusy else { return nil }
        helperBusy = true
        defer { helperBusy = false }
        // Any live session must come down first — uninstalling while
        // connected in SOCKS-only mode (systemProxyActive, no tunnel) would
        // boot the helper out with the system proxy still pointing at the
        // engine, and disconnecting later would have no helper to restore it.
        if tunnelActive || systemProxyActive || systemDNSActive || isConnected {
            await disconnect()
        }
        do {
            try await Task.detached(priority: .userInitiated) { try HelperInstaller.uninstall() }.value
            refreshHelperStatus()
            appendLog("privileged helper removed")
            return nil
        } catch let e as HelperInstaller.InstallError {
            if case .cancelled = e { return nil }
            return e.localizedDescription
        } catch {
            return error.localizedDescription
        }
    }

    /// Tracked wrapper: routes "connect fastest" through the serialized
    /// connection task so it cancels/competes correctly with manual toggles.
    func requestConnectFastest() {
        connectionTask?.cancel()
        connectionTask = Task { await connectFastest() }
    }

    /// Ping everything, then select and connect the best-ranked server.
    func connectFastest() async {
        await pingAll()   // refreshes `recommendedServerID` at the end
        guard !Task.isCancelled else { return }
        guard let bestID = recommendedServerID,
              let best = allServers.first(where: { $0.id == bestID }) else {
            appendLog("no reachable servers to auto-connect")
            return
        }
        guard !Task.isCancelled else { return }
        appendLog("fastest: \(best.name) (\(rankerBackend))")
        selectedServerID = best.id
        persist()
        await connect()
    }

    // MARK: - Connect / disconnect

    func toggleConnection() {
        connectionTask?.cancel()
        switch connection {
        case .connected, .error, .connecting:
            // `.connecting` toggles to cancel an in-flight connect/reconnect.
            connectionTask = Task { await disconnect() }
        case .disconnected:
            connectionTask = Task { await connect() }
        }
    }

    /// Switch-driven connect (RootView top bar). From an error state the switch
    /// reads OFF, so turning it ON must clean up the failed session first and
    /// reconnect — not hit toggleConnection's error→disconnect path.
    func setConnected(_ on: Bool) {
        connectionTask?.cancel()
        var needsCleanup = !on
        if case .error = connection { needsCleanup = true }
        connectionTask = Task {
            if needsCleanup { await disconnect() }
            if on, !Task.isCancelled { await connect() }
        }
    }

    /// Stop the hysteria bridge run `token` identifies, if this connect task
    /// actually got one up before failing. Token-guarded (see
    /// HysteriaController.stop(ifRunning:)): a successor's fresh run is never
    /// touched, and a nil token (WG/xray sessions, or the bridge never came
    /// up) is a no-op.
    private func stopHyEngine(ifNeeded token: UUID?) {
        guard let token else { return }
        hysteria.stop(ifRunning: token)
    }

    func connect(isReconnect: Bool = false) async {
        let gen = commandGeneration &+ 1
        commandGeneration = gen
        guard let server = selectedServer else {
            connection = .error("No server selected"); return
        }
        if !isReconnect {
            // A fresh manual connect supersedes any in-flight auto-reconnect.
            reconnectTask?.cancel()
            reconnectTask = nil
            intentionalStop = false
            resetRecoveryState()
            // A connect issued while a previous session is still up (the
            // "Fastest" button, or connectFastest after an auto-pick) must
            // take that session FULLY down first. The engine restart below
            // alone leaves the old tunnel armed — with the system resolver
            // pinned to a gateway whose engine just changed port, i.e. a
            // machine-wide DNS outage (a full blackhole under the kill
            // switch) until the successor's startTunnel lands. Full teardown
            // first: same contract as the toggle's disconnect→connect path.
            if tunnelActive || systemDNSActive || systemProxyActive {
                await teardown(gen: gen)
                // teardown contains multiple XPC await points; a successor
                // command may have bumped the generation while we were inside.
                guard !Task.isCancelled, commandGeneration == gen else { return }
            }
        }
        // Masking for this attempt: a recovery escalation wins; else the profile
        // learned to keep THIS server flowing; else the user's global setting.
        let (maskOpts, profile) = maskingForConnect(server)
        activeProfile = profile
        let bypassEntries = splitTunnel.activeEntries
        xray.bypass = bypassEntries
        sessionServerID = server.id
        connection = .connecting
        // The bundled engine (Xray-core 26.x) validates certificates
        // unconditionally — links carrying allowInsecure=1 used to fail
        // silently (TLS error, opaque reconnect loop). Say it out loud
        // instead of blocking: panels often set the flag gratuitously while
        // the cert is perfectly valid.
        if server.allowInsecure {
            appendLog("note: '\(server.name)' asks to skip cert validation (allowInsecure); the bundled engine ignores that — if this server uses a self-signed cert, the connection will fail")
        }
        // Identity of the engine run THIS task spawns — the supersede check
        // below tears it down only while it is still ours.
        var engineRun: UUID?
        // WireGuard-family servers run on the amneziawg-go engine through the
        // helper (xray cannot speak the obfuscated handshake). The whole
        // masking/fragment machinery below is xray-specific and inert here.
        let isWG = server.proto.isWireGuardFamily
        // Hysteria-family: the client binary runs user-side, serves a local
        // SOCKS bridge, and xray routes through it like any proxy.
        let isHy = server.proto.isHysteriaFamily
        // The live hysteria run's token — the supersede sweep below stops
        // exactly this run, never a successor's.
        var hyRun: UUID?
        // Local start closure so the busy-retry loop below can re-run either
        // engine's start without duplicating its branches.
        let startEngine: () async throws -> Void = {
            if isWG {
                if self.awg.isSessionUp { self.awg.endSession() }
                try self.awg.validate(server: server)
                _ = try self.awg.makeConfigScript(server: server)   // fail before the helper spawns anything
                return
            }
            if isHy {
                if self.hysteria.isRunning { self.hysteria.stop() }
                let port = try await self.hysteria.start(server: server)
                hyRun = self.hysteria.runToken
                // Route xray through the bridge; the endpoint stays the real
                // hysteria server, so display/bypass logic keeps pointing at
                // the right host. userData carries the bridge port into the
                // config builder (its socks outbound target).
                var routed = server
                routed.userData = (server.userData ?? [:]).merging(["hySocksPort": String(port)]) { _, new in new }
                if self.xray.isRunning { self.xray.stop() }
                try await self.xray.start(server: routed, anti: maskOpts)
                return
            }
            // Belt and braces: a stale hysteria bridge (e.g. left over from an
            // aborted hy connect) must not survive into a non-hy session.
            if self.hysteria.isRunning { self.hysteria.stop() }
            if self.xray.isRunning { self.xray.stop() }
            try await self.xray.start(server: server, anti: maskOpts)
        }
        do {
            // Reclaim an engine orphaned by a superseded connect: start() refuses
            // to launch over a live one, and the task that spawned it has long
            // bailed — without this, every later connect dies on
            // `.alreadyRunning` until the app restarts. (A *concurrent* start
            // — still between its guards — is protected by the `starting` flag
            // inside start() and is not touched here.)
            try await startEngine()
            if !isWG { engineRun = xray.runToken }
        } catch XrayError.cancelled {
            stopHyEngine(ifNeeded: hyRun)   // superseded — it owns the state now
            return
        } catch XrayError.alreadyRunning {
            // Another start is mid-flight (its `starting` guard tripped). It
            // resolves in bounded time (DNS race ≤3 s, readiness ≤5 s), so
            // poll-retry instead of yielding: the other task is by
            // construction superseded — every entry point cancels the
            // previous connection task — and a yielded task used to strand
            // the state at `.connecting` forever when that superseded start
            // aborted itself instead of finishing and owning the state.
            var started = false
            for _ in 0..<30 {   // ≤ 15 s at 500 ms
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, commandGeneration == gen else {
                    stopHyEngine(ifNeeded: hyRun)   // hysteria may be up from a prior iteration
                    return
                }
                do {
                    try await startEngine()
                    if !isWG { engineRun = xray.runToken }
                    started = true
                    break
                } catch XrayError.alreadyRunning { continue }
                catch XrayError.cancelled { stopHyEngine(ifNeeded: hyRun); return }
                catch {
                    guard !Task.isCancelled, commandGeneration == gen else { return }
                    stopHyEngine(ifNeeded: hyRun)
                    if isReconnect {
                        appendLog("start failed (\(server.name)): \(error.localizedDescription)")
                        attemptReconnect()
                    } else {
                        connection = .error(error.localizedDescription)
                    }
                    return
                }
            }
            guard started else {
                guard commandGeneration == gen else { return }
                stopHyEngine(ifNeeded: hyRun)
                appendLog("engine start stayed busy — giving up")
                connection = .error("Engine start did not finish — try connecting again")
                return
            }
        } catch {
            // A cancelled/superseded task must not clobber the successor's
            // state: it may have already set .connecting/.connected while this
            // catch was unwinding.
            guard !Task.isCancelled, commandGeneration == gen else { return }
            // In the hysteria family the bridge client is up before xray is
            // asked to start — a throw below that point used to strand the
            // bridge process (live QUIC session + bound port) until the next
            // hy connect or a manual disconnect, and nothing in a later
            // non-hy connect would reap it. Token-guarded, so it can never
            // touch a successor's fresh run.
            stopHyEngine(ifNeeded: hyRun)
            // Mid-recovery a failed start is just the next rung of the ladder
            // (climb masking / fail over), not a dead stop.
            if isReconnect {
                appendLog("start failed (\(server.name)): \(error.localizedDescription)")
                attemptReconnect()
            } else {
                connection = .error(error.localizedDescription)
            }
            return
        }

        // Bring up the system-wide tunnel via the privileged helper. If the
        // helper isn't installed yet, we stay "connected" in SOCKS-only mode so
        // the user can still test the proxy at 127.0.0.1:<socksPort>.
        // (WireGuard-family: SOCKS-only is meaningless — the engine has no
        // local inbound to test — so a helper failure is a hard failure there.)
        tunnelEpoch &+= 1
        let tunEpoch = tunnelEpoch
        let (ok, err): (Bool, String?)
        if isWG {
            guard helperInstalled else {
                guard !Task.isCancelled, commandGeneration == gen else { return }
                connection = .error("WireGuard-family servers need the privileged helper — install it in Settings")
                return
            }
            guard let enginePath = AWGController.resolveBinary() else {
                guard !Task.isCancelled, commandGeneration == gen else { return }
                let missing: AWGController.AWGError = AWGController.isBundled ? .engineNotInstalled : .binaryNotFound
                connection = .error(missing.localizedDescription)
                return
            }
            appendLog("AmneziaWG \(server.awgVersion.rawValue) profile → \(server.address):\(server.port)")
            for warning in AmneziaWGConfigBuilder.warnings(server: server) {
                appendLog("AmneziaWG: \(warning)")
            }
            // The engine takes `endpoint=` as an address literal only — a
            // domain fails the whole UAPI set — so a domain endpoint is
            // resolved here. The helper pins its bypass route to exactly that
            // address, so the engine's own dial can't follow the tunnel's
            // routes back into the utun.
            guard let endpoint = await awg.resolveEndpoint(server.address) else {
                guard !Task.isCancelled, commandGeneration == gen else { return }
                let message = "Could not resolve the server address \(server.address)"
                if isReconnect {
                    appendLog("\(message) — recovering")
                    attemptReconnect()
                } else {
                    connection = .error(message)
                }
                return
            }
            // The lookup suspended: a command issued meanwhile owns the helper
            // now, and a start sent after its own would replace its tunnel.
            guard !Task.isCancelled, !intentionalStop, commandGeneration == gen else { return }
            let script: String
            do { script = try awg.makeConfigScript(server: server, endpoint: endpoint) } catch {
                connection = .error(error.localizedDescription)
                return
            }
            if AmneziaWGConfigBuilder.tunnelIPv4(server: server) == nil {
                appendLog("AmneziaWG: the profile names no IPv4 interface Address — using \(LoaderIdentifiers.defaultAWGTunAddress), which the server may refuse; re-import the full config if no traffic flows")
            }
            let r = await helper.startAWGTunnel(
                enginePath: enginePath.path,
                configScript: script,
                serverAddress: endpoint,
                tunAddress: awg.tunnelAddress(server: server),
                killSwitch: killSwitchEnabled,
                mtu: awg.effectiveMTU(server: server))
            ok = r.ok; err = r.error
            activeSessionIsWG = true
            // On success the reply's message carries the kernel-assigned utun
            // name (see the XPC contract) — the netstat counters key off it.
            if ok { awg.beginSession(utun: err) } else { awg.endSession() }
        } else {
            let r = await helper.startTunnel(
                socksPort: xray.socksPort, serverAddress: server.address, killSwitch: killSwitchEnabled)
            ok = r.ok; err = r.error
            activeSessionIsWG = false
        }

        // The user may have cancelled while we were bringing the tunnel up,
        // or a newer user command superseded this task (generation moved on).
        // The successor has run (or will run) its own teardown against the
        // state it knows about — touching anything else here used to kill the
        // successor's freshly started engine (shared XrayController) and
        // clobber its connection state. The things ONLY this task knows are
        // whether ITS engine is still up (by token: if the successor already
        // stopped it and started its own, the token no longer matches) and
        // whether ITS helper startTunnel landed: stop exactly those orphans.
        if Task.isCancelled || intentionalStop || commandGeneration != gen {
            if let engineRun { xray.stop(ifRunning: engineRun) }
            // A WG session begun right before the supersede must not leak its
            // bookkeeping (the tunnel itself is epoch-guarded below).
            if isWG { awg.endSession() }
            // Same for a hysteria engine spawned right before the supersede:
            // stop only the run THIS task started.
            if let hyRun { hysteria.stop(ifRunning: hyRun) }
            // Epoch-guard the tunnel stop: if a successor connect has already
            // begun tunneling, its startTunnel (executed in XPC arrival
            // order after this stop) is the one that must win — a stop issued
            // here would tear down the successor's fresh tunnel. If nobody
            // else took over tunneling, this really is our orphan: take it
            // down or its /1 routes and kill switch outlive the session.
            if ok, tunnelEpoch == tunEpoch { _ = await helper.stopTunnel() }
            return
        }
        tunnelActive = ok
        systemTunnelError = ok ? nil : (err ?? "helper unavailable")
        if !ok {
            appendLog(isWG
                ? "system tunnel not active: \(systemTunnelError!)"
                : "system tunnel not active: \(systemTunnelError!) — SOCKS at 127.0.0.1:\(xray.socksPort)")
            // Fail-closed recovery (teardown keepTunnel) leaves the resolver
            // pinned at the tunnel gateway on purpose — but only so the
            // follow-up connect can re-arm the tunnel under it. That connect
            // just failed: a resolver pointed at a gateway with no tunnel
            // behind it leaves the machine name-resolution-dead (and the
            // DNS-set block below is skipped precisely because tunnelActive
            // is false). Restore the resolver before falling through.
            if systemDNSActive {
                _ = await helper.clearSystemDNS()
                systemDNSActive = false
                appendLog("tunnel failed to re-arm — system DNS restored")
            }
            if isWG {
                // No local inbound to fall back to — a WG session without the
                // system tunnel carries nothing at all. Mid-recovery that is
                // the next rung of the ladder, like a failed engine start:
                // ending the episode here turned a transient helper failure
                // into a dead stop.
                guard !Task.isCancelled, commandGeneration == gen else { return }
                if isReconnect {
                    attemptReconnect()
                } else {
                    connection = .error(systemTunnelError!)
                }
                return
            }
        }
        // Split tunneling at the OS level: listed networks and the current
        // addresses of listed domains route via the physical gateway (never
        // into the utun) and stay open under the kill switch. Applied before
        // the DNS pin, so the domains resolve with the local resolver — the
        // answer a geo-restricted local service expects.
        if tunnelActive, !bypassEntries.isEmpty {
            if helperCurrent {
                let (networks, domains) = SplitTunnelParser.partition(bypassEntries)
                let r = await helper.applyBypass(networks: networks, domains: domains)
                guard !Task.isCancelled, !intentionalStop, commandGeneration == gen else { return }
                appendLog(r.ok
                    ? "split tunneling: \(bypassEntries.count) destination(s) bypass the VPN"
                    : "split tunneling: \(r.error ?? "helper error")")
            } else {
                appendLog("split tunneling: update the helper (Settings) to route the bypass list around the system tunnel")
            }
        }
        // Route the system resolver through the tunnel: DNS is where blocked
        // apps actually "fall" — the ISP resolver's answers for blocked domains
        // are poisoned by DPI, so even a perfect tunnel can't open them.
        // Pointing the resolver at the tunnel gateway hands every lookup to the
        // engine, which answers via proxied DoH. Only meaningful under the
        // full tunnel; in SOCKS-only mode the resolver must stay physical.
        if tunnelActive {
            // xray sessions: the engine answers lookups itself (proxied DoH)
            // at the tunnel gateway. WG sessions: the engine doesn't answer
            // DNS — hand the system resolver to the profile's own DNS servers
            // (reached inside the tunnel via the /1 routes), falling back to
            // an open resolver when the profile lists none.
            let r: (ok: Bool, error: String?)
            if isWG, let dns = server.wgProfile?.dns.first(where: { !$0.isEmpty }) {
                r = await helper.setSystemDNS(server: dns)
            } else if isWG {
                appendLog("profile lists no DNS servers — leaving the system resolver untouched")
                r = (false, "no DNS servers in profile")
            } else {
                r = await helper.setSystemDNS()
            }
            // The XPC round-trip can straddle a disconnect whose teardown
            // already restored the resolver (its clear is issued after this
            // set, so the helper's final state is restored) — writing r.ok
            // now would mark a restored system as pinned, and a compensating
            // clear here could instead land after a successor's own set.
            // On supersede, trust the teardown's ordering and walk away.
            guard !Task.isCancelled, !intentionalStop, commandGeneration == gen else { return }
            systemDNSActive = r.ok
            appendLog(r.ok
                ? "system DNS → tunnel: lookups answered via proxied DoH (no ISP poisoning)"
                : "could not set system DNS: \(r.error ?? "helper error") — update the helper in Settings")
        }
        connectedSince = Date()
        connection = .connected
        // Recovery state is cleared only once the connection proves stable (see
        // the health loop), so the ladder keeps progressing across a server that
        // connects but then carries no traffic.
        startStatsPolling()
        startHealthCheck()
        // Coexist mode: when the full tunnel isn't up (e.g. a third-party VPN
        // owns the routes), point the system SOCKS proxy at the engine so
        // browsers/proxy-aware apps actually route through Anemia's foreign exit
        // — otherwise SOCKS mode carries nothing (0 bytes). No-op under the full
        // tunnel, which already routes everything.
        if systemProxyEnabled, !tunnelActive, helperInstalled {
            let r = await helper.setSystemProxy(port: xray.socksPort)
            // Same straddle as setSystemDNS above: a disconnect that ran
            // while this XPC was in flight already cleared the proxy
            // (unconditional restore, issued after this set) — committing
            // r.ok here would leave the flag claiming a live pin over a
            // dead engine port. The setting can also have been flipped off
            // mid-flight: systemProxyActive was still false then, so the
            // toggle-off branch was a no-op and only this re-check honors
            // it. Walk away on supersede; compensate when the helper did
            // apply the set the user no longer wants.
            guard !Task.isCancelled, !intentionalStop, commandGeneration == gen, systemProxyEnabled else {
                if r.ok, !systemProxyEnabled { _ = await helper.clearSystemProxy() }
                return
            }
            systemProxyActive = r.ok
            appendLog(r.ok
                ? "system SOCKS proxy → 127.0.0.1:\(xray.socksPort): apps now exit via Anemia"
                : "could not set system proxy: \(r.error ?? "helper error") — update the helper in Settings")
        }
    }

    /// Health loop: every 10s measure real latency through the tunnel, and ask
    /// the helper whether the system tunnel is still alive. A dead bridge used
    /// to look like "Connected" forever (with the kill switch on — a full
    /// blackhole); now it routes into the standard reconnect path. Cancelled
    /// on teardown so a stale result can't land after disconnect.
    private func startHealthCheck() {
        proxyLatency = nil
        proxyThroughput = nil
        proxyReachable = true
        proxyUnreachableSince = nil
        var consecutiveFailures = 0
        var healthyChecks = 0
        var measuredThroughput = false
        var learned = false
        let port = xray.socksPort
        // Session identity for the one-shot capacity probe below: an 8 s
        // download outliving a fast reconnect would otherwise report the OLD
        // engine's capacity as the new session's (isConnected alone can't
        // tell them apart — healthTask.cancel() can't reach the detached
        // probe once it's downloading).
        let epoch = tunnelEpoch
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                // WireGuard-family sessions have no local SOCKS inbound to
                // probe — health is the helper's tunnel status (utun exists
                // AND the engine process is alive). Latency stays nil there:
                // ProxyHealth's SOCKS dial would just fail against nothing.
                let ms: Int?
                if self.activeSessionIsWG {
                    ms = await self.helper.isTunnelUp() ? -1 : nil
                } else {
                    ms = await ProxyHealth.check(socksPort: port)
                }
                guard !Task.isCancelled, self.isConnected else { return }
                // -1 marks "alive, latency not measured" (WG sessions) — the
                // UI must never see it as a millisecond value.
                self.proxyLatency = ms == -1 ? nil : ms
                // Honest status: two misses in a row means traffic isn't
                // actually getting through, even though the engine is "up".
                consecutiveFailures = (ms == nil) ? consecutiveFailures + 1 : 0
                self.proxyReachable = consecutiveFailures < 2
                if consecutiveFailures == 2 {
                    self.proxyUnreachableSince = Date()
                    self.appendLog("proxy unreachable — engine up but no route to server")
                }

                if ms != nil {
                    healthyChecks += 1
                    self.proxyUnreachableSince = nil
                    // First good check: measure real tunnel capacity once.
                    // (WG sessions have no SOCKS inbound to probe through —
                    // the capacity probe only applies to xray sessions.)
                    if !measuredThroughput, !self.activeSessionIsWG {
                        measuredThroughput = true
                        Task { [weak self] in
                            let tp = await ProxyHealth.throughput(socksPort: port)
                            await MainActor.run {
                                guard let self, self.isConnected, self.tunnelEpoch == epoch else { return }
                                self.proxyThroughput = tp
                                if let tp { self.appendLog("tunnel capacity ~\(Format.speed(tp))") }
                            }
                        }
                    }
                    // Stable for ~30 s: this connection (and its masking) works —
                    // learn the profile for the server and clear the ladder.
                    if healthyChecks >= 3, !learned {
                        learned = true
                        self.onStableConnection()
                    }
                } else {
                    healthyChecks = 0
                }

                // Recovery trigger. Under the full tunnel a dead bridge or a
                // ~30 s traffic blackout routes into the ladder (unless the kill
                // switch is deliberately failing closed). In SOCKS-only mode
                // there's no blackhole, so a persistent no-route just climbs the
                // masking/failover ladder.
                if self.tunnelActive {
                    let up = await self.helper.isTunnelUp()
                    guard !Task.isCancelled, self.isConnected else { return }
                    if !up {
                        self.appendLog("system tunnel lost — recovering")
                        self.attemptReconnect()
                        return
                    }
                    // A soft-dead upstream (TCP alive, no traffic) with the
                    // utun still up reads as "connected, no route" forever
                    // unless we act — the kill switch is no reason to stand
                    // down: the recovery ladder's keepTunnel path keeps the
                    // tunnel (and its fail-closed pf) armed through the
                    // engine restart, so no traffic leaks while it retries.
                    if consecutiveFailures >= 3 {
                        self.appendLog("server unreachable with tunnel up — recovering connectivity")
                        self.attemptReconnect()
                        return
                    }
                } else if consecutiveFailures >= 3 {
                    self.appendLog("proxy unreachable — recovering")
                    self.attemptReconnect()
                    return
                }
                // After a miss, re-probe in 3 s instead of the calm 10 s
                // cadence: a dead tunnel is reported after two misses in ~6 s
                // and the reconnect ladder starts at ~9 s instead of ~30 s.
                let interval: UInt64 = ms == nil ? 3_000_000_000 : 10_000_000_000
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    /// The current connection has held for a while: remember the masking that
    /// works for this server and clear the recovery ladder.
    private func onStableConnection() {
        if let s = sessionServer, learnedMasking[s.identityKey] != activeProfile {
            learnedMasking[s.identityKey] = activeProfile
            persist()
        }
        resetRecoveryState()
    }

    /// Tunnel watchdog — a last-resort recovery trigger, independent of the
    /// health loop. The health loop already reconnects after ~3 misses (~9 s),
    /// but its action can still be lost: the recovery ladder retries with
    /// long backoff while the tunnel (with the kill switch on) keeps
    /// blackholing traffic, or a helper/XPC call wedges the loop past its
    /// deadline. Every 5 s this checks, and once the proxy has been
    /// unreachable for a hard 25 s while the session claims "connected", it
    /// forces `attemptReconnect` — a fresh connect always restarts the health
    /// loop, so the net can't double-fire against a live recovery.
    private func startTunnelWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                guard self.isConnected, !self.intentionalStop else { continue }
                guard !self.proxyReachable, let since = self.proxyUnreachableSince else { continue }
                let dead = Date().timeIntervalSince(since)
                guard dead > 25 else { continue }
                self.appendLog("watchdog: proxy unreachable for \(Int(dead))s — forcing reconnect")
                self.proxyUnreachableSince = nil
                self.attemptReconnect()
            }
        }
    }

    func disconnect() async {
        let gen = commandGeneration &+ 1
        commandGeneration = gen
        intentionalStop = true
        reconnectTask?.cancel()
        reconnectTask = nil
        resetRecoveryState()
        flushHistorySync()
        await teardown(gen: gen)
        // A newer command (e.g. the connect of an off→on toggle) owns the
        // connection state now — flipping to .disconnected under its live
        // tunnel is the stale-teardown clobber.
        guard commandGeneration == gen else { return }
        connection = .disconnected
        sessionServerID = nil
        rescanNetworkHealth()
    }

    /// Stop the engine + tunnel + stats without deciding the resulting state.
    /// `gen` (when given) aborts the teardown the moment a newer command
    /// superseded it: the helper calls fire inside await windows regardless,
    /// but a superseded teardown must not stop the successor's engine or
    /// reset state the successor just set.
    ///
    /// `keepTunnel` (fail-closed recovery): with the kill switch on, keep the
    /// utun, its routes, its kill switch and the DNS pin up while the engine
    /// restarts — traffic stays blackholed at the dead bridge instead of
    /// leaking around the tunnel for the whole backoff + dial window. The
    /// recovery's `startTunnel` then tears the old tunnel down and re-arms it
    /// against the new engine (the helper's start is self-healing/idempotent).
    private func teardown(gen: Int? = nil, keepTunnel: Bool = false) async {
        healthTask?.cancel()
        healthTask = nil
        stopStatsPolling()
        guard !isSuperseded(gen) else { return }
        if helperInstalled {
            // All three restores are issued unconditionally — not gated on
            // the active flags. A 20 s XPC timeout leaves a flag false while
            // the helper may still have applied the change (a startTunnel
            // that lands after the app gave up waiting), so flag-gated
            // teardown leaked live tunnels/proxy pins/resolver pins with
            // nothing left to recover them. The helper is idempotent:
            // stopTunnel tears down only what exists, the clears restore
            // from the pre-override backups and touch nothing unbacked.
            // DNS first: with the utun going away, a resolver still pointed
            // at the tunnel gateway would leave the whole machine
            // name-resolution-dead.
            if !keepTunnel { _ = await helper.clearSystemDNS() }
            guard !isSuperseded(gen) else { return }
            if !keepTunnel { systemDNSActive = false }
            // Restore the system proxy, so apps stop pointing at a SOCKS
            // port that's about to die.
            _ = await helper.clearSystemProxy()
            guard !isSuperseded(gen) else { return }
            systemProxyActive = false
            if !keepTunnel {
                _ = await helper.stopTunnel()
                guard !isSuperseded(gen) else { return }
                tunnelActive = false
            }
        }
        guard !isSuperseded(gen) else { return }
        xray.stop()
        awg.endSession()
        hysteria.stop()
        activeSessionIsWG = false
        connectedSince = nil
        proxyLatency = nil
        proxyThroughput = nil
        proxyReachable = true
        systemTunnelError = nil
    }

    private func isSuperseded(_ gen: Int?) -> Bool {
        guard let gen else { return false }
        return commandGeneration != gen
    }

    /// Recovery ladder, run on any unexpected loss (engine exit, dead bridge, or
    /// a live tunnel that stops passing traffic). Each rung escalates:
    ///   attempt 1 — retry the same server, same masking (most drops are blips).
    ///   attempt 2 — same server, one rung stronger masking (looks like DPI).
    ///   attempt 3+ — fail over to the next-best stable foreign, non-Russian
    ///                server, starting from its own learned/global masking.
    /// Ends (into `.error`, tunnel torn down so the Mac stays reachable) when no
    /// untried eligible server remains or a hard attempt cap is hit. The pending
    /// step is tracked so a manual connect/disconnect cancels it.
    private func attemptReconnect() {
        guard !intentionalStop else { return }
        // No physical network: hold rather than climb (see holdForNetwork).
        guard networkWatcher.isOnline else {
            holdForNetwork()
            return
        }
        // Start of an episode: remember the server we're leaving so failover
        // rotates instead of looping on it.
        if reconnectAttempts == 0, let cur = sessionServerID ?? selectedServerID { recoveryTried.insert(cur) }
        reconnectAttempts += 1
        let attempt = reconnectAttempts

        // Hard cap so a run of start-failures can never spin forever.
        guard attempt <= maxReconnects + 5 else {
            connection = .error("Connection lost")
            // Pass the generation: a nil gen disables the supersede checks
            // inside teardown entirely, so this orphan could keep running
            // (up to 3 × 20 s XPC timeouts) while the user starts a fresh
            // connect — and then kill the successor's engine and tunnel.
            let gen = commandGeneration
            Task { await teardown(gen: gen) }
            resetRecoveryState()
            return
        }

        var action = "retry"
        if attempt == 2, escalatedProfile == nil, let esc = activeProfile.escalated {
            escalatedProfile = esc
            action = "stronger masking → \(esc.title)"
        } else if attempt >= 2 {
            guard let next = nextFailoverServer() else {
                connection = .error("Connection lost — no working server")
                // Same nil-gen hazard as the hard-cap path above: the orphan
                // teardown must still honor supersede.
                let gen = commandGeneration
                Task { await teardown(gen: gen) }
                resetRecoveryState()
                return
            }
            recoveryTried.insert(next.id)
            escalatedProfile = nil            // fresh server → its own profile
            selectedServerID = next.id
            persist()
            action = "switch to \(next.name)"
        }

        connection = .connecting
        appendLog("recovering — \(action) (attempt \(attempt))")
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            let gen = self.commandGeneration &+ 1
            self.commandGeneration = gen
            // Fail-closed recovery: with the kill switch on, keep the tunnel
            // (and its kill switch) armed through the engine restart — the
            // old code tore it down first, so every recovery episode leaked
            // unprotected traffic exactly when the connection was failing,
            // e.g. mid-censorship-event. startTunnel re-arms it against the
            // new engine once the dial succeeds.
            let keepTunnel = self.killSwitchEnabled && self.tunnelActive
            await self.teardown(gen: gen, keepTunnel: keepTunnel)
            let backoff = UInt64(min(4, 1 << max(0, min(attempt - 1, 3)))) * 1_000_000_000  // 1→2→4s
            try? await Task.sleep(nanoseconds: backoff)
            guard !Task.isCancelled, !self.intentionalStop else { return }
            await self.connect(isReconnect: true)
        }
    }

    /// Reset the recovery ladder (attempts, tried set, masking escalation).
    private func resetRecoveryState() {
        reconnectAttempts = 0
        recoveryTried.removeAll()
        escalatedProfile = nil
        waitingForNetwork = false
        networkHoldTask?.cancel()
        networkHoldTask = nil
    }

    /// The next server to fail over to: the best-ranked reachable, foreign,
    /// non-Russian server not yet tried this episode.
    private func nextFailoverServer() -> ProxyServer? {
        allServers
            .filter { s in
                qualityScore[s.id] != nil && !recoveryTried.contains(s.id)
                    && !isRussianExit(s.id) && isForeignExit(s.id)
            }
            .sorted { (qualityScore[$0.id] ?? .greatestFiniteMagnitude)
                    < (qualityScore[$1.id] ?? .greatestFiniteMagnitude) }
            .first
    }

    /// Masking to connect `server` with, plus the profile it represents (so a
    /// stable connection can be learned). A recovery escalation wins; else the
    /// profile learned for this server; else the user's global options. The
    /// user's fingerprint and mux/TFO tweaks always carry through.
    private func maskingForConnect(_ server: ProxyServer) -> (AntiCensorshipOptions, MaskingProfile) {
        if let esc = escalatedProfile { return (withUserTweaks(esc.options), esc) }
        if let learned = learnedMasking[server.identityKey], learned != maskingProfile {
            return (withUserTweaks(learned.options), learned)
        }
        return (anti, maskingProfile)
    }

    private func withUserTweaks(_ base: AntiCensorshipOptions) -> AntiCensorshipOptions {
        var o = base
        o.fingerprint = anti.fingerprint
        o.muxEnabled = anti.muxEnabled
        o.tcpFastOpen = anti.tcpFastOpen
        return o
    }

    // MARK: - Traffic stats

    private func startStatsPolling() {
        // WireGuard-family sessions poll the engine's utun counters via
        // netstat; xray sessions poll the Stats API. The xray prerequisite
        // check only applies to the xray branch.
        if !activeSessionIsWG {
            guard xray.resolveBinary() != nil, xray.apiPort != nil else { return }
        }
        // Snapshot the WG identity ONCE: tearing the session down (disconnect)
        // must not flip a mid-flight poll into the other engine's path.
        let wgSession = activeSessionIsWG
        let wgInterface = awg.utunName
        uplinkTotal = 0; downlinkTotal = 0; uplinkSpeed = 0; downlinkSpeed = 0
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            var lastUp: Int64 = 0, lastDown: Int64 = 0
            var lastAt = DispatchTime.now()
            var firstSample = true
            // Baseline for the session TOTALS: the helper can re-arm a stale
            // tunnel instead of creating a fresh utun, in which case the
            // first sample already carries the previous session's bytes —
            // publishing it raw would bill those to this session. Speeds are
            // delta-based and never needed this.
            var baseUp: Int64 = 0, baseDown: Int64 = 0
            while !Task.isCancelled {
                // Polling runs off the main actor at background QoS (energy:
                // it's a diagnostic path).
                let sample: (up: Int64, down: Int64)?
                if wgSession {
                    if let iface = wgInterface {
                        sample = await Task.detached(priority: .background) {
                            AWGController.trafficCounters(interface: iface)
                        }.value
                    } else {
                        // No utun name (helper predates 0.7.0, or routing
                        // failed) — no counters exist; the loop idles at the
                        // failed-sample cadence.
                        sample = nil
                    }
                } else {
                    guard let binary = self?.xray.resolveBinary()?.path,
                          let apiPort = self?.xray.apiPort else { break }
                    sample = await Task.detached(priority: .background) {
                        queryXrayTraffic(binaryPath: binary, apiPort: apiPort)
                    }.value
                }
                if let (up, down) = sample {
                    // First sample is the baseline: the utun counters are
                    // cumulative from interface creation (possibly the
                    // previous session's), so the first read is "everything
                    // so far", not a speed.
                    let (deltaUp, deltaDown) = firstSample ? (0, 0) : (max(0, up - lastUp), max(0, down - lastDown))
                    if firstSample { baseUp = up; baseDown = down }
                    firstSample = false
                    // Speed per actual elapsed second — robust to poll jitter.
                    let now = DispatchTime.now()
                    let dt = max(0.001, Double(now.uptimeNanoseconds - lastAt.uptimeNanoseconds) / 1_000_000_000)
                    lastAt = now
                    let upSpeed = Int64((Double(deltaUp) / dt).rounded())
                    let downSpeed = Int64((Double(deltaDown) / dt).rounded())
                    lastUp = up; lastDown = down
                    await MainActor.run {
                        // A sample spawned just before a disconnect can land
                        // after teardown zeroed the counters — writing it
                        // back would re-populate the dimmed stats row with
                        // stale bytes for the whole disconnected period.
                        guard let self, !Task.isCancelled, self.isConnected else { return }
                        self.uplinkSpeed = upSpeed
                        self.downlinkSpeed = downSpeed
                        // Session totals relative to the first sample's
                        // baseline — the raw counters may carry a previous
                        // session's bytes when the helper re-armed its utun.
                        self.uplinkTotal = max(0, up - baseUp)
                        self.downlinkTotal = max(0, down - baseDown)
                        // Session history for the map tile's sparkline: a
                        // fixed ring, oldest dropped first.
                        self.trafficHistory.append(TrafficSample(down: downSpeed, up: upSpeed))
                        if self.trafficHistory.count > Self.trafficHistoryCapacity {
                            self.trafficHistory.removeFirst(self.trafficHistory.count - Self.trafficHistoryCapacity)
                        }
                    }
                }
                // Cadence follows demand: each sample forks the whole `xray`
                // binary (~28 MB RSS churn per spawn), so the old flat 2 s was
                // a constant background load for numbers nobody was watching.
                // 2 s while a stats UI is open, 5 s headless, 10 s while the
                // API is failing (a wedged query must not spawn per 2 s).
                let cadence: UInt64
                if sample == nil {
                    cadence = 10
                } else if self?.statsViewers ?? 0 > 0 {
                    cadence = 2
                } else {
                    cadence = 5
                }
                try? await Task.sleep(nanoseconds: cadence * 1_000_000_000)
            }
        }
    }

    private func stopStatsPolling() {
        statsTask?.cancel()
        statsTask = nil
        uplinkSpeed = 0; downlinkSpeed = 0
        // Totals too: leaving the previous session's cumulative bytes in the
        // dimmed stats row while disconnected read as live traffic.
        uplinkTotal = 0; downlinkTotal = 0
        // History belongs to the session that produced it — a stale curve
        // under the map would read as live traffic after reconnect.
        trafficHistory = []
    }

    // MARK: - Logs

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > maxLogLines {
            logLines.removeFirst(logLines.count - maxLogLines)
        }
        logRevision += 1
        AppLog.write(line)
    }

    func clearLogs() { logLines.removeAll() }

    private func handleXrayExit(_ status: Int32) {
        stopStatsPolling()
        connectedSince = nil
        // User-initiated stop: nothing to recover.
        if intentionalStop { return }
        // Unexpected exit while (re)connecting — try to recover.
        if connection == .connected || connection == .connecting {
            appendLog("engine exited unexpectedly (code \(status))")
            attemptReconnect()
        }
    }
}

#if DEBUG
// MARK: - Preview scenarios (headless UI snapshots)

extension AppState {
    /// Canned states for Tests/LoaderAppSnapshotTests — the only way to see
    /// connected / broken-network surfaces without a live server or root.
    enum PreviewScenario { case idle, connected, networkNeedsRepair }

    func applyPreview(_ scenario: PreviewScenario) {
        homeCountry = "RU"
        waitingForNetwork = false
        connection = .disconnected
        tunnelActive = false
        connectedSince = nil
        proxyLatency = nil
        proxyThroughput = nil
        proxyReachable = true
        systemTunnelError = nil
        networkIssues = []
        uplinkSpeed = 0; downlinkSpeed = 0; uplinkTotal = 0; downlinkTotal = 0
        trafficHistory = []
        for (i, s) in allServers.enumerated() { pings[s.id] = .ms(42 + i * 37) }
        switch scenario {
        case .idle:
            break
        case .connected:
            connection = .connected
            tunnelActive = true
            connectedSince = Date().addingTimeInterval(-754)
            proxyLatency = 48
            proxyThroughput = 12_400_000
            downlinkSpeed = 3_450_000; uplinkSpeed = 182_000
            downlinkTotal = 412_000_000; uplinkTotal = 18_300_000
            trafficHistory = (0..<60).map { i in
                TrafficSample(down: Int64(2_000_000 + 1_500_000 * sin(Double(i) / 5)),
                              up: Int64(150_000 + 60_000 * cos(Double(i) / 4)))
            }
        case .networkNeedsRepair:
            networkIssues = [NetworkHealthScan.Issue(
                id: "dns|Wi-Fi",
                message: "Wi-Fi: DNS is set to 172.28.0.2 — a tunnel address that no longer exists, so no website can be resolved")]
        }
    }
}
#endif

// MARK: - Network safety

extension AppState {
    /// Re-scan for broken leftovers off the main actor. A result that lands
    /// while a session is live is dropped — its own overrides are expected.
    func rescanNetworkHealth() {
        Task { [weak self] in
            let issues = await Task.detached(priority: .utility) { NetworkHealthScan.scan() }.value
            guard let self, !self.isConnected, self.connection != .connecting else { return }
            guard issues != self.networkIssues else { return }
            self.networkIssues = issues
            for issue in issues { self.appendLog("network check: \(issue.message)") }
        }
    }

    /// Bring the network back to a working state, whatever a session, a crash
    /// or an older version left behind: the tunnel comes down, recorded DNS
    /// and proxy overrides are restored, the kill switch is flushed, orphaned
    /// bridges and dead pins are swept. Uses the installed helper when it is
    /// current; otherwise one admin prompt runs the bundled helper's restore —
    /// so it works with no helper installed at all.
    func repairNetwork() async {
        guard !repairInProgress else { return }
        repairInProgress = true
        defer { repairInProgress = false }
        if isConnected || connection == .connecting || tunnelActive || systemDNSActive || systemProxyActive {
            await disconnect()
        }
        var report: String?
        if helperInstalled, helperCurrent {
            report = await helper.repairNetwork()
        }
        if report == nil {
            do {
                report = try await Task.detached(priority: .userInitiated) {
                    try HelperInstaller.repairNetworkWithAdminPrompt()
                }.value
            } catch HelperInstaller.InstallError.cancelled {
                return
            } catch {
                report = "Repair failed: \(error.localizedDescription)"
            }
        }
        let text = report ?? "Repair finished."
        lastRepairReport = text
        appendLog("network repair:\n\(text)")
        refreshHelperStatus()
        rescanNetworkHealth()
    }

    /// Plain-text snapshot for bug reports: versions, session state, the
    /// network check, the helper's own view of the system, the recent log.
    func diagnosticsReport() async -> String {
        let info = Bundle.main.infoDictionary
        var lines = [
            "Anemia \(info?["CFBundleShortVersionString"] as? String ?? "dev") (\(info?["CFBundleVersion"] as? String ?? "-"))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "helper: \(helperInstalled ? (helperCurrent ? "installed, current" : "installed, outdated") : "not installed") (app expects \(LoaderHelperVersion))",
            "connection: \(connection); tunnel \(tunnelActive ? "up" : "down"); DNS pin \(systemDNSActive); proxy pin \(systemProxyActive); kill switch \(killSwitchEnabled ? "on" : "off")"
        ]
        if let err = systemTunnelError { lines.append("tunnel error: \(err)") }
        let issues = await Task.detached(priority: .utility) { NetworkHealthScan.scan() }.value
        lines.append(issues.isEmpty
            ? "network check: clean"
            : "network check:\n" + issues.map { "  " + $0.message }.joined(separator: "\n"))
        if helperInstalled, helperCurrent, let view = await helper.networkDiagnostics() {
            lines.append("helper view:\n" + view.split(separator: "\n").map { "  " + $0 }.joined(separator: "\n"))
        }
        lines.append("recent log:")
        lines += logLines.suffix(60).map { "  " + $0 }
        return lines.joined(separator: "\n")
    }

    func copyDiagnosticsToPasteboard() async {
        let text = await diagnosticsReport()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        appendLog("diagnostics copied to the clipboard")
    }

    /// Reveal the persistent app log in Finder.
    func revealLogFile() {
        NSWorkspace.shared.activateFileViewerSelecting([AppLog.path])
    }

    /// The full tunnel failed because another VPN client owns the system
    /// routes or our tunnel range — the case where routing apps through the
    /// system proxy is the useful fallback (offered, never forced).
    var tunnelBlockedByAnotherVPN: Bool {
        guard let err = systemTunnelError else { return false }
        return err.contains("owned by another tunnel") || err.contains("collides with our tunnel range")
    }
}

/// Mirrors in-app log lines to a persistent file so tunnel problems can be
/// diagnosed after the fact — the in-memory buffer dies with the app.
enum AppLog {
    static let path = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Loader/app.log")
    private static let queue = DispatchQueue(label: "com.loader.vpn.applog", qos: .utility)
    private static let maxBytes = 1_000_000
    // Only ever touched from the serial `queue` above — the class is mutable
    // state, but no two writes can race (queue-serialized).
    private nonisolated(unsafe) static let stampFormatter = ISO8601DateFormatter()

    static func write(_ line: String) {
        queue.async {
            let stamp = stampFormatter.string(from: Date())
            let entry = "\(stamp) \(line)\n"
            let url = path
            let dir = url.deletingLastPathComponent()
            // The hot path is a cached handle + a plain write. The old per-line
            // flow paid createDirectory + attributesOfItem (stat) + FileHandle
            // open/seek/close on EVERY log line — several syscalls and a heap
            // object per line, on an engine that can log in bursts.
            if logFile == nil {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                logFile = FileHandle(forWritingAtPath: url.path)
                _ = try? logFile?.seekToEnd()
                logWritten = 0
                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? Int {
                    logWritten = size
                }
            }
            // Rotation is decided by the byte counter, not a stat per line;
            // the counter is seeded from the file size on open and tracks
            // every write, so it stays in sync with the on-disk size.
            if logWritten > maxBytes {
                try? logFile?.close()
                logFile = nil
                // Remove the previous rotation first: moveItem refuses to
                // overwrite, so the second rotation onward used to fail
                // silently and app.log grew without bound.
                try? FileManager.default.removeItem(at: dir.appendingPathComponent("app.log.1"))
                try? FileManager.default.moveItem(at: url, to: dir.appendingPathComponent("app.log.1"))
                FileManager.default.createFile(atPath: url.path, contents: nil)
                logFile = FileHandle(forWritingAtPath: url.path)
                _ = try? logFile?.seekToEnd()
                logWritten = 0
            }
            guard let handle = logFile else { return }
            let data = Data(entry.utf8)
            _ = try? handle.write(contentsOf: data)
            logWritten += data.count
        }
    }

    /// Serial to the `queue` above — the handle, the byte counter and the
    /// rotation flow are only ever touched from queue-serialized blocks.
    private nonisolated(unsafe) static var logFile: FileHandle?
    private nonisolated(unsafe) static var logWritten = 0
}
