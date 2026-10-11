using System.Text;
using AnemiaCore;
using Xunit;

namespace AnemiaCoreTests;

/// <summary>
/// The two pieces of the sync golden this port can answer today: the bundle
/// recognizer, and the ids a subscription refresh carries over. Both are shared
/// fixtures — `sync/looks/cases.golden.txt` and `sync/carry/cases.golden.txt` —
/// written by the Swift code, so the C# answers are compared with the same rows
/// Kotlin reads.
/// </summary>
public class ParitySyncTests
{
    private const string Folder = "sync";

    [Fact]
    public void BundleRecognitionMatchesSwift()
    {
        var produced = new StringBuilder();
        var rows = 0;
        foreach (var raw in Parity.Split(Parity.Read(Folder, "looks", "cases.txt")))
        {
            if (raw.Length == 0) continue;
            rows++;
            var text = Unescape(raw);
            produced.Append(text).Append(Parity.Tab)
                .Append(SyncBundle.LooksLikeBundle(text) ? "да" : "нет").Append(Parity.LineFeed);
        }
        Parity.Compare(produced.ToString(), Parity.Read(Folder, "looks", "cases.golden.txt"),
                       "узнавание бандла", floor: 8);
        // Measured from the golden: 9 rows, of which 5 answer «да» — a recognizer
        // that answered yes to everything would still match five of nine, so the
        // row count is checked and the whole text is compared anyway.
        Assert.Equal(9, rows);
        Assert.Equal(5, Parity.Split(Parity.Read(Folder, "looks", "cases.golden.txt"))
            .Count(line => line.EndsWith("да", StringComparison.Ordinal)));
    }

    /// <summary>The rules the fixture is built to test, written out as cases of
    /// their own so a change in the predicate has to break something named.</summary>
    [Theory]
    [InlineData("anemia://sync/abc", true)]
    [InlineData("ANEMIA://SYNC/abc", true)]
    [InlineData("  anemia://sync/abc  ", true)]
    [InlineData("{\"device\":\"Mac\",\"exportedAt\":\"x\"}", true)]
    [InlineData("{ \"exportedAt\" : \"x\", \"device\" : \"m\" }", true)]
    [InlineData("{\"exportedAt\":\"x\"}", false)]                 // no device
    [InlineData("{\"device\":\"Mac\"}", false)]                  // no stamp
    [InlineData("vless://1b564d2f@example.com:443#A", false)]     // a share link
    [InlineData("", false)]
    [InlineData("   ", false)]
    // Measured: the quoted-key test is exact, so a longer key that merely ends
    // in the word does not count, and a key with a space inside does not either.
    [InlineData("{\"devicee\":\"a\",\"exportedAtt\":\"b\"}", false)]
    [InlineData("{\"xdevice\":\"a\",\"xexportedAt\":\"b\"}", false)]
    [InlineData("{\"my.device\":\"a\",\"my.exportedAt\":\"b\"}", false)]
    [InlineData("{\" device \":\"a\",\"exportedAt\":\"b\"}", false)]
    [InlineData("anemia://sync/", true)]
    [InlineData("anemia://syn/abc", false)]
    // Trailing text after a complete bundle still reads as one — the sheet is
    // deciding whether to offer a preview, not validating the JSON.
    [InlineData("{\"device\":\"a\",\"exportedAt\":\"b\"} trailing", true)]
    // Leading spaces of every kind are trimmed before the prefix test — measured:
    // NBSP and U+200B both count, so a plain string.Trim(), which does not know
    // U+200B, is not the same predicate.
    [InlineData("\u00A0anemia://sync/abc", true)]
    [InlineData("\u200Banemia://sync/abc", true)]
    [InlineData("\t{\"device\":\"a\",\"exportedAt\":\"b\"}", true)]
    public void RecognizerRules(string text, bool expected)
        => Assert.Equal(expected, SyncBundle.LooksLikeBundle(text));

    [Fact]
    public void CarriedIdsMatchSwift()
    {
        var produced = new StringBuilder();
        var rows = 0;
        foreach (var raw in Parity.Split(Parity.Read(Folder, "carry", "cases.txt")))
        {
            if (raw.Length == 0) continue;
            var parts = raw.Split('|');
            if (parts.Length < 2) continue;
            rows++;
            var old = ParseList(parts[0].Trim(' ', (char)0x09));
            var fresh = ParseList(parts[1].Trim(' ', (char)0x09));
            var carried = SubscriptionParser.CarryingIDs(old, fresh);
            produced.Append(raw).Append(Parity.Tab)
                .Append(string.Join(",", carried.Select(server => TrafficLedger.Uuid(server.Id))))
                .Append(Parity.LineFeed);
        }
        Parity.Compare(produced.ToString(), Parity.Read(Folder, "carry", "cases.golden.txt"),
                       "перенос id подписки", floor: 6);
        Assert.Equal(7, rows);
    }

    /// <summary>The carry rules worth naming separately, because each one is a
    /// different way an id could be lost: identity repeated in the old list, in
    /// the new one, an id that would collide, and an identity nobody had.</summary>
    [Fact]
    public void EveryOldIdIsHandedOutOnceAndNothingElseIsRenamed()
    {
        var old = ParseList("а=00000000-0000-0000-0000-000000000001,а=00000000-0000-0000-0000-000000000002");
        var fresh = ParseList("а=00000000-0000-0000-0000-000000000003,а=00000000-0000-0000-0000-000000000004," +
                              "а=00000000-0000-0000-0000-000000000005,б=00000000-0000-0000-0000-000000000006");
        var carried = SubscriptionParser.CarryingIDs(old, fresh);
        Assert.Equal(new[] { "00000000-0000-0000-0000-000000000001",
                             "00000000-0000-0000-0000-000000000002",
                             "00000000-0000-0000-0000-000000000005",
                             "00000000-0000-0000-0000-000000000006" },
            carried.Select(server => server.Id.ToString("D")).ToArray());
        // Every id still unique — a duplicate would break every id-keyed list.
        Assert.Equal(carried.Count, carried.Select(server => server.Id).Distinct().Count());
    }

    /// <summary>One fixture row per the emitter: `name=id[,name=id…]`, and a row
    /// whose id is not a UUID drops that server, the way Swift's compactMap does.</summary>
    private static List<ProxyServer> ParseList(string text)
    {
        var servers = new List<ProxyServer>();
        foreach (var pair in text.Split(','))
        {
            var bits = pair.Split('=');
            if (bits.Length != 2 || !Guid.TryParseExact(bits[1], "D", out var id)) continue;
            servers.Add(new ProxyServer { Name = bits[0], Proto = ProxyProtocol.Vless,
                Address = bits[0], Port = 443, Credential = bits[0], Id = id });
        }
        return servers;
    }

    /// <summary>The fixture writes a real newline in a case as «\n».</summary>
    private static string Unescape(string text)
    {
        var out_ = new StringBuilder();
        for (var i = 0; i < text.Length; i++)
        {
            if (text[i] != '\\' || i + 1 >= text.Length) { out_.Append(text[i]); continue; }
            var kind = text[++i];
            out_.Append(kind switch
            {
                'n' => "\n",
                'r' => "\r",
                't' => "\t",
                '\\' => "\\",
                'v' => "\u000B",
                'f' => "\u000C",
                _ => "\\" + kind,
            });
        }
        return out_.ToString();
    }
}
