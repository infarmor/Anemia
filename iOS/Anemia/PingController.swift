import Foundation
import LoaderCore
import Observation

/// Measures the servers and picks the fastest.
///
/// Two kinds of numbers: a ping (a TLS handshake, or ICMP for UDP servers),
/// and a real check — one HTTPS request through the server by the engine,
/// which also catches servers that answer the handshake but carry nothing.
/// While the VPN is up the app's own packets would ride the tunnel, so both
/// run inside the tunnel extension, whose sockets go straight to the network.
@MainActor
@Observable
final class PingController {
    enum Result: Equatable, Codable {
        case measuring
        case ms(Int)
        case failed
    }

    /// The outcome of a real check.
    enum Verdict: Equatable, Codable {
        /// Milliseconds for one request through the server.
        case works(Int)
        /// Answers, but no request got through.
        case broken(String)
    }

    private(set) var results: [UUID: Result] = [:]
    private(set) var verdicts: [UUID: Verdict] = [:]
    private(set) var isRunning = false
    /// Servers done and in total while a real check runs.
    private(set) var progress: (done: Int, total: Int)?

    /// Recent RTTs per server (−1 = lost), the input of ServerScoring.
    @ObservationIgnored private var history: [UUID: [Float]] = [:]
    @ObservationIgnored private weak var tunnel: TunnelController?
    /// The masking each server is checked with (its own, if it has one).
    @ObservationIgnored var maskingFor: (ProxyServer) -> MaskingProfile = { _ in .balanced }
    /// Retry blocked servers with stronger masking, and report what worked.
    @ObservationIgnored var adaptsMasking: () -> Bool = { false }
    @ObservationIgnored var onLearnedMasking: (ProxyServer, MaskingProfile) -> Void = { _, _ in }
    /// Когда последний раз записывали замер с туннеля — по монотонным часам:
    /// шаг стенных часов назад превращал порог в 55 с в «никогда», и остров
    /// держал «42 мс» до конца сессии, а `TunnelHealth` — считал протухшим.
    @ObservationIgnored private var lastRecorded: [UUID: DispatchTime] = [:]
    @ObservationIgnored private var recordedSinceSave = 0
    private static let historyKey = "pingHistory"
    private static let verdictKey = "serverVerdicts"
    /// Enough for kxc to see trends and loss bursts, not just a level.
    private static let historyLimit = 64
    private static let batchSize = 12

    init(tunnel: TunnelController) {
        self.tunnel = tunnel
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.historyKey),
           let saved = try? JSONDecoder().decode([UUID: [Float]].self, from: data) {
            history = saved
            for (id, rtts) in saved { results[id] = Self.summary(rtts.suffix(3)) }
        }
        if let data = defaults.data(forKey: Self.verdictKey),
           let saved = try? JSONDecoder().decode([UUID: Verdict].self, from: data) {
            verdicts = saved
        }
    }

    // MARK: - Rounds

    /// A quick round: three pings each, a batch at a time. False when another
    /// round was already running and this call measured nothing — the caller
    /// that ranks servers has to know its verdicts are stale.
    @discardableResult
    func pingAll(_ servers: [ProxyServer]) async -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        defer {
            isRunning = false
            save()
        }
        await pingRound(servers.filter(\.runsOnIOS))
        return true
    }

    /// The thorough round: pings, then a real request through every server
    /// that can take one (WireGuard-family servers keep their ping), then —
    /// with adaptive masking — stronger masking for the ones that answer
    /// but carry nothing.
    @discardableResult
    func checkAll(_ servers: [ProxyServer]) async -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        defer {
            isRunning = false
            progress = nil
            save()
        }
        let usable = servers.filter(\.runsOnIOS)
        await pingRound(usable)
        // A server that refuses even the TCP handshake won't carry a request:
        // don't wait out its timeout. UDP servers often ignore pings, so they
        // always get the real check.
        let candidates = usable.filter { server in
            guard ProbeConfig.supports(server) else { return false }
            let udp = PingTarget(server: server).method == .icmp
            return udp || results[server.id] != .failed
        }
        for server in usable where ProbeConfig.supports(server) && !candidates.contains(where: { $0.id == server.id }) {
            verdicts[server.id] = .broken("не отвечает")
        }
        progress = (0, candidates.count)
        let items = candidates.map { EngineProbe.Item(server: $0, masking: maskingFor($0)) }
        for outcome in await probe(items, trackingProgress: true) {
            verdicts[outcome.id] = outcome.ms.map(Verdict.works) ?? .broken(Self.reason(outcome.error))
        }
        guard adaptsMasking() else { return true }

        // Reachable (the handshake answered), blocked anyway: DPI at work.
        // Stronger masking may get through; the first profile that does is
        // kept for the server.
        var blocked = candidates.filter { server in
            guard case .broken = verdicts[server.id], Self.maskable(server) else { return false }
            if case .ms = results[server.id] { return true }
            return false
        }
        for profile in [MaskingProfile.maximum, .ruYandex] where !blocked.isEmpty {
            let retry = blocked.filter { maskingFor($0).strength < profile.strength }
            guard !retry.isEmpty else { continue }
            let outcomes = await probe(retry.map { EngineProbe.Item(server: $0, masking: profile) }, trackingProgress: false)
            for outcome in outcomes {
                guard let ms = outcome.ms, let server = retry.first(where: { $0.id == outcome.id }) else { continue }
                verdicts[outcome.id] = .works(ms)
                onLearnedMasking(server, profile)
                blocked.removeAll { $0.id == outcome.id }
            }
        }
        return true
    }

    /// Waits for a round started elsewhere to finish. Returns whether the
    /// controller went idle — after the timeout the verdicts may still be
    /// moving, and the caller says so rather than ranking on half a round.
    func waitForRound(timeout: TimeInterval = 120) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
        return !isRunning
    }

    /// Real checks, a batch at a time: in the extension while the tunnel
    /// runs, in the app otherwise.
    private func probe(_ items: [EngineProbe.Item], trackingProgress: Bool) async -> [EngineProbe.Outcome] {
        let viaTunnel = tunnel?.status == .connected
        var outcomes: [EngineProbe.Outcome] = []
        for start in stride(from: 0, to: items.count, by: Self.batchSize) {
            let batch = Array(items[start..<min(start + Self.batchSize, items.count)])
            if viaTunnel {
                // No answer from the extension says nothing about the servers.
                outcomes += await tunnel?.probe(batch) ?? []
            } else {
                outcomes += await EngineProbe.runDetached(batch, concurrency: 6)
            }
            if trackingProgress, let total = progress?.total {
                progress = (min(start + batch.count, total), total)
            }
        }
        return outcomes
    }

    /// Masking shapes the TCP handshake: it helps TCP transports, not QUIC
    /// (Hysteria, mKCP, QUIC) and not WireGuard.
    private static func maskable(_ server: ProxyServer) -> Bool {
        switch server.proto {
        case .vless, .vmess, .trojan, .shadowsocks:
            return server.network != .kcp && server.network != .quic
        default:
            return false
        }
    }

    private func pingRound(_ servers: [ProxyServer]) async {
        let targets = servers.map { PingTarget(server: $0) }
        for target in targets { results[target.id] = .measuring }
        let viaTunnel = tunnel?.status == .connected
        for start in stride(from: 0, to: targets.count, by: Self.batchSize) {
            let batch = Array(targets[start..<min(start + Self.batchSize, targets.count)])
            let samples: [PingSample]
            if viaTunnel {
                samples = await tunnel?.ping(batch) ?? []
            } else {
                samples = await ServerPinger.run(batch)
            }
            for sample in samples { record(sample) }
            for target in batch where results[target.id] == .measuring {
                results[target.id] = nil
            }
        }
    }

    // MARK: - Choosing

    /// The best server — outside Russia unless nothing else works, since a
    /// Russian exit bypasses no Russian blocks. Servers with a real check are
    /// ranked by it; WireGuard-family ones by their ping, scaled to the same
    /// footing (a request takes a few round trips); servers a check found
    /// broken are out.
    func best(among servers: [ProxyServer], excluding excluded: UUID? = nil) -> ProxyServer? {
        let ranked = servers
            .filter { $0.runsOnIOS && $0.id != excluded }
            .compactMap { server -> (server: ProxyServer, cost: Double)? in
                cost(of: server).map { (server, $0) }
            }
            .sorted { $0.cost < $1.cost }
        return (ranked.first { Country.code(inServerName: $0.server.name) != "RU" } ?? ranked.first)?.server
    }

    /// Estimated milliseconds for a request through `server`; nil when it
    /// doesn't work or was never measured.
    ///
    /// kxc reads the ping history for where the server is heading: a server
    /// that has started to drift or drop packets costs more than its last
    /// number says, a recovering one less. Near-ties go to the steadier one.
    func cost(of server: ProxyServer) -> Double? {
        let rtts = history[server.id] ?? []
        let stability = rtts.isEmpty ? 0.5 : ServerScoring.stability(rtts)
        let steadiness = 1.3 - 0.3 * stability
        let now = rtts.isEmpty ? nil : ServerScoring.rankingScore(rtts)
        let forecast = Kxc.shared.forecast(rtts)
        switch verdicts[server.id] {
        case .works(let ms):
            var outlook = 1.0
            if let forecast, let now, now > 0, now < 100_000 {
                outlook = min(max(forecast / now, 0.8), 1.5)
            }
            return Double(ms) * steadiness * outlook
        case .broken:
            return nil
        case nil:
            guard let score = forecast ?? now, score < 100_000 else { return nil }
            return (score * Self.requestFactor(server) + 30) * steadiness
        }
    }

    /// The running tunnel pings its server every minute; those numbers feed
    /// the same history, so kxc keeps learning about the server in use.
    func record(latency ms: Int?, for id: UUID) {
        let now = DispatchTime.now()
        if let last = lastRecorded[id], now < last + 55 { return }
        lastRecorded[id] = now
        let sample: Float = ms.map(Float.init) ?? -1
        var series = (history[id] ?? []) + [sample]
        if series.count > Self.historyLimit { series.removeFirst(series.count - Self.historyLimit) }
        history[id] = series
        if let ms { results[id] = .ms(ms) }
        recordedSinceSave += 1
        if recordedSinceSave >= 5 {
            recordedSinceSave = 0
            save()
        }
    }

    /// A whole request takes a few round trips: an ICMP ping is one of
    /// them, a TLS handshake about two.
    private static func requestFactor(_ server: ProxyServer) -> Double {
        PingTarget(server: server).method == .icmp ? 3.5 : 2
    }

    /// Latency for sorting: working, measured servers first, fastest first.
    func sortKey(_ server: ProxyServer) -> Double {
        switch verdicts[server.id] {
        case .broken: return .infinity
        case .works(let ms): return Double(ms)
        case nil:
            guard case .ms(let ms) = results[server.id] else { return .infinity }
            return Double(ms) * Self.requestFactor(server)
        }
    }

    /// 0…1, how dependable the pings were; nil before any.
    func stability(_ id: UUID) -> Double? {
        guard let rtts = history[id], !rtts.isEmpty else { return nil }
        return ServerScoring.stability(rtts)
    }

    /// Forget a server's real check (its settings changed).
    func forget(_ id: UUID) {
        verdicts[id] = nil
        // Без `save()` вердикт жил только в памяти: «сбросить маскировку»
        // возвращался после перезапуска вместе с записанным блоком вердиктов,
        // а `broken` в нём значит «не искать этот выход» для `best(among:)`.
        save()
    }

    /// Drops everything remembered about servers that no longer exist. Both
    /// `history` and `verdicts` go to UserDefaults, and panels that re-issue
    /// their servers on every refresh leave the old keys behind forever.
    func forget(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        for id in ids {
            results[id] = nil
            verdicts[id] = nil
            history[id] = nil
            lastRecorded[id] = nil
        }
        save()
    }

    // MARK: - Recording

    private func record(_ sample: PingSample) {
        let rtts = sample.rtts.map { $0.map(Float.init) ?? -1 }
        var series = (history[sample.id] ?? []) + rtts
        if series.count > Self.historyLimit { series.removeFirst(series.count - Self.historyLimit) }
        history[sample.id] = series
        results[sample.id] = Self.summary(rtts[...])
    }

    private static func summary(_ rtts: ArraySlice<Float>) -> Result {
        let ok = rtts.filter { $0 >= 0 }
        guard !ok.isEmpty else { return .failed }
        return .ms(Int((ok.reduce(0, +) / Float(ok.count)).rounded()))
    }

    /// The engine's error, in a few words.
    private static func reason(_ error: String?) -> String {
        guard let error = error?.lowercased() else { return "не пропускает трафик" }
        if error.contains("timeout") || error.contains("deadline") { return "нет ответа через прокси" }
        if error.contains("eof") || error.contains("reset") || error.contains("closed") { return "сервер обрывает соединение" }
        if error.contains("certificate") || error.contains("x509") || error.contains("tls") { return "ошибка TLS" }
        if error.contains("адрес") { return "не удалось узнать адрес" }
        return "не пропускает трафик"
    }

    private func save() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: Self.historyKey)
        }
        if let data = try? JSONEncoder().encode(verdicts) {
            defaults.set(data, forKey: Self.verdictKey)
        }
    }
}
