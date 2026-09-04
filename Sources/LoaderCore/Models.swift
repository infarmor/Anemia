import Foundation

/// Transport protocol of an outbound proxy server.
public enum ProxyProtocol: String, Codable, Sendable, CaseIterable {
    case vless
    case vmess
    case shadowsocks = "ss"
    case trojan

    /// Protocol name as Xray-core expects it in an outbound. Share links use
    /// the scheme `ss`, but Xray's outbound protocol id is `shadowsocks`.
    public var xrayProtocolName: String {
        self == .shadowsocks ? "shadowsocks" : rawValue
    }
}

/// Underlying stream/network type carried inside the proxy tunnel.
public enum NetworkType: String, Codable, Sendable {
    case tcp
    case ws          // websocket
    case grpc
    case http        // http/2
    case httpupgrade
    case quic
    case kcp = "mkcp"
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

    public var network: NetworkType
    public var security: StreamSecurity

    // TLS / Reality parameters
    public var sni: String?
    public var alpn: [String]
    public var fingerprint: String?      // uTLS fingerprint, e.g. "chrome"
    public var allowInsecure: Bool
    public var realityPublicKey: String? // pbk
    public var realityShortId: String?   // sid
    public var realitySpiderX: String?   // spx

    // XTLS / VLESS flow control
    public var flow: String?             // e.g. "xtls-rprx-vision"

    // Transport-specific
    public var path: String?             // ws/http/grpc path or grpc serviceName
    public var host: String?             // ws/http Host header
    public var headerType: String?       // mkcp/tcp header obfuscation type

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
        headerType: String? = nil
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
    }
}

/// Errors surfaced while parsing share links or subscriptions.
public enum ParseError: Error, Equatable, Sendable {
    case unsupportedScheme(String)
    case malformedURI(String)
    case missingField(String)
    case invalidBase64
    case emptyInput
}
