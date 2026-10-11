using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using AnemiaCore;
using Xunit;

namespace AnemiaCoreTests;

/// <summary>
/// Three shapes the shared `links/corpus.golden.txt` does not contain, each put
/// to the real Swift parser through `LoaderTool dump-links` and answered as
/// recorded below. Mutation testing asked for them: a mutant that stopped
/// checking the qCompress size header survived, because every fixture payload
/// decompresses to exactly the length its header promises.
///
/// The last row is the more uncomfortable finding: an Amnezia envelope whose INI
/// ends with `[Peer]` gets the envelope's `dns1`/`dns2` appended after that
/// section, so the line lands in the peer block and the interface keeps no DNS
/// at all. Swift does exactly that; pinning it here is what keeps a future
/// "improvement" from quietly making Windows disagree with the other three
/// devices about the same link.
/// </summary>
public class ParityVpnProbes
{
    private const string Peer =
        "[Peer]\nPublicKey = Ox5vDWfJ9yfkXcUuJ2XgKlQSmGvvnBB0qR9vK3F2zV0=\n" +
        "Endpoint = 203.0.113.7:51820\nAllowedIPs = 0.0.0.0/0\n";
    private const string InterfaceOnly =
        "[Interface]\nPrivateKey = yAnz5TF+fT28A5vH0vGcC8pVXqv5ZfV0+0P4Rn1v5HE=\nAddress = 10.8.1.2/32\n";

    /// <summary>An Amnezia envelope around `ini`, in the uncompressed export form
    /// or qCompress'd with a 4-byte size header that may or may not match.</summary>
    private static string Link(string ini, bool withDns = true, int? declaredSize = null)
    {
        var env = new JsonObject
        {
            ["hostName"] = "srv",
            ["description"] = "Amnezia AWG",
            ["defaultContainer"] = "amnezia-awg",
            ["containers"] = new JsonArray
            {
                new JsonObject
                {
                    ["container"] = "amnezia-awg",
                    ["awg"] = new JsonObject { ["last_config"] = JsonSerializer.Serialize(new { config = ini }) },
                },
            },
        };
        if (withDns)
        {
            env["dns1"] = "1.1.1.1";
            env["dns2"] = "8.8.8.8";
        }
        var raw = Encoding.UTF8.GetBytes(env.ToJsonString());
        if (declaredSize is null) return "vpn://" + Url(raw);

        using var buffer = new System.IO.MemoryStream();
        using (var deflate = new System.IO.Compression.DeflateStream(
            buffer, System.IO.Compression.CompressionLevel.Optimal, leaveOpen: true))
            deflate.Write(raw);
        var body = buffer.ToArray();
        var payload = new byte[6 + body.Length];
        var promised = (uint)declaredSize.Value;
        payload[0] = (byte)(promised >> 24);
        payload[1] = (byte)(promised >> 16);
        payload[2] = (byte)(promised >> 8);
        payload[3] = (byte)promised;
        payload[4] = 0x78;   // zlib CMF/FLG: 0x789c, and 0x789c % 31 == 0
        payload[5] = 0x9c;
        body.CopyTo(payload, 6);
        return "vpn://" + Url(payload);

        static string Url(byte[] data) =>
            Convert.ToBase64String(data).Replace('+', '-').Replace('/', '_').TrimEnd('=');
    }

    /// <summary>Swift: `malformedURI("vpn link: not an Amnezia config
    /// (undecodable JSON)")`. The header promised more bytes than the stream
    /// holds, the inflate came up short, and the payload is therefore kept as it
    /// arrived — compressed bytes, which are not JSON. Without that length check
    /// a truncated or forged container would be read as if it were whole.</summary>
    [Fact]
    public void ASizeHeaderThatLiesRefusesTheLink()
    {
        var link = Link(InterfaceOnly + Peer, declaredSize: 999_999);
        var error = Assert.Throws<ParseErrorException>(() => ShareLinkParser.Parse(link));
        Assert.Equal(ParseErrorKind.MalformedUri, error.Kind);
        Assert.Equal("vpn link: not an Amnezia config (undecodable JSON)", error.Detail);
    }

    /// <summary>The same bytes with an honest header do read — so the refusal
    /// above is the length check, not the container.</summary>
    [Fact]
    public void TheSameContainerWithAnHonestHeaderReads()
    {
        var plain = Link(InterfaceOnly + Peer);
        var server = ShareLinkParser.Parse(plain);
        Assert.Equal("203.0.113.7", server.Address);

        // Same envelope, compressed, declared size = what the JSON really is.
        var compressed = Link(InterfaceOnly + Peer, declaredSize: JsonLength(InterfaceOnly + Peer));
        Assert.Equal(server.Address, ShareLinkParser.Parse(compressed).Address);
    }

    /// <summary>Swift: `malformedURI("AmneziaWG config: missing peer
    /// PublicKey")` — an envelope whose INI carries only an interface section is
    /// not a server, and the structured fields do not stand in for a peer.</summary>
    [Fact]
    public void InterfaceOnlyEnvelopeIsRefused()
    {
        var error = Assert.Throws<ParseErrorException>(
            () => ShareLinkParser.Parse(Link(InterfaceOnly)));
        Assert.Equal(ParseErrorKind.MalformedUri, error.Kind);
        Assert.Equal("AmneziaWG config: missing peer PublicKey", error.Detail);
    }

    /// <summary>Measured Swift answer for `dns1`/`dns2` over an INI that ends
    /// with `[Peer]` and mentions no DNS: the server parses, and its DNS list
    /// stays empty.</summary>
    [Fact]
    public void EnvelopeDnsLandsAfterThePeerSectionAndIsLost()
    {
        var server = ShareLinkParser.Parse(Link(InterfaceOnly + Peer));
        Assert.Equal("Amnezia AWG", server.Name);
        Assert.NotNull(server.WgProfile);
        Assert.Empty(server.WgProfile!.Dns);
        Assert.Equal(new[] { "0.0.0.0/0" }, server.WgProfile.AllowedIPs);
    }

    /// <summary>Two containers, and `defaultContainer` names the second: Swift
    /// dials the endpoint of the container it was told to prefer, and falls back
    /// to the first only when the name matches nothing (all three answers taken
    /// from `LoaderTool dump-links`). Ignoring the preference would send a user
    /// to a server the panel did not pick — and with two WG containers in one
    /// envelope the endpoints differ, so the wrong choice is a wrong tunnel.</summary>
    [Theory]
    [InlineData("amnezia-awg", "172.16.0.9")]     // the second container
    [InlineData("wireguard", "10.0.0.1")]         // the first
    [InlineData("openvpn", "10.0.0.1")]           // a name that matches nothing
    [InlineData(null, "10.0.0.1")]                // no preference at all
    public void DefaultContainerPicksWhichEnvelopeServerSurvives(string? preferred, string expected)
    {
        var env = new JsonObject
        {
            ["hostName"] = "h",
            ["description"] = "D",
            ["containers"] = new JsonArray
            {
                new JsonObject
                {
                    ["container"] = "wireguard",
                    ["wireguard"] = new JsonObject { ["last_config"] = JsonSerializer.Serialize(new { config = Conf("10.0.0.1") }) },
                },
                new JsonObject
                {
                    ["container"] = "amnezia-awg",
                    ["awg"] = new JsonObject { ["last_config"] = JsonSerializer.Serialize(new { config = Conf("172.16.0.9") }) },
                },
            },
        };
        if (preferred is not null) env["defaultContainer"] = preferred;
        var link = "vpn://" + Url(Encoding.UTF8.GetBytes(env.ToJsonString()));
        Assert.Equal(expected, ShareLinkParser.Parse(link).Address);
    }

    /// <summary>`encryption=` on a vless link, measured: `none` and an empty
    /// value both mean "no vless encryption" and store nothing, while a real
    /// string is kept — it is the field a server with `decryption` requires, and
    /// a port that drops it imports a server that cannot handshake. Storing the
    /// word `none` would be the other failure: the outbound would ask the engine
    /// for an encryption mode named that.</summary>
    [Theory]
    [InlineData("none", null)]
    [InlineData("NONE", null)]
    [InlineData("", null)]
    [InlineData("1b232a42dc540bc1", "1b232a42dc540bc1")]
    public void VlessEncryptionIsKeptExceptWhenItMeansNothing(string value, string? expected)
    {
        var server = ShareLinkParser.Parse(
            "vless://1b564d2f-5117-4c8c-9b0d-9e2f8a3f1c22@example.com:443?encryption=" + value + "#n");
        Assert.Equal(expected, server.VlessEncryption);
    }

    private static string Conf(string ip) =>
        "[Interface]\nPrivateKey = yAnz5TF+fT28A5vH0vGcC8pVXqv5ZfV0+0P4Rn1v5HE=\nAddress = 10.8.1.2/32\n" +
        "[Peer]\nPublicKey = Ox5vDWfJ9yfkXcUuJ2XgKlQSmGvvnBB0qR9vK3F2zV0=\n" +
        $"Endpoint = {ip}:51820\nAllowedIPs = 0.0.0.0/0\n";

    private static string Url(byte[] data) =>
        Convert.ToBase64String(data).Replace('+', '-').Replace('/', '_').TrimEnd('=');

    private static int JsonLength(string ini)
    {
        var env = new JsonObject
        {
            ["hostName"] = "srv",
            ["description"] = "Amnezia AWG",
            ["defaultContainer"] = "amnezia-awg",
            ["containers"] = new JsonArray
            {
                new JsonObject
                {
                    ["container"] = "amnezia-awg",
                    ["awg"] = new JsonObject { ["last_config"] = JsonSerializer.Serialize(new { config = ini }) },
                },
            },
            ["dns1"] = "1.1.1.1",
            ["dns2"] = "8.8.8.8",
        };
        return Encoding.UTF8.GetByteCount(env.ToJsonString());
    }
}
