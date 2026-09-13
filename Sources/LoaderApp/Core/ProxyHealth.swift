import Foundation

/// Confirms the tunnel actually carries traffic by fetching a tiny 204 endpoint
/// through the local SOCKS proxy, and reports the real round-trip latency.
enum ProxyHealth {
    static func check(socksPort: Int, timeout: TimeInterval = 6) async -> Int? {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.connectionProxyDictionary = [
            "SOCKSEnable": 1,
            "SOCKSProxy": "127.0.0.1",
            "SOCKSPort": socksPort
        ]
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }
        guard let url = URL(string: "http://cp.cloudflare.com/generate_204") else { return nil }

        let start = DispatchTime.now()
        do {
            let (_, resp) = try await session.data(from: url)
            guard let http = resp as? HTTPURLResponse, (200...399).contains(http.statusCode) else { return nil }
            return Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        } catch {
            return nil
        }
    }

    /// One-shot capacity probe: download `bytes` through the live SOCKS proxy
    /// and return the achieved throughput in **bytes/sec**, or nil on failure.
    /// Latency says how responsive a server is; this says how *fast* it is — a
    /// server can ping well yet be throttled to a trickle. Kept small (256 KB)
    /// and bounded so it barely costs the user any traffic.
    static func throughput(socksPort: Int, bytes: Int = 262_144, timeout: TimeInterval = 8) async -> Int64? {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.connectionProxyDictionary = [
            "SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": socksPort
        ]
        let session = URLSession(configuration: cfg)
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
}
