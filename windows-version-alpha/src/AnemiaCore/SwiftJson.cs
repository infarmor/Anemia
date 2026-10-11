using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AnemiaCore;

/// <summary>
/// What <c>JSONEncoder</c> writes, byte for byte — because a bundle file is
/// compared by its bytes on every platform and a QR payload is deflated from
/// them, so a stray space here changes a device name into a different file.
///
/// Measured against Foundation (a <c>swiftc</c> probe of
/// <c>JSONEncoder.outputFormatting</c> and the <c>sync/cases.golden.txt</c>
/// <c>file-bytes</c> rows), not copied from a JSON tutorial:
/// <list type="bullet">
/// <description>keys are sorted <b>ordinally</b> by <c>.sortedKeys</c>. The
/// collation order a <c>canonicalJSON</c> dump shows
/// (<c>adaptiveMasking</c> before <c>adBlock</c>) is
/// <c>JSONSerialization</c>'s, and the two disagree — the file's own bytes put
/// <c>adBlock</c> first;</description>
/// <description>an absent optional is omitted, never <c>: null</c>;</description>
/// <description>the solidus is escaped (<c>https:\/\/host</c>), while Cyrillic,
/// emoji and even U+2028 are written raw;</description>
/// <description>pretty form is two spaces per level, <c>" : "</c> around every
/// member, and an <em>empty</em> array or object is a blank line between its
/// brackets — <c>"alpn" : [\n\n      ]</c>.</description>
/// </list>
/// </summary>
public static class SwiftJson
{
    public static string Compact(JsonNode? node)
    {
        var text = new StringBuilder();
        Write(node, text, 0, pretty: false);
        return text.ToString();
    }

    /// <summary>`JSONEncoder` with `[.prettyPrinted, .sortedKeys]`.</summary>
    public static string Pretty(JsonNode? node)
    {
        var text = new StringBuilder();
        Write(node, text, 0, pretty: true);
        return text.ToString();
    }

    private static void Write(JsonNode? node, StringBuilder into, int depth, bool pretty)
    {
        switch (node)
        {
            case null:
                into.Append("null");
                break;
            case JsonObject obj:
                WriteObject(obj, into, depth, pretty);
                break;
            case JsonArray arr:
                WriteArray(arr, into, depth, pretty);
                break;
            case JsonValue value:
                into.Append(ValueText(value));
                break;
        }
    }

    private static void WriteObject(JsonObject obj, StringBuilder into, int depth, bool pretty)
    {
        if (obj.Count == 0)
        {
            into.Append(pretty ? "{\n\n" + Indent(depth) + "}" : "{}");
            return;
        }
        into.Append(pretty ? "{\n" : "{");
        // Sorted into a copy rather than with LINQ: an exported bundle is a few
        // hundred of these objects, and the ordering query allocated an
        // enumerator, a list and a key array per object on every export.
        var members = new KeyValuePair<string, JsonNode?>[obj.Count];
        ((ICollection<KeyValuePair<string, JsonNode?>>)obj).CopyTo(members, 0);
        Array.Sort(members, (left, right) => string.CompareOrdinal(left.Key, right.Key));
        for (var index = 0; index < members.Length; index++)
        {
            var pair = members[index];
            if (index > 0) into.Append(pretty ? ",\n" : ",");
            if (pretty) into.Append(Indent(depth + 1));
            into.Append(Quote(pair.Key)).Append(pretty ? " : " : ":");
            Write(pair.Value, into, depth + 1, pretty);
        }
        into.Append(pretty ? "\n" + Indent(depth) + "}" : "}");
    }

    private static void WriteArray(JsonArray arr, StringBuilder into, int depth, bool pretty)
    {
        if (arr.Count == 0)
        {
            into.Append(pretty ? "[\n\n" + Indent(depth) + "]" : "[]");
            return;
        }
        into.Append(pretty ? "[\n" : "[");
        for (var index = 0; index < arr.Count; index++)
        {
            if (index > 0) into.Append(pretty ? ",\n" : ",");
            if (pretty) into.Append(Indent(depth + 1));
            Write(arr[index], into, depth + 1, pretty);
        }
        into.Append(pretty ? "\n" + Indent(depth) + "]" : "]");
    }

    private static string Indent(int depth) => new string(' ', 2 * depth);

    private static string ValueText(JsonValue value)
    {
        if (value.TryGetValue<string>(out var text)) return Quote(text);
        // One unboxing, then the runtime type: the tempting `else` for a number
        // is `GetValue<JsonElement>`, and on a node built from a CLR number —
        // every `port` and `alterId` in a state this port assembles by hand —
        // that call does not fall back, it *throws*. A bundle of 500 servers
        // measured 2,0 с to compact that way against 9 мс for the same document
        // with strings in those places, which is the cost of a thousand
        // exceptions per export.
        var raw = value.GetValue<object>();
        switch (raw)
        {
            case bool flag:
                return flag ? "true" : "false";
            case string s:
                return Quote(s);
            case JsonElement element:
                // Parsed numbers keep the text they were read as, so a hand-edited
                // decimal is not reformatted on the way out.
                return element.ValueKind == JsonValueKind.String
                    ? Quote(element.GetString()!)
                    : element.GetRawText();
            case int or long or short or byte or sbyte or uint or ulong or ushort:
                return System.Convert.ToInt64(raw).ToString(CultureInfo.InvariantCulture);
            case decimal or double or float:
                var real = System.Convert.ToDouble(raw, CultureInfo.InvariantCulture);
                return real == Math.Truncate(real) && real is >= long.MinValue and <= long.MaxValue
                    ? ((long)real).ToString(CultureInfo.InvariantCulture)
                    : real.ToString("R", CultureInfo.InvariantCulture);
            case null:
                return "null";
            default:
                try
                {
                    return value.GetValue<JsonElement>().GetRawText();
                }
                catch (InvalidOperationException)
                {
                    return value.ToJsonString();
                }
        }
    }

    private static string Quote(string text)
    {
        var builder = new StringBuilder(text.Length + 2).Append('"');
        foreach (var c in text)
        {
            switch (c)
            {
                case '"': builder.Append("\\\""); break;
                case '\\': builder.Append("\\\\"); break;
                case '/': builder.Append("\\/"); break;
                case '\b': builder.Append("\\b"); break;
                case '\t': builder.Append("\\t"); break;
                case '\n': builder.Append("\\n"); break;
                case '\r': builder.Append("\\r"); break;
                case '\f': builder.Append("\\f"); break;
                default:
                    if (c < 0x20)
                        builder.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    else builder.Append(c);   // Cyrillic, emoji, U+2028: raw, as Foundation writes them
                    break;
            }
        }
        return builder.Append('"').ToString();
    }
}
