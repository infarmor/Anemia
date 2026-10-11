namespace AnemiaCore;

/// <summary>
/// The leak check: what the internet sees, what the provider's own address is,
/// and what the two difference means. Port of the orchestration in
/// `Sources/LoaderApp/Core/LeakTestModel.swift` and of `LeakCheck.dnsServers`.
///
/// Everything that touches the network arrives as a delegate, and that shape is
/// not decoration. The three answers must be asked over **different paths**: the
/// exit address through the tunnel, the provider's address around it, bound to
/// the physical interface. On macOS that second one is `curl --interface en0`;
/// on Windows it is a socket bound to the interface's own address, and on a
/// phone the platform refuses the bind outright (Android measured `EPERM`). Only
/// the judging and the ordering are portable logic, so only they live here —
/// and they are the parts that can lie to a user: a "clean" verdict printed
/// without the direct address ever having been measured is the failure this
/// whole screen exists to avoid.
/// </summary>
public static class LeakTestModel
{
    public const string IpsbUrl = "https://api-ipv4.ip.sb/geoip";
    public const string TraceUrl = "https://www.cloudflare.com/cdn-cgi/trace";
    public const string Ipv6Url = "https://api-6.ip.sb/geoip";
    public const string DnsIdUrl = "https://bash.ws/id";
    /// <summary>The id is appended to this, plus "?json".</summary>
    public const string DnsResultUrl = "https://bash.ws/dnsleak/test/";

    public enum VerdictKind
    {
        /// <summary>The VPN is off: nothing is being protected.</summary>
        Unprotected,
        /// <summary>The address answer itself failed.</summary>
        Failed,
        /// <summary>The exit is hidden, but there is no provider address to
        /// compare with — usually the kill switch blocking the direct request.</summary>
        Unknown,
        Leaks,
        Clean,
    }

    public sealed class Report
    {
        public DateTimeOffset Date { get; init; } = DateTimeOffset.UtcNow;
        /// <summary>The server the check ran through; null with the tunnel down.</summary>
        public Guid? ServerId { get; init; }
        /// <summary>Only proxy-aware apps used the VPN (no system tunnel).</summary>
        public bool SocksOnly { get; init; }
        public LeakCheck.IpInfo? Exit { get; init; }
        /// <summary>The provider's own address; with the tunnel down this is <see cref="Exit"/>.</summary>
        public LeakCheck.IpInfo? Direct { get; init; }
        /// <summary>Null: IPv6 does not get out at all.</summary>
        public LeakCheck.IpInfo? Ipv6 { get; init; }
        /// <summary>Null when the DNS test did not answer.</summary>
        public List<LeakCheck.DnsServer>? Dns { get; init; }
        public List<LeakCheck.Finding> Findings { get; init; } = new();

        /// <summary>The order of these guards is the safety of the screen: an
        /// exit that never answered is a failure even when a stale provider
        /// address is on hand, and «no findings» with no direct address is
        /// <see cref="VerdictKind.Unknown"/>, never <see cref="VerdictKind.Clean"/>.</summary>
        public VerdictKind Verdict
        {
            get
            {
                if (Exit is null) return VerdictKind.Failed;
                if (ServerId is null) return VerdictKind.Unprotected;
                if (Findings.Count > 0) return VerdictKind.Leaks;
                return Direct is null ? VerdictKind.Unknown : VerdictKind.Clean;
            }
        }

        public bool Bypassed => Findings.Any(f => f is LeakCheck.Finding.TunnelBypassed);

        public LeakCheck.IpInfo? Ipv6Leak => Findings.OfType<LeakCheck.Finding.Ipv6Leak>()
            .Select(f => f.Info).FirstOrDefault();

        public List<LeakCheck.DnsServer> DnsLeak => Findings.OfType<LeakCheck.Finding.DnsLeak>()
            .Select(f => f.Servers).FirstOrDefault() ?? new List<LeakCheck.DnsServer>();

        /// <summary>Whether the last report still describes this connection:
        /// same server, not older than half an hour.</summary>
        public bool IsCurrent(Guid? server, DateTimeOffset now) =>
            ServerId == server && (now - Date) < TimeSpan.FromMinutes(30);
    }

    /// <summary>
    /// The whole check, with the paths injected. `throughTunnel` answers over the
    /// tunnel (or over the local SOCKS inbound when only proxy-aware apps are
    /// inside it); `aroundTunnel` answers bound to the physical interface and is
    /// null when this machine cannot get around the tunnel at all.
    /// </summary>
    public static async Task<Report> RunAsync(
        Guid? serverId,
        Func<string, Task<string?>> throughTunnel,
        Func<string, Task<string?>>? aroundTunnel = null,
        Func<string, Task>? resolve = null,
        bool socksOnly = false,
        DateTimeOffset? now = null)
    {
        var exitTask = throughTunnel(IpsbUrl);
        var ipv6Task = throughTunnel(Ipv6Url);
        var directTask = serverId is null ? Task.FromResult<LeakCheck.IpInfo?>(null) : DirectAddress(aroundTunnel);
        await Task.WhenAll(exitTask, ipv6Task, directTask);

        var exit = Try(exitTask.Result, LeakCheck.ParseIpsb);
        var ipv6 = Try(ipv6Task.Result, LeakCheck.ParseIpsb);
        // With the tunnel down there is nothing to compare against: what the
        // internet sees *is* the provider's address.
        var direct = serverId is null ? exit : directTask.Result;

        var dns = resolve is null ? null : await DnsServers(throughTunnel, resolve);
        var findings = serverId is null
            ? new List<LeakCheck.Finding>()
            : LeakCheck.Findings(exit, direct, ipv6, dns ?? new List<LeakCheck.DnsServer>());

        return new Report
        {
            Date = now ?? DateTimeOffset.UtcNow,
            ServerId = serverId,
            SocksOnly = serverId is not null && socksOnly,
            Exit = exit,
            Direct = direct,
            Ipv6 = ipv6,
            Dns = dns,
            Findings = findings,
        };
    }

    /// <summary>ip.sb first, Cloudflare's trace as the fallback — the provider's
    /// address, measured outside the tunnel. Null means there was no way around
    /// it (no physical interface, or the kill switch ate the request), which turns
    /// the verdict into «unknown» and never into «clean».</summary>
    public static async Task<LeakCheck.IpInfo?> DirectAddress(Func<string, Task<string?>>? aroundTunnel)
    {
        if (aroundTunnel is null) return null;
        if (Try(await aroundTunnel(IpsbUrl), LeakCheck.ParseIpsb) is { } ipsb) return ipsb;
        return Try(await aroundTunnel(TraceUrl), LeakCheck.ParseTrace);
    }

    /// <summary>One body, either parser; a body that is not the answer the
    /// endpoint promises is no answer at all.</summary>
    private static LeakCheck.IpInfo? Try(string? body, Func<string, LeakCheck.IpInfo> parse)
    {
        if (body is not { Length: > 0 }) return null;
        try
        {
            return parse(body);
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>bash.ws: take a test id, make six lookups under it through the
    /// system resolver, then read which resolvers answered. The id is checked
    /// before it goes into a URL, and an empty one is a failure rather than a
    /// request to `/test/`.</summary>
    public static async Task<List<LeakCheck.DnsServer>?> DnsServers(
        Func<string, Task<string?>> fetch, Func<string, Task> resolve)
    {
        var id = (await Fetch(DnsIdUrl))?.Trim();
        if (string.IsNullOrEmpty(id) || !id.All(IsLetterOrNumber)) return null;
        await Task.WhenAll(Enumerable.Range(1, 6).Select(index => resolve($"{index}.{id}.bash.ws")));
        var body = await Fetch(DnsResultUrl + id + "?json");
        if (body is not { Length: > 0 }) return null;
        try { return LeakCheck.ParseBashWs(body); }
        catch (Exception) { return null; }

        async Task<string?> Fetch(string url)
        {
            try { return await fetch(url); }
            catch (Exception) { return null; }
        }
    }

    /// <summary>Swift's `isLetter || isNumber` over Unicode categories — the id
    /// bash.ws hands out is alphanumeric, and the check exists so a body that is
    /// an error page cannot be pasted into the next URL.</summary>
    private static bool IsLetterOrNumber(char c) =>
        char.IsLetter(c) || Country.IsNumberLike(c);
}
