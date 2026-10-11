using AnemiaCore;
using Xunit;

namespace AnemiaCoreTests;

/// <summary>
/// The leak check's judgement, run on canned bodies (the shapes below are taken
/// from the shared `leak/answers.*` fixture) with the network paths injected —
/// because what this screen is trusted for is the difference between «clean» and
/// «I could not measure it», and that difference must not depend on a Windows
/// box being reachable from a test.
/// </summary>
public class LeakTestModelTests
{
    private const string IpsbTemplate =
        """{"ip":"{ip}","country_code":"{cc}","country":"{country}","city":"Berlin","isp":"Telekom"}""";
    private const string TraceTemplate = "ip={ip}\nloc={cc}\nhttp=HTTP/1.1\ntls=TLSv1.3\nwarp=off\n";
    private const string BashWs =
        """[{"ip":"94.140.15.15","country":"DE","country_name":"Germany","asn":"AS49505","org":"Selectel","type":"dns"}]""";

    private static string Ipsb(string ip, string cc, string country) =>
        IpsbTemplate.Replace("{ip}", ip).Replace("{cc}", cc).Replace("{country}", country);

    private static Func<string, Task<string?>> Server(string body, string? v6 = null, string? dns = null) =>
        url => Task.FromResult(url switch
        {
            LeakTestModel.IpsbUrl => body,
            LeakTestModel.Ipv6Url => v6,
            LeakTestModel.DnsIdUrl => "abc123",
            _ when url.StartsWith(LeakTestModel.DnsResultUrl, StringComparison.Ordinal) => dns ?? BashWs,
            _ => null,
        });

    private static Guid ServerId() => Guid.Parse("11111111-1111-1111-1111-111111111111");

    /// <summary>Hidden exit, a provider address measured outside that proves the
    /// two differ: the only shape that earns the word «clean».</summary>
    [Fact]
    public async Task HiddenExitAndADifferentProviderAddressIsClean()
    {
        var report = await LeakTestModel.RunAsync(
            ServerId(),
            Server(Ipsb("203.0.113.9", "nl", "Netherlands")),
            aroundTunnel: _ => Task.FromResult<string?>(Ipsb("198.51.100.7", "de", "Germany")));

        Assert.Equal(LeakTestModel.VerdictKind.Clean, report.Verdict);
        Assert.Empty(report.Findings);
        Assert.Equal("203.0.113.9", report.Exit!.Ip);
        Assert.Equal("198.51.100.7", report.Direct!.Ip);
    }

    /// <summary>The internet sees the provider's own address: traffic went around
    /// the tunnel. This is the one finding the screen exists to catch.</summary>
    [Fact]
    public async Task SameAddressOutsideAndInsideIsABypass()
    {
        var body = Ipsb("198.51.100.7", "de", "Germany");
        var report = await LeakTestModel.RunAsync(
            ServerId(), Server(body), aroundTunnel: _ => Task.FromResult<string?>(body));

        Assert.Equal(LeakTestModel.VerdictKind.Leaks, report.Verdict);
        Assert.True(report.Bypassed);
    }

    /// <summary>No route around the tunnel — no physical interface, or the kill
    /// switch ate the request. «Nothing found» here is not «nothing leaks».</summary>
    [Fact]
    public async Task WithoutTheProviderAddressTheAnswerIsUnknownAndNeverClean()
    {
        var report = await LeakTestModel.RunAsync(
            ServerId(), Server(Ipsb("203.0.113.9", "nl", "Netherlands")), aroundTunnel: null);

        Assert.Null(report.Direct);
        Assert.Equal(LeakTestModel.VerdictKind.Unknown, report.Verdict);
        Assert.Empty(report.Findings);
    }

    [Fact]
    public async Task TunnelOffIsUnprotectedAndAnswersAreItsOwnAddress()
    {
        var report = await LeakTestModel.RunAsync(null, Server(Ipsb("198.51.100.7", "de", "Germany")));
        Assert.Equal(LeakTestModel.VerdictKind.Unprotected, report.Verdict);
        Assert.Equal(report.Exit, report.Direct);
        Assert.False(report.SocksOnly);
        // The same address inside and outside is not a bypass while there is no
        // tunnel to bypass: judging that anyway would put «traffic goes around
        // the VPN» on the screen of a user whose VPN is simply off.
        Assert.Empty(report.Findings);
        Assert.False(report.Bypassed);
    }

    /// <summary>An exit that never answered is a failed check even if a
    /// provider address is on hand — the guard order is the safety of the screen.</summary>
    [Fact]
    public async Task AnUnansweredExitFailsWhateverElseArrived()
    {
        var report = await LeakTestModel.RunAsync(
            ServerId(),
            _ => Task.FromResult<string?>("not json"),
            aroundTunnel: _ => Task.FromResult<string?>(Ipsb("198.51.100.7", "de", "Germany")));
        Assert.Null(report.Exit);
        Assert.Equal(LeakTestModel.VerdictKind.Failed, report.Verdict);
    }

    /// <summary>IPv6 out from the home country while the tunnel is IPv4-only.</summary>
    [Fact]
    public async Task Ipv6FromHomeIsReportedWithItsAddress()
    {
        var report = await LeakTestModel.RunAsync(
            ServerId(),
            Server(Ipsb("203.0.113.9", "nl", "Netherlands"), v6: Ipsb("2001:db8::42", "de", "Germany")),
            aroundTunnel: _ => Task.FromResult<string?>(Ipsb("198.51.100.7", "de", "Germany")));

        Assert.Equal(LeakTestModel.VerdictKind.Leaks, report.Verdict);
        Assert.Equal("2001:db8::42", report.Ipv6Leak?.Ip);
    }

    /// <summary>No v6 route at all is not a leak: the answer is simply nil.</summary>
    [Fact]
    public async Task NoIpv6RouteIsNotALeak()
    {
        var report = await LeakTestModel.RunAsync(
            ServerId(),
            Server(Ipsb("203.0.113.9", "nl", "Netherlands"), v6: null),
            aroundTunnel: _ => Task.FromResult<string?>(Ipsb("198.51.100.7", "de", "Germany")));
        Assert.Null(report.Ipv6);
        Assert.Equal(LeakTestModel.VerdictKind.Clean, report.Verdict);
    }

    /// <summary>id → six lookups → results. The six names are asked under the id
    /// that came back, and the resolver count is part of the contract: fewer
    /// lookups and a resolver that only answers some names is missed.</summary>
    [Fact]
    public async Task DnsProbeAsksSixNamesUnderOneId()
    {
        var asked = new List<string>();
        var report = await LeakTestModel.RunAsync(
            ServerId(),
            Server(Ipsb("203.0.113.9", "nl", "Netherlands")),
            aroundTunnel: _ => Task.FromResult<string?>(Ipsb("198.51.100.7", "de", "Germany")),
            resolve: name => { asked.Add(name); return Task.CompletedTask; });

        Assert.Equal(6, asked.Count);
        Assert.Equal("1.abc123.bash.ws", asked[0]);
        Assert.Single(report.Dns!);
        Assert.Equal("94.140.15.15", report.Dns![0].Ip);
    }

    /// <summary>An id that is not alphanumeric — an error page, an empty body —
    /// must not be pasted into the next URL.</summary>
    [Fact]
    public async Task AnUnusableIdStopsTheDnsProbe()
    {
        var report = await LeakTestModel.RunAsync(
            ServerId(),
            _ => Task.FromResult<string?>(null),
            aroundTunnel: _ => Task.FromResult<string?>(Ipsb("198.51.100.7", "de", "Germany")),
            resolve: _ => Task.CompletedTask);
        Assert.Null(report.Dns);
    }

    /// <summary>A report belongs to the connection it was made for, and for half
    /// an hour after: a stale «clean» under a newly selected server is worse than
    /// no report at all.</summary>
    [Fact]
    public async Task ReportIsCurrentOnlyForItsOwnServerAndOnlyForItsAge()
    {
        var now = DateTimeOffset.UtcNow;
        var report = await LeakTestModel.RunAsync(
            ServerId(), Server(Ipsb("203.0.113.9", "nl", "Netherlands")), now: now);

        Assert.True(report.IsCurrent(ServerId(), now.AddMinutes(29)));
        Assert.False(report.IsCurrent(ServerId(), now.AddMinutes(31)));
        Assert.False(report.IsCurrent(Guid.Parse("22222222-2222-2222-2222-222222222222"), now));
        Assert.False(report.IsCurrent(null, now));
    }

    /// <summary>Both guards at once: nothing answered and the tunnel was down.
    /// Swift asks "did the address check work?" first, so the screen says the
    /// check failed rather than reassuring the user with "no VPN, nothing to
    /// protect" — which is also wrong, because they may believe the VPN is on.</summary>
    [Fact]
    public async Task NoAnswerOutweighsTheTunnelBeingOff()
    {
        var report = await LeakTestModel.RunAsync(null, _ => Task.FromResult<string?>(null));
        Assert.Equal(LeakTestModel.VerdictKind.Failed, report.Verdict);
    }

    /// <summary>An error page is not a test id: the body arrives non-empty, so
    /// only the character check keeps it out of the next URL.</summary>
    [Fact]
    public async Task AnErrorPageIsNotTakenForATestId()
    {
        var report = await LeakTestModel.RunAsync(
            ServerId(),
            url => url == LeakTestModel.DnsIdUrl
                ? Task.FromResult<string?>("<html><body>rate limited</body></html>")
                : Server(Ipsb("203.0.113.9", "nl", "Netherlands"))(url),
            aroundTunnel: _ => Task.FromResult<string?>(Ipsb("198.51.100.7", "de", "Germany")),
            resolve: _ => Task.CompletedTask);
        Assert.Null(report.Dns);
    }

    /// <summary>ip.sb being down must not read as «no provider address»: the
    /// Cloudflare trace answer is the same measurement in another shape.</summary>
    [Fact]
    public async Task ProviderAddressFallsBackToTheTraceEndpoint()
    {
        var report = await LeakTestModel.RunAsync(
            ServerId(),
            Server(Ipsb("203.0.113.9", "nl", "Netherlands")),
            aroundTunnel: url => url == LeakTestModel.IpsbUrl
                ? Task.FromResult<string?>("garbage")
                : Task.FromResult<string?>(TraceTemplate.Replace("{ip}", "198.51.100.7").Replace("{cc}", "DE")));

        Assert.Equal("198.51.100.7", report.Direct?.Ip);
        Assert.Equal(LeakTestModel.VerdictKind.Clean, report.Verdict);
    }

    /// <summary>«Only proxy-aware apps used the VPN» changes what the user should
    /// believe about the rest of the system, so it is recorded on the report.</summary>
    [Fact]
    public async Task SocksOnlyIsRememberedForTheSession()
    {
        var report = await LeakTestModel.RunAsync(
            ServerId(), Server(Ipsb("203.0.113.9", "nl", "Netherlands")), socksOnly: true);
        Assert.True(report.SocksOnly);
    }
}
