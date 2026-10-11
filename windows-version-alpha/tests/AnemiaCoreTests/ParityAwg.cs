using System.Text;
using AnemiaCore;
using Xunit;

namespace AnemiaCoreTests;

/// <summary>
/// AmneziaWG parity against the goldens <c>LoaderTool awg-uapi</c> wrote from the
/// Swift builder: every wg-quick conf under <c>awg/</c> becomes a UAPI
/// <c>set=1</c> script, and a script that differs by one key is a tunnel that
/// works on the Mac and not on the PC.
///
/// The validator output is compared too (<c>*.problems.txt</c>), because half of
/// those fixtures exist to be refused — a port that accepts them builds a config
/// the daemon drops packets from without saying so.
/// </summary>
public class ParityAwgTests
{
    private const string Folder = "awg";

    [Fact]
    public void UapiScriptsMatchSwift()
    {
        var directory = System.IO.Path.Combine(Parity.Fixtures, Folder);
        var confs = System.IO.Directory.GetFiles(directory, "*.conf").OrderBy(name => name, StringComparer.Ordinal).ToList();
        Assert.NotEmpty(confs);

        var compared = 0;
        var diffs = new List<string>();
        foreach (var conf in confs)
        {
            var stem = System.IO.Path.GetFileNameWithoutExtension(conf);
            var golden = System.IO.Path.Combine(directory, stem + ".uapi");
            Assert.True(System.IO.File.Exists(golden), "нет эталона " + golden);

            var server = WireGuardLink.ParseConfigText(System.IO.File.ReadAllText(conf, Encoding.UTF8));
            var actual = AmneziaWgConfigBuilder.MakeUapiSetScript(server);
            var expected = System.IO.File.ReadAllText(golden, Encoding.UTF8);
            if (actual.TrimEnd() != expected.TrimEnd())
            {
                diffs.Add(stem + ".conf:\n" + FirstDiff(expected, actual));
            }
            compared++;
        }

        // Ни один парный эталон не должен висеть без конфига: иначе проверка
        // тихо весела бы ровно на число потерянных файлов.
        var names = confs.Select(stem => System.IO.Path.GetFileNameWithoutExtension(stem)).ToHashSet(StringComparer.Ordinal);
        var orphans = System.IO.Directory.GetFiles(directory, "*.uapi")
            .Concat(System.IO.Directory.GetFiles(directory, "*.problems.txt"))
            .Select(name => System.IO.Path.GetFileName(name))
            .Where(name => name != "links.uapi")
            .Select(name => name.EndsWith(".uapi")
                ? name[..^".uapi".Length]
                : name[..^".problems.txt".Length])
            .Where(stem => !names.Contains(stem))
            .ToList();

        Assert.True(diffs.Count == 0, string.Join("\n", diffs));
        Assert.Empty(orphans);
        Assert.True(compared >= 10, "конфигов сверено: " + compared);
    }

    /// <summary>What the validator and the warning pass say about each conf —
    /// the same lines <c>golden-awg-problems.sh</c> captured from stderr.</summary>
    [Fact]
    public void ValidatorProblemsMatchSwift()
    {
        var directory = System.IO.Path.Combine(Parity.Fixtures, Folder);
        var confs = System.IO.Directory.GetFiles(directory, "*.conf").OrderBy(name => name, StringComparer.Ordinal).ToList();
        var compared = 0;
        var withProblems = 0;
        var diffs = new List<string>();
        foreach (var conf in confs)
        {
            var stem = System.IO.Path.GetFileNameWithoutExtension(conf);
            var goldenPath = System.IO.Path.Combine(directory, stem + ".problems.txt");
            if (!System.IO.File.Exists(goldenPath)) continue;
            var server = WireGuardLink.ParseConfigText(System.IO.File.ReadAllText(conf, Encoding.UTF8));
            var lines = AmneziaWgConfigBuilder.Validate(server)
                .Select(problem => "problem: " + problem)
                .Concat(AmneziaWgConfigBuilder.Warnings(server).Select(warning => "warning: " + warning))
                .ToList();
            if (lines.Count > 0) withProblems++;
            var expected = System.IO.File.ReadAllText(goldenPath, Encoding.UTF8).TrimEnd();
            var actual = string.Join("\n", lines);
            if (actual.TrimEnd() != expected)
                diffs.Add(stem + ": ожидалось\n" + expected + "\n— получено\n" + actual);
            compared++;
        }
        Assert.True(diffs.Count == 0, string.Join("\n\n", diffs));
        Assert.True(compared >= 10, "замечания сверено для: " + compared);
        Assert.True(withProblems >= 3, "конфигов с замечаниями: " + withProblems);
    }

    /// <summary>Servers that arrive as links — the path the live app actually
    /// uses, where the profile comes from a query string or a base64 conf and
    /// the endpoint is a host name rather than the conf's own.</summary>
    [Fact]
    public void UapiForLinkedServersMatchesSwift()
    {
        var rows = Parity.Lines(Parity.Read(Folder, "links.txt"));
        var blocks = ReadBlocks(Parity.Read(Folder, "links.uapi"));
        Assert.Equal(rows.Count, blocks.Count);

        var refused = 0;
        var diffs = new List<string>();
        foreach (var row in rows)
        {
            var label = row.Split(Parity.Tab)[0];
            var link = row.Contains(Parity.Tab) ? row[(row.IndexOf(Parity.Tab) + 1)..] : "";
            var want = blocks[label].TrimEnd();
            string actual;
            try
            {
                actual = AmneziaWgConfigBuilder.MakeUapiSetScript(ShareLinkParser.Parse(link)).TrimEnd();
            }
            catch (ParseErrorException error)
            {
                refused++;
                actual = "error: " + Describe(error).TrimEnd();
            }
            if (actual != want)
                diffs.Add(label + ": ожидалось\n" + want + "\n— получено\n" + actual);
        }
        Assert.True(diffs.Count == 0, string.Join("\n\n", diffs));
        Assert.True(refused >= 4, "ссылок, которые порт отвергает, — это тоже эталон: " + refused);
    }

    /// <summary>Swift's `errorDescription` shape for a parse error, which is what
    /// the golden captured on stderr.</summary>
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

    /// <summary>`=== label` starts a block; its body is the bare script (or the
    /// single `error: ` line), so it cannot be split on tabs like the other
    /// goldens.</summary>
    private static Dictionary<string, string> ReadBlocks(string text)
    {
        var blocks = new Dictionary<string, string>(StringComparer.Ordinal);
        string? current = null;
        var body = new StringBuilder();
        foreach (var line in Parity.Split(text))
        {
            if (line.StartsWith("=== ", StringComparison.Ordinal))
            {
                if (current is not null) blocks[current] = body.ToString();
                current = line[4..];
                body = new StringBuilder();
                continue;
            }
            if (current is null) continue;
            body.Append(line).Append(Parity.LineFeed);
        }
        if (current is not null) blocks[current] = body.ToString();
        return blocks;
    }

    private static string FirstDiff(string expected, string actual)
    {
        var want = Parity.Split(expected);
        var got = Parity.Split(actual);
        var builder = new StringBuilder();
        for (var i = 0; i < Math.Max(want.Length, got.Length); i++)
        {
            var left = i < want.Length ? want[i] : "<нет>";
            var right = i < got.Length ? got[i] : "<нет>";
            if (left == right) continue;
            builder.Append("  строка ").Append(i + 1)
                .Append(": swift=").Append(left).Append(" csharp=").Append(right).Append('\n');
            if (builder.Length > 400) break;
        }
        return builder.ToString();
    }
}
