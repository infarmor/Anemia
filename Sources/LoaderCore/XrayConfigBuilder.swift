import Foundation

/// A profile the bundled engine (Xray-core 26.x) cannot run.
public enum ConfigBuilderError: Error, LocalizedError, Equatable, Sendable {
    /// HTTP/2 (`h2`) and QUIC stream transports were removed from
    /// Xray-core in the 26.x line; the config would be rejected (or worse,
    /// silently dial plain TCP) at engine start.
    case transportRemovedByEngine(String)
    /// A Reality link without `pbk=` can never handshake: the engine has no
    /// server public key to authenticate against, so the dial fails after a
    /// confusing delay. Caught at build time with an actionable message.
    case realityMissingPublicKey
    /// WireGuard-family servers must never reach the Xray config: Xray's
    /// wireguard outbound speaks only the plain handshake and would silently
    /// strip every AmneziaWG obfuscation parameter.
    case wireGuardNotOnXray(String)
    /// A hysteria outbound needs the local SOCKS bridge port the hysteria
    /// engine picked at start (`userData["hySocksPort"]`). Without it the
    /// config would route into a port nobody listens on.
    case hysteriaBridgeMissing

    public var errorDescription: String? {
        switch self {
        case .transportRemovedByEngine(let name):
            return "Transport '\(name)' is no longer supported by the bundled Xray-core (removed in 26.x). Ask the provider for a ws/grpc/tcp variant of this server."
        case .realityMissingPublicKey:
            return "This Reality server carries no public key (pbk=) — the handshake cannot authenticate. Re-import the share link from the panel so it includes the key."
        case .wireGuardNotOnXray(let proto):
            return "\(proto) servers run on the AmneziaWG engine, not Xray."
        case .hysteriaBridgeMissing:
            return "Hysteria engine is not running — no local bridge port to route through."
        }
    }
}

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
    /// Static `dns.hosts` entries (domain → IP), pinned into the engine's DNS
    /// config. The essential one is the VPN server's own domain: after the
    /// app points the system resolver at the tunnel, any lookup of the
    /// server's domain would travel into the tunnel → engine → DoH through
    /// the proxy → and to reach the proxy the engine must resolve that same
    /// domain — a loop that stalls until every TTL expires (the "connected,
    /// then everything dies after ~30 s" failure). A hosts entry answers it
    /// locally and instantly, engine dials included.
    public var dnsHosts: [String: String] = [:]
    /// Drop QUIC (UDP/443) so browsers fall back to HTTP/2 over TCP — the path
    /// Reality/XTLS-Vision actually secure. QUIC over a proxy is frequently
    /// throttled or reset by DPI and, being UDP, benefits from none of the TCP
    /// obfuscation; forcing TCP is a standard reliability win for circumvention.
    /// LAN UDP/443 still goes direct (matched by the private-CIDR rule first).
    public var blockQUIC: Bool
    /// Answer tunneled DNS (any :53, UDP or TCP) inside the engine via the
    /// built-in `dns` outbound, resolving with `remoteDNS` (DoH through the
    /// proxy). The app points the macOS system resolver at the tunnel's
    /// gateway address, so system lookups enter the utun → tun2socks → SOCKS
    /// UDP → engine: poisoned answers from the ISP resolver become impossible
    /// while the tunnel is up (the main reason blocked apps "fall" otherwise).
    public var hijackDNS: Bool
    /// Per-connection copy-buffer (KB) in the engine's connection policy. A
    /// larger buffer means fewer syscalls per byte on bulk transfers over a
    /// high-BDP path (pairs with the utun's 8500 MTU + tun2socks TCP
    /// auto-tuning). 0 lets the core auto-size it (unbounded — most throughput,
    /// most memory).
    public var bufferSizeKB: Int
    /// Physical interface (e.g. "en0") the engine's server connection is pinned
    /// to via `sockopt.interface` (IP_BOUND_IF). Without this pin, whenever a
    /// TUN holds the default route (our own tunnel during a reconnect race, or
    /// a third-party VPN like a sing-box client on 198.18.0.1), the engine's
    /// dial is swallowed by that TUN — its fragmented ClientHello loops back
    /// into the tunnel and dies with RST / dial errors. Detection happens in
    /// the app before engine start; nil disables the pin.
    public var dialerInterface: String?

    public init(
        socksPort: Int = 10808,
        httpPort: Int = 10809,
        listen: String = "127.0.0.1",
        logLevel: String = "warning",
        enableSniffing: Bool = true,
        apiPort: Int? = 10812,
        remoteDNS: [String] = ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query", "1.1.1.1"],
        dialerInterface: String? = nil,
        blockQUIC: Bool = true,
        hijackDNS: Bool = true,
        bufferSizeKB: Int = 512
    ) {
        self.socksPort = socksPort
        self.httpPort = httpPort
        self.listen = listen
        self.logLevel = logLevel
        self.enableSniffing = enableSniffing
        self.apiPort = apiPort
        self.remoteDNS = remoteDNS
        self.dialerInterface = dialerInterface
        self.blockQUIC = blockQUIC
        self.hijackDNS = hijackDNS
        self.bufferSizeKB = bufferSizeKB
    }

    /// Build the full config as a JSON-serializable dictionary.
    /// Throws for WireGuard-family servers (see `makeProxyOutbound`).
    public func makeConfig(server: ProxyServer, anti: AntiCensorshipOptions = .recommended) throws -> [String: Any] {
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
        outbounds.insert(try makeProxyOutbound(server: server, anti: anti, useFragment: useFragment), at: 0)

        // --- Direct + block --------------------------------------------
        outbounds.append(["tag": "direct", "protocol": "freedom", "settings": ["domainStrategy": "UseIP"]])
        outbounds.append(["tag": "block", "protocol": "blackhole", "settings": [:] as [String: Any]])
        // Built-in DNS outbound: answers hijacked :53 traffic with the
        // configured (proxied DoH) resolvers.
        if hijackDNS {
            outbounds.append(["tag": "dns-out", "protocol": "dns", "settings": [:] as [String: Any]])
        }

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
        // Hijack tunneled DNS FIRST: the system resolver (and any app that
        // hardcodes :53) must be answered by the engine through proxied DoH —
        // before the LAN-direct rule can hand those queries to the physical
        // network, where ISP DPI poisons them.
        // Restricted to the tunnel inbounds: an unrestricted `port: 53` would
        // also catch the DNS module's OWN queries to the plain fallback
        // resolver ("1.1.1.1") and route them back into the `dns` outbound —
        // a query answering itself with a query, forever.
        if hijackDNS {
            rules.append(["type": "field", "inboundTag": ["socks-in", "http-in"],
                          "port": 53, "outboundTag": "dns-out"])
        }
        // Link-local / LAN-name lookups (mDNS ".local", router ".lan",
        // ".home.arpa", ".internal") must be answered on the physical network:
        // a proxied lookup reaches a resolver that has never heard of those
        // names and the LAN host stays unreachable until the tunnel drops.
        // Matched before the private-CIDR rule because the name, not the
        // (often unknown) IP, is what identifies the destination.
        rules.append(["type": "field", "outboundTag": "direct",
                      "domain": ["domain:local", "domain:lan", "domain:home.arpa", "domain:internal"]])
        // LAN / loopback next, so local UDP/443 (and everything private) still
        // goes direct even with the QUIC block below.
        rules.append(["type": "field", "outboundTag": "direct", "ip": privateCIDRs])
        // Multicast + subnet broadcast can't traverse a SOCKS-backed tunnel:
        // handing them to the engine just burns its worker on a dial that can
        // never connect (mDNS discovery, SSDP, SMB announcements...). Block
        // them outright — apps time out on these either way, but the engine
        // stays quiet.
        rules.append(["type": "field", "outboundTag": "block",
                      "ip": ["224.0.0.0/4", "255.255.255.255/32", "ff00::/8"]])
        // Drop QUIC (UDP/443) → browsers retry over HTTP/2/TCP through the proxy.
        if blockQUIC {
            rules.append(["type": "field", "outboundTag": "block", "network": "udp", "port": 443])
        }
        let routing: [String: Any] = ["domainStrategy": "AsIs", "rules": rules]

        // --- DNS (anti-leak): resolve names remotely through the proxy ---
        // Caching is explicit (default-on) so repeated lookups don't pay a fresh
        // DoH round-trip on every new connection.
        var dns: [String: Any] = [
            "servers": remoteDNS,
            "queryStrategy": "UseIP",
            "disableCache": false
        ]
        if !dnsHosts.isEmpty {
            dns["hosts"] = dnsHosts
        }

        var config: [String: Any] = [
            "log": ["loglevel": logLevel],
            "dns": dns,
            "inbounds": inbounds,
            "outbounds": outbounds,
            "routing": routing
        ]

        // --- Connection policy (throughput + resource tuning) -----------
        // level 0 governs every proxied connection:
        //  * bufferSize 512 KB — a larger per-connection copy buffer means
        //    fewer read/write syscalls per byte on bulk transfers over a
        //    high-BDP path (pairs with the utun's 8500 MTU + tun2socks TCP
        //    auto-tuning). The core's default is small and syscall-bound.
        //  * connIdle 300 s — reclaim genuinely idle connections instead of
        //    holding sockets (and NAT mappings) open indefinitely.
        //  * handshake 4 s — fail a dead upstream fast so the app's health
        //    loop can reconnect, rather than hanging a new connection.
        var policy: [String: Any] = [
            "levels": ["0": ["handshake": 4, "connIdle": 300, "bufferSize": bufferSizeKB]]
        ]

        // --- Stats API wiring -------------------------------------------
        if apiPort != nil {
            config["api"] = ["tag": "api", "services": ["StatsService"]]
            config["stats"] = [:] as [String: Any]
            policy["system"] = [
                "statsInboundUplink": true, "statsInboundDownlink": true,
                "statsOutboundUplink": true, "statsOutboundDownlink": true
            ]
        }
        config["policy"] = policy

        return config
    }

    /// Serialize the config to pretty-printed JSON data (stable key order).
    public func makeConfigData(server: ProxyServer, anti: AntiCensorshipOptions = .recommended) throws -> Data {
        // Fail before serializing anything the engine can't run: 26.x removed
        // the HTTP/2 and QUIC stream transports, and a config carrying them
        // dies at engine start with a cryptic core-side message (or worse,
        // silently dials plain TCP). Better one clear, actionable error here.
        switch server.network {
        case .http, .quic:
            throw ConfigBuilderError.transportRemovedByEngine(server.network.rawValue)
        default:
            break
        }
        // A Reality link without the server's public key authenticates against
        // nothing — the dial would fail (or worse, fall to a MITM-able path)
        // only after the user waits for a timeout. Fail here, with the fix.
        if server.security == .reality, server.realityPublicKey == nil {
            throw ConfigBuilderError.realityMissingPublicKey
        }
        let config = try makeConfig(server: server, anti: anti)
        return try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
    }

    public func makeConfigString(server: ProxyServer, anti: AntiCensorshipOptions = .recommended) throws -> String {
        String(data: try makeConfigData(server: server, anti: anti), encoding: .utf8) ?? ""
    }

    // MARK: - Outbound assembly

    /// FNV-1a over the UTF-8 bytes — `String.hashValue` is seeded per process,
    /// so a pick derived from it would reshuffle on every app launch. This one
    /// is stable across launches and machines.
    static func stableHash(_ s: String) -> Int {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        // Non-negative fold: the only use is `hash % count` as a stable pool
        // pick, and Swift's `%` keeps the dividend's sign — a negative fold
        // produced a negative index and crashed the config builder (Index out
        // of range) for every server whose identity hashed sign-bit-set.
        // Masking the sign bit keeps the mapping stable and in-bounds.
        return Int(truncatingIfNeeded: h & 0x7FFF_FFFF_FFFF_FFFF)
    }

    private func makeProxyOutbound(server: ProxyServer, anti: AntiCensorshipOptions, useFragment: Bool) throws -> [String: Any] {
        // Xray-core's wireguard outbound speaks the plain WireGuard handshake
        // only — it cannot carry the AmneziaWG junk/padding/header parameters,
        // so emitting one would silently strip every obfuscation setting and
        // drop all traffic on an AWG server. These protos are supervised by
        // the separate amneziawg-go engine; reaching this builder means the
        // caller misrouted the server.
        guard !server.proto.isWireGuardFamily else {
            throw ConfigBuilderError.wireGuardNotOnXray(server.proto.rawValue)
        }
        // Hysteria speaks QUIC with its own framing — nothing xray can dial.
        // The dedicated hysteria engine owns the wire and serves a local
        // SOCKS5 bridge; this outbound is a plain socks dial into that
        // bridge. No streamSettings (no network layer to configure) and no
        // mux (the bridge is loopback — multiplexing buys nothing).
        if server.proto.isHysteriaFamily {
            guard let portStr = server.userData?["hySocksPort"], let bridgePort = Int(portStr),
                  (1...65535).contains(bridgePort) else {
                throw ConfigBuilderError.hysteriaBridgeMissing
            }
            return [
                "tag": "proxy",
                "protocol": "socks",
                "settings": ["servers": [["address": "127.0.0.1", "port": bridgePort]]]
            ]
        }
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
                // Honor the link's `scy` (v2rayN "security"): a panel set to
                // `zero` or a fixed AEAD cipher rejects the client's `auto`
                // pick during negotiation. Nil → engine default.
                "security": server.vmessCipher ?? "auto",
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

        case .hysteria, .hysteria2, .amnezia, .wireguard:
            // Unreachable: makeProxyOutbound handles the hysteria family via
            // its local socks bridge and rejects the WG family outright
            // before this switch runs.
            return [:]
        }
    }

    private func makeStreamSettings(_ server: ProxyServer, anti: AntiCensorshipOptions, useFragment: Bool) -> [String: Any] {
        var stream: [String: Any] = ["network": server.network.rawValue]

        // Stealth SNI: an explicit link SNI always wins. Otherwise borrow a
        // host from the anti-DPI mimicry pool (TSPU whitelist evasion) — but
        // only where a mismatched serverName is safe, i.e. Reality
        // (camouflage SNI is the whole point). For a TLS server the cert is
        // always name-validated now — Xray-core 26.x removed `allowInsecure`,
        // so a borrowed SNI would fail validation and break the handshake;
        // leave the name unset and let xray default it to the server address.
        // The pick is stable per server (hashed off its identity, not
        // randomElement) so a reconnect keeps the same camouflage host — a
        // flapping SNI across reconnects is itself a DPI correlation signal,
        // and it also keeps engine config + stats keys stable across the
        // recovery ladder's rapid restarts.
        let mimicrySNI = anti.mimicry.isEmpty
            ? nil
            : anti.mimicry[Self.stableHash(server.identityKey) % anti.mimicry.count]
        // RU-service fingerprint aliases collapse onto real uTLS IDs here, so
        // xray never sees a name it doesn't know.
        let effectiveFingerprint =
            AntiCensorshipOptions.utlsFingerprint(server.fingerprint ?? anti.fingerprint)

        // Security layer.
        switch server.security {
        case .reality:
            stream["security"] = "reality"
            var reality: [String: Any] = ["show": false]
            if let sni = server.sni ?? mimicrySNI { reality["serverName"] = sni }
            reality["fingerprint"] = effectiveFingerprint
            if let pbk = server.realityPublicKey { reality["publicKey"] = pbk }
            if let sid = server.realityShortId { reality["shortId"] = sid }
            // The link may pin the camouflage ALPN (e.g. h2-only or
            // http/1.1-only Reality); without it the engine defaults to
            // [h2, http/1.1] and the TLS handshake fails on ALPN mismatch.
            if !server.alpn.isEmpty { reality["alpn"] = server.alpn }
            // spiderX is the path the Reality client "crawls" on the camouflage
            // site; default to root so a link that omits it still handshakes.
            reality["spiderX"] = server.realitySpiderX ?? "/"
            stream["realitySettings"] = reality
        case .tls, .xtls:
            stream["security"] = "tls"
            // NOTE: `allowInsecure` is deliberately NOT emitted. Xray-core 26.x
            // removed the option entirely — `true` is a fatal config error and
            // certificate validation can no longer be skipped at all. The
            // flag lives on in ProxyServer purely so links and old saved
            // state still parse.
            var tls: [String: Any] = [:]
            // CDN links routinely carry no `sni`, only `host` — the domain
            // fronting the origin (`vless://uuid@IP:443?security=tls&host=
            // cdn.example.com`). Falling back to the address (an IP) as SNI
            // gets the handshake cut by the CDN; `host` is the serverName
            // the panel meant (same fallback v2rayN applies).
            if let sni = server.sni ?? server.host { tls["serverName"] = sni }
            if !server.alpn.isEmpty { tls["alpn"] = server.alpn }
            tls["fingerprint"] = effectiveFingerprint
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
            // `:authority` from the link (its `host` param) and the
            // multiplexing mode — dropping either silently broke gRPC
            // servers that actually rely on them.
            if let authority = server.host, !authority.isEmpty { grpc["authority"] = authority }
            if server.grpcMultiMode == true { grpc["multiMode"] = true }
            stream["grpcSettings"] = grpc
        case .http:
            // Unreachable from makeConfigData (rejected there); kept so
            // makeConfig stays total for direct dictionary inspection.
            var h2: [String: Any] = [:]
            if let path = server.path { h2["path"] = path }
            if let host = server.host { h2["host"] = [host] }
            stream["httpSettings"] = h2
        case .tcp:
            if let headerType = server.headerType, headerType == "http" {
                // Full http-obfuscation request: with `request` absent, Xray
                // substitutes a bare default and the link's path/Host are
                // lost — emit them explicitly.
                stream["tcpSettings"] = ["header": [
                    "type": "http",
                    "request": [
                        "version": "1.1",
                        "method": "GET",
                        "path": [server.path ?? "/"],
                        "headers": ["Host": [server.host ?? server.address]]
                    ] as [String: Any]
                ] as [String: Any]]
            }
        case .kcp:
            // mKCP still exists, but 26.x removed both `seed` and `header`
            // obfuscation from kcpSettings — emitting either is a config
            // error. Plain tunable settings only; the defaults are fine.
            stream["kcpSettings"] = [:] as [String: Any]
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
        var sockopt: [String: Any] = [
            // Interactive latency: don't let Nagle coalesce the small, fragmented
            // ClientHello writes we rely on for DPI evasion.
            "tcpNoDelay": true,
            // Keep the NAT mapping warm and notice a silently-dropped tunnel
            // faster (pairs with the app-side health check + auto-reconnect).
            // NOTE: xray's Darwin sockopt code applies Idle/Interval swapped
            // (tcpKeepAliveIdle drives TCP_KEEPINTVL and vice versa), so emit
            // BOTH — a lone Idle leaves a zero write on the idle option.
            "tcpKeepAliveIdle": 30,
            "tcpKeepAliveInterval": 10
        ]
        // tcpFastOpen (`anti.tcpFastOpen`) is deliberately NOT emitted: on
        // Darwin xray's TFO setsockopt fails with EINVAL ("failed to apply
        // socket options > invalid argument", Xray-core#989) — fatal to the
        // dial, repeated every connection attempt. The flag stays in the
        // options struct for persisted-state compatibility only.
        // Pin the physical interface so the engine's own server connection can
        // never be swallowed by a TUN (ours mid-race, or a third-party VPN).
        if let dialerInterface, !dialerInterface.isEmpty {
            sockopt["interface"] = dialerInterface
        }
        if !anti.noises.isEmpty {
            sockopt["noises"] = anti.noises.map { noise in
                ["type": noise.type, "packet": noise.packet, "delay": noise.delay] as [String: Any]
            }
        }
        if let dialerProxy { sockopt["dialerProxy"] = dialerProxy }
        return sockopt
    }
}
