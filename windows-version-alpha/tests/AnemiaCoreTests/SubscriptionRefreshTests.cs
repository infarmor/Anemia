using AnemiaCore;
using Xunit;

namespace AnemiaCoreTests;

/// <summary>
/// The rules a refresh must keep, pinned here because the merge that replaced
/// them on Windows for months was invisible from the outside: the row looked
/// healthy while it carried servers the panel had revoked.
/// </summary>
public class SubscriptionRefreshTests
{
    private const string LinkA = "vless://11111111-1111-1111-1111-111111111111@a.test:443#A";
    private const string LinkB = "vless://22222222-2222-2222-2222-222222222222@b.test:443#B";

    private static List<ProxyServer> Stored(params string[] links) =>
        SubscriptionParser.Parse(string.Join("\n", links)).Servers;

    private static (RefreshVerdict Verdict, List<ProxyServer> Servers) Apply(
        List<ProxyServer> stored, string body, SubscriptionInfo? info = null, long now = 1_800_000_000) =>
        SubscriptionRules.DecideRefresh(stored, SubscriptionParser.Parse(body), info, now);

    [Fact]
    public void AnEmptyBodyNeverWipesTheList()
    {
        var stored = Stored(LinkA);
        var (verdict, servers) = Apply(stored, "");
        Assert.Equal(RefreshVerdict.NoUsableServers, verdict);
        Assert.Single(servers);
    }

    [Fact]
    public void AnErrorPageIsAFailureNotAnEmptySubscription()
    {
        var stored = Stored(LinkA);
        // A captive portal answers HTML; every line fails to parse.
        var (verdict, servers) = Apply(stored, "<html><body>login</body></html>");
        Assert.Equal(RefreshVerdict.NoUsableServers, verdict);
        Assert.Single(servers);
    }

    [Fact]
    public void ExpiredHeadersSayWhyTheListWasEmpty()
    {
        var info = SubscriptionInfo.Parse(new Dictionary<string, string>
        {
            ["subscription-userinfo"] = "upload=1; download=2; total=3; expire=1700000000",
        });
        Assert.NotNull(info);
        var (verdict, servers) = Apply(Stored(LinkA), "<html>gone</html>", info);
        Assert.Equal(RefreshVerdict.Expired, verdict);
        Assert.Single(servers); // still kept: expired is a message, not a deletion
    }

    [Fact]
    public void ARevokedServerActuallyDisappears()
    {
        // The Windows refresh used to MERGE, so a server the panel dropped stayed
        // listed forever — and a session through it was never torn down.
        var stored = Stored(LinkA, LinkB);
        var (verdict, servers) = Apply(stored, LinkA);
        Assert.Equal(RefreshVerdict.Applied, verdict);
        Assert.Single(servers);
        Assert.Equal("A", servers[0].Name);
    }

    [Fact]
    public void IdsAreCarriedAcrossARefreshSoSelectionSurvives()
    {
        var stored = Stored(LinkA, LinkB);
        var before = stored.Select(s => s.Id).ToList();
        var (verdict, servers) = Apply(stored, string.Join("\n", LinkB, LinkA));
        Assert.Equal(RefreshVerdict.Applied, verdict);
        // Order follows the panel; identity follows the stored entry.
        Assert.Equal(before[1], servers[0].Id);
        Assert.Equal(before[0], servers[1].Id);
    }

    [Fact]
    public void DuplicateIdsAreHandedOutOnce()
    {
        // A panel that lists the same credential twice must not give both rows the
        // same id: every id-keyed list downstream (selection, history, learned
        // masking) would address two servers at once.
        var stored = Stored(LinkA);
        var (verdict, servers) = Apply(stored, LinkA + "\n" + LinkA + "\n" + LinkB);
        Assert.Equal(RefreshVerdict.Applied, verdict);
        Assert.Equal(2, servers.Count); // the repeated link collapses to one entry
        Assert.Distinct(servers.Select(s => s.Id));
    }

    [Fact]
    public void TlsGateUsesTheSchemeNotTheRestOfTheUrl()
    {
        Assert.True(new Subscription("p", "HTTPS://panel.test/sub").TlsProtected);
        Assert.False(new Subscription("p", "http://panel.test/sub").TlsProtected);
        // `https:/x` is one slash short of a protected panel — and a check written
        // as `StartsWith("https:")` would call it safe.
        Assert.False(new Subscription("p", "https:/panel.test/sub").TlsProtected);
    }
}
