using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using AnemiaCore;
using Xunit;

namespace AnemiaCoreTests;

/// <summary>
/// Hysteria parity: the client YAML the Windows port writes must be the bytes
/// Swift writes, because hysteria reads the config itself — a field spelled
/// `pinnedSHA256` instead of `pinSHA256` parses fine and simply does not pin
/// anything. `hysteria/links.golden.txt` is Swift's answer for 44 cases, and
/// `Scripts/verify-hysteria.sh` then feeds each YAML to the real binary.
/// </summary>
public class ParityHysteriaTests
{
    private const string Folder = "hysteria";

    [Fact]
    public void ClientYamlMatchesSwift()
    {
        var rows = Parity.Lines(Parity.Read(Folder, "links.txt"));
        var produced = new StringBuilder();
        var yamls = 0;
        var problems = 0;
        foreach (var row in rows)
        {
            var parts = row.Split(Parity.Tab).Where(part => part.Length > 0).ToArray();
            if (parts.Length == 0) continue;
            var socksPort = parts.Length > 2 && SwiftInt.Parse(parts[2]) is { } port ? (int)port : 21180;
            produced.Append("=== ").Append(row).Append(Parity.LineFeed);
            try
            {
                var server = parts[0] == "server" ? ServerFromJson(parts[1]) : ShareLinkParser.Parse(parts[0]);
                foreach (var problem in HysteriaConfigBuilder.Validate(server))
                {
                    produced.Append("problem").Append(Parity.Tab).Append(problem).Append(Parity.LineFeed);
                    problems++;
                }
                var yaml = HysteriaConfigBuilder.MakeClientConfig(server, socksPort);
                produced.Append("yaml").Append(Parity.Tab)
                    .Append(Convert.ToBase64String(Encoding.UTF8.GetBytes(yaml))).Append(Parity.LineFeed);
                yamls++;
            }
            catch (ParseErrorException error)
            {
                produced.Append("error").Append(Parity.Tab).Append(Describe(error)).Append(Parity.LineFeed);
            }
            catch (ConfigBuilderException error)
            {
                produced.Append("error").Append(Parity.Tab).Append(error.Message).Append(Parity.LineFeed);
            }
        }

        Parity.Compare(produced.ToString(), Parity.Read(Folder, "links.golden.txt"), "hysteria YAML", floor: 40);
        Assert.True(yamls >= 25, "YAML построено: " + yamls);
        Assert.True(problems >= 5, "громко сказанных замечаний: " + problems);
    }

    private static ProxyServer ServerFromJson(string json) =>
        PersistedState.ProxyServerFromJson(JsonNode.Parse(json))
        ?? throw new ParseErrorException(ParseErrorKind.InvalidBase64, "bad server json");

    private static string Describe(ParseErrorException error) => error.Detail.Length == 0
        ? Name(error.Kind)
        : $"{Name(error.Kind)}(\"{error.Detail}\")";

    private static string Name(ParseErrorKind kind) => kind switch
    {
        ParseErrorKind.UnsupportedScheme => "unsupportedScheme",
        ParseErrorKind.MalformedUri => "malformedURI",
        ParseErrorKind.MissingField => "missingField",
        ParseErrorKind.InvalidBase64 => "invalidBase64",
        ParseErrorKind.EmptyInput => "emptyInput",
        ParseErrorKind.UnsupportedTransport => "unsupportedTransport",
        _ => kind.ToString(),
    };
}
