import Foundation
import LoaderCore

/// Confirms the tunnel actually carries traffic by fetching a tiny endpoint
/// through the local SOCKS proxy, and reports the real round-trip latency.
enum ProxyHealth {
    /// HTTPS only: App Transport Security refuses plain-HTTP loads before they
    /// reach the proxy, so http:// probes never ran (only the HSTS-upgraded
    /// cp.cloudflare.com did). The IP-literal probes carry no hostname — SOCKS
    /// sends ATYP=IPv4 and they need no DNS at all (Cloudflare's 1.1.1.1
    /// certificate covers both addresses).
    static let probeURLs: [URL] = [
        URL(string: "https://1.1.1.1/cdn-cgi/trace")!,
        URL(string: "https://1.0.0.1/cdn-cgi/trace")!,
        URL(string: "https://cp.cloudflare.com/generate_204")!,
        URL(string: "https://www.gstatic.com/generate_204")!
    ]

    /// Round-trip latency in ms through the proxy, or why every probe failed.
    static func check(socksPort: Int, timeout: TimeInterval = 6) async -> (ms: Int?, failure: String?) {
        let session = URLSession(configuration: proxied(socksPort: socksPort, timeout: timeout))
        defer { session.invalidateAndCancel() }
        let start = DispatchTime.now()
        let failures = FailureLog()
        let probes = probeURLs.map { url in
            { @Sendable () async -> Int? in
                // URLSession's async API cancels the request with its task, so
                // the losing probe stops the moment the winner lands.
                do {
                    let (_, resp) = try await session.data(from: url)
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200...399).contains(status) else {
                        failures.record("\(url.host ?? "probe"): HTTP \(status)")
                        return nil
                    }
                    return Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
                } catch {
                    let code = (error as? URLError).map { " (\($0.code.rawValue))" } ?? ""
                    failures.record("\(url.host ?? "probe"): \(error.localizedDescription)\(code)")
                    return nil
                }
            }
        }
        let ms = await AsyncRace.firstNonNil(probes)
        return (ms, ms == nil ? failures.first : nil)
    }

    /// One-shot capacity probe: download `bytes` through the live SOCKS proxy
    /// and return the achieved throughput in **bytes/sec**, or nil on failure.
    /// Latency says how responsive a server is; this says how *fast* it is — a
    /// server can ping well yet be throttled to a trickle. Kept small (256 KB)
    /// and bounded so it barely costs the user any traffic.
    static func throughput(socksPort: Int, bytes: Int = 262_144, timeout: TimeInterval = 8) async -> Int64? {
        let session = URLSession(configuration: proxied(socksPort: socksPort, timeout: timeout))
        defer { session.invalidateAndCancel() }
        guard let url = URL(string: "https://speed.cloudflare.com/__down?bytes=\(bytes)") else { return nil }

        let start = DispatchTime.now()
        do {
            let (data, resp) = try await session.data(from: url)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  !data.isEmpty else { return nil }
            let secs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
            guard secs > 0 else { return nil }
            return Int64(Double(data.count) / secs)
        } catch {
            return nil
        }
    }

    private static func proxied(socksPort: Int, timeout: TimeInterval) -> URLSessionConfiguration {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.connectionProxyDictionary = [
            "SOCKSEnable": 1,
            "SOCKSProxy": "127.0.0.1",
            "SOCKSPort": socksPort
        ]
        return cfg
    }
}

/// Failures reported by concurrently running probes, first one kept for the log.
private final class FailureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var reasons: [String] = []

    func record(_ reason: String) {
        lock.lock()
        reasons.append(reason)
        lock.unlock()
    }

    var first: String? {
        lock.lock()
        defer { lock.unlock() }
        return reasons.first
    }
}
