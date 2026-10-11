using AnemiaCore;
using Xunit;

namespace AnemiaCoreTests;

/// <summary>
/// The AWG rules the shared goldens do not reach. Each one here exists because a
/// mutation of it survived the parity run against
/// `Android/core/src/test/resources/awg` — the fixtures never carry a bare
/// address, a `Jc` equal to the MTU, a 64-character key that is not hex, or a
/// control character inside an `I` value. Kotlin's suite has the same blind
/// spots, so these are pinned locally rather than left "covered by the golden".
/// </summary>
public class AmneziaWgRuleTests
{
    private static ProxyServer Base() => new()
    {
        Name = "t",
        Proto = ProxyProtocol.Amnezia,
        Address = "10.0.0.1",
        Port = 51820,
        Credential = "yAnz5TF+fT28A5vH0vGcC8pVXqv5ZfV0+0P4Rn1v5HE=",
        WgProfile = new WireGuardProfile("Ox5vDWfJ9yfkXcUuJ2XgKlQSmGvvnBB0qR9vK3F2zV0="),
    };

    [Theory]
    [InlineData("10.8.1.2", "10.8.1.2/32")]           // wg-quick reads a bare address as a host route
    [InlineData("fd42::2", "fd42::2/128")]
    [InlineData("10.8.1.2/24", "10.8.1.2/24")]
    [InlineData(" 10.8.1.2/32 ", "10.8.1.2/32")]      // Foundation trims, the daemon does not see spaces
    [InlineData("10.8.1.2/+8", "10.8.1.2/8")]         // Int(String) takes a sign, and the prefix is rewritten
    public void AllowedIpNormalizesToADaemonRoute(string entry, string expected) =>
        Assert.Equal(expected, AmneziaWgConfigBuilder.AllowedIP(entry));

    [Theory]
    [InlineData("")]
    [InlineData("example.com")]                  // a name is not a route
    [InlineData("10.8.1.2/33")]                  // past the family's prefix limit
    [InlineData("fd42::2/129")]
    [InlineData("10.8.1.2//32")]
    public void AllowedIpRefusesWhatTheDaemonWouldReject(string entry) =>
        Assert.Null(AmneziaWgConfigBuilder.AllowedIP(entry));

    [Fact]
    public void AFullTunnelDefaultSurvivesAnAbsentAllowedIps()
    {
        // A conf that names no AllowedIPs must keep the default; replacing it
        // with an empty list routes nothing.
        var server = WireGuardLink.ParseConfigText(string.Join("\n",
            "[Interface]",
            "PrivateKey = yAnz5TF+fT28A5vH0vGcC8pVXqv5ZfV0+0P4Rn1v5HE=",
            "",
            "[Peer]",
            "PublicKey = Ox5vDWfJ9yfkXcUuJ2XgKlQSmGvvnBB0qR9vK3F2zV0=",
            "Endpoint = 203.0.113.9:51820"));
        Assert.Equal(new[] { "0.0.0.0/0", "::/0" }, server.WgProfile!.AllowedIPs);
        Assert.Empty(AmneziaWgConfigBuilder.Validate(server));
    }

    [Fact]
    public void JunkPacketExactlyAtTheMtuIsRefused()
    {
        // `>` instead of `>=` survives every fixture, because none of them sets
        // Jmax equal to the MTU — yet that packet is fragmented all the same.
        var server = Base();
        server.WgProfile!.Mtu = 1400;
        server.Awg = new AwgObfuscation { JunkMax = 1400 };
        Assert.Contains(AmneziaWgConfigBuilder.Validate(server),
                        problem => problem.Contains("Jmax (1400) ≥ MTU (1400)", StringComparison.Ordinal));
    }

    [Fact]
    public void PaddingCollisionIsFoundBySubtractingNotAdding()
    {
        var server = Base();
        server.Awg = new AwgObfuscation { InitPadding = 40, ResponsePadding = 96 };
        Assert.Contains(AmneziaWgConfigBuilder.Validate(server),
                        problem => problem.StartsWith("S1 + 56 = S2", StringComparison.Ordinal));
        // 96 + 56 would be the same collision read from the other side, and it is
        // not one: the initiation is the larger packet.
        var other = Base();
        other.Awg = new AwgObfuscation { InitPadding = 152, ResponsePadding = 96 };
        Assert.DoesNotContain(AmneziaWgConfigBuilder.Validate(other),
                              problem => problem.StartsWith("S1 + 56 = S2", StringComparison.Ordinal));
    }

    [Fact]
    public void SixtyFourCharactersAreOnlyAKeyWhenTheyAreHex()
    {
        // The builder's own rule, and the validator must not be narrower than it:
        // 64 hex chars pass, 44 base64 chars pass, anything else that merely has
        // the right length does not.
        Assert.NotNull(AmneziaWgConfigBuilder.HexKey(new string('0', 63) + "a"));
        Assert.NotNull(AmneziaWgConfigBuilder.HexKey("yAnz5TF+fT28A5vH0vGcC8pVXqv5ZfV0+0P4Rn1v5HE="));
        Assert.Null(AmneziaWgConfigBuilder.HexKey(new string('g', 64)));
        Assert.Null(AmneziaWgConfigBuilder.HexKey("yAnz5TF+fT28A5vH0vGcC8pVXqv5ZfV0+0P4Rn1v5H"));
        // Uppercase hex is lowercased on the way in — the daemon decodes with
        // FromHex, which takes lowercase only.
        Assert.Equal(new string('f', 64), AmneziaWgConfigBuilder.HexKey(new string('F', 64)));
    }

    [Fact]
    public void TimerRangesAreJudgedAtTheirOwnWidth()
    {
        // ContentPaddingAddition and friends are u16 on the wire: 70000 parses as
        // a number and is still unusable, and only the 65535 bound says so.
        var server = Base();
        server.Awg = new AwgObfuscation { ContentPaddingAddition = "70000", RekeyAfterTime = "10-20-30" };
        var problems = AmneziaWgConfigBuilder.Validate(server);
        Assert.Contains(problems, problem => problem.Contains("ContentPaddingAddition = 70000", StringComparison.Ordinal));
        Assert.Contains(problems, problem => problem.Contains("RekeyAfterTime = 10-20-30", StringComparison.Ordinal));
    }

    [Fact]
    public void AControlCharacterInAnIValueIsRefusedByValidatorAndBuilder()
    {
        // The script is line-oriented and goes to a root daemon: one newline
        // inside a chain spec is one more directive, able to rewrite the private
        // key or the routes after it.
        var server = Base();
        server.Awg = new AwgObfuscation { SpecialHandshakes = new List<string> { "<b 41>\nset=2" } };
        Assert.Contains(AmneziaWgConfigBuilder.Validate(server),
                        problem => problem.StartsWith("I1 has a character outside", StringComparison.Ordinal));
        var error = Assert.Throws<ParseErrorException>(
            () => AmneziaWgConfigBuilder.MakeUapiSetScript(server));
        Assert.Contains("carries an unprintable character", error.Message);
    }

    [Fact]
    public void TheScriptEndsWithItsOwnBlankLine()
    {
        // The parity comparison trims both sides (as the Kotlin check does), so
        // this is pinned here instead: a script without the trailing newline is
        // the last directive cut off.
        var script = AmneziaWgConfigBuilder.MakeUapiSetScript(Base());
        Assert.EndsWith("protocol_version=1\n", script, StringComparison.Ordinal);
    }

    [Fact]
    public void PlainWireGuardConfIsNotCalledAmnezia()
    {
        var server = WireGuardLink.ParseConfigText(string.Join("\n",
            "[Interface]",
            "PrivateKey = yAnz5TF+fT28A5vH0vGcC8pVXqv5ZfV0+0P4Rn1v5HE=",
            "Address = 10.8.1.2/32",
            "",
            "[Peer]",
            "PublicKey = Ox5vDWfJ9yfkXcUuJ2XgKlQSmGvvnBB0qR9vK3F2zV0=",
            "Endpoint = 203.0.113.9:51820"));
        Assert.Equal(ProxyProtocol.WireGuard, server.Proto);
        Assert.Null(server.Awg);
        Assert.Equal(AwgVersion.V1, server.AwgVersion);
    }

    [Fact]
    public void ABareInterfaceAddressKeepsItsHostPrefix()
    {
        // `Address = 10.8.1.2` without a prefix is how several panels export the
        // profile. wg-quick reads it as /32, and dropping the entry instead would
        // leave the tunnel with no address at all — silently, because the conf
        // parsed fine.
        var server = WireGuardLink.ParseConfigText(string.Join("\n",
            "[Interface]",
            "PrivateKey = yAnz5TF+fT28A5vH0vGcC8pVXqv5ZfV0+0P4Rn1v5HE=",
            "Address = 10.8.1.2, fd00::2",
            "",
            "[Peer]",
            "PublicKey = Ox5vDWfJ9yfkXcUuJ2XgKlQSmGvvnBB0qR9vK3F2zV0=",
            "Endpoint = 203.0.113.9:51820"));
        Assert.Equal("10.8.1.2/32, fd00::2/128", server.UserData!["wgAddress"]);
        Assert.Equal("10.8.1.2", AmneziaWgConfigBuilder.TunnelIPv4(server));
    }

    [Fact]
    public void ADuplicatedConfKeyTakesTheLastValue()
    {
        // Swift assigns into the section dictionary, so the last line wins — and
        // panels that re-emit a conf really do repeat a key. First-wins here would
        // quietly pick a stale endpoint.
        var server = WireGuardLink.ParseConfigText(string.Join("\n",
            "[Interface]",
            "PrivateKey = yAnz5TF+fT28A5vH0vGcC8pVXqv5ZfV0+0P4Rn1v5HE=",
            "Address = 10.8.1.2/32",
            "MTU = 1280",
            "MTU = 1420",
            "",
            "[Peer]",
            "PublicKey = Ox5vDWfJ9yfkXcUuJ2XgKlQSmGvvnBB0qR9vK3F2zV0=",
            "Endpoint = old.example.com:51820",
            "Endpoint = new.example.com:51821"));
        Assert.Equal(1420, server.WgProfile!.Mtu);
        Assert.Equal("new.example.com", server.Address);
        Assert.Equal(51821, server.Port);
    }

    [Fact]
    public void AnEmptyPrivateKeyIsAMissingOne()
    {
        // `PrivateKey = ` parses as a key that exists; Swift's non-empty check
        // treats it as absent, and the daemon would otherwise be handed a script
        // without a key at all.
        Assert.Throws<ParseErrorException>(() => WireGuardLink.ParseConfigText(string.Join("\n",
            "[Interface]",
            "PrivateKey =",
            "Address = 10.8.1.2/32",
            "",
            "[Peer]",
            "PublicKey = Ox5vDWfJ9yfkXcUuJ2XgKlQSmGvvnBB0qR9vK3F2zV0=",
            "Endpoint = 203.0.113.9:51820")));
    }
}
