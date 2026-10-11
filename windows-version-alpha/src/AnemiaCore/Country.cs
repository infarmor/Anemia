using System.Globalization;
using System.Text;

namespace AnemiaCore;

/// <summary>
/// Which country an exit is in, from the name a panel gave it, and how to say
/// that back to the user: the flag, the Russian name, and the name with the flag
/// removed. Port of <c>Country</c> in <c>iOS/Activity/ActivityText.swift</c> —
/// the same helper the Dynamic Island, the server groups and the map use.
///
/// Country *names* come from the system CLDR, and Apple's, the JVM's and ICU's
/// tables and spellings differ: the shared harness therefore compares names as a
/// printed difference list, while the decision «found a region / return the code»
/// and the flag and place strings are compared exactly. See
/// <c>ParityCountryTests</c>.
/// </summary>
public static class Country
{
    private static readonly CultureInfo Russian = new("ru-RU");

    /// <summary>Codes panels actually use. "IN…" or "IT …" must not read as a
    /// country standing alone at the start of a name.</summary>
    internal static readonly HashSet<string> PanelCodes = new(StringComparer.Ordinal)
    {
        "AE", "AM", "AR", "AT", "AU", "AZ", "BE", "BG", "BR", "BY", "CA", "CH", "CL", "CY", "CZ",
        "DE", "DK", "EE", "ES", "FI", "FR", "GB", "GE", "GR", "HK", "HR", "HU", "ID", "IE", "IL",
        "IS", "JP", "KG", "KR", "KZ", "LT", "LU", "LV", "MD", "MX", "MY", "NL", "NO", "NZ", "PL",
        "PT", "RO", "RS", "RU", "SE", "SG", "SI", "SK", "TH", "TR", "TW", "UA", "US", "UZ", "VN", "ZA",
    };

    /// <summary>Where VPN servers usually stand, in the spellings panels use.
    /// Order matters: the first whole-word match wins.</summary>
    internal static readonly (string City, string Code)[] Cities =
    {
        ("амстердам", "NL"), ("amsterdam", "NL"), ("роттердам", "NL"), ("rotterdam", "NL"),
        ("франкфурт", "DE"), ("frankfurt", "DE"), ("берлин", "DE"), ("berlin", "DE"),
        ("мюнхен", "DE"), ("munich", "DE"), ("нюрнберг", "DE"), ("nuremberg", "DE"),
        ("фалькенштайн", "DE"), ("falkenstein", "DE"), ("дюссельдорф", "DE"), ("dusseldorf", "DE"),
        ("париж", "FR"), ("paris", "FR"), ("марсель", "FR"), ("marseille", "FR"),
        ("лондон", "GB"), ("london", "GB"), ("манчестер", "GB"), ("manchester", "GB"),
        ("хельсинки", "FI"), ("helsinki", "FI"), ("стокгольм", "SE"), ("stockholm", "SE"),
        ("осло", "NO"), ("oslo", "NO"), ("копенгаген", "DK"), ("copenhagen", "DK"),
        ("варшава", "PL"), ("warsaw", "PL"), ("рига", "LV"), ("riga", "LV"),
        ("таллин", "EE"), ("таллинн", "EE"), ("tallinn", "EE"), ("вильнюс", "LT"), ("vilnius", "LT"),
        ("прага", "CZ"), ("prague", "CZ"), ("вена", "AT"), ("vienna", "AT"),
        ("цюрих", "CH"), ("zurich", "CH"), ("женева", "CH"), ("geneva", "CH"),
        ("милан", "IT"), ("milan", "IT"), ("мадрид", "ES"), ("madrid", "ES"),
        ("барселона", "ES"), ("barcelona", "ES"), ("лиссабон", "PT"), ("lisbon", "PT"),
        ("дублин", "IE"), ("dublin", "IE"), ("брюссель", "BE"), ("brussels", "BE"),
        ("люксембург", "LU"), ("будапешт", "HU"), ("budapest", "HU"), ("бухарест", "RO"),
        ("bucharest", "RO"), ("софия", "BG"), ("sofia", "BG"), ("белград", "RS"), ("belgrade", "RS"),
        ("афины", "GR"), ("athens", "GR"), ("стамбул", "TR"), ("istanbul", "TR"),
        ("тбилиси", "GE"), ("tbilisi", "GE"), ("ереван", "AM"), ("yerevan", "AM"),
        ("баку", "AZ"), ("baku", "AZ"), ("алматы", "KZ"), ("almaty", "KZ"), ("астана", "KZ"),
        ("astana", "KZ"), ("ташкент", "UZ"), ("tashkent", "UZ"), ("бишкек", "KG"), ("bishkek", "KG"),
        ("кишинёв", "MD"), ("кишинев", "MD"), ("chisinau", "MD"), ("москва", "RU"), ("moscow", "RU"),
        ("санкт петербург", "RU"), ("петербург", "RU"), ("saint petersburg", "RU"),
        ("токио", "JP"), ("tokyo", "JP"), ("осака", "JP"), ("osaka", "JP"), ("сеул", "KR"), ("seoul", "KR"),
        ("сингапур", "SG"), ("гонконг", "HK"), ("hong kong", "HK"), ("тайбэй", "TW"), ("taipei", "TW"),
        ("дубай", "AE"), ("dubai", "AE"), ("тель авив", "IL"), ("tel aviv", "IL"),
        ("нью йорк", "US"), ("new york", "US"), ("лос анджелес", "US"), ("los angeles", "US"),
        ("майами", "US"), ("miami", "US"), ("чикаго", "US"), ("chicago", "US"), ("даллас", "US"),
        ("dallas", "US"), ("сиэтл", "US"), ("seattle", "US"), ("сан франциско", "US"),
        ("san francisco", "US"), ("сан хосе", "US"), ("san jose", "US"), ("ашберн", "US"), ("ashburn", "US"),
        ("торонто", "CA"), ("toronto", "CA"), ("монреаль", "CA"), ("montreal", "CA"),
        ("ванкувер", "CA"), ("vancouver", "CA"), ("сидней", "AU"), ("sydney", "AU"),
        ("мельбурн", "AU"), ("melbourne", "AU"), ("сан паулу", "BR"), ("sao paulo", "BR"),
        ("йоханнесбург", "ZA"), ("johannesburg", "ZA"),
    };

    /// <summary>The ISO region code of the exit, or null when the name gives no
    /// clue: a flag first, then a standing-two-letter code, then a city or
    /// country named in words.</summary>
    public static string? Code(string serverName) =>
        FlagCode(serverName) ?? LeadingCode(serverName) ?? NamedCode(serverName);

    /// <summary>"FR" → 🇫🇷. Like Swift: every ASCII letter becomes a regional
    /// indicator and everything else simply falls out, so "RUS" gives three
    /// flags and "A1" one, not an empty string.</summary>
    public static string Flag(string code)
    {
        var text = new StringBuilder();
        // Swift upper-cases first and only ASCII A…Z survive the range test, so a
        // Cyrillic «АБ» gives nothing while "RUS" gives three flags and "A1" one.
        foreach (var rune in code.ToUpperInvariant().EnumerateRunes())
            if (rune.Value is >= 'A' and <= 'Z')
                text.Append(char.ConvertFromUtf32(0x1F1E6 - 'A' + rune.Value));
        return text.ToString();
    }

    /// <summary>"FR" → «Франция» in this system's Russian CLDR, or the given
    /// string when nothing resolves — because the argument can be the raw
    /// <c>loc=</c> field of a leak service's answer, and «1» must stay «1».
    /// The case of the argument is preserved on the way out: Swift returns the
    /// string it was given, not an upper-cased version of it.</summary>
    public static string Name(string code)
    {
        if (code.Length is < 2 or > 3) return code;
        try
        {
            var region = new RegionInfo("ru-" + code.ToUpperInvariant());
            // A culture .NET could not map to a region reports the region name as
            // the code itself; that is "not found", same as Swift's nil.
            var display = region.DisplayName;
            return display == code.ToUpperInvariant() || display.Length == 0 ? code : display;
        }
        catch (Exception e) when (e is ArgumentException or CultureNotFoundException)
        {
            return code;
        }
    }

    /// <summary>The server's name without flags ("🇳🇱 Амстердам #2" →
    /// "Амстердам #2"), and with the wrapping punctuation and spaces trimmed —
    /// walked by code points, because a flag is a surrogate pair and filtering by
    /// UTF-16 unit would keep both halves of it.</summary>
    public static string Place(string serverName)
    {
        var text = new StringBuilder();
        foreach (var rune in serverName.EnumerateRunes())
            if (rune.Value is < 0x1F1E6 or > 0x1F1FF) text.Append(char.ConvertFromUtf32(rune.Value));
        return TrimSwift(text.ToString());
    }

    /// <summary>`trimmingCharacters(in: .whitespacesAndNewlines.union(
    /// .punctuationCharacters))`.</summary>
    private static string TrimSwift(string text)
    {
        var start = 0;
        var end = text.Length;
        while (start < end && IsTrimChar(text[start])) start++;
        while (end > start && IsTrimChar(text[end - 1])) end--;
        return text[start..end];
    }

    private static bool IsTrimChar(char c) => Foundation.IsFoundationSpaceOrNewline(c) || IsPunctuation(c);

    /// <summary>Unicode general category P* — what Foundation calls
    /// <c>.punctuationCharacters</c>. Not <c>char.IsPunctuation</c> alone, which
    /// agrees except that it also answers for the symbols Swift leaves.</summary>
    internal static bool IsPunctuation(char c) =>
        CharUnicodeInfo.GetUnicodeCategory(c) switch
        {
            UnicodeCategory.DashPunctuation or UnicodeCategory.OpenPunctuation or
            UnicodeCategory.ClosePunctuation or UnicodeCategory.ConnectorPunctuation or
            UnicodeCategory.OtherPunctuation or UnicodeCategory.InitialQuotePunctuation or
            UnicodeCategory.FinalQuotePunctuation => true,
            _ => false,
        };

    /// <summary>Foundation's <c>Character.isNumber</c> is Nd + Nl + No, so «³» is
    /// a digit to it — which is why "Франция³" keeps its superscript in
    /// <see cref="Place"/> and "³" is not a separator in <see cref="Words"/>.</summary>
    internal static bool IsNumberLike(int value) =>
        CharUnicodeInfo.GetUnicodeCategory(char.ConvertFromUtf32(value), 0) switch
        {
            UnicodeCategory.DecimalDigitNumber or UnicodeCategory.LetterNumber or
            UnicodeCategory.OtherNumber => true,
            _ => false,
        };

    // MARK: - Clues

    /// <summary>A flag emoji: the first two regional-indicator letters.</summary>
    internal static string? FlagCode(string name)
    {
        var flags = new List<int>();
        foreach (var rune in name.EnumerateRunes())
            if (rune.Value is >= 0x1F1E6 and <= 0x1F1FF)
            {
                flags.Add(rune.Value);
                if (flags.Count == 2) break;
            }
        if (flags.Count < 2) return null;
        return new string(flags.Select(value => (char)(value - 0x1F1E6 + 'A')).ToArray());
    }

    /// <summary>A capitalized code standing alone at the start: "DE-01",
    /// "[NL] …", "US | 3". Only codes panels use, so a name that merely starts
    /// with two capitals ("IN…", "IT …") isn't taken for a country.</summary>
    internal static string? LeadingCode(string name)
    {
        var text = name.TrimStart(' ', '(', '[', '【', '{');
        var clusters = Graphemes(text);
        if (clusters.Count < 2) return null;
        var letters = clusters.Take(2).ToList();
        // Swift looks at two `Character`s — grapheme clusters, not code points:
        // "DE◌́-01" (E with a combining acute) is one cluster «É», not A…Z.
        foreach (var cluster in letters)
            if (cluster.Length != 1 || cluster[0] is < 'A' or > 'Z') return null;
        var code = new string(letters.Select(cluster => cluster[0]).ToArray());
        if (clusters.Count > 2)
        {
            var next = clusters[2][0];
            if (char.IsLetter(next)) return null;
        }
        if (code == "UK") code = "GB";
        return PanelCodes.Contains(code) ? code : null;
    }

    private static List<string> Graphemes(string text)
    {
        var out_ = new List<string>();
        var iterator = StringInfo.GetTextElementEnumerator(text);
        while (iterator.MoveNext()) out_.Add(iterator.GetTextElement());
        return out_;
    }

    /// <summary>A city or a country named in words, matched as whole words.</summary>
    internal static string? NamedCode(string name)
    {
        var text = " " + Words(name) + " ";
        foreach (var (city, code) in Cities)
            if (text.Contains(" " + city + " ", StringComparison.Ordinal)) return code;
        foreach (var (code, country) in NameTable.Value)
            if (text.Contains(" " + country + " ", StringComparison.Ordinal)) return code;
        return null;
    }

    /// <summary>The region names of the two languages this port consults,
    /// normalized once for the process instead of per server name.
    ///
    /// <see cref="NamedCode"/> used to build a <c>RegionInfo</c> for every region
    /// and every language on every call — measured at 70 мкс per name on this
    /// machine, which is 35 мс to repaint a list of 500 servers and a freeze
    /// nobody sees on a Mac, because there the same names come from a table that
    /// is already there. The entries are in the order the old nested loop walked
    /// (region, then Russian, then English) and carry the same length filter, so
    /// which name wins a tie cannot shift with the cache.</summary>
    private static readonly Lazy<(string Code, string Words)[]> NameTable = new(BuildNameTable);

    private static (string Code, string Words)[] BuildNameTable()
    {
        var languages = new[] { Russian, new CultureInfo("en-US") };
        var table = new List<(string, string)>();
        foreach (var region in IsoRegions)
        {
            if (region.Length != 2 || !region.All(char.IsLetter)) continue;
            foreach (var culture in languages)
            {
                if (RegionName(region, culture) is not { } localized) continue;
                var country = Words(localized);
                if (country.Length >= 4) table.Add((region, country));
            }
        }
        return table.ToArray();
    }

    /// <summary>Lowercased letters and digits, everything else a single space.</summary>
    internal static string Words(string text)
    {
        var mapped = new StringBuilder();
        foreach (var rune in Foundation.SwiftLower(text).EnumerateRunes())
            mapped.Append(Rune.IsLetter(rune) || IsNumberLike(rune.Value) ? rune.ToString() : " ");
        return string.Join(" ", mapped.ToString().Split(' ', StringSplitOptions.RemoveEmptyEntries));
    }

    private static readonly string[] IsoRegions = BuildIsoRegions();

    /// <summary>The system's region table, probed the only way .NET allows: every
    /// two-letter pair through <c>RegionInfo</c>. 676 constructions once, and what
    /// comes out is ICU's list — the counterpart of Swift's
    /// <c>Locale.Region.isoRegions</c> and of the JVM's <c>getISOCountries()</c>.</summary>
    private static string[] BuildIsoRegions()
    {
        var codes = new List<string>();
        for (var a = 0; a < 26; a++)
            for (var b = 0; b < 26; b++)
            {
                var code = "" + (char)('A' + a) + (char)('A' + b);
                try
                {
                    if (new RegionInfo(code).TwoLetterISORegionName == code) codes.Add(code);
                }
                catch (Exception e) when (e is ArgumentException or CultureNotFoundException) { }
            }
        return codes.ToArray();
    }

    /// <summary>The name of a region *as one language says it*, not the region of
    /// a culture: "ru-NL" is Нидерланды, while `new CultureInfo("ru-RU")`'s own
    /// region would be Россия. The language part, not the whole culture name, or
    /// the tag becomes the invalid "ru-RU-NL".</summary>
    private static string? RegionName(string code, CultureInfo culture)
    {
        try { return new RegionInfo(culture.TwoLetterISOLanguageName + "-" + code).DisplayName; }
        catch (Exception e) when (e is ArgumentException or CultureNotFoundException) { return null; }
    }
}
