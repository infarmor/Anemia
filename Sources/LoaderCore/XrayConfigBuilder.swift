import Foundation

/// Builds an Xray-core JSON configuration from a ``ProxyServer`` plus
/// ``AntiCensorshipOptions``.
///
/// The generated config exposes local SOCKS + HTTP inbounds (which the utun
/// tun2socks bridge and system-proxy paths dial into) and a single "proxy"
/// outbound to the selected server. Anti-DPI features are layered on natively:
///
///  * `fragment` → a `freedom` outbound used as `dialerProxy` that shreds the
///    TLS ClientHello so SNI-based DPI can't classify the handshake.
///  * `noises`   → junk packets emitted before real data (`sockopt.noises`).
///  * `mux`      → connection multiplexing with padding (skipped under
///    XTLS-Vision, which is faster unmuxed).
public struct XrayConfigBuilder {
    public var socksPort: Int
    public var httpPort: Int
    public var listen: String
    public var logLevel: String
    public var enableSniffing: Bool
    /// Local Xray Stats API port (dokodemo-door). Nil disables traffic stats.
    public var apiPort: Int?
    /// Remote DNS resolvers, queried through the proxy to avoid DNS leaks.
    public var remoteDNS: [String]

    public init(
        socksPort: Int = 10808,
        httpPort: Int = 10809,
        listen: String = "127.0.0.1",
        logLevel: String = "warning",
        enableSniffing: Bool = true,
        apiPort: Int? = 10812,
        remoteDNS: [String] = ["https://1.1.1.1/dns-query", "1.1.1.1"]
    ) {
        self.socksPort = socksPort
        self.httpPort = httpPort
        self.listen = listen
        self.logLevel = logLevel
        self.enableSniffing = enableSniffing
        self.apiPort = apiPort
        self.remoteDNS = remoteDNS
    }

    /// Build the full config as a JSON-serializable dictionary.
    public func makeConfig(server: ProxyServer, anti: AntiCensorshipOptions = .recommended) -> [String: Any] {
        var outbounds: [[String: Any]] = []

        // --- Fragment dialer (optional) ---------------------------------
        // When fragmentation is on, the physical socket is opened by this
        // freedom outbound, so junk-noise + TFO sockopts live here.
        let useFragment = anti.fragment != nil
        if let frag = anti.fragment {
            var fragmentOutbound: [String: Any] = [
                "tag": "fragment",
                "protocol": "freedom",
                "settings": [
                    "domainStrategy": "AsIs",
                    "fragment": [
                        "packets": frag.packets,
                        "length": frag.length,
                        "interval": frag.interval
                    ]
                ]
            ]
            if let sockopt = makeSockopt(anti: anti, dialerProxy: nil) {
                fragmentOutbound["streamSettings"] = ["sockopt": sockopt]
            }
            outbounds.append(fragmentOutbound)
        }

        // --- Main proxy outbound ---------------------------------------
        outbounds.insert(makeProxyOutbound(server: server, anti: anti, useFragment: useFragment), at: 0)

        // --- Direct + block --------------------------------------------
        outbounds.append(["tag": "direct", "protocol": "freedom", "settings": ["domainStrategy": "UseIP"]])
        outbounds.append(["tag": "block", "protocol": "blackhole", "settings": [:] as [String: Any]])

        // --- Inbounds ---------------------------------------------------
        var socksIn: [String: Any] = [
            "tag": "socks-in",
            "protocol": "socks",
            "listen": listen,
            "port": socksPort,
            "settings": ["udp": true, "auth": "noauth"]
        ]
        var httpIn: [String: Any] = [
            "tag": "http-in",
            "protocol": "http",
            "listen": listen,
            "port": httpPort
        ]
        if enableSniffing {
            let sniff: [String: Any] = ["enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": false]
            socksIn["sniffing"] = sniff
            httpIn["sniffing"] = sniff
        }

        var inbounds: [[String: Any]] = [socksIn, httpIn]
        // Local Stats API inbound (dokodemo-door), used to poll live traffic.
        if let apiPort {
            inbounds.append([
                "tag": "api-in",
                "protocol": "dokodemo-door",
                "listen": "127.0.0.1",
                "port": apiPort,
                "settings": ["address": "127.0.0.1"]
            ])
        }

        // --- Routing ----------------------------------------------------
        // Keep LAN / loopback traffic off the proxy using explicit private
        // CIDRs, so no external geoip.dat/geosite.dat assets are required.
        let privateCIDRs = [
            "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
            "172.16.0.0/12", "192.168.0.0/16",
            "::1/128", "fc00::/7", "fe80::/10"
        ]
        var rules: [[String: Any]] = []
        if apiPort != nil {
            // Dispatch the API inbound to the built-in API handler.
            rules.append(["type": "field", "inboundTag": ["api-in"], "outboundTag": "api"])
        }
        rules.append(["type": "field", "outboundTag": "direct", "ip": privateCIDRs])
        let routing: [String: Any] = ["domainStrategy": "AsIs", "rules": rules]

        // --- DNS (anti-leak): resolve names remotely through the proxy ---
        let dns: [String: Any] = [
            "servers": remoteDNS,
            "queryStrategy": "UseIP"
        ]

        var config: [String: Any] = [
            "log": ["loglevel": logLevel],
            "dns": dns,
            "inbounds": inbounds,
            "outbounds": outbounds,
            "routing": routing
        ]

        // --- Stats API wiring -------------------------------------------
        if apiPort != nil {
            config["api"] = ["tag": "api", "services": ["StatsService"]]
            config["stats"] = [:] as [String: Any]
            config["policy"] = [
                "system": [
                    "statsInboundUplink": true, "statsInboundDownlink": true,
                    "statsOutboundUplink": true, "statsOutboundDownlink": true
                ]
            ]
        }

        return config
    }

    /// Serialize the config to pretty-printed JSON data (stable key order).
    public func makeConfigData(server: ProxyServer, anti: AntiCensorshipOptions = .recommended) throws -> Data {
        let config = makeConfig(server: server, anti: anti)
        return try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
    }

    public func makeConfigString(server: ProxyServer, anti: AntiCensorshipOptions = .recommended) throws -> String {
        String(data: try makeConfigData(server: server, anti: anti), encoding: .utf8) ?? ""
    }

    // MARK: - Outbound assembly

    private func makeProxyOutbound(server: ProxyServer, anti: AntiCensorshipOptions, useFragment: Bool) -> [String: Any] {
        var outbound: [String: Any] = [
            "tag": "proxy",
            "protocol": server.proto.xrayProtocolName,
            "settings": makeProxySettings(server)
        ]

        outbound["streamSettings"] = makeStreamSettings(server, anti: anti, useFragment: useFragment)

        // Mux with padding — but not with XTLS-Vision (incompatible + slower).
        let isVision = (server.flow ?? "").contains("vision")
        if anti.muxEnabled && !isVision {
            outbound["mux"] = [
                "enabled": true,
                "concurrency": anti.muxConcurrency,
                "xudpConcurrency": 8,
                "xudpProxyUDP443": "reject"
            ]
        }
        return outbound
    }

    private func makeProxySettings(_ server: ProxyServer) -> [String: Any] {
        switch server.proto {
        case .vless:
            var user: [String: Any] = ["id": server.credential, "encryption": "none", "level": 0]
            if let flow = server.flow, !flow.isEmpty { user["flow"] = flow }
            return ["vnext": [["address": server.address, "port": server.port, "users": [user]]]]

        case .vmess:
            let user: [String: Any] = [
                "id": server.credential,
                "alterId": server.alterId,
                "security": "auto",
                "level": 0
            ]
            return ["vnext": [["address": server.address, "port": server.port, "users": [user]]]]

        case .trojan:
            var srv: [String: Any] = ["address": server.address, "port": server.port, "password": server.credential, "level": 0]
            if let flow = server.flow, !flow.isEmpty { srv["flow"] = flow }
            return ["servers": [srv]]

        case .shadowsocks:
            let srv: [String: Any] = [
                "address": server.address,
                "port": server.port,
                "method": server.method ?? "aes-256-gcm",
                "password": server.credential,
                "uot": true,
                "level": 0
            ]
            return ["servers": [srv]]
        }
    }

    private func makeStreamSettings(_ server: ProxyServer, anti: AntiCensorshipOptions, useFragment: Bool) -> [String: Any] {
        var stream: [String: Any] = ["network": server.network.rawValue]

        // Security layer.
        switch server.security {
        case .reality:
            stream["security"] = "reality"
            var reality: [String: Any] = [:]
            if let sni = server.sni { reality["serverName"] = sni }
            reality["fingerprint"] = server.fingerprint ?? anti.fingerprint
            if let pbk = server.realityPublicKey { reality["publicKey"] = pbk }
            if let sid = server.realityShortId { reality["shortId"] = sid }
            if let spx = server.realitySpiderX { reality["spiderX"] = spx }
            stream["realitySettings"] = reality
        case .tls, .xtls:
            stream["security"] = "tls"
            var tls: [String: Any] = ["allowInsecure": server.allowInsecure]
            if let sni = server.sni { tls["serverName"] = sni }
            if !server.alpn.isEmpty { tls["alpn"] = server.alpn }
            tls["fingerprint"] = server.fingerprint ?? anti.fingerprint
            stream["tlsSettings"] = tls
        case .none:
            stream["security"] = "none"
        }

        // Transport-specific settings.
        switch server.network {
        case .ws:
            var ws: [String: Any] = [:]
            if let path = server.path { ws["path"] = path }
            if let host = server.host { ws["headers"] = ["Host": host] }
            stream["wsSettings"] = ws
        case .httpupgrade:
            var hu: [String: Any] = [:]
            if let path = server.path { hu["path"] = path }
            if let host = server.host { hu["host"] = host }
            stream["httpupgradeSettings"] = hu
        case .grpc:
            var grpc: [String: Any] = [:]
            if let name = server.path { grpc["serviceName"] = name }
            stream["grpcSettings"] = grpc
        case .http:
            var h2: [String: Any] = [:]
            if let path = server.path { h2["path"] = path }
            if let host = server.host { h2["host"] = [host] }
            stream["httpSettings"] = h2
        case .tcp:
            if let headerType = server.headerType, headerType == "http" {
                stream["tcpSettings"] = ["header": ["type": "http"]]
            }
        case .kcp:
            var kcp: [String: Any] = ["seed": server.path ?? ""]
            if let headerType = server.headerType { kcp["header"] = ["type": headerType] }
            stream["kcpSettings"] = kcp
        case .quic:
            break
        }

        // Socket options: when fragmenting, the fragment outbound owns the
        // physical socket (TFO/noises), and we only chain to it here.
        if useFragment {
            stream["sockopt"] = ["dialerProxy": "fragment"]
        } else if let sockopt = makeSockopt(anti: anti, dialerProxy: nil) {
            stream["sockopt"] = sockopt
        }

        return stream
    }

    private func makeSockopt(anti: AntiCensorshipOptions, dialerProxy: String?) -> [String: Any]? {
        var sockopt: [String: Any] = [:]
        if anti.tcpFastOpen { sockopt["tcpFastOpen"] = true }
        if !anti.noises.isEmpty {
            sockopt["noises"] = anti.noises.map { noise in
                ["type": noise.type, "packet": noise.packet, "delay": noise.delay] as [String: Any]
            }
        }
        if let dialerProxy { sockopt["dialerProxy"] = dialerProxy }
        return sockopt.isEmpty ? nil : sockopt
    }
}
