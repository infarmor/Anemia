using System.Globalization;
using System.Numerics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AnemiaCore;

/// <summary>
/// The handful of Foundation behaviours this port cannot get from the BCL,
/// written out as rules instead of approximated: the two whitespace sets
/// Foundation trims with, `Double(String)` (C's strtod) and `Int(String)`,
/// strict UTF-8 and percent decoding, and Swift's newline set.
///
/// Code points are written numerically on purpose: `char.IsWhiteSpace` is a
/// different set, and the difference is what a panel header is made of. The
/// shared goldens under `Android/core/src/test/resources` — the same fixtures
/// the Kotlin port is compared against — pin every rule here.
/// </summary>
public static class Foundation
{
    /// <summary>`trimmingCharacters(in: .whitespacesAndNewlines)`: the space
    /// separators plus the C0 controls 09…0D, NEL, LS and PS. Measured scalar by
    /// scalar against Foundation (`base64/trim-sets.tsv`).</summary>
    public static string TrimSpaceLike(string text) => TrimWith(text, IsSpaceLike);

    /// <summary>`String.lowercased()` — not <c>ToLowerInvariant()</c>. Swept
    /// code point by code point against Swift (0x80…0x10FFFF, 1462 cases, this
    /// machine, 2026-09-27): the two tables are identical except U+0130, which
    /// Unicode lowercases to two scalars («i» + combining dot above) while .NET
    /// leaves it alone. That is not decoration here: a lowercased label is what
    /// becomes punycode, so «İ.example.com» would route a different name on
    /// Windows than on the phone.</summary>
    public static string SwiftLower(string text) =>
        text.ToLowerInvariant().Replace("\u0130", "i\u0307", StringComparison.Ordinal);

    /// <summary>`trimmingCharacters(in: .whitespaces)` — spaces and tab, and
    /// deliberately NOT newline, CR, VT, FF, NEL, LS or PS.</summary>
    public static string TrimFoundationSpaces(string text) => TrimWith(text, IsFoundationSpace);

    /// <summary>`trimmingCharacters(in: .whitespacesAndNewlines)` — what the
    /// bypass rules trim each line with. Not <c>char.IsWhiteSpace</c>:
    /// Foundation trims U+200B and .NET does not, and .NET trims U+180E which
    /// Foundation leaves alone, so a rule ending in an invisible space would be
    /// stored differently by the two ports.</summary>
    public static string TrimFoundationSpacesAndNewlines(string text) =>
        TrimWith(text, IsFoundationSpaceOrNewline);

    public static bool IsSpaceLike(char c) =>
        c == 0x20 || (c >= 0x09 && c <= 0x0D) || c == 0x85 || c == 0xA0 ||
        c == 0x1680 || (c >= 0x2000 && c <= 0x200B) || c == 0x2028 ||
        c == 0x2029 || c == 0x202F || c == 0x205F || c == 0x3000;

    /// <summary>`CharacterSet.whitespacesAndNewlines` — the set server names are
    /// trimmed with. Measured on this macOS (2026-09-27): it holds U+200B and
    /// U+00A0 but not U+FEFF or U+200D, so it is neither "all Cf" nor plain Zs —
    /// and U+200B is already inside the 0x2000…0x200B span `whitespaces`
    /// declares, which is why no extra clause belongs here (an earlier draft had
    /// a redundant one, and a mutant that deleted it changed nothing).</summary>
    public static bool IsFoundationSpaceOrNewline(char c) =>
        IsFoundationSpace(c) || IsSwiftNewline(c);

    public static bool IsFoundationSpace(char c) =>
        c == 0x20 || c == 0x09 || c == 0xA0 || c == 0x1680 ||
        (c >= 0x2000 && c <= 0x200B) || c == 0x202F || c == 0x205F || c == 0x3000;

    /// <summary>`Character.isNewline` - the set Swift cuts a subscription body
    /// with. Splitting on '\n' and '\r' alone is not it: it loses VT, FF,
    /// NEL, LS and PS.</summary>
    public static bool IsSwiftNewline(char c) =>
        c == 0x0A || c == 0x0B || c == 0x0C || c == 0x0D ||
        c == 0x85 || c == 0x2028 || c == 0x2029;

    /// <summary>UTF-8 bytes to text, or null when they aren't valid UTF-8.
    /// `Encoding.UTF8.GetString` can't stand in: it substitutes U+FFFD instead
    /// of failing, and Swift's `String(data:encoding:.utf8)` returns nil.</summary>
    public static string? Utf8(byte[] bytes)
    {
        try
        {
            return StrictUtf8.GetString(bytes);
        }
        catch (DecoderFallbackException)
        {
            return null;
        }
    }

    /// <summary>`removingPercentEncoding`: `%XX` escapes decoded, `+` left alone.
    /// Null on a malformed escape or invalid UTF-8, which is what Swift hands
    /// back and what a caller must not paper over with the raw text.</summary>
    public static string? PercentDecode(string text)
    {
        if (!text.Contains('%')) return text;
        var result = new StringBuilder(text.Length);
        var bytes = new List<byte>(text.Length);
        var index = 0;
        while (index < text.Length)
        {
            if (text[index] != '%')
            {
                var start = index;
                while (index < text.Length && text[index] != '%') index++;
                if (bytes.Count > 0)
                {
                    if (Utf8(bytes.ToArray()) is not { } decoded) return null;
                    result.Append(decoded);
                    bytes.Clear();
                }
                result.Append(text, start, index - start);
                continue;
            }
            if (index + 2 >= text.Length) return null;
            if (HexDigit(text[index + 1]) is not { } high) return null;
            if (HexDigit(text[index + 2]) is not { } low) return null;
            bytes.Add((byte)(high * 16 + low));
            index += 3;
        }
        if (bytes.Count > 0)
        {
            if (Utf8(bytes.ToArray()) is not { } decoded) return null;
            result.Append(decoded);
        }
        return result.ToString();
    }

    private static readonly UTF8Encoding StrictUtf8 =
        new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    private static string TrimWith(string text, Func<char, bool> isSpace)
    {
        var start = 0;
        var end = text.Length;
        while (start < end && isSpace(text[start])) start++;
        while (end > start && isSpace(text[end - 1])) end--;
        return text[start..end];
    }

    private static int? HexDigit(char c) =>
        c >= '0' && c <= '9' ? c - '0' :
        c >= 'a' && c <= 'f' ? c - 'a' + 10 :
        c >= 'A' && c <= 'F' ? c - 'A' + 10 : null;
}

/// <summary>
/// Foundation's `Double(String)` — C's `strtod`, not JSON's number grammar and
/// not tolerant of whitespace. `double.Parse` disagrees in ways a panel header
/// reaches:
///
///   * .NET skips leading and trailing whitespace, `strtod` accepts none;
///   * .NET has no hex floats at all, `strtod` does (`0x1f` is 31, `0x1.8p1` is
///     3), so the rounding is done here from the exact bits;
///   * .NET spells the specials `Infinity`/`NaN` case-sensitively, `strtod`
///     takes `inf`, `INF`, `nan(1)`.
///
/// `sub/numbers.tsv` pins every case against what Swift's `Double(_:)` itself
/// answers, compared as IEEE-754 bit patterns (`-0` and `0` differ in one bit).
/// </summary>
public static class SwiftDouble
{
    /// <summary>Null wherever Foundation would return nil.</summary>
    public static double? Parse(string text)
    {
        var start = 0;
        var negative = false;
        if (text.Length > 0 && (text[0] == '-' || text[0] == '+'))
        {
            negative = text[0] == '-';
            start = 1;
        }
        var rest = text[start..];
        if (rest.Length == 0) return null;

        if (Special(rest) is { } special) return negative ? -special : special;

        // The grammar is checked here character by character; only a text that
        // passes reaches the arithmetic, so the decimal path can use the BCL's
        // correctly-rounded parser and still agree with strtod bit for bit.
        if (rest.StartsWith("0x", StringComparison.Ordinal))
            return HexFloat(rest, negative);

        if (!DecimalGrammar(rest)) return null;
        try
        {
            return double.Parse(text, NumberStyles.Float, CultureInfo.InvariantCulture);
        }
        catch (Exception e) when (e is FormatException or OverflowException)
        {
            return null;
        }
    }

    /// <summary>`inf`, `infinity`, `nan`, `nan(<C integer literal>)`.</summary>
    private static double? Special(string rest)
    {
        var lower = rest.ToLowerInvariant();
        if (lower == "inf" || lower == "infinity") return double.PositiveInfinity;
        if (lower == "nan") return double.NaN;
        if (rest.Length >= 5 && lower.StartsWith("nan(", StringComparison.Ordinal) &&
            rest.EndsWith(")", StringComparison.Ordinal) &&
            IntegerLiteral(rest[4..^1]))
            return double.NaN;
        return null;
    }

    /// <summary>What Foundation accepts between `nan(` and `)`: a C integer
    /// literal — empty is fine, `0x…` needs a lowercase x, a leading 0 means
    /// octal. Measured case by case; only whether the whole string parses is at
    /// stake, the payload is discarded either way.</summary>
    private static bool IntegerLiteral(string text)
    {
        if (text.Length == 0) return true;
        if (text.StartsWith("0x", StringComparison.Ordinal))
            return All(text, c => IsHexDigit(c), 2);
        if (text.Length > 1 && text[0] == '0')
            return All(text, c => IsDigit(c) && c <= '7', 0);
        return All(text, IsDigit, 0);
    }

    /// <summary>Hex float, rounded exactly: `0x` is a lowercase-only prefix, the
    /// `p` exponent may be either case and may be left out entirely.</summary>
    private static double? HexFloat(string rest, bool negative)
    {
        var body = rest[2..];
        var pIndex = body.IndexOfAny(new[] { 'p', 'P' });
        var mantissa = pIndex >= 0 ? body[..pIndex] : body;
        var exponentText = pIndex >= 0 ? body[(pIndex + 1)..] : "";
        if (mantissa.Length == 0) return null;
        if (!GrammarOk(mantissa, IsHexDigit)) return null;

        BigInteger exponent;
        if (exponentText.Length == 0)
        {
            exponent = 0;
        }
        else
        {
            var signed = exponentText[0] == '-' || exponentText[0] == '+';
            var digits = signed ? exponentText[1..] : exponentText;
            if (digits.Length == 0 || !All(digits, IsDigit, 0)) return null;
            if (!BigInteger.TryParse(digits, NumberStyles.None, CultureInfo.InvariantCulture, out exponent))
                return null;
            if (exponentText[0] == '-') exponent = -exponent;
        }

        var dot = mantissa.IndexOf('.');
        var intPart = dot >= 0 ? mantissa[..dot] : mantissa;
        var fracPart = dot >= 0 ? mantissa[(dot + 1)..] : "";
        var hexDigits = intPart + fracPart;
        if (hexDigits.Length == 0 || !All(hexDigits, IsHexDigit, 0)) return null;

        var value = BigInteger.Parse(hexDigits, NumberStyles.HexNumber, CultureInfo.InvariantCulture);
        // Each fractional hex digit moves the binary point by four, and the p
        // exponent adds on top of that.
        var scaled = exponent - (BigInteger)4 * fracPart.Length;
        return Assemble(value, scaled, negative);
    }

    private static bool DecimalGrammar(string rest)
    {
        var e = rest.IndexOfAny(new[] { 'e', 'E' });
        var mantissa = e >= 0 ? rest[..e] : rest;
        var exponent = e >= 0 ? rest[(e + 1)..] : null;
        if (!GrammarOk(mantissa, IsDigit)) return false;
        if (exponent is not null && !IsIntegerText(exponent)) return false;
        return true;
    }

    /// <summary>Mantissa: digits, at most one dot, at least one digit.</summary>
    private static bool GrammarOk(string text, Func<char, bool> isDigit)
    {
        if (text.Count(c => c == '.') > 1) return false;
        var digits = text.Replace(".", "");
        return digits.Length > 0 && All(digits, isDigit, 0);
    }

    /// <summary>Exponent: an integer, signed or not, at least one ASCII digit.</summary>
    private static bool IsIntegerText(string text)
    {
        var body = text.Length > 0 && (text[0] == '+' || text[0] == '-') ? text[1..] : text;
        return body.Length > 0 && All(body, IsDigit, 0);
    }

    /// <summary>Round `value * 2^shift` (value an exact integer) to a double:
    /// round-to-nearest-even over the mantissa, then place it in a normal, a
    /// subnormal or an infinity. Done on the bits because .NET cannot parse a
    /// hex float at all, so there is no library call to hide behind.</summary>
    private static double Assemble(BigInteger value, BigInteger shift, bool negative)
    {
        if (value.IsZero) return negative ? -0.0 : 0.0;

        var bits = BigInteger.Abs(value);
        var bitLength = 0;
        for (var probe = bits; probe > 0; probe >>= 1) bitLength++;

        // Keep the top 53 significant bits, rounding the remainder away.
        var guard = bitLength - 53;
        if (guard > 0)
        {
            var kept = bits >> guard;
            var dropped = bits - (kept << guard);
            var half = BigInteger.One << (guard - 1);
            var roundUp = dropped > half || (dropped == half && (kept & BigInteger.One) != 0);
            bits = roundUp ? kept + 1 : kept;
            shift += guard;
            if (bits >> 53 != 0)
            {
                bits >>= 1;
                shift += 1;
            }
        }

        // value = bits * 2^shift. The two branches below assume a 53-bit
        // leading-1 form, so a short integer has to be widened (and the shift
        // reduced by the same amount) before the exponent can be read off.
        if (guard < 0)
        {
            bits <<= -guard;
            shift += guard;
        }

        // bits is exactly 53 bits with the leading one set, so under the
        // 1.f × 2^e form the unbiased exponent is shift + 52. A normal number
        // needs e >= -1022 (the biased field starts at 1), not e >= 1 — the
        // difference is the whole subnormal range, and it is what a
        // `0x.8p1` fixture lands in.
        var exponent = shift + 52;
        long raw;
        if (exponent >= 1024)
            raw = 0x7FF0000000000000L; // overflow → infinity, as strtod returns
        else if (exponent >= -1022)
            raw = ((long)(exponent + 1023) << 52) | (long)(bits & ((1L << 52) - 1));
        else
        {
            // Subnormal: the mantissa has to shrink to 52 bits at exponent
            // -1074, under the same round-to-nearest-even rule.
            var right = (int)(-1022 - exponent);
            if (right > 53) return negative ? -0.0 : 0.0; // past half of the least subnormal
            var dropped = bits & ((BigInteger.One << right) - 1);
            var kept = bits >> right;
            var half = BigInteger.One << (right - 1);
            var roundUp = dropped > half || (dropped == half && (kept & BigInteger.One) != 0);
            kept = roundUp ? kept + 1 : kept;
            // A carry out of the 52nd bit is not zero: it is the smallest
            // normal, 2^-1022.
            raw = kept >> 52 != 0 ? 1L << 52 : (long)kept;
        }
        // Set the sign bit rather than negating: -0 has to stay -0, and `0 - x`
        // would print +0 for a `+0x0p0` input that Swift answers -0 for.
        return BitConverter.Int64BitsToDouble(
            negative ? raw | unchecked((long)0x8000000000000000L) : raw);
    }

    private static bool All(string text, Func<char, bool> test, int skip)
    {
        for (var i = skip; i < text.Length; i++)
            if (!test(text[i])) return false;
        return true;
    }

    private static bool IsDigit(char c) => c >= '0' && c <= '9';

    private static bool IsHexDigit(char c) => IsDigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

/// <summary>
/// Foundation's `Int(String)` (and `UInt8`/`UInt16`/`UInt32` through the same
/// initializer): ASCII digits only, optional sign, leading zeros allowed, nil on
/// overflow. `int.TryParse` runs every character through `CharUnicodeInfo`, so
/// «1٠» (an ASCII one followed by an Extended Arabic-Indic zero) becomes a number
/// here and nothing on iOS.
/// </summary>
public static class SwiftInt
{
    public static long? Parse(string text)
    {
        var index = 0;
        var negative = false;
        if (text.Length > 0 && (text[0] == '-' || text[0] == '+'))
        {
            negative = text[0] == '-';
            index = 1;
        }
        var digits = text[index..];
        if (digits.Length == 0) return null;
        foreach (var c in digits)
            if (c < '0' || c > '9') return null;
        if (!long.TryParse(digits, NumberStyles.None, CultureInfo.InvariantCulture, out var value))
            return null;
        return negative ? -value : value;
    }

    /// <summary>The same for an unsigned field: a negative value is not a number.</summary>
    public static long? ParseUnsigned(string text, long max) =>
        Parse(text) is { } value && value >= 0 && value <= max ? value : null;
}
/// <summary>
/// The typing rules of Swift's <c>Decodable</c>, which the saved state and the
/// sync bundle are written against. A synthesized Swift decoder does not coerce:
/// a <c>"4"</c> where <c>Int</c> is declared fails the whole <c>decode</c>, and the
/// surrounding <c>(try? …) ?? default</c> then yields the <em>default</em>, not 4.
/// Reading a saved file permissively here would disagree with what the Mac and
/// the phone store from the same bytes, and the next save from this app would
/// carry the difference out to them — so these helpers answer "is this exactly
/// the type the schema declared", and the caller decides the fallback.
/// </summary>
public static class Strict
{
    /// <summary>Every reader below goes through <c>JsonElement</c>, not
    /// <c>JsonValue.GetValue&lt;T&gt;</c>, and that difference is a bug this port
    /// had: a node built from a CLR value (<c>JsonObject["port"] = 443</c>)
    /// throws <c>InvalidOperationException</c> when asked for a <c>double</c>,
    /// while the same bytes parsed from text answer it — so
    /// <c>FromJson(state.ToJson())</c> inside one process refused servers that
    /// round-tripped fine from the file on disk. Going through an element makes
    /// the two paths one path.</summary>
    private static JsonElement? Element(JsonNode? node)
    {
        if (node is null) return null;
        try { return node.GetValue<JsonElement>(); }
        catch (InvalidOperationException)
        {
            // A node built from a CLR value (`JsonObject["port"] = 443`) has no
            // element behind it to borrow. Serialising it is exactly what the
            // file on disk would carry, so both paths read one document.
            using var document = JsonDocument.Parse(node.ToJsonString());
            return document.RootElement.Clone();
        }
    }

    /// <summary><c>decode(String.self)</c>: a JSON string only — not a number
    /// rendered as text, not <c>true</c>, not null.</summary>
    public static string? Text(JsonNode? node) =>
        Element(node) is { } value && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    /// <summary><c>decode(Bool.self)</c>: JSON <c>true</c>/<c>false</c> only. The
    /// string "true" is a failed decode, which is what Swift's anti-DPI struct
    /// does with <c>muxEnabled: "yes"</c> — it takes the default.</summary>
    public static bool? Bool(JsonNode? node) => Element(node) is { } value ? value.ValueKind switch
    {
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        _ => (bool?)null,
    } : null;

    /// <summary><c>decode(Int.self)</c>: a JSON number whose value is integral.
    /// Measured on the <c>type-drift</c> fixture: Swift takes 443.0 and refuses
    /// both "443" and 443.5.</summary>
    public static int? Int(JsonNode? node)
    {
        if (Element(node) is not { } value || value.ValueKind != JsonValueKind.Number) return null;
        if (value.TryGetInt32(out var whole)) return whole;
        if (!value.TryGetDouble(out var real) || !double.IsFinite(real)) return null;
        return real == System.Math.Truncate(real) && real >= int.MinValue && real <= int.MaxValue
            ? (int)real : null;
    }

    /// <summary><c>decode(Int.self)</c> — Swift's <c>Int</c> is 64-bit, so this
    /// is the reader that actually matches it. <see cref="Int"/> above silently
    /// refuses what Foundation stores: a saved <c>junkPackets: 5000000000</c>
    /// (measured 2026-09-30, <c>LoaderTool state</c>) keeps its server on the Mac
    /// and costs it here, because the value cannot be represented. Any field
    /// declared <c>Int</c> in Swift and written by another app should be read
    /// with this one.</summary>
    public static long? Long(JsonNode? node)
    {
        if (Element(node) is not { } value || value.ValueKind != JsonValueKind.Number) return null;
        if (value.TryGetInt64(out var whole)) return whole;
        if (!value.TryGetDouble(out var real) || !double.IsFinite(real)) return null;
        return real == System.Math.Truncate(real) && real >= long.MinValue && real <= long.MaxValue
            ? (long)real : null;
    }

    /// <summary><c>decode(Double.self)</c> — and the one place a fraction is
    /// allowed: Foundation writes a <c>Date</c> as seconds since 2001, and
    /// 791692800.25 is a real saved timestamp.</summary>
    public static double? Double(JsonNode? node) =>
        Element(node) is { } value && value.ValueKind == JsonValueKind.Number &&
        value.TryGetDouble(out var real) && double.IsFinite(real) ? real : null;

    /// <summary><c>decode([String].self)</c>: an array whose every element is a
    /// string. One wrong element fails the array, not that element — a saved list
    /// of bypass lines with a stray number in it is not a list of lines.</summary>
    public static List<string>? TextArray(JsonNode? node)
    {
        if (node is not JsonArray array) return null;
        var result = new List<string>(array.Count);
        foreach (var entry in array)
        {
            if (Text(entry) is not { } text) return null;
            result.Add(text);
        }
        return result;
    }

    /// <summary><c>decode([String: String].self)</c> — the same all-or-nothing
    /// rule for a dictionary's values.</summary>
    public static Dictionary<string, string>? TextMap(JsonNode? node)
    {
        if (node is not JsonObject obj) return null;
        var result = new Dictionary<string, string>(System.StringComparer.Ordinal);
        foreach (var (key, value) in obj)
        {
            if (Text(value) is not { } text) return null;
            result[key] = text;
        }
        return result;
    }
}

    /// <summary>
    /// Foundation's `ISO8601DateFormatter` with the options `JSONEncoder`'s
    /// `.iso8601` strategy uses. The grammar and the range checks below are each
    /// an answer the real decoder gave (`LoaderTool sync` on generated probes),
    /// because the format is stranger than the standard: it rolls a Feb 30 over
    /// into March, accepts an hour of 99, refuses a day of 32, needs the
    /// uppercase `T` but not a lowercase `z`, and stops reading as soon as the
    /// date is complete — trailing junk is not an error.
    /// </summary>
    public static class SwiftDate
    {
        /// <summary>Seconds since 1970 as `Date` holds them; nil is a failed
        /// decode, which costs the whole bundle rather than just the stamp.</summary>
        public static double? Parse(string text)
        {
            var at = 0;
            if (!Digits(text, ref at, out var year)) return null;
            if (at >= text.Length || text[at] != '-') return null;
            at++;
            if (!Digits(text, ref at, out var month)) return null;
            if (at >= text.Length || text[at] != '-') return null;
            at++;
            if (!Digits(text, ref at, out var day)) return null;
            if (at >= text.Length || text[at] != 'T') return null;   // a space, or a lowercase t, is not a separator
            at++;
            if (!Digits(text, ref at, out var hour)) return null;
            if (at >= text.Length || text[at] != ':') return null;
            at++;
            if (!Digits(text, ref at, out var minute)) return null;
            if (at >= text.Length || text[at] != ':') return null;
            at++;
            if (!Digits(text, ref at, out var second)) return null;
            if (at < text.Length && text[at] == '.')
            {
                at++;
                if (!Digits(text, ref at, out _)) return null;      // a bare dot is not a fraction
            }
            if (at >= text.Length) return null;                     // no zone at all is not ISO 8601

            var offsetSeconds = 0.0;
            if (text[at] == 'Z' || text[at] == 'z')
            {
                at++;                                               // whatever follows is ignored, as Foundation ignores it
            }
            else if (text[at] is '+' or '-')
            {
                var sign = text[at] == '-' ? -1 : 1;
                at++;
                // At most two digits per part: `+3`, `+03`, `+0300`, `+03:00` and
                // `+03:0` are all one zone (measured). The hour is range-checked
                // at 23 while the minutes roll over, so `+00:60` is an hour and
                // `+24:00` is nothing.
                var offHour = ZonePart(text, ref at, 2);
                if (offHour < 0 || offHour > 23) return null;
                var offMinute = 0L;
                if (at < text.Length && text[at] == ':') at++;       // the colon is optional in the zone too
                if (at < text.Length && char.IsAsciiDigit(text[at]))
                {
                    offMinute = ZonePart(text, ref at, 2);
                    if (offMinute < 0) return null;
                }
                offsetSeconds = sign * (offHour * 3600 + offMinute * 60);
            }
            else return null;

            // Month and day-of-month are range-checked (month 13 and day 32 fail,
            // month 0 and day 0 too); the day is then *added* rather than placed,
            // so 2026-02-30 becomes March 2 and hour 25 spills into the next day.
            if (month < 1 || month > 12 || day < 1 || day > 31) return null;
            // Years outside a `Date()` this app can carry are refused rather than
            // guessed at: Foundation runs `0000-01-01` and `1-01-01` through its
            // lenient era rules (measured −62167392000 and −62135769600, neither
            // the proleptic-Gregorian day this port would compute), and no Anemia
            // has exported a stamp from the first millennium.
            if (year < 1 || year > 9999) return null;
            var days = DaysFromCivil(year, month, day);
            var seconds = days * 86400.0 + hour * 3600.0 + minute * 60.0 + second - offsetSeconds;
            if (double.IsNaN(seconds) || seconds < MinUnixSeconds || seconds > MaxUnixSeconds) return null;
            return seconds;
        }

        /// <summary>What `JSONEncoder` writes: whole seconds, uppercase `T`, `Z`
        /// for the zone. A fraction the file carried is dropped on the way out —
        /// Foundation's default formatter has no fractional-seconds option.</summary>
        public static string Format(double secondsSinceUnix)
        {
            var whole = Math.Floor(secondsSinceUnix);
            var days = (long)Math.Floor(whole / 86400.0);
            var secondOfDay = whole - days * 86400.0;
            var (year, month, day) = CivilFromDays(days);
            var hour = (long)(secondOfDay / 3600);
            var minute = (long)(secondOfDay / 60) % 60;
            var second = (long)secondOfDay % 60;
            return $"{year:0000}-{month:00}-{day:00}T{hour:00}:{minute:00}:{second:00}Z";
        }

        private const double MinUnixSeconds = -62135596800;   // DateTimeOffset.MinValue
        private const double MaxUnixSeconds = 253402300799;   // DateTimeOffset.MaxValue

        /// <summary>Up to `limit` digits, left-aligned — the zone's own reading.</summary>
        private static long ZonePart(string text, ref int at, int limit)
        {
            var value = -1L;
            for (var taken = 0; taken < limit && at < text.Length && char.IsAsciiDigit(text[at]); taken++, at++)
                value = value < 0 ? (text[at] - '0') : value * 10 + (text[at] - '0');
            return value;
        }

        private static bool Digits(string text, ref int at, out long value)
        {
            value = 0;
            var start = at;
            while (at < text.Length && char.IsAsciiDigit(text[at]))
            {
                value = value * 10 + (text[at] - '0');
                if (value > 100_000_000) return false;        // past any calendar this file can mean
                at++;
            }
            return at > start;
        }

        /// <summary>Howard Hinnant's civil-calendar arithmetic, so a year of 0000
        /// and a 99-hour day land where Foundation's calendar puts them.</summary>
        private static long DaysFromCivil(long year, long month, long day)
        {
            year -= month <= 2 ? 1 : 0;
            var era = (year >= 0 ? year : year - 399) / 400;
            var yearOfEra = year - era * 400;                              // [0, 399]
            var dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1;
            var dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear;
            return era * 146097 + dayOfEra - 719468;                       // 1970-01-01
        }

        private static (long Year, long Month, long Day) CivilFromDays(long days)
        {
            days += 719468;
            var era = (days >= 0 ? days : days - 146096) / 146097;
            var dayOfEra = days - era * 146097;
            var yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146096) / 365;
            var year = yearOfEra + era * 400;
            var dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100 + yearOfEra / 400);
            var marchMonth = (5 * dayOfYear + 2) / 153;
            var day = dayOfYear - (153 * marchMonth + 2) / 5 + 1;
            var month = marchMonth + (marchMonth < 10 ? 3 : -9);
            return (year + (month <= 2 ? 1 : 0), month, day);
        }
    }
