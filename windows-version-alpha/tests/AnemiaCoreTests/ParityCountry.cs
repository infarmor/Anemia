using System.Text;
using AnemiaCore;
using Xunit;
using Xunit.Abstractions;

namespace AnemiaCoreTests;

/// <summary>
/// Country detection, replayed against the golden the Swift code writes
/// (`iOS/Activity/ActivityText.swift` is the source of both tables). The strict
/// part is what the app *decides*: the code found in a server name, its flag and
/// the name with the flag removed. The Russian spelling of a region comes from
/// the system CLDR, and Apple's, the JVM's and ICU's tables differ — those
/// differences are printed, exactly as the Kotlin port prints them, rather than
/// silently forgiven or silently failed.
/// </summary>
public class ParityCountryTests
{
    private const string Folder = "country";
    private readonly ITestOutputHelper _output;

    public ParityCountryTests(ITestOutputHelper output) => _output = output;

    [Fact]
    public void ServerNamesResolveTheSameCodeFlagAndPlace()
    {
        var inputs = Parity.Split(Parity.Read(Folder, "names.txt")).Where(line => line.Length > 0).ToList();
        var golden = Parity.Split(Parity.Read(Folder, "names.tsv")).Where(line => line.Length > 0).ToList();
        Assert.Equal(golden.Count, inputs.Count);
        var names = new List<string>();
        var produced = new StringBuilder();
        for (var i = 0; i < inputs.Count; i++)
        {
            var columns = golden[i].Split(Parity.Tab);
            Assert.Equal(4, columns.Length);
            var code = Country.Code(inputs[i]);
            var flag = code is null ? "" : Country.Flag(code);
            var place = Country.Place(inputs[i]);
            produced.Append(code ?? "").Append(Parity.Tab).Append(flag).Append(Parity.Tab)
                .Append(place).Append(Parity.LineFeed);
            Assert.Equal(columns[0], code ?? "");
            Assert.Equal(columns[1], flag);
            Assert.Equal(columns[2], place);
            if (columns[0].Length > 0)
            {
                var ours = Country.Name(columns[0]);
                if (ours != columns[3]) names.Add($"{columns[0]}: Apple «{columns[3]}» / ICU «{ours}»");
            }
        }
        // The decisions match; the spellings are a dictionary question.
        Assert.Equal(26, inputs.Count);
        if (names.Count > 0) _output.WriteLine("имена стран расходятся с CLDR Apple: " + string.Join("; ", names));
    }

    /// <summary>Not server names but «country codes as the app receives them»:
    /// the `loc=` field of a leak service, three letters, digits, Cyrillic, a
    /// flag passed back in. Here the contract is the *decision* — Apple found no
    /// name for «el» and returned the string it was given, so this port must do
    /// the same instead of showing «Греция» where the other screens show «el».</summary>
    [Fact]
    public void ArbitraryCodesAreJudgedTheSameWay()
    {
        var inputs = Parity.Split(Parity.Read(Folder, "codes.txt")).Where(line => line.Length > 0).ToList();
        var golden = Parity.Split(Parity.Read(Folder, "codes.tsv")).Where(line => line.Length > 0).ToList();
        Assert.Equal(golden.Count, inputs.Count);
        var names = new List<string>();
        foreach (var line in golden)
        {
            var columns = line.Split(Parity.Tab);
            Assert.True(columns.Length >= 3, "эталонной строке не хватает колонок: " + line);
            var code = columns[0];
            Assert.Equal(Country.Flag(code), columns[1]);
            var ours = Country.Name(code);
            if (columns[2] == code) Assert.Equal(code, ours);
            else if (ours != columns[2]) names.Add($"{code}: Apple «{columns[2]}» / ICU «{ours}»");
        }
        Assert.Equal(20, inputs.Count);
        if (names.Count > 0) _output.WriteLine("имена не покрываются таблицей алиасов ICU: " + string.Join("; ", names));
    }

    /// <summary>The two shapes that must not be confused with a country: a name
    /// that merely starts with two capitals, and a flag that is not a region.</summary>
    [Theory]
    [InlineData("IN01", null)]
    [InlineData("IT 05", null)]
    [InlineData("example.com", null)]
    [InlineData("185.199.108.153", null)]
    [InlineData("🇷🇹 Несуществующий код", "RT")]      // flags are taken as written
    [InlineData("UK 02", "GB")]
    [InlineData("[NL] Amsterdam", "NL")]
    [InlineData("San Francisco, CA", "US")]
    [InlineData("FR\u200B-02", "FR")]
    public void CodesAreFoundOrRefusedTheWaySwiftDoes(string name, string? expected)
        => Assert.Equal(expected, Country.Code(name));

    [Theory]
    [InlineData("RUS", "🇷🇺🇸")]
    [InlineData("A1", "🇦")]
    [InlineData("410", "")]
    [InlineData("🇫🇷", "")]
    [InlineData("F R", "🇫🇷")]
    [InlineData("XxX", "🇽🇽🇽")]
    [InlineData("АБ", "")]
    public void FlagsAreBuiltFromAsciiLettersOnly(string code, string expected)
        => Assert.Equal(expected, Country.Flag(code));

    [Theory]
    [InlineData("🇳🇱 Амстердам #2", "Амстердам #2")]
    [InlineData("Frankfurt · VLESS · Reality", "Frankfurt · VLESS · Reality")]  // inner dots stay
    [InlineData("Франция³", "Франция³")]                                        // ³ is a number, not a mark
    [InlineData("Amsterdam​", "Amsterdam")]
    [InlineData("🇫🇷 Франция 3", "Франция 3")]
    [InlineData("Тестовый сервер без подсказок", "Тестовый сервер без подсказок")]
    public void PlaceDropsFlagsAndWraps(string name, string expected)
        => Assert.Equal(expected, Country.Place(name));

    /// <summary>The word path: a city table first, then any CLDR region whose
    /// Russian or English name appears as a whole word — and never a substring of
    /// a longer word («Chisinau» is MD, not a China hit).</summary>
    /// <summary>Rows measured against the Swift code itself (a `swiftc` build of
    /// `iOS/Activity/ActivityText.swift`), each one a rule the shared fixture does
    /// not reach: one regional indicator is not a flag, a letter pair glued to a
    /// letter is not a code, the bracket before a code must be dropped before the
    /// pair is read, a city inside a longer word is not that city, and a region
    /// whose Russian name is three letters long is not matched at all.</summary>
    [Theory]
    [InlineData("🇫 Server", null)]
    [InlineData("IT01 server", null)]
    [InlineData("DEutschland", null)]
    [InlineData("[DE] Server 5", "DE")]
    [InlineData("Ослово", null)]
    [InlineData("Чад", null)]
    [InlineData("Перу", "PE")]
    [InlineData("Chad", "TD")]
    [InlineData("Куба", "CU")]
    public void ClueRulesTheFixtureAloneDoesNotPin(string name, string? expected)
        => Assert.Equal(expected, Country.Code(name));

    /// <summary>A flag alone leaves no place at all, and U+200B trims as
    /// whitespace (measured on Apple's set; it already sits inside the
    /// 0x2000…0x200B range the set declares). Inner zero-width spaces stay —
    /// trimming only works at the ends.</summary>
    [Fact]
    public void AFlagAloneLeavesNoPlaceAndAZeroWidthSpaceIsTrimmed()
    {
        Assert.Equal("", Country.Place("🇫🇷"));
        Assert.Equal("Server", Country.Place("\u200BServer"));
        Assert.Equal("A\u200BB", Country.Place("A\u200BB"));
    }

    [Theory]
    [InlineData("Нидерланды 2", "NL")]
    [InlineData("Сингапур", "SG")]
    [InlineData("dallas-01", "US")]
    [InlineData("Санкт-Петербург #3", "RU")]
    [InlineData("Chicago il", "US")]
    [InlineData("Турция антидпи", "TR")]
    [InlineData("Chisinau", "MD")]
    [InlineData("chinese server", null)]
    public void WordCluesMatchWholeWords(string name, string? expected)
        => Assert.Equal(expected, Country.Code(name));
}
