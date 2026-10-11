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
    /// XHTTP `mode` outside the engine's set — a config error at engine start.
    case invalidXHTTPMode(String)
    /// The link's XHTTP `extra` is not a JSON object.
    case invalidXHTTPExtra
    /// Xray's built-in hysteria client speaks Hysteria 2 only.
    case hysteriaV1Unsupported
    /// A Hysteria server without its auth password.
    case hysteriaMissingAuth
    /// `insecure=1` without a certificate pin: Xray-core 26.x can no longer
    /// skip certificate validation, so a self-signed server is trusted only
    /// through `pinSHA256`.
    case hysteriaInsecureWithoutPin
    /// A Shadowsocks link with no cipher at all (`ss://:pw@host`).
    case shadowsocksMethodMissing
    /// A cipher the bundled engine no longer has: the legacy stream ciphers
    /// (`aes-256-cfb`, `chacha20-ietf`, `rc4-md5`, `salsa20`) were dropped from
    /// Xray-core, and the config dies at engine start with
    /// `unknown cipher method: …` — a Go message the user cannot act on.
    case shadowsocksMethodUnsupported(String)
    /// mKCP header obfuscation and `seed` were removed from `kcpSettings` in
    /// 26.x (the engine answers `removed feature: mkcp header & seed`), so a
    /// server that expects them cannot be reached through this engine at all.
    case mkcpObfuscationUnsupported(String)
    /// The engine reads `pinnedPeerCertSha256` as hex only (commas separate
    /// several pins, colons are the OpenSSL spelling) and demands 32 bytes:
    /// anything else is a fatal config error at engine start.
    case hysteriaPinMalformed(String)
    /// A `encryption=` value that is neither "none" nor a VLESS Encryption
    /// group key in the grammar the engine parses.
    case vlessEncryptionUnsupported(String)
    /// A `flow=` the bundled engine does not know.
    case vlessFlowUnsupported(String)


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
        case .invalidXHTTPMode(let mode):
            return "XHTTP mode '\(mode)' is not one the engine knows (auto, packet-up, stream-up, stream-one)."
        case .invalidXHTTPExtra:
            return "The link's XHTTP 'extra' settings are not valid JSON — re-import it from the panel."
        case .hysteriaV1Unsupported:
            return "Hysteria v1 servers are not supported here — ask the provider for a hysteria2 (hy2://) link."
        case .hysteriaMissingAuth:
            return "Hysteria server carries no auth/password — re-import the link."
        case .hysteriaInsecureWithoutPin:
            return "This Hysteria server uses an untrusted certificate (insecure=1) without pinSHA256 — the bundled Xray-core can't skip certificate checks. Ask the provider for a link with pinSHA256."
        case .shadowsocksMethodMissing:
            return "The Shadowsocks link carries no cipher method (ss://:password@host) — re-import it from the panel, which writes e.g. aes-256-gcm:password."
        case .shadowsocksMethodUnsupported(let method):
            return "Cipher '\(method)' is not supported by the bundled Xray-core (the legacy stream ciphers were removed). Ask the provider for an AEAD cipher such as aes-256-gcm or chacha20-ietf-poly1305."
        case .hysteriaPinMalformed(let pin):
            return "pinSHA256 '\(pin)' is not a 32-byte SHA-256 written in hex (64 digits, ':' separators allowed, several pins separated by ',') — re-import the link from the panel."
        case .vlessEncryptionUnsupported(let value):
            return "The link asks for VLESS Encryption '\(value)', which the bundled Xray-core cannot use: the value must be a mlkem768x25519plus group key in native/xorpub/random 1rtt/0rtt form. Ask the provider for a plain (encryption=none) link, or update the app's engine."
        case .vlessFlowUnsupported(let flow):
            return "Flow '\(flow)' is not supported by the bundled Xray-core (only xtls-rprx-vision and xtls-rprx-vision-udp443) — re-import the link or ask for a ws/tcp variant."
        case .mkcpObfuscationUnsupported(let detail):
            return "mKCP header obfuscation and seed were removed from Xray-core 26.x (\(detail)) — this server needs a ws/grpc/tcp variant."
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
///  * `noises`   → junk packets emitted before real data (`settings.noises` on the
///    same masking `freedom` outbound as `fragment` — xray has no socket option
///    by that name). Both are filtered by what the engine loads; see
///    ``AntiCensorshipOptions/emittableNoises``.
///  * `mux`      → connection multiplexing with padding (skipped under
///    XTLS-Vision, which is faster unmuxed).
public struct XrayConfigBuilder {
    /// The ciphers the bundled Xray-core accepts, measured against the shipped
    /// binary with `xray run -c … -test`: everything else fails to start
    /// (`unknown cipher method`), and the engine matches them case-insensitively.
    public static let supportedCiphers: Set<String> = [
        "aes-128-gcm", "aes-256-gcm", "chacha20-poly1305", "chacha20-ietf-poly1305",
        "xchacha20-ietf-poly1305", "none",
        "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305",
    ]

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
    /// locally and instantly. For the engine's OWN server dial the pin only
    /// takes effect through `sockopt.domainStrategy` (see `pinsServerDial`).
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
    /// Split tunneling: destinations routed to a `bypass` freedom outbound
    /// pinned to ``dialerInterface`` instead of the proxy. With local proxies
    /// (macOS) it is emitted only while that pin exists — an unpinned direct
    /// dial under the system tunnel follows the tunnel's own split routes
    /// straight back into it, an endless connection loop. (The helper routes
    /// the same destinations around the utun at the OS level; this covers
    /// proxy-mode traffic and addresses a domain rotated to since.) In packet-
    /// tunnel mode (iOS) no pin is needed: the provider's own sockets never
    /// enter its tunnel.
    public var bypass: [BypassEntry] = []
    /// Plain DNS server (an IPv4 address, e.g. 77.88.8.8) asked directly —
    /// and exclusively — for the bypassed domains, so they resolve the way the
    /// local network sees them instead of through the proxy's resolver. Nil
    /// resolves them with ``remoteDNS`` like every other name.
    public var bypassResolver: String?

    /// Where the engine's traffic comes from.
    public enum InboundMode: Sendable, Equatable {
        /// Local SOCKS + HTTP listeners that tun2socks and the system proxy
        /// dial (macOS).
        case localProxies
        /// Xray's own `tun` inbound reading a packet tunnel (iOS: the
        /// NetworkExtension utun, handed over by the engine wrapper through
        /// `xray.tun.fd`). Listens on no port.
        case packetTunnel(mtu: Int)
    }
    public var inboundMode: InboundMode = .localProxies
    private var isPacketTunnel: Bool {
        if case .packetTunnel = inboundMode { return true }
        return false
    }
    /// Tag of the ``InboundMode/packetTunnel(mtu:)`` inbound. The iOS engine
    /// wrapper finds it by this tag and starts it after everything else.
    public static let tunnelInboundTag = "tun-in"

    /// How a Hysteria 2 server is dialed.
    public enum HysteriaMode: Sendable, Equatable {
        /// Through the standalone hysteria client's local SOCKS bridge (macOS).
        case socksBridge
        /// Xray's built-in hysteria outbound: one engine in one process (iOS).
        case native
    }
    public var hysteriaMode: HysteriaMode = .socksBridge

    /// DNS `queryStrategy`. `UseIPv4` keeps AAAA answers away from apps when
    /// the exit likely has no IPv6 — they would try v6 first and stall.
    public var dnsQueryStrategy = "UseIP"
    /// Count proxy traffic without exposing the Stats API (`apiPort`); the
    /// iOS engine reads the counters in-process.
    public var collectsStats = false
    /// File for the engine's error log; nil keeps Xray's default (stdout).
    public var logFile: String?

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

        // --- Masking dialer (optional) ---------------------------------
        // Both features xray attaches to the dial — ClientHello fragmentation
        // and junk packets — live on one `freedom` outbound the proxy chains to
        // through `sockopt.dialerProxy`, and both in its `settings`:
        // `settings.fragment` and `settings.noises` (`infra/conf/freedom.go` of
        // 26.3.27). xray has no `sockopt.noises` at all — measured on the
        // shipped binary a bad `sockopt.interface` fails the decode while
        // `sockopt.noises`, garbage included, is ignored — so emitting them
        // there gave every profile except `off` a knob that did nothing while
        // the UI named it. Both keys are read STRICTLY now, so anything the
        // engine would refuse to load is filtered out
        // (`emittableNoises`/`emittableFragment`): one poisoned record must
        // cost its own junk packet, not the tunnel.
        let maskNoises = anti.emittableNoises
        let maskFragment = anti.emittableFragment
        let viaMaskDialer = maskFragment != nil || !maskNoises.isEmpty
        let pinDial = pinsServerDial(server)
        if viaMaskDialer {
            var maskSettings: [String: Any] = ["domainStrategy": "AsIs"]
            if let frag = maskFragment {
                maskSettings["fragment"] = [
                    "packets": frag.packets, "length": frag.length, "interval": frag.interval,
                ]
            }
            if !maskNoises.isEmpty {
                maskSettings["noises"] = maskNoises.map {
                    ["type": $0.type, "packet": $0.packet, "delay": $0.delay] as [String: Any]
                }
            }
            var fragmentOutbound: [String: Any] = [
                "tag": "fragment",
                "protocol": "freedom",
                "settings": maskSettings,
            ]
            if let sockopt = makeSockopt(anti: anti, dialerProxy: nil, pinServerDial: pinDial) {
                fragmentOutbound["streamSettings"] = ["sockopt": sockopt]
            }
            outbounds.append(fragmentOutbound)
        }

        // --- Main proxy outbound ---------------------------------------
        outbounds.insert(try makeProxyOutbound(server: server, anti: anti, viaMaskDialer: viaMaskDialer), at: 0)

        // --- Direct + block --------------------------------------------
        outbounds.append(["tag": "direct", "protocol": "freedom", "settings": ["domainStrategy": "UseIP"]])
        let bypassPin = (dialerInterface ?? "").isEmpty ? nil : dialerInterface
        let bypassActive = !bypass.isEmpty && (bypassPin != nil || isPacketTunnel)
        let bypassDomains = bypass.filter(\.isDomain).map { "domain:\($0.value)" }
        let resolver = bypassResolver.flatMap { DirectResolver.isIPv4($0) ? $0 : nil }
        if bypassActive {
            var bypassOutbound: [String: Any] = [
                "tag": "bypass",
                "protocol": "freedom",
                "settings": ["domainStrategy": "UseIP"]
            ]
            if let bypassPin {
                bypassOutbound["streamSettings"] = ["sockopt": ["interface": bypassPin]]
            }
            outbounds.append(bypassOutbound)
        }
        outbounds.append(["tag": "block", "protocol": "blackhole", "settings": [:] as [String: Any]])
        // Built-in DNS outbound: answers hijacked :53 traffic with the
        // configured (proxied DoH) resolvers.
        if hijackDNS {
            outbounds.append(["tag": "dns-out", "protocol": "dns", "settings": [:] as [String: Any]])
        }

        // --- Inbounds ---------------------------------------------------
        let sniff: [String: Any]? = enableSniffing
            ? ["enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": false]
            : nil
        var inbounds: [[String: Any]]
        // Inbounds that carry user traffic (the DNS hijack applies to these).
        let trafficInboundTags: [String]
        switch inboundMode {
        case .localProxies:
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
            socksIn["sniffing"] = sniff
            httpIn["sniffing"] = sniff
            inbounds = [socksIn, httpIn]
            trafficInboundTags = ["socks-in", "http-in"]
        case .packetTunnel(let mtu):
            var tunIn: [String: Any] = [
                "tag": Self.tunnelInboundTag,
                "protocol": "tun",
                "port": 0,
                "settings": ["MTU": mtu]
            ]
            // Sniffing restores the domain behind each IP flow, so routing
            // and the proxy see names, not the addresses DNS handed out.
            tunIn["sniffing"] = sniff
            inbounds = [tunIn]
            trafficInboundTags = [Self.tunnelInboundTag]
        }
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
            rules.append(["type": "field", "inboundTag": trafficInboundTags,
                          "port": 53, "outboundTag": "dns-out"])
        }
        // Split tunneling: listed destinations leave through the physical
        // network. Ahead of the QUIC block, so a bypassed destination keeps
        // its UDP/443 path too.
        if bypassActive {
            let networks = bypass.filter { !$0.isDomain }.map(\.value)
            if !bypassDomains.isEmpty {
                rules.append(["type": "field", "outboundTag": "bypass", "domain": bypassDomains])
            }
            if !networks.isEmpty {
                rules.append(["type": "field", "outboundTag": "bypass", "ip": networks])
            }
            // The bypass resolver itself is reached directly, like the names
            // it answers for (the DNS module's queries carry no inbound tag,
            // so the hijack rule above leaves them alone).
            if let resolver, !bypassDomains.isEmpty {
                rules.append(["type": "field", "outboundTag": "bypass", "ip": ["\(resolver)/32"]])
            }
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
        var dnsServers: [Any] = remoteDNS
        if bypassActive, let resolver, !bypassDomains.isEmpty {
            // Exclusive for the bypassed names (finalQuery) and never a
            // fallback for anything else (skipFallback).
            dnsServers.insert([
                "address": resolver,
                "domains": bypassDomains,
                "skipFallback": true,
                "finalQuery": true
            ] as [String: Any], at: 0)
        }
        var dns: [String: Any] = [
            "servers": dnsServers,
            "queryStrategy": dnsQueryStrategy,
            "disableCache": false,
            // Ask every resolver at once and take the first answer: one
            // throttled or blackholed DoH endpoint no longer stalls every new
            // name for its full timeout before the next server is tried.
            "enableParallelQuery": true,
            // A known name answers from cache even just past its TTL, and the
            // engine refreshes it in the background — page loads stop paying
            // a DoH round trip through the proxy for sites already visited.
            "serveStale": true,
            "serveExpiredTTL": 3600
        ]
        if !dnsHosts.isEmpty {
            dns["hosts"] = dnsHosts
        }

        var log: [String: Any] = ["loglevel": logLevel]
        if let logFile {
            // Per-connection access lines would drown the errors in a
            // file that nobody rotates.
            log["error"] = logFile
            log["access"] = "none"
        }
        var config: [String: Any] = [
            "log": log,
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
        }
        if apiPort != nil || collectsStats {
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
        if server.network == .xhttp {
            if let mode = server.xhttpMode, !["auto", "packet-up", "stream-up", "stream-one"].contains(mode) {
                throw ConfigBuilderError.invalidXHTTPMode(mode)
            }
            if let extra = server.xhttpExtra,
               (try? JSONSerialization.jsonObject(with: Data(extra.utf8))) as? [String: Any] == nil {
                throw ConfigBuilderError.invalidXHTTPExtra
            }
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

    /// Whether the socket that dials the server must resolve its domain
    /// through the engine's DNS module (and so hit the `dnsHosts` pin).
    ///
    /// Measured against the bundled 26.x engine: with the default AsIs
    /// strategy the dial hands the domain to Go's dialer, i.e. the SYSTEM
    /// resolver — `dns.hosts` is never consulted, a domain only the pin knows
    /// fails outright, and under the tunnel the lookup travels back into the
    /// engine itself (the loop the pin exists to break). `UseIPv4` routes the
    /// lookup through the DNS module, where hosts answer first. Emitted only
    /// while a pin exists: without one the module would resolve the server
    /// via DoH *through the proxy it is trying to reach*.
    func pinsServerDial(_ server: ProxyServer) -> Bool {
        !server.proto.isHysteriaFamily && dnsHosts[server.address] != nil
    }

    private func makeProxyOutbound(server: ProxyServer, anti: AntiCensorshipOptions, viaMaskDialer: Bool) throws -> [String: Any] {
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
        if server.proto.isHysteriaFamily, hysteriaMode == .native {
            return try makeNativeHysteriaOutbound(server)
        }
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

        // The cipher is the one field a Shadowsocks server cannot fall back
        // from: an empty one and the removed stream ciphers both make the
        // engine refuse the config (`unknown cipher method: …`), which reaches
        // the user as a Go line about a server they cannot inspect.
        if server.proto == .shadowsocks {
            let method = (server.method ?? "").trimmingCharacters(in: .whitespaces)
            guard !method.isEmpty else { throw ConfigBuilderError.shadowsocksMethodMissing }
            guard Self.supportedCiphers.contains(method.lowercased()) else {
                throw ConfigBuilderError.shadowsocksMethodUnsupported(method)
            }
        }
        // mKCP obfuscation: 26.x refuses any `header` or `seed` in kcpSettings
        // outright, and dropping them silently here would dial a plain mKCP at
        // a server that expects obfuscation — no answer, no error.
        if server.proto == .vless {
            let encryption = server.vlessEncryption ?? "none"
            guard encryption == "none" || Self.isVlessEncryptionKey(encryption) else {
                throw ConfigBuilderError.vlessEncryptionUnsupported(encryption)
            }
        }
        if let flow = server.flow, !flow.isEmpty,
           flow != "xtls-rprx-vision", flow != "xtls-rprx-vision-udp443" {
            throw ConfigBuilderError.vlessFlowUnsupported(flow)
        }
        if server.network == .kcp {
            let header = (server.headerType ?? "").trimmingCharacters(in: .whitespaces)
            if !header.isEmpty && header.lowercased() != "none" {
                throw ConfigBuilderError.mkcpObfuscationUnsupported("header=\(header)")
            }
            if let seed = server.userData?["kcpSeed"], !seed.isEmpty {
                throw ConfigBuilderError.mkcpObfuscationUnsupported("seed is set")
            }
        }

        outbound["streamSettings"] = makeStreamSettings(server, anti: anti, viaMaskDialer: viaMaskDialer)

        // Mux with padding — but not with XTLS-Vision (incompatible + slower),
        // and not over XHTTP, which multiplexes on its own (XMUX).
        let isVision = (server.flow ?? "").contains("vision")
        if anti.muxEnabled && !isVision && server.network != .xhttp {
            outbound["mux"] = [
                "enabled": true,
                "concurrency": anti.muxConcurrency,
                "xudpConcurrency": 8,
                "xudpProxyUDP443": "reject"
            ]
        }
        return outbound
    }

    /// Xray's built-in Hysteria 2 client (checked against xray-core
    /// v1.260327.0): endpoint in `settings`, auth in `hysteriaSettings`,
    /// Salamander and port hopping in `finalmask`. The QUIC side negotiates
    /// ALPN h3 on its own, and uTLS fingerprints don't apply to QUIC.
    private func makeNativeHysteriaOutbound(_ server: ProxyServer) throws -> [String: Any] {
        guard server.proto == .hysteria2 else { throw ConfigBuilderError.hysteriaV1Unsupported }
        guard !server.credential.isEmpty else { throw ConfigBuilderError.hysteriaMissingAuth }
        let pin = server.userData?["pinSHA256"].flatMap { $0.isEmpty ? nil : $0 }
        if server.allowInsecure, pin == nil { throw ConfigBuilderError.hysteriaInsecureWithoutPin }
        if let pin, !Self.isSha256PinList(pin) { throw ConfigBuilderError.hysteriaPinMalformed(pin) }

        var tls: [String: Any] = [:]
        if let sni = server.sni, !sni.isEmpty { tls["serverName"] = sni }
        if let pin { tls["pinnedPeerCertSha256"] = pin }
        var stream: [String: Any] = [
            "network": "hysteria",
            "security": "tls",
            "tlsSettings": tls,
            "hysteriaSettings": ["version": 2, "auth": server.credential] as [String: Any]
        ]
        var finalmask: [String: Any] = [:]
        if server.userData?["obfs"] == "salamander",
           let password = server.userData?["obfsPassword"], !password.isEmpty {
            finalmask["udp"] = [["type": "salamander", "settings": ["password": password]]]
        }
        if let hop = server.userData?["portHopping"], !hop.isEmpty,
           HysteriaConfigBuilder.isValidPortSpec(hop) {
            finalmask["quicParams"] = ["udpHop": ["ports": HysteriaConfigBuilder.portSpec(for: server)]]
        }
        if !finalmask.isEmpty { stream["finalmask"] = finalmask }

        return [
            "tag": "proxy",
            "protocol": "hysteria",
            "settings": ["version": 2, "address": server.address, "port": server.port] as [String: Any],
            "streamSettings": stream
        ]
    }

    /// Exactly what the engine accepts (`infra/conf/transport_internet.go`):
    /// comma-separated pins, each optional-colon hex decoding to 32 bytes.
    static func isSha256PinList(_ pin: String) -> Bool {
        var found = false
        for item in pin.components(separatedBy: ",") {
            let hex = item.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":", with: "")
            if hex.isEmpty { continue }
            guard hex.count == 64, hex.unicodeScalars.allSatisfy({ isHexScalar($0) }) else { return false }
            found = true
        }
        return found
    }

    /// Grammar of a VLESS Encryption value, from `infra/conf/vless.go` of the
    /// pinned engine: `mlkem768x25519plus.{native|xorpub|random}.{1rtt|0rtt}.`
    /// then base64url keys of 32 (x25519) or 1184 (mlkem768) bytes; shorter
    /// trailing parts are the padding prefix, not keys.
    static func isVlessEncryptionKey(_ value: String) -> Bool {
        let parts = value.components(separatedBy: ".")
        guard parts.count >= 4, parts[0] == "mlkem768x25519plus",
              ["native", "xorpub", "random"].contains(parts[1]),
              ["1rtt", "0rtt"].contains(parts[2]) else { return false }
        var keys = 0
        for part in parts.dropFirst(3) {
            if part.count < 20 { continue }
            guard let bytes = base64UrlBytes(part),
                  bytes.count == 32 || bytes.count == 1184 else { return false }
            keys += 1
        }
        return keys > 0
    }

    /// Strict unpadded URL-safe base64, as Go's `base64.RawURLEncoding` reads
    /// it: `=` and anything outside the alphabet is an error.
    private static func base64UrlBytes(_ text: String) -> [UInt8]? {
        var bits = 0
        var count = 0
        var out: [UInt8] = []
        for scalar in text.unicodeScalars {
            let value: Int
            switch scalar.value {
            case 0x41...0x5A: value = Int(scalar.value - 0x41)
            case 0x61...0x7A: value = Int(scalar.value - 0x47)
            case 0x30...0x39: value = Int(scalar.value + 4)
            case 0x2D: value = 62
            case 0x5F: value = 63
            default: return nil
            }
            bits = (bits << 6) | value
            count += 6
            if count >= 8 {
                count -= 8
                out.append(UInt8((bits >> count) & 0xFF))
            }
        }
        return out
    }

    private static func isHexScalar(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 0x30 && scalar.value <= 0x39) ||
            (scalar.value >= 0x61 && scalar.value <= 0x66) ||
            (scalar.value >= 0x41 && scalar.value <= 0x46)
    }

    private func makeProxySettings(_ server: ProxyServer) -> [String: Any] {
        switch server.proto {
        case .vless:
            var user: [String: Any] = ["id": server.credential,
                                       "encryption": server.vlessEncryption ?? "none", "level": 0]
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

    private func makeStreamSettings(_ server: ProxyServer, anti: AntiCensorshipOptions, viaMaskDialer: Bool) -> [String: Any] {
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
        case .xhttp:
            var xhttp: [String: Any] = [:]
            if let path = server.path { xhttp["path"] = path }
            if let host = server.host { xhttp["host"] = host }
            if let mode = server.xhttpMode { xhttp["mode"] = mode }
            if let extra = server.xhttpExtra,
               let object = (try? JSONSerialization.jsonObject(with: Data(extra.utf8))) as? [String: Any] {
                xhttp["extra"] = object
            }
            stream["xhttpSettings"] = xhttp
        case .kcp:
            // mKCP still exists, but 26.x removed both `seed` and `header`
            // obfuscation from kcpSettings — emitting either is a config
            // error. Plain tunable settings only; the defaults are fine.
            stream["kcpSettings"] = [:] as [String: Any]
        case .quic:
            break
        }

        // Socket options: when masking, the dialer outbound owns the physical
        // socket, and we only chain to it here.
        if viaMaskDialer {
            stream["sockopt"] = ["dialerProxy": "fragment"]
        } else if let sockopt = makeSockopt(anti: anti, dialerProxy: nil,
                                            pinServerDial: pinsServerDial(server)) {
            stream["sockopt"] = sockopt
        }

        return stream
    }

    private func makeSockopt(anti: AntiCensorshipOptions, dialerProxy: String?,
                             pinServerDial: Bool = false) -> [String: Any]? {
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
        // Resolve the server's domain via the engine's DNS (hosts pin first)
        // rather than the system resolver — see `pinsServerDial`.
        if pinServerDial {
            sockopt["domainStrategy"] = "UseIPv4"
        }
        // `noises` deliberately absent: xray reads junk packets from the masking
        // freedom outbound's `settings.noises`, never from a socket option.
        if let dialerProxy { sockopt["dialerProxy"] = dialerProxy }
        return sockopt
    }
}
