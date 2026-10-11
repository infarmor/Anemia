using System.Net;
using System.Net.Sockets;
using System.Text.Json.Nodes;
using AnemiaCore;
using Xunit;

namespace AnemiaCoreTests;

public class PortFinderTests
{
    [Fact]
    public void FreePortInRange()
    {
        var p = PortFinder.FreePort();
        Assert.NotNull(p);
        Assert.InRange(p!.Value, 1, 65535);
    }

    [Fact]
    public void PickAvoidsExcluded()
    {
        var a = PortFinder.FreePort()!.Value;
        var picked = PortFinder.Pick(a, new HashSet<int> { a });
        Assert.NotEqual(a, picked);  // excluded preferred port must not be returned
    }

    /// <summary>CanConnect must see a live listener…</summary>
    [Fact]
    public void CanConnectDetectsListener()
    {
        using var sock = new TcpListener(IPAddress.Loopback, 0);
        sock.Start();
        var port = ((IPEndPoint)sock.LocalEndpoint).Port;
        Assert.True(PortFinder.CanConnect(port));
    }

    /// <summary>… and must not see one where there is none.</summary>
    [Fact]
    public void CanConnectRejectsClosedPort()
    {
        var port = PortFinder.FreePort()!.Value;
        Assert.False(PortFinder.CanConnect(port));
        Assert.False(PortFinder.CanConnect(0));
        Assert.False(PortFinder.CanConnect(70000));
    }
}

public class MaskingProfileTests
{
    [Fact]
    public void MaximumIsMoreAggressive()
    {
        var max = MaskingProfile.Maximum.Options();
        Assert.NotNull(max.Fragment);
        Assert.True(max.Noises.Count >= 2);
        Assert.Equal("randomized", max.Fingerprint);
    }

    [Fact]
    public void OffHasNoObfuscation()
    {
        var off = MaskingProfile.Off.Options();
        Assert.Null(off.Fragment);
        Assert.Empty(off.Noises);
    }

    [Fact]
    public void FingerprintFromOptionsUsedWhenServerHasNone()
    {
        // Server without an explicit fingerprint → builder uses anti.fingerprint.
        var server = new ProxyServer(name: "R", proto: ProxyProtocol.Vless, address: "e.com", port: 443,
            credential: "u", network: NetworkType.Tcp, security: StreamSecurity.Reality,
            realityPublicKey: "PBK");
        var anti = AntiCensorshipOptions.Balanced();
        anti.Fingerprint = "firefox";
        var cfg = new XrayConfigBuilder().MakeConfig(server, anti);
        var outbounds = (cfg["outbounds"] as JsonArray)!;
        var proxy = outbounds.OfType<JsonObject>().First(o => o["tag"]?.GetValue<string>() == "proxy");
        var reality = ((proxy["streamSettings"] as JsonObject)!)["realitySettings"] as JsonObject;
        Assert.Equal("firefox", reality!["fingerprint"]!.GetValue<string>());
    }

    [Fact]
    public void DoHDnsPresent()
    {
        var cfg = new XrayConfigBuilder().MakeConfig(
            new ProxyServer(name: "S", proto: ProxyProtocol.Ss, address: "s.com", port: 8388,
                credential: "p", method: "aes-256-gcm"), AntiCensorshipOptions.Off());
        var servers = ((cfg["dns"] as JsonObject)!["servers"] as JsonArray)!;
        Assert.Contains(servers, s => s!.GetValue<string>().StartsWith("https://"));
    }
}

public class RussiaStealthTests
{
    /// <summary>RU aliases must collapse onto real uTLS IDs — xray would reject
    /// "yandex"/"vk" as unknown ClientHello names.</summary>
    [Fact]
    public void FingerprintAliases()
    {
        Assert.Equal("chrome", AntiCensorshipOptions.UtlsFingerprint("yandex"));
        Assert.Equal("android", AntiCensorshipOptions.UtlsFingerprint("vk"));
        Assert.Equal("firefox", AntiCensorshipOptions.UtlsFingerprint("firefox"));
    }

    private static ProxyServer RealityServer() => new(
        name: "R", proto: ProxyProtocol.Vless, address: "e.com", port: 443,
        credential: "u", network: NetworkType.Tcp, security: StreamSecurity.Reality,
        realityPublicKey: "PBK");

    private static JsonObject RealitySettings(AntiCensorshipOptions anti)
    {
        var cfg = new XrayConfigBuilder().MakeConfig(RealityServer(), anti);
        var outbounds = (cfg["outbounds"] as JsonArray)!;
        var proxy = outbounds.OfType<JsonObject>().First(o => o["tag"]?.GetValue<string>() == "proxy");
        return ((proxy["streamSettings"] as JsonObject)!)["realitySettings"]!.AsObject();
    }

    /// <summary>No link SNI + RU preset → handshake borrows a host from the
    /// mimicry pool.</summary>
    [Fact]
    public void MimicrySniAppliedWhenLinkHasNone()
    {
        var anti = AntiCensorshipOptions.RussiaYandex();
        var reality = RealitySettings(anti);
        var sni = reality["serverName"]?.GetValue<string>();
        Assert.NotNull(sni);  // stealth SNI expected
        Assert.Contains(sni!, anti.Mimicry);  // SNI must come from the mimicry pool
        Assert.Equal("chrome", reality["fingerprint"]!.GetValue<string>());  // alias maps to a real uTLS ID
    }

    /// <summary>An explicit link SNI always wins over the mimicry pool.</summary>
    [Fact]
    public void ExplicitSniWinsOverMimicry()
    {
        var server = RealityServer();
        server.Sni = "explicit.example.com";
        var cfg = new XrayConfigBuilder().MakeConfig(server, AntiCensorshipOptions.RussiaVK());
        var outbounds = (cfg["outbounds"] as JsonArray)!;
        var proxy = outbounds.OfType<JsonObject>().First(o => o["tag"]?.GetValue<string>() == "proxy");
        var reality = ((proxy["streamSettings"] as JsonObject)!)["realitySettings"] as JsonObject;
        Assert.Equal("explicit.example.com", reality!["serverName"]!.GetValue<string>());
        Assert.Equal("android", reality["fingerprint"]!.GetValue<string>());
    }

    /// <summary>Without a mimicry pool (old presets) no SNI is invented.</summary>
    [Fact]
    public void BalancedInventsNoSni()
    {
        var reality = RealitySettings(AntiCensorshipOptions.Balanced());
        Assert.Null(reality["serverName"]);
    }

    private static JsonObject TlsSettings(ProxyServer server, AntiCensorshipOptions anti)
    {
        var cfg = new XrayConfigBuilder().MakeConfig(server, anti);
        var outbounds = (cfg["outbounds"] as JsonArray)!;
        var proxy = outbounds.OfType<JsonObject>().First(o => o["tag"]?.GetValue<string>() == "proxy");
        return ((proxy["streamSettings"] as JsonObject)!)["tlsSettings"]!.AsObject();
    }

    /// <summary>A validated TLS server (allowInsecure=false) with no link SNI
    /// must NOT borrow a mimicry host: a mismatched serverName would fail cert
    /// validation and break the handshake. xray defaults serverName to the
    /// address instead.</summary>
    [Fact]
    public void MimicryNotAppliedToValidatedTls()
    {
        var server = new ProxyServer(name: "T", proto: ProxyProtocol.Trojan, address: "real.example.com",
            port: 443, credential: "p", network: NetworkType.Tcp, security: StreamSecurity.Tls);
        var tls = TlsSettings(server, AntiCensorshipOptions.RussiaYandex());
        Assert.Null(tls["serverName"]);  // validated TLS must not borrow a stealth SNI
    }

    /// <summary>Xray-core 26.x removed allowInsecure — emitting true is a fatal
    /// config error. The builder must not emit the key at all, and since cert
    /// validation can no longer be skipped, an insecure-flagged server must not
    /// borrow a mimicry SNI either (it would fail validation).</summary>
    [Fact]
    public void AllowInsecureNotEmittedAndBorrowsNoSni()
    {
        var server = new ProxyServer(name: "T", proto: ProxyProtocol.Trojan, address: "real.example.com",
            port: 443, credential: "p", network: NetworkType.Tcp, security: StreamSecurity.Tls)
        { AllowInsecure = true };
        var tls = TlsSettings(server, AntiCensorshipOptions.RussiaYandex());
        Assert.Null(tls["allowInsecure"]);  // 26.x removed allowInsecure — never emit it
        Assert.Null(tls["serverName"]);     // certs are always validated now — no mimicry borrow
    }

    /// <summary>Persisted state from before `mimicry` existed must still decode
    /// — a strict decoder would fail and Persistence would wipe the store.</summary>
    [Fact]
    public void LegacyAntiOptionsDecode()
    {
        var legacy = "{\"fragment\": {\"packets\":\"tlshello\",\"length\":\"100-200\",\"interval\":\"10-20\"}," +
            "\"noises\": [], \"muxEnabled\": false, \"muxConcurrency\": 8," +
            "\"tcpFastOpen\": true, \"fingerprint\": \"chrome\"}";
        var decoded = AntiCensorshipOptions.FromJson(JsonNode.Parse(legacy));
        Assert.Empty(decoded.Mimicry);
        Assert.Equal("chrome", decoded.Fingerprint);
        Assert.Equal("100-200", decoded.Fragment!.Length);
    }

    /// <summary>Masking escalation walks lightest → heaviest and tops out at
    /// null, so the recovery ladder can't loop.</summary>
    [Fact]
    public void MaskingEscalationLadder()
    {
        Assert.Equal(MaskingProfile.Balanced, MaskingProfile.Off.Escalated());
        Assert.Equal(MaskingProfile.Maximum, MaskingProfile.Balanced.Escalated());
        Assert.Equal(MaskingProfile.RuYandex, MaskingProfile.Maximum.Escalated());
        Assert.Equal(MaskingProfile.RuVK, MaskingProfile.RuYandex.Escalated());
        Assert.Null(MaskingProfile.RuVK.Escalated());
        // Every profile reaches the top in a bounded number of steps.
        var p = (MaskingProfile?)MaskingProfile.Off;
        var steps = 0;
        while (p is { } current)
        {
            p = current.Escalated();
            steps++;
            Assert.True(steps < 10);
        }
    }

    /// <summary>Both RU presets pass xray's acceptance criteria: fragment +
    /// noise wired.</summary>
    [Fact]
    public void RussiaPresetsAreComplete()
    {
        foreach (var preset in new[] { AntiCensorshipOptions.RussiaYandex(), AntiCensorshipOptions.RussiaVK() })
        {
            Assert.NotNull(preset.Fragment);
            Assert.True(preset.Noises.Count >= 2);
            Assert.NotEmpty(preset.Mimicry);
            Assert.NotEqual(AntiCensorshipOptions.UtlsFingerprint(preset.Fingerprint),
                preset.Fingerprint);  // RU presets must use alias fingerprints
        }
    }
}

/// <summary>Regression tests for the two production connection failures found
/// in the field (2026-09): xray's "failed to apply socket options > invalid
/// argument" killing every dial, and the engine's own connection being
/// swallowed by a TUN (ours mid-race, or a third-party VPN on 198.18.0.1),
/// surfacing as "connection reset by peer" right after the FRAGMENT line.</summary>
public class SockoptSafetyTests
{
    private static ProxyServer Server() => new(
        name: "S", proto: ProxyProtocol.Vless, address: "e.com", port: 443,
        credential: "u", network: NetworkType.Tcp, security: StreamSecurity.None);

    private static List<JsonObject> Outbounds(XrayConfigBuilder builder, AntiCensorshipOptions anti) =>
        ((builder.MakeConfig(Server(), anti)["outbounds"] as JsonArray)!).OfType<JsonObject>().ToList();

    private static List<JsonObject> Sockopts(List<JsonObject> cfg) => cfg
        .Select(o => ((o["streamSettings"] as JsonObject)?["sockopt"]) as JsonObject)
        .OfType<JsonObject>()
        .ToList();

    /// <summary>Sockopts of the outbound that owns the physical socket: the
    /// fragment dialer when fragmenting (the proxy outbound there only carries
    /// dialerProxy), the proxy outbound otherwise.</summary>
    private static List<JsonObject> PhysicalSockopts(List<JsonObject> cfg) =>
        Sockopts(cfg).Where(s => s["dialerProxy"] is null).ToList();

    /// <summary>Xray-core#989: "tcpFastOpen": true makes xray's TFO setsockopt
    /// fail with EINVAL — fatal per dial, log spam "failed to apply socket
    /// options > invalid argument". The builder must never emit it, no matter
    /// which preset requests it (.off historically did!).</summary>
    [Fact]
    public void NoTcpFastOpenAnywhere()
    {
        foreach (var anti in new[]
                 {
                     AntiCensorshipOptions.Off(), AntiCensorshipOptions.Balanced(),
                     AntiCensorshipOptions.Maximum(), AntiCensorshipOptions.RussiaYandex(),
                     AntiCensorshipOptions.RussiaVK(),
                 })
        {
            Assert.True(anti.TcpFastOpen, "presets still carry the (now inert) flag");
            foreach (var s in Sockopts(Outbounds(new XrayConfigBuilder(), anti)))
                Assert.Null(s["tcpFastOpen"]);  // tcpFastOpen must not reach xray
        }
    }

    /// <summary>xray's keepalive code applies Idle/Interval swapped on some
    /// platforms — emitting only Idle leaves a zero write on TCP_KEEPALIVE.
    /// Both must be present (and non-zero) on the physical dialer.</summary>
    [Fact]
    public void KeepalivePairAlwaysPresent()
    {
        foreach (var anti in new[] { AntiCensorshipOptions.Off(), AntiCensorshipOptions.Balanced(), AntiCensorshipOptions.RussiaYandex() })
        {
            var sk = PhysicalSockopts(Outbounds(new XrayConfigBuilder(), anti));
            Assert.NotEmpty(sk);
            foreach (var s in sk)
            {
                Assert.True(s["tcpNoDelay"]!.GetValue<bool>(), "stream settings must disable Nagle");
                Assert.True((s["tcpKeepAliveIdle"]?.GetValue<int>() ?? 0) > 0);
                Assert.True((s["tcpKeepAliveInterval"]?.GetValue<int>() ?? 0) > 0);
            }
        }
    }

    /// <summary>The interface pin must land on the physical dialer: the
    /// fragment outbound when fragmenting, the proxy outbound otherwise.</summary>
    [Fact]
    public void InterfacePinOnPhysicalDialer()
    {
        var builder = new XrayConfigBuilder { DialerInterface = "Ethernet" };

        // No fragment → pin on the proxy outbound.
        var sk = Sockopts(Outbounds(builder, AntiCensorshipOptions.Off()));
        Assert.Contains(sk, s => s["interface"]?.GetValue<string>() == "Ethernet");

        // Fragment → pin on the fragment dialer (owner of the real socket);
        // the proxy outbound only carries dialerProxy, never the pin.
        var cfg = Outbounds(builder, AntiCensorshipOptions.Balanced());
        var fragment = cfg.First(o => o["tag"]?.GetValue<string>() == "fragment");
        var fSk = (fragment["streamSettings"] as JsonObject)!["sockopt"]!.AsObject();
        Assert.Equal("Ethernet", fSk["interface"]!.GetValue<string>());
        var proxy = cfg.First(o => o["tag"]?.GetValue<string>() == "proxy");
        var pSk = (proxy["streamSettings"] as JsonObject)!["sockopt"]!.AsObject();
        Assert.Null(pSk["interface"]);
        Assert.Equal("fragment", pSk["dialerProxy"]!.GetValue<string>());
    }

    /// <summary>No pin detected → no "interface" key at all (never guess).</summary>
    [Fact]
    public void NoPinWhenUndetected()
    {
        Assert.Null(new XrayConfigBuilder().DialerInterface);
        foreach (var s in Sockopts(Outbounds(new XrayConfigBuilder(), AntiCensorshipOptions.Balanced())))
            Assert.Null(s["interface"]);
    }
}