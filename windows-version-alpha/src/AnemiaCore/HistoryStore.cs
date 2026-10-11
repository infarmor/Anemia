using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AnemiaCore;

/// <summary>
/// Persists a rolling per-server ping history (RTT ms; a failed probe is -1)
/// across launches, so the ranker's temporal model has a real time-series to
/// read.
/// The file is versioned by *probe methodology*. When the way latency is
/// measured changes, the old series are on a different scale and would corrupt
/// averages and the model. Bumping <see cref="Schema"/> makes Load discard any
/// file that isn't on the current methodology.
/// </summary>
public sealed class HistoryStore
{
    private readonly int _maxSamples;

    /// <summary>2 = TLS-handshake latencies. (1 = the legacy TCP-connect era, discarded.)</summary>
    public const int Schema = 2;

    public string FilePath { get; }

    public HistoryStore(int maxSamples = 256)
    {
        var baseDir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        if (string.IsNullOrEmpty(baseDir)) baseDir = Environment.CurrentDirectory;
        FilePath = Path.Combine(baseDir, "Anemia", "history.json");
        _maxSamples = maxSamples;
    }

    public Dictionary<string, List<float>> Load()
    {
        try
        {
            var data = File.ReadAllBytes(FilePath);
            var node = JsonNode.Parse(data);
            if (node is not JsonObject obj) return new();
            if (obj["schema"] is not JsonValue v || !v.TryGetValue<int>(out var schema) || schema != Schema)
                return new();
            var series = new Dictionary<string, List<float>>();
            if (obj["series"] is JsonObject seriesObj)
            {
                foreach (var (key, val) in seriesObj)
                {
                    if (val is not JsonArray arr) continue;
                    var samples = arr.OfType<JsonValue>()
                        .Select(static j => j.TryGetValue<float>(out var f) ? f : 0f)
                        .ToList();
                    series[key] = samples;
                }
            }
            return series;
        }
        catch (FileNotFoundException)
        {
            return new();
        }
        catch (DirectoryNotFoundException)
        {
            return new();
        }
        catch (IOException)
        {
            return new();
        }
        catch (JsonException)
        {
            // Legacy bare-dictionary file (pre-versioning, TCP era): discard it
            // so stale near-zero samples can't leak into the new TLS-based
            // rankings.
            return new();
        }
    }

    public void Save(Dictionary<string, List<float>> history)
    {
        try
        {
            var series = new JsonObject();
            foreach (var (key, samples) in history)
            {
                // Cap each series to the most recent maxSamples.
                var capped = samples.Skip(Math.Max(0, samples.Count - _maxSamples));
                var arr = new JsonArray();
                foreach (var f in capped) arr.Add(f);
                series[key] = arr;
            }
            var env = new JsonObject { ["schema"] = Schema, ["series"] = series };
            var dir = Path.GetDirectoryName(FilePath);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            File.WriteAllText(FilePath, env.ToJsonString(new JsonSerializerOptions { WriteIndented = false }));
        }
        catch (IOException)
        {
            // best effort — history is advisory data
        }
    }
}