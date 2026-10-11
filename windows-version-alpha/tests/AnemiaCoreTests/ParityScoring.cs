using System.Globalization;
using System.Text;
using AnemiaCore;
using Xunit;

namespace AnemiaCoreTests;

/// <summary>
/// The ranker inputs. <c>score/histories.golden.txt</c> is Swift's own answer for
/// every history in the corpus — four numbers and a 25-wide feature vector, each
/// printed as an IEEE-754 bit pattern, because the last bit is exactly what
/// decides which exit a device picks and what the trainer learned on.
/// </summary>
public class ParityScoringTests
{
    private const string Folder = "score";

    [Fact]
    public void ScoresAndFeaturesMatchSwift()
    {
        var produced = new StringBuilder();
        var compared = 0;
        var sentinels = 0;
        foreach (var line in Parity.Lines(Parity.Read(Folder, "histories.txt")))
        {
            var history = ParseHistory(line);
            var features = KxcFeatures.Extract(history);
            if (ServerScoring.RankingScore(history) >= 100_000) sentinels++;
            produced.Append(line).Append(Parity.Tab)
                .Append("score=").Append(Bits(ServerScoring.RankingScore(history))).Append(Parity.Tab)
                .Append("avg=").Append(Bits(ServerScoring.AveragePing(history))).Append(Parity.Tab)
                .Append("stability=").Append(Bits(ServerScoring.Stability(history))).Append(Parity.Tab)
                .Append("kxc=").Append(string.Join(" ", features.Select(Bits))).Append(Parity.LineFeed);
            compared++;
        }

        Parity.Compare(produced.ToString(), Parity.Read(Folder, "histories.golden.txt"),
                       "ранжирование", floor: 38);
        Assert.True(sentinels >= 2, "историй без единой удачной пробы: " + sentinels);
    }

    /// <summary>The feature names, in model order. Cheap to check and the one
    /// place where a locale-sensitive format would silently rename a column.</summary>
    [Fact]
    public void FeatureNamesMatchTheModel()
    {
        var expected = Parity.Lines(Parity.Read(Folder, "names.golden.txt"));
        var actual = KxcFeatures.Names;
        Assert.Equal(expected.Count, actual.Count);
        for (var i = 0; i < expected.Count; i++)
            Assert.Equal(expected[i], actual[i]);
        Assert.Equal("f09", actual[9]);
    }

    /// <summary>`Float(text)` after a whitespace trim: ASCII grammar, and a
    /// history of `−1` means "this probe failed", not "negative latency".</summary>
    private static List<float> ParseHistory(string line) =>
        line.Split(',')
            .Select(part => Foundation.TrimFoundationSpaces(part))
            .Where(part => part.Length > 0)
            .Select(part => SwiftDouble.Parse(part))
            .Where(value => value is not null)
            .Select(value => (float)value!.Value)
            .ToList();

    private static string Bits(double value) =>
        BitConverter.DoubleToInt64Bits(value).ToString("x16", CultureInfo.InvariantCulture);
}
