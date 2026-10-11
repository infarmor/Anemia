using System.Globalization;
using System.Text;
using System.Text.Json;

namespace AnemiaCore;

/// <summary>
/// Is the tunnel really carrying everything? The address the internet sees, the
/// resolvers that answer this device's lookups, and — measured outside the
/// tunnel — the provider's own address, compared. Port of
/// <c>Sources/LoaderCore/LeakCheck.swift</c>.
///
/// Only the parsing and the judgement live here: the network calls stay in the
/// app, so this half is testable on any machine and is the half the other ports
/// share (one golden, three answers).
/// </summary>
public static class LeakCheck
{
    public sealed record IpInfo(string Ip, string? CountryCode = null, string? Country = null,
                                string? City = null, string? Isp = null);

    public sealed record DnsServer(string Ip, string? CountryCode = null, string? Country = null,
                                   string? Org = null);

    public abstract record Finding
    {
        /// <summary>The internet sees the provider's address: traffic is not in
        /// the tunnel at all.</summary>
        public sealed record TunnelBypassed : Finding;

        /// <summary>IPv6 goes out from the home country.</summary>
        public sealed record Ipv6Leak(IpInfo Info) : Finding;

        /// <summary>These resolvers sit in the home country: the provider can
        /// read the names being looked up.</summary>
        public sealed record DnsLeak(List<DnsServer> Servers) : Finding;
    }

    /// <summary>An answer that is not an answer — the shape the screens show.</summary>
    public sealed class LeakException(string message) : Exception(message);

    // MARK: - Judging

    /// <summary>What is wrong, comparing what the tunnel shows (<paramref name="exit"/>)
    /// with the provider's own address (<paramref name="direct"/>, measured
    /// outside the tunnel). Empty means nothing leaks — or that there is no
    /// direct address to compare with, which is not the same claim and is why
    /// the caller shows "not measured" rather than a green tick.</summary>
    public static List<Finding> Findings(IpInfo? exit, IpInfo? direct, IpInfo? ipv6,
                                         IReadOnlyList<DnsServer> dns)
    {
        var findings = new List<Finding>();
        if (direct is null) return findings;
        if (exit is not null && exit.Ip == direct.Ip) findings.Add(new Finding.TunnelBypassed());

        var home = direct.CountryCode?.ToUpperInvariant();
        var away = exit?.CountryCode?.ToUpperInvariant();
        // A home-country exit hides nothing *by country*, so the country-based
        // verdicts below are not made at all — but the bypass found above stays.
        if (home is null || home == away) return findings;

        if (ipv6 is not null && ipv6.CountryCode?.ToUpperInvariant() == home)
            findings.Add(new Finding.Ipv6Leak(ipv6));
        var local = dns.Where(server => server.CountryCode?.ToUpperInvariant() == home).ToList();
        if (local.Count > 0) findings.Add(new Finding.DnsLeak(local));
        return findings;
    }

    // MARK: - Parsing

    /// <summary>ip.sb's geoip answer. `isp` falls back to the ASN organization,
    /// because the free endpoint fills one or the other.</summary>
    public static IpInfo ParseIpsb(string body)
    {
        using var document = Json(body);
        var root = Root(document);
        var ip = Text(root, "ip") ?? throw Bad("ip.sb: unexpected answer");
        if (ip.Length == 0) throw Bad("ip.sb: unexpected answer");
        return new IpInfo(ip,
            CountryCode: Text(root, "country_code")?.ToUpperInvariant(),
            Country: Text(root, "country"),
            City: Text(root, "city"),
            Isp: Text(root, "isp") ?? Text(root, "asn_organization"));
    }

    /// <summary>Cloudflare's `cdn-cgi/trace` — plain `key=value` lines. It knows
    /// the country, never the provider.</summary>
    public static IpInfo ParseTrace(string body)
    {
        var fields = new Dictionary<string, string>();
        foreach (var line in SplitLines(body))
        {
            // Swift's `split(separator: "=", maxSplits: 1)` drops leading empty
            // pieces, so "=value" is one field and not a key at all; and the
            // value may itself contain '='.
            var first = line.IndexOf('=');
            if (first <= 0 || first == line.Length - 1) continue;
            var parts = new[] { line[..first], line[(first + 1)..] };
            fields[parts[0]] = parts[1];
        }
        var ip = fields.TryGetValue("ip", out var found) && found.Length > 0
            ? found
            : throw Bad("Cloudflare: unexpected answer");
        return new IpInfo(ip, CountryCode: fields.TryGetValue("loc", out var loc) ? loc.ToUpperInvariant() : null);
    }

    /// <summary>bash.ws's dns-leak report: one entry per resolver that asked
    /// about the test name, including non-DNS rows this screen does not show.</summary>
    public static List<DnsServer> ParseBashWs(string body)
    {
        using var document = Json(body);
        if (Root(document) is not JsonElement { ValueKind: JsonValueKind.Array } array)
            throw Bad("bash.ws: unexpected answer");
        var servers = new List<DnsServer>();
        var seen = new HashSet<string>();
        foreach (var entry in array.EnumerateArray())
        {
            if (entry.ValueKind != JsonValueKind.Object) throw Bad("bash.ws: unexpected answer");
            var ip = Text(entry, "ip");
            var type = Text(entry, "type");
            // `ip` and `type` are required by the Decodable shape: a row without
            // them fails the whole answer, not just that row.
            if (ip is null || type is null) throw Bad("bash.ws: unexpected answer");
            if (type != "dns" || !seen.Add(ip)) continue;
            servers.Add(new DnsServer(ip,
                CountryCode: Text(entry, "country")?.ToUpperInvariant(),
                Country: Text(entry, "country_name"),
                Org: Text(entry, "org") ?? Text(entry, "asn")));
        }
        return servers;
    }

    // MARK: - JSON helpers

    private static JsonDocument Json(string body)
    {
        try
        {
            return JsonDocument.Parse(body);
        }
        catch (JsonException)
        {
            throw Bad("unexpected answer");
        }
    }

    /// <summary>A JSON scalar that is not the declared type is a decode failure
    /// in Swift, not a nil — so `{"ip":2030113009}` throws rather than reading
    /// «2030113009».</summary>
    private static string? Text(JsonElement element, string name)
    {
        if (!element.TryGetProperty(name, out var value)) return null;
        return value.ValueKind switch
        {
            JsonValueKind.String => value.GetString(),
            JsonValueKind.Null => null,
            _ => throw Bad("unexpected answer"),
        };
    }

    private static JsonElement Root(JsonDocument document) => document.RootElement;

    private static LeakException Bad(string message) => new(message);

    /// <summary>Swift's `split(whereSeparator: \.isNewline)` over the body.</summary>
    private static List<string> SplitLines(string text)
    {
        var lines = new List<string>();
        var current = new StringBuilder();
        foreach (var c in text)
        {
            if (Foundation.IsSwiftNewline(c))
            {
                if (current.Length > 0) lines.Add(current.ToString());
                current.Clear();
            }
            else current.Append(c);
        }
        if (current.Length > 0) lines.Add(current.ToString());
        return lines;
    }
}
