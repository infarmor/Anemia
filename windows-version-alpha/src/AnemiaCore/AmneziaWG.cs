using System.Globalization;
using System.Text.Json.Nodes;

namespace AnemiaCore;

/// <summary>A saved AmneziaWG block whose field type is not what the
/// schema declared: Swift's decoder throws, which costs the whole server, and
/// the caller of this code turns that into "drop the entry" rather than
/// "default the field".</summary>
public sealed class AwgShapeException(string field) : System.Exception(field);

/// <summary>
/// AmneziaWG protocol generations. Each version strictly extends the previous
/// one's obfuscation set; the engine on the other end must be at least as new as
/// the version a config names, or its UAPI parser rejects the keys. Port of
/// <c>AWGVersion</c> in <c>Sources/LoaderCore/AmneziaWG.swift</c>.
/// </summary>
public enum AwgVersion
{
    V1 = 0,
    V15 = 1,
    V2 = 2,
    V3 = 3,
    V31 = 4,
}

public static class AwgVersionExtensions
{
    /// <summary>The wire spelling the generations are named by.</summary>
    public static string Raw(this AwgVersion version) => version switch
    {
        AwgVersion.V1 => "1.0",
        AwgVersion.V15 => "1.5",
        AwgVersion.V2 => "2.0",
        AwgVersion.V3 => "3.0",
        AwgVersion.V31 => "3.1",
        _ => "1.0",
    };

    /// <summary>Highest generation whose marker parameters are present. A config
    /// that only sets S1/S2/H1–H4 declares itself 1.0 even though a 3.1 engine
    /// accepts it — the version describes what the config <em>uses</em>.</summary>
    public static AwgVersion Detect(AwgObfuscation? obfuscation)
    {
        if (obfuscation is null) return AwgVersion.V1;
        if (obfuscation.RandomTrailers == true || obfuscation.DisableCookies == true) return AwgVersion.V31;
        if (obfuscation.HeaderProtectionKey is not null ||
            obfuscation.ContentPaddingAddition is not null ||
            obfuscation.HasTimingOverrides) return AwgVersion.V3;
        if (obfuscation.CookiePadding is not null || obfuscation.TransportPadding is not null ||
            new[] { obfuscation.Header1, obfuscation.Header2, obfuscation.Header3, obfuscation.Header4 }
                .Any(header => header is not null && header.Contains('-'))) return AwgVersion.V2;
        if (obfuscation.SpecialHandshakes.Count > 0) return AwgVersion.V15;
        return AwgVersion.V1;
    }
}

/// <summary>
/// The AmneziaWG obfuscation parameter set, exactly as a server config or a
/// share link carries it. Every field is optional: plain WireGuard servers carry
/// none of these, and older saved state predates the whole struct.
///
/// Values the protocol allows to be ranges (H1–H4 from 2.0) stay strings —
/// <c>"1234567"</c> or <c>"1234567-1234599"</c> — so a range survives a round trip
/// without a range type everywhere.
/// </summary>
public sealed class AwgObfuscation : IEquatable<AwgObfuscation>
{
    // Swift declares these as `Int` — 64-bit. Stored any narrower, a file
    // written by another port loses its server here rather than its value.
    public long? JunkPackets { get; set; }
    public long? JunkMin { get; set; }
    public long? JunkMax { get; set; }
    public long? InitPadding { get; set; }
    public long? ResponsePadding { get; set; }
    public long? CookiePadding { get; set; }
    public long? TransportPadding { get; set; }
    public string? Header1 { get; set; }
    public string? Header2 { get; set; }
    public string? Header3 { get; set; }
    public string? Header4 { get; set; }
    public List<string> SpecialHandshakes { get; set; } = new();
    public string? HeaderProtectionKey { get; set; }
    public string? ContentPaddingAddition { get; set; }
    public string? RekeyAfterTime { get; set; }
    public string? RekeyTimeout { get; set; }
    public string? RejectAfterTime { get; set; }
    public string? KeepaliveTimeout { get; set; }
    public string? MaxHandshakeAttempts { get; set; }
    public bool? RandomTrailers { get; set; }
    public bool? DisableCookies { get; set; }

    public bool HasTimingOverrides =>
        RekeyAfterTime is not null || RekeyTimeout is not null || RejectAfterTime is not null ||
        KeepaliveTimeout is not null || MaxHandshakeAttempts is not null;

    /// <summary>No parameter at all — plain WireGuard on the wire.</summary>
    public bool IsEmpty => Equals(new AwgObfuscation());

    public bool Equals(AwgObfuscation? other) => other is not null &&
        JunkPackets == other.JunkPackets && JunkMin == other.JunkMin && JunkMax == other.JunkMax &&
        InitPadding == other.InitPadding && ResponsePadding == other.ResponsePadding &&
        CookiePadding == other.CookiePadding && TransportPadding == other.TransportPadding &&
        Header1 == other.Header1 && Header2 == other.Header2 && Header3 == other.Header3 &&
        Header4 == other.Header4 && SpecialHandshakes.SequenceEqual(other.SpecialHandshakes) &&
        HeaderProtectionKey == other.HeaderProtectionKey &&
        ContentPaddingAddition == other.ContentPaddingAddition &&
        RekeyAfterTime == other.RekeyAfterTime && RekeyTimeout == other.RekeyTimeout &&
        RejectAfterTime == other.RejectAfterTime && KeepaliveTimeout == other.KeepaliveTimeout &&
        MaxHandshakeAttempts == other.MaxHandshakeAttempts &&
        RandomTrailers == other.RandomTrailers && DisableCookies == other.DisableCookies;

    public override bool Equals(object? obj) => Equals(obj as AwgObfuscation);

    public override int GetHashCode() =>
        HashCode.Combine(
            HashCode.Combine(JunkPackets, JunkMin, JunkMax, InitPadding, ResponsePadding),
            HashCode.Combine(CookiePadding, TransportPadding, Header1, Header2, Header3),
            Header4);


    // MARK: - The saved form
    //
    // Swift's `AWGObfuscation.init(from:)` is hand-written: every field is
    // `try c.decodeIfPresent(…)`, so a *wrong type* throws and costs the whole
    // server (that is the `{"junkPackets":"5"}` case in the state fixture),
    // while an absent one is simply nil. The one deliberate exception is the
    // legacy integer `contentPaddingAddition`: files written before the ranges
    // were modeled hold a number there, and a strict string decode would drop
    // every saved AmneziaWG server.

    public static AwgObfuscation? FromJson(JsonNode? node)
    {
        if (node is null) return null;
        if (node is not JsonObject obj) return null;      // a wrong-typed container is the caller's failure
        var awg = new AwgObfuscation();
        // Integers: junkPackets/junkMin/junkMax/initPadding/responsePadding/
        // cookiePadding/transportPadding. A string where a number belongs is a
        // failed decode, which the caller turns into "drop this server".
        foreach (var (key, assign) in new (string, System.Action<long?>)[]
        {
            ("junkPackets", v => awg.JunkPackets = v), ("junkMin", v => awg.JunkMin = v),
            ("junkMax", v => awg.JunkMax = v), ("initPadding", v => awg.InitPadding = v),
            ("responsePadding", v => awg.ResponsePadding = v),
            ("cookiePadding", v => awg.CookiePadding = v),
            ("transportPadding", v => awg.TransportPadding = v),
        })
        {
            if (!obj.TryGetPropertyValue(key, out var value) || value is null) continue;
            if (Strict.Long(value) is not { } whole) throw new AwgShapeException(key);
            assign(whole);
        }
        foreach (var (key, assign) in new (string, System.Action<string?>)[]
        {
            ("header1", v => awg.Header1 = v), ("header2", v => awg.Header2 = v),
            ("header3", v => awg.Header3 = v), ("header4", v => awg.Header4 = v),
            ("headerProtectionKey", v => awg.HeaderProtectionKey = v),
            ("rekeyAfterTime", v => awg.RekeyAfterTime = v),
            ("rekeyTimeout", v => awg.RekeyTimeout = v),
            ("rejectAfterTime", v => awg.RejectAfterTime = v),
            ("keepaliveTimeout", v => awg.KeepaliveTimeout = v),
            ("maxHandshakeAttempts", v => awg.MaxHandshakeAttempts = v),
        })
        {
            if (!obj.TryGetPropertyValue(key, out var value) || value is null) continue;
            if (Strict.Text(value) is not { } text) throw new AwgShapeException(key);
            assign(text);
        }
        if (obj.TryGetPropertyValue("contentPaddingAddition", out var padding) && padding is not null)
        {
            // Number first (the legacy shape), then the string the ranges are
            // modeled as — Swift tries exactly these two, in this order.
            if (Strict.Long(padding) is { } legacy) awg.ContentPaddingAddition = legacy.ToString(CultureInfo.InvariantCulture);
            else if (Strict.Text(padding) is { } range) awg.ContentPaddingAddition = range;
            else throw new AwgShapeException("contentPaddingAddition");
        }
        foreach (var (key, assign) in new (string, System.Action<bool?>)[]
        {
            ("randomTrailers", v => awg.RandomTrailers = v),
            ("disableCookies", v => awg.DisableCookies = v),
        })
        {
            if (!obj.TryGetPropertyValue(key, out var value) || value is null) continue;
            if (Strict.Bool(value) is not { } flag) throw new AwgShapeException(key);
            assign(flag);
        }
        if (obj.TryGetPropertyValue("specialHandshakes", out var hands) && hands is not null)
        {
            if (Strict.TextArray(hands) is not { } list) throw new AwgShapeException("specialHandshakes");
            awg.SpecialHandshakes = list;
        }
        return awg;
    }

    public JsonObject ToJson()
    {
        var obj = new JsonObject();
        void PutInt(string key, long? value) { if (value is { } v) obj[key] = v; }
        void PutText(string key, string? value) { if (value is not null) obj[key] = value; }
        void PutBool(string key, bool? value) { if (value is { } v) obj[key] = v; }
        PutInt("junkPackets", JunkPackets); PutInt("junkMin", JunkMin); PutInt("junkMax", JunkMax);
        PutInt("initPadding", InitPadding); PutInt("responsePadding", ResponsePadding);
        PutInt("cookiePadding", CookiePadding); PutInt("transportPadding", TransportPadding);
        PutText("header1", Header1); PutText("header2", Header2);
        PutText("header3", Header3); PutText("header4", Header4);
        // Swift writes this array always — it is not optional in the struct.
        obj["specialHandshakes"] = new JsonArray(SpecialHandshakes.Select(h => (JsonNode?)JsonValue.Create(h)).ToArray());
        PutText("headerProtectionKey", HeaderProtectionKey);
        PutText("contentPaddingAddition", ContentPaddingAddition);
        PutText("rekeyAfterTime", RekeyAfterTime); PutText("rekeyTimeout", RekeyTimeout);
        PutText("rejectAfterTime", RejectAfterTime); PutText("keepaliveTimeout", KeepaliveTimeout);
        PutText("maxHandshakeAttempts", MaxHandshakeAttempts);
        PutBool("randomTrailers", RandomTrailers); PutBool("disableCookies", DisableCookies);
        return obj;
    }
}

/// <summary>
/// WireGuard peer values shared by AmneziaWG and plain WireGuard servers. The
/// client private key lives in <see cref="ProxyServer.Credential"/> (so the
/// identity rotates with a key rotation, as with every other protocol's
/// credential); everything describing the <em>peer side</em> lives here.
/// </summary>
public sealed class WireGuardProfile
{
    public string PeerPublicKey { get; set; } = "";
    public string? PresharedKey { get; set; }

    /// <summary>Routes to pull into the tunnel. Defaults to the full tunnel.</summary>
    public List<string> AllowedIPs { get; set; } = new() { "0.0.0.0/0", "::/0" };

    /// <summary>Resolvers to hand the system while tunneled — may carry
    /// hostnames, which are search domains and not resolvers.</summary>
    public List<string> Dns { get; set; } = new();

    public int? Mtu { get; set; }
    public int? KeepAlive { get; set; }

    public WireGuardProfile() { }

    public WireGuardProfile(string peerPublicKey) => PeerPublicKey = peerPublicKey;

    /// <summary>The entries a tunnel may actually hand the system as resolvers:
    /// the address literals, in the order the profile lists them. wg-quick sends
    /// the rest as <c>search</c>, and every platform API that takes resolvers
    /// (iOS <c>NEDNSSettings.servers</c>, macOS <c>networksetup</c>, Android
    /// <c>addDnsServer</c>) wants addresses — so the cut lives here rather than
    /// in three places that would then disagree.</summary>
    public List<string> ResolverAddresses => Dns.Where(DirectResolver.IsIPAddress).ToList();


    /// <summary>Swift's synthesized decoder for this struct: `peerPublicKey`,
    /// <c>allowedIPs</c> and <c>dns</c> are not optional, so a file that omits
    /// them (or holds a number where a list belongs) fails the whole server —
    /// the fixture's "профиль без маршрутов" is exactly that, and the phone
    /// drops it while a lenient reader would route everything through an
    /// empty default.</summary>
    public static WireGuardProfile? FromJson(JsonNode? node)
    {
        if (node is not JsonObject obj) return null;
        var profile = new WireGuardProfile();
        foreach (var key in new[] { "allowedIPs", "dns" })
        {
            if (!obj.TryGetPropertyValue(key, out var value) || Strict.TextArray(value) is not { } list)
                return null;
            if (key == "allowedIPs") profile.AllowedIPs = list; else profile.Dns = list;
        }
        // A JSON null and an absent key mean the same thing to
        // `decodeIfPresent`, so the indexer's null covers both.
        if (Strict.Text(obj["peerPublicKey"]) is not { } peerKey) return null;
        profile.PeerPublicKey = peerKey;
        if (obj["presharedKey"] is { } psk && psk.GetValueKind() != System.Text.Json.JsonValueKind.Null)
        {
            if (Strict.Text(psk) is not { } pskText) return null;
            profile.PresharedKey = pskText;
        }
        foreach (var (key, assign) in new (string, System.Action<int?>)[]
        { ("mtu", v => profile.Mtu = v), ("keepAlive", v => profile.KeepAlive = v) })
        {
            if (obj[key] is not { } value || value.GetValueKind() == System.Text.Json.JsonValueKind.Null) continue;
            if (Strict.Int(value) is not { } whole) return null;
            assign(whole);
        }
        return profile;
    }

    public JsonObject ToJson()
    {
        var obj = new JsonObject { ["peerPublicKey"] = PeerPublicKey };
        if (PresharedKey is { } psk) obj["presharedKey"] = psk;
        obj["allowedIPs"] = new JsonArray(AllowedIPs.Select(a => (JsonNode?)JsonValue.Create(a)).ToArray());
        obj["dns"] = new JsonArray(Dns.Select(a => (JsonNode?)JsonValue.Create(a)).ToArray());
        if (Mtu is { } mtu) obj["mtu"] = mtu;
        if (KeepAlive is { } keepAlive) obj["keepAlive"] = keepAlive;
        return obj;
    }
}

/// <summary>
/// Renders a WireGuard-family server into the artifact the engine consumes: the
/// UAPI <c>set=1</c> script pushed into a running <c>amneziawg-go</c> daemon,
/// plus the checks on a parsed profile. Port of
/// <c>AmneziaWGConfigBuilder</c>.
/// </summary>
public static class AmneziaWgConfigBuilder
{
    /// <summary>The range used when a profile names no IPv4 address of its own.
    /// The server may refuse it — this is "connect anyway", not a guess that
    /// usually works.</summary>
    public const string FallbackTunAddress = "172.29.0.1";

    /// <summary>Problems that would make the config fail *silently* — packets
    /// dropped by the server with no error anywhere. Surfaced at import/connect
    /// instead of leaving the user to discover a dead tunnel.</summary>
    public static List<string> Validate(ProxyServer server, int mtu = 1420)
    {
        var problems = new List<string>();
        if (server.WgProfile is not { } profile)
        {
            problems.Add("missing peer profile (server public key)");
            return problems;
        }
        if (!IsValidWgKey(profile.PeerPublicKey))
            problems.Add("peer public key is not a 32-byte base64 key");
        if (!IsValidWgKey(server.Credential))
            problems.Add("private key is not a 32-byte base64 key");
        if (profile.PresharedKey is { } psk && !IsValidWgKey(psk))
            problems.Add("preshared key is not a 32-byte base64 key");

        var usable = profile.AllowedIPs.Where(entry => AllowedIP(entry) is not null).ToList();
        var unusable = profile.AllowedIPs.Where(entry => AllowedIP(entry) is null).ToList();
        if (unusable.Count > 0)
        {
            // The daemon reads every `allowed_ip=` with netip.ParsePrefix and
            // takes the whole `set=1` script or nothing: one unparseable entry
            // kills a tunnel that looked fine at import.
            problems.Add("AllowedIPs " +
                string.Join(", ", unusable.Select(entry => "'" + entry + "'")) +
                " is not an address/prefix route");
        }
        if (usable.Count == 0)
            problems.Add("AllowedIPs is empty — nothing would route into the tunnel");

        if (profile.Mtu is { } profileMtu && (profileMtu <= 0 || profileMtu > 65535))
            problems.Add($"MTU ({profileMtu}) is not usable — leave it unset or pick 576…1500");
        if (profile.KeepAlive is { } keepAlive && (keepAlive < 0 || keepAlive > 65535))
            problems.Add($"PersistentKeepalive ({keepAlive}) is outside the 0…65535 the daemon parses");

        // The MTU the obfuscation is judged against is the one this profile will
        // actually run at, not the builder default.
        problems.AddRange(ValidateObfuscation(server.Awg, profile.Mtu ?? mtu));
        return problems;
    }

    /// <summary>A route the daemon can use: <c>address/prefix</c> with a prefix
    /// the family allows, or a bare address, which means a host route the way
    /// <c>wg-quick</c> reads it. Null is "the engine would reject this line".</summary>
    public static string? AllowedIP(string entry)
    {
        var trimmed = Foundation.TrimFoundationSpaces(entry);
        if (trimmed.Length == 0) return null;
        var pieces = trimmed.Split(new[] { '/' }, 2);
        var address = pieces[0];
        if (!DirectResolver.IsIPAddress(address)) return null;
        var bits = address.Contains(':') ? 128 : 32;
        if (pieces.Length == 1) return address + "/" + bits;
        if (SwiftInt.Parse(pieces[1]) is not { } prefix || prefix < 0 || prefix > bits) return null;
        return address + "/" + prefix.ToString(CultureInfo.InvariantCulture);
    }

    private static List<string> ValidateObfuscation(AwgObfuscation? o, int mtu)
    {
        var problems = new List<string>();
        if (o is null) return problems;
        // What the daemon will accept: jc/jmin/jmax parse as ParseUint(…, 32) and
        // S1…S4 as ParseUint(…, 16) (device/uapi.go of the pinned amneziawg-go).
        // A negative or oversized value fails the whole IpcSet.
        foreach (var (name, value) in new[]
                 {
                     ("Jc", o.JunkPackets), ("Jmin", o.JunkMin), ("Jmax", o.JunkMax),
                 })
        {
            if (value is { } number && (number < 0L || number > 4_294_967_295L))
                problems.Add($"{name} ({number}) is outside the 0…4294967295 the daemon parses");
        }
        foreach (var (name, value) in new[]
                 {
                     ("S1", o.InitPadding), ("S2", o.ResponsePadding),
                     ("S3", o.CookiePadding), ("S4", o.TransportPadding),
                 })
        {
            if (value is { } number && (number < 0L || number > 65_535L))
                problems.Add($"{name} ({number}) is outside the 0…65535 the daemon parses");
        }
        // A junk packet at or above the MTU gets IP-fragmented — a DPI signature
        // no legit flow produces. Refuse, don't warn.
        if (o.JunkMax is { } junkMax && junkMax >= mtu)
            problems.Add($"Jmax ({junkMax}) ≥ MTU ({mtu}) — junk packets will be fragmented; set Jmax below {mtu}");
        if (o.JunkMin is { } junkMin && o.JunkMax is { } junkTop && junkMin > junkTop)
            problems.Add($"Jmin ({junkMin}) > Jmax ({junkTop})");
        // Documented AmneziaWG trap: this coincidence makes the 148-byte
        // initiation and the 92-byte response the same size again. Subtracted,
        // not added — a link carrying int.Max would otherwise overflow while the
        // validator was explaining why it refused.
        if (o.InitPadding is { } s1 && o.ResponsePadding is { } s2 && s2 >= 56 && s2 - 56 == s1)
            problems.Add($"S1 + 56 = S2 ({s1} + 56 = {s2}) — initiation and response packets become indistinguishable by size; change one");
        // S4 rides the wire as a u8 padding length.
        if (o.TransportPadding is { } s4 && s4 > 255)
            problems.Add($"S4 ({s4}) is above the 255-byte transport-padding limit");

        if (o.HeaderProtectionKey is { } protectionKey)
        {
            if (HexKey(protectionKey) is null)
                problems.Add("HeaderProtectionKey is not a 32-byte key (base64 or hex)");
            // amneziawg-go: header protection needs every padding S1–S4 ≥ 12.
            var shortPaddings = new[]
            {
                ("S1", o.InitPadding), ("S2", o.ResponsePadding),
                ("S3", o.CookiePadding), ("S4", o.TransportPadding),
            }.Where(entry => (entry.Item2 ?? 0) < 12)
             .Select(entry => entry.Item1 + " = " + (entry.Item2?.ToString(CultureInfo.InvariantCulture) ?? "unset"))
             .ToList();
            if (shortPaddings.Count > 0)
                problems.Add("header protection needs S1–S4 ≥ 12 (" + string.Join(", ", shortPaddings) + ")");
        }

        // 3.x ranges ride the wire as 16-bit values.
        foreach (var (name, raw) in new[]
                 {
                     ("ContentPaddingAddition", o.ContentPaddingAddition), ("RekeyAfterTime", o.RekeyAfterTime),
                     ("RekeyTimeout", o.RekeyTimeout), ("RejectAfterTime", o.RejectAfterTime),
                     ("KeepaliveTimeout", o.KeepaliveTimeout), ("MaxHandshakeAttempts", o.MaxHandshakeAttempts),
                 })
        {
            // u16 on the wire: the daemon parses these with ParseUint(…, 16).
            if (raw is not null && ParseRange(raw, 65_535) is null)
                problems.Add($"{name} = {raw} is not a number or range up to 65535");
        }

        // Overlapping header ranges make packets unclassifiable — the engine
        // drops them silently, with no log line.
        var ranges = new List<(string Name, (uint Low, uint High) Range)>();
        foreach (var (name, raw) in new[]
                 {
                     ("H1", o.Header1), ("H2", o.Header2), ("H3", o.Header3), ("H4", o.Header4),
                 })
        {
            // An unset header keeps WireGuard's default type value — legal.
            if (raw is null) continue;
            if (ParseHeaderRange(raw) is not { } parsed)
            {
                problems.Add($"{name} = {raw} is not a number or range");
                continue;
            }
            foreach (var (otherName, other) in ranges.Where(pair => Overlaps(pair.Range, parsed)))
                problems.Add($"{name} range {raw} overlaps {otherName} range — packets would be dropped as unclassifiable");
            ranges.Add((name, parsed));
        }

        // I1–I5 are the one family the daemon takes as free text, appended to the
        // script verbatim — and the script is line-oriented, so a newline inside an
        // I value is one more directive to a root daemon, able to rewrite the
        // private key or the routes that follow it.
        for (var index = 0; index < Math.Min(5, o.SpecialHandshakes.Count); index++)
        {
            if (HasUnprintable(o.SpecialHandshakes[index]))
                problems.Add($"I{index + 1} has a character outside the printable ASCII the chain spec allows");
        }
        return problems;
    }

    /// <summary>Legal configs known to misbehave — logged at connect instead of
    /// refused, since the server side is not the user's to change.</summary>
    public static List<string> Warnings(ProxyServer server)
    {
        var results = new List<string>();
        if (server.Awg is not { RandomTrailers: true } o) return results;
        // amneziawg-go#186: with RandomTrailers on, a transport packet whose
        // random prefix lands inside an H1–H3 range is classified as a handshake
        // and dropped — loss ≈ 1 − ∏(1 − width/2³²).
        double keep = 1.0;
        foreach (var raw in new[] { o.Header1, o.Header2, o.Header3 })
        {
            if (raw is null || ParseHeaderRange(raw) is not { } range) continue;
            keep *= 1 - ((double)range.Item2 - range.Item1 + 1) / 4_294_967_296.0;
        }
        var loss = 1 - keep;
        if (loss <= 0.001) return results;
        results.Add(string.Format(CultureInfo.InvariantCulture,
            "RandomTrailers with wide H1–H3 ranges drops ~{0:F1}% of packets (amneziawg-go #186) — the server should narrow those ranges",
            loss * 100));
        return results;
    }

    public static (uint Low, uint High)? ParseHeaderRange(string raw) => ParseRange(raw, uint.MaxValue);

    private static bool Overlaps((uint Low, uint High) a, (uint Low, uint High) b) =>
        a.Low <= b.High && b.Low <= a.High;

    /// <summary>A value or <c>lo-hi</c> range (decimal or <c>0x</c> hex), bounded
    /// by <paramref name="max"/>. Both spellings are what the daemon takes.</summary>
    public static (uint Low, uint High)? ParseRange(string raw, uint max)
    {
        uint? Value(string text)
        {
            var trimmed = Foundation.TrimFoundationSpaces(text);
            uint? parsed;
            if (trimmed.StartsWith("0x", StringComparison.Ordinal))
            {
                // UInt32(_, radix: 16): no sign, no prefix repeat, letters in
                // either case.
                parsed = uint.TryParse(trimmed[2..], NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var hex)
                    ? hex : null;
            }
            else
            {
                // Foundation's UInt32(String) is NOT uint.Parse: it takes a
                // leading "+" ("1-+9" is the range 1…9, which the shared fixture
                // proves), rejects a "-" and any whitespace, and returns nil for
                // a value out of range.
                parsed = SwiftInt.ParseUnsigned(trimmed, uint.MaxValue) is { } v ? (uint)v : null;
            }
            return parsed is { } value && value <= max ? value : null;
        }

        var dash = raw.IndexOf('-');
        if (dash >= 0)
        {
            if (Value(raw[..dash]) is not { } low || Value(raw[(dash + 1)..]) is not { } high || low > high)
                return null;
            return (low, high);
        }
        return Value(raw) is { } single ? (single, single) : null;
    }

    /// <summary>A key in the lowercase hex the UAPI requires (amneziawg-go
    /// decodes every key with <c>FromHex</c>). Conf files and links carry base64;
    /// an already-hex key (64 chars) passes through. Null when neither is 32
    /// bytes.</summary>
    public static string? HexKey(string raw)
    {
        var text = Foundation.TrimFoundationSpaces(raw);
        if (text.Length == 64 && text.All(IsHexDigit)) return text.ToLowerInvariant();
        // Flexible base64, exactly like the link layer: a saved profile carries
        // the padded form, a pasted one often does not.
        // Strict: a key is 32 bytes or the profile is broken. The lenient
        // decoder would strip a stray character out of a corrupted key and hand
        // back 32 bytes that are not the key the panel meant.
        if (Base64.DecodeStrict(text) is not { Length: 32 } data) return null;
        var builder = new System.Text.StringBuilder(64);
        foreach (var byteValue in data) builder.Append(byteValue.ToString("x2", CultureInfo.InvariantCulture));
        return builder.ToString();

        static bool IsHexDigit(char c) =>
            c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F';
    }

    /// <summary>A WireGuard key is 32 bytes: base64 (44 chars) or the hex the
    /// daemon actually reads. Checking narrower than the builder writes means
    /// refusing a config that works.</summary>
    public static bool IsValidWgKey(string value) => HexKey(value) is not null;

    /// <summary>The address the tunnel interface must carry: the first usable
    /// IPv4 of the profile's own Address list, without its prefix. The server
    /// accepts inner packets only from addresses it assigned this peer, so a
    /// made-up one completes the handshake and then drops every packet.</summary>
    public static string? TunnelIPv4(ProxyServer server)
    {
        foreach (var entry in TunnelAddresses(server))
        {
            var ip = AddressPart(entry);
            if (!DirectResolver.IsIPv4(ip)) continue;
            if (!int.TryParse(ip.Split('.')[0], NumberStyles.None, CultureInfo.InvariantCulture, out var first)) continue;
            // this-network, loopback and multicast/reserved cannot be a tunnel
            // address the server will accept traffic from.
            if (first == 0 || first == 127 || first >= 224) continue;
            return ip;
        }
        return null;
    }

    /// <summary>The profile's own IPv6 interface address, prefix included.</summary>
    public static string? TunnelIPv6(ProxyServer server) =>
        TunnelAddresses(server).FirstOrDefault(entry => AddressPart(entry).Contains(':'));

    /// <summary>The interface addresses a profile names, as written.</summary>
    public static List<string> TunnelAddresses(ProxyServer server) =>
        (server.UserData is { } data && data.TryGetValue("wgAddress", out var listed) ? listed : "")
            .Split(',')
            .Select(Foundation.TrimFoundationSpaces)
            .Where(entry => entry.Length > 0)
            .ToList();

    /// <summary>The `set=1` script for the running daemon. Key names and value
    /// formats are exactly what amneziawg-go's UAPI parser accepts; empty
    /// parameters are omitted rather than sent as blanks, because the engine
    /// rejects `h1=` with an empty value and a plain-WireGuard peer needs the
    /// obfuscation lines absent, not present-but-empty.
    ///
    /// <paramref name="endpointAddress"/> replaces the server's own address on
    /// the `endpoint=` line: the daemon parses it with netip.ParseAddrPort, so a
    /// domain is refused outright — the caller resolves first.</summary>
    public static string MakeUapiSetScript(ProxyServer server, string? endpointAddress = null)
    {
        if (server.WgProfile is not { } profile)
            throw AwgConfig("no peer profile");
        if (HexKey(server.Credential) is not { } privateKey)
            throw AwgConfig("private key is not a 32-byte base64 key");
        if (HexKey(profile.PeerPublicKey) is not { } publicKey)
            throw AwgConfig("peer public key is not a 32-byte base64 key");

        var lines = new List<string> { "set=1", "private_key=" + privateKey };
        if (server.Awg is { } o)
        {
            void Number(string key, long? value)
            {
                if (value is { } number) lines.Add(key + "=" + number.ToString(CultureInfo.InvariantCulture));
            }
            void Text(string key, string? value)
            {
                if (!string.IsNullOrEmpty(value)) lines.Add(key + "=" + value);
            }

            Number("jc", o.JunkPackets);
            Number("jmin", o.JunkMin);
            Number("jmax", o.JunkMax);
            Number("s1", o.InitPadding);
            Number("s2", o.ResponsePadding);
            Number("s3", o.CookiePadding);
            Number("s4", o.TransportPadding);
            Text("h1", o.Header1);
            Text("h2", o.Header2);
            Text("h3", o.Header3);
            Text("h4", o.Header4);
            for (var index = 0; index < Math.Min(5, o.SpecialHandshakes.Count); index++)
                Text("i" + (index + 1), o.SpecialHandshakes[index]);
            if (!string.IsNullOrEmpty(o.HeaderProtectionKey))
            {
                if (HexKey(o.HeaderProtectionKey) is not { } protectionKey)
                    throw AwgConfig("HeaderProtectionKey is not a 32-byte key");
                lines.Add("header_protection_key=" + protectionKey);
            }
            Text("content_padding_addition", o.ContentPaddingAddition);
            Text("rekey_after_time", o.RekeyAfterTime);
            Text("rekey_timeout", o.RekeyTimeout);
            Text("reject_after_time", o.RejectAfterTime);
            Text("keepalive_timeout", o.KeepaliveTimeout);
            Text("max_handshake_attempts", o.MaxHandshakeAttempts);
            if (o.RandomTrailers is { } trailers) lines.Add("random_trailers=" + Bool(trailers));
            if (o.DisableCookies is { } cookies) lines.Add("disable_cookies=" + Bool(cookies));
        }
        lines.Add("replace_peers=true");
        lines.Add("public_key=" + publicKey);
        if (!string.IsNullOrEmpty(profile.PresharedKey))
        {
            if (HexKey(profile.PresharedKey) is not { } psk)
                throw AwgConfig("preshared key is not a 32-byte base64 key");
            lines.Add("preshared_key=" + psk);
        }
        var host = endpointAddress ?? server.Address;
        lines.Add("endpoint=" + (host.Contains(':') ? "[" + host + "]" : host) + ":" +
                  server.Port.ToString(CultureInfo.InvariantCulture));
        if (profile.KeepAlive is { } keepAlive)
            lines.Add("persistent_keepalive_interval=" + keepAlive.ToString(CultureInfo.InvariantCulture));
        lines.Add("replace_allowed_ips=true");
        foreach (var route in profile.AllowedIPs.Select(AllowedIP).Where(route => route is not null))
            lines.Add("allowed_ip=" + route);
        lines.Add("protocol_version=1");
        lines.Add("");   // UAPI scripts end with a blank line

        // The last word for callers that build a script without validating first
        // (diagnostics, the golden tool): these lines go to a root daemon, so a
        // value smuggling a second directive never leaves this function at all.
        foreach (var line in lines)
            if (HasUnprintable(line))
                throw AwgConfig(line.Split('=')[0] + " carries an unprintable character");

        return string.Join("\n", lines);

        static string Bool(bool value) => value ? "true" : "false";
    }

    private static string AddressPart(string entry)
    {
        var slash = entry.IndexOf('/');
        return Foundation.TrimFoundationSpaces(slash >= 0 ? entry[..slash] : entry);
    }

    /// <summary>Characters the UAPI line protocol cannot carry: below 0x20 —
    /// newline included, which is exactly how a smuggled second directive
    /// arrives — and DEL. A script line is one directive; anything that looks
    /// like a newline inside one is a second directive for the root daemon.</summary>
    private static bool HasUnprintable(string text)
    {
        foreach (var c in text)
            if (c < (char)0x20 || c == (char)0x7F) return true;
        return false;
    }

    private static ParseErrorException AwgConfig(string reason) =>
        new(ParseErrorKind.MalformedUri, "AmneziaWG config: " + reason);
}
