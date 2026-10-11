using System.Globalization;
using System.Text;
using AnemiaCore;
using Xunit;

namespace AnemiaCoreTests;

/// <summary>
/// Parity of the subscription layer against the Swift goldens: the number
/// grammar Foundation uses for a panel header, what
/// <c>SubscriptionInfo.Parse</c> makes of a header set, and the decision
/// whether a panel may change its list without the user.
/// </summary>
public class ParitySubscriptionsTests
{
    /// <summary>`sub/numbers.tsv` is what Swift's `Double(_:)` itself answers for
    /// each case, hex-encoded so that a vertical tab can be a case at all, and
    /// compared as IEEE-754 bit patterns — `-0` and `0` differ in one bit, and a
    /// hex float is exactly where a hand-written parser goes wrong.</summary>
    [Fact]
    public void NumberGrammarMatchesFoundation()
    {
        var cases = Parity.Lines(Parity.Read("sub", "numbers.txt"));
        var rows = Parity.Lines(Parity.Read("sub", "numbers.tsv"));
        Assert.Equal(cases.Count, rows.Count);

        var nils = 0;
        var diffs = new List<string>();
        for (var i = 0; i < rows.Count; i++)
        {
            var columns = Parity.Columns(rows[i]);
            var input = DecodeHex(columns[0]);
            var expected = columns[1];
            var actual = Verdict(SwiftDouble.Parse(input));
            if (actual == "nil") nils++;
            if (actual != expected)
                diffs.Add("  " + Show(input) + ": swift=" + expected + " csharp=" + actual);
        }

        Assert.True(diffs.Count == 0, "грамматика чисел разошлась с Foundation:\n" + string.Join("\n", diffs));
        Assert.True(nils > 20, "слишком мало отказов: " + nils + " — фикстура перестала проверятьGrammar");
    }

    /// <summary>Headers a panel sends, dumped in exactly the shape
    /// `LoaderTool subinfo` prints, so the two files can be compared whole.</summary>
    [Fact]
    public void SubscriptionHeadersMatchSwift()
    {
        var produced = new StringBuilder();
        var parsed = 0;
        foreach (var rawLine in Parity.Lines(Parity.Read("sub", "headers.txt")))
        {
            var parts = Parity.Columns(rawLine);
            if (parts.Length < 2) continue;
            var headers = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var header in parts.Skip(1))
            {
                var colon = header.IndexOf(':');
                if (colon < 0) continue;
                headers[header[..colon]] = header[(colon + 1)..];
            }
            var info = SubscriptionInfo.Parse(headers);
            if (info is not null) parsed++;
            produced.Append(Dump(parts[0], info)).Append(Parity.LineFeed);
        }

        Parity.Compare(produced.ToString(), Parity.Read("sub", "headers.golden.txt"), "заголовки", floor: 14);
        Assert.True(parsed >= 12, "наборов заголовков с информацией: " + parsed);
    }

    /// <summary>The auto-refresh decision: TLS gate, the panel's own interval,
    /// the clamp and the future-dated mark, all in one predicate, so a Windows
    /// install cannot fetch a list an iPhone refuses to touch.</summary>
    [Fact]
    public void RefreshDueDecisionMatchesSwift()
    {
        var produced = new StringBuilder();
        var verdicts = 0;
        var refusals = 0;
        foreach (var line in Parity.Lines(Parity.Read("sub", "due.txt")))
        {
            var parts = Parity.Columns(line);
            var label = parts.Length > 0 ? parts[0] : "";
            if (label.Length == 0)
            {
                produced.Append("error").Append(Parity.Tab).Append("no label").Append(Parity.Tab).Append(line).Append(Parity.LineFeed);
                refusals++;
                continue;
            }
            if (line.Contains((char)0x0D))
            {
                produced.Append(label).Refuse("cr");
                refusals++;
                continue;
            }
            if (parts.Length != 7)
            {
                produced.Append(label).Refuse("columns " + parts.Length);
                refusals++;
                continue;
            }
            if (parts[1].Length == 0)
            {
                produced.Append(label).Refuse("no url");
                refusals++;
                continue;
            }
            if (!(parts[6].Length == 0 || parts[6] == "0" || parts[6] == "1"))
            {
                produced.Append(label).Refuse("allowInsecure");
                refusals++;
                continue;
            }

            string? problem = null;
            double? OptionalNumber(int index, string name)
            {
                var raw = parts[index];
                if (raw.Length == 0) return null;
                var value = Parity.Number(raw);
                if (value is null && problem is null) problem = name;
                return value;
            }
            var lastFetched = OptionalNumber(2, "lastUpdated");
            var now = OptionalNumber(3, "now");
            var panelInterval = OptionalNumber(4, "panelInterval");
            var defaultAge = OptionalNumber(5, "defaultAge");
            if (problem is not null)
            {
                produced.Append(label).Refuse(problem);
                refusals++;
                continue;
            }
            if (now is not { } nowValue)
            {
                produced.Append(label).Refuse("now");
                refusals++;
                continue;
            }

            var sub = new Subscription(label, parts[1]);
            // Пустой столбец defaultAge отдаёт дефолт самого аргумента, а не
            // удвоенную константу: иначе правка дефолта золотой бы не заметила.
            var maxAgeSeconds = sub.RefreshMaxAgeSeconds(panelInterval, defaultAge);
            var due = Subscription.RefreshIsDue(lastFetched, nowValue, sub.TlsProtected,
                panelInterval, defaultAge, allowInsecure: parts[6] == "1");
            verdicts++;
            produced.Append(label).Append(Parity.Tab).Append("maxAge=").Append(AgeText(maxAgeSeconds))
                .Append(Parity.Tab).Append("due=").Append(due ? "1" : "0").Append(Parity.LineFeed);
        }

        Parity.Compare(produced.ToString(), Parity.Read("sub", "due.golden.txt"), "расписание обновлений", floor: 38);
        Assert.True(verdicts >= 30, "вердиктов: " + verdicts);
        Assert.True(refusals >= 7, "громко отказанных кейсов: " + refusals);
    }

    /// <summary>Same clamp rule Swift prints: an age that is not a number is
    /// named, because `Int(NaN)` would trap in the middle of a fixture and leave
    /// the golden truncated.</summary>
    private static string AgeText(double seconds)
    {
        if (double.IsNaN(seconds)) return "nan";
        if (seconds == double.PositiveInfinity) return "inf";
        if (seconds == double.NegativeInfinity) return "-inf";
        return ((long)seconds).ToString(CultureInfo.InvariantCulture);
    }

    private static string Dump(string id, SubscriptionInfo? info)
    {
        string Number(long? value) => value?.ToString(CultureInfo.InvariantCulture) ?? Parity.Dash;
        return string.Join(Parity.Tab,
            id,
            "title=" + (info is null ? "nil" : info.Title ?? Parity.Dash),
            "up=" + Number(info?.Uploaded),
            "down=" + Number(info?.Downloaded),
            "total=" + Number(info?.Total),
            "used=" + Number(info?.Used),
            "remaining=" + Number(info?.Remaining),
            "unlimited=" + ((info?.IsUnlimited ?? false) ? "true" : "false"),
            "fraction=" + (info?.UsedFraction is { } fraction
                ? fraction.ToString("F4", CultureInfo.InvariantCulture)
                : Parity.Dash),
            "expires=" + (info?.ExpiresEpochSeconds is { } expires
                ? (expires >= (double)long.MaxValue ? "overflow" : expires.ToString(CultureInfo.InvariantCulture))
                : Parity.Dash),
            "interval=" + (info?.UpdateIntervalSeconds is { } interval
                ? interval.ToString("F0", CultureInfo.InvariantCulture)
                : Parity.Dash),
            "support=" + (info?.SupportUrl ?? Parity.Dash),
            "web=" + (info?.WebPageUrl ?? Parity.Dash),
            "announce=" + (info?.Announcement ?? Parity.Dash));
    }

    /// <summary>The answer is printed as a bit pattern for finite values and by
    /// <em>name</em> for the specials — `LoaderTool` does, because `Int(NaN)` and
    /// `Int(inf)` would trap before they could be printed. `-nan` loses its sign
    /// here the same way it does there.</summary>
    private static string Verdict(double? value) => value switch
    {
        null => "nil",
        double nan when double.IsNaN(nan) => "nan",
        double pos when pos == double.PositiveInfinity => "inf",
        double neg when neg == double.NegativeInfinity => "-inf",
        _ => BitConverter.DoubleToInt64Bits(value.Value).ToString("x16"),
    };

    private static string DecodeHex(string hex)
    {
        var bytes = new byte[hex.Length / 2];
        for (var i = 0; i < bytes.Length; i++)
            bytes[i] = byte.Parse(hex.Substring(i * 2, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
        return Encoding.UTF8.GetString(bytes);
    }

    private static string Show(string text)
    {
        var builder = new StringBuilder(text.Length + 8);
        foreach (var c in text)
        {
            if (c < 0x20 || c == 0x7F) builder.Append("<").Append(((int)c).ToString("x2")).Append(">");
            else builder.Append(c);
        }
        return builder.ToString();
    }
}

internal static class ParityLineExtensions
{
    /// <summary>`label<TAB>error<TAB>reason` — the shape both harnesses print for
    /// a case they refuse, so a truncated fixture can never become a verdict.</summary>
    public static StringBuilder Refuse(this StringBuilder line, string reason)
    {
        line.Append((char)0x09).Append("error").Append((char)0x09).Append(reason).Append((char)0x0A);
        return line;
    }
}
