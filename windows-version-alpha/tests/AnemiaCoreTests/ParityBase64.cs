using AnemiaCore;
using Xunit;

namespace AnemiaCoreTests;

/// <summary>
/// The shared base64 fixture — 56 inputs and the bytes Foundation's
/// `Data(base64Encoded:, options: .ignoreUnknownCharacters)` made of them, as
/// `LoaderTool b64` prints them.
///
/// This is the decoder every share link runs its credentials through, so a rule
/// here is not academic: the padding has to be counted on the alphabet-only view
/// (one stray character used to shift a whole vmess payload), a `=` has to end
/// the data (or a legacy `ss://…=example.com:8388` decodes into junk that still
/// parses as a host), and an interior space must <em>not</em> be dropped.
/// </summary>
public class ParityBase64
{
    private const string Folder = "base64";

    [Fact]
    public void FlexibleDecodeMatchesFoundationRowByRow()
    {
        var produced = new System.Text.StringBuilder();
        var decoded = 0;
        var refused = 0;
        foreach (var line in Parity.Split(Parity.Read(Folder, "cases.txt")))
        {
            if (line.Length == 0) continue;
            var data = Base64.DecodeFlexible(line);
            produced.Append(line).Append(Parity.Tab)
                .Append(data is null ? "nil" : Hex(data)).Append(Parity.LineFeed);
            if (data is null) refused++; else decoded++;
        }

        var goldenText = Parity.Read(Folder, "cases.golden.txt");
        Parity.Compare(produced.ToString(), goldenText, "base64", floor: 50);
        // Both halves of the contract have to be reached — a run in which every
        // row decoded would never notice a decoder that cannot say nil. The
        // numbers are counted from the golden, not estimated: 19 of its 56 rows
        // are `nil`, and a fixture regenerated with different shapes moves them.
        var expectedRefused = Parity.Split(goldenText).Count(line =>
            line.EndsWith(Parity.Tab + "nil", StringComparison.Ordinal));
        Assert.Equal(expectedRefused, refused);
        Assert.Equal(Parity.Split(goldenText).Length - expectedRefused, decoded);
    }

    private static string Hex(byte[] data) =>
        string.Concat(data.Select(b => b.ToString("x2", System.Globalization.CultureInfo.InvariantCulture)));

    /// <summary>The strict variant keys go through, measured against
    /// `Data(base64Encoded:)` without options: a stray character — a space, an
    /// extra '@' from a doubled userinfo — is a failed decode, not something to
    /// skip. Padding may be one `=` too generous, never missing.</summary>
    [Theory]
    [InlineData("yAnz5TF+fT28A5vH0vGcC8pVXqv5ZfV0+0P4Rn1v5HE=", 32)]     // a real key
    [InlineData("yAnz5TF+fT28A5vH0vGcC8pVXqv5ZfV0+0P4Rn1v5HE==", 32)]    // Foundation tolerates the extra pad
    [InlineData("yAnz5TF+fT28A5vH0vGcC8pVXqv5ZfV0+0P4Rn1v5HE", -1)]      // unpadded 43: nil there too
    [InlineData("yAnz5TF+fT28A5vH0vGcC8pVXqv5ZfV0+0P4Rn1v5HE=@", -1)]    // the double-`@` link
    [InlineData("yAnz5TF+fT28A5vH0vGcC8pVXqv5ZfV0+0P4Rn1v 5HE=", -1)]    // an interior space
    [InlineData("YW JjZA==", -1)]                                             // an interior space, padding intact
    [InlineData("YWJjZA==\n", -1)]                                           // even a trailing newline
    [InlineData("####", -1)]
    [InlineData("YWJj", 3)]
    public void StrictDecodeFollowsFoundation(string text, int byteCount)
    {
        var data = Base64.DecodeStrict(text);
        if (byteCount < 0) Assert.Null(data);
        else Assert.Equal(byteCount, data!.Length);
    }

    /// <summary>An empty string is <em>empty</em> to both decoders, not a
    /// failure — the callers use nil for "not base64" and would otherwise treat a
    /// deliberately blank field as a broken link.</summary>
    [Fact]
    public void EmptyIsDecodedAsEmpty()
    {
        Assert.Empty(Base64.DecodeStrict("")!);
        Assert.Null(Base64.DecodeFlexible(""));
    }
}
