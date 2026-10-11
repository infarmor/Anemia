using System.Text.Json.Nodes;
using AnemiaCore;
using Xunit;

namespace AnemiaCoreTests;

public class PersistenceTests : IDisposable
{
    private readonly string _path =
        Path.Combine(Path.GetTempPath(), $"loader-persist-tests-{Guid.NewGuid():N}.json");

    public void Dispose()
    {
        try
        {
            File.Delete(_path);
        }
        catch (FileNotFoundException) { }
        // The corrupt-store backups too — a stale .corrupt-*.bak would let a
        // later regression pass via prefix leftovers.
        var baseName = Path.GetFileNameWithoutExtension(_path);
        var dir = Path.GetDirectoryName(_path)!;
        foreach (var f in Directory.GetFiles(dir, $"{baseName}.json.corrupt-*.bak"))
        {
            try { File.Delete(f); } catch (IOException) { }
        }
    }

    [Fact]
    public void LoadMissingFileReturnsDefaults()
    {
        var state = new StatePersistence(_path).Load();
        Assert.Empty(state.Servers);
        Assert.Null(state.SelectedServerId);
    }

    [Fact]
    public void MalformedStateIsBackedUpAndReset()
    {
        var server = new ProxyServer(name: "kept", proto: ProxyProtocol.Vless, address: "a.example.com",
            port: 443, credential: "u");
        var good = new PersistedState { Servers = { server }, SelectedServerId = server.Id };
        new StatePersistence(_path).Save(good);

        // Corrupt the store in place with JSON the lenient decoder can't map
        // (`{}` alone decodes to defaults — a *type-mismatched* field fails).
        File.WriteAllText(_path, "{\"servers\": 42}");

        var reloaded = new StatePersistence(_path).Load();
        Assert.Empty(reloaded.Servers);  // corrupt state must fall back to defaults

        // …but the previous data is recoverable from the timestamped backup.
        var baseName = Path.GetFileNameWithoutExtension(_path);
        var dir = Path.GetDirectoryName(_path)!;
        var backup = Directory.GetFiles(dir, $"{baseName}.json.corrupt-*.bak").FirstOrDefault();
        Assert.NotNull(backup);  // a .corrupt-*.bak backup of the malformed store must exist
        Assert.Equal("{\"servers\": 42}", File.ReadAllText(backup!));
    }

    [Fact]
    public void RoundTripPreservesState()
    {
        var server = new ProxyServer(name: "n", proto: ProxyProtocol.Trojan, address: "h", port: 1, credential: "p");
        var original = new PersistedState { Servers = { server }, SelectedServerId = server.Id };
        new StatePersistence(_path).Save(original);
        var reloaded = new StatePersistence(_path).Load();
        Assert.Equal(original.SelectedServerId, reloaded.SelectedServerId);
        Assert.Equal(original.Servers.Count, reloaded.Servers.Count);
        var a = original.Servers[0];
        var b = reloaded.Servers[0];
        Assert.Equal(a.Id, b.Id);
        Assert.Equal(a.Name, b.Name);
        Assert.Equal(a.Proto, b.Proto);
        Assert.Equal(a.Address, b.Address);
        Assert.Equal(a.Port, b.Port);
        Assert.Equal(a.Credential, b.Credential);
    }

    /// <summary>The learned per-server masking map survives a save/load
    /// round-trip, and a store written before the field existed still decodes
    /// (empty map).</summary>
    [Fact]
    public void LearnedMaskingRoundTripAndLegacyDecode()
    {
        var server = new ProxyServer(name: "n", proto: ProxyProtocol.Vless, address: "h", port: 443, credential: "u");
        var original = new PersistedState
        {
            Servers = { server },
            LearnedMasking = { [server.IdentityKey] = MaskingProfile.RuYandex.ToString() },
        };
        new StatePersistence(_path).Save(original);
        var reloaded = new StatePersistence(_path).Load();
        Assert.Equal(MaskingProfile.RuYandex.ToString(), reloaded.LearnedMasking[server.IdentityKey]);

        // Legacy store without the key → empty map, no data loss.
        File.WriteAllText(_path, "{\"servers\":[],\"subscriptions\":[]}");
        Assert.Empty(new StatePersistence(_path).Load().LearnedMasking);
    }

    /// <summary>A store where one server entry is poisoned must keep every
    /// healthy sibling — the lenient element-wise decode used to be
    /// all-or-nothing and dropped the user's whole list.</summary>
    [Fact]
    public void LenientDecodeDropsOnlyPoisonedEntries()
    {
        var server = new ProxyServer(name: "n", proto: ProxyProtocol.Vless, address: "h", port: 443, credential: "u");
        var state = new PersistedState { Servers = { server } };
        new StatePersistence(_path).Save(state);

        // Inject one poisoned entry (bad proto enum) next to the healthy one.
        var raw = JsonNode.Parse(File.ReadAllBytes(_path))!.AsObject();
        var poisoned = JsonNode.Parse("{\"proto\":\"shadowsocks-old\",\"address\":\"x\",\"port\":1,\"credential\":\"c\"}")!;
        (raw["servers"] as JsonArray)!.Add(poisoned);
        File.WriteAllText(_path, raw!.ToJsonString());

        var reloaded = new StatePersistence(_path).Load();
        Assert.Single(reloaded.Servers);   // the healthy entry survived
        Assert.Equal(server.IdentityKey, reloaded.Servers[0].IdentityKey);
    }
}

public class ServerIdentityTests
{
    [Fact]
    public void IdentityKeyIgnoresCosmeticFields()
    {
        var a = new ProxyServer(name: "Alpha", proto: ProxyProtocol.Vless, address: "h", port: 443,
            credential: "u", network: NetworkType.Tcp, security: StreamSecurity.Tls, sni: "sni.example.com");
        var b = new ProxyServer(name: "Beta", proto: ProxyProtocol.Vless, address: "h", port: 443,
            credential: "u", network: NetworkType.Ws, security: StreamSecurity.None, path: "/ws");
        Assert.Equal(a.IdentityKey, b.IdentityKey);  // name/sni/transport must not change identity
    }

    [Fact]
    public void IdentityKeyDistinguishesCredentialsAndProtocols()
    {
        var @base = new ProxyServer(name: "A", proto: ProxyProtocol.Vless, address: "h", port: 443, credential: "u1");
        Assert.NotEqual(@base.IdentityKey,
            new ProxyServer(name: "A", proto: ProxyProtocol.Vless, address: "h", port: 443, credential: "u2").IdentityKey);
        Assert.NotEqual(@base.IdentityKey,
            new ProxyServer(name: "A", proto: ProxyProtocol.Trojan, address: "h", port: 443, credential: "u1").IdentityKey);
        Assert.NotEqual(@base.IdentityKey,
            new ProxyServer(name: "A", proto: ProxyProtocol.Vless, address: "h", port: 8443, credential: "u1").IdentityKey);
    }
}

public class DirectResolverTests
{
    /// <summary>Tests for the direct resolver's pure predicates: the fake-IP
    /// filter that keeps a concurrently running sing-box/clash client from
    /// poisoning the engine's server pin, and the IPv4 literal check that
    /// skips resolution.</summary>
    [Fact]
    public void FakeIpDetection()
    {
        // sing-box/clash fake-IP pool: the whole 198.18.0.0/15.
        Assert.True(DirectResolver.IsFakeIP("198.18.0.1"));
        Assert.True(DirectResolver.IsFakeIP("198.19.255.254"));
        // Real addresses — server, LAN, public — must pass.
        Assert.False(DirectResolver.IsFakeIP("13.143.140.2"));
        Assert.False(DirectResolver.IsFakeIP("192.168.1.24"));
        Assert.False(DirectResolver.IsFakeIP("172.28.0.1"));
        // Prefix bleeding: 198.190.x is public space, not the pool.
        Assert.False(DirectResolver.IsFakeIP("198.190.0.1"));
        Assert.False(DirectResolver.IsFakeIP("198.180.0.1"));
        // Hostnames that merely START with the pool's octets are real,
        // resolvable domains — the old bare prefix test treated them as
        // fake-IP answers and made ipv4() refuse to even look them up.
        Assert.False(DirectResolver.IsFakeIP("198.18.mirror.example.com"));
        Assert.False(DirectResolver.IsFakeIP("198.19.com"));
    }

    [Fact]
    public void IPv4LiteralCheck()
    {
        Assert.True(DirectResolver.IsIPv4("13.143.140.2"));
        Assert.True(DirectResolver.IsIPv4("198.18.0.1"));
        Assert.False(DirectResolver.IsIPv4("ee.ascl.dev"));
        Assert.False(DirectResolver.IsIPv4("1.2.3"));
        Assert.False(DirectResolver.IsIPv4("1.2.3.999"));
        Assert.False(DirectResolver.IsIPv4("::1"));
        // Empty octets: count one way, validate the other — these must NOT
        // pass as valid literals.
        Assert.False(DirectResolver.IsIPv4("1..2.3"));
        Assert.False(DirectResolver.IsIPv4("1.2.3."));
        Assert.False(DirectResolver.IsIPv4(".1.2.3.4"));
        // Signed octets: Int("+4") parses, so a "+1.2.3.4" from a malformed
        // link must not masquerade as a resolvable literal.
        Assert.False(DirectResolver.IsIPv4("+1.2.3.4"));
        Assert.False(DirectResolver.IsIPv4("1.2.3.+4"));
        // Out-of-range values in disguise.
        Assert.False(DirectResolver.IsIPv4("1.2.3.256"));
        Assert.False(DirectResolver.IsIPv4("300.2.3.4"));
    }
}

public class XrayStatsApiTests
{
    private static byte[] EncodeVarint(ulong v)
    {
        var outBytes = new List<byte>();
        while (true)
        {
            var b = (byte)(v & 0x7F);
            v >>= 7;
            if (v != 0) b |= 0x80;
            outBytes.Add(b);
            if (v == 0) break;
        }
        return outBytes.ToArray();
    }

    /// <summary>Encode a Stat submessage and wrap it in a QueryStatsResponse.</summary>
    private static byte[] EncodeResponse(IEnumerable<(string Name, long Value)> stats)
    {
        using var msg = new MemoryStream();
        foreach (var (name, value) in stats)
        {
            using var sub = new MemoryStream();
            sub.WriteByte(0x0A);  // field 1 (name), wire 2
            sub.Write(EncodeVarint((ulong)System.Text.Encoding.UTF8.GetByteCount(name)));
            sub.Write(System.Text.Encoding.UTF8.GetBytes(name));
            sub.WriteByte(0x10);  // field 2 (value), wire 0
            sub.Write(EncodeVarint((ulong)value));
            msg.WriteByte(0x0A);  // repeated field 1, wire 2
            msg.Write(EncodeVarint((ulong)sub.Length));
            msg.Write(sub.ToArray());
        }
        return msg.ToArray();
    }

    [Fact]
    public void ParsesProtobufStats()
    {
        var parsed = XrayStatsApi.ParseProtobuf(EncodeResponse(new[]
        {
            ("outbound>>>proxy>>>traffic>>>uplink", 88_597_084L),
            ("outbound>>>proxy>>>traffic>>>downlink", 938_439_941L),
        }));
        Assert.Equal(2, parsed.Count);
        Assert.Equal("outbound>>>proxy>>>traffic>>>uplink", parsed[0].Name);
        Assert.Equal(88_597_084, parsed[0].Value);
        Assert.Equal("outbound>>>proxy>>>traffic>>>downlink", parsed[1].Name);
        Assert.Equal(938_439_941, parsed[1].Value);
    }

    /// <summary>Counters not yet exercised carry no value field at all (xray
    /// emits name-only stats) — they must parse as 0, not abort the walk.</summary>
    [Fact]
    public void ParsesProtobufNameOnlyStat()
    {
        var parsed = XrayStatsApi.ParseProtobuf(EncodeResponse(new[] { ("outbound>>>block>>>traffic>>>uplink", 0L) }));
        Assert.Single(parsed);
        Assert.Equal("outbound>>>block>>>traffic>>>uplink", parsed[0].Name);
        Assert.Equal(0, parsed[0].Value);
    }

    [Fact]
    public void ParsesProtobufEmptyAndGarbage()
    {
        Assert.Empty(XrayStatsApi.ParseProtobuf(Array.Empty<byte>()));
        // Truncated varint / truncated submessage must not crash — garbage in,
        // whatever parses out.
        _ = XrayStatsApi.ParseProtobuf(new byte[] { 0x0A });
        _ = XrayStatsApi.ParseProtobuf(new byte[] { 0x0A, 0xFF, 0xFF });
    }
}