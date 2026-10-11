using AnemiaCore;
using Xunit;

namespace AnemiaCoreTests;

/// <summary>
/// The class of hysteria bug the engine itself will not report. Measured on the
/// bundled binary (2026-09-27): it refuses a config only for YAML *syntax*;
/// an unknown field (`unknown_field: 7`) and even a field of the wrong shape
/// (`tls: 5` instead of a block) are accepted and silently ignored — the TLS
/// options simply stop applying, which for a pinned certificate means the pin is
/// off and nothing says so. So field names are pinned here, by text.
/// </summary>
public class HysteriaConfigTests
{
    private static ProxyServer Hy2(string query = "") =>
        ShareLinkParser.Parse("hy2://p%40ss@h.example.com:443" + query);

    [Fact]
    public void ThePinFieldIsTheOneTheBinaryReads()
    {
        var yaml = HysteriaConfigBuilder.MakeClientConfig(Hy2("?pinsha256=aa.bb"), 21180);
        Assert.Contains("  pinSHA256: \"aa.bb\"", yaml);
        // The spelling that parses and does nothing.
        Assert.DoesNotContain("pinnedSHA256", yaml);
    }

    [Fact]
    public void TlsIsABlockAndNeverAScalar()
    {
        var yaml = HysteriaConfigBuilder.MakeClientConfig(Hy2("?sni=a.example.com&insecure=1&alpn=h3,h2"), 21180);
        Assert.Contains("\ntls:\n", yaml);
        Assert.Contains("  sni: \"a.example.com\"", yaml);
        Assert.Contains("  insecure: true", yaml);
        Assert.Contains("  alpn: \"h3,h2\"", yaml);
    }

    [Fact]
    public void ObfsNeedsBothSpellingAndPassword()
    {
        // A half-written obfuscation block would leave the client dialling
        // plainly while the link says the server expects salamander.
        Assert.DoesNotContain("obfs", HysteriaConfigBuilder.MakeClientConfig(Hy2("?obfs=salamander"), 21180));
        var both = HysteriaConfigBuilder.MakeClientConfig(Hy2("?obfs=salamander&obfs-password=abcd"), 21180);
        Assert.Contains("obfs:\n  type: \"salamander\"\n  salamander:\n    password: \"abcd\"", both);
    }

    [Fact]
    public void TheBridgePortIsWhereTheXrayOutboundLooks()
    {
        var yaml = HysteriaConfigBuilder.MakeClientConfig(Hy2(), 21600);
        Assert.Contains("socks5:\n  listen: \"127.0.0.1:21600\"", yaml);
    }

    [Fact]
    public void AHostilePasswordCannotEndTheDocument()
    {
        // Quotes, a colon, a newline, `#`, a line separator and Cyrillic: the
        // scalar must come back as one quoted JSON string, not as several lines.
        var server = ShareLinkParser.Parse("hy2://" + Uri.EscapeDataString("a\"b\nc#d\u2028е") + "@h.example.com:443");
        var yaml = HysteriaConfigBuilder.MakeClientConfig(server, 21180);
        Assert.Contains("auth: \"a\\\"b\\nc#d", yaml);
        Assert.Equal(5, yaml.Split('\n').Length - 1);   // server, auth, tls, socks5, listen
    }

    [Fact]
    public void V1WritesTheLegacyShape()
    {
        var server = ShareLinkParser.Parse(
            "hysteria://h.example.com:80?auth=secret&peer=h.example.com&up=10&down=20&obfs=shade&obfs-param=k");
        var yaml = HysteriaConfigBuilder.MakeClientConfig(server, 21180);
        Assert.Contains("protocol: \"udp\"", yaml);
        Assert.Contains("auth_str: \"secret\"", yaml);
        Assert.Contains("up: \"10 Mbps\"", yaml);
        Assert.Contains("down: \"20 Mbps\"", yaml);
        Assert.Contains("obfs: \"shade\"", yaml);
        Assert.Contains("obfs_param: \"k\"", yaml);
        // …and the validator says the bundled binary cannot run it.
        Assert.Contains(HysteriaConfigBuilder.Validate(server),
                        problem => problem.Contains("legacy hysteria v1 client binary", StringComparison.Ordinal));
    }

    [Fact]
    public void PortHoppingWidensOnlyWhenThePortIsNotAlreadyCovered()
    {
        var covered = ShareLinkParser.Parse("hy2://p@h.example.com:443,20000-50000");
        Assert.Contains("server: \"h.example.com:443,20000-50000\"",
                        HysteriaConfigBuilder.MakeClientConfig(covered, 21180));
        var notCovered = ShareLinkParser.Parse("hy2://p@h.example.com:8443?mport=20000-50000");
        Assert.Contains("server: \"h.example.com:8443,20000-50000\"",
                        HysteriaConfigBuilder.MakeClientConfig(notCovered, 21180));
    }


    [Fact]
    public void TheUserinfoPasswordWinsOverTheAuthQuery()
    {
        // Swift reads `parts.userInfo ?? lq["auth"]`, and panels write both when
        // they are unsure which client will read the link. A fixture cannot reach
        // this — no shared link carries both — so it is pinned here.
        var both = ShareLinkParser.Parse("hy2://fromUserinfo@h.example.com:443?auth=fromQuery");
        Assert.Equal("fromUserinfo", both.Credential);
        Assert.Equal("fromQuery", ShareLinkParser.Parse("hy2://@h.example.com:443?auth=fromQuery").Credential);
    }

    [Fact]
    public void EachGenerationHasItsOwnSniPreference()
    {
        // v2 reads `sni ?? peer`, v1 reads `peer ?? sni` — the historical spelling
        // of each protocol. Getting this backwards sends SNI of the wrong host and
        // the server closes the connection without saying why.
        var v2 = ShareLinkParser.Parse("hy2://p@h.example.com:443?sni=first.example.com&peer=second.example.com");
        Assert.Equal("first.example.com", v2.Sni);
        var v1 = ShareLinkParser.Parse("hysteria://h.example.com:80?auth=a&peer=first.example.com&sni=second.example.com");
        Assert.Equal("first.example.com", v1.Sni);
    }

    [Fact]
    public void LowercaseQuerySpellingWinsACaseCollision()
    {
        // `Obfs=1&obfs=2` folds to one key. Folding in sorted order makes the
        // winner the lowercase spelling deterministically; the naive version
        // trapped (`uniqueKeysWithValues` on a collision killed the import) and a
        // dictionary-order version would change between runs.
        var server = ShareLinkParser.Parse("hy2://p@h.example.com:443?Obfs=upper&obfs=lower");
        Assert.Equal("lower", server.UserData!["obfs"]);
    }

    [Fact]
    public void AnEmptyObfsPasswordDoesNotOpenTheBlock()
    {
        // Reachable only through a saved server (the parser never stores an empty
        // value), which is exactly what the `server` rows of the shared corpus
        // feed the golden with.
        var server = ShareLinkParser.Parse("hy2://p@h.example.com:443");
        server.UserData = new Dictionary<string, string> { ["obfs"] = "salamander", ["obfsPassword"] = "" };
        Assert.DoesNotContain("obfs", HysteriaConfigBuilder.MakeClientConfig(server, 21180));
    }

    [Theory]
    [InlineData("hysteria://h.example.com?auth=a")]
    [InlineData("hysteria://h.example.com:?auth=a")]
    public void V1WithoutAPortDefaultsToEighty(string link)
    {
        // v1 links historically live on :80, v2 on :443. Collapsing the two
        // defaults sends every legacy link to the wrong port.
        Assert.Equal(80, ShareLinkParser.Parse(link).Port);
        Assert.Equal(443, ShareLinkParser.Parse("hy2://p@h.example.com").Port);
    }
    [Theory]
    [InlineData("443", true)]
    [InlineData("443,20000-50000", true)]
    [InlineData("20000-50000,443", true)]
    [InlineData("0-99999", false)]          // out of range and descending at once
    [InlineData("443-80", false)]           // descending range
    [InlineData("443,", false)]             // an empty item is not a port
    [InlineData("", false)]
    [InlineData("٤٤٣", false)]              // digits a JVM would accept
    [InlineData("100000", false)]           // six digits is not a port
    [InlineData("000080", false)]           // Foundation counts characters, not value
    [InlineData("443-443", true)]           // a one-port range is ascending all the same
    public void PortSpecGrammar(string spec, bool valid) =>
        Assert.Equal(valid, HysteriaConfigBuilder.IsValidPortSpec(spec));

    /// <summary>Deliberate, said-out-loud divergence from the other three ports:
    /// Swift wraps the scalar in `JSONEncoder`, which leaves U+2028 and U+2029
    /// LITERAL (measured: its output for the same password contains the raw
    /// line separator), while .NET escapes them. The escaped form is the one this
    /// port writes, because a line separator inside a quoted scalar is exactly
    /// the character a document structure can end on, and a panel chooses the
    /// password. Making the ports agree means changing Swift's `yamlString` and
    /// regenerating `hysteria/links.golden.txt` — not bending this side to the
    /// riskier form. No fixture carries those characters today, so the byte
    /// parity run cannot see the difference; this test can.</summary>
    [Fact]
    public void ALineSeparatorInAPasswordIsEscapedNotEmittedRaw()
    {
        var server = ShareLinkParser.Parse(
            "hy2://" + Uri.EscapeDataString("p\u2028ss") + "@h.example.com:443");
        var yaml = HysteriaConfigBuilder.MakeClientConfig(server, 21180);
        Assert.Contains("auth: \"p\\u2028ss\"", yaml);
        Assert.DoesNotContain("\u2028", yaml.Replace("\\u2028", ""));
    }

    [Fact]
    public void XrayDialsTheBridgeAndNothingElse()
    {
        // Hysteria is QUIC; xray cannot speak it. The outbound must be a plain
        // socks dial into the bridge the hysteria process serves — and if the
        // bridge port was never chosen, that is a wiring bug, not a config.
        var server = Hy2();
        server.UserData = new Dictionary<string, string>(server.UserData ?? new Dictionary<string, string>())
        {
            ["hySocksPort"] = "21600",
        };
        var json = new XrayConfigBuilder().MakeConfigString(server);
        Assert.Contains("\"protocol\": \"socks\"", json);
        Assert.Contains("\"port\": 21600", json);
        Assert.DoesNotContain("hysteriaSettings", json);

        var withoutBridge = ShareLinkParser.Parse("hy2://p@h.example.com:443");
        var error = Assert.Throws<ConfigBuilderException>(
            () => new XrayConfigBuilder().MakeConfigData(withoutBridge));
        Assert.Equal(ConfigBuilderErrorKind.HysteriaBridgeMissing, error.Kind);
    }
}
