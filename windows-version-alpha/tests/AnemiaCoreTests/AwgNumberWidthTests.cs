using System.Text.Json.Nodes;
using AnemiaCore;
using Xunit;

namespace AnemiaCoreTests;

/// <summary>
/// Width of the saved integers. Swift declares these fields <c>Int</c>, which is
/// 64-bit on every Apple and Android target, while this port read them as
/// <c>int</c> — so a file written by another device could hold a number the port
/// could not store, and it lost the <em>server</em> over it.
///
/// Measured 2026-09-30 with <c>LoaderTool state</c> over probe documents (in the
/// Swift decode: <c>junkPackets: 5000000000</c> keeps the server and the number;
/// <c>99999999999999999999</c> costs it; <c>muxConcurrency: 5000000000</c> comes
/// back as 5000000000, not as the default). The refusal for an oversized value
/// belongs to the daemon's own bounds, which the validator states — not to the
/// width of a C# field.
/// </summary>
public class AwgNumberWidthTests
{
    private const string Big = "5000000000";          // above int32, well inside Int64
    private const string Beyond = "99999999999999999999";   // above Int64

    private static string AwgDocument(string awgJson) =>
        "{\"servers\":[{\"id\":\"1B564D2F-5117-4C8C-9B0D-9E2F8A3F1C22\",\"name\":\"s\"," +
        "\"proto\":\"awg\",\"address\":\"example.com\",\"port\":51820,\"credential\":\"c\"," +
        "\"alterId\":0,\"network\":\"tcp\",\"security\":\"none\",\"alpn\":[]," +
        "\"allowInsecure\":false,\"awg\":" + awgJson + "}]}";

    private static ProxyServer Base() => new()
    {
        Name = "t",
        Proto = ProxyProtocol.Amnezia,
        Address = "10.0.0.1",
        Port = 51820,
        Credential = "yAnz5TF+fT28A5vH0vGcC8pVXqv5ZfV0+0P4Rn1v5HE=",
        WgProfile = new WireGuardProfile("Ox5vDWfJ9yfkXcUuJ2XgKlQSmGvvnBB0qR9vK3F2zV0="),
    };

    [Fact]
    public void AJunkCountAboveInt32KeepsBothTheServerAndTheNumber()
    {
        var state = PersistedState.FromJson(JsonNode.Parse(
            AwgDocument("""{"junkPackets":5000000000,"specialHandshakes":[]}""")));
        Assert.NotNull(state);
        var server = Assert.Single(state!.Servers);
        Assert.Equal(5000000000L, server.Awg!.JunkPackets);

        // And the document this port writes back holds the same number, as an
        // integer — not 5E+09, and not the field dropped.
        var written = state.ToJson()["servers"]!.AsArray()[0]!["awg"]!["junkPackets"]!.ToJsonString();
        Assert.Equal(Big, written);
    }

    [Fact]
    public void AJunkCountBeyondInt64CostsTheServerAsSwiftDoes()
    {
        var state = PersistedState.FromJson(JsonNode.Parse(
            AwgDocument("""{"junkPackets":""" + Beyond + ""","specialHandshakes":[]}""")));
        Assert.NotNull(state);
        // Swift's `decodeIfPresent(Int.self)` throws there, and the element goes
        // with it; a port that clamped the number instead would silently connect
        // with someone else's settings.
        Assert.Empty(state!.Servers);
    }

    [Theory]
    [InlineData(Big, "Jc (5000000000) is outside the 0…4294967295 the daemon parses")]
    [InlineData("-1", "Jc (-1) is outside the 0…4294967295 the daemon parses")]
    public void TheDaemonBoundsRefuseWhatItCannotParse(string value, string expected)
    {
        var server = Base();
        server.Awg = AwgObfuscation.FromJson(JsonNode.Parse(
            """{"junkPackets":""" + value + "}"));
        Assert.NotNull(server.Awg);
        Assert.Contains(AmneziaWgConfigBuilder.Validate(server),
                        problem => problem.Contains(expected, StringComparison.Ordinal));
    }

    [Fact]
    public void PaddingAboveTheSixteenBitRangeIsRefusedNotTruncated()
    {
        var server = Base();
        server.Awg = new AwgObfuscation { InitPadding = 70000 };
        Assert.Contains(AmneziaWgConfigBuilder.Validate(server),
                        problem => problem.Contains("S1 (70000) is outside the 0…65535",
                                                    StringComparison.Ordinal));
    }

    [Fact]
    public void ALegacyNumericPaddingFieldKeepsABigNumberAsText()
    {
        // Written before the ranges were modeled, this was a plain integer, and
        // Swift tries the number first. Read as int it threw, and the server
        // went with it.
        var awg = AwgObfuscation.FromJson(JsonNode.Parse(
            """{"contentPaddingAddition":5000000000}"""));
        Assert.Equal(Big, awg!.ContentPaddingAddition);
    }

    [Fact]
    public void AConfLineIsReadAtTheFullWidthToo()
    {
        var server = WireGuardLink.ParseConfigText(string.Join("\n",
            "[Interface]",
            "PrivateKey = yAnz5TF+fT28A5vH0vGcC8pVXqv5ZfV0+0P4Rn1v5HE=",
            "jc = 5000000000",
            "",
            "[Peer]",
            "PublicKey = Ox5vDWfJ9yfkXcUuJ2XgKlQSmGvvnBB0qR9vK3F2zV0=",
            "Endpoint = 203.0.113.9:51820"));
        Assert.Equal(5000000000L, server.Awg!.JunkPackets);
    }

    [Fact]
    public void MuxConcurrencyKeepsTheNumberSwiftStores()
    {
        var anti = AntiCensorshipOptions.FromJson(JsonNode.Parse("""{"muxConcurrency":5000000000}"""));
        // The port used to answer the default 8 here: the same file then built a
        // different config on Windows than on the Mac.
        Assert.Equal(5000000000L, anti.MuxConcurrency);
        Assert.Equal(Big, anti.ToJson()["muxConcurrency"]!.ToJsonString());
    }

    [Fact]
    public void TheNumberTravelsIntoTheEngineConfigUnchanged()
    {
        var server = new ProxyServer
        {
            Name = "m", Proto = ProxyProtocol.Vless, Address = "example.com", Port = 443,
            Credential = "11111111-1111-1111-1111-111111111111",
            Network = NetworkType.Tcp, Security = StreamSecurity.None,
        };
        var anti = AntiCensorshipOptions.FromJson(JsonNode.Parse(
            """{"muxEnabled":true,"muxConcurrency":5000000000}"""));
        var config = new XrayConfigBuilder().MakeConfig(server, anti);
        var proxy = ((config["outbounds"] as JsonArray)!).OfType<JsonObject>()
            .First(o => o["tag"]?.GetValue<string>() == "proxy");
        Assert.Equal(Big, proxy["mux"]!["concurrency"]!.ToJsonString());
    }
}
