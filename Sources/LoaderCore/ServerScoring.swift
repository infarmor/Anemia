import Foundation

/// The hand-built server scores, over a chronological probe history (RTT in
/// ms; a failed probe is stored as −1). Shared by the app and by the kxc
/// trainer (Scripts/kxc), where `rankingScore` defines how good a window of
/// probes *was* — the quantity kxc learns to forecast for the next window.
public enum ServerScoring {
    /// "Badness", lower is better: best/average latency, jitter (weighted more
    /// at high latency), the worst-case tail, packet loss (super-linear) and a
    /// rising-latency trend. A window without one successful probe scores the
    /// 100 000 sentinel.
    public static func rankingScore(_ history: [Float]) -> Double {
        let v = history.filter { $0 >= 0 }.map(Double.init)
        guard !v.isEmpty else { return 100_000 }
        let mean = v.reduce(0, +) / Double(v.count)
        let mn = v.min() ?? mean
        let mx = v.max() ?? mean
        // x·x rather than pow(x, 2): libm and the JVM disagree in the last bit
        // for some values, and this term feeds both the ranking score and the
        // kxc features.
        let std = (v.map { let d = $0 - mean; return d * d }.reduce(0, +) / Double(v.count)).squareRoot()
        let loss = Double(history.count - v.count) / Double(history.count)
        let trend = slope(v)
        return 0.6 * mean + 0.4 * mn
             + std * (1 + mean / 200)
             + max(0, mx - mean) * 0.3
             + 1000 * loss * (1 + loss)
             + max(0, trend) * Double(v.count) * 0.5
    }

    /// Linear-regression slope of a series (units per step); positive = worsening.
    public static func slope(_ y: [Double]) -> Double {
        let n = y.count
        guard n > 1 else { return 0 }
        let mx = Double(n - 1) / 2
        let my = y.reduce(0, +) / Double(n)
        var num = 0.0, den = 0.0
        for i in 0..<n {
            let dx = Double(i) - mx
            num += dx * (y[i] - my)
            den += dx * dx
        }
        return den == 0 ? 0 : num / den
    }

    /// Plain average RTT (ranking with ML switched off).
    public static func averagePing(_ history: [Float]) -> Double {
        let ok = history.filter { $0 >= 0 }
        guard !ok.isEmpty else { return 100_000 }
        return Double(ok.reduce(0, +)) / Double(ok.count)
    }

    /// Stability in [0, 1] — how *dependable* a server is, independent of how
    /// fast it is. High only when losses are rare, jitter is low and latency
    /// isn't drifting upward; the factors multiply, so one bad trait sinks the
    /// score. Recency-weighted, so a server that has just started dropping
    /// packets scores low immediately instead of hiding behind a clean past.
    public static func stability(_ history: [Float]) -> Double {
        let h = history
        guard !h.isEmpty else { return 0 }
        let decay = 0.94
        let n = h.count
        var wTotal = 0.0, wLoss = 0.0, wValid = 0.0, wSum = 0.0
        var weights = [Double](repeating: 0, count: n)
        // `decay` raised by repeated multiplication rather than `pow(decay, k)`:
        // a transcendental is the one place where two correct math libraries
        // disagree in the last bits, and this score feeds the ranker, so the
        // number a phone computes must be the number a Mac computed.
        var weight = 1.0
        for i in stride(from: n - 1, through: 0, by: -1) {
            weights[i] = weight
            weight *= decay
        }
        for i in 0..<n {
            let w = weights[i]
            wTotal += w
            if h[i] < 0 { wLoss += w } else { wValid += w; wSum += w * Double(h[i]) }
        }
        let loss = wTotal > 0 ? wLoss / wTotal : 1
        // x·√x rather than pow(x, 1.5) — see the note on `weights`: only
        // correctly-rounded operations are the same number on every platform.
        let spare = max(0, 1 - loss)
        let lossTerm = spare * spare.squareRoot()
        guard wValid > 0 else { return 0 }
        let mean = wSum / wValid
        var wVar = 0.0
        for i in 0..<n where h[i] >= 0 { let d = Double(h[i]) - mean; wVar += weights[i] * d * d }
        let std = (wVar / wValid).squareRoot()
        let cv = mean > 0 ? std / mean : 1
        let valid = h.filter { $0 >= 0 }.map(Double.init)
        let drift = valid.count >= 2 ? max(0, slope(valid)) / max(mean, 1) : 0
        let jitterTerm = 1 / (1 + 4 * cv)
        let driftTerm = 1 / (1 + 8 * drift)
        let product = lossTerm * jitterTerm * driftTerm
        // A non-finite history (inf samples, NaN in the sums) used to read as
        // perfectly stable: `min(1, NaN)` is 1 in Swift while the JVM's
        // `minOf` yields NaN — two different wrong answers. Both sides now
        // answer 0: no measurement, no stability credit.
        guard product.isFinite else { return 0 }
        return max(0, min(1, product))
    }
}
