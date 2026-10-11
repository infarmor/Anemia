using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AnemiaCoreTests;

/// <summary>
/// Shared plumbing for the parity checks: the third contour of the harness that
/// already compares Kotlin against Swift.
///
/// The fixtures and goldens live in `Android/core/src/test/resources` and are
/// produced by `LoaderTool` from the Swift sources, so a check here answers a
/// stronger question than a unit test: not "does the C# port agree with its own
/// assumptions", but "does a Windows user get the same bytes as a Mac and an
/// iPhone user".
///
/// Two rules carried over from the Android harness, both of which cost a run
/// there before they were written down:
///   * a loop that compared nothing must be red — a missing file used to print a
///     clean "0 расхождений", so every check declares a floor of cases it expects
///     to have reached the comparison;
///   * a golden is compared as a whole text, and the first differing line is
///     printed with its neighbours, because a shifted-by-one fixture is the most
///     common way a comparison lies.
/// </summary>
internal static class Parity
{
    public const char Tab = (char)0x09;
    public const char LineFeed = (char)0x0A;
    public const char EmDash = (char)0x2014;
    public static readonly string Dash = EmDash.ToString();

    /// <summary>Walk up from the test binary until the repo root shows up — the
    /// fixtures are shared source, never copied into this project.</summary>
    public static string Fixtures
    {
        get
        {
            var dir = new DirectoryInfo(AppContext.BaseDirectory);
            while (dir is not null)
            {
                var candidate = Path.Combine(dir.FullName, "Android", "core", "src", "test", "resources");
                if (Directory.Exists(candidate)) return candidate;
                dir = dir.Parent;
            }
            throw new InvalidOperationException(
                "no Android/core/src/test/resources above " + AppContext.BaseDirectory +
                " - the shared goldens are missing, not skipped");
        }
    }

    public static string Read(params string[] parts)
    {
        var path = Path.Combine(new[] { Fixtures }.Concat(parts).ToArray());
        if (!File.Exists(path))
            throw new FileNotFoundException(
                "нет фикстуры " + path + ": перегенерируй её Scripts/golden-*.sh из Android", path);
        return File.ReadAllText(path, Encoding.UTF8);
    }

    /// <summary>Compare a produced dump against the Swift golden, line by line.
    /// Up to five differing rows are printed, each with its line number, and the
    /// total number of differences is named — a run that fixed one of thirteen
    /// divergences must not look like it fixed the file. `floor` is the smallest
    /// number of compared cases that counts as a real run.</summary>
    public static void Compare(string produced, string golden, string what, int floor)
    {
        var a = Split(golden);
        var b = Split(produced);
        var compared = Math.Min(a.Length, b.Length);
        var every = new List<int>();
        for (var i = 0; i < compared; i++)
            if (a[i] != b[i]) every.Add(i);
        // A short dump is a difference too: rows that fell off the end would
        // otherwise leave the list above empty and the run green.
        if (a.Length != b.Length) every.Add(compared);

        var message = new StringBuilder();
        if (every.Count > 0)
        {
            message.Append(what).Append(": расхождений ").Append(every.Count)
                .Append(", первое со строки ").Append(every[0] + 1).Append('\n');
            foreach (var i in every.Take(5))
            {
                message.Append("  ! ").Append(i + 1).Append(". ")
                    .Append("swift: ").Append(i < a.Length ? Show(a[i]) : "<нет>").Append('\n');
                message.Append("        ")
                    .Append("csharp:").Append(i < b.Length ? Show(b[i]) : "<нет>").Append('\n');
            }
        }
        if (a.Length != b.Length)
            message.Append(what).Append(": строк ").Append(b.Length).Append(", эталон ").Append(a.Length).Append('\n');
        if (compared < floor)
            message.Append(what).Append(": до сравнения дошло ").Append(compared)
                .Append(" кейсов, нужно минимум ").Append(floor).Append('\n');

        if (message.Length > 0) throw new Xunit.Sdk.XunitException(message.ToString());
    }

    /// <summary>Tab and newline made visible: a trailing tab versus a trailing
    /// space is the difference that eats a whole afternoon. Long rows (a base64
    /// document, a whole server dump) are cut to their first 160 characters with
    /// the real length kept, so five differences still fit in one readable
    /// message instead of forty kilobytes.</summary>
    private static string Show(string line)
    {
        var shown = line.Replace('\t', '→').Replace(" ", "·");
        const int keep = 160;
        return shown.Length <= keep ? shown : $"{shown[..keep]}…({shown.Length})";
    }

    /// <summary>Lines of a golden file. A trailing newline is not a line.</summary>
    public static string[] Split(string text)
    {
        var trimmed = text.TrimEnd((char)0x0A);
        return trimmed.Length == 0 ? Array.Empty<string>() : trimmed.Split((char)0x0A);
    }

    /// <summary>Fixture lines, empty ones dropped the way both harnesses do.</summary>
    public static List<string> Lines(string text) =>
        Split(text).Where(l => l.Length > 0).ToList();

    /// <summary>Columns of a fixture line, keeping empty fields — a missing
    /// column has to be visible as a wrong count, not silently shortened.</summary>
    public static string[] Columns(string line) => line.Split(Tab);

    /// <summary>`LoaderTool`'s `unescaped`: the fixture is one line per case, so
    /// the characters a case needs to contain (LF, TAB, VT, FF, CR, a literal
    /// backslash) are written as escapes and expanded the same way on both
    /// sides. An unknown escape keeps its backslash, which is what the Swift
    /// emitter does, and a difference there would look like a text mismatch.</summary>
    public static string Unescape(string text)
    {
        var result = new StringBuilder();
        var index = 0;
        while (index < text.Length)
        {
            var at = text.IndexOf('\\', index);
            if (at < 0)
            {
                result.Append(text, index, text.Length - index);
                break;
            }
            result.Append(text, index, at - index);
            index = at + 1;
            if (index >= text.Length) break;
            var kind = text[index];
            index++;
            result.Append(kind switch
            {
                'n' => "\n", 'r' => "\r", 't' => "\t", '\\' => "\\",
                'v' => ((char)0x0B).ToString(), 'f' => ((char)0x0C).ToString(),
                _ => "\\" + kind,
            });
        }
        return result.ToString();
    }

    /// <summary>`LoaderTool`'s own number reader: Foundation's grammar, and a
    /// value that does not parse is the case's error rather than a nil.</summary>
    public static double? Number(string raw) =>
        raw.Length == 0 ? null : AnemiaCore.SwiftDouble.Parse(raw);
    /// <summary>`canonicalJSON` + `sortedTrafficServers` in one pass: object keys
    /// sorted, and the ledger's flat «key, value» server array sorted by key, so
    /// two documents holding the same days and totals compare equal whatever
    /// order a dictionary enumerated in.</summary>
    /// <summary>`canonicalJSON` + `sortedTrafficServers` in one pass: object keys
    /// sorted, and a ledger's flat «key, value» server array sorted by key, so two documents
    /// holding the same days and totals compare equal whatever order a dictionary
    /// enumerated in. Arrays that are not such pairs keep their order — a server
    /// list is content in its order.</summary>
    public static string Canonical(string json)
    {
        var node = JsonNode.Parse(json);
        if (node is null) return "?";
        var text = new StringBuilder();
        Write(node, text);
        return text.ToString();
    }

    internal static void Write(JsonNode? node, StringBuilder into)
    {
        switch (node)
        {
            case JsonObject obj:
                into.Append('{');
                var first = true;
                foreach (var pair in obj.OrderBy(pair => pair.Key, StringComparer.Ordinal))
                {
                    if (!first) into.Append(',');
                    first = false;
                    into.Append(Quote(pair.Key)).Append(':');
                    Write(pair.Value, into);
                }
                into.Append('}');
                break;
            case JsonArray arr:
                WriteArray(arr, into);
                break;
            case JsonValue value:
                into.Append(ValueText(value));
                break;
            default:
                into.Append("null");
                break;
        }
    }

    internal static void WriteArray(JsonArray arr, StringBuilder into)
    {
        // A ledger `servers` array is alternating key/value pairs: sort the pairs,
        // never the elements, and keep them a pair — «key, value» with a comma, not
        // an object member.
        // Positional check on purpose: filtering to JsonValues first reindexes
        // the array, so a list of objects ([{…},{…}]) looked like "no non-key
        // elements" and every one of its members was then read as a GUID.
        var isPairs = arr.Count > 0 && arr.Count % 2 == 0;
        for (var index = 0; index < arr.Count && isPairs; index += 2)
            isPairs = arr[index] is JsonValue key && key.TryGetValue<string>(out var text) &&
                      Guid.TryParseExact(text, "D", out _);
        if (isPairs)
        {
            var pairs = Enumerable.Range(0, arr.Count / 2)
                .Select(index => (Key: arr[index * 2]!.GetValue<string>(), Node: arr[index * 2 + 1]))
                .OrderBy(pair => pair.Key, StringComparer.Ordinal)
                .ToList();
            into.Append('[');
            for (var i = 0; i < pairs.Count; i++)
            {
                // «key, value, key, value» — те же запятые, что в исходном
                // массиве: пара остаётся парой, объект из неё не собирается.
                if (i > 0) into.Append(',');
                into.Append(Quote(pairs[i].Key)).Append(',');
                Write(pairs[i].Node, into);
            }
            into.Append(']');
            return;
        }
        into.Append('[');
        for (var i = 0; i < arr.Count; i++)
        {
            if (i > 0) into.Append(',');
            Write(arr[i], into);
        }
        into.Append(']');
    }

    /// <summary>Numbers are re-emitted from the parsed value, so "10" and "10.0"
    /// on the two sides are the same text while a real difference in the number
    /// still shows up. Strings are escaped here rather than through
    /// <c>JsonValue.ToJsonString</c>, which needs a resolver on this runtime.</summary>
    internal static string ValueText(JsonValue value)
    {
        if (value.TryGetValue<string>(out var text)) return Quote(text);
        if (value.TryGetValue<bool>(out var flag)) return flag ? "true" : "false";
        if (value.TryGetValue<long>(out var whole)) return whole.ToString(CultureInfo.InvariantCulture);
        if (value.TryGetValue<double>(out var real)) return real.ToString("R", CultureInfo.InvariantCulture);
        return value.GetValue<JsonElement>().GetRawText();
    }

    internal static string Quote(string text)
    {
        var quote = ((char)0x22).ToString();
        var back = ((char)0x5C).ToString();
        var builder = new StringBuilder(quote);
        foreach (var c in text)
        {
            switch (c)
            {
                case (char)0x22: builder.Append(back).Append(quote); break;
                case (char)0x5C: builder.Append(back).Append(back); break;
                // Swift's `JSONEncoder` escapes the solidus, so every canonical
                // row in the shared goldens writes a URL as `https:\/\/host`.
                // Without this rule the two sides differ on any string carrying
                // a slash, which is most of a VPN config.
                case (char)0x2F: builder.Append(back).Append(c); break;
                case (char)0x08: builder.Append(back).Append('b'); break;
                case (char)0x09: builder.Append(back).Append('t'); break;
                case (char)0x0A: builder.Append(back).Append('n'); break;
                case (char)0x0D: builder.Append(back).Append('r'); break;
                default:
                    if (c < (char)0x20)
                        builder.Append(back).Append('u')
                            .Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    else builder.Append(c);
                    break;
            }
        }
        return builder.Append(quote).ToString();
    }
}
