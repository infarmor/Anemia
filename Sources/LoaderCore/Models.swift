import Foundation

/// Transport protocol of an outbound proxy server.
public enum ProxyProtocol: String, Codable, Sendable, CaseIterable {
    case vless
    case vmess
    case shadowsocks = "ss"
    case trojan
    /// AmneziaWG — WireGuard with junk/packet/header obfuscation. Runs on the
    /// separate `amneziawg-go` engine, never on Xray-core (Xray's wireguard
    /// outbound cannot speak the obfuscated handshake, so emitting one would
    /// silently drop every anti-DPI parameter).
    case amnezia = "awg"
    /// Plain WireGuard — same engine path as AmneziaWG with an empty
    /// obfuscation set (the daemon tolerates missing J*/S*/H* keys).
    case wireguard = "wg"
    /// Hysteria (protocol v1) — QUIC-based. Parsed from `hysteria://` links;
    /// the engine path runs the separate hysteria client binary.
    case hysteria
    /// Hysteria 2 — QUIC-based, the `hysteria2://` / `hy2://` schemes. Same
    /// engine path: the hysteria binary serves a local SOCKS5 bridge and
    /// Xray routes through it (it cannot dial the hysteria protocol itself).
    case hysteria2

    /// Protocol name as Xray-core expects it in an outbound. Share links use
    /// the scheme `ss`, but Xray's outbound protocol id is `shadowsocks`.
    /// WireGuard-family servers never reach Xray — the dedicated engine runs
    /// them — so there is deliberately no Xray name for them here. The
    /// hysteria family reaches Xray only as a local SOCKS bridge outbound,
    /// which the config builder assembles itself.
    public var xrayProtocolName: String {
        switch self {
        case .shadowsocks: return "shadowsocks"
        case .hysteria, .hysteria2: return "socks"
        case .amnezia, .wireguard: return rawValue
        default: return rawValue
        }
    }

    /// The WireGuard family is supervised by the AmneziaWG engine, not Xray.
    public var isWireGuardFamily: Bool {
        self == .amnezia || self == .wireguard
    }

    /// The Hysteria family runs the dedicated hysteria client binary next to
    /// Xray: the engine owns the QUIC wire and serves a local SOCKS5 bridge
    /// that Xray routes through.
    public var isHysteriaFamily: Bool {
        self == .hysteria || self == .hysteria2
    }
}

/// Underlying stream/network type carried inside the proxy tunnel.
///
/// Raw values are what share links use (and what the config emits as
/// `streamSettings.network`). Aliases (`h2`, `kcp`, `raw`, `websocket`) are
/// normalized by ``ShareLinkParser``; `.http` (h2) and `.quic` are still parsed
/// (old links carry them) but rejected at config-build time — Xray-core 26.x
/// removed those transports from the engine.
public enum NetworkType: String, Codable, Sendable {
    case tcp
    case ws          // websocket
    case grpc
    case http        // http/2
    case httpupgrade
    case quic
    case kcp = "mkcp"
    /// XHTTP (née SplitHTTP) — Xray's HTTP-native transport, the usual carrier
    /// for VLESS + REALITY behind CDNs in 2025–26.
    case xhttp
}

/// TLS-layer security for the stream.
public enum StreamSecurity: String, Codable, Sendable {
    case none
    case tls
    case reality
    case xtls        // legacy, kept for parsing tolerance
}

/// A single proxy server, normalized from any supported share-link format.
///
/// This is the canonical in-memory representation. `ShareLinkParser` produces
/// these from `vless://`, `vmess://`, `ss://`, `trojan://` URIs, and
/// `XrayConfigBuilder` turns one into an Xray outbound.
public struct ProxyServer: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    /// Human-readable label (from the URI fragment / vmess `ps`).
    public var name: String
    public var proto: ProxyProtocol

    public var address: String
    public var port: Int

    /// UUID (vless/vmess) or password (trojan/shadowsocks).
    public var credential: String
    /// Shadowsocks cipher, e.g. `aes-256-gcm`, `chacha20-ietf-poly1305`.
    public var method: String?
    /// VMess alterId (legacy). 0 for AEAD.
    public var alterId: Int
    /// VMess cipher from the link's `scy` field (v2rayN format): `auto`,
    /// `zero`, `aes-128-gcm`, `chacha20-poly1305`. Nil → engine default
    /// (`auto`). Optional so state saved before this field existed still
    /// decodes.
    public var vmessCipher: String?

    public var network: NetworkType
    public var security: StreamSecurity

    // TLS / Reality parameters
    public var sni: String?
    public var alpn: [String]
    public var fingerprint: String?      // uTLS fingerprint, e.g. "chrome"
    /// Parsed from links for tolerance, but the bundled engine ignores it:
    /// Xray-core 26.x removed `allowInsecure` (cert validation is always on).
    public var allowInsecure: Bool
    public var realityPublicKey: String? // pbk
    public var realityShortId: String?   // sid
    public var realitySpiderX: String?   // spx

    // XTLS / VLESS flow control
    public var flow: String?             // e.g. "xtls-rprx-vision"

    // Transport-specific
    public var path: String?             // ws/http path or grpc serviceName
    public var host: String?             // ws Host header / http host / grpc authority
    public var headerType: String?       // tcp header obfuscation type
    /// gRPC multi-mode (`mode=multi` in the link): one stream per request
    /// instead of multiplexing over a single long-lived gRPC stream. Optional
    /// so state saved before this field existed still decodes.
    public var grpcMultiMode: Bool?
    /// XHTTP `mode` (`auto`, `packet-up`, `stream-up`, `stream-one`); nil →
    /// the engine's `auto`.
    public var xhttpMode: String?
    /// XHTTP `extra` — the link's JSON object of advanced settings (xmux,
    /// padding, download split), passed to the engine verbatim.
    public var xhttpExtra: String?
    /// VLESS Encryption (`mlkem768x25519plus…` from `xray vlessenc`); nil →
    /// `none`. A server with `decryption` set rejects plain VLESS clients.
    public var vlessEncryption: String?

    /// AmneziaWG obfuscation parameters (J*/S*/H*/I*/3.x keys). Nil for
    /// non-WireGuard-family servers and plain WireGuard alike.
    public var awg: AWGObfuscation?
    /// WireGuard peer profile: server public key, optional PSK, AllowedIPs,
    /// DNS, MTU, keepalive. The client private key lives in `credential`.
    public var wgProfile: WireGuardProfile?
    /// Free-form extras that don't fit a protocol field (e.g. the wg conf's
    /// own tunnel Address). Optional so state saved before this field existed
    /// still decodes; never used for matching.
    public var userData: [String: String]?

    public init(
        id: UUID = UUID(),
        name: String,
        proto: ProxyProtocol,
        address: String,
        port: Int,
        credential: String,
        method: String? = nil,
        alterId: Int = 0,
        network: NetworkType = .tcp,
        security: StreamSecurity = .none,
        vmessCipher: String? = nil,
        sni: String? = nil,
        alpn: [String] = [],
        fingerprint: String? = nil,
        allowInsecure: Bool = false,
        realityPublicKey: String? = nil,
        realityShortId: String? = nil,
        realitySpiderX: String? = nil,
        flow: String? = nil,
        path: String? = nil,
        host: String? = nil,
        headerType: String? = nil,
        grpcMultiMode: Bool? = nil,
        xhttpMode: String? = nil,
        xhttpExtra: String? = nil,
        vlessEncryption: String? = nil,
        awg: AWGObfuscation? = nil,
        wgProfile: WireGuardProfile? = nil,
        userData: [String: String]? = nil
    ) {
        self.id = id
        self.name = name
        self.proto = proto
        self.address = address
        self.port = port
        self.credential = credential
        self.method = method
        self.alterId = alterId
        self.network = network
        self.security = security
        self.vmessCipher = vmessCipher
        self.sni = sni
        self.alpn = alpn
        self.fingerprint = fingerprint
        self.allowInsecure = allowInsecure
        self.realityPublicKey = realityPublicKey
        self.realityShortId = realityShortId
        self.realitySpiderX = realitySpiderX
        self.flow = flow
        self.path = path
        self.host = host
        self.headerType = headerType
        self.grpcMultiMode = grpcMultiMode
        self.xhttpMode = xhttpMode
        self.xhttpExtra = xhttpExtra
        self.vlessEncryption = vlessEncryption
        self.awg = awg
        self.wgProfile = wgProfile
        self.userData = userData
    }
}

extension ProxyServer {
    /// Config-independent identity of a server (what the admin would rotate):
    /// protocol, endpoint and credential. Used to keep IDs stable across
    /// subscription refreshes, so selection and ping history survive.
    public var identityKey: String {
        [proto.rawValue, address, String(port), credential, method ?? "", flow ?? ""].joined(separator: "|")
    }
}

/// Errors surfaced while parsing share links or subscriptions.
public enum ParseError: Error, Equatable, Sendable {
    case unsupportedScheme(String)
    case malformedURI(String)
    case missingField(String)
    case invalidBase64
    case emptyInput
    /// The link names a transport or plugin the bundled engines can't run —
    /// an unknown `type=`, or a SIP003 Shadowsocks plugin.
    case unsupportedTransport(String)
}
