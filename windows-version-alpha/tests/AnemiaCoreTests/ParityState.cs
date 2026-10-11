using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using AnemiaCore;
using Xunit;

namespace AnemiaCoreTests;

/// <summary>
/// The saved state, replayed through the same golden Kotlin runs: every case
/// file is decoded with the app's own lenient reader and re-emitted, and the
/// document is compared with what Swift's <c>JSONEncoder</c> wrote for the same
/// input. This is the check that catches a field this port does not know about:
/// such a field simply disappears from the file, and the user's next save on the
/// Mac finds one of their rules gone.
/// </summary>
public class ParityStateTests
{
    private const string Folder = "state";

    /// <summary>Relaxed escaping, like Swift's encoder: «Панель» stays UTF-8 in
    /// the document rather than a run of <c>\u</c> escapes.</summary>
    private static readonly JsonSerializerOptions Write = new()
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        TypeInfoResolver = new System.Text.Json.Serialization.Metadata.DefaultJsonTypeInfoResolver(),
    };

    /// <summary>The same document, read two ways: as the live nodes the writer
    /// just built, and as the bytes those nodes serialize to. They used to
    /// disagree — a <c>JsonObject["port"] = 443</c> node answers
    /// <c>GetValue&lt;double&gt;</c> with an exception while a parsed 443 answers it
    /// with a number, so every <c>FromJson(ToJson())</c> in this process (the
    /// merge preview, the sync sheet, a state copied between stores) dropped the
    /// servers that the file on disk kept. A bug invisible to any test that only
    /// reads files.</summary>
    [Fact]
    public void TheSameDocumentReadAsNodesAndAsBytesKeepsTheSameServers()
    {
        var link = "vless://11111111-1111-1111-1111-111111111111@k.test:443" +
                   "?security=tls&type=kcp&seed=hunter2#k";
        var state = new PersistedState
        {
            Servers = new List<ProxyServer> { ShareLinkParser.Parse(link) },
            Subscriptions = new List<Subscription>
            {
                new() { Name = "панель", Url = "https://panel.example/sub" },
            },
        };
        var document = state.ToJson();

        var live = PersistedState.FromJson(document);
        var bytes = PersistedState.FromJson(JsonNode.Parse(document.ToJsonString(Write)));

        Assert.NotNull(live);
        Assert.NotNull(bytes);
        Assert.Single(live!.Servers);
        Assert.Equal(bytes!.Servers.Select(s => s.Id).ToList(), live.Servers.Select(s => s.Id).ToList());
        Assert.Equal(bytes.Subscriptions.Select(s => s.Id).ToList(), live.Subscriptions.Select(s => s.Id).ToList());
        Assert.Equal("hunter2", live.Servers[0].UserData!["kcpSeed"]);
    }

    /// <summary>A saved id is Foundation's dashed UUID and nothing else: the
    /// shared fixture hands over five shapes and Swift keeps one.</summary>
    [Theory]
    [InlineData("1B564D2F-5117-4C8C-9B0D-9E2F8A3F1C22", true)]
    [InlineData("1b564d2f-5117-4c8c-9b0d-9e2f8a3f1c22", true)]
    [InlineData("1b564d2f51174c8c9b0d9e2f8a3f1c22", false)]
    [InlineData("0-0-0-0-0", false)]
    [InlineData(" 1B564D2F-5117-4C8C-9B0D-9E2F8A3F1C22", false)]
    [InlineData("1B564D2F-5117-4C8C-9B0D-9E2F8A3F1C2Z", false)]
    [InlineData("{1B564D2F-5117-4C8C-9B0D-9E2F8A3F1C22}", false)]
    public void OnlyTheDashedUuidShapeIsASavedId(string text, bool valid)
        => Assert.Equal(valid, PersistedState.IsUuid(text));

    /// <summary>The whole state golden, row by row: every case file decoded by
    /// the app's own reader and re-encoded, compared with what Swift's encoder
    /// wrote for the same bytes. This is the check that notices a field this
    /// port does not know — such a field vanishes from the file, and the user's
    /// next save on another device finds a server, a subscription stamp or a
    /// bypass rule gone.
    ///
    /// It carries its own <c>[Fact]</c> on purpose: without one xunit silently
    /// skips the method, the suite still prints 362 green, and ten of the
    /// mutants that make the decoder lenient again survive. A test nobody calls
    /// is worse than no test, because it makes the number look like coverage.</summary>
    [Fact]
    public void DecodedStateMatchesSwift()
    {
        var directory = Path.Combine(Parity.Fixtures, Folder, "cases");
        var files = Directory.GetFiles(directory, "*.json").OrderBy(name => name, StringComparer.Ordinal).ToList();
        Assert.NotEmpty(files);

        var produced = new StringBuilder();
        var decoded = 0;
        foreach (var file in files)
        {
            var name = Path.GetFileNameWithoutExtension(file);
            var text = File.ReadAllText(file, Encoding.UTF8);
            produced.Append("=== ").Append(name).Append(Parity.LineFeed);
            produced.Append("input").Append(Parity.Tab).Append(CanonicalOr("unparseable", text)).Append(Parity.LineFeed);
            var state = PersistedState.FromJson(Parse(text));
            if (state is null)
            {
                produced.Append("decode").Append(Parity.Tab).Append("throw").Append(Parity.LineFeed);
                continue;
            }
            decoded++;
            produced.Append("decode").Append(Parity.Tab)
                .Append(Parity.Canonical(state.ToJson().ToJsonString(Write))).Append(Parity.LineFeed);
        }

        // Only `=== name`, `input` and `decode` rows belong here: `loaded`,
        // `backup` and `backups` are the file layer's own behaviour.
        var rows = Parity.Split(Parity.Read(Folder, "cases.golden.txt"));
        var golden = RowsNamed(rows, "=== ", "input" + Parity.Tab, "decode" + Parity.Tab);
        Parity.Compare(produced.ToString(), golden, "сохранённое состояние", floor: 15);
        // Two of the twenty files are not a state object at all (`broken-json`,
        // `not-an-object`) and Swift answers them with `throw`, so the number of
        // decoders is taken from the golden rather than from the file count.
        Assert.Equal(20, files.Count);
        Assert.Equal(files.Count - rows.Count(line => line == "decode" + Parity.Tab + "throw"), decoded);
    }

    /// <summary>A base server in the shape the fixture files use: every field
    /// Swift's element decode demands, in the case it demands. `field` names the
    /// key the probe overrides; for `awg` the base switches to the AWG transport
    /// because a `vless` element with an `awg` block is a different question.</summary>
    private static string Document(string field, string value)
    {
        var awg = field == "awg";
        var server = "{\"id\":\"1B564D2F-5117-4C8C-9B0D-9E2F8A3F1C22\",\"name\":\"s\"," +
            $"\"proto\":\"{(awg ? "awg" : "vless")}\",\"address\":\"example.com\"," +
            $"\"port\":{(awg ? 51820 : 443)}," +
            $"\"credential\":\"{(awg ? "c" : "11111111-1111-1111-1111-111111111111")}\"," +
            "\"alterId\":0," +
            $"\"network\":\"{(awg ? "tcp" : "ws")}\",\"security\":\"{(awg ? "none" : "tls")}\"," +
            "\"alpn\":[],\"allowInsecure\":false,\"path\":\"/t\",\"host\":\"example.com\"}";
        if (awg) server = server[..^1] + ",\"awg\":" + value + "}";
        else server = System.Text.RegularExpressions.Regex.Replace(server,
            $"\"{field}\":[^,]*", $"\"{field}\":{value}");
        return "{\"servers\":[" + server + "]}";
    }

    /// <summary>Shapes the shared fixture does not contain, measured against the
    /// real Swift decoder rather than guessed: `LoaderTool state` on each probe,
    /// then `LoaderTool state-read` on the document this port wrote back.
    ///
    /// Two rules came out of it, and mutation testing proved the 20 golden cases
    /// exercise neither — so both survived ten otherwise-green mutants. An enum
    /// written in the wrong *case* loses the whole server (Swift decodes by raw
    /// value, it does not fold). An `awg` block dies on a field of the wrong
    /// *type* but survives a field that is merely absent, and the absent field is
    /// then missing from the file rather than defaulted. Getting that second one
    /// backwards silently deletes or invents a user's WireGuard keys.</summary>
    [Theory]
    [InlineData("proto", "\"vless\"", 1)]
    [InlineData("proto", "\"VLESS\"", 0)]
    [InlineData("proto", "\"Trojan\"", 0)]
    [InlineData("network", "\"ws\"", 1)]
    [InlineData("network", "\"Kcp\"", 0)]
    [InlineData("network", "\"quic2\"", 0)]
    [InlineData("security", "\"tls\"", 1)]
    [InlineData("security", "\"TLS\"", 0)]
    [InlineData("awg", "5", 0)]
    [InlineData("awg", """{"interfacePrivateKey":"AA==","junkPackets":0}""", 1)]
    [InlineData("awg", """{"junkPackets":"x"}""", 0)]
    [InlineData("awg", """{"interfacePrivateKey":"AA==","peerPublicKey":"BB==","allowedIPs":["0.0.0.0/0"],""" +
                       """ "dns":["1.1.1.1"],"junkPackets":0,"contentPaddingAddition":"42","specialHandshakes":[]}""", 1)]
    public void SwiftDropsTheElementNotTheField(string field, string value, int kept)
    {
        var state = PersistedState.FromJson(JsonNode.Parse(Document(field, value)));
        Assert.NotNull(state);
        Assert.Equal(kept, state!.Servers.Count);
    }

    /// <summary>What Swift writes back for the probe whose `awg` carries only two
    /// of its fields: exactly those two. A default invented here would be a key
    /// the other three ports never saved, and a device that reads it would take
    /// this port's guess for the user's config.</summary>
    [Fact]
    public void AbsentAwgFieldsStayAbsent()
    {
        var state = PersistedState.FromJson(JsonNode.Parse(Document("awg",
            """{"interfacePrivateKey":"AA==","junkPackets":0}""")));
        Assert.NotNull(state);
        var server = Assert.Single(state!.Servers);
        Assert.NotNull(server.Awg);
        Assert.Equal(0, server.Awg!.JunkPackets);
        Assert.Empty(server.Awg.SpecialHandshakes);
        // The document this port writes back holds the two keys Swift's answer
        // holds — the unknown `interfacePrivateKey` is not stored, and no key is
        // invented for the ones that were absent.
        var written = state.ToJson()["servers"]!.AsArray()[0]!["awg"]!;
        Assert.Equal("""{"junkPackets":0,"specialHandshakes":[]}""",
            Parity.Canonical(written.ToJsonString()));
    }

    /// <summary>Wrongly typed fields fall back per field instead of discarding
    /// the store — the shape Swift's `anti-lenient` case exists to pin.</summary>
    [Fact]
    public void UnknownAndHostileFieldsFallBackInsteadOfDiscarding()
    {
        var state = PersistedState.FromJson(JsonNode.Parse(
            """{"anti":{"fingerprint":7},"maskingProfile":"nonsense","splitTunnel":{"enabled":"yes","entries":[1,"ok",2]},"servers":[]}"""));
        Assert.NotNull(state);
        Assert.Equal(MaskingProfile.Balanced, state!.MaskingProfile);
        Assert.True(state.SplitTunnel.Enabled);            // "yes" is not a bool
        // One number in the array costs the whole array — Swift decodes
        // `[String]`, it does not filter it. Keeping "ok" would have been the
        // permissive reading, and the two disagree about what the user saved.
        Assert.Empty(state.SplitTunnel.Entries);
        Assert.True(state.MlRankingEnabled);               // absent keeps the default
    }

    /// <summary>What a Windows save owes the other three ports: a rule the user
    /// typed as «# комментарий» or as an empty line survives verbatim, because
    /// the file stores lines, not this port's opinion about them.</summary>
    [Fact]
    public void BypassLinesAreStoredAsTyped()
    {
        var rules = SplitTunnelRules.FromJson(JsonNode.Parse(
            """{"enabled":false,"entries":["# комментарий","не valid !!","","  ","*.foo.com"]}"""));
        Assert.False(rules.Enabled);
        Assert.Equal(new[] { "# комментарий", "не valid !!", "", "  ", "*.foo.com" }, rules.Entries.ToArray());
        Assert.Empty(rules.ActiveEntries);                 // disabled: nothing routes
        rules.Enabled = true;
        // The `*.` decoration is stripped by the parser, same as in the bypass
        // golden — the route is the domain, which already covers subdomains.
        Assert.Equal(new[] { "foo.com" },
            rules.ActiveEntries.Select(entry => entry.Value).ToArray());
    }

    /// <summary>A truncated file is part of the fixture: Swift prints
    /// <c>unparseable</c> rather than failing the run, so the comparison has to
    /// say the same word for the same bytes.</summary>
    private static string CanonicalOr(string fallback, string json)
    {
        try { return Parity.Canonical(json); }
        catch (JsonException) { return fallback; }
    }

    private static JsonNode? Parse(string json)
    {
        try { return JsonNode.Parse(json); }
        catch (JsonException) { return null; }
    }

    /// <summary>Golden rows this check owns, in file order.</summary>
    private static string RowsNamed(string[] golden, params string[] prefixes) =>
        string.Join(Parity.LineFeed.ToString(), golden
            .Where(line => prefixes.Any(prefix => line.StartsWith(prefix, StringComparison.Ordinal))))
        + Parity.LineFeed;
}
