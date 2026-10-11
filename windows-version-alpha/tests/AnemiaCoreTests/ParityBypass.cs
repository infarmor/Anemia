using System.Text;
using AnemiaCore;
using Xunit;

namespace AnemiaCoreTests;

/// <summary>
/// The bypass rules, replayed through the same golden Kotlin and Swift run:
/// every fixture line is handed to the parser as a paste, and the normalized
/// entry or the refusal is compared as text, in the emitter's own shape
/// (`value [case("value")] `, rejections `нет: reason`).
///
/// The IPv6 half is the part worth pinning rather than trusting: the canonical
/// text comes from libc's <c>inet_ntop</c>, whose v4-shaped exceptions and
/// first-longest-run rule <c>IPAddress.ToString()</c> does not share.
/// </summary>
public class ParityBypassTests
{
    private const string Folder = "bypass";

    [Fact]
    public void BypassLinesMatchSwift()
    {
        var produced = new StringBuilder();
        var cases = 0;
        var rejections = 0;
        foreach (var line in Parity.Split(Parity.Read(Folder, "lines.txt")))
        {
            if (line.Length == 0) continue;
            cases++;
            var result = SplitTunnelParser.ParseText(line);
            produced.Append(line).Append(Parity.Tab);
            foreach (var entry in result.Entries)
                produced.Append(entry.Value).Append(" [").Append(entry.Describe()).Append("] ");
            rejections += result.Rejected.Count;
            produced.Append(string.Join("; ", result.Rejected
                .Select(rejection => "нет: " + rejection.Reason)));
            produced.Append(Parity.LineFeed);
        }

        Parity.Compare(produced.ToString(), Parity.Read(Folder, "lines.golden.txt"),
                       "правила обхода", floor: 50);
        // Both counts measured from the fixtures: 60 lines in, and the trap rows
        // are the point of half of them.
        Assert.Equal(60, cases);
        Assert.Equal(27, rejections);
    }

    /// <summary>Cases the shared fixture does not carry, each one measured
    /// against <c>LoaderTool split-tunnel</c> on this Mac (macOS, 2026-09-27) and
    /// kept here so the rule cannot drift with a refactor. The <c>inet_ntop</c>
    /// group is the interesting one: «::2» stays hex while «::1:2» becomes a
    /// dotted quad, which no written-down RFC would predict from the outside.</summary>
    [Theory]
    [InlineData("2001:db8::1.2.3.4", "2001:db8::102:304")]  // nonzero prefix → hex
    [InlineData("::2", "::2")]                          // 96 zero bits, tail starts at byte 14
    [InlineData("::1:2", "::0.1.0.2")]                  // 96 zero bits, tail at byte 12
    [InlineData("::0.0.1.0", "::100")]
    [InlineData("::ffff:1.2.3.4", "::ffff:1.2.3.4")]
    [InlineData("::ffff:0.0.0.1", "::ffff:0.0.0.1")]
    [InlineData("::ffff:ffff", "::255.255.255.255")]
    [InlineData("0:0:0:0:0:1:1.2.3.4", "::1:102:304")]
    [InlineData("0:0:0:0:0:ffff:1.2.3.4", "::ffff:1.2.3.4")]
    [InlineData("::", "::")]
    [InlineData("1:2:3:4:5:6:0:0", "1:2:3:4:5:6::")]
    [InlineData("2001:db8:0:0:1:0:0:1", "2001:db8::1:0:0:1")]   // tie → first run wins
    [InlineData("2001:db8:0:1:0:0:1:0", "2001:db8:0:1::1:0")]
    [InlineData("0:0:0:0:1:0:0:0", "::1:0:0:0")]
    [InlineData("1:0:0:2:0:0:0:0", "1:0:0:2::")]
    [InlineData("1:0:1:0:0:1:0:1", "1:0:1::1:0:1")]
    [InlineData("0:1:0:0:0:0:0:0", "0:1::")]
    [InlineData("1:2:3:4:5:6:7:8", "1:2:3:4:5:6:7:8")]
    [InlineData("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
                "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff")]
    [InlineData("0300::1", "300::1")]
    public void CanonicalIpv6MatchesMacLibc(string input, string expected)
    {
        Assert.Equal(expected + "/128", OnlyValue(input));
    }

    /// <summary>What <c>inet_pton</c> accepts is a contract of its own, and the
    /// corpus leans on it: a bypass written as <c>1.2.3.4::</c> must not become a
    /// route, and a scope id is not an address at all.</summary>
    [Theory]
    [InlineData("1.2.3.4::")]
    [InlineData("::1.2.3.4::")]
    [InlineData("1:2:3:4:5:6:7:8:9")]
    [InlineData("::1:2:3:4:5:6:7:8")]
    [InlineData("00000::1")]
    [InlineData("fe80::1%eth0")]
    [InlineData("1::2::3")]
    [InlineData("2001:db8::1.2.3")]
    [InlineData("2001:db8::1.2.3.4.5")]
    [InlineData("2001:db8:")]
    [InlineData(":2001:db8::1")]
    [InlineData(":::1")]
    [InlineData("1:2:3:4:5:6:7:8.")]
    [InlineData("1::2:3:4:5:6:7:8")]   // "::" must still stand for at least one group
    [InlineData("1:2:3:4:5:6:7:1.2.3.4")]   // no room left for the quad's two groups
    [InlineData("::1:2:3:4:5:6:1.2.3.4")]
    [InlineData("1:2:3:4:5:6:7:8:1.2.3.4")]
    public void MalformedIpv6IsRefused(string input)
    {
        var result = SplitTunnelParser.ParseText(input);
        Assert.Empty(result.Entries);
        Assert.Equal("not a valid IPv6 address", Assert.Single(result.Rejected).Reason);
    }

    [Theory]
    // the only zero run here is a single group, so nothing gets compressed
    [InlineData("1:2:3:4:5:6:7::", "1:2:3:4:5:6:7:0/128")]
    [InlineData("::0.0.0.0", "::/128")]
    [InlineData("2001:db8::1.2.3.4/64", "2001:db8::/64")]
    [InlineData("[2001:db8::1]/64", "2001:db8::1/128")]   // the prefix after ] is dropped
    public void BracketedAndCompressedFormsMatch(string input, string expected)
    {
        Assert.Equal(expected, OnlyValue(input));
    }

    /// <summary>The floors that make a bypass useless or dangerous: /8 for v4,
    /// /16 for v6, and no loopback or tunnel range at any prefix that overlaps
    /// them — including a wider net that merely covers one.</summary>
    [Theory]
    [InlineData("203.0.113.0/7", "too broad — /7 would send most traffic around the VPN (use /8 or narrower)")]
    [InlineData("10.0.0.0/7", "too broad — /7 would send most traffic around the VPN (use /8 or narrower)")]
    [InlineData("0.0.0.0/0", "too broad — /0 would send most traffic around the VPN (use /8 or narrower)")]
    [InlineData("2001:db8::/0", "too broad — /0 would send most IPv6 traffic around the VPN (use /16 or narrower)")]
    [InlineData("fd00::/15", "too broad — /15 would send most IPv6 traffic around the VPN (use /16 or narrower)")]
    [InlineData("127.127.127.127", "loopback never goes through the VPN")]
    [InlineData("172.28.0.5/32", "that range is the VPN tunnel itself")]
    [InlineData("172.29.0.0/20", "that range is the VPN tunnel itself")]
    [InlineData("::1", "loopback never goes through the VPN")]
    [InlineData("::1/64", "loopback never goes through the VPN")]
    public void TooBroadOrReservedIsRefused(string input, string reason)
    {
        var result = SplitTunnelParser.ParseText(input);
        Assert.Empty(result.Entries);
        Assert.Equal(reason, Assert.Single(result.Rejected).Reason);
    }

    /// <summary>The overlap test is by the shorter of the two prefixes, so a net
    /// that merely *contains* a reserved range is refused while a neighbour that
    /// only touches it by name stays.</summary>
    [Theory]
    [InlineData("172.30.0.0/16", "172.30.0.0/16")]
    [InlineData("172.27.0.0/16", "172.27.0.0/16")]
    [InlineData("203.0.113.0/8", "203.0.0.0/8")]
    [InlineData("10.7.0.7/24", "10.7.0.0/24")]
    [InlineData("255.255.255.255/32", "255.255.255.255/32")]
    [InlineData("0.0.0.0/8", "0.0.0.0/8")]   // covers no reserved range, so it stays
    [InlineData("2001:db8::/17", "2001::/17")]
    public void NetworksAreCanonicalisedToTheirPrefix(string input, string expected)
    {
        Assert.Equal(expected, OnlyValue(input));
    }

    /// <summary>Domains: punycode of the labels a routing rule has to match in
    /// ASCII, the trailing-dot and wildcard decorations that are dropped, and
    /// the shapes that are not names.</summary>
    [Theory]
    [InlineData("сбербанк.рф", "xn--80abap1arsf.xn--p1ai")]
    [InlineData("ми.ру", "xn--h1ah.xn--p1ag")]
    [InlineData("test.рф.", "test.xn--p1ai")]
    [InlineData("xn--e1afmkfd.xn--p1ai", "xn--e1afmkfd.xn--p1ai")]
    [InlineData("*.example.com", "example.com")]
    [InlineData("https://User@Host.Example.COM:8443/path", "host.example.com")]
    [InlineData("user@exam.com", "exam.com")]
    [InlineData("a--.b.com", null)]
    [InlineData("a.b-.com", null)]
    [InlineData("1.2.3.4.5", null)]
    [InlineData("1٠.2.3.4/24", "xn--1-8pc.2.3.4")]   // not ASCII digits → a name, and no prefix
    // U+0130 lowercases to two scalars (i + combining dot above), then punycodes
    [InlineData("\u0130.example.com", "xn--i-9bb.example.com")]
    public void DomainLabelsMatchSwift(string input, string? expected)
    {
        var result = SplitTunnelParser.ParseText(input);
        if (expected is null)
        {
            Assert.Empty(result.Entries);
            Assert.NotEmpty(result.Rejected);
            return;
        }
        Assert.Equal(expected, OnlyValue(input));
    }

    /// <summary>One paste, many destinations, and one bad row among them: the
    /// good ones still route, the bad one is reported. Order follows the input.</summary>
    [Fact]
    public void AWholePasteCarriesEveryRowAndStillNamesTheBadOne()
    {
        var result = SplitTunnelParser.ParseText("example.com, 999.1.1.1; ми.ру\n# note\n");
        // the stored value is the ASCII form the helper matches on
        Assert.Equal(new[] { "example.com", "xn--h1ah.xn--p1ag" },
                     result.Entries.Select(entry => entry.Value).ToArray());
        var rejection = Assert.Single(result.Rejected);
        Assert.Equal("999.1.1.1", rejection.Line);
        Assert.Equal("not a valid IPv4 address", rejection.Reason);
    }

    /// <summary>Duplicates collapse to the first place they appeared; the same
    /// destination written two ways is one route, not two.</summary>
    [Fact]
    public void TheSameDestinationWrittenTwiceIsOneEntry()
    {
        var result = SplitTunnelParser.ParseText("203.0.113.7, 203.0.113.7/32, EXAMPLE.COM");
        Assert.Equal(new[] { "203.0.113.7/32", "example.com" },
                     result.Entries.Select(entry => entry.Value).ToArray());
    }

    /// <summary>What the helper is handed: addresses and names separated, so the
    /// first needs no resolver and the second does.</summary>
    [Fact]
    public void PartitionSeparatesAddressesFromNames()
    {
        var (networks, domains) = SplitTunnelParser.Partition(
            SplitTunnelParser.ParseText("10.7.0.0/24, bank.ru, 2001:db8::1/64").Entries);
        Assert.Equal(new[] { "10.7.0.0/24", "2001:db8::/64" }, networks);
        Assert.Equal(new[] { "bank.ru" }, domains);
    }

    /// <summary>Scheme and userinfo trimming, measured against
    /// `LoaderTool split-tunnel`: the scheme is cut at the *first* `://` (so a
    /// doubly-prefixed line yields the label «https», not a hostname), the
    /// userinfo at the *last* `@`, and a `/prefix` after `host:port` is dropped
    /// — a prefix belongs to a bare address only. Each of these three is a
    /// mutant that survived until these rows existed.</summary>
    [Theory]
    [InlineData("http://https://example.com", "https")]
    [InlineData("user@host@example.com", "example.com")]
    [InlineData("a@b", "b")]
    [InlineData("@example.com", "example.com")]
    [InlineData("example.com:8443/24", "example.com")]
    [InlineData("https://1.2.3.4:443/8", "1.2.3.4/32")]
    [InlineData("ftp://user@192.168.0.0:21/16", "192.168.0.0/32")]
    public void SchemeAndUserInfoEdgesMatchSwift(string input, string expected)
    {
        Assert.Equal(expected, OnlyValue(input));
    }

    /// <summary>The label limit is 63 characters, and the shared fixture only
    /// carries a 70-character one — which is why a mutant that accepted 64
    /// survived its first run. 63 in, 64 out, measured against
    /// <c>LoaderTool split-tunnel</c>.</summary>
    [Fact]
    public void ALabelOfSixtyThreeCharactersIsTheLastOneAccepted()
    {
        Assert.Equal(new string('a', 63), OnlyValue(new string('a', 63)));
        Assert.Equal(new string('a', 63) + ".com", OnlyValue(new string('a', 63) + ".com"));
        var result = SplitTunnelParser.ParseText(new string('a', 64) + ".com");
        Assert.Empty(result.Entries);
        Assert.Equal("not a valid domain", Assert.Single(result.Rejected).Reason);
    }

    private static string OnlyValue(string input)
    {
        var result = SplitTunnelParser.ParseText(input);
        Assert.Single(result.Entries);
        return result.Entries[0].Value;
    }
}
