using AnemiaCore;
using Xunit;

namespace AnemiaCoreTests;

public class ShareLinkParserTests
{
    [Fact]
    public void ParsesVlessReality()
    {
        var link = "vless://b831381d-6324-4d53-ad4f-8cda48b30811@example.com:443" +
            "?encryption=none&security=reality&sni=www.microsoft.com&fp=chrome" +
            "&pbk=PUBKEY123&sid=abcd&spx=%2F&type=tcp&flow=xtls-rprx-vision#My%20Reality";

        var s = ShareLinkParser.Parse(link);
        Assert.Equal(ProxyProtocol.Vless, s.Proto);
        Assert.Equal("example.com", s.Address);
        Assert.Equal(443, s.Port);
        Assert.Equal("b831381d-6324-4d53-ad4f-8cda48b30811", s.Credential);
        Assert.Equal(StreamSecurity.Reality, s.Security);
        Assert.Equal("www.microsoft.com", s.Sni);
        Assert.Equal("chrome", s.Fingerprint);
        Assert.Equal("PUBKEY123", s.RealityPublicKey);
        Assert.Equal("abcd", s.RealityShortId);
        Assert.Equal("/", s.RealitySpiderX);
        Assert.Equal("xtls-rprx-vision", s.Flow);
        Assert.Equal(NetworkType.Tcp, s.Network);
        Assert.Equal("My Reality", s.Name);
    }

    [Fact]
    public void ParsesVlessWebSocketTls()
    {
        var link = "vless://uuid-1@cdn.example.net:8443" +
            "?encryption=none&security=tls&type=ws&path=%2Fwspath&host=cdn.example.net&sni=cdn.example.net#WS";
        var s = ShareLinkParser.Parse(link);
        Assert.Equal(NetworkType.Ws, s.Network);
        Assert.Equal(StreamSecurity.Tls, s.Security);
        Assert.Equal("/wspath", s.Path);
        Assert.Equal("cdn.example.net", s.Host);
    }

    [Fact]
    public void ParsesTrojanDefaultsToTls()
    {
        var link = "trojan://sekret-pass@t.example.org:443?type=tcp#Trojan";
        var s = ShareLinkParser.Parse(link);
        Assert.Equal(ProxyProtocol.Trojan, s.Proto);
        Assert.Equal("sekret-pass", s.Credential);
        Assert.Equal(StreamSecurity.Tls, s.Security);   // implied
        Assert.Equal(443, s.Port);
    }

    [Fact]
    public void ParsesVmess()
    {
        var json = "{\"v\":\"2\",\"ps\":\"Node-JP\",\"add\":\"jp.example.com\",\"port\":\"443\"," +
            "\"id\":\"11111111-2222-3333-4444-555555555555\",\"aid\":\"0\",\"scy\":\"auto\"," +
            "\"net\":\"ws\",\"type\":\"none\",\"host\":\"jp.example.com\",\"path\":\"/vm\"," +
            "\"tls\":\"tls\",\"sni\":\"jp.example.com\",\"fp\":\"chrome\"}";
        var b64 = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(json));
        var s = ShareLinkParser.Parse($"vmess://{b64}");
        Assert.Equal(ProxyProtocol.Vmess, s.Proto);
        Assert.Equal("Node-JP", s.Name);
        Assert.Equal("jp.example.com", s.Address);
        Assert.Equal(443, s.Port);
        Assert.Equal("11111111-2222-3333-4444-555555555555", s.Credential);
        Assert.Equal(0, s.AlterId);
        Assert.Equal(NetworkType.Ws, s.Network);
        Assert.Equal(StreamSecurity.Tls, s.Security);
        Assert.Equal("/vm", s.Path);
        Assert.Equal("jp.example.com", s.Host);
    }

    [Fact]
    public void ParsesShadowsocksSip002()
    {
        var userInfo = "aes-256-gcm:mypassword";
        var b64 = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(userInfo));
        var s = ShareLinkParser.Parse($"ss://{b64}@ss.example.com:8388#SS-Node");
        Assert.Equal(ProxyProtocol.Ss, s.Proto);
        Assert.Equal("aes-256-gcm", s.Method);
        Assert.Equal("mypassword", s.Credential);
        Assert.Equal("ss.example.com", s.Address);
        Assert.Equal(8388, s.Port);
        Assert.Equal("SS-Node", s.Name);
    }

    /// <summary>SIP002 generators that percent-encode the base64 userinfo
    /// (= as %3D, +/ / as %2B/%2F) used to fail with malformedURI: the first
    /// decode ran on the still-encoded string and the fallback never retried
    /// base64 after percent-decoding.</summary>
    [Fact]
    public void ParsesShadowsocksSip002PercentEncodedBase64()
    {
        var userInfo = "aes-256-gcm:mypassword";
        var b64 = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(userInfo))
            .Replace("=", "%3D");
        var s = ShareLinkParser.Parse($"ss://{b64}@ss.example.com:8388#SS-Node");
        Assert.Equal("aes-256-gcm", s.Method);
        Assert.Equal("mypassword", s.Credential);
        Assert.Equal("ss.example.com", s.Address);
        Assert.Equal(8388, s.Port);
    }

    /// <summary>Plain percent-encoded method:password userinfo (: as %3A) must
    /// survive the base64-retry path too — the retry must not swallow it.</summary>
    [Fact]
    public void ParsesShadowsocksSip002PlainPercentEncoded()
    {
        var s = ShareLinkParser.Parse("ss://aes-256-gcm%3AmyPassword@ss.example.com:8388#SS");
        Assert.Equal("aes-256-gcm", s.Method);
        Assert.Equal("myPassword", s.Credential);
        Assert.Equal("ss.example.com", s.Address);
        Assert.Equal(8388, s.Port);
    }

    [Fact]
    public void ParsesShadowsocksLegacy()
    {
        var whole = "chacha20-ietf-poly1305:pw123@legacy.example.com:8389";
        var b64 = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(whole));
        var s = ShareLinkParser.Parse($"ss://{b64}#Legacy");
        Assert.Equal("chacha20-ietf-poly1305", s.Method);
        Assert.Equal("pw123", s.Credential);
        Assert.Equal("legacy.example.com", s.Address);
        Assert.Equal(8389, s.Port);
    }

    [Fact]
    public void UnsupportedSchemeThrows()
    {
        var ex = Assert.Throws<ParseErrorException>(() => ShareLinkParser.Parse("http://example.com"));
        Assert.Equal(new ParseErrorException(ParseErrorKind.UnsupportedScheme, "http"), ex);
    }

    [Fact]
    public void ParsesIpv6Host()
    {
        var link = "vless://uuid-9@[2606:4700:4700::1111]:443?encryption=none&security=tls&type=tcp#v6";
        var s = ShareLinkParser.Parse(link);
        Assert.Equal("2606:4700:4700::1111", s.Address);
        Assert.Equal(443, s.Port);
    }

    // MARK: Transport normalization

    /// <summary>Real-world links spell the same transport several ways; aliases
    /// must all map to the canonical NetworkType.</summary>
    [Theory]
    [InlineData("h2", NetworkType.Http)]
    [InlineData("kcp", NetworkType.Kcp)]
    [InlineData("mkcp", NetworkType.Kcp)]
    [InlineData("raw", NetworkType.Tcp)]
    [InlineData("none", NetworkType.Tcp)]  // panels emit type=none for plain TCP
    [InlineData("websocket", NetworkType.Ws)]
    [InlineData("httpupgrade", NetworkType.HttpUpgrade)]
    public void TransportAliases(string type, NetworkType expected)
    {
        var link = $"vless://u@h.example.com:443?security=tls&type={type}#n";
        Assert.Equal(expected, ShareLinkParser.Parse(link).Network);
    }

    /// <summary>An unknown transport must fail the parse loudly — the old
    /// silent .tcp fallback wired the link to a plain-TCP connection that could
    /// never complete the real handshake. (This test used to assert `xhttp` was
    /// one of them; the corpus golden says Swift parses it, so the port does too
    /// and <see cref="XhttpCarriesModeAndExtra"/> pins it.)</summary>
    [Fact]
    public void UnknownTransportThrows()
    {
        var ex = Assert.Throws<ParseErrorException>(
            () => ShareLinkParser.Parse("vless://u@h.example.com:443?type=h2x#n"));
        Assert.Equal(new ParseErrorException(ParseErrorKind.UnsupportedTransport, "h2x"), ex);
    }

    /// <summary>xhttp (spelled `splithttp` by newer panels) keeps its two own
    /// parameters: `mode` and `extra`. Neither is folded to lower case — the
    /// engine compares them exactly — and an empty one is absent, not "auto",
    /// because that would send a mode the server was not configured for.</summary>
    [Fact]
    public void XhttpCarriesModeAndExtra()
    {
        foreach (var spelling in new[] { "xhttp", "splithttp", "XHTTP" })
        {
            var server = ShareLinkParser.Parse(
                $"vless://u@h.example.com:443?security=tls&type={spelling}" +
                "&mode=packet-up&extra=%7B%22xc%22%3A%22reload%22%7D&path=%2Fx#n");
            Assert.Equal(NetworkType.Xhttp, server.Network);
            Assert.Equal("packet-up", server.XhttpMode);
            Assert.Equal("""{"xc":"reload"}""", server.XhttpExtra);
            Assert.Equal("/x", server.Path);
        }

        var bare = ShareLinkParser.Parse("vless://u@h.example.com:443?type=xhttp&mode=&extra=");
        Assert.Null(bare.XhttpMode);
        Assert.Null(bare.XhttpExtra);
    }

    // MARK: gRPC extras

    [Fact]
    public void GrpcModeAndAuthority()
    {
        var link = "vless://u@g.example.com:443?security=tls&type=grpc" +
            "&serviceName=GunSvc&host=front.example.com&mode=multi#GR";
        var s = ShareLinkParser.Parse(link);
        Assert.Equal(NetworkType.Grpc, s.Network);
        Assert.Equal("GunSvc", s.Path);
        Assert.Equal("front.example.com", s.Host);
        Assert.Equal(true, s.GrpcMultiMode);
    }

    [Fact]
    public void GrpcDefaultsToSingleMode()
    {
        var link = "vless://u@g.example.com:443?security=tls&type=grpc&serviceName=GunSvc#GR";
        var s = ShareLinkParser.Parse(link);
        Assert.NotEqual(true, s.GrpcMultiMode);
    }

    // MARK: SIP002 host:port edge cases

    /// <summary>SIP002 permits a trailing path after the port (host:8388/ or
    /// host:8388/?plugin=…); the path is decoration, not part of the
    /// authority, and used to break the whole import.</summary>
    [Fact]
    public void Sip002TrailingPath()
    {
        var b64 = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes("aes-256-gcm:pw"));
        var s = ShareLinkParser.Parse($"ss://{b64}@ss.example.com:8388/#SS");
        Assert.Equal("ss.example.com", s.Address);
        Assert.Equal(8388, s.Port);
    }

    /// <summary>A SIP002 plugin= names an external helper process (obfs-local,
    /// v2ray-plugin) the app never bundles: parsing it silently used to import
    /// a server that could only fail at connect time with an opaque TLS/reset
    /// error. It must fail loudly at import instead.</summary>
    [Fact]
    public void Sip002PluginFailsLoud()
    {
        var b64 = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes("aes-256-gcm:pw"));
        var ex = Assert.Throws<ParseErrorException>(() => ShareLinkParser.Parse(
            $"ss://{b64}@ss.example.com:8388/?plugin=obfs-local%3Bobfs%3Dhttp#SS"));
        Assert.Equal(ParseErrorKind.UnsupportedTransport, ex.Kind);
        Assert.Contains("obfs-local", ex.Detail);
    }

    /// <summary>v2rayN-style links are pasted with a #name or ?note suffix
    /// after the base64 body; a lenient base64 decode used to choke on the
    /// suffix's letters and the whole link read as "invalid".</summary>
    [Theory]
    [InlineData("#renamed")]
    [InlineData("?added=later")]
    [InlineData("#a%20b?not-json")]
    public void ParsesVmessFragmentAndQueryPeel(string suffix)
    {
        var json = "{\"v\":\"2\",\"ps\":\"Node-FR\",\"add\":\"fr.example.com\",\"port\":\"443\"," +
            "\"id\":\"11111111-2222-3333-4444-555555555555\",\"aid\":\"0\",\"net\":\"tcp\",\"tls\":\"tls\"}";
        var b64 = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(json));
        var s = ShareLinkParser.Parse($"vmess://{b64}{suffix}");
        Assert.Equal("fr.example.com", s.Address);
        Assert.Equal("Node-FR", s.Name);
        Assert.Equal(StreamSecurity.Tls, s.Security);
    }

    /// <summary>tls may arrive as a JSON Bool (true/false) or the strings
    /// "tls"/"" — and v2rayN sends "tls": "xtls" for legacy XTLS links, which
    /// must map to the tolerated .xtls security, not fall back to none.</summary>
    [Theory]
    [InlineData("true", StreamSecurity.Tls)]
    [InlineData("false", StreamSecurity.None)]
    [InlineData("\"tls\"", StreamSecurity.Tls)]
    [InlineData("\"xtls\"", StreamSecurity.Xtls)]
    [InlineData("\"none\"", StreamSecurity.None)]
    public void ParsesVmessTlsVariants(string tls, StreamSecurity expected)
    {
        var json = "{\"v\":\"2\",\"ps\":\"N\",\"add\":\"a.example.com\",\"port\":\"443\"," +
            "\"id\":\"11111111-2222-3333-4444-555555555555\",\"aid\":\"0\",\"net\":\"tcp\",\"tls\":" + tls + "}";
        var b64 = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(json));
        Assert.Equal(expected, ShareLinkParser.Parse($"vmess://{b64}").Security);
    }

    /// <summary>The vmess scy cipher travels to the engine's user object; a
    /// link with scy: "zero" that imported as cipher auto would fail auth
    /// silently.</summary>
    [Fact]
    public void ParsesVmessScyCipher()
    {
        var json = "{\"v\":\"2\",\"ps\":\"N\",\"add\":\"a.example.com\",\"port\":\"443\"," +
            "\"id\":\"11111111-2222-3333-4444-555555555555\",\"aid\":\"0\",\"scy\":\"zero\"," +
            "\"net\":\"tcp\",\"tls\":\"none\"}";
        var b64 = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(json));
        Assert.Equal("zero", ShareLinkParser.Parse($"vmess://{b64}").VmessCipher);

        var noScy = "{\"v\":\"2\",\"ps\":\"N\",\"add\":\"a.example.com\",\"port\":\"443\"," +
            "\"id\":\"11111111-2222-3333-4444-555555555555\",\"aid\":\"0\",\"net\":\"tcp\",\"tls\":\"none\"}";
        var s2 = ShareLinkParser.Parse("vmess://" + Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(noScy)));
        Assert.Null(s2.VmessCipher);   // engine default (auto) applies
    }
}

public class SubscriptionParserTests
{
    [Fact]
    public void ParsesBase64Blob()
    {
        var links = string.Join("\n",
            "vless://uuid-a@a.example.com:443?encryption=none&security=reality&pbk=P&type=tcp#A",
            "trojan://pw@b.example.com:443?type=tcp#B");
        var blob = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(links));
        var result = SubscriptionParser.Parse(blob);
        Assert.Equal(2, result.Servers.Count);
        Assert.Empty(result.Failures);
        Assert.Equal(ProxyProtocol.Vless, result.Servers[0].Proto);
        Assert.Equal(ProxyProtocol.Trojan, result.Servers[1].Proto);
    }

    [Fact]
    public void SkipsBadLinesButKeepsGood()
    {
        var text = "vless://uuid-a@a.example.com:443?encryption=none&type=tcp#A\nnot-a-link\ngarbage://x";
        var result = SubscriptionParser.Parse(text);
        Assert.Single(result.Servers);
        Assert.Single(result.Failures);  // "garbage://" is a failed parse; "not-a-link" is skipped
    }
}