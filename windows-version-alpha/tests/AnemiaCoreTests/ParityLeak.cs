using System.Text;
using System.Text.Json;
using AnemiaCore;
using Xunit;

namespace AnemiaCoreTests;

/// <summary>
/// The leak answers, replayed through the golden the Kotlin port also runs: the
/// three service replies parsed, and the verdict `Findings` reaches about them.
/// Formatting lives here (it is harness shape, not product behaviour) — dumps,
/// the `ip|cc|country|city|isp` column parser, and the fixture's `\n` escapes.
/// </summary>
public class ParityLeakTests
{
    private const string Folder = "leak";

    [Fact]
    public void LeakAnswersMatchSwift()
    {
        var produced = new StringBuilder();
        var parses = 0;
        var verdicts = 0;
        var failures = 0;
        foreach (var raw in Parity.Split(Parity.Read(Folder, "answers.txt")))
        {
            var parts = raw.Split(Parity.Tab);
            var verb = parts.Length > 0 ? parts[0] : "";
            var body = parts.Length > 1 ? parts[1] : "";
            switch (verb)
            {
                case "ipsb":
                    parses++;
                    produced.Append("ipsb").Append(Parity.Tab).Append(Try(() => Dump(LeakCheck.ParseIpsb(body))));
                    break;
                case "trace":
                    parses++;
                    var text = Unescape(body);
                    produced.Append("trace").Append(Parity.Tab).Append(Try(() => Dump(LeakCheck.ParseTrace(text))));
                    break;
                case "bashws":
                    parses++;
                    produced.Append("bashws").Append(Parity.Tab)
                        .Append(Try(() => string.Join(";", LeakCheck.ParseBashWs(body).Select(Dump))));
                    break;
                case "findings":
                    if (parts.Length < 5) { produced.Append("error").Append(Parity.Tab)
                        .Append("findings: мало полей"); break; }
                    verdicts++;
                    var found = LeakCheck.Findings(InfoField(parts[1]), InfoField(parts[2]),
                                                   InfoField(parts[3]), DnsField(parts[4]));
                    produced.Append("findings").Append(Parity.Tab).Append(found.Count == 0 ? "чисто"
                        : string.Join(" ", found.Select(Describe)));
                    break;
                default:
                    produced.Append("error").Append(Parity.Tab).Append("unknown verb ").Append(verb);
                    break;
            }
            var row = produced.ToString();
            row = row[(row.LastIndexOf('\n') + 1)..];
            if (row.EndsWith("throw", StringComparison.Ordinal)) failures++;
            produced.Append(Parity.LineFeed);
        }

        Parity.Compare(produced.ToString(), Parity.Read(Folder, "answers.golden.txt"),
                       "проверка утечек", floor: 40);
        // Measured from the fixtures: 52 rows (12 ipsb, 16 trace, 13 bashws,
        // 11 verdicts), and 13 of them are answers this parser must refuse.
        Assert.Equal(52, parses + verdicts);
        Assert.Equal(11, verdicts);
        Assert.Equal(13, failures);
    }

    /// <summary>A wrong JSON type where a string belongs is a failed answer, not
    /// a nil: `{"ip":2030113009}` must throw, or the screen would print a
    /// plausible-looking address made out of somebody else's number.</summary>
    [Fact]
    public void WronglyTypedFieldsFailInsteadOfBecomingNil()
    {
        Assert.Throws<LeakCheck.LeakException>(() => LeakCheck.ParseIpsb("{\"ip\":2030113009}"));
        Assert.Throws<LeakCheck.LeakException>(() => LeakCheck.ParseIpsb("{\"ip\":null}"));
        Assert.Throws<LeakCheck.LeakException>(() => LeakCheck.ParseIpsb("{\"ip\":\"1.1.1.1\",\"city\":5}"));
        Assert.Throws<LeakCheck.LeakException>(() => LeakCheck.ParseBashWs("[{\"ip\":\"1.1.1.1\"}]"));
        Assert.Throws<LeakCheck.LeakException>(() => LeakCheck.ParseBashWs("{\"ip\":\"1.1.1.1\",\"type\":\"dns\"}"));
        // A JSON `null` in an optional is a real nil, and isp still falls back.
        var info = LeakCheck.ParseIpsb("{\"ip\":\"1.1.1.1\",\"isp\":null,\"asn_organization\":\"Hetzner\"}");
        Assert.Equal("Hetzner", info.Isp);
    }

    /// <summary>Cloudflare's line format: last value wins for a repeated key, a
    /// value may contain '=', and `ip` is only accepted when non-empty.</summary>
    [Fact]
    public void TraceLinesAreTakenTheWaySwiftTakesThem()
    {
        var info = LeakCheck.ParseTrace("fl=1\r\nip=1.1.1.1\r\nloc=nl\r\ngw=IPv4\r\nip=2.2.2.2\r\nx=a=b");
        Assert.Equal("2.2.2.2", info.Ip);
        Assert.Equal("NL", info.CountryCode);
        Assert.Throws<LeakCheck.LeakException>(() => LeakCheck.ParseTrace("ip=\r\nloc=NL"));
        Assert.Throws<LeakCheck.LeakException>(() => LeakCheck.ParseTrace("warp=off"));
        // "=value" has no key at all, so it must not become the ip.
        Assert.Throws<LeakCheck.LeakException>(() => LeakCheck.ParseTrace("=1.1.1.1"));
    }

    /// <summary>The verdict table on its own, with the cases the fixture's 11
    /// rows do not separate: no direct address at all, and the same country on
    /// both sides (which is not a leak claim about DNS or IPv6).</summary>
    [Fact]
    public void FindingsRefuseToGuessWhenThereIsNothingToCompare()
    {
        var direct = new LeakCheck.IpInfo("1.1.1.1", "NL");
        Assert.Empty(LeakCheck.Findings(null, null, null, Array.Empty<LeakCheck.DnsServer>()));
        // An exit abroad with a resolver at home IS a DNS leak: the country
        // comparison only refuses to guess when the exit is already home.
        var foreignExit = LeakCheck.Findings(new LeakCheck.IpInfo("2.2.2.2", "DE"), direct, null,
            new[] { new LeakCheck.DnsServer("9.9.9.9", "NL") });
        Assert.Equal("dnsLeak(ip=9.9.9.9 cc=NL country=- org=-)", Describe(foreignExit.Single()));
        Assert.Equal("tunnelBypassed",
            Describe(LeakCheck.Findings(new LeakCheck.IpInfo("1.1.1.1", "NL"), direct, null,
                Array.Empty<LeakCheck.DnsServer>()).Single()));
        // An exit in the home country says nothing about IPv6 or DNS — the
        // bypass line, if any, is the only thing reported.
        var homeExit = LeakCheck.Findings(new LeakCheck.IpInfo("3.3.3.3", "NL"), direct,
            new LeakCheck.IpInfo("::1", "NL"), new[] { new LeakCheck.DnsServer("9.9.9.9", "NL") });
        Assert.Empty(homeExit);
    }

    /// <summary>bash.ws lists every resolver that asked, and this screen shows
    /// only the DNS ones — once each, in the order reported.</summary>
    [Fact]
    public void BashWsKeepsDnsRowsOnceEachInReportedOrder()
    {
        var servers = LeakCheck.ParseBashWs(
            "[{\"ip\":\"9.9.9.9\",\"country\":\"nl\",\"type\":\"dns\"}," +
            "{\"ip\":\"1.1.1.1\",\"type\":\"dot\"}," +
            "{\"ip\":\"9.9.9.9\",\"country\":\"nl\",\"type\":\"dns\"}," +
            "{\"ip\":\"8.8.8.8\",\"asn\":\"AS15169\",\"type\":\"dns\"}]");
        Assert.Equal(new[] { "9.9.9.9", "8.8.8.8" }, servers.Select(server => server.Ip).ToArray());
        Assert.Equal("NL", servers[0].CountryCode);
        Assert.Equal("AS15169", servers[1].Org);
    }

    /// <summary>Country codes arrive in whatever case the service felt like, and
    /// the comparison is made upper-cased on both sides — measured against
    /// `LoaderTool leak`: a `nl` direct answer still flags a `NL` resolver, and
    /// an exit in `de` is treated as home for a `DE` provider (so no country
    /// verdict at all). The shared fixture happens to carry upper-case codes
    /// everywhere, which is why these two rows existed as tests of their own.</summary>
    [Theory]
    [InlineData("2.2.2.2|DE|-|-|-", "1.1.1.1|nl|-|-|-", "NONE", "9.9.9.9|NL|-|-",
                "dnsLeak(ip=9.9.9.9 cc=NL country=- org=-)")]
    [InlineData("2.2.2.2|de|-|-|-", "1.1.1.1|DE|-|-|-", "NONE", "9.9.9.9|DE|-|-", "чисто")]
    [InlineData("2.2.2.2|DE|-|-|-", "1.1.1.1|NL|-|-|-", "::1|nl|-|-|-", "-",
                "ipv6Leak(ip=::1 cc=nl country=- city=- isp=-)")]
    public void CountryCodesAreFoldedTheWaySwiftFoldsThem(
        string exit, string direct, string ipv6, string dns, string expected)
    {
        var found = LeakCheck.Findings(InfoField(exit), InfoField(direct), InfoField(ipv6),
                                       DnsField(dns));
        Assert.Equal(expected, found.Count == 0 ? "чисто"
            : string.Join(" ", found.Select(Describe)));
    }

    // MARK: - Harness shape (what `LoaderTool leak` prints)

    private static string Try(Func<string> body)
    {
        try { return body(); }
        catch (LeakCheck.LeakException) { return "throw"; }
        catch (JsonException) { return "throw"; }
        catch (InvalidOperationException) { return "throw"; }   // wrong JsonElement kind
        catch (NotSupportedException) { return "throw"; }
    }

    private static string Dump(LeakCheck.IpInfo? info) => info is null ? "NONE"
        : $"ip={info.Ip} cc={info.CountryCode ?? "-"} country={info.Country ?? "-"}" +
          $" city={info.City ?? "-"} isp={info.Isp ?? "-"}";

    private static string Dump(LeakCheck.DnsServer server) =>
        $"ip={server.Ip} cc={server.CountryCode ?? "-"} country={server.Country ?? "-"}" +
        $" org={server.Org ?? "-"}";

    private static string Describe(LeakCheck.Finding finding) => finding switch
    {
        LeakCheck.Finding.TunnelBypassed => "tunnelBypassed",
        LeakCheck.Finding.Ipv6Leak leak => "ipv6Leak(" + Dump(leak.Info) + ")",
        LeakCheck.Finding.DnsLeak dns => "dnsLeak(" + string.Join(";", dns.Servers.Select(Dump)) + ")",
        _ => "?",
    };

    /// <summary>One reading written as `ip|cc|country|city|isp`, with `-` for a
    /// nil and `NONE` for the whole reading missing. No case folding: the golden
    /// prints `cc=nl` when the fixture wrote `nl`, and the comparison inside
    /// `Findings` uppercases on its own.</summary>
    private static LeakCheck.IpInfo? InfoField(string text)
    {
        if (text == "NONE") return null;
        var parts = text.Split('|');
        if (parts.Length != 5) return null;
        return new LeakCheck.IpInfo(parts[0], Optional(parts[1]), Optional(parts[2]),
                                    Optional(parts[3]), Optional(parts[4]));
    }

    private static List<LeakCheck.DnsServer> DnsField(string text)
    {
        if (text == "-") return new List<LeakCheck.DnsServer>();
        var servers = new List<LeakCheck.DnsServer>();
        foreach (var item in text.Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            var parts = item.Split('|');
            if (parts.Length != 4) continue;
            servers.Add(new LeakCheck.DnsServer(parts[0], Optional(parts[1]),
                Optional(parts[2]), Optional(parts[3])));
        }
        return servers;
    }

    private static string? Optional(string value) => value == "-" ? null : value;

    /// <summary>`unescaped` in the emitter: the fixture writes `\n` inside a
    /// trace body so one case stays on one line.</summary>
    private static string Unescape(string text)
    {
        var out_ = new StringBuilder();
        var i = 0;
        while (i < text.Length)
        {
            if (text[i] != '\\') { out_.Append(text[i]); i++; continue; }
            i++;
            if (i >= text.Length) break;
            var kind = text[i];
            switch (kind)
            {
                case 'n': out_.Append('\n'); break;
                case 'r': out_.Append('\r'); break;
                case 't': out_.Append('\t'); break;
                case '\\': out_.Append('\\'); break;
                case 'v': out_.Append((char)0x0B); break;
                case 'f': out_.Append((char)0x0C); break;
                default: out_.Append('\\').Append(kind); break;
            }
            i++;
        }
        return out_.ToString();
    }
}
