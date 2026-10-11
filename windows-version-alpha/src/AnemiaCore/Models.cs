using System.Text.Json.Serialization;

namespace AnemiaCore;

/// <summary>Transport protocol of an outbound proxy server.</summary>
public enum ProxyProtocol
{
    Vless,
    Vmess,
    Ss,
    Trojan,
    /// <summary>AmneziaWG — WireGuard with the obfuscation parameter set. Wire
    /// name "awg".</summary>
    Amnezia,
    /// <summary>Plain WireGuard. Wire name "wg".</summary>
    WireGuard,
    Hysteria,
    Hysteria2,
}

/// <summary>Underlying stream/network type carried inside the proxy tunnel.</summary>
///
/// Raw values are what share links use (and what the config emits as
/// <c>streamSettings.network</c>). Aliases (h2, kcp, raw, websocket) are
/// normalized by <see cref="ShareLinkParser"/>; <see cref="NetworkType.Http"/> (h2)
/// and <see cref="NetworkType.Quic"/> are still parsed (old links carry them) but
/// rejected at config-build time — Xray-core 26.x removed those transports.
public enum NetworkType
{
    Tcp,
    Ws,
    Grpc,
    Http,
    HttpUpgrade,
    Quic,
    Kcp, // wire name "mkcp"
    /// <summary>Xray's `xhttp` transport, which links also spell `splithttp`.
    /// Refusing it as an unknown transport would drop a working server, because
    /// the alias is what newer panels emit.</summary>
    Xhttp,
}

/// <summary>TLS-layer security for the stream.</summary>
public enum StreamSecurity
{
    None,
    Tls,
    Reality,
    Xtls, // legacy, wire name "xtls", kept for parsing tolerance
}

/// <summary>
/// A single proxy server, normalized from any supported share-link format.
/// This is the canonical in-memory representation: <see cref="ShareLinkParser"/>
/// produces these from vless/vmess/ss/trojan URIs, and
/// <see cref="XrayConfigBuilder"/> turns one into an Xray outbound.
/// </summary>
public sealed class ProxyServer
{
    public Guid Id { get; set; } = Guid.NewGuid();

    /// <summary>Human-readable label (from the URI fragment / vmess ps).</summary>
    public string Name { get; set; } = "";

    public ProxyProtocol Proto { get; set; }

    public string Address { get; set; } = "";
    public int Port { get; set; }

    /// <summary>UUID (vless/vmess) or password (trojan/shadowsocks).</summary>
    public string Credential { get; set; } = "";

    /// <summary>Shadowsocks cipher, e.g. aes-256-gcm, chacha20-ietf-poly1305.</summary>
    public string? Method { get; set; }

    /// <summary>VMess alterId (legacy). 0 for AEAD.</summary>
    public int AlterId { get; set; }

    /// <summary>
    /// VMess cipher from the link's scy field (v2rayN format): auto, zero,
    /// aes-128-gcm, chacha20-poly1305. Null → engine default (auto). Optional
    /// so state saved before this field existed still decodes.
    /// </summary>
    public string? VmessCipher { get; set; }

    public NetworkType Network { get; set; } = NetworkType.Tcp;
    public StreamSecurity Security { get; set; } = StreamSecurity.None;

    // TLS / Reality parameters
    public string? Sni { get; set; }
    public List<string> Alpn { get; set; } = new();
    /// <summary>uTLS fingerprint, e.g. "chrome".</summary>
    public string? Fingerprint { get; set; }

    /// <summary>
    /// Parsed from links for tolerance, but the bundled engine ignores it:
    /// Xray-core 26.x removed allowInsecure (cert validation is always on).
    /// </summary>
    public bool AllowInsecure { get; set; }

    public string? RealityPublicKey { get; set; }  // pbk
    public string? RealityShortId { get; set; }    // sid
    public string? RealitySpiderX { get; set; }    // spx

    // XTLS / VLESS flow control, e.g. "xtls-rprx-vision"
    public string? Flow { get; set; }

    // Transport-specific
    /// <summary>ws/http path or grpc serviceName.</summary>
    public string? Path { get; set; }
    /// <summary>ws Host header / http host / grpc authority.</summary>
    public string? Host { get; set; }
    /// <summary>tcp header obfuscation type.</summary>
    public string? HeaderType { get; set; }

    /// <summary>
    /// gRPC multi-mode (mode=multi in the link): one stream per request
    /// instead of multiplexing over a single long-lived gRPC stream. Nullable
    /// so state saved before this field existed still decodes.
    /// </summary>
    public bool? GrpcMultiMode { get; set; }

    /// <summary>XHTTP <c>mode</c> (auto, packet-up, stream-up, stream-one);
    /// null → the engine's auto.</summary>
    public string? XhttpMode { get; set; }
    /// <summary>XHTTP <c>extra</c> — the link's JSON object of advanced
    /// settings, kept as text and passed to the engine verbatim.</summary>
    public string? XhttpExtra { get; set; }
    /// <summary>VLESS Encryption (mlkem768x25519plus…); null → none. A server
    /// with <c>decryption</c> set rejects plain VLESS clients, so the value has
    /// to survive a save and a sync as typed.</summary>
    public string? VlessEncryption { get; set; }

    /// <summary>AmneziaWG obfuscation parameters; null for plain WireGuard.</summary>
    public AwgObfuscation? Awg { get; set; }

    /// <summary>Peer-side WireGuard values (server key, routes, MTU). The
    /// client private key stays in <see cref="Credential"/>.</summary>
    public WireGuardProfile? WgProfile { get; set; }

    /// <summary>The generation this server's obfuscation set exercises.</summary>
    [JsonIgnore]
    public AwgVersion AwgVersion => AwgVersionExtensions.Detect(Awg);

    /// <summary>
    /// Values a link carries that the Xray outbound shape has no field for —
    /// the mKCP seed, the AmneziaWG junk profile. Mirrors Swift's `userData`
    /// and stays null when the link had none, because Swift writes `{}` and an
    /// omitted key as two different things and its decoder tells them apart.
    /// </summary>
    public Dictionary<string, string>? UserData { get; set; }

    public ProxyServer() { }

    public ProxyServer(
        string name, ProxyProtocol proto, string address, int port, string credential,
        string? method = null, int alterId = 0,
        NetworkType network = NetworkType.Tcp, StreamSecurity security = StreamSecurity.None,
        string? vmessCipher = null, string? sni = null, List<string>? alpn = null,
        string? fingerprint = null, bool allowInsecure = false,
        string? realityPublicKey = null, string? realityShortId = null,
        string? realitySpiderX = null, string? flow = null,
        string? path = null, string? host = null, string? headerType = null,
        bool? grpcMultiMode = null)
    {
        Name = name;
        Proto = proto;
        Address = address;
        Port = port;
        Credential = credential;
        Method = method;
        AlterId = alterId;
        Network = network;
        Security = security;
        VmessCipher = vmessCipher;
        Sni = sni;
        Alpn = alpn ?? new List<string>();
        Fingerprint = fingerprint;
        AllowInsecure = allowInsecure;
        RealityPublicKey = realityPublicKey;
        RealityShortId = realityShortId;
        RealitySpiderX = realitySpiderX;
        Flow = flow;
        Path = path;
        Host = host;
        HeaderType = headerType;
        GrpcMultiMode = grpcMultiMode;
    }

    /// <summary>Protocol name as Xray-core expects it in an outbound. Share
    /// links use the scheme "ss", but Xray's outbound protocol id is
    /// "shadowsocks".</summary>
    [JsonIgnore]
    public string XrayProtocolName => Proto switch
    {
        // The engine's protocol id differs from the link scheme.
        ProxyProtocol.Ss => "shadowsocks",
        // Hysteria is reached through a local SOCKS bridge the hysteria binary
        // owns, so what xray dials is socks — same on every platform.
        ProxyProtocol.Hysteria or ProxyProtocol.Hysteria2 => "socks",
        _ => Wire.Name(Proto),
    };

    /// <summary>WireGuard-family servers are never an xray outbound: the
    /// handshake is the daemon's, not the engine's.</summary>
    [JsonIgnore]
    public bool IsWireGuardFamily => Proto is ProxyProtocol.Amnezia or ProxyProtocol.WireGuard;

    [JsonIgnore]
    public bool IsHysteriaFamily => Proto is ProxyProtocol.Hysteria or ProxyProtocol.Hysteria2;

    /// <summary>
    /// Config-independent identity of a server (what the admin would rotate):
    /// protocol, endpoint and credential. Used to keep IDs stable across
    /// subscription refreshes, so selection and ping history survive.
    /// </summary>
    [JsonIgnore]
    public string IdentityKey =>
        string.Join("|", Wire.Name(Proto), Address, Port.ToString(), Credential, Method ?? "", Flow ?? "");
}