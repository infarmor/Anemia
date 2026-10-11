using System.Globalization;

namespace AnemiaCore;

/// <summary>
/// The WireGuard-family link formats: a wg-quick style conf (plain text or
/// base64 of one), and the query form v2rayN and the Amnezia panels hand out.
/// Port of <c>parseAWGLink</c>, <c>parseAWGQueryLink</c>, <c>parseConfigText</c>
/// and their helpers in <c>Sources/LoaderCore/ShareLinkParser.swift</c>.
/// </summary>
public static class WireGuardLink
{
    /// <summary>`awg://` / `amnezia://` / `wireguard://` / `wg://`.</summary>
    public static ProxyServer Parse(string link, ProxyProtocol proto)
    {
        var scheme = SchemeOf(link);
        var body = Foundation.TrimSpaceLike(link[(scheme.Length + 3)..]);
        string? name = null;
        var hash = body.IndexOf('#');
        if (hash >= 0)
        {
            name = DisplayName(Foundation.PercentDecode(body[(hash + 1)..]) ?? body[(hash + 1)..]);
            body = body[..hash];
        }

        // The query form always carries "?" (publickey=…); base64 never does —
        // and never carries "@" either, so a bare base64 blob of a conf cannot be
        // mistaken for `privkey@host:port` here.
        var hasAuthority = HasAuthority(body);
        var looksLikeQuery = body.Contains('?');
        if ((hasAuthority || looksLikeQuery) && !body.Contains("[Interface]", StringComparison.Ordinal))
            return ParseQuery(body, proto, name, link);

        // Base64 of a whole conf, possibly percent-wrapped by the exporter.
        var unescaped = Foundation.PercentDecode(body) ?? body;
        var decoded = DecodeText(body) ?? DecodeText(unescaped);
        if (decoded is null || (!decoded.Contains("[Interface]", StringComparison.Ordinal) &&
                                !decoded.Contains("[Peer]", StringComparison.Ordinal)))
            throw new ParseErrorException(ParseErrorKind.MalformedUri, link);
        var server = ParseConfigText(decoded, proto);
        if (!string.IsNullOrEmpty(name)) server.Name = name;
        return server;
    }

    /// <summary>Foundation's `^[^/?#]+@`. The run before the matched "@" may
    /// itself contain "@" — `amnezia://@@host:port` has an empty userinfo in front
    /// of a real one, and demanding that the first at-sign be the boundary sent
    /// that link down the base64 branch instead (link14 of the shared fixture).
    /// </summary>
    private static bool HasAuthority(string body)
    {
        for (var i = 1; i < body.Length; i++)
        {
            if (body[i] is '/' or '?' or '#') return false;
            if (body[i] == '@') return true;
        }
        return false;
    }

    private static string? DecodeText(string text) =>
        Base64.DecodeFlexible(text) is { } data ? Foundation.Utf8(data) : null;

    /// <summary>`wireguard://KEY@host:port?publickey=…&jc=…`.</summary>
    private static ProxyServer ParseQuery(string body, ProxyProtocol proto, string? name, string link)
    {
        var rest = body.StartsWith("?", StringComparison.Ordinal) ? body[1..] : body;
        // Split off the authority: everything before the first "?" (or all of it)
        // is `privkey@host:port`.
        var question = rest.IndexOf('?');
        var authority = question >= 0 ? rest[..question] : rest;
        var queryRaw = question >= 0 ? rest[(question + 1)..] : "";

        var query = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var pair in queryRaw.Split('&'))
        {
            if (pair.Length == 0) continue;
            var equals = pair.IndexOf('=');
            var key = (equals >= 0 ? pair[..equals] : pair).ToLowerInvariant();
            var value = equals >= 0 ? pair[(equals + 1)..] : "";
            query[key] = Foundation.PercentDecode(value) ?? value;
        }

        var privateKey = "";
        var host = "";
        var port = 0;
        var at = authority.LastIndexOf('@');
        if (at >= 0)
        {
            var userRaw = authority[..at];
            // Doubly-encoded userinfo (base64 OF the 44-character key): the
            // payload is the key's own ASCII text, so it is 44 bytes long. The
            // check used to demand 32 bytes, which no input can satisfy — such a
            // link stored the base64 wrapper as its private key.
            if (Base64.DecodeFlexible(userRaw) is { Length: 44 } wrapped &&
                Foundation.Utf8(wrapped) is { Length: 44 } key)
                privateKey = key;
            else
                privateKey = Foundation.PercentDecode(userRaw) ?? userRaw;
            authority = authority[(at + 1)..];
        }
        if (privateKey.Length == 0) privateKey = query.GetValueOrDefault("privatekey", "");
        if (privateKey.Length == 0) throw new ParseErrorException(ParseErrorKind.MissingField, "private key");

        var colon = authority.LastIndexOf(':');
        if (colon >= 0 && SwiftInt.Parse(authority[(colon + 1)..]) is { } candidate &&
            candidate is >= 1 and <= 65535)
        {
            var head = authority[..colon];
            // IPv6 literals arrive bracketed in authority position; a stored
            // "[2001:db8::1]" fails resolution at connect.
            if (head.Length > 2 && head[0] == '[' && head[^1] == ']') head = head[1..^1];
            host = head;
            port = (int)candidate;
        }
        if (host.Length == 0 || port == 0) throw new ParseErrorException(ParseErrorKind.MissingField, "host/port");

        var profile = new WireGuardProfile(query.GetValueOrDefault("publickey", ""))
        {
            PresharedKey = NonEmpty(query.GetValueOrDefault("presharedkey")),
            AllowedIPs = SplitList(query.TryGetValue("allowedips", out var allowed) ? allowed : "0.0.0.0/0, ::/0"),
            Dns = SplitList(query.GetValueOrDefault("dns", "")),
            Mtu = NonEmpty(query.GetValueOrDefault("mtu")) is { } mtuText ? (int?)SwiftInt.Parse(mtuText) : null,
            KeepAlive = FirstInt(query.GetValueOrDefault("keepalive"),
                                 query.GetValueOrDefault("persistentkeepaliveinterval")),
        };

        var obfuscation = ObfuscationFromQuery(query);
        if (proto == ProxyProtocol.Amnezia && obfuscation is null)
        {
            // An amnezia:// link with no obfuscation parameters at all would be
            // indistinguishable from plain WireGuard — keep the AWG label and let
            // the engine run the unobfuscated handshake.
            obfuscation = new AwgObfuscation();
        }

        var server = new ProxyServer
        {
            Name = name ?? host,
            Proto = proto,
            Address = host,
            Port = port,
            Credential = privateKey,
            Awg = obfuscation,
            WgProfile = profile,
        };
        // The interface address (v2rayN `address`, sing-box-style `ip`,
        // `localaddress`): like a conf's Address, the only source the server
        // accepts inner packets from.
        var listed = NonEmpty(query.GetValueOrDefault("address"))
                     ?? NonEmpty(query.GetValueOrDefault("ip"))
                     ?? NonEmpty(query.GetValueOrDefault("localaddress"));
        if (listed is not null && InterfaceAddressList(listed) is { } address)
            server.UserData = new Dictionary<string, string> { ["wgAddress"] = address };
        _ = link;
        return server;
    }

    /// <summary>A wg-quick style `[Interface]`/`[Peer]` conf — the interchange
    /// format of the Amnezia app, wg-quick itself and every panel's export. Keys
    /// are matched case-insensitively, and the obfuscation keys accept both the
    /// wiki's CamelCase (`Jc`, `H1`) and the UAPI's lowercase (`jc`, `h1`)
    /// spelling.</summary>
    public static ProxyServer ParseConfigText(string raw, ProxyProtocol proto = ProxyProtocol.Amnezia)
    {
        // A UTF-8 BOM (the norm for .conf files exported on Windows) is not in
        // Foundation's whitespace set: left in place it made the first
        // "[Interface]" line miss the section check, silently voiding the whole
        // section and failing with a misleading "missing PrivateKey".
        var text = Foundation.TrimSpaceLike(raw.StartsWith("\uFEFF", StringComparison.Ordinal) ? raw[1..] : raw);
        var lower = text.ToLowerInvariant();
        if (!lower.Contains("[interface]") && !lower.Contains("[peer]"))
            throw AwgConfig("not a WireGuard config (no [Interface]/[Peer] section)");

        var section = "";
        var interface_ = new Dictionary<string, string>(StringComparer.Ordinal);
        var peer = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var rawLine in SplitLines(text))
        {
            var line = Foundation.TrimFoundationSpaces(rawLine);
            if (line.StartsWith("[", StringComparison.Ordinal))
            {
                section = line.ToLowerInvariant();
                continue;
            }
            if (section.Length == 0) continue;
            var equals = line.IndexOf('=');
            if (equals < 0) continue;
            var key = Foundation.TrimFoundationSpaces(line[..equals]).ToLowerInvariant();
            var value = Foundation.TrimFoundationSpaces(line[(equals + 1)..]);
            switch (section)
            {
                case "[interface]": interface_[key] = value; break;
                case "[peer]": peer[key] = value; break;
            }
        }

        if (NonEmpty(interface_.GetValueOrDefault("privatekey")) is not { } privateKey)
            throw AwgConfig("missing PrivateKey");
        if (NonEmpty(peer.GetValueOrDefault("publickey")) is not { } publicKey)
            throw AwgConfig("missing peer PublicKey");
        if (NonEmpty(peer.GetValueOrDefault("endpoint")) is not { } endpoint)
            throw AwgConfig("missing Endpoint in [Peer]");

        var endpointParts = endpoint.Contains('/') ? endpoint[..endpoint.IndexOf('/')] : endpoint;
        var lastColon = endpointParts.LastIndexOf(':');
        if (lastColon < 0 || SwiftInt.Parse(endpointParts[(lastColon + 1)..]) is not { } portValue ||
            portValue is < 1 or > 65535)
            throw AwgConfig("Endpoint must be host:port — got " + endpoint);
        var host = HostFromEndpoint(endpointParts);

        var o = new AwgObfuscation
        {
            JunkPackets = LongKey(interface_, "jc", "junkpacketcount"),
            JunkMin = LongKey(interface_, "jmin", "junkpacketminsize"),
            JunkMax = LongKey(interface_, "jmax", "junkpacketmaxsize"),
            InitPadding = LongKey(interface_, "s1", "initpacketjunksize"),
            ResponsePadding = LongKey(interface_, "s2", "responsepacketjunksize"),
            CookiePadding = LongKey(interface_, "s3", "cookiepacketjunksize"),
            TransportPadding = LongKey(interface_, "s4", "transportpacketjunksize"),
            Header1 = StrKey(interface_, "h1", "magicheader1"),
            Header2 = StrKey(interface_, "h2", "magicheader2"),
            Header3 = StrKey(interface_, "h3", "magicheader3"),
            Header4 = StrKey(interface_, "h4", "magicheader4"),
            HeaderProtectionKey = StrKey(interface_, "headerprotectionkey"),
            ContentPaddingAddition = StrKey(interface_, "contentpaddingaddition"),
            RekeyAfterTime = StrKey(interface_, "rekeyaftertime"),
            RekeyTimeout = StrKey(interface_, "rekeytimeout"),
            RejectAfterTime = StrKey(interface_, "rejectaftertime"),
            KeepaliveTimeout = StrKey(interface_, "keepalivetimeout"),
            MaxHandshakeAttempts = StrKey(interface_, "maxhandshakeattempts"),
        };
        o.SpecialHandshakes = Enumerable.Range(1, 5)
            .Select(index => StrKey(interface_, "i" + index))
            .Where(value => value is not null)
            .Select(value => value!)
            .ToList();
        if (interface_.TryGetValue("randomtrailers", out var trailers)) o.RandomTrailers = Flag(trailers);
        if (interface_.TryGetValue("disablecookies", out var cookies)) o.DisableCookies = Flag(cookies);

        // Any parameter at all makes it AmneziaWG: a 2.x/3.x conf whose only
        // obfuscation key is, say, ContentPaddingAddition must not be downgraded
        // to plain WireGuard (the handshake would fail silently).
        var hasObfuscation = !o.IsEmpty;
        // A conf without obfuscation keys parsed as amnezia:// is plain
        // WireGuard in disguise — save the honest protocol, because the engine
        // choice and the UI badge follow it.
        var actualProto = proto == ProxyProtocol.Amnezia && !hasObfuscation
            ? ProxyProtocol.WireGuard : proto;

        var profile = new WireGuardProfile(publicKey)
        {
            PresharedKey = NonEmpty(peer.GetValueOrDefault("presharedkey")),
            Mtu = IntKey(interface_, "mtu"),
            KeepAlive = FirstInt(peer.GetValueOrDefault("persistentkeepalive"),
                                 peer.GetValueOrDefault("persistentkeepaliveinterval")),
        };

        // A conf that names no AllowedIPs keeps the full-tunnel default: the
        // profile is only overridden when it lists something, and replacing the
        // default with an empty list would route nothing at all.
        if (SplitList(peer.GetValueOrDefault("allowedips", "")) is { Count: > 0 } allowedIps)
            profile.AllowedIPs = allowedIps;
        if (SplitList(interface_.GetValueOrDefault("dns", "")) is { Count: > 0 } dns)
            profile.Dns = dns;

        var server = new ProxyServer
        {
            Name = host,
            Proto = actualProto,
            Address = host,
            Port = (int)portValue,
            Credential = privateKey,
            Awg = actualProto == ProxyProtocol.Amnezia || hasObfuscation ? o : null,
            WgProfile = profile,
        };
        // The conf's own Address list is authoritative; userData is always set,
        // with an empty string when the profile names none, exactly as Swift does.
        server.UserData = new Dictionary<string, string>
        {
            ["wgAddress"] = interface_.TryGetValue("address", out var listed) &&
                            InterfaceAddressList(listed) is { } addresses ? addresses : "",
        };
        return server;
    }

    /// <summary>Query-param → obfuscation, with v2rayN's CamelCase aliases
    /// folded onto the UAPI names (the query keys are already lowercased).</summary>
    private static AwgObfuscation? ObfuscationFromQuery(Dictionary<string, string> q)
    {
        int? I(params string[] keys)
        {
            foreach (var key in keys)
                if (NonEmpty(q.GetValueOrDefault(key)) is { } raw && SwiftInt.Parse(raw) is { } value) return (int)value;
            return null;
        }
        string? S(params string[] keys)
        {
            foreach (var key in keys)
                if (NonEmpty(q.GetValueOrDefault(key)) is { } raw) return raw;
            return null;
        }

        var o = new AwgObfuscation
        {
            JunkPackets = I("jc", "junkpacketcount"),
            JunkMin = I("jmin", "junkpacketminsize"),
            JunkMax = I("jmax", "junkpacketmaxsize"),
            InitPadding = I("s1", "initpacketjunksize"),
            ResponsePadding = I("s2", "responsepacketjunksize"),
            CookiePadding = I("s3", "cookiepacketjunksize"),
            TransportPadding = I("s4", "transportpacketjunksize"),
            Header1 = S("h1", "magicheader1"),
            Header2 = S("h2", "magicheader2"),
            Header3 = S("h3", "magicheader3"),
            Header4 = S("h4", "magicheader4"),
            HeaderProtectionKey = S("headerprotectionkey"),
            ContentPaddingAddition = S("contentpaddingaddition"),
            RekeyAfterTime = S("rekeyaftertime"),
            RekeyTimeout = S("rekeytimeout"),
            RejectAfterTime = S("rejectaftertime"),
            KeepaliveTimeout = S("keepalivetimeout"),
            MaxHandshakeAttempts = S("maxhandshakeattempts"),
        };
        o.SpecialHandshakes = Enumerable.Range(1, 5)
            .Select(index => S("i" + index))
            .Where(value => value is not null)
            .Select(value => value!)
            .ToList();
        if (q.TryGetValue("randomtrailers", out var trailers)) o.RandomTrailers = Flag(trailers);
        if (q.TryGetValue("disablecookies", out var cookies)) o.DisableCookies = Flag(cookies);
        return o.IsEmpty ? null : o;
    }

    /// <summary>The interface address list, kept whole: `Address = 10.8.1.2/32,
    /// fd42::2/128` means the peer has both, and dropping either one leaves that
    /// family routed into a tunnel whose server never assigned it an address.
    /// Bare entries get the host prefix the way wg-quick does.</summary>
    private static string? InterfaceAddressList(string list)
    {
        var entries = new List<string>();
        foreach (var part in list.Split(','))
        {
            var text = Foundation.TrimFoundationSpaces(part);
            if (text.Length == 0) continue;
            var slash = text.IndexOf('/');
            var head = slash >= 0 ? text[..slash] : text;
            // Swift's `split(separator: "/", maxSplits: 1)` omits empty
            // subsequences, so `10.7.0.2/` is ONE piece — a bare address that
            // earns its /32 — while `10.7.0.2/32` is two. Reading the trailing
            // slash as an empty prefix dropped the interface address of every
            // link written as `address=10.7.0.2/`, and the server then had no
            // source address for the tunnel at all.
            var tail = slash >= 0 ? text[(slash + 1)..] : null;
            if (tail is { Length: 0 }) tail = null;
            if (head.Length == 0 && tail is not null) { head = tail; tail = null; }
            if (tail is not null)
            {
                // A prefix the tunnel settings cannot express (/999) has to be
                // dropped here rather than reach the platform API.
                if (!DirectResolver.IsIPAddress(head) || SwiftInt.Parse(tail) is not { } prefix) continue;
                var limit = head.Contains(':') ? 128 : 32;
                if (prefix < 0 || prefix > limit) continue;
                entries.Add(text);
                continue;
            }
            if (DirectResolver.IsIPv4(head)) entries.Add(head + "/32");
            else if (DirectResolver.IsIPv6(head)) entries.Add(head + "/128");
        }
        return entries.Count == 0 ? null : string.Join(", ", entries);
    }

    /// <summary>Port of Swift's `displayName(fromFragment:)` — one rule for
    /// every scheme, so an `amnezia://…#Name?serverDescription=…` and a
    /// `vless://…#same` cannot import two different labels from one link.</summary>
    public static string DisplayName(string raw) => ShareLinkParser.DisplayName(raw);

    private static string HostFromEndpoint(string endpoint)
    {
        if (endpoint.Length > 1 && endpoint[0] == '[')
        {
            var close = endpoint.IndexOf(']');
            if (close > 0) return endpoint[1..close];
        }
        var colon = endpoint.LastIndexOf(':');
        return colon >= 0 ? endpoint[..colon] : endpoint;
    }

    private static int? IntKey(Dictionary<string, string> map, params string[] keys) =>
        keys.Select(key => map.GetValueOrDefault(key))
            .Where(raw => raw is not null)
            .Select(raw => SwiftInt.Parse(raw!))
            .FirstOrDefault(value => value is not null) is { } value ? (int)value : null;

    /// <summary>The same, un-narrowed: Swift reads the junk-packet keys into
    /// `Int`, so a conf written by another client can carry a value that has no
    /// int32 spelling. Reading it as int would drop the number, and with it the
    /// server, where the Mac keeps both and refuses at validation instead.</summary>
    private static long? LongKey(Dictionary<string, string> map, params string[] keys) =>
        keys.Select(key => map.GetValueOrDefault(key))
            .Where(raw => raw is not null)
            .Select(raw => SwiftInt.Parse(raw!))
            .FirstOrDefault(value => value is not null);

    private static string? StrKey(Dictionary<string, string> map, params string[] keys) =>
        keys.Select(key => NonEmpty(map.GetValueOrDefault(key)))
            .FirstOrDefault(value => value is not null);

    private static int? FirstInt(string? first, string? second) =>
        NonEmpty(first) is { } a && SwiftInt.Parse(a) is { } aValue ? (int)aValue
        : NonEmpty(second) is { } b && SwiftInt.Parse(b) is { } bValue ? (int)bValue : null;

    private static List<string> SplitList(string raw) =>
        raw.Split(',').Select(Foundation.TrimFoundationSpaces).Where(entry => entry.Length > 0).ToList();

    private static bool Flag(string raw)
    {
        var value = Foundation.TrimFoundationSpaces(raw).ToLowerInvariant();
        return value is "1" or "true" or "on" or "yes";
    }

    private static string? NonEmpty(string? value) =>
        value is null || Foundation.TrimFoundationSpaces(value).Length == 0 ? null : value;

    /// <summary>Split on Swift's newline set, keeping the pieces between
    /// consecutive separators the way `split(whereSeparator:)` does.</summary>
    private static List<string> SplitLines(string text)
    {
        var lines = new List<string>();
        var start = 0;
        for (var i = 0; i < text.Length; i++)
        {
            if (!Foundation.IsSwiftNewline(text[i])) continue;
            lines.Add(text[start..i]);
            start = i + 1;
        }
        if (start < text.Length) lines.Add(text[start..]);
        return lines;
    }

    private static string SchemeOf(string link)
    {
        var end = link.IndexOf("://", StringComparison.Ordinal);
        return end < 0 ? "" : link[..end].ToLowerInvariant();
    }

    private static ParseErrorException AwgConfig(string reason) =>
        new(ParseErrorKind.MalformedUri, "AmneziaWG config: " + reason);
}
