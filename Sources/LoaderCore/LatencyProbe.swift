import Foundation
import Network
import Security

/// Measures real round-trip latency to a server by timing a full TLS handshake.
///
/// A plain TCP-connect "ping" is unreliable whenever a system-wide TUN proxy in
/// fake-IP mode is active (sing-box / clash / Mihomo and friends): the local
/// tunnel answers every TCP SYN itself, so `connect()` returns in well under a
/// millisecond and every server reads "0 ms". A TLS handshake cannot be faked
/// locally — the tunnel has to relay ClientHello/ServerHello to the real
/// endpoint — so its timing reflects the true network path. It also mirrors what
/// the proxy actually does when you browse: these are TLS/Reality servers on 443.
public enum LatencyProbe {

    /// Ping `count` times, returning each attempt's RTT in ms (nil =
    /// failed/timed-out attempt) for jitter/loss statistics.
    ///
    /// `tls` picks the probe: a full TLS handshake (the default, for TLS/Reality
    /// servers on 443) or a plain TCP connect (for `security: none` servers,
    /// which don't speak TLS — a handshake probe would always "fail" them and
    /// hide them from ranking/auto-pick). A TCP connect can read ~0 ms behind a
    /// system fake-IP TUN, but that beats never measuring the server at all.
    ///
    /// `sni` names the server the way the engine itself dials it
    /// (`server.sni ?? server.host`): for CDN/Reality entries the link address
    /// is an IP or fronting host, and probing with that as SNI gets the
    /// handshake rejected by the CDN — the server reads "dead" while working
    /// fine through the tunnel. Falls back to `host` when nil.
    ///
    /// `earlyAbortAfterFails`: stop probing after this many consecutive
    /// failed attempts. A dead server costs `count × timeout` otherwise —
    /// five 4 s timeouts apiece — and with many down servers in a
    /// subscription the round spent most of its wall clock waiting on
    /// servers that were never going to answer. Reachable servers are
    /// unaffected (a success resets the failure streak).
    public static func sample(
        host: String, port: Int, sni: String? = nil, count: Int = 5, timeout: TimeInterval = 4,
        tls: Bool = true, earlyAbortAfterFails: Int? = nil
    ) async -> [Int?] {
        await collect(count: count, earlyAbortAfterFails: earlyAbortAfterFails) { _ in
            await handshakePing(host: host, port: port, sni: sni, timeout: timeout, tls: tls)
        }
    }

    /// The bookkeeping of a round, apart from the network: how results
    /// accumulate and when a round gives up on a dead server. Pure, so the
    /// Android port can be compared against it without a live endpoint.
    public static func collect(
        count: Int, earlyAbortAfterFails: Int?, attempt: @Sendable (Int) async -> Int?
    ) async -> [Int?] {
        var results: [Int?] = []
        var consecutiveFails = 0
        for index in 0..<max(1, count) {
            if Task.isCancelled { break }
            let r = await attempt(index)
            results.append(r)
            if r == nil {
                consecutiveFails += 1
                if let limit = earlyAbortAfterFails, consecutiveFails >= limit { break }
            } else {
                consecutiveFails = 0
            }
        }
        return results
    }

    /// What one probe should dial: whether the arguments are usable at all, and
    /// the TLS server name to present (nil = omit the extension).
    ///
    /// SNI is defined as a DNS name, and several servers hard-fail a handshake
    /// that presents an IP literal, so a literal address — or an SNI that is one
    /// — sends no server name at all.
    public static func target(host: String, port: Int, sni: String?, tls: Bool)
        -> (usable: Bool, port: Int, serverName: String?, tls: Bool) {
        guard !host.isEmpty, port > 0, port <= 65_535 else {
            return (false, port, nil, tls)
        }
        let sniName = sni ?? host
        let name = (!sniName.isEmpty && !DirectResolver.isIPv4(sniName) && !sniName.contains(":"))
            ? sniName : nil
        return (true, port, name, tls)
    }

    /// One handshake/connect RTT in milliseconds, or nil on failure/timeout.
    /// `tls == true` times a full TLS handshake; `false` times a TCP connect.
    public static func handshakePing(host: String, port: Int, sni: String? = nil,
                                     timeout: TimeInterval = 4, tls: Bool = true) async -> Int? {
        // A cancelled round must stop spending its timeout budget: without
        // this check every queued server still burns its full 4 s slot (×5,
        // ×100 dead servers) after the user has moved on.
        guard !Task.isCancelled else { return nil }
        let dial = target(host: host, port: port, sni: sni, tls: tls)
        guard dial.usable, let nwPort = NWEndpoint.Port(rawValue: UInt16(dial.port)) else { return nil }

        let parameters: NWParameters
        if dial.tls {
            let tlsOptions = NWProtocolTLS.Options()
            let sec = tlsOptions.securityProtocolOptions
            // SNI so Reality/TLS servers steer the handshake to the right site.
            if let name = dial.serverName {
                name.withCString { sec_protocol_options_set_tls_server_name(sec, $0) }
            }
            // No session resumption: every probe is a full handshake, so repeated
            // samples measure the same thing (comparable jitter, no 0-RTT skew).
            sec_protocol_options_set_tls_resumption_enabled(sec, false)
            // We only time the handshake — accept any certificate. These endpoints
            // present camouflage/self-signed certs; validation isn't the point, and
            // a rejection would just cost us the measurement.
            sec_protocol_options_set_verify_block(sec, { _, _, complete in complete(true) },
                                                  DispatchQueue.global(qos: .userInitiated))
            parameters = NWParameters(tls: tlsOptions)
        } else {
            // Plain TCP connect: for non-TLS servers (shadowsocks, vmess/vless
            // without TLS) `.ready` fires on the completed TCP handshake.
            parameters = NWParameters(tls: nil)
        }

        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort,
                                using: parameters)

        return await withCheckedContinuation { (cont: CheckedContinuation<Int?, Never>) in
            let probe = HandshakeProbe(connection: conn, continuation: cont)
            let queue = DispatchQueue(label: "LatencyProbe.tls")
            let start = DispatchTime.now()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:   // TLS established — the handshake round-trip is done.
                    let ms = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
                    probe.finish(ms)
                case .failed, .cancelled:
                    probe.finish(nil)
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { probe.finish(nil) }
        }
    }
}

/// Guarantees the continuation resumes exactly once and the connection is torn
/// down, whether the handshake succeeds, fails, or times out. `CheckedContinuation`
/// traps on a double-resume, so the one-shot latch is load-bearing.
private final class HandshakeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let connection: NWConnection
    private let continuation: CheckedContinuation<Int?, Never>

    init(connection: NWConnection, continuation: CheckedContinuation<Int?, Never>) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(_ value: Int?) {
        lock.lock()
        if done { lock.unlock(); return }
        done = true
        lock.unlock()
        // Break the retain cycle (connection → stateUpdateHandler closure →
        // probe → connection) before cancelling: nothing ever nils the
        // handler otherwise, so every probe leaks its NWConnection and its
        // dispatch queue — hundreds per ping round on a large subscription,
        // monotonically for the app's lifetime.
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(returning: value)
    }
}
