using System.Text;
using AnemiaCore;
using Xunit;

namespace AnemiaCoreTests;

/// <summary>
/// Shapes the shared `sync/cases` fixture does not contain, measured against the
/// real Swift decoder rather than guessed: each body below was put into a `read`
/// case and run through `LoaderTool sync`, which answers `bundle …` or
/// `error notABundle`.
///
/// The rule they pin is the one the state file does <em>not</em> follow: a
/// `SyncBundle` is decoded by Swift's synthesized `Decodable`, so a single bad
/// server element costs the whole transfer instead of that one row. The state
/// reader drops bad entries and keeps the file — the same leniency applied here
/// would let a Windows import silently lose half of what an iPhone sent.
/// </summary>
public class ParitySyncProbes
{
    private const string Template =
        "{\"version\":1,\"exportedAt\":\"2026-02-02T02:40:00Z\",\"device\":\"iPhone Маши\",\"servers\":[{\"id\":\"1B564D2F-5117-4C8C-9B0D-9E2F8A3F1C22\",\"name\":\"R\",\"proto\":\"vless\",\"address\":\"example.com\",\"port\":443,\"credential\":\"1b564d2f-5117-4c8c-9b0d-9e2f8a3f1c22\",\"alterId\":0,\"network\":\"ws\",\"security\":\"reality\",\"alpn\":[],\"allowInsecure\":false,\"flow\":\"xtls-rprx-vision\",\"sni\":\"www.microsoft.com\",\"realityPublicKey\":\"k\"}],\"subscriptions\":[{\"name\":\"Панель\",\"url\":\"https://panel.example.com/sub\"}],\"settings\":{\"maskingProfile\":\"maximum\",\"killSwitchEnabled\":true}}";

    [Theory]
    [InlineData("", "", "ok")]                                               // the control
    [InlineData("s", "3", "notABundle")]                                    // a wrong root type
    [InlineData("\"servers\":[", "\"servers\":[{\"id\":\"nope\",\"name\":\"x\"},", "notABundle")]
    [InlineData("\"port\":443", "\"port\":\"443\"", "notABundle")]           // a string where a number belongs
    [InlineData("\"url\":\"https://panel.example.com/sub\"", "\"url\":5", "notABundle")]
    [InlineData("\"settings\":{", "\"settings\":5", "notABundle")]          // a scalar where a block belongs
    [InlineData("\"maskingProfile\":\"maximum\"", "\"maskingProfile\":\"turbo\"", "notABundle")]
    [InlineData("\"killSwitchEnabled\":true", "\"killSwitchEnabled\":\"yes\"", "notABundle")]
    [InlineData("\"settings\":{\"maskingProfile\":\"maximum\",\"killSwitchEnabled\":true}", 
            "\"settings\":null", "no-settings")]   // an explicit null is "no settings"
    [InlineData("\"subscriptions\":[", "\"quantumTunnel\":true,\"subscriptions\":[", "ok")]
    public void ABundleIsDecodedAllOrNothing(string find, string replace, string verdict)
    {
        var body = find.Length == 0 ? Template : Template.Replace(find, replace);
        if (verdict is "ok" or "no-settings")
        {
            var bundle = SyncBundle.Decode(body);
            Assert.Equal("iPhone Маши", bundle.Device);
            if (verdict == "ok") Assert.NotNull(bundle.Settings);
            else Assert.Null(bundle.Settings);
        }
        else
        {
            var error = Assert.Throws<SyncBundle.DecodeException>(() => SyncBundle.Decode(body));
            Assert.Equal("notABundle", error.Reason);
        }
    }

    /// <summary>Two settings fields of the wrong type inside one object still
    /// refuse the bundle: Swift's `Settings` is synthesized too, so the first bad
    /// field throws before the rest are read — this port returns null for the
    /// whole bundle at the first one as well.</summary>
    [Fact]
    public void OneBadSettingsFieldCostsTheBundle()
    {
        var body = Template
            .Replace("\"killSwitchEnabled\":true", "\"killSwitchEnabled\":\"yes\",\"adBlock\":true");
        var error = Assert.Throws<SyncBundle.DecodeException>(() => SyncBundle.Decode(body));
        Assert.Equal("notABundle", error.Reason);
    }

    /// <summary>`SyncBundle.fromLink` tests the prefix on a lower-cased copy of
    /// the text, so an uppercase QR link still decodes when the link is handed to
    /// that function directly — while `decode` matches the prefix case-sensitively
    /// and refuses the same text. The fixtures only walk `decode`, which is why
    /// `LoaderTool sync` cannot show this half; the two lines of Swift's own
    /// source are the evidence, and the asymmetry is deliberate: the import sheet
    /// asks «is this ours» loosely, the reader is strict about what it routes.</summary>
    [Fact]
    public void FromLinkIsCaseInsensitiveWhileDecodeIsNot()
    {
        // The `link-full` block specifically: the first link row in the file is
        // `link-empty`, whose bundle has no servers and a different device.
        var rows = Parity.Split(Parity.Read("sync", "cases.golden.txt"));
        var link = rows.Skip(Array.IndexOf(rows, "=== link-full") + 1)
            .First(line => line.StartsWith("link" + Parity.Tab, StringComparison.Ordinal))
            .Split(Parity.Tab)[1];
        var uppercase = SyncBundle.LinkPrefix.ToUpperInvariant() + link[SyncBundle.LinkPrefix.Length..];

        var bundle = SyncBundle.FromLink(uppercase);
        Assert.Equal("iPhone Маши", bundle.Device);
        Assert.Throws<SyncBundle.DecodeException>(() => SyncBundle.Decode(uppercase));
        Assert.True(SyncBundle.LooksLikeBundle(uppercase));   // the sheet offers it either way
    }
}
