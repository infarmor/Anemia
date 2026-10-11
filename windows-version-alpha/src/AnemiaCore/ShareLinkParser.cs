using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AnemiaCore;

/// <summary>Errors surfaced while parsing share links or subscriptions.</summary>
public enum ParseErrorKind
{
    UnsupportedScheme,
    MalformedUri,
    MissingField,
    InvalidBase64,
    EmptyInput,
    /// <summary>The link names a transport the parser knows but the bundled
    /// engine no longer ships — e.g. xhttp/splithttp.</summary>
    UnsupportedTransport,
}

/// <summary>Exception form of <see cref="ParseErrorKind"/>; equality is by
/// (kind, detail) so tests can assert like the Swift enum did.</summary>
public sealed class ParseErrorException : Exception, IEquatable<ParseErrorException>
{
    public ParseErrorKind Kind { get; }
    public string Detail { get; }

    public ParseErrorException(ParseErrorKind kind, string detail = "")
    {
        Kind = kind;
        Detail = detail;
    }

    public bool Equals(ParseErrorException? other) =>
        other is not null && other.Kind == Kind && other.Detail == Detail;
    public override bool Equals(object? obj) => Equals(obj as ParseErrorException);
    public override int GetHashCode() => HashCode.Combine(Kind, Detail);
    public override string Message =>
        string.IsNullOrEmpty(Detail) ? Kind.ToString() : $"{Kind}: {Detail}";
}

/// <summary>
/// Parses proxy share links into the canonical <see cref="ProxyServer"/> model.
/// Supported schemes: vless://, vmess://, ss://, trojan://, awg://, amnezia://,
/// wireguard://, wg://. The parser is
/// deliberately lenient about missing/optional query fields so that real-world
/// links from a range of panels import cleanly.
/// </summary>
public static class ShareLinkParser
{
    /// <summary>Parse a single share link. Whitespace is trimmed first.</summary>
    public static ProxyServer Parse(string raw)
    {
        var link = raw.Trim();
        if (link.Length == 0) throw new ParseErrorException(ParseErrorKind.EmptyInput);

        int schemeEnd = link.IndexOf("://", StringComparison.Ordinal);
        if (schemeEnd < 0) throw new ParseErrorException(ParseErrorKind.MalformedUri, link);
        var scheme = link[..schemeEnd].ToLowerInvariant();

        return scheme switch
        {
            "vless" => ParseVless(link),
            "trojan" => ParseTrojan(link),
            "vmess" => ParseVmess(link),
            "ss" => ParseShadowsocks(link),
            // The WireGuard family: the Amnezia spelling carries the obfuscation
            // set, plain wireguard:// does not; a conf parsed under the amnezia
            // scheme with no obfuscation keys is downgraded inside the parser.
            "amnezia" or "awg" => WireGuardLink.Parse(link, ProxyProtocol.Amnezia),
            "wireguard" or "wg" => WireGuardLink.Parse(link, ProxyProtocol.WireGuard),
            // The Amnezia container: an envelope of per-protocol configs, in
            // Qt's qCompress bytes or plain, that resolves to one of the links
            // the branches above already understand.
            "vpn" => ParseVpnLink(link),
            "hysteria" => ParseHysteria(link, version: 1),
            "hysteria2" or "hy2" => ParseHysteria(link, version: 2),
            _ => throw new ParseErrorException(ParseErrorKind.UnsupportedScheme, scheme),
        };
    }

    // MARK: - VLESS

    private static ProxyServer ParseVless(string link)
    {
        var uri = new UriParts(link);
        if (string.IsNullOrEmpty(uri.UserInfo)) throw new ParseErrorException(ParseErrorKind.MissingField, "uuid");
        if (uri.Host is null || uri.Port is null) throw new ParseErrorException(ParseErrorKind.MissingField, "host/port");
        ValidatePort(uri.Port.Value, link);

        var q = uri.Query;
        var security = SecurityValue(q, fallback: StreamSecurity.None);
        var server = new ProxyServer(
            name: uri.Fragment ?? uri.Host!,
            proto: ProxyProtocol.Vless,
            address: uri.Host!,
            port: uri.Port.Value,
            credential: uri.UserInfo!,
            network: NetworkTypeOf(q),
            security: security,
            flow: q.GetValueOrDefault("flow") is { Length: > 0 } flow ? flow : null)
        { Security = security };
        // VLESS Encryption: a server with `decryption` set refuses plain
        // clients, so the link's encryption string has to reach the outbound.
        // `none` is the absence of encryption spelled out, not a mode name —
        // Swift drops it, and so does this port.
        server.VlessEncryption = NonEmpty(q.GetValueOrDefault("encryption")) is { } enc &&
            !enc.Equals("none", StringComparison.OrdinalIgnoreCase) ? enc : null;
        ApplyStreamParams(server, q);
        return server;
    }

    // MARK: - Trojan

    private static ProxyServer ParseTrojan(string link)
    {
        var uri = new UriParts(link);
        if (string.IsNullOrEmpty(uri.UserInfo)) throw new ParseErrorException(ParseErrorKind.MissingField, "password");
        if (uri.Host is null || uri.Port is null) throw new ParseErrorException(ParseErrorKind.MissingField, "host/port");
        ValidatePort(uri.Port.Value, link);

        var q = uri.Query;
        // Trojan defaults to TLS even when `security` is omitted.
        var security = SecurityValue(q, fallback: StreamSecurity.Tls);
        // No `flow`: the XTLS flow field exists only for VLESS — a trojan
        // link's stray flow= param (panels emit it gratuitously) would reach
        // the trojan outbound where Xray rejects unknown flow values at
        // config validation.
        var server = new ProxyServer(
            name: uri.Fragment ?? uri.Host!,
            proto: ProxyProtocol.Trojan,
            address: uri.Host!,
            port: uri.Port.Value,
            credential: uri.UserInfo!,
            network: NetworkTypeOf(q),
            security: security
        );
        ApplyStreamParams(server, q);
        return server;
    }

    /// <summary>Case-insensitive security= parsing: real-world links carry TLS,
    /// Reality, REALITY…. A case-sensitive rawValue lookup silently fell back
    /// to none — a TLS server parsed as plaintext that could never handshake,
    /// with no diagnostic.</summary>
    private static StreamSecurity SecurityValue(Dictionary<string, string> q, StreamSecurity fallback)
    {
        var raw = q.GetValueOrDefault("security");
        if (string.IsNullOrEmpty(raw)) return fallback;
        return Wire.ParseSecurity(raw) ?? fallback;
    }

    /// <summary>Ports outside 1…65535 parse fine as integers but reach the
    /// engine config verbatim, where the outbound bind fails at start with an
    /// opaque error — reject at the source instead.</summary>
    private static void ValidatePort(int port, string link)
    {
        if (port is < 1 or > 65535) throw new ParseErrorException(ParseErrorKind.MalformedUri, link);
    }

    // MARK: - VMess

    private static ProxyServer ParseVmess(string link)
    {
        // Some generators append a #remarks fragment (or a query) to the
        // base64 body: vmess://BASE64#name. The base64 alphabet never contains
        // '#' or '?', so anything from the first one is decoration — but a
        // lenient decode ignores unknown characters, so ASCII letters of a
        // fragment name would be swallowed into the payload, shift the stream
        // alignment and corrupt the JSON. Peel it first, exactly like the ss
        // branch does.
        var body = link["vmess://".Length..];
        int cut = body.AsSpan().IndexOfAny('#', '?');
        if (cut >= 0) body = body[..cut];

        var data = Base64.DecodeFlexible(body);
        // Read through JsonDocument, not JsonNode: a parsed JsonObject that
        // carries a repeated key throws `An item with the same key has already
        // been added` on the first access — indexing *or* enumerating it. Panels
        // do repeat a field (`{"add":a, … ,"add":b}` is case 45 of the shared
        // corpus), and JsonDocument keeps both occurrences and lets us choose.
        // Both Swift and its golden read the FIRST one, so the map does too.
        JsonDocument? doc = null;
        if (data is not null)
        {
            try { doc = JsonDocument.Parse(data); }
            catch (JsonException) { }
        }
        if (doc is null || doc.RootElement.ValueKind != JsonValueKind.Object)
            throw new ParseErrorException(ParseErrorKind.InvalidBase64);

        var fields = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        foreach (var property in doc.RootElement.EnumerateObject())
            if (!fields.ContainsKey(property.Name)) fields[property.Name] = property.Value;

        JsonElement? Field(string key) =>
            fields.TryGetValue(key, out var value) ? value : null;
        string? Str(string key) =>
            Field(key) is { } node && node.ValueKind == JsonValueKind.String ? node.GetString() : null;
        int? IntVal(string key)
        {
            if (Field(key) is not { } node) return null;
            if (node.ValueKind == JsonValueKind.Number && node.TryGetInt32(out var i)) return i;
            // A panel that writes `"port": 443.7` still means 443: Swift reads
            // the NSNumber with `intValue`, which truncates, and a port that
            // fails to parse here kills the whole server as "add/port/id".
            if (node.ValueKind == JsonValueKind.Number && node.TryGetDouble(out var real) &&
                double.IsFinite(real) && real >= int.MinValue && real <= int.MaxValue)
                return (int)real;
            if (node.ValueKind == JsonValueKind.String && int.TryParse(node.GetString(), out var parsed))
                return parsed;
            return null;
        }
        var add = Str("add");
        var port = IntVal("port");
        var id = Str("id");
        if (string.IsNullOrEmpty(add) || port is null || port is < 1 or > 65535 || string.IsNullOrEmpty(id))
            throw new ParseErrorException(ParseErrorKind.MissingField, "add/port/id");

        // Panels emit `tls` three ways: string ("tls"/"reality"/"xtls"/"none"),
        // JSON boolean ("tls": true), or absent. Boolean must be checked
        // before Str, or true masquerades as "1".
        string tlsName;
        if (Field("tls") is { } bv && bv.ValueKind == JsonValueKind.True)
            tlsName = "tls";
        else if (Field("tls") is { } bf && bf.ValueKind == JsonValueKind.False)
            tlsName = "none";
        else
            tlsName = (Str("tls") ?? "none").ToLowerInvariant();
        var security = tlsName switch
        {
            "tls" => StreamSecurity.Tls,
            "reality" => StreamSecurity.Reality,
            "xtls" => StreamSecurity.Xtls,
            _ => StreamSecurity.None,
        };
        var net = NetworkTypeOfJson(Str("net"));

        var server = new ProxyServer(
            name: Str("ps") ?? add,
            proto: ProxyProtocol.Vmess,
            address: add,
            port: port.Value,
            credential: id,
            alterId: IntVal("aid") ?? 0,
            network: net,
            security: security,
            vmessCipher: EmptyToNull(Str("scy")),
            sni: EmptyToNull(Str("sni")),
            fingerprint: EmptyToNull(Str("fp")),
            realityPublicKey: EmptyToNull(Str("pbk")),
            realityShortId: EmptyToNull(Str("sid")),
            realitySpiderX: EmptyToNull(Str("spx")),
            path: EmptyToNull(Str("path")),
            host: EmptyToNull(Str("host")),
            headerType: EmptyToNull(Str("type"))
        );
        if (Str("alpn") is { Length: > 0 } alpn)
            server.Alpn = SplitAlpn(alpn);
        // mode=multi for a gRPC transport never reaches the stream-params path
        // (the vmess JSON carries it as a top-level field, not a query):
        // without this, multi-mode servers failed their handshake silently.
        if (net == NetworkType.Grpc)
        {
            var mode = Str("mode");
            server.GrpcMultiMode = mode is not null && mode.Equals("multi", StringComparison.OrdinalIgnoreCase);
        }
        if (net == NetworkType.Xhttp)
        {
            // The vmess JSON's `mode` is the xhttp mode, not the gRPC one: the
            // same key means different things per transport, and dropping it
            // silently changes which request shape the server sees.
            server.XhttpMode = Str("mode") is { Length: > 0 } mode ? mode : null;
        }
        // mKCP's seed has no place in the outbound Xray 26.x accepts, but it must
        // survive to the builder, or a link obfuscated with a seed would dial
        // plain mKCP and fail without an error message.
        if (net == NetworkType.Kcp && Str("seed") is { Length: > 0 } seed)
            server.UserData = new Dictionary<string, string> { ["kcpSeed"] = seed };
        return server;
    }

    // MARK: - Hysteria

    /// <summary>`hysteria://` (v1) and `hysteria2://` / `hy2://` (v2). Port of
    /// Swift's <c>parseHysteria</c>: v2 carries the password in the userinfo and
    /// everything else in the query, v1 puts the password in the query too — but
    /// both are read from either spot, because panels are sloppy.</summary>
    private static ProxyServer ParseHysteria(string rawLink, int version)
    {
        // Port hopping lives in the authority (`host:443,20000-50000`), which no
        // URL grammar accepts — it used to swallow the whole spec into the host.
        var (link, portSpec) = SplitHysteriaPorts(rawLink);
        var parts = new UriParts(link);
        if (parts.Host is not { Length: > 0 } host)
            throw new ParseErrorException(ParseErrorKind.MalformedUri, link);
        var port = parts.Port ?? (version == 2 ? 443 : 80);
        ValidatePort(port, link);

        // Query keys arrive in their original case (obfsParam, UpMbps…), so match
        // case-insensitively. `Obfs=1&obfs=2` collides once lowercased, and a
        // dictionary that traps there kills the whole subscription import; folding
        // in sorted key order makes the winner the lowercase spelling rather than
        // whatever order the hash happened to enumerate.
        var lq = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var entry in parts.Query.OrderBy(pair => pair.Key, StringComparer.Ordinal))
            lq[entry.Key.ToLowerInvariant()] = entry.Value;

        string? Auth(string key) => lq.TryGetValue(key, out var value) ? value : null;

        var auth = parts.UserInfo is { Length: > 0 } userinfo ? userinfo : Auth("auth");
        if (string.IsNullOrEmpty(auth))
            throw new ParseErrorException(ParseErrorKind.MissingField,
                version == 2 ? "auth (userinfo password)" : "auth query");

        var extras = new Dictionary<string, string> { ["hysteriaVersion"] = version.ToString() };
        if (portSpec is not null) extras["portHopping"] = portSpec;

        var server = new ProxyServer
        {
            Name = parts.Fragment ?? host,
            Proto = version == 2 ? ProxyProtocol.Hysteria2 : ProxyProtocol.Hysteria,
            Address = host,
            Port = port,
            Credential = auth,
            Security = StreamSecurity.Tls,
            AllowInsecure = BoolParam(Auth("insecure")),
            UserData = extras,
        };

        // alpn is one YAML field for both generations: dropping it left a server
        // pinned to `http/1.1` dialling the client default `h3`, and every
        // handshake failed with no config error anywhere.
        if (Auth("alpn") is { Length: > 0 } alpn)
            server.Alpn = alpn.Split(',').Select(Foundation.TrimFoundationSpaces).ToList();

        if (version == 2)
        {
            if (Auth("obfs") is { Length: > 0 } obfs) extras["obfs"] = obfs;
            // Read by name rather than walking the dictionary: a link carrying
            // both `obfs-password` and `obfsparam` must not import with one
            // password on one run and the other on the next. The standard
            // spelling wins.
            if ((Auth("obfs-password") ?? Auth("obfsparam")) is { Length: > 0 } obfsPassword)
                extras["obfsPassword"] = obfsPassword;
            if (Auth("pinsha256") is { Length: > 0 } pin) extras["pinSHA256"] = pin;
            if (!extras.ContainsKey("portHopping") &&
                (Auth("mport") ?? Auth("ports")) is { Length: > 0 } hop)
                extras["portHopping"] = hop;
            server.Sni = Auth("sni") ?? Auth("peer");
            return server;
        }

        // Hysteria 1: auth/peer/bandwidth/obfs all live in the query.
        if ((Auth("obfsparam") ?? Auth("obfs-param")) is { Length: > 0 } v1Param) extras["obfsPassword"] = v1Param;
        if (Auth("obfs") is { Length: > 0 } v1Obfs) extras["obfs"] = v1Obfs;
        if ((Auth("upmbps") ?? Auth("up")) is { Length: > 0 } up) extras["upmbps"] = up;
        if ((Auth("downmbps") ?? Auth("down")) is { Length: > 0 } bandwidth) extras["downmbps"] = bandwidth;
        if (Auth("protocol") is { Length: > 0 } protocol) extras["protocol"] = protocol;
        server.Sni = Auth("peer") ?? Auth("sni");
        return server;
    }

    /// <summary>`scheme://auth@host:443,20000-50000/?…` → the link with its first
    /// port only, plus the full port spec. Links without a multi-port authority
    /// come back unchanged.</summary>
    public static (string Link, string? Ports) SplitHysteriaPorts(string link)
    {
        var schemeEnd = link.IndexOf("://", StringComparison.Ordinal);
        if (schemeEnd < 0) return (link, null);
        var rest = link[(schemeEnd + 3)..];
        var authorityEnd = rest.Length;
        for (var i = 0; i < rest.Length; i++)
            if (rest[i] is '/' or '?' or '#') { authorityEnd = i; break; }
        var authority = rest[..authorityEnd];
        var atSign = authority.LastIndexOf('@');
        var hostStart = atSign >= 0 ? atSign + 1 : 0;
        var hostPort = authority[hostStart..];

        int? colon = null;
        if (hostPort.Length > 0 && hostPort[0] == '[')
        {
            var close = hostPort.IndexOf(']');
            if (close >= 0 && close + 1 < hostPort.Length && hostPort[close + 1] == ':') colon = close + 1;
        }
        else
        {
            var last = hostPort.LastIndexOf(':');
            if (last >= 0) colon = last;
        }
        if (colon is not { } at) return (link, null);

        var spec = hostPort[(at + 1)..];
        if (!spec.Contains(',') && !spec.Contains('-')) return (link, null);
        if (!HysteriaConfigBuilder.IsValidPortSpec(spec)) return (link, null);
        var first = spec.Split(',', '-').First();
        var cut = schemeEnd + 3 + authorityEnd;   // index in `link` of the authority tail
        var specStartInLink = schemeEnd + 3 + hostStart + at + 1;
        return (link[..specStartInLink] + first + link[cut..], spec);
    }

    /// <summary>Truthy spellings seen in the wild: `1`, `true`, `yes` (and
    /// `on`, the conf form).</summary>
    private static bool BoolParam(string? raw)
    {
        var value = raw is null ? "" : Foundation.TrimFoundationSpaces(raw).ToLowerInvariant();
        return value is "1" or "true" or "yes" or "on";
    }

    // MARK: - Shadowsocks

    private static ProxyServer ParseShadowsocks(string link)
    {
        // Two encodings exist:
        //   Legacy:  ss://base64(method:password@host:port)#name
        //   SIP002:  ss://base64(method:password)@host:port/?plugin=...#name
        var body = link["ss://".Length..];

        // Peel off #name first.
        string? name = null;
        int hash = body.IndexOf('#');
        if (hash >= 0)
        {
            name = DisplayName(Uri.UnescapeDataString(body[(hash + 1)..]));
            body = body[..hash];
        }

        // Peel off the query and keep it: both encodings can carry parameters
        // (panels append them to legacy links too, where a leftover ?… tail
        // would shift the base64 decode), and the SIP002 branch checks it for
        // a load-bearing plugin.
        string? query = null;
        int qMark = body.IndexOf('?');
        if (qMark >= 0)
        {
            query = body[(qMark + 1)..];
            body = body[..qMark];
        }

        if (body.Contains('@'))
        {
            // SIP002 (userinfo may be base64 or plain).
            if (query is not null)
            {
                // A SIP003 plugin (obfs-local, v2ray-plugin, shadow-tls…) is
                // load-bearing obfuscation: ProxyServer has no field for it,
                // and importing the link as plain Shadowsocks would look
                // healthy, then fail every handshake server-side with no
                // explanation. Fail the parse loudly instead, so the
                // subscription importer reports the real reason.
                foreach (var pair in query.Split('&'))
                {
                    int eq = pair.IndexOf('=');
                    var key = eq > 0 ? pair[..eq] : pair;
                    if (key != "plugin") continue;
                    var rawValue = eq > 0 ? pair[(eq + 1)..] : "";
                    var plugin = TryUnescape(rawValue) ?? rawValue;
                    if (plugin.Length > 0)
                    {
                        var pluginName = plugin.Split(';')[0];
                        throw new ParseErrorException(ParseErrorKind.UnsupportedTransport, $"plugin: {pluginName}");
                    }
                }
            }
            int at = body.LastIndexOf('@');
            if (at < 0) throw new ParseErrorException(ParseErrorKind.MalformedUri, link);
            var userInfoRaw = body[..at];
            var hostPort = body[(at + 1)..];

            // SIP002 generators commonly percent-encode the base64 userinfo
            // itself (`…d29yZA%3D%3D`). When a `%` is present the encoded form
            // must not be decoded first: the hex digits of `%3D` are themselves
            // alphabet characters, so `…cGFzc3dvcmQ%3D%3D` decodes as
            // `…password7p` — a wrong password that imports cleanly and fails
            // every handshake. Percent-decode first, and only fall back to the
            // raw spelling when the two are the same text.
            var unescaped = TryUnescape(userInfoRaw) ?? userInfoRaw;
            var spellings = unescaped == userInfoRaw ? new[] { userInfoRaw } : new[] { unescaped, userInfoRaw };
            string? userInfo = null;
            foreach (var candidate in spellings)
            {
                var decoded = Base64.DecodeFlexible(candidate);
                // Strict UTF-8, as `String(data:encoding:.utf8)` is: base64 that
                // decodes to non-text is not a userinfo, and replacement
                // characters would let a binary blob through as a password.
                var text = decoded is null ? null : Foundation.Utf8(decoded);
                if (text is not null && text.Contains(':'))
                {
                    userInfo = text;
                    break;
                }
            }
            userInfo ??= unescaped;
            var (method, password) = SplitMethodPassword(userInfo, link);
            var (host, port) = SplitHostPort(hostPort, link);
            return new ProxyServer(name ?? host, ProxyProtocol.Ss, host, port, password, method: method);
        }
        else
        {
            // Legacy: whole thing is base64(method:password@host:port)
            var decoded = Base64.DecodeFlexible(body);
            var decodedStr = decoded is null ? null : Foundation.Utf8(decoded);
            if (decodedStr is null) throw new ParseErrorException(ParseErrorKind.InvalidBase64);
            int at = decodedStr.LastIndexOf('@');
            if (at < 0) throw new ParseErrorException(ParseErrorKind.MalformedUri, link);
            var userInfo = decodedStr[..at];
            var hostPort = decodedStr[(at + 1)..];
            var (method, password) = SplitMethodPassword(userInfo, link);
            var (host, port) = SplitHostPort(hostPort, link);
            return new ProxyServer(name ?? host, ProxyProtocol.Ss, host, port, password, method: method);
        }
    }

    // MARK: - Shared stream-parameter application (VLESS/Trojan)

    /// <summary>Normalize a link's transport name (VLESS/Trojan `type`, VMess
    /// `net`). Real-world links use several aliases for the same transports
    /// (h2 for HTTP/2, kcp for mKCP, raw/websocket for the long names) and
    /// some transports the bundled engine no longer ships (xhttp/splithttp).
    /// A silent .tcp fallback here used to rewire such links into a plain TCP
    /// connection that could never handshake — unknown transports now fail
    /// the parse loudly, so the subscription importer reports the server as
    /// broken instead of connecting nonsense.</summary>
    private static NetworkType NetworkTypeOf(Dictionary<string, string> q) => NetworkTypeOfJson(q.GetValueOrDefault("type"));

    private static NetworkType NetworkTypeOfJson(string? raw)
    {
        var name = (raw ?? "tcp").ToLowerInvariant();
        return name switch
        {
            "" or "tcp" or "raw" or "none" => NetworkType.Tcp,
            "ws" or "websocket" => NetworkType.Ws,
            "grpc" => NetworkType.Grpc,
            "http" or "h2" => NetworkType.Http,
            "httpupgrade" => NetworkType.HttpUpgrade,
            "quic" => NetworkType.Quic,
            "kcp" or "mkcp" => NetworkType.Kcp,
            "xhttp" or "splithttp" => NetworkType.Xhttp,
            _ => throw new ParseErrorException(ParseErrorKind.UnsupportedTransport, name),
        };
    }

    private static void ApplyStreamParams(ProxyServer server, Dictionary<string, string> q)
    {
        server.Sni = NonEmpty(q.GetValueOrDefault("sni")) ?? NonEmpty(q.GetValueOrDefault("peer"));
        server.Fingerprint = NonEmpty(q.GetValueOrDefault("fp"));
        server.RealityPublicKey = NonEmpty(q.GetValueOrDefault("pbk"));
        server.RealityShortId = NonEmpty(q.GetValueOrDefault("sid"));
        server.RealitySpiderX = NonEmpty(q.GetValueOrDefault("spx"));
        server.AllowInsecure =
            q.GetValueOrDefault("allowInsecure") == "1" ||
            (q.GetValueOrDefault("allowInsecure")?.ToLowerInvariant() == "true");
        server.HeaderType = NonEmpty(q.GetValueOrDefault("headerType"));
        if (NonEmpty(q.GetValueOrDefault("alpn")) is { } alpn)
            server.Alpn = SplitAlpn(alpn);
        // gRPC carries serviceName in `path`, the :authority header in `host`
        // and its multiplexing mode in `mode`; ws/http use path + Host header.
        // An *empty* serviceName must be dropped, not preferred: some panels
        // emit serviceName= as a placeholder next to a real path=, and Xray
        // cannot dial gRPC without a service name.
        if (server.Network == NetworkType.Grpc)
        {
            server.Path = NonEmpty(q.GetValueOrDefault("serviceName")) ?? NonEmpty(q.GetValueOrDefault("path"));
            server.Host = NonEmpty(q.GetValueOrDefault("host"));
            server.GrpcMultiMode = q.GetValueOrDefault("mode")?.ToLowerInvariant() == "multi";
        }
        else
        {
            server.Path = NonEmpty(q.GetValueOrDefault("path"));
            server.Host = NonEmpty(q.GetValueOrDefault("host"));
        }
        // xhttp keeps its own two parameters: `mode` (auto, packet-up, stream-up,
        // stream-one) and `extra` as a JSON object. Both are stored as written —
        // lower-casing a mode would send the engine a value it does not accept,
        // and an empty one means "the engine's default", not "auto".
        if (server.Network == NetworkType.Xhttp)
        {
            server.XhttpMode = NonEmpty(q.GetValueOrDefault("mode"));
            server.XhttpExtra = NonEmpty(q.GetValueOrDefault("extra"));
        }
        // The vmess JSON carries the query fields itself; the same seed rule
        // applies there, or the link would dial plain mKCP at an obfuscated
        // server and fail without a message.
        if (server.Network == NetworkType.Kcp && NonEmpty(q.GetValueOrDefault("seed")) is { } vmessSeed)
            server.UserData = new Dictionary<string, string> { ["kcpSeed"] = vmessSeed };
    }

    /// <summary>Some generators put the panel's own label in the fragment as
    /// `#Name?serverDescription=&lt;base64&gt;`. Swift reads that parameter, drops the
    /// control characters the label carries (panels embed newlines between the
    /// host and the note) and joins the two parts with « · », shortening the note
    /// to 48 characters so one panel cannot rename the whole list. A fragment
    /// without the parameter is used as written, and a base64 that is not text
    /// leaves the name to the part before the `?` rather than importing a blob as
    /// a label.</summary>
    internal static string DisplayName(string raw)
    {
        var mark = raw.IndexOf('?');
        if (mark < 0) return raw;
        var baseName = raw[..mark];
        string? encoded = null;
        foreach (var pair in raw[(mark + 1)..].Split('&'))
        {
            var kv = pair.Split('=', 2);
            if (kv.Length == 2 && kv[0].ToLowerInvariant() == "serverdescription")
            {
                encoded = kv[1];
                break;
            }
        }
        if (encoded is null) return raw;
        if (Base64.DecodeToString(encoded) is not { } text) return baseName;
        var label = Foundation.TrimFoundationSpacesAndNewlines(
            new string(text.Where(c => !char.IsControl(c)).ToArray()));
        if (label.Length == 0) return baseName;
        // 48 *characters*, as Swift's `prefix(48)` counts them: an emoji flag in
        // a panel name is one character there and two UTF-16 units here.
        var elements = new System.Globalization.StringInfo(label);
        var shortened = elements.SubstringByTextElements(0,
            Math.Min(48, elements.LengthInTextElements));
        return baseName.Length == 0 ? shortened : $"{baseName} · {shortened}";
    }

    // MARK: - Small helpers

    private static string? EmptyToNull(string? s) => string.IsNullOrEmpty(s) ? null : s;
    private static string? NonEmpty(string? s) => string.IsNullOrEmpty(s) ? null : s;

    /// <summary>Swift's `split(separator: ",")` drops empty subsequences, so
    /// `alpn=h2,,h3` is two protocols, not three with a blank: an empty entry
    /// reaches the TLS stack as an empty ALPN identity. Both the link query and
    /// the vmess JSON read their ALPN list here, so one cannot keep a blank the
    /// other drops.</summary>
    internal static List<string> SplitAlpn(string list) =>
        list.Split(',').Where(part => part.Length > 0).Select(part => part.Trim()).ToList();

    /// <summary>Swift's `removingPercentEncoding` answers <em>nil</em> for a
    /// stray `%` — and that nil is what makes a label like `#100%` fall back to
    /// the host instead of importing "100%" as a server name, and a percent
    /// encoded userinfo go to the raw spelling. .NET's unescape is lenient and
    /// hands the bad text back, so the same check happens here first.</summary>
    internal static string? TryUnescape(string s)
    {
        for (var i = 0; i < s.Length; i++)
        {
            if (s[i] != '%') continue;
            if (i + 2 >= s.Length || !IsHexDigit(s[i + 1]) || !IsHexDigit(s[i + 2])) return null;
            i += 2;
        }
        try { return Uri.UnescapeDataString(s); }
        catch (UriFormatException) { return null; }
    }

    private static bool IsHexDigit(char c) =>
        c is >= '0' and <= '9' or >= 'a' and <= 'f' or >= 'A' and <= 'F';

    private static (string Method, string Password) SplitMethodPassword(string s, string link)
    {
        int colon = s.IndexOf(':');
        if (colon < 0) throw new ParseErrorException(ParseErrorKind.MalformedUri, link);
        return (s[..colon], s[(colon + 1)..]);
    }

    private static (string Host, int Port) SplitHostPort(string s, string link)
    {
        // SIP002 allows (and panels love) a trailing path after the port —
        // ss://b64@host:8388/?plugin=… or even a bare /. The query is already
        // peeled, so anything from the first / onward is transport decoration,
        // not part of the authority. IPv6 literals never contain a slash, so
        // this cut is unambiguous.
        int slash = s.IndexOf('/');
        if (slash >= 0) s = s[..slash];

        // IPv6 in brackets: [::1]:443
        if (s.StartsWith('['))
        {
            int close = s.IndexOf(']');
            if (close < 0) throw new ParseErrorException(ParseErrorKind.MalformedUri, link);
            var host = s[1..close];
            var rest = s[(close + 1)..];
            if (!rest.StartsWith(':') || !int.TryParse(rest[1..], out var p6) || p6 is < 1 or > 65535)
                throw new ParseErrorException(ParseErrorKind.MalformedUri, link);
            return (host, p6);
        }
        int colon = s.LastIndexOf(':');
        if (colon < 0 || !int.TryParse(s[(colon + 1)..], out var port) || port is < 1 or > 65535)
            throw new ParseErrorException(ParseErrorKind.MalformedUri, link);
        return (s[..colon], port);
    }
    // MARK: - Amnezia vpn:// container

    /// <summary>
    /// The Amnezia app's config-share format: `vpn://` + base64url (unpadded) of
    /// either a Qt `qCompress` blob (4-byte big-endian uncompressed-length header,
    /// then a zlib stream) or, as the uncompressed fallback Amnezia also exports,
    /// plain base64 of the JSON itself. The JSON is an envelope:
    ///
    ///     { hostName, description, defaultContainer, dns1, dns2,
    ///       containers: [ { container: "amnezia-awg",
    ///                       awg: { last_config: "<json string>", port, … } } ] }
    ///
    /// `last_config` is itself a JSON string (double serialization) whose `config`
    /// field carries the verbatim wg-quick INI — which is exactly what
    /// <see cref="WireGuardLink.ParseConfigText"/> already knows how to eat. The
    /// structured fields back-fill the INI when it is missing.
    /// </summary>
    private static ProxyServer ParseVpnLink(string link)
    {
        var payload = link;
        var schemeEnd = payload.IndexOf("://", StringComparison.Ordinal);
        if (schemeEnd >= 0) payload = payload[(schemeEnd + 3)..];
        payload = Foundation.TrimSpaceLike(payload);
        if (payload.Length == 0) throw new ParseErrorException(ParseErrorKind.MalformedUri, link);
        // A trailing fragment (#Name) is decoration some generators add.
        var hash = payload.IndexOf('#');
        if (hash >= 0) payload = payload[..hash];

        var data = Base64.DecodeFlexible(payload) ?? throw new ParseErrorException(ParseErrorKind.InvalidBase64);

        // qUncompress, done by hand: the payload is a 4-byte length header, a
        // 2-byte zlib wrapper (CMF 0x78 + FLG, and CMF<<8|FLG is a multiple of 31)
        // and then raw DEFLATE whose 4-byte Adler-32 tail is simply never read —
        // which is also how Apple's inflater behaves. Only attempted when the
        // header really looks like qCompress, because an uncompressed export
        // starts with the JSON itself.
        if (data.Length > 6 && data[4] == 0x78 && ((data[4] << 8) | data[5]) % 31 == 0)
        {
            var expected = (data[0] << 24) | (data[1] << 16) | (data[2] << 8) | data[3];
            // The header names the exact uncompressed size, so the output is
            // bounded by it and a truncated inflate cannot pass unnoticed: a
            // short result leaves `data` as the bytes that came in, exactly as
            // Swift's guard does, and the JSON attempt below then fails loudly.
            if (expected > 0 && expected <= 16_000_000 &&
                InflateRaw(data[6..], expected) is { } inflated && inflated.Length == expected)
                data = inflated;
        }

        // The Amnezia JSON envelope first: its double-serialized last_config also
        // *contains* the literal "[Interface]", so checking for the INI first
        // swallowed every real Amnezia export and failed on "missing PrivateKey".
        var envelope = TryJsonObject(data);
        if (envelope is not null) return ServerFromEnvelope(envelope, link);

        // 3x-ui (and some other panels) put the verbatim wg-quick `.conf` straight
        // into the payload — base64url of the INI text, no envelope at all.
        var text = Foundation.Utf8(data);
        if (text is not null && text.Contains("[Interface]", StringComparison.Ordinal))
            return WireGuardLink.ParseConfigText(text, ProxyProtocol.Amnezia);

        throw new ParseErrorException(ParseErrorKind.MalformedUri,
            "vpn link: not an Amnezia config (undecodable JSON)");
    }

    /// <summary>Walks the Amnezia envelope and produces a server. The WireGuard
    /// family goes through the conf parser (verbatim INI); Xray containers hand
    /// their last_config to the ordinary link parser; anything else is refused by
    /// name, because a container this port cannot read is a server it must not
    /// invent.</summary>
    private static ProxyServer ServerFromEnvelope(JsonObject env, string link)
    {
        var containers = new List<JsonObject>();
        if (env["containers"] is JsonArray list)
            foreach (var item in list)
                if (item is JsonObject entry) containers.Add(entry);

        var wanted = Strict.Text(env["defaultContainer"]);
        var container = (wanted is not null
            ? containers.FirstOrDefault(c => Strict.Text(c["container"]) == wanted)
            : null) ?? containers.FirstOrDefault();

        if (container is not null)
        {
            var kind = (Strict.Text(container["container"]) ?? "").ToLowerInvariant();
            foreach (var key in new[] { "awg", "wireguard" })
            {
                if (kind.Contains("xray", StringComparison.Ordinal)) continue;
                if (container[key] is not JsonObject cfg) continue;

                string? ini = LastConfigString(cfg) is { } last ? IniFromLastConfig(last) : null;
                // Older exports store the INI directly under the container.
                if (ini is null && Strict.Text(container["config"]) is { } direct &&
                    direct.Contains("[Interface]", StringComparison.Ordinal))
                    ini = direct;
                if (ini is not { } conf)
                    throw new ParseErrorException(ParseErrorKind.MalformedUri,
                        "vpn link: WireGuard container without a usable config");

                // The envelope is authoritative for DNS when the INI is silent.
                var dns = new[] { Strict.Text(env["dns1"]), Strict.Text(env["dns2"]) }
                    .Where(value => value is { Length: > 0 })
                    .ToList();
                if (dns.Count > 0 && !conf.ToLowerInvariant().Contains("dns", StringComparison.Ordinal))
                    conf += "\nDNS = " + string.Join(", ", dns);

                var server = WireGuardLink.ParseConfigText(conf,
                    kind.Contains("awg", StringComparison.Ordinal) ? ProxyProtocol.Amnezia : ProxyProtocol.WireGuard);
                // Prefer the envelope's human label over the file's absence of one.
                if (Strict.Text(env["description"]) is { Length: > 0 } description)
                    server.Name = description;
                return server;
            }

            if (kind.Contains("xray", StringComparison.Ordinal))
            {
                foreach (var key in new[] { "xray", "vless" })
                {
                    if (container[key] is not JsonObject cfg) continue;
                    if (LastConfigString(cfg) is not { } inner) continue;
                    var trimmed = Foundation.TrimSpaceLike(inner);
                    if (trimmed.ToLowerInvariant().Contains("://", StringComparison.Ordinal))
                        return Parse(trimmed);
                    // A raw JSON xray config: fish the vless link out of it.
                    if (TryJsonObject(Encoding.UTF8.GetBytes(trimmed)) is { } obj)
                        foreach (var value in obj.Select(pair => pair.Value))
                            if (Strict.Text(value) is { } text &&
                                text.ToLowerInvariant().StartsWith("vless://", StringComparison.Ordinal))
                                return Parse(text);
                }
                throw new ParseErrorException(ParseErrorKind.UnsupportedScheme,
                    "vpn link: xray container without a vless link");
            }
        }

        // No containers at all: the JSON itself may already be a last_config —
        // some generators skip the envelope.
        if (IniFromLastConfig(env.ToJsonString()) is { } bareIni)
            return WireGuardLink.ParseConfigText(bareIni, ProxyProtocol.Amnezia);

        throw new ParseErrorException(ParseErrorKind.UnsupportedScheme,
            "vpn link: no supported container (amnezia-awg / wireguard / xray)");
    }

    /// <summary>`last_config` is a JSON string, or — in the double-serialized
    /// form some builds write — a JSON object.</summary>
    private static string? LastConfigString(JsonObject cfg) => cfg["last_config"] switch
    {
        JsonValue value when value.TryGetValue<string>(out var text) => text,
        // Re-serialized the way `JSONSerialization.data(withJSONObject:)` does
        // it — which escapes the solidus. That is not cosmetic: the string below
        // is tested for `"://"`, and an unescaped `vless:\/\/host` reads as a
        // link where Swift's `vless:\/\/…` reads as JSON, so the whole container
        // takes a different branch.
        JsonObject obj => SwiftJson.Compact(obj),
        _ => null,
    };

    /// <summary>The wg-quick INI inside a `last_config` value: it may already BE
    /// the INI, or it may be a JSON object whose `config` field holds it. JSON is
    /// tried first for the same reason the envelope is: the double-serialized form
    /// still contains the literal `[Interface]` inside a JSON string.</summary>
    private static string? IniFromLastConfig(string raw)
    {
        var trimmed = Foundation.TrimSpaceLike(raw);
        if (trimmed.Length == 0) return null;
        if (trimmed.StartsWith("{", StringComparison.Ordinal) &&
            TryJsonObject(Encoding.UTF8.GetBytes(trimmed)) is { } obj &&
            Strict.Text(obj["config"]) is { } conf &&
            conf.ToLowerInvariant().Contains("[interface]", StringComparison.Ordinal))
            return conf;
        return trimmed.ToLowerInvariant().Contains("[interface]", StringComparison.Ordinal) ? trimmed : null;
    }

    private static JsonObject? TryJsonObject(byte[] bytes)
    {
        try
        {
            var text = Foundation.Utf8(bytes);
            if (text is null) return null;
            return JsonNode.Parse(text) as JsonObject;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>Raw-DEFLATE inflate bounded by the size the qCompress header
    /// promises; the Adler-32 tail is never read, so trailing bytes are not an
    /// error — the same licence Apple's `compression_decode_buffer` takes.</summary>
    private static byte[]? InflateRaw(byte[] source, int expected)
    {
        try
        {
            using var input = new MemoryStream(source);
            using var deflate = new System.IO.Compression.DeflateStream(
                input, System.IO.Compression.CompressionMode.Decompress);
            var buffer = new byte[expected];
            var written = 0;
            while (written < expected)
            {
                var read = deflate.Read(buffer, written, expected - written);
                if (read <= 0) break;
                written += read;
            }
            return written > 0 ? buffer[..written] : null;
        }
        catch (InvalidDataException)
        {
            return null;
        }
    }
}

/// <summary>Decomposed URI parts for scheme://userInfo@host:port?query#fragment links.</summary>
internal sealed class UriParts
{
    public string? UserInfo { get; }
    public string? Host { get; }
    public int? Port { get; }
    public Dictionary<string, string> Query { get; } = new();
    public string? Fragment { get; }

    public UriParts(string link)
    {
        int schemeEnd = link.IndexOf("://", StringComparison.Ordinal);
        if (schemeEnd < 0) throw new ParseErrorException(ParseErrorKind.MalformedUri, link);
        var rest = link[(schemeEnd + 3)..];

        // Fragment (#name), percent-decoded. A bare # yields no name — an
        // empty string would surface as a blank label in the UI instead of
        // falling back to the host.
        string? frag = null;
        int hash = rest.IndexOf('#');
        if (hash >= 0)
        {
            frag = TryUnescape(rest[(hash + 1)..]) is { } raw ? ShareLinkParser.DisplayName(raw) : null;
            rest = rest[..hash];
        }
        Fragment = string.IsNullOrEmpty(frag) ? null : frag;

        // Query string.
        int qMark = rest.IndexOf('?');
        if (qMark >= 0)
        {
            var qStr = rest[(qMark + 1)..];
            rest = rest[..qMark];
            foreach (var pair in qStr.Split('&'))
            {
                int eq = pair.IndexOf('=');
                var key = eq > 0 ? pair[..eq] : pair;
                var value = eq > 0 ? pair[(eq + 1)..] : "";
                Query[key] = TryUnescape(value) ?? value;
            }
        }

        // A path after the authority (`host:443/` before the query — the
        // share-link standard allows it and many generators emit `/?…`) is not
        // part of host:port. Left in, "443/" is not a port and the whole
        // "host:443/" becomes the host name, which the engine then cannot dial.
        int slash = rest.IndexOf('/');
        if (slash >= 0) rest = rest[..slash];

        // Authority: userInfo@host:port
        var authority = rest;
        string? user = null;
        int at = authority.LastIndexOf('@');
        if (at >= 0)
        {
            // A stray `%` in a password (panels hand out random ASCII) makes
            // percent-decoding fail, and a nil user part reads as "no
            // credentials in this link" — so the raw text is the fallback, not
            // an absence.
            user = TryUnescape(authority[..at]) ?? authority[..at];
            authority = authority[(at + 1)..];
        }
        UserInfo = user;

        // host:port with IPv6 bracket support. A port outside 1…65535 parses
        // fine as an integer but fails the engine's outbound bind at connect
        // time with an opaque error — reject it here, at the source.
        int? PortValue(string s) =>
            int.TryParse(s, out var p) && p is >= 1 and <= 65535 ? p : null;

        if (authority.StartsWith('['))
        {
            int close = authority.IndexOf(']');
            if (close >= 0)
            {
                Host = authority[1..close];
                var tail = authority[(close + 1)..];
                Port = tail.StartsWith(':') ? PortValue(tail[1..]) : null;
                return;
            }
        }
        var colon = authority.LastIndexOf(':');
        if (colon >= 0)
        {
            var portPart = authority[(colon + 1)..];
            var hostPart = authority[..colon];
            // The last colon is a port separator only when its tail is all
            // digits *and* the head holds no further colon. An unbracketed IPv6
            // literal is therefore never split: it stays one host with no port
            // and the caller refuses it as "host/port", instead of importing a
            // server that dials address "2001:db8:" on port 1. The digit test is
            // Swift's `Character.isNumber` (Nd + Nl + No), not ASCII-only — the
            // port's own `country` work already needed that same set.
            if (IsSwiftNumberText(portPart) && !hostPart.Contains(':'))
            {
                Host = hostPart;
                Port = PortValue(portPart);
            }
            else
            {
                Host = authority.Length == 0 ? null : authority;
                Port = null;
            }
        }
        else
        {
            Host = authority.Length == 0 ? null : authority;
            Port = null;
        }
    }

    /// <summary>`string.allSatisfy(\.isNumber)` — vacuously true for an empty
    /// tail, which is why `host:` parses as host "host" with no port rather than
    /// as a host named "host:".</summary>
    private static bool IsSwiftNumberText(string text)
    {
        foreach (var scalar in text.EnumerateRunes())
            if (!Country.IsNumberLike(scalar.Value)) return false;
        return true;
    }

    /// <summary>The percent-decode rule is ShareLinkParser's; one grammar for
    /// every field, so a fragment and a userinfo cannot disagree about what a
    /// stray `%` means.</summary>
    private static string? TryUnescape(string s) => ShareLinkParser.TryUnescape(s);

}
