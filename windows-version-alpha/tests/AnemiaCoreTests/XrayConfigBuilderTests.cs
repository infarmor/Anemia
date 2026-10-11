using System.Text.Json.Nodes;
using AnemiaCore;
using Xunit;

namespace AnemiaCoreTests;

public class XrayConfigBuilderTests
{
    private static ProxyServer RealityServer() => new(
        name: "R", proto: ProxyProtocol.Vless, address: "example.com", port: 443,
        credential: "uuid-1", network: NetworkType.Tcp, security: StreamSecurity.Reality,
        sni: "www.microsoft.com", fingerprint: "chrome",
        realityPublicKey: "PBK", realityShortId: "abcd", flow: "xtls-rprx-vision");

    private static JsonObject ProxyOutbound(JsonObject cfg) =>
        ((cfg["outbounds"] as JsonArray)!).OfType<JsonObject>()
            .First(o => o["tag"]?.GetValue<string>() == "proxy");

    [Fact]
    public void InboundsPresent()
    {
        var builder = new XrayConfigBuilder(socksPort: 10808, httpPort: 10809, apiPort: null);
        var cfg = builder.MakeConfig(RealityServer(), AntiCensorshipOptions.Off());
        var inbounds = (cfg["inbounds"] as JsonArray)!;
        Assert.Equal(2, inbounds.Count);   // no api inbound when apiPort == null
        Assert.Equal(10808, inbounds[0]!["port"]!.GetValue<int>());
        Assert.Equal(10809, inbounds[1]!["port"]!.GetValue<int>());
    }

    /// <summary>Regression: the fold into Int used to keep the sign bit, and
    /// Swift's % keeps the dividend's sign — the mimicry pick
    /// mimicry[stableHash(id) % count] then built a negative index and crashed
    /// the whole config builder (Index out of range) for any server whose
    /// identity hashed sign-bit-set. The hash must stay non-negative so the
    /// modulo is always in-bounds.</summary>
    [Fact]
    public void StableHashNeverNegative()
    {
        var keys = new List<string> { "", "a", "example.com", "e.com|vless|tcp|443|uuid-1", "🇩🇪 DE-01" };
        for (var i = 0; i < 2000; i++)
            keys.Add($"node-{i}@panel-{i % 7}.example");
        foreach (var k in keys)
            Assert.True(XrayConfigBuilder.StableHash(k) >= 0,
                $"negative stableHash crashes the mimicry pick for key {k}");
        // And the actual use site: a mimicry pick over a RU preset must build
        // a config for ANY identity, including formerly-crashing ones.
        var anti = AntiCensorshipOptions.RussiaYandex();
        foreach (var k in keys)
        {
            var server = new ProxyServer(name: k, proto: ProxyProtocol.Trojan, address: "real.example.com",
                port: 443, credential: "p", network: NetworkType.Tcp, security: StreamSecurity.Tls);
            new XrayConfigBuilder().MakeConfigData(server, anti);
        }
    }

    [Fact]
    public void StatsApiInboundAndPolicy()
    {
        var cfg = new XrayConfigBuilder(apiPort: 10812).MakeConfig(RealityServer(), AntiCensorshipOptions.Off());
        var inbounds = (cfg["inbounds"] as JsonArray)!;
        Assert.Contains(inbounds.OfType<JsonObject>(), i => i["tag"]?.GetValue<string>() == "api-in");
        Assert.Equal("api", (cfg["api"] as JsonObject)?["tag"]?.GetValue<string>());
        Assert.NotNull(cfg["stats"]);
        Assert.NotNull(cfg["policy"]);
        Assert.NotNull(cfg["dns"]);   // anti-leak DNS always present
    }

    /// <summary>The connection-tuning policy (buffer/idle/handshake) is always
    /// present — even without the stats API — and the stats system-policy is
    /// merged in, not overwritten, when the API is enabled. BufferSizeKb is
    /// honoured.</summary>
    [Fact]
    public void ConnectionPolicyTuning()
    {
        // No API: level-0 tuning still present, no stats system policy.
        var noApi = new XrayConfigBuilder(apiPort: null, bufferSizeKb: 768)
            .MakeConfig(RealityServer(), AntiCensorshipOptions.Off());
        var p0 = noApi["policy"] as JsonObject;
        var level0 = ((p0?["levels"] as JsonObject)?["0"]) as JsonObject;
        Assert.Equal(768, level0?["bufferSize"]?.GetValue<int>());
        Assert.Equal(300, level0?["connIdle"]?.GetValue<int>());
        Assert.Equal(4, level0?["handshake"]?.GetValue<int>());
        Assert.Null(p0?["system"]);  // no stats system policy without the API

        // With API: tuning kept AND stats system policy merged in.
        var withApi = new XrayConfigBuilder(apiPort: 10812).MakeConfig(RealityServer(), AntiCensorshipOptions.Off());
        var p1 = withApi["policy"] as JsonObject;
        Assert.NotNull((p1?["levels"] as JsonObject)?["0"]);
        Assert.Equal(true, (p1?["system"] as JsonObject)?["statsOutboundUplink"]?.GetValue<bool>());
    }

    /// <summary>QUIC (UDP/443) is routed to the block outbound by default so
    /// browsers fall back to TCP; disabling BlockQuic removes the rule. DNS
    /// caching is explicit.</summary>
    [Fact]
    public void BlockQuicAndDnsCache()
    {
        static JsonObject? QuicRule(JsonObject cfg)
        {
            var rules = (cfg["routing"] as JsonObject)!["rules"] as JsonArray;
            return rules!.OfType<JsonObject>()
                .FirstOrDefault(r => r["network"]?.GetValue<string>() == "udp" && r["port"]?.GetValue<int>() == 443);
        }
        var on = new XrayConfigBuilder().MakeConfig(RealityServer(), AntiCensorshipOptions.Off());
        var rule = QuicRule(on);
        Assert.Equal("block", rule?["outboundTag"]?.GetValue<string>());
        Assert.Equal(false, (on["dns"] as JsonObject)?["disableCache"]?.GetValue<bool>());

        var off = new XrayConfigBuilder(blockQuic: false).MakeConfig(RealityServer(), AntiCensorshipOptions.Off());
        Assert.Null(QuicRule(off));  // no QUIC block rule when disabled
    }

    [Fact]
    public void RealityOutbound()
    {
        var cfg = new XrayConfigBuilder().MakeConfig(RealityServer(), AntiCensorshipOptions.Off());
        var proxy = ProxyOutbound(cfg);
        var stream = proxy["streamSettings"] as JsonObject;
        Assert.Equal("reality", stream!["security"]!.GetValue<string>());
        var reality = stream["realitySettings"] as JsonObject;
        Assert.Equal("PBK", reality!["publicKey"]!.GetValue<string>());
        Assert.Equal("www.microsoft.com", reality["serverName"]!.GetValue<string>());

        // Vision flow present on user.
        var settings = proxy["settings"] as JsonObject;
        var vnext = (settings!["vnext"] as JsonArray)![0] as JsonObject;
        var users = (vnext!["users"] as JsonArray)![0] as JsonObject;
        Assert.Equal("xtls-rprx-vision", users!["flow"]!.GetValue<string>());
    }

    [Fact]
    public void FragmentAndNoiseInjected()
    {
        var cfg = new XrayConfigBuilder().MakeConfig(RealityServer(), AntiCensorshipOptions.Recommended);
        var outbounds = (cfg["outbounds"] as JsonArray)!;

        // Fragment outbound exists and carries junk noises (TFO is — by
        // design, Xray-core#989 — never emitted).
        var fragment = outbounds.OfType<JsonObject>()
            .FirstOrDefault(o => o["tag"]?.GetValue<string>() == "fragment");
        Assert.NotNull(fragment);  // fragment dialer outbound should be present
        var fragStream = fragment!["streamSettings"] as JsonObject;
        var fragSockopt = fragStream!["sockopt"] as JsonObject;
        Assert.Null(fragSockopt!["tcpFastOpen"]);  // TFO is EINVAL-fatal — never emit it
        Assert.True(fragSockopt["tcpNoDelay"]!.GetValue<bool>(), "sockopt must disable Nagle");
        Assert.NotNull(fragSockopt["noises"]);     // junk noises should be present

        // Proxy chains into the fragment dialer.
        var proxy = ProxyOutbound(cfg);
        var proxyStream = proxy["streamSettings"] as JsonObject;
        var proxySockopt = proxyStream!["sockopt"] as JsonObject;
        Assert.Equal("fragment", proxySockopt!["dialerProxy"]!.GetValue<string>());
    }

    [Fact]
    public void VisionDisablesMux()
    {
        var anti = AntiCensorshipOptions.Recommended;
        anti.MuxEnabled = true;
        var cfg = new XrayConfigBuilder().MakeConfig(RealityServer(), anti);
        var proxy = ProxyOutbound(cfg);
        Assert.Null(proxy["mux"]);  // mux must be disabled under XTLS-Vision
    }

    [Fact]
    public void ShadowsocksOutbound()
    {
        var s = new ProxyServer(name: "S", proto: ProxyProtocol.Ss, address: "ss.example.com", port: 8388,
            credential: "pw", method: "aes-256-gcm");
        var cfg = new XrayConfigBuilder().MakeConfig(s, AntiCensorshipOptions.Off());
        var proxy = ProxyOutbound(cfg);
        Assert.Equal("shadowsocks", proxy["protocol"]!.GetValue<string>());
        var servers = ((proxy["settings"] as JsonObject)!["servers"] as JsonArray)!;
        var server0 = servers[0] as JsonObject;
        Assert.Equal("aes-256-gcm", server0!["method"]!.GetValue<string>());
    }

    [Fact]
    public void SerializesToValidJson()
    {
        var data = new XrayConfigBuilder().MakeConfigData(RealityServer(), AntiCensorshipOptions.Recommended);
        var roundtrip = JsonNode.Parse(data) as JsonObject;
        Assert.NotNull(roundtrip?["outbounds"]);
    }

    /// <summary>HTTP/2 and QUIC stream transports were removed from the engine
    /// in 26.x — building a config for them must fail with a clear error, not
    /// produce something the engine rejects with a cryptic core message.</summary>
    [Theory]
    [InlineData(NetworkType.Http)]
    [InlineData(NetworkType.Quic)]
    public void RemovedTransportsRejectedAtBuild(NetworkType network)
    {
        var server = RealityServer();
        server.Network = network;
        var ex = Assert.Throws<ConfigBuilderException>(
            () => new XrayConfigBuilder().MakeConfigData(server, AntiCensorshipOptions.Off()));
        Assert.Equal(ConfigBuilderErrorKind.TransportRemovedByEngine, ex.Kind);
    }

    /// <summary>gRPC mode=multi and the :authority from the link must survive
    /// into grpcSettings — dropping them silently broke servers that need
    /// them.</summary>
    [Fact]
    public void GrpcSettingsCarryModeAndAuthority()
    {
        var server = RealityServer();
        server.Network = NetworkType.Grpc;
        server.Path = "GunSvc";
        server.Host = "front.example.com";
        server.GrpcMultiMode = true;
        var cfg = new XrayConfigBuilder().MakeConfig(server, AntiCensorshipOptions.Off());
        var grpc = ((ProxyOutbound(cfg)["streamSettings"] as JsonObject)!["grpcSettings"]) as JsonObject;
        Assert.Equal("GunSvc", grpc!["serviceName"]!.GetValue<string>());
        Assert.Equal("front.example.com", grpc["authority"]!.GetValue<string>());
        Assert.True(grpc["multiMode"]!.GetValue<bool>(), "gRPC multiMode must be on");
    }

    [Fact]
    public void GrpcOmitsMultiModeByDefault()
    {
        var server = RealityServer();
        server.Network = NetworkType.Grpc;
        server.Path = "GunSvc";
        var cfg = new XrayConfigBuilder().MakeConfig(server, AntiCensorshipOptions.Off());
        var grpc = ((ProxyOutbound(cfg)["streamSettings"] as JsonObject)!["grpcSettings"]) as JsonObject;
        Assert.Null(grpc!["multiMode"]);
        Assert.Null(grpc["authority"]);
    }

    /// <summary>26.x removed mKCP seed and header obfuscation — emitting either
    /// is a config error. kcpSettings must carry neither key.</summary>
    [Fact]
    public void MkcpSettingsHaveNoSeedOrHeader()
    {
        var server = RealityServer();
        server.Network = NetworkType.Kcp;
        server.Path = "seed-value";      // legacy links parked the seed here
        server.HeaderType = "srtp";
        var cfg = new XrayConfigBuilder().MakeConfig(server, AntiCensorshipOptions.Off());
        var kcp = ((ProxyOutbound(cfg)["streamSettings"] as JsonObject)!["kcpSettings"]) as JsonObject;
        Assert.Null(kcp!["seed"]);
        Assert.Null(kcp["header"]);
    }

    /// <summary>TCP http-obfuscation must carry the link's path/Host in the
    /// full request — a bare {"type":"http"} makes Xray substitute defaults and
    /// silently drop them.</summary>
    [Fact]
    public void TcpHTTPHeaderCarriesRequest()
    {
        var server = RealityServer();
        server.HeaderType = "http";
        server.Path = "/loose";
        server.Host = "front.example.com";
        var cfg = new XrayConfigBuilder().MakeConfig(server, AntiCensorshipOptions.Off());
        var tcp = ((ProxyOutbound(cfg)["streamSettings"] as JsonObject)!["tcpSettings"]) as JsonObject;
        var header = (tcp!["header"]) as JsonObject;
        Assert.Equal("http", header!["type"]!.GetValue<string>());
        var request = header["request"] as JsonObject;
        Assert.Equal("/loose", (request!["path"] as JsonArray)![0]!.GetValue<string>());
        var headers = request["headers"] as JsonObject;
        Assert.Equal("front.example.com", (headers!["Host"] as JsonArray)![0]!.GetValue<string>());
    }

    /// <summary>The vmess scy cipher from the link must reach the engine's user
    /// object; null means the engine default (auto) applies.</summary>
    [Fact]
    public void VmessCipherReachesUserObject()
    {
        static JsonArray Users(string? vmessCipher)
        {
            var s = new ProxyServer(name: "V", proto: ProxyProtocol.Vmess, address: "vm.example.com", port: 443,
                credential: "11111111-2222-3333-4444-555555555555",
                network: NetworkType.Tcp, security: StreamSecurity.None, vmessCipher: vmessCipher);
            var cfg = new XrayConfigBuilder().MakeConfig(s, AntiCensorshipOptions.Off());
            var proxy = ProxyOutbound(cfg);
            var settings = proxy["settings"] as JsonObject;
            return ((settings!["vnext"] as JsonArray)!)[0]!["users"]!.AsArray();
        }
        Assert.Equal("zero", (Users("zero")[0] as JsonObject)!["security"]!.GetValue<string>());
        Assert.Equal("auto", (Users(null)[0] as JsonObject)!["security"]!.GetValue<string>());
    }

    /// <summary>Reality honors the link's ALPN list — CDNs fronting Reality
    /// panels commonly require h2; dropping it made the handshake fail at the
    /// edge.</summary>
    [Fact]
    public void RealityEmitsAlpn()
    {
        var server = RealityServer();
        server.Alpn = new List<string> { "h2", "http/1.1" };
        var cfg = new XrayConfigBuilder().MakeConfig(server, AntiCensorshipOptions.Off());
        var reality = ((ProxyOutbound(cfg)["streamSettings"] as JsonObject)!["realitySettings"]) as JsonObject;
        Assert.Equal(new[] { "h2", "http/1.1" }, (reality!["alpn"] as JsonArray)!.Select(n => n!.GetValue<string>()));

        // Empty list → key omitted entirely (an empty array is a config error).
        var bare = RealityServer();
        bare.Alpn = new List<string>();
        var cfg2 = new XrayConfigBuilder().MakeConfig(bare, AntiCensorshipOptions.Off());
        var reality2 = ((ProxyOutbound(cfg2)["streamSettings"] as JsonObject)!["realitySettings"]) as JsonObject;
        Assert.Null(reality2!["alpn"]);
    }

    /// <summary>Plain-TLS servers whose link carried no explicit SNI must fall
    /// back to the transport Host header as serverName — CDN-fronted TLS
    /// entries put the real origin name there, and an absent serverName breaks
    /// SNI routing.</summary>
    [Fact]
    public void TlsServerNameFallsBackToHost()
    {
        var server = RealityServer();
        server.Security = StreamSecurity.Tls;
        server.Network = NetworkType.Ws;
        server.Sni = null;
        server.Host = "origin.example.com";
        var cfg = new XrayConfigBuilder().MakeConfig(server, AntiCensorshipOptions.Off());
        var tls = ((ProxyOutbound(cfg)["streamSettings"] as JsonObject)!["tlsSettings"]) as JsonObject;
        Assert.Equal("origin.example.com", tls!["serverName"]!.GetValue<string>());
    }
}