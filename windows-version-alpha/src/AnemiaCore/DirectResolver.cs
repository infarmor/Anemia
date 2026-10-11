using System.Globalization;
using System.Net;
using System.Net.Sockets;

namespace AnemiaCore;

/// <summary>
/// Direct (getaddrinfo) DNS resolution used OUTSIDE the tunnel: the VPN
/// server's own address must be known before the engine can provide any
/// tunneled answers, so its resolution can never depend on the proxy.
/// </summary>
public static class DirectResolver
{
    /// <summary>
    /// Whether the string is already a dotted-quad IPv4 literal. Octets must
    /// be plain ASCII digits (a leading "+4" must not parse), each 0…255 with
    /// no leading zero, and exactly four of them — "1..2.3" / "1.2.3." must not
    /// pass. Foundation's check is equally strict, and a profile address read
    /// two ways would be a different address on two platforms.
    /// </summary>
    public static bool IsIPv4(string s)
    {
        var parts = s.Split('.');
        return parts.Length == 4 && parts.All(part =>
            part.Length > 0 &&
            part.All(c => c >= '0' && c <= '9') &&
            !(part.Length > 1 && part[0] == '0') &&
            int.TryParse(part, NumberStyles.None, CultureInfo.InvariantCulture, out var v) &&
            v is >= 0 and <= 255);
    }

    /// <summary>
    /// An IPv6 literal, checked structurally rather than through the resolver:
    /// `Dns.GetHostEntry` answers the same question but falls back to a network
    /// call for anything it cannot parse, which in a config parser means a DNS
    /// lookup (and a stall) on every malformed link.
    ///
    /// Accepted: up to eight colon-separated hex groups with at most one `::`
    /// run, and the IPv4-tail form (`::ffff:10.0.0.1`). Rejected: a zone id
    /// (`%en0`) — not an address a profile can assign.
    /// </summary>
    public static bool IsIPv6(string s)
    {
        if (s.Length == 0 || !s.Contains(':') || s.Contains('%')) return false;
        var body = s;
        var lastColon = body.LastIndexOf(':');
        if (lastColon >= 0 && body.IndexOf('.') > lastColon)
        {
            // An IPv4 tail stands in for the last two groups.
            if (!IsIPv4(body[(lastColon + 1)..])) return false;
            body = body[..lastColon] + ":0:0";
        }
        List<string> groups;
        var doubleColon = body.IndexOf("::", StringComparison.Ordinal);
        if (doubleColon >= 0)
        {
            if (body.IndexOf("::", doubleColon + 1, StringComparison.Ordinal) >= 0) return false;
            var left = body[..doubleColon].Split(':').Where(part => part.Length > 0).ToList();
            var right = body[(doubleColon + 2)..].Split(':').Where(part => part.Length > 0).ToList();
            if (left.Count + right.Count > 7) return false;
            groups = left.Concat(right).ToList();
        }
        else
        {
            groups = body.Split(':').ToList();
            if (groups.Count != 8) return false;
        }
        return groups.All(group => group.Length is >= 1 and <= 4 && group.All(IsHex));
    }

    /// <summary>Either literal form — what a profile's `Address`/`DNS` entries
    /// have to be to be usable as an address rather than a name.</summary>
    public static bool IsIPAddress(string s) => IsIPv4(s) || IsIPv6(s);

    private static bool IsHex(char c) =>
        c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F';

    /// <summary>
    /// Whether the address falls inside 198.18.0.0/15 — the fake-IP pool that
    /// sing-box/clash/mihomo clients hand out from their DNS. A resolution
    /// landing there is never a real destination. Only a literal dotted-quad
    /// can be a fake-IP answer: a hostname that merely starts with "198.18."
    /// (e.g. 198.18.mirror.example.com) is a real, resolvable domain.
    /// </summary>
    public static bool IsFakeIP(string s)
    {
        if (!s.All(c => (c >= '0' && c <= '9') || c == '.')) return false;
        return s.StartsWith("198.18.") || s.StartsWith("198.19.");
    }

    /// <summary>
    /// Resolve a hostname to IPv4 addresses via the system resolver — no
    /// tunnel involvement. Fake-IP answers are filtered out so a concurrently
    /// running fake-IP VPN can't poison the pin.
    /// </summary>
    public static List<string> IPv4(string host)
    {
        if (IsIPv4(host) || IsFakeIP(host)) return new List<string>();
        try
        {
            // AddressFamily.InterNetwork restricts the query to A records.
            var entries = Dns.GetHostEntry(host, AddressFamily.InterNetwork).AddressList;
            var ips = new List<string>();
            foreach (var entry in entries)
            {
                var ip = entry.ToString();
                if (!ips.Contains(ip) && !IsFakeIP(ip)) ips.Add(ip);
            }
            return ips;
        }
        catch (SocketException)
        {
            return new List<string>();
        }
        catch (ArgumentException)
        {
            return new List<string>();
        }
    }

    /// <summary>
    /// Resolve a hostname to IPv6 addresses. Kept apart from the IPv4 query
    /// because the caller decides the families separately: a bypass host route
    /// only means something where the machine has an IPv6 gateway. There is no
    /// fake-IP filter here — that pool is IPv4-only.
    /// </summary>
    public static List<string> IPv6(string host)
    {
        if (IsIPv6(host)) return new List<string>();
        try
        {
            var ips = new List<string>();
            foreach (var entry in Dns.GetHostEntry(host, AddressFamily.InterNetworkV6).AddressList)
            {
                var ip = entry.ToString();
                if (!ips.Contains(ip)) ips.Add(ip);
            }
            return ips;
        }
        catch (SocketException)
        {
            return new List<string>();
        }
        catch (ArgumentException)
        {
            return new List<string>();
        }
    }
}