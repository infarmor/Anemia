namespace AnemiaCore;

/// <summary>
/// The hand-built server scores over a chronological probe history (RTT in ms,
/// a failed probe stored as −1). Port of <c>Sources/LoaderCore/ServerScoring.swift</c>.
///
/// The arithmetic is written the way it is because two correct math libraries
/// disagree in the last bits: <c>pow(x, 2)</c> and <c>pow(decay, k)</c> differ
/// between libSystem and the JVM by up to 2 ULP, and this number decides which
/// exit a phone picks. Only repeated multiplication, square roots and correctly
/// rounded operations are the same value on every platform, so they are the only
/// ones used here — <c>Math.Pow</c> would be "cleaner" and would rank differently.
/// </summary>
public static class ServerScoring
{
    /// <summary>"Badness", lower is better: best/average latency, jitter
    /// (weighted more at high latency), the worst-case tail, packet loss
    /// (super-linear) and a rising-latency trend. A window without one
    /// successful probe scores the 100 000 sentinel.</summary>
    public static double RankingScore(IReadOnlyList<float> history)
    {
        var v = Positive(history).Select(sample => (double)sample).ToList();
        if (v.Count == 0) return 100_000;
        var mean = v.Sum() / v.Count;
        var mn = v.Min();
        var mx = v.Max();
        var std = Math.Sqrt(v.Sum(d => { var diff = d - mean; return diff * diff; }) / v.Count);
        var loss = (double)(history.Count - v.Count) / history.Count;
        var trend = Slope(v);
        return 0.6 * mean + 0.4 * mn
            + std * (1 + mean / 200)
            + Math.Max(0, mx - mean) * 0.3
            + 1000 * loss * (1 + loss)
            + Math.Max(0, trend) * v.Count * 0.5;
    }

    /// <summary>Linear-regression slope of a series (units per step); positive
    /// means worsening.</summary>
    public static double Slope(IReadOnlyList<double> y)
    {
        var n = y.Count;
        if (n <= 1) return 0;
        var mx = (double)(n - 1) / 2;
        var my = y.Sum() / n;
        double num = 0, den = 0;
        for (var i = 0; i < n; i++)
        {
            var dx = i - mx;
            num += dx * (y[i] - my);
            den += dx * dx;
        }
        return den == 0 ? 0 : num / den;
    }

    /// <summary>Plain average RTT (ranking with the model switched off). Summed
    /// in <c>float</c> on both sides on purpose: a <c>double</c> would be
    /// "better" and would rank differently.</summary>
    public static double AveragePing(IReadOnlyList<float> history)
    {
        var ok = Positive(history);
        if (ok.Count == 0) return 100_000;
        return (double)ok.Sum() / ok.Count;
    }

    /// <summary>Stability in [0, 1] — how dependable a server is, regardless of
    /// how fast. High only when losses are rare, jitter is low and latency is
    /// not drifting upward; the factors multiply, so one bad trait sinks the
    /// score. Recency-weighted, so a server that has just started dropping
    /// packets scores low at once instead of hiding behind a clean past.</summary>
    public static double Stability(IReadOnlyList<float> history)
    {
        var h = history;
        if (h.Count == 0) return 0;
        const double decay = 0.94;
        var n = h.Count;
        double wTotal = 0, wLoss = 0, wValid = 0, wSum = 0;
        var weights = new double[n];
        var weight = 1.0;
        for (var i = n - 1; i >= 0; i--)
        {
            weights[i] = weight;
            weight *= decay;
        }
        for (var i = 0; i < n; i++)
        {
            var w = weights[i];
            wTotal += w;
            if (h[i] < 0) wLoss += w;
            else { wValid += w; wSum += w * h[i]; }
        }
        var loss = wTotal > 0 ? wLoss / wTotal : 1;
        var spare = Math.Max(0, 1 - loss);
        // x·√x rather than pow(x, 1.5) — see the note on the weights.
        var lossTerm = spare * Math.Sqrt(spare);
        if (wValid <= 0) return 0;
        var mean = wSum / wValid;
        var wVar = 0.0;
        for (var i = 0; i < n; i++)
        {
            if (h[i] < 0) continue;
            var d = (double)h[i] - mean;
            wVar += weights[i] * d * d;
        }
        var std = Math.Sqrt(wVar / wValid);
        var cv = mean > 0 ? std / mean : 1;
        var valid = Positive(h).Select(sample => (double)sample).ToList();
        var drift = valid.Count >= 2 ? Math.Max(0, Slope(valid)) / Math.Max(mean, 1) : 0;
        var jitterTerm = 1 / (1 + 4 * cv);
        var driftTerm = 1 / (1 + 8 * drift);
        var product = lossTerm * jitterTerm * driftTerm;
        // A non-finite history (inf samples, NaN in the sums) used to read as
        // perfectly stable — `min(1, NaN)` is 1 in Swift while the JVM yields
        // NaN. Both answer 0 now: no measurement, no stability credit.
        if (!double.IsFinite(product)) return 0;
        return Math.Max(0, Math.Min(1, product));
    }

    private static List<float> Positive(IReadOnlyList<float> history) =>
        history.Where(sample => sample >= 0).ToList();
}

/// <summary>
/// kxc v4's view of a server: a fixed vector of engineered features over its
/// probe history. Port of <c>Sources/LoaderCore/KxcFeatures.swift</c>, which the
/// macOS trainer compiles as the same file — what the model learned on and what
/// it sees in the app cannot drift apart. Windows has no ranker model yet, but
/// the features are the shared definition of "the shape of a history", and
/// <c>score/histories.golden.txt</c> prints all 25 of them.
/// </summary>
public static class KxcFeatures
{
    public const int Count = 25;
    public const int Window = 256;
    public const int Horizon = 32;
    public const double ScoreCap = 4000.0;
    private const double DeadRtt = 3000.0;

    /// <summary>Input names in model order (<c>f00</c> … <c>f24</c>). The golden
    /// of its own file checks this list, because a JVM would print «f0» for a
    /// locale-sensitive formatter and the trainer's column names would move.</summary>
    public static List<string> Names { get; } = Enumerable.Range(0, Count)
        .Select(index => "f" + index.ToString("00", System.Globalization.CultureInfo.InvariantCulture))
        .ToList();

    public static List<double> Extract(IReadOnlyList<float> fullHistory)
    {
        var h = fullHistory.Count > Window
            ? fullHistory.Skip(fullHistory.Count - Window).ToList()
            : fullHistory.ToList();
        var n = h.Count;
        var valid = h.Where(sample => sample >= 0).Select(sample => (double)sample).ToList();

        double LossRate(IReadOnlyList<float> slice) =>
            slice.Count == 0 ? 0 : (double)slice.Count(sample => sample < 0) / slice.Count;
        double? Mean(IReadOnlyList<double> x) => x.Count == 0 ? null : x.Sum() / x.Count;
        double Std(IReadOnlyList<double> x, double m) =>
            x.Count == 0 ? 0 : Math.Sqrt(x.Sum(d => (d - m) * (d - m)) / x.Count);
        double? Median(IReadOnlyList<double> x)
        {
            if (x.Count == 0) return null;
            var s = x.OrderBy(value => value).ToList();
            return s.Count % 2 == 1
                ? s[s.Count / 2]
                : (s[s.Count / 2 - 1] + s[s.Count / 2]) / 2;
        }

        var lossAll = LossRate(h);
        var loss16 = LossRate(Tail(h, 16));
        double ewLoss = 0, ewTotal = 0, w = 1;
        for (var i = n - 1; i >= 0; i--)
        {
            ewLoss += h[i] < 0 ? w : 0;
            ewTotal += w;
            w *= 0.9;
        }
        var lossEW = ewTotal > 0 ? ewLoss / ewTotal : 0;
        int longestRun = 0, runs = 0, run = 0;
        foreach (var sample in Tail(h, 64))
        {
            if (sample < 0)
            {
                run += 1;
                if (run == 1) runs += 1;
                longestRun = Math.Max(longestRun, run);
            }
            else run = 0;
        }
        var lastFailed = (h.Count == 0 ? 0f : h[^1]) < 0 ? 1.0 : 0.0;
        var sinceFailIndex = -1;
        for (var i = n - 1; i >= 0; i--)
            if (h[i] < 0) { sinceFailIndex = n - 1 - i; break; }
        var sinceFail = (double)(sinceFailIndex < 0 ? n : sinceFailIndex);

        var sorted = valid.OrderBy(value => value).ToList();
        var meanAll = Mean(valid) ?? DeadRtt;
        var medianAll = Median(valid) ?? DeadRtt;
        var minAll = sorted.Count > 0 ? sorted[0] : DeadRtt;
        var p90All = sorted.Count == 0
            ? DeadRtt
            : sorted[(int)Math.Round((sorted.Count - 1) * 0.9, MidpointRounding.AwayFromZero)];
        var stdAll = Std(valid, meanAll);
        var recent16 = Tail(h, 16).Where(sample => sample >= 0).Select(sample => (double)sample).ToList();
        var mean16 = Mean(recent16) ?? meanAll;
        var std16 = recent16.Count == 0 ? stdAll : Std(recent16, mean16);
        var mean4 = Mean(Tail(valid, 4)) ?? meanAll;

        double ewMean = 0, ewWeight = 0;
        w = 1;
        for (var i = valid.Count - 1; i >= 0; i--)
        {
            ewMean += w * valid[i];
            ewWeight += w;
            w *= 0.85;
        }
        ewMean = ewWeight > 0 ? ewMean / ewWeight : DeadRtt;
        double ewDev = 0;
        w = 1;
        for (var i = valid.Count - 1; i >= 0; i--)
        {
            ewDev += w * Math.Abs(valid[i] - ewMean);
            w *= 0.85;
        }
        ewDev = ewWeight > 0 ? ewDev / ewWeight : 0;

        var slopeAll = ServerScoring.Slope(valid);
        var slope32 = ServerScoring.Slope(Tail(h, 32).Where(sample => sample >= 0).Select(sample => (double)sample).ToList());
        var recentOverAll = mean16 / Math.Max(meanAll, 1);
        var prior = h.Take(Math.Max(0, h.Count - 16)).Where(sample => sample >= 0).Select(sample => (double)sample).ToList();
        var levelShift = (Median(recent16) ?? mean16) - (Median(prior) ?? medianAll);

        var scoreAll = Math.Min(ScoreCap, ServerScoring.RankingScore(h));
        var score32 = Math.Min(ScoreCap, ServerScoring.RankingScore(Tail(h, Horizon)));
        var stability = ServerScoring.Stability(h);

        return new List<double>
        {
            n, lossAll, loss16, lossEW, longestRun,
            runs, meanAll, medianAll, minAll, p90All,
            stdAll, mean16, std16, mean4, ewMean,
            ewDev, slopeAll, slope32, recentOverAll, scoreAll,
            score32, stability, lastFailed, Math.Min(sinceFail, Window), levelShift,
        };
    }

    private static List<T> Tail<T>(IReadOnlyList<T> source, int count) =>
        source.Count <= count ? source.ToList() : source.Skip(source.Count - count).ToList();
}
