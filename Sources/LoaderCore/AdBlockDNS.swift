import Foundation

/// AdGuard DNS: answers ad and tracker domains with nothing. "Без рекламы" /
/// "Block ads" in both apps.
public enum AdBlockDNS {
    public static let servers = ["94.140.14.14", "94.140.15.15"]
    public static let dohHost = "dns.adguard-dns.com"
    /// For the engine's DNS, through the proxy like the default resolvers.
    /// Pin ``dohHost`` to ``servers`` in the engine's hosts, so reaching it
    /// needs no other lookup.
    public static let remoteDNS = ["https://\(dohHost)/dns-query", servers[0]]
}

/// A local SOCKS5 proxy to send the app's own requests through — the Mac
/// engine's inbound, when the system tunnel isn't carrying the app.
public struct LocalProxy: Sendable, Equatable {
    public var host: String
    public var port: Int

    public init(host: String = "127.0.0.1", port: Int) {
        self.host = host
        self.port = port
    }

    /// An ephemeral configuration whose requests go through `proxy`; a plain
    /// ephemeral one without.
    public static func sessionConfiguration(_ proxy: LocalProxy?) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        if let proxy {
            // CFNetwork's keys (kCFNetworkProxiesSOCKS*), spelled out: the
            // constants exist on macOS only.
            configuration.connectionProxyDictionary = [
                "SOCKSEnable": 1,
                "SOCKSProxy": proxy.host,
                "SOCKSPort": proxy.port,
            ]
        }
        return configuration
    }
}
