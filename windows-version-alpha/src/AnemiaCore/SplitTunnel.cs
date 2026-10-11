using System.Globalization;
using System.Text;

namespace AnemiaCore;

/// <summary>
/// What the user keeps: the switch and the raw lines, one destination per line.
/// The lines are stored as typed, never as parsed entries, so a later change to
/// validation cannot silently rewrite what somebody wrote — the parser runs at
/// connect time on every device instead. Port of Swift's `SplitTunnelRules`.
/// </summary>
public sealed class SplitTunnelRules
{
    public bool Enabled { get; set; } = true;
    public List<string> Entries { get; set; } = new();

    /// <summary>The validated destinations the helper is told about.</summary>
    public List<BypassEntry> ActiveEntries =>
        Enabled ? SplitTunnelParser.Parse(Entries).Entries : new List<BypassEntry>();

    /// <summary>Swift's `Decodable`: an absent or wrongly typed field falls back
    /// to the default instead of failing the whole store.</summary>
    /// <summary>Swift's <c>Decodable</c>: <c>enabled</c> has to be a JSON bool and
    /// <c>entries</c> an array of strings, or the field takes its default — the
    /// whole array, not the good half of it.</summary>
    public static SplitTunnelRules FromJson(System.Text.Json.Nodes.JsonNode? node)
    {
        var rules = new SplitTunnelRules();
        if (node is not System.Text.Json.Nodes.JsonObject obj) return rules;
        rules.Enabled = Strict.Bool(obj["enabled"]) ?? true;
        rules.Entries = Strict.TextArray(obj["entries"]) ?? new List<string>();
        return rules;
    }

    public System.Text.Json.Nodes.JsonNode ToJson()
    {
        var arr = new System.Text.Json.Nodes.JsonArray();
        foreach (var entry in Entries) arr.Add(entry);
        return new System.Text.Json.Nodes.JsonObject
        {
            ["enabled"] = Enabled,
            ["entries"] = arr,
        };
    }
}

/// <summary>
/// Split tunneling ("local bypass"): destinations that must leave through the
/// physical network instead of the VPN — a bank or government site that refuses
/// foreign IPs, a work network, a NAS on another subnet. Port of
/// <c>Sources/LoaderCore/SplitTunnel.swift</c>.
///
/// What persists is the user's raw lines, never these parsed values, so a later
/// validation change cannot silently rewrite what somebody typed. The
/// normalization decides only what the helper is told to route for this run —
/// and it has to agree with Swift and Kotlin, because one rule text on three
/// machines must produce the same routes.
/// </summary>
public readonly struct BypassEntry : IEquatable<BypassEntry>
{
    public enum Kind { IPv4, IPv6, Domain }

    public string Value { get; }
    public Kind EntryKind { get; }

    public BypassEntry(Kind kind, string value)
    {
        Value = value;
        EntryKind = kind;
    }

    public bool IsDomain => EntryKind == Kind.Domain;

    /// <summary>Swift's <c>String(describing:)</c> of the enum case — the shared
    /// golden prints entries this way, so its dump is compared as text.</summary>
    public string Describe() => EntryKind switch
    {
        Kind.IPv4 => "ipv4(\"" + Value + "\")",
        Kind.IPv6 => "ipv6(\"" + Value + "\")",
        _ => "domain(\"" + Value + "\")",
    };

    public bool Equals(BypassEntry other) => other.Value == Value && other.EntryKind == EntryKind;

    public override bool Equals(object? obj) => obj is BypassEntry e && Equals(e);

    public override int GetHashCode() => HashCode.Combine(Value, (int)EntryKind);

    public override string ToString() => Describe();
}

/// <summary>A line the parser refused, with the reason the user is shown.</summary>
public readonly record struct BypassRejection(string Line, string Reason);

public readonly record struct BypassResult(List<BypassEntry> Entries, List<BypassRejection> Rejected);

public static class SplitTunnelParser
{
    /// <summary>Narrowest prefixes accepted: anything broader would route most of
    /// the internet around the tunnel — a VPN switched off by a typo.</summary>
    public const int MinimumIPv4Prefix = 8;
    public const int MinimumIPv6Prefix = 16;

    /// <summary>Networks a bypass may never cover: loopback (never tunneled
    /// anyway) and the helper's own tunnel ranges — sending those to the physical
    /// gateway would cut the tunnel's DNS and its link to the engine.</summary>
    private static readonly (uint Network, int Prefix, string Reason)[] ReservedIPv4 =
    {
        (0x7F00_0000, 8, "loopback never goes through the VPN"),
        (0xAC1C_0000, 24, "that range is the VPN tunnel itself"),   // 172.28.0.0/24
        (0xAC1D_0000, 24, "that range is the VPN tunnel itself"),   // 172.29.0.0/24
    };

    private static (string Reason, BypassEntry Entry, bool Ok) Bad(string reason)
        => (reason, default, false);

    private static (string Reason, BypassEntry Entry, bool Ok) Good(BypassEntry entry)
        => ("", entry, true);

    /// <summary>Parse a free-form paste: newlines, commas, semicolons and
    /// whitespace all separate destinations; <c>#</c> starts a comment.</summary>
    public static BypassResult ParseText(string text)
    {
        var pieces = new List<string>();
        foreach (var line in SwiftSplit(text, Foundation.IsSwiftNewline))
        {
            var hash = line.IndexOf('#');
            var code = hash >= 0 ? line[..hash] : line;
            pieces.AddRange(SwiftSplit(code, c => c is ',' or ';' or ' ' or (char)0x09));
        }
        return Parse(pieces);
    }

    /// <summary>Parse stored lines, one destination each. Duplicates collapse;
    /// the first occurrence keeps its place.</summary>
    public static BypassResult Parse(IEnumerable<string> lines)
    {
        var entries = new List<BypassEntry>();
        var seen = new HashSet<BypassEntry>();
        var rejected = new List<BypassRejection>();
        foreach (var raw in lines)
        {
            var line = Foundation.TrimFoundationSpacesAndNewlines(raw);
            if (line.Length == 0 || line.StartsWith("#", StringComparison.Ordinal)) continue;
            var (reason, entry, ok) = ParseEntry(line);
            if (ok) { if (seen.Add(entry)) entries.Add(entry); }
            else rejected.Add(new BypassRejection(line, reason));
        }
        return new BypassResult(entries, rejected);
    }

    /// <summary>Split validated entries into what the helper routes by address
    /// and what it must resolve first.</summary>
    public static (List<string> Networks, List<string> Domains) Partition(
        IEnumerable<BypassEntry> entries)
    {
        var networks = new List<string>();
        var domains = new List<string>();
        foreach (var entry in entries)
        {
            if (entry.IsDomain) domains.Add(entry.Value);
            else networks.Add(entry.Value);
        }
        return (networks, domains);
    }

    internal static (string Reason, BypassEntry Entry, bool Ok) ParseEntry(string input)
    {
        var s = Foundation.SwiftLower(input);
        var scheme = s.IndexOf("://", StringComparison.Ordinal);
        if (scheme >= 0) s = s[(scheme + 3)..];
        var at = s.LastIndexOf('@');
        if (at >= 0) s = s[(at + 1)..];

        // Bracketed IPv6 URL host: [2001:db8::1]:443/path. The prefix that some
        // people append after the bracket is not read: `[2001:db8::1]/64` is /128.
        if (s.StartsWith("[", StringComparison.Ordinal))
        {
            var close = s.IndexOf(']');
            if (close > 0) return ParseIPv6(s[1..close], null);
        }

        var slash = s.IndexOf('/');
        var head = slash >= 0 ? s[..slash] : s;
        var tail = slash >= 0 ? s[(slash + 1)..] : null;
        if (head.Count(c => c == ':') > 1) return ParseIPv6(head, tail);

        var colon = head.IndexOf(':');
        var host = colon >= 0 ? head[..colon] : head;
        if (IsIPv4Literal(host))
            // A prefix only belongs to a bare address, not to host:port/path.
            return colon < 0 ? ParseIPv4(host, tail) : ParseIPv4(host, null);
        return ParseDomain(host);
    }

    // MARK: - IPv4

    /// <summary>Four dot-separated runs of ASCII digits. Swift's
    /// <c>Character.isNumber</c> also answers true for Arabic-Indic digits, which
    /// is why the ASCII bound is here rather than decorative: «1٠.2.3.4» has to
    /// fall through to the domain branch, not be read as an address.</summary>
    internal static bool IsIPv4Literal(string text)
    {
        var parts = text.Split('.', StringSplitOptions.None);
        return parts.Length == 4 && parts.All(part => part.Length > 0 &&
            part.All(c => c is >= '0' and <= '9'));
    }

    private static (string Reason, BypassEntry Entry, bool Ok) ParseIPv4(string address, string? prefix)
    {
        uint value = 0;
        foreach (var part in address.Split('.', StringSplitOptions.RemoveEmptyEntries))
        {
            if (part.Length > 3 ||
                !uint.TryParse(part, NumberStyles.None, CultureInfo.InvariantCulture, out var octet) ||
                octet > 255 || (part.Length > 1 && part[0] == '0'))
                return Bad("not a valid IPv4 address");
            value = value << 8 | octet;
        }
        var bits = 32;
        if (prefix is not null)
        {
            var parsed = SwiftInt.Parse(prefix);
            if (parsed is null || parsed < 0 || parsed > 32)
                return Bad("prefix length must be 0–32");
            bits = (int)parsed.Value;
        }
        if (bits < MinimumIPv4Prefix)
            return Bad($"too broad — /{bits} would send most traffic around the VPN" +
                       $" (use /{MinimumIPv4Prefix} or narrower)");
        var mask = bits == 0 ? 0u : uint.MaxValue << (32 - bits);
        var network = value & mask;
        foreach (var reserved in ReservedIPv4)
        {
            var common = Math.Min(bits, reserved.Prefix);
            var commonMask = common == 0 ? 0u : uint.MaxValue << (32 - common);
            if ((network & commonMask) == (reserved.Network & commonMask))
                return Bad(reserved.Reason);
        }
        var octets = new[] { 24, 16, 8, 0 }
            .Select(shift => ((network >> shift) & 0xFF).ToString(CultureInfo.InvariantCulture));
        return Good(new BypassEntry(BypassEntry.Kind.IPv4,
            string.Join(".", octets) + "/" + bits.ToString(CultureInfo.InvariantCulture)));
    }

    // MARK: - IPv6

    private static (string Reason, BypassEntry Entry, bool Ok) ParseIPv6(string address, string? prefix)
    {
        if (address.Contains('%') || !Inet6.Pton(address, out var bytes))
            return Bad("not a valid IPv6 address");
        var bits = 128;
        if (prefix is not null)
        {
            var parsed = SwiftInt.Parse(prefix);
            if (parsed is null || parsed < 0 || parsed > 128)
                return Bad("prefix length must be 0–128");
            bits = (int)parsed.Value;
        }
        if (bits < MinimumIPv6Prefix)
            return Bad($"too broad — /{bits} would send most IPv6 traffic around the VPN" +
                       $" (use /{MinimumIPv6Prefix} or narrower)");
        if (bytes.SequenceEqual(Inet6.Loopback)) return Bad("loopback never goes through the VPN");
        for (var i = 0; i < 16; i++)
        {
            var keep = Math.Max(0, Math.Min(8, bits - i * 8));
            bytes[i] &= (byte)(keep == 8 ? 0xFF : (0xFF << (8 - keep)) & 0xFF);
        }
        return Good(new BypassEntry(BypassEntry.Kind.IPv6,
            Inet6.Ntop(bytes) + "/" + bits.ToString(CultureInfo.InvariantCulture)));
    }

    // MARK: - Domains

    private static (string Reason, BypassEntry Entry, bool Ok) ParseDomain(string input)
    {
        var host = input;
        if (host.StartsWith("*.", StringComparison.Ordinal)) host = host[2..];
        if (host.StartsWith(".", StringComparison.Ordinal)) host = host[1..];
        if (host.EndsWith(".", StringComparison.Ordinal)) host = host[..^1];
        if (host.Length == 0) return Bad("empty domain");
        var labels = new List<string>();
        foreach (var label in host.Split('.', StringSplitOptions.None))
        {
            if (label.Length == 0) return Bad("not a valid domain");
            var ascii = Punycode.EncodeLabel(label);
            if (ascii is null) return Bad("not a valid domain");
            if (ascii.Length > 63 ||
                !ascii.All(c => (c <= (char)0x7F && (char.IsLetter(c) || char.IsNumber(c))) || c == '-') ||
                ascii[0] == '-' || ascii[^1] == '-')
                return Bad("not a valid domain");
            labels.Add(ascii);
        }
        var domain = string.Join(".", labels);
        if (domain.Length > 253) return Bad("domain is too long");
        // All digits is a broken IP, not a name — `1.2.3.4.5` says so here.
        if (labels.All(label => label.All(c => c is >= '0' and <= '9')))
            return Bad("not a valid IP address or domain");
        return Good(new BypassEntry(BypassEntry.Kind.Domain, domain));
    }

    /// <summary>`split(whereSeparator:)` with Swift's drop-empty default.</summary>
    private static List<string> SwiftSplit(string text, Func<char, bool> isSeparator)
    {
        var parts = new List<string>();
        var current = new StringBuilder();
        foreach (var c in text)
        {
            if (isSeparator(c))
            {
                if (current.Length > 0) parts.Add(current.ToString());
                current.Clear();
            }
            else current.Append(c);
        }
        if (current.Length > 0) parts.Add(current.ToString());
        return parts;
    }
}

/// <summary>
/// IPv6 text forms as the libc calls the Swift side uses them
/// (<c>inet_pton</c>/<c>inet_ntop</c>), not as RFC 5952 says. Measured against
/// `LoaderTool split-tunnel` on macOS (2026-09-27), the printer keeps rules .NET's
/// <c>IPAddress.ToString()</c> does not have: an address with 96 leading zero bits
/// becomes a dotted quad only when the *first two* bytes of the tail are
/// non-zero («::2» stays «::2», «::1:2» becomes «::0.1.0.2»), a v4-mapped one
/// always does, and the compressed zero run is the first longest, not the last.
/// </summary>
internal static class Inet6
{
    /// <summary>::1 — the address the bypass rules refuse as text.</summary>
    public static readonly byte[] Loopback =
        { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };

    /// <summary>Strict <c>inet_pton(AF_INET6)</c>: up to eight 16-bit groups of at
    /// most four hex digits, at most one <c>::</c> that must stand for at least
    /// one group, an IPv4 tail that fills the last two groups, and nothing else —
    /// no scope id (the caller rejects '%'), no leading '+', no spaces.</summary>
    public static bool Pton(string text, out byte[] bytes)
    {
        bytes = new byte[16];
        if (text.Length == 0) return false;

        var head = new List<int>();
        var tail = new List<int>();
        var into = head;
        var sawDoubleColon = false;

        var p = 0;
        if (text[0] == ':')
        {
            if (text.Length < 2 || text[1] != ':') return false;
            p = 2;
            into = tail;
            sawDoubleColon = true;
            if (text.Length == 2) return true;      // "::"
        }

        while (p < text.Length)
        {
            var value = 0;
            var digits = 0;
            var start = p;
            while (p < text.Length && HexValue(text[p]) >= 0)
            {
                value = value * 16 + HexValue(text[p]);
                digits++;
                if (digits > 4 || value > 0xFFFF) return false;
                p++;
            }
            if (digits == 0) return false;

            if (p < text.Length && text[p] == '.')
            {
                // The dotted tail replaces the group being read plus one more;
                // it has to start early enough for both to fit.
                var soFar = ReferenceEquals(into, head) ? head.Count : head.Count + tail.Count;
                if (soFar > 6) return false;
                if (!TryQuad(text, start, out var t1, out var t2, out var t3, out var t4)) return false;
                into.Add((t1 << 8) | t2);
                into.Add((t3 << 8) | t4);
                break;
            }

            into.Add(value);
            if (p == text.Length) break;
            if (text[p] != ':') return false;
            p++;
            if (p < text.Length && text[p] == ':')
            {
                if (sawDoubleColon) return false;              // a second "::"
                p++;
                sawDoubleColon = true;
                into = tail;
                if (p == text.Length) break;                    // ends with "::"
                if (HexValue(text[p]) < 0) return false;
            }
            else if (p == text.Length) return false;                // single trailing ':'
        }

        // A quad in front of a `::` (`1.2.3.4::`) never reaches here as 8 groups,
        // so the count check below already refuses it.
        var explicitCount = head.Count + tail.Count;
        // "::" has to stand for at least one group; without it there must be
        // exactly eight, and the head-list alone must not overflow.
        if (sawDoubleColon ? explicitCount > 7 : explicitCount != 8) return false;
        if (head.Count > 8 || tail.Count > 8) return false;

        var index = 0;
        foreach (var group in head) Write(group, bytes, index++);
        for (var fill = explicitCount; fill < 8; fill++) Write(0, bytes, index++);
        foreach (var group in tail) Write(group, bytes, index++);
        return index == 8;

        static void Write(int value, byte[] into, int at)
        {
            into[at * 2] = (byte)(value >> 8);
            into[at * 2 + 1] = (byte)(value & 0xFF);
        }
    }

    /// <summary>Four decimal octets filling the rest of the string, each at most
    /// three digits, no leading zeros, none over 255.</summary>
    private static bool TryQuad(string text, int from, out int a, out int b, out int c, out int d)
    {
        a = b = c = d = 0;
        var parts = text[from..].Split('.', StringSplitOptions.None);
        if (parts.Length != 4) return false;
        var values = new int[4];
        for (var i = 0; i < 4; i++)
        {
            var part = parts[i];
            if (part.Length == 0 || part.Length > 3 ||
                !part.All(ch => ch is >= '0' and <= '9') ||
                (part.Length > 1 && part[0] == '0')) return false;
            values[i] = int.Parse(part, CultureInfo.InvariantCulture);
            if (values[i] > 255) return false;
        }
        (a, b, c, d) = (values[0], values[1], values[2], values[3]);
        return true;
    }

    private static int HexValue(char c) =>
        c is >= '0' and <= '9' ? c - '0'
            : c is >= 'a' and <= 'f' ? c - 'a' + 10
            : c is >= 'A' and <= 'F' ? c - 'A' + 10 : -1;

    /// <summary><c>inet_ntop(AF_INET6)</c> as macOS prints it — see the class
    /// comment for the two v4 shapes and the tie rule, all measured.</summary>
    public static string Ntop(byte[] b)
    {
        var leadingZero = b.Take(10).All(x => x == 0);
        if (leadingZero && b[10] == 0xFF && b[11] == 0xFF) return "::ffff:" + Quad(b);
        if (leadingZero && b[10] == 0 && b[11] == 0 && (b[12] != 0 || b[13] != 0)) return "::" + Quad(b);

        var groups = new int[8];
        for (var g = 0; g < 8; g++) groups[g] = (b[g * 2] << 8) | b[g * 2 + 1];

        var bestStart = -1;
        var bestLength = 1;      // a run of one group is not compressed
        for (var g = 0; g < 8; g++)
        {
            if (groups[g] != 0) continue;
            var end = g;
            while (end < 8 && groups[end] == 0) end++;
            if (end - g > bestLength) { bestLength = end - g; bestStart = g; }
            g = end - 1;
        }

        var text = new StringBuilder();
        for (var g = 0; g < 8; g++)
        {
            if (bestStart >= 0 && g >= bestStart && g < bestStart + bestLength)
            {
                if (g == bestStart) text.Append("::");
                continue;
            }
            if (text.Length > 0 && !(bestStart >= 0 && g == bestStart + bestLength))
                text.Append(':');
            text.Append(groups[g].ToString("x", CultureInfo.InvariantCulture));
        }
        return text.Length == 0 ? "::" : text.ToString();
    }

    private static string Quad(byte[] b) =>
        string.Join(".", new[] { b[12], b[13], b[14], b[15] }
            .Select(x => x.ToString(CultureInfo.InvariantCulture)));
}

/// <summary>
/// RFC 3492 Punycode for one domain label («пример» → «xn--e1afmkfd»). Routing
/// rules are matched against the ASCII form a TLS ClientHello carries, so a
/// Cyrillic domain typed by the user has to be converted before it means
/// anything to the helper. Port of Swift's <c>Punycode</c>, including its
/// refusal to encode on overflow — a label that does not fit is rejected rather
/// than wrapped. Counters are 64-bit because Swift's <c>Int</c> is: an
/// <c>int</c> here would overflow on a long label with high code points, where
/// the Swift original keeps going.
/// </summary>
public static class Punycode
{
    private const long Base = 36, TMin = 1, TMax = 26, Skew = 38, Damp = 700;
    private const long InitialBias = 72, InitialN = 128;

    /// <summary>Encode one label; pure-ASCII labels pass through unchanged. Null
    /// when the label overflows the encoding.</summary>
    public static string? EncodeLabel(string label)
    {
        var scalars = label.EnumerateRunes().Select(rune => (long)rune.Value).ToArray();
        if (!scalars.Any(value => value >= InitialN)) return label;

        var output = new List<char>(scalars.Where(value => value < InitialN)
                                           .Select(value => (char)value));
        var basicCount = output.Count;
        var handled = basicCount;
        if (basicCount > 0) output.Add('-');

        long n = InitialN, delta = 0, bias = InitialBias;
        while (handled < scalars.Length)
        {
            long m = long.MaxValue;
            foreach (var value in scalars)
                if (value >= n && value < m) m = value;
            if (m == long.MaxValue) return null;
            try { delta = checked(delta + (m - n) * (handled + 1)); }
            catch (OverflowException) { return null; }
            n = m;
            foreach (var c in scalars)
            {
                if (c < n) delta++;
                if (c != n) continue;
                var q = delta;
                for (long k = Base; ; k += Base)
                {
                    var t = k <= bias ? TMin : (k >= bias + TMax ? TMax : k - bias);
                    if (q < t) break;
                    output.Add(Digit((int)(t + (q - t) % (Base - t))));
                    q = (q - t) / (Base - t);
                }
                output.Add(Digit((int)q));
                bias = Adapt(delta, handled + 1, handled == basicCount);
                delta = 0;
                handled++;
            }
            delta++;
            n++;
        }
        return "xn--" + new string(output.ToArray());
    }

    private static long Adapt(long delta, long points, bool first)
    {
        var d = first ? delta / Damp : delta / 2;
        d += d / points;
        long k = 0;
        while (d > ((Base - TMin) * TMax) / 2)
        {
            d /= Base - TMin;
            k += Base;
        }
        return k + ((Base - TMin + 1) * d) / (d + Skew);
    }

    private static char Digit(int d) => (char)(d < 26 ? 97 + d : 22 + d);
}
