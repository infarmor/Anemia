using AnemiaCore;
using Xunit;

namespace AnemiaCoreTests;

/// <summary>
/// The two guards that keep a bad link from reaching the engine, plus the field
/// that carries the second half of the story. Both were macOS/iOS behaviour for
/// a month and absent here: an unusable cipher and an obfuscated mKCP both made
/// the engine, not the app, the thing that reported the problem — in Go, about a
/// server the user cannot inspect.
/// </summary>
public class BuilderGuardTests
{
    private static readonly XrayConfigBuilder Builder = new();

    private static ProxyServer Plain(string link) => ShareLinkParser.Parse(link);

    [Fact]
    public void MissingCipherIsRefusedBeforeTheEngineSeesIt()
    {
        var server = new ProxyServer("ss", ProxyProtocol.Ss, "ss.test", 8443, "pass", method: null);
        var error = Assert.Throws<ConfigBuilderException>(() => Builder.MakeConfigData(server));
        Assert.Equal(ConfigBuilderErrorKind.ShadowsocksMethodMissing, error.Kind);

        // A method of whitespace trims into the same branch — the engine would
        // otherwise see an empty string it cannot match.
        var blank = new ProxyServer("ss", ProxyProtocol.Ss, "ss.test", 8443, "pass", method: "   ");
        Assert.Equal(ConfigBuilderErrorKind.ShadowsocksMethodMissing,
                     Assert.Throws<ConfigBuilderException>(() => Builder.MakeConfigData(blank)).Kind);
    }

    [Theory]
    [InlineData("aes-256-cfb")]           // removed stream cipher
    [InlineData("chacha20")]              // not AEAD
    [InlineData("2022-blake3-aes-128")]   // suffix truncated
    public void UnsupportedCipherIsRefused(string method)
    {
        var server = new ProxyServer("ss", ProxyProtocol.Ss, "ss.test", 8443, "pass", method: method);
        var error = Assert.Throws<ConfigBuilderException>(() => Builder.MakeConfigData(server));
        Assert.Equal(ConfigBuilderErrorKind.ShadowsocksMethodUnsupported, error.Kind);
        Assert.Contains(method.Trim(), error.Message);
    }

    [Theory]
    [InlineData("aes-256-gcm")]
    [InlineData("AES-256-GCM")]           // the engine matches case-insensitively
    [InlineData("chacha20-ietf-poly1305")]
    [InlineData("2022-blake3-aes-256-gcm")]
    [InlineData("2022-blake3-chacha20-poly1305")]
    [InlineData("none")]
    public void EveryAcceptedCipherIsTheOnesList(string method)
    {
        var server = new ProxyServer("ss", ProxyProtocol.Ss, "ss.test", 8443,
            // 2022-blake3 ciphers need a key of the right length for the engine,
            // which the builder does not check — only the method name matters here.
            "c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0");
        server.Method = method;
        // Any throw fails the test on its own; there is nothing to assert, which
        // is the point: these shapes must reach the engine.
        Builder.MakeConfigData(server);
    }

    [Theory]
    [InlineData("none")]        // explicit "no obfuscation" is not obfuscation
    [InlineData("")]            // absent
    public void PlainMkcpStillBuilds(string headerType)
    {
        var server = new ProxyServer("kcp", ProxyProtocol.Vless, "k.test", 443,
            "11111111-1111-1111-1111-111111111111", network: NetworkType.Kcp);
        server.HeaderType = headerType.Length == 0 ? null : headerType;
        // Any throw fails the test on its own; there is nothing to assert, which
        // is the point: these shapes must reach the engine.
        Builder.MakeConfigData(server);
    }

    [Theory]
    [InlineData("srtp:v1")]
    [InlineData("utp")]
    [InlineData("HTTP")]        // any non-"none" header, whatever its case
    public void ObfuscatedMkcpIsRefusedByName(string headerType)
    {
        var server = new ProxyServer("kcp", ProxyProtocol.Vless, "k.test", 443,
            "11111111-1111-1111-1111-111111111111", network: NetworkType.Kcp);
        server.HeaderType = headerType;
        var error = Assert.Throws<ConfigBuilderException>(() => Builder.MakeConfigData(server));
        Assert.Equal(ConfigBuilderErrorKind.MkcpObfuscationUnsupported, error.Kind);
        Assert.Contains("header=" + headerType, error.Message);
    }

    [Fact]
    public void SeedFromTheLinkSurvivesToTheGuard()
    {
        // Without the field the seed is dropped at parse time and the guard below
        // it can never fire: the user dials plain mKCP at an obfuscated server.
        var server = Plain("vless://11111111-1111-1111-1111-111111111111@k.test:443" +
                           "?security=tls&type=kcp&seed=hunter2#k");
        Assert.Equal(NetworkType.Kcp, server.Network);
        Assert.Equal("hunter2", Assert.Contains("kcpSeed", server.UserData!));
        var error = Assert.Throws<ConfigBuilderException>(() => Builder.MakeConfigData(server));
        Assert.Equal(ConfigBuilderErrorKind.MkcpObfuscationUnsupported, error.Kind);
        Assert.Contains("seed is set", error.Message);
    }

    [Fact]
    public void SeedRoundTripsThroughTheStateFile()
    {
        var server = Plain("vless://11111111-1111-1111-1111-111111111111@k.test:443" +
                           "?security=tls&type=kcp&seed=hunter2#k");
        var state = new PersistedState { Servers = new List<ProxyServer> { server } };
        var decoded = PersistedState.FromJson(state.ToJson());
        Assert.Equal("hunter2", Assert.Contains("kcpSeed", decoded!.Servers[0].UserData!));
    }

    [Fact]
    public void AbsentUserDataStaysAbsentRatherThanAnEmptyObject()
    {
        // Swift writes `"userData": {}` and no key as two different states; a port
        // that invents an empty dictionary changes what the other platforms read.
        var server = Plain("vless://11111111-1111-1111-1111-111111111111@n.test:443#n");
        Assert.Null(server.UserData);
        var json = new PersistedState { Servers = new List<ProxyServer> { server } }.ToJson().ToJsonString();
        Assert.DoesNotContain("userData", json);
    }

    [Fact]
    public void ARepeatedKeyInVmessJsonTakesTheFirstValue()
    {
        // System.Text.Json's JsonObject throws on a parsed object with a
        // duplicate key — indexing it *or* enumerating it — while legal JSON
        // allows the repeat. Case 45 of the shared corpus is exactly this link,
        // and both Swift and its golden read the first "add".
        var link = "vmess://" + Convert.ToBase64String(
            System.Text.Encoding.UTF8.GetBytes(
                "{\"add\":\"example.com\",\"port\":443,\"id\":\"x\",\"add\":\"other.com\"}")) +
            "#duplicate-keys";
        var server = ShareLinkParser.Parse(link);
        Assert.Equal("example.com", server.Address);
        Assert.Equal(443, server.Port);
    }

    [Theory]
    [InlineData("awg")]
    [InlineData("wg")]
    public void AWireGuardFamilyServerNeverReachesXray(string scheme)
    {
        // Emitting a plain wireguard outbound would strip every junk/padding
        // parameter and drop all traffic on an obfuscated server, with the
        // tunnel looking connected.
        var link = scheme + "://QVgA6rX5+V8kq2T3x5D8wB0lI2pR4sT6uV8wX0yZ1aB="
            + "@10.0.0.1:51820?publickey=QVgA6rX5+V8kq2T3x5D8wB0lI2pR4sT6uV8wX0yZ1aB=&jc=4";
        var server = ShareLinkParser.Parse(link);
        Assert.True(server.IsWireGuardFamily);
        var error = Assert.Throws<ConfigBuilderException>(() => Builder.MakeConfigData(server));
        Assert.Equal(ConfigBuilderErrorKind.WireGuardNotOnXray, error.Kind);
        Assert.Contains("run on the AmneziaWG engine", error.Message);
    }
}
