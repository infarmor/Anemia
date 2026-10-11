using AnemiaCore;
using Xunit;

namespace AnemiaCoreTests;

/// <summary>
/// The split-tunnel decision table: which routes the Windows helper installs,
/// in what order, and what it refuses to touch. Every rule here is a line of
/// `Sources/LoaderHelper/HelperService.swift`; what the tests pin is the
/// Windows half of it — the `route.exe` argument text and the arithmetic over
/// prefixes. The plumbing that reads a real route table can only be measured
/// on a Windows machine, so nothing below claims to have measured it.
/// </summary>
public class SplitTunnelPlanTests
{
    private static SplitTunnelPlan.Env Env(
        string? gatewayV4 = "192.168.1.1",
        string? gatewayV6 = null,
        int? indexV4 = null,
        int? indexV6 = null,
        string[]? onLink = null,
        string[]? tunnelOwned = null,
        string[]? pinsV4 = null,
        string[]? pinsV6 = null)
    {
        var env = new SplitTunnelPlan.Env
        {
            GatewayV4 = gatewayV4,
            GatewayV6 = gatewayV6,
            InterfaceV4 = indexV4,
            InterfaceV6 = indexV6,
            ServerPinsV4 = new List<string>(pinsV4 ?? Array.Empty<string>()),
            ServerPinsV6 = new List<string>(pinsV6 ?? Array.Empty<string>()),
        };
        foreach (var text in onLink ?? Array.Empty<string>())
            env.OnLink.Add(Prefix(text));
        foreach (var text in tunnelOwned ?? Array.Empty<string>())
            env.TunnelOwned.Add(Prefix(text));
        return env;
    }

    private static SplitTunnelPlan.Prefix Prefix(string cidr)
    {
        Assert.True(SplitTunnelPlan.TryPrefix(cidr, out var prefix), cidr + " did not parse");
        return prefix;
    }

    private static List<string> Resolve(params string[] ips) => new(ips);

    private static List<string> None(string _) => new();

    private static string[] Args(SplitTunnelPlan.Result result) =>
        result.Operations.Select(op => op.Arguments).ToArray();

    // MARK: - What one rule becomes

    [Fact]
    public void OneNetworkBecomesOneHostOfItsOwnSize()
    {
        var state = new SplitTunnelPlan.State();
        var result = SplitTunnelPlan.Apply(state, Env(), new[] { "203.0.113.0/24" }, None);

        Assert.Equal(new[] { "add 203.0.113.0 mask 255.255.255.0 192.168.1.1" }, Args(result));
        Assert.Empty(result.Problems);
        Assert.Equal(new[] { "203.0.113.0/24" }, state.NetworksV4);
        Assert.Equal(new[] { "203.0.113.0" }, state.Installed.Select(r => r.Destination));
    }

    [Fact]
    public void AHostIsRoutedAsAHost()
    {
        var state = new SplitTunnelPlan.State();
        var result = SplitTunnelPlan.Apply(state, Env(), new[] { "198.51.100.7" }, None);
        Assert.Equal("add 198.51.100.7 mask 255.255.255.255 192.168.1.1", Args(result)[0]);
    }

    [Theory]
    [InlineData("10.0.0.0/8", "add 10.0.0.0 mask 255.0.0.0 192.168.1.1")]
    [InlineData("10.20.30.0/23", "add 10.20.30.0 mask 255.255.254.0 192.168.1.1")]
    [InlineData("10.20.30.40/32", "add 10.20.30.40 mask 255.255.255.255 192.168.1.1")]
    public void NetmaskTextForPrefixLength(string line, string expected)
    {
        var result = SplitTunnelPlan.Apply(new SplitTunnelPlan.State(), Env(), new[] { line }, None);
        Assert.Equal(expected, Args(result)[0]);
    }

    [Fact]
    public void Ipv6CarriesTheFamilyFlagThePrefixLengthAndItsInterface()
    {
        // route.exe spells an IPv6 mask as a prefix number, not as a mask, and
        // a link-local next hop means nothing without the interface it lives on.
        var env = Env(gatewayV6: "fe80::1", indexV4: 11, indexV6: 12);
        var result = SplitTunnelPlan.Apply(new SplitTunnelPlan.State(), env,
                                          new[] { "2001:db8::/32" }, None);
        Assert.Equal("-6 add 2001:db8:: mask 32 fe80::1 if 12", Args(result)[0]);
    }

    [Fact]
    public void AHostRouteWithoutAnInterfaceStaysUnqualified()
    {
        var result = SplitTunnelPlan.Apply(new SplitTunnelPlan.State(), Env(indexV4: null),
                                          new[] { "198.51.100.7" }, None);
        Assert.DoesNotContain(" if ", Args(result)[0]);
    }

    [Fact]
    public void DeleteNamesTheRouteAndItsSizeOnly()
    {
        var state = new SplitTunnelPlan.State();
        SplitTunnelPlan.Apply(state, Env(gatewayV6: "fe80::1"),
                              new[] { "203.0.113.0/24", "2001:db8::/64" }, None);
        var down = SplitTunnelPlan.TearDown(state);
        Assert.Equal(new[]
        {
            "delete 203.0.113.0 mask 255.255.255.0",
            "-6 delete 2001:db8:: mask 64",
        }, down.Select(op => op.Arguments));
        Assert.True(state.Empty);
    }

    // MARK: - What is refused, and by whom

    [Fact]
    public void TheClientIsNeverBelievedAboutWhatARuleIs()
    {
        // The app validates before sending; the helper re-parses anyway, since
        // a bypass of the whole internet is exactly what a buggy or hostile
        // client would ask for, and it would be permanent if it landed.
        var result = SplitTunnelPlan.Apply(new SplitTunnelPlan.State(), Env(),
                                           new[] { "0.0.0.0/0", "127.0.0.1" }, None);
        Assert.Empty(result.Operations);
        Assert.Equal(new[]
        {
            "0.0.0.0/0: too broad — /0 would send most traffic around the VPN (use /8 or narrower)",
            "127.0.0.1: loopback never goes through the VPN",
        }, result.Problems);
    }

    [Fact]
    public void TheTunnelsOwnRangeIsNotBypassable()
    {
        // The wintun adapter lives at 198.18.0.1/24 inside the fake-IP pool.
        // The shared parser cannot refuse it — Swift and Kotlin route their
        // tunnels out of 172.28/24 — so the ranges that are ours are decided
        // here, where they are known.
        var env = Env(tunnelOwned: new[] { "198.18.0.0/15" });
        var result = SplitTunnelPlan.Apply(new SplitTunnelPlan.State(), env,
                                          new[] { "198.18.5.0/24", "198.0.0.0/8" }, None);
        Assert.Empty(result.Operations);
        Assert.Equal(new[]
        {
            "198.18.5.0/24: that range is the VPN tunnel itself",
            "198.0.0.0/8: that range is the VPN tunnel itself",
        }, result.Problems);
    }

    [Fact]
    public void ARangeNextToTheTunnelIsStillTheUsers()
    {
        var env = Env(tunnelOwned: new[] { "198.18.0.0/15" });
        var result = SplitTunnelPlan.Apply(new SplitTunnelPlan.State(), env,
                                          new[] { "198.20.0.0/16" }, None);
        Assert.Single(result.Operations);
        Assert.Empty(result.Problems);
    }

    [Fact]
    public void ADestinationAlreadyOnTheLinkNeedsNoRoute()
    {
        // The LAN the machine is standing on is reachable with or without the
        // tunnel's default route, and repointing its link route at a gateway
        // sends it through the router twice.
        var env = Env(onLink: new[] { "192.168.1.0/24" });
        var result = SplitTunnelPlan.Apply(new SplitTunnelPlan.State(), env,
                                           new[] { "192.168.1.0/24", "192.168.1.47", "192.168.9.0/24" },
                                           None);
        Assert.Equal(new[] { "add 192.168.9.0 mask 255.255.255.0 192.168.1.1" }, Args(result));
    }

    [Fact]
    public void ABroaderRequestThanTheLinkIsStillRouted()
    {
        // 192.168.0.0/16 is only partly on-link: the rest of it needs a route.
        var env = Env(onLink: new[] { "192.168.1.0/24" });
        var result = SplitTunnelPlan.Apply(new SplitTunnelPlan.State(), env,
                                           new[] { "192.168.0.0/16" }, None);
        Assert.Equal("add 192.168.0.0 mask 255.255.0.0 192.168.1.1", Args(result)[0]);
    }

    [Fact]
    public void ANameOnThePinnedServerLeavesThatRouteAlone()
    {
        // The /32 that keeps the engine's own dial off the tunnel belongs to the
        // session, not to the rule set: a domain answering with it must not get
        // a second route over the top, which is what macOS's `where
        // !bypassV4.contains(ip)` guard does.
        var env = Env(pinsV4: new[] { "203.0.113.9" });
        var result = SplitTunnelPlan.Apply(new SplitTunnelPlan.State(), env, new[] { "server.example" },
                                          _ => Resolve("203.0.113.9", "203.0.113.10"));
        Assert.Equal(new[] { "add 203.0.113.10 mask 255.255.255.255 192.168.1.1" }, Args(result));
    }

    [Fact]
    public void ATypedAddressIsRoutedEvenWhenTheTunnelPinsIt()
    {
        // Writing the server's address as a rule makes it a /32 network entry,
        // and the pin guard only covers hosts resolved from names — macOS
        // re-adds it here too, and the duplicate is refused by the table rather
        // than replacing the pin. Recorded so the difference from the domain
        // case above is a fact, not an accident.
        var env = Env(pinsV4: new[] { "203.0.113.9" });
        var result = SplitTunnelPlan.Apply(new SplitTunnelPlan.State(), env,
                                          new[] { "203.0.113.9", "198.51.100.0/24" }, None);
        Assert.Equal(new[]
        {
            "add 203.0.113.9 mask 255.255.255.255 192.168.1.1",
            "add 198.51.100.0 mask 255.255.255.0 192.168.1.1",
        }, Args(result));
    }

    [Fact]
    public void ANetworkIsRoutedEvenWhenItsGatewayIsAPin()
    {
        // The pin guard is about host routes only: a network covering the
        // server is the user's business, and macOS routes it too.
        var env = Env(pinsV4: new[] { "203.0.113.9" });
        var result = SplitTunnelPlan.Apply(new SplitTunnelPlan.State(), env,
                                           new[] { "203.0.113.0/24" }, None);
        Assert.Single(result.Operations);
    }

    [Fact]
    public void IPv6WaitsForAnIPv6Gateway()
    {
        var without = SplitTunnelPlan.Apply(new SplitTunnelPlan.State(), Env(gatewayV6: null),
                                            new[] { "2001:db8::/32" }, None);
        Assert.Empty(without.Operations);
        Assert.Empty(without.Problems);    // as on macOS: silent, not a complaint

        var state = new SplitTunnelPlan.State();
        var with = SplitTunnelPlan.Apply(state, Env(gatewayV6: "fe80::1"), new[] { "2001:db8::/32" }, None);
        Assert.Single(with.Operations);
    }

    [Fact]
    public void NothingIsPromisedWithoutAPhysicalGateway()
    {
        var state = new SplitTunnelPlan.State();
        SplitTunnelPlan.Apply(state, Env(), new[] { "203.0.113.0/24" }, None);
        var result = SplitTunnelPlan.Apply(state, Env(gatewayV4: null), new[] { "198.51.100.0/24" }, None);
        // What was there comes down; nothing new is promised; the user is told.
        Assert.Equal(new[] { "delete 203.0.113.0 mask 255.255.255.0" }, Args(result));
        Assert.Equal(new[] { "no physical gateway" }, result.Problems);
    }

    [Fact]
    public void EmptyRulesAskForNothing()
    {
        var result = SplitTunnelPlan.Apply(new SplitTunnelPlan.State(), Env(), Array.Empty<string>(), None);
        Assert.Empty(result.Operations);
        Assert.Empty(result.Problems);
    }

    // MARK: - Replacing a session's rules

    [Fact]
    public void AChangedRuleSetComesDownBeforeItGoesUp()
    {
        var state = new SplitTunnelPlan.State();
        SplitTunnelPlan.Apply(state, Env(), new[] { "203.0.113.0/24", "198.51.100.0/25" }, None);

        var second = SplitTunnelPlan.Apply(state, Env(), new[] { "203.0.113.0/24", "192.0.2.0/24" }, None);

        // Deletion first, in install order, so a destination the user removed
        // cannot survive the edit — and the route that stayed is re-added
        // rather than trusted to still be there.
        Assert.Equal(new[]
        {
            "delete 203.0.113.0 mask 255.255.255.0",
            "delete 198.51.100.0 mask 255.255.255.128",
            "add 203.0.113.0 mask 255.255.255.0 192.168.1.1",
            "add 192.0.2.0 mask 255.255.255.0 192.168.1.1",
        }, Args(second));
        Assert.Equal(new[] { "203.0.113.0/24", "192.0.2.0/24" }, state.NetworksV4);
    }

    [Fact]
    public void NetworksGoInBeforeTheHostsUnderThem()
    {
        // The order is macOS's: v4 networks, v4 hosts, then the v6 pair. It is
        // the order the table ends up built in, and a heartbeat that re-pins a
        // host before its network would re-add over a route not there yet.
        var state = new SplitTunnelPlan.State();
        SplitTunnelPlan.Apply(state, Env(), new[] { "bank.example", "198.51.100.0/24" },
                              _ => Resolve("198.51.100.7"));
        Assert.Equal(new[]
        {
            "change 198.51.100.0 mask 255.255.255.0 192.168.1.254",
            "change 198.51.100.7 mask 255.255.255.255 192.168.1.254",
        }, Args(SplitTunnelPlan.Reassert(state, Env(gatewayV4: "192.168.1.254"),
                                         _ => Resolve("198.51.100.7"))));
    }

    [Fact]
    public void TurningTheFeatureOffRemovesEverything()
    {
        var state = new SplitTunnelPlan.State();
        SplitTunnelPlan.Apply(state, Env(), new[] { "203.0.113.0/24" }, None);
        var off = SplitTunnelPlan.Apply(state, Env(),
                                        new SplitTunnelRules { Enabled = false, Entries = { "203.0.113.0/24" } }
                                            .ActiveEntries.Select(e => e.Value), None);
        Assert.Equal("delete 203.0.113.0 mask 255.255.255.0", Args(off)[0]);
        Assert.True(state.Empty);
    }

    // MARK: - Domains

    [Fact]
    public void ADomainIsRoutedAsTheAddressesItAnswersWith()
    {
        var state = new SplitTunnelPlan.State();
        var result = SplitTunnelPlan.Apply(state, Env(), new[] { "bank.example" },
                                          name => Resolve("198.51.100.1", "198.51.100.2"));
        Assert.Equal(new[]
        {
            "add 198.51.100.1 mask 255.255.255.255 192.168.1.1",
            "add 198.51.100.2 mask 255.255.255.255 192.168.1.1",
        }, Args(result));
    }

    [Fact]
    public void AFakeIpAnswerRoutesNothing()
    {
        // A concurrent sing-box/clash client answers the system resolver from
        // its 198.18.0.0/15 pool; a route to a pool address is a route to the
        // tunnel's own address space.
        var state = new SplitTunnelPlan.State();
        var result = SplitTunnelPlan.Apply(state, Env(), new[] { "bank.example" },
                                          name => Resolve("198.18.44.7", "198.51.100.1"));
        Assert.Equal("add 198.51.100.1 mask 255.255.255.255 192.168.1.1", Args(result)[0]);
        Assert.Equal(new[] { "198.51.100.1" }, state.HostsV4);
    }

    [Fact]
    public void ANameWithNoAnswerIsNotAProblem()
    {
        // macOS logs the dead domains nowhere and simply routes nothing; the
        // user's rule stays, because the name may resolve on the next run.
        var result = SplitTunnelPlan.Apply(new SplitTunnelPlan.State(), Env(), new[] { "gone.example" }, None);
        Assert.Empty(result.Operations);
        Assert.Empty(result.Problems);
    }

    [Fact]
    public void IPv6HostsFollowTheIPv6Gateway()
    {
        var env = Env(gatewayV6: "fe80::1");
        var state = new SplitTunnelPlan.State();
        var result = SplitTunnelPlan.Apply(state, env, new[] { "bank.example" },
                                          _ => Resolve("198.51.100.1"),
                                          _ => Resolve("2001:db8::5"));
        Assert.Equal(new[]
        {
            "add 198.51.100.1 mask 255.255.255.255 192.168.1.1",
            "-6 add 2001:db8::5 mask 128 fe80::1",
        }, Args(result));
    }

    [Fact]
    public void NoIPv6QueryWithoutAnIPv6Gateway()
    {
        // The machine cannot route a v6 destination anywhere until it has a v6
        // gateway, so asking for the addresses is DNS traffic for nothing —
        // and macOS guards the lookup the same way.
        var lookedUp = new List<string>();
        var state = new SplitTunnelPlan.State();
        var result = SplitTunnelPlan.Apply(state, Env(gatewayV6: null), new[] { "bank.example" },
                                          _ => Resolve("198.51.100.1"),
                                          name => { lookedUp.Add(name); return Resolve("2001:db8::5"); });
        Assert.Empty(lookedUp);
        Assert.Empty(state.HostsV6);
        Assert.Equal("add 198.51.100.1 mask 255.255.255.255 192.168.1.1", Args(result)[0]);
    }

    // MARK: - Caps

    [Fact]
    public void ListsAreCappedWhereAnUnboundedOneWouldGrowForever()
    {
        var many = Enumerable.Range(0, 300).Select(i => $"10.{i / 250}.{i % 250}.0/24").ToArray();
        var result = SplitTunnelPlan.Apply(new SplitTunnelPlan.State(), Env(), many, None);
        Assert.Equal(SplitTunnelPlan.NetworkCap, result.Operations.Count);
    }

    [Fact]
    public void DomainsAreCappedToo()
    {
        var many = Enumerable.Range(0, 100).Select(i => $"host{i}.example").ToArray();
        var state = new SplitTunnelPlan.State();
        SplitTunnelPlan.Apply(state, Env(), many, _ => new List<string>());
        Assert.Equal(SplitTunnelPlan.DomainCap, state.Domains.Count);
    }

    [Fact]
    public void ACDNThatRotatesAddressesStopsAtTheCap()
    {
        var state = new SplitTunnelPlan.State();
        var wave = Enumerable.Range(0, 400).Select(i => $"198.51.{i / 250}.{i % 250}").ToArray();
        SplitTunnelPlan.Apply(state, Env(), new[] { "cdn.example" }, _ => new List<string>(wave));
        Assert.Equal(SplitTunnelPlan.HostCap, state.HostsV4.Count);
    }

    // MARK: - Re-asserting without tearing anything down

    [Fact]
    public void ARepinChangesAKnownRouteAndNeverDeletes()
    {
        var state = new SplitTunnelPlan.State();
        SplitTunnelPlan.Apply(state, Env(), new[] { "203.0.113.0/24" }, None);

        // The router renewed and the gateway moved: the entry is repointed, not
        // deleted and re-added, because a delete would cut what is already up.
        var env = Env(gatewayV4: "192.168.1.254");
        var result = SplitTunnelPlan.Reassert(state, env, None);
        Assert.Equal(new[] { "change 203.0.113.0 mask 255.255.255.0 192.168.1.254" }, Args(result));
        Assert.False(result.Grew);
    }

    [Fact]
    public void NewAddressesFromReResolutionAreAddedBesideTheOld()
    {
        var state = new SplitTunnelPlan.State();
        SplitTunnelPlan.Apply(state, Env(), new[] { "bank.example" }, _ => Resolve("198.51.100.1"));

        var asked = 0;
        var result = SplitTunnelPlan.Reassert(state, Env(),
            name => { asked++; return Resolve("198.51.100.1", "198.51.100.9"); });

        Assert.Equal(new[]
        {
            "change 198.51.100.1 mask 255.255.255.255 192.168.1.1",
            "add 198.51.100.9 mask 255.255.255.255 192.168.1.1",
        }, Args(result));
        Assert.True(result.Grew);
        // One query per stored name per round: the heartbeat runs every minute
        // and a resolver called per route would be a lookup storm.
        Assert.Equal(1, asked);
    }

    [Fact]
    public void AReassertThatChangesNothingReportsNothing()
    {
        var state = new SplitTunnelPlan.State();
        SplitTunnelPlan.Apply(state, Env(), new[] { "bank.example" }, _ => Resolve("198.51.100.1"));
        var again = SplitTunnelPlan.Reassert(state, Env(), _ => Resolve("198.51.100.1"));
        Assert.False(again.Grew);
        Assert.All(again.Operations, op => Assert.Equal(SplitTunnelPlan.Action.Change, op.What));
    }

    [Fact]
    public void ReassertingWithNoRulesIsANoOp()
    {
        var result = SplitTunnelPlan.Reassert(new SplitTunnelPlan.State(), Env(),
                                              _ => Resolve("198.51.100.1"));
        Assert.Empty(result.Operations);
    }

    [Fact]
    public void ReassertingWithoutAGatewayWaitsSilently()
    {
        var state = new SplitTunnelPlan.State();
        SplitTunnelPlan.Apply(state, Env(), new[] { "203.0.113.0/24" }, None);
        var result = SplitTunnelPlan.Reassert(state, Env(gatewayV4: null), None);
        Assert.Empty(result.Operations);
        Assert.Empty(result.Problems);
    }

    [Fact]
    public void AStaleHostRouteIsStillRePinned()
    {
        // A host the domain no longer answers with keeps its route: deleting it
        // would break a connection that is up, and a stale /32 costs one entry.
        var state = new SplitTunnelPlan.State();
        SplitTunnelPlan.Apply(state, Env(), new[] { "bank.example" }, _ => Resolve("198.51.100.1"));
        var result = SplitTunnelPlan.Reassert(state, Env(gatewayV4: "192.168.1.254"), None);
        Assert.Equal("change 198.51.100.1 mask 255.255.255.255 192.168.1.254", Args(result)[0]);
    }

    [Fact]
    public void AReassertSkipsOnLinkDestinationsLikeApplyDoes()
    {
        var env = Env(onLink: new[] { "192.168.1.0/24" });
        var state = new SplitTunnelPlan.State();
        SplitTunnelPlan.Apply(state, env, new[] { "192.168.1.0/24" }, None);
        Assert.Empty(state.Installed);     // skipped at install time
        var result = SplitTunnelPlan.Reassert(state, env, None);
        Assert.Empty(result.Operations);
    }

    // MARK: - The kill switch's list

    [Fact]
    public void TheAllowListIsPinsThenNetworksThenHosts()
    {
        var env = Env(pinsV4: new[] { "203.0.113.9" });
        var state = new SplitTunnelPlan.State();
        SplitTunnelPlan.Apply(state, env, new[] { "198.51.100.0/24", "bank.example" },
                              _ => Resolve("198.51.100.7", "203.0.113.9"));

        var (v4, v6) = SplitTunnelPlan.AllowList(state, env);
        Assert.Equal(new[] { "203.0.113.9", "198.51.100.0/24", "198.51.100.7" }, v4);
        Assert.Empty(v6);
    }

    // MARK: - Prefix arithmetic

    [Theory]
    [InlineData("192.168.1.0/24", "192.168.1.50/32", true)]
    [InlineData("192.168.1.0/25", "192.168.1.200/32", false)]
    [InlineData("192.168.1.0/24", "192.168.1.0/24", true)]
    [InlineData("192.168.1.0/24", "192.168.0.0/16", false)]
    [InlineData("198.18.0.0/15", "198.19.0.0/16", true)]
    [InlineData("198.18.0.0/15", "198.20.0.0/16", false)]
    [InlineData("2001:db8::/32", "2001:db8:ff::/64", true)]
    [InlineData("2001:db8::/32", "2001:db9::/48", false)]
    [InlineData("2001:db8::/32", "192.168.1.0/24", false)]
    public void ContainmentIsBitwise(string outer, string inner, bool expected)
    {
        Assert.Equal(expected, SplitTunnelPlan.Covers(Prefix(outer), Prefix(inner)));
    }

    [Theory]
    [InlineData("192.168.1.0/24", true)]
    [InlineData("2001:db8::/64", true)]
    [InlineData("192.168.1.0/33", false)]
    [InlineData("2001:db8::/129", false)]
    [InlineData("192.168.1.0", false)]
    [InlineData("192.168.1.0/", false)]
    [InlineData("192.168.1.999/24", false)]
    [InlineData("2001:db8::1%en0/64", false)]
    public void APrefixFromTheSystemHasToParse(string text, bool expected)
    {
        Assert.Equal(expected, SplitTunnelPlan.TryPrefix(text, out _));
    }

    [Theory]
    [InlineData(8, "255.0.0.0")]
    [InlineData(16, "255.255.0.0")]
    [InlineData(24, "255.255.255.0")]
    [InlineData(30, "255.255.255.252")]
    [InlineData(32, "255.255.255.255")]
    public void NetmasksAreDotted(int bits, string expected)
    {
        Assert.Equal(expected, SplitTunnelPlan.MaskFromBits(bits));
    }
}
