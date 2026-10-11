using System.Text;
using AnemiaCore;
using Xunit;

namespace AnemiaCoreTests;

/// <summary>
/// The whole share-link corpus: 114 links, each dumped field by field exactly as
/// `LoaderTool dump-links` prints it, and compared with the golden the Swift
/// parser wrote. This is the check that a Windows user importing a link from a
/// panel gets the same server the Mac would have built — same transport, same
/// Reality keys, same junk profile, and the same refusal in the same words when
/// the link cannot be read.
///
/// The dump is deliberately not "parse and assert three fields": a link can be
/// right about its host and wrong about the `wgAllowedIPs` the engine then
/// routes, and only the whole block shows that.
/// </summary>
public class ParityLinks
{
    private const string Folder = "links";

    [Fact]
    public void EveryShareLinkDumpMatchesSwift()
    {
        var links = Parity.Split(Parity.Read(Folder, "corpus.txt"))
            .Select(line => line.Trim())
            .Where(line => line.Length > 0)
            .ToList();
        Assert.NotEmpty(links);

        var produced = new StringBuilder();
        var parsed = 0;
        var refused = 0;
        foreach (var link in links)
        {
            produced.Append("=== ").Append(link).Append(Parity.LineFeed);
            try
            {
                var server = ShareLinkParser.Parse(link);
                parsed++;
                foreach (var (key, value) in Fields(server))
                    produced.Append(key).Append(Parity.Tab).Append(value).Append(Parity.LineFeed);
            }
            catch (ParseErrorException e)
            {
                refused++;
                produced.Append("error").Append(Parity.Tab).Append(Describe(e)).Append(Parity.LineFeed);
            }
        }

        Parity.Compare(produced.ToString(), Parity.Read(Folder, "corpus.golden.txt"), "разбор ссылок", floor: 100);
        Assert.Equal(114, links.Count);
        // Both halves have to be reached: a run that only parsed, or only
        // refused, would mean the corpus walked one branch.
        Assert.True(parsed > 80 && refused > 5, $"parsed={parsed} refused={refused}");
    }

    /// <summary>`linkFieldPairs` from `Sources/LoaderTool/main.swift`, key for
    /// key, in its sorted order, with its empty-for-absent rule.</summary>
    internal static IEnumerable<(string Key, string Value)> Fields(ProxyServer s)
    {
        var fields = new List<(string, string)>
        {
            ("name", s.Name),
            ("proto", Wire.Name(s.Proto)),
            ("address", s.Address),
            ("port", s.Port.ToString(System.Globalization.CultureInfo.InvariantCulture)),
            ("credential", s.Credential),
            ("method", s.Method ?? ""),
            ("alterId", s.AlterId.ToString(System.Globalization.CultureInfo.InvariantCulture)),
            ("vmessCipher", s.VmessCipher ?? ""),
            ("network", Wire.Name(s.Network)),
            ("security", Wire.Name(s.Security)),
            ("sni", s.Sni ?? ""),
            ("alpn", string.Join(",", s.Alpn)),
            ("fingerprint", s.Fingerprint ?? ""),
            ("allowInsecure", s.AllowInsecure ? "true" : "false"),
            ("realityPublicKey", s.RealityPublicKey ?? ""),
            ("realityShortId", s.RealityShortId ?? ""),
            ("realitySpiderX", s.RealitySpiderX ?? ""),
            ("flow", s.Flow ?? ""),
            ("path", s.Path ?? ""),
            ("host", s.Host ?? ""),
            ("headerType", s.HeaderType ?? ""),
            ("grpcMultiMode", s.GrpcMultiMode is { } grpc ? (grpc ? "true" : "false") : ""),
            ("xhttpMode", s.XhttpMode ?? ""),
            ("xhttpExtra", s.XhttpExtra ?? ""),
            ("vlessEncryption", s.VlessEncryption ?? ""),
            ("awgVersion", s.IsWireGuardFamily ? s.AwgVersion.Raw() : ""),
            ("wgAddresses", s.UserData is { } data && data.TryGetValue("wgAddress", out var address) ? address : ""),
            // The peer profile is what the AWG engine actually consumes, so a
            // link parser that fills it wrong is invisible in every other field.
            ("wgPeer", s.WgProfile?.PeerPublicKey ?? ""),
            ("wgPreshared", s.WgProfile?.PresharedKey ?? ""),
            ("wgAllowedIPs", s.WgProfile is { } profile ? string.Join(", ", profile.AllowedIPs) : ""),
            ("wgDNS", s.WgProfile is { } dns ? string.Join(", ", dns.Dns) : ""),
            ("wgMTU", s.WgProfile?.Mtu?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? ""),
            ("wgKeepAlive", s.WgProfile?.KeepAlive?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? ""),
            ("userData", s.UserData is { } map
                ? string.Join(";", map.OrderBy(pair => pair.Key, StringComparer.Ordinal)
                    .Select(pair => $"{pair.Key}={pair.Value}"))
                : ""),
        };
        return fields.OrderBy(field => field.Item1, StringComparer.Ordinal);
    }

    /// <summary>Swift prints its error enum the way `String(reflecting:)` does:
    /// the case name with its associated value in quotes, or the bare name when
    /// the case carries nothing. The names are lower-camel because that is the
    /// declaration, and a port that printed `MalformedUri` instead would differ
    /// from the golden on every refusal row while being equally right.</summary>
    internal static string Describe(ParseErrorException e)
    {
        var name = e.Kind switch
        {
            ParseErrorKind.UnsupportedScheme => "unsupportedScheme",
            ParseErrorKind.MalformedUri => "malformedURI",
            ParseErrorKind.MissingField => "missingField",
            ParseErrorKind.InvalidBase64 => "invalidBase64",
            ParseErrorKind.EmptyInput => "emptyInput",
            ParseErrorKind.UnsupportedTransport => "unsupportedTransport",
            _ => e.Kind.ToString(),
        };
        return e.Detail.Length == 0 ? name : $"{name}(\"{e.Detail}\")";
    }
}
