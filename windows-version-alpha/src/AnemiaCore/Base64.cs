using System.Text;

namespace AnemiaCore;

/// <summary>
/// Base64 decoding that tolerates the sloppy variants seen in proxy share
/// links and subscriptions: URL-safe alphabet (-_) and missing = padding.
/// </summary>
public static class Base64
{
    /// <summary>Decode standard or URL-safe base64, with or without padding.
    ///
    /// The rules are Apple's, measured through `LoaderTool b64` on the shapes
    /// share links actually carry: characters outside the alphabet (a stray
    /// `.`, a BOM, a percent sign's digits) are dropped rather than rejected, a
    /// `=` ends the data and everything after it is discarded
    /// (`YWVz…cGFzc3dvcmQ=example.com:8388` decodes to `aes-256-gcm:password`
    /// and not to that plus junk), the padding is restored from the count of
    /// alphabet characters and not from the raw length (one stray character used
    /// to corrupt the padding of an otherwise valid blob), and an input with no
    /// alphabet characters at all is an empty result rather than a failure.</summary>
    public static byte[]? DecodeFlexible(string input)
    {
        var s = Foundation.TrimFoundationSpacesAndNewlines(input);
        if (s.Length == 0) return null;

        // Normalize the URL-safe alphabet to standard, gated on an actual
        // URL-safe character so the common path skips the copies.
        if (s.Contains('-') || s.Contains('_'))
            s = s.Replace('-', '+').Replace('_', '/');

        // Foundation's `Data(base64Encoded:, options: .ignoreUnknownCharacters)`,
        // derived from 30 shapes measured through `LoaderTool b64` and pinned by
        // all 56 rows of the shared `base64/cases.golden.txt`:
        //   * characters outside the alphabet are dropped, and what is left is
        //     grouped in fours of *significant* characters — `a b c` is three
        //     sextets and decodes to two bytes, it is not three broken quartets;
        //   * a group with a single sextet is nil (`a`, `YWJjZ` — the fifth
        //     character cannot make a byte), two gives one, three gives two;
        //   * `=` is padding only after two or three sextets of its group, and a
        //     sextet after a `=` in the same group is nil (`QQ=A`, `Y=`, `=AAA`);
        //   * a padded group ENDS the data: everything after it is ignored, so
        //     `QQ==A` and `AA==AA==` are one byte each;
        //   * a group of nothing but `=` is tolerated only at the very end of a
        //     stream that has already produced sextets — `abcd===` and
        //     `AAAA====` decode, `ABCD====AAAA` and `====` are nil;
        //   * a stream with no sextets at all is nil unless it was a whole
        //     number of four-character junk groups: `####` is empty, `###` is nil.
        var significant = new List<char>(s.Length);
        foreach (var c in s)
        {
            if (c == '=') { significant.Add('='); continue; }
            if (Sextet(c) >= 0) significant.Add(c);
        }
        if (significant.Count == 0)
            return s.Length % 4 == 0 ? Array.Empty<byte>() : null;

        var bytes = new List<byte>();
        for (var at = 0; at < significant.Count; at += 4)
        {
            var group = significant.GetRange(at, System.Math.Min(4, significant.Count - at));
            var pad = group.IndexOf('=');
            if (pad < 0)
            {
                if (!FlushGroup(bytes, group)) return null;
                continue;
            }
            if (pad < 2)
            {
                // A quartet of nothing but padding closes the stream when data
                // has already been read — and only when nothing but padding
                // follows it: `AAAA====` is three bytes, `ABCD====AAAA` is nil,
                // and `====` with nothing before it is nil.
                if (pad != 0 || bytes.Count == 0) return null;
                return group.All(c => c == '=') && RestIsPadding(significant, at + 4)
                    ? bytes.ToArray() : null;
            }
            if (group.Skip(pad).Any(c => c != '=')) return null;   // a sextet after padding
            if (!FlushGroup(bytes, group.GetRange(0, pad))) return null;
            return bytes.ToArray();                                // the padded quartet ends it
        }
        return bytes.ToArray();
    }

    private static bool RestIsPadding(List<char> significant, int from)
    {
        for (var i = from; i < significant.Count; i++)
            if (significant[i] != '=') return false;
        return true;
    }

    /// <summary>Four sextets are three bytes, three are two, two are one; one is
    /// nothing the format can express.</summary>
    private static bool FlushGroup(List<byte> bytes, IList<char> group)
    {
        int Value(int index) => Sextet(group[index]);
        switch (group.Count)
        {
            case 0:
                return true;
            case 1:
                return false;
            case 2:
                bytes.Add((byte)((Value(0) << 2) | (Value(1) >> 4)));
                return true;
            case 3:
                bytes.Add((byte)((Value(0) << 2) | (Value(1) >> 4)));
                bytes.Add((byte)((Value(1) << 4) | (Value(2) >> 2)));
                return true;
            default:
                bytes.Add((byte)((Value(0) << 2) | (Value(1) >> 4)));
                bytes.Add((byte)((Value(1) << 4) | (Value(2) >> 2)));
                bytes.Add((byte)((Value(2) << 6) | Value(3)));
                return true;
        }
    }

    /// <summary>`####` decodes to nothing while `###` is a failure: with no
    /// sextets at all, only a whole number of four-character groups is a stream.</summary>
    private static bool IsWholeJunk(string s) => s.Length % 4 == 0;

    private static int Sextet(char c) => c switch
    {
        >= 'A' and <= 'Z' => c - 'A',
        >= 'a' and <= 'z' => c - 'a' + 26,
        >= '0' and <= '9' => c - '0' + 52,
        '+' => 62,
        '/' => 63,
        _ => -1,
    };

    /// <summary>Decode base64 the way `Data(base64Encoded:)` does <em>without</em>
    /// the ignore-unknown option — this is the decoder a WireGuard key goes
    /// through, and the difference is the whole point: `yAnz…HE=@`, a key with one
    /// more '@' in the link, is silently stripped to a valid 32-byte key by the
    /// lenient decoder, so a corrupted link would import as a working server.
    ///
    /// Measured against Foundation: an interior space is nil, a 43-character
    /// string with no padding is nil, one `=` and two `=` at the end of the same
    /// key both decode, `####` is nil rather than empty, and an empty string is
    /// empty (0 bytes, not nil).</summary>
    public static byte[]? DecodeStrict(string input)
    {
        var core = input;
        for (var i = 0; i < core.Length; i++)
        {
            var c = core[i];
            if (c is >= 'A' and <= 'Z' or >= 'a' and <= 'z' or >= '0' and <= '9' or '+' or '/' or '=')
                continue;
            if (c is '-' or '_') { core = core.Replace('-', '+').Replace('_', '/'); break; }
            return null;   // a space, a newline, an '@' — anything else is a failed decode
        }

        var padded = core.Length > 0 && core[^1] == '=';
        var body = core.TrimEnd('=');
        // Padding may be one character too generous (Apple reads `HE==` as `HE=`)
        // but never missing: an unpadded 43-character key is nil there too.
        if (!padded && body.Length % 4 != 0) return null;
        var remainder = body.Length % 4;
        if (remainder > 0) body = body.PadRight(body.Length + (4 - remainder), '=');

        try
        {
            return Convert.FromBase64String(body);
        }
        catch (FormatException)
        {
            return null;
        }
    }

    /// <summary>Decode flexible base64 to a UTF-8 string, if valid.</summary>
    public static string? DecodeToString(string input)
    {
        var data = DecodeFlexible(input);
        // Strict UTF-8: Foundation's `String(data:encoding:.utf8)` answers nil for
        // a blob that is valid base64 and invalid text, and the caller has to see
        // that difference — decoding it to replacement characters would hide an
        // undecodable body behind an empty subscription.
        return data is null ? null : Foundation.Utf8(data);
    }
}