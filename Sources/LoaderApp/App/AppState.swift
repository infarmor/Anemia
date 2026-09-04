import Foundation
import SwiftUI
import LoaderCore

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
    @Published var lastImportError: String?

    // Live traffic (cumulative bytes + per-second speed) and session start.
    @Published private(set) var uplinkTotal: Int64 = 0
    @Published private(set) var downlinkTotal: Int64 = 0
    @Published private(set) var uplinkSpeed: Int64 = 0
    @Published private(set) var downlinkSpeed: Int64 = 0
    @Published private(set) var connectedSince: Date?

    // Server pinging + ML ranking.
    @Published var pings: [UUID: PingResult] = [:]
    @Published var autoConnectOnLaunch = false
    @Published var mlRankingEnabled = true
    @Published private(set) var kxcDevice = "—"
    @Published private(set) var isPinging = false
    /// Real latency measured through the live tunnel (health check).
    @Published private(set) var proxyLatency: Int?
    private var pingHistory: [UUID: [Float]] = [:]
    private let historyStore = HistoryStore(maxSamples: 256)
    private let probesPerRound = 8
    private let ranker: ServerRanker = CoreMLRanker()
    var rankerBackend: String { ranker.backend }
    /// In-flight auto-reconnect (cancelled by a manual connect/disconnect).
    private var reconnectTask: Task<Void, Never>?
    /// Post-connect health check (cancelled on teardown so a stale result
    /// can't land after disconnect).
    private var healthTask: Task<Void, Never>?

    private let persistence: StatePersistence
    private let xray: XrayController
    private let helper = HelperClient()
    private let maxLogLines = 500
    private var statsTask: Task<Void, Never>?

    // Auto-reconnect bookkeeping.
    private var intentionalStop = false
    private var reconnectAttempts = 0
    private let maxReconnects = 3

    init(
        persistence: StatePersistence = StatePersistence(fileURL: StatePersistence.defaultURL()),
        xray: XrayController = XrayController()
    ) {
        self.persistence = persistence
        self.xray = xray

        xray.onLog = { [weak self] line in
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

        // On launch: if enabled and servers exist, ping and connect the fastest.
        if autoConnectOnLaunch, !allServers.isEmpty {
            Task { [weak self] in await self?.connectFastest() }
        }
        // Detect where CoreML places kxc, for the settings display.
        Task { [weak self] in await self?.refreshKxcInfo() }
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
            mlRankingEnabled: mlRankingEnabled
        )
        do { try persistence.save(state) }
        catch { appendLog("persist error: \(error.localizedDescription)") }
    }

    func setKillSwitch(_ on: Bool) {
        killSwitchEnabled = on
        persist()
    }

    /// Apply a masking preset, preserving the chosen fingerprint.
    func setMaskingProfile(_ profile: MaskingProfile) {
        maskingProfile = profile
        let fp = anti.fingerprint
        anti = profile.options
        anti.fingerprint = fp
        persist()
    }

    func setFingerprint(_ fingerprint: String) {
        anti.fingerprint = fingerprint
        persist()
    }

    // MARK: - Server management

    func select(_ id: UUID) {
        selectedServerID = id
        persist()
    }

    /// One-tap: select this server and connect (switching if already connected).
    func quickConnect(_ id: UUID) {
        selectedServerID = id
        persist()
        Task {
            if isConnected || connection == .connecting { await disconnect() }
            await connect()
        }
    }

    func importLink(_ raw: String) {
        do {
            let server = try ShareLinkParser.parse(raw)
            servers.append(server)
            if selectedServerID == nil { selectedServerID = server.id }
            lastImportError = nil
            persist()
        } catch {
            lastImportError = "\(error)"
        }
    }

    func removeServer(_ id: UUID) {
        servers.removeAll { $0.id == id }
        if selectedServerID == id { selectedServerID = allServers.first?.id }
        pruneHistory()
        persist()
    }

    func addSubscription(name: String, url: String) async {
        var sub = Subscription(name: name.isEmpty ? url : name, url: url)
        await refresh(&sub)
        subscriptions.append(sub)
        if selectedServerID == nil { selectedServerID = sub.servers.first?.id }
        persist()
    }

    func refreshSubscription(_ id: UUID) async {
        guard let idx = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        var sub = subscriptions[idx]
        await refresh(&sub)
        subscriptions[idx] = sub
        persist()
    }

    private func refresh(_ sub: inout Subscription) async {
        guard let url = URL(string: sub.url) else {
            lastImportError = "Bad subscription URL"; return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let body = String(data: data, encoding: .utf8) ?? ""
            var result = SubscriptionParser.parse(body)
            // Carry stable IDs across refreshes (link text is the identity):
            // the selected server survives an update and ping history doesn't
            // orphan.
            var byLink: [String: UUID] = [:]
            for old in sub.servers { byLink[old.identityKey] = old.id }
            for i in result.servers.indices {
                if let known = byLink[result.servers[i].identityKey] {
                    result.servers[i].id = known
                }
            }
            sub.servers = result.servers
            sub.lastUpdated = Date()
            if !result.failures.isEmpty {
                appendLog("subscription '\(sub.name)': \(result.failures.count) links skipped")
            }
        } catch {
            lastImportError = "Fetch failed: \(error.localizedDescription)"
        }
    }

    func removeSubscription(_ id: UUID) {
        subscriptions.removeAll { $0.id == id }
        if selectedServer == nil { selectedServerID = allServers.first?.id }
        pruneHistory()
        persist()
    }

    /// Drop ping history for servers that no longer exist so the persisted
    /// store can't grow without bound and stale entries never leak back in.
    private func pruneHistory() {
        let live = Set(allServers.map { $0.id })
        pingHistory = pingHistory.filter { live.contains($0.key) }
        for gone in pings.keys where !live.contains(gone) { pings[gone] = nil }
        saveHistory()
    }

    // MARK: - Ping & ML ranking

    func setAutoConnectOnLaunch(_ on: Bool) {
        autoConnectOnLaunch = on
        persist()
    }

    /// Ping every server (3 TCP probes each) and record latency + features.
    func pingAll() async {
        let servers = allServers
        guard !servers.isEmpty else { return }
        isPinging = true
        for s in servers { pings[s.id] = .measuring }
        let n = probesPerRound
        await withTaskGroup(of: (UUID, PingResult, [Float]).self) { group in
            for s in servers {
                let host = s.address, port = s.port, id = s.id
                group.addTask {
                    let samples = await LatencyProbe.sample(host: host, port: port, count: n, timeout: 2)
                    // Raw series for history: success = RTT, failed = -1.
                    let raw = samples.map { $0.map(Float.init) ?? -1 }
                    let ok = samples.compactMap { $0 }
                    let result: PingResult = ok.isEmpty
                        ? .failed
                        : .ms(Int((Double(ok.reduce(0, +)) / Double(ok.count)).rounded()))
                    return (id, result, raw)
                }
            }
            for await (id, result, raw) in group {
                pings[id] = result
                var h = pingHistory[id] ?? []
                h.append(contentsOf: raw)
                if h.count > 256 { h.removeFirst(h.count - 256) }
                pingHistory[id] = h
            }
        }
        saveHistory()
        isPinging = false
    }

    private func saveHistory() {
        var dict: [String: [Float]] = [:]
        for (id, v) in pingHistory { dict[id.uuidString] = v }
        historyStore.save(dict)
    }

    /// Reachable servers, best-first. Uses the kxc temporal ranker when enabled,
    /// otherwise plain lowest average ping. Scoring runs concurrently off the
    /// main actor — ANE inference never blocks the UI or the tunnel path.
    func rankedServers() async -> [ProxyServer] {
        let mlEnabled = mlRankingEnabled
        let ranker = self.ranker
        let entries: [(server: ProxyServer, features: ServerFeatures)] = allServers.compactMap { s in
            guard let h = pingHistory[s.id], h.contains(where: { $0 >= 0 }) else { return nil }
            return (s, ServerFeatures(history: h))
        }
        guard !entries.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, Double).self) { group in
            for (i, entry) in entries.enumerated() {
                group.addTask {
                    let score = mlEnabled
                        ? await ranker.score(entry.features)
                        : averagePingScore(entry.features.history)
                    return (i, score)
                }
            }
            var scores = [Int: Double](minimumCapacity: entries.count)
            for await (i, score) in group { scores[i] = score }
            return entries.enumerated()
                .sorted { scores[$0.offset]! < scores[$1.offset]! }
                .map { $0.element.server }
        }
    }

    // MARK: - kxc (ML ranker) info

    var kxcName: String { CoreMLRanker.name }
    var kxcLoaded: Bool { (ranker as? CoreMLRanker)?.isLoaded ?? false }

    func setMLRanking(_ on: Bool) {
        mlRankingEnabled = on
        persist()
    }

    /// Query where CoreML actually places kxc (Neural Engine / GPU / CPU).
    func refreshKxcInfo() async {
        guard let r = ranker as? CoreMLRanker, let dev = await r.detectComputeDevice() else { return }
        kxcDevice = dev
    }

    /// Ping everything, then select and connect the best-ranked server.
    func connectFastest() async {
        await pingAll()
        guard let best = await rankedServers().first else {
            appendLog("no reachable servers to auto-connect")
            return
        }
        appendLog("fastest: \(best.name) (\(rankerBackend))")
        selectedServerID = best.id
        persist()
        await connect()
    }

    // MARK: - Connect / disconnect

    func toggleConnection() {
        switch connection {
        case .connected, .error, .connecting:
            // `.connecting` toggles to cancel an in-flight connect/reconnect.
            Task { await disconnect() }
        case .disconnected:
            Task { await connect() }
        }
    }

    func connect(isReconnect: Bool = false) async {
        guard let server = selectedServer else {
            connection = .error("No server selected"); return
        }
        if !isReconnect {
            // A fresh manual connect supersedes any in-flight auto-reconnect.
            reconnectTask?.cancel()
            reconnectTask = nil
            intentionalStop = false
            reconnectAttempts = 0
        }
        connection = .connecting
        do {
            try await xray.start(server: server, anti: anti)
        } catch {
            connection = .error(error.localizedDescription)
            return
        }

        // Bring up the system-wide tunnel via the privileged helper. If the
        // helper isn't installed yet, we stay "connected" in SOCKS-only mode so
        // the user can still test the proxy at 127.0.0.1:<socksPort>.
        let (ok, err) = await helper.startTunnel(
            socksPort: xray.socksPort, serverAddress: server.address, killSwitch: killSwitchEnabled)

        // The user may have cancelled while we were bringing the tunnel up.
        if intentionalStop {
            await teardown()
            connection = .disconnected
            return
        }
        tunnelActive = ok
        if !ok {
            appendLog("system tunnel not active: \(err ?? "helper unavailable") — SOCKS at 127.0.0.1:\(xray.socksPort)")
        }
        connectedSince = Date()
        connection = .connected
        reconnectAttempts = 0
        startStatsPolling()
        startHealthCheck()
    }

    /// Probe real connectivity through the tunnel and record the round-trip.
    private func startHealthCheck() {
        proxyLatency = nil
        let port = xray.socksPort
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            let ms = await ProxyHealth.check(socksPort: port)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.isConnected else { return }
                self.proxyLatency = ms
                if ms == nil { self.appendLog("health check: no response through proxy") }
            }
        }
    }

    func disconnect() async {
        intentionalStop = true
        reconnectTask?.cancel()
        reconnectTask = nil
        await teardown()
        connection = .disconnected
    }

    /// Stop the engine + tunnel + stats without deciding the resulting state.
    private func teardown() async {
        healthTask?.cancel()
        healthTask = nil
        stopStatsPolling()
        if tunnelActive {
            _ = await helper.stopTunnel()
            tunnelActive = false
        }
        xray.stop()
        connectedSince = nil
        proxyLatency = nil
    }

    /// Called when the engine exits unexpectedly: retry with exponential
    /// backoff, or give up after `maxReconnects`. The pending retry is
    /// tracked so a manual connect/disconnect cancels it (no double-start).
    private func attemptReconnect() {
        guard !intentionalStop else { return }
        guard reconnectAttempts < maxReconnects else {
            connection = .error("Connection lost")
            Task { await teardown() }
            return
        }
        reconnectAttempts += 1
        let attempt = reconnectAttempts
        connection = .connecting
        appendLog("reconnecting (attempt \(attempt)/\(maxReconnects))…")
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            await self.teardown()
            let backoff = UInt64(1 << (attempt - 1)) * 1_000_000_000  // 1s, 2s, 4s
            try? await Task.sleep(nanoseconds: backoff)
            // Superseded by a manual connect or a disconnect?
            guard !Task.isCancelled, !self.intentionalStop else { return }
            await self.connect(isReconnect: true)
        }
    }

    // MARK: - Traffic stats

    private func startStatsPolling() {
        guard let binary = xray.resolveBinary()?.path, let apiPort = xray.apiPort else { return }
        uplinkTotal = 0; downlinkTotal = 0; uplinkSpeed = 0; downlinkSpeed = 0
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            var lastUp: Int64 = 0, lastDown: Int64 = 0
            var lastAt = DispatchTime.now()
            while !Task.isCancelled {
                // Polling runs the `xray api statsquery` CLI off the main
                // actor at background QoS (energy: it's a diagnostic path).
                let sample = await Task.detached(priority: .background) {
                    queryXrayTraffic(binaryPath: binary, apiPort: apiPort)
                }.value
                if let (up, down) = sample {
                    // Speed per actual elapsed second — robust to poll jitter.
                    let now = DispatchTime.now()
                    let dt = max(0.001, Double(now.uptimeNanoseconds - lastAt.uptimeNanoseconds) / 1_000_000_000)
                    lastAt = now
                    let upSpeed = Int64((Double(max(0, up - lastUp)) / dt).rounded())
                    let downSpeed = Int64((Double(max(0, down - lastDown)) / dt).rounded())
                    lastUp = up; lastDown = down
                    await MainActor.run {
                        guard let self else { return }
                        self.uplinkSpeed = upSpeed
                        self.downlinkSpeed = downSpeed
                        self.uplinkTotal = up
                        self.downlinkTotal = down
                    }
                }
                // 2s cadence: each poll spawns an `xray api` subprocess;
                // 1 Hz was a process spawn per second for a diagnostic read.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func stopStatsPolling() {
        statsTask?.cancel()
        statsTask = nil
        uplinkSpeed = 0; downlinkSpeed = 0
    }

    // MARK: - Logs

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > maxLogLines {
            logLines.removeFirst(logLines.count - maxLogLines)
        }
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
