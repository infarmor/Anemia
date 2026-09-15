import Foundation
import LoaderCore

/// Confirms the tunnel actually carries traffic by fetching a tiny 204 endpoint
/// through the local SOCKS proxy, and reports the real round-trip latency.
enum ProxyHealth {
    /// Probe endpoints, ordered by DNS dependency. IP-literal probes come
    /// first: SOCKS5 sends them as ATYP=IPv4, so xray routes them without
    /// issuing any DNS query — which matters early in a session when xray's
    /// proxied DoH is still warming up (the first few DoH round-trips can
    /// time out while the tunnel's outbound connection is being established,
    /// causing health misses even though the SOCKS proxy itself is working).
    /// Domain-based probes race alongside and win if DNS is already live.
    static let probeURLs: [URL] = [
        URL(string: "http://1.1.1.1/")!,      // Cloudflare DNS IP — no DNS, SOCKS ATYP=IPv4
        URL(string: "http://1.0.0.1/")!,      // Cloudflare alt IP  — no DNS, SOCKS ATYP=IPv4
        URL(string: "http://cp.cloudflare.com/generate_204")!,
        URL(string: "http://www.gstatic.com/generate_204")!
    ]

    static func check(socksPort: Int, timeout: TimeInterval = 6) async -> Int? {
        let session = URLSession(configuration: proxied(socksPort: socksPort, timeout: timeout))
        defer { session.invalidateAndCancel() }
        let start = DispatchTime.now()
        let probes = probeURLs.map { url in
            { @Sendable () async -> Int? in
                // URLSession's async API cancels the request with its task, so
                // the losing probe stops the moment the winner lands.
                guard let (_, resp) = try? await session.data(from: url),
                      let http = resp as? HTTPURLResponse, (200...399).contains(http.statusCode)
                else { return nil }
                return Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
            }
        }
        return await AsyncRace.firstNonNil(probes)
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
