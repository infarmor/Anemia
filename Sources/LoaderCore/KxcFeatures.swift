import Foundation

/// kxc v4's view of a server: a fixed vector of engineered features over its
/// probe history (RTT in ms, −1 = failed probe). The app scores with exactly
/// this code, and the trainer (Scripts/kxc) compiles this same file — what the
/// model learned on and what it sees in the app cannot drift apart.
///
/// The features separate what a single average blurs together: the level now
/// versus over the whole history, how loss is distributed (a recent burst, a
/// run of failures, a block that just started), dispersion and tail, drift,
/// and the hand-built scores themselves over the full and the recent window.
public enum KxcFeatures {
    public static let count = 25
    /// Input names in model order (`f00` … `f24`).
    public static let names: [String] = (0..<count).map { String(format: "f%02d", $0) }
    /// Samples considered (the app's HistoryStore keeps 256 per server).
    public static let window = 256
    /// Horizon of the forecast target, in probes.
    public static let horizon = 32
    /// Hand-built scores are capped here before they become features or
    /// targets: the 100 000 all-fail sentinel would otherwise swamp every split.
    public static let scoreCap = 4000.0
    /// Latency statistic for "no successful probe in this slice".
    static let deadRTT = 3000.0

    public static func extract(_ fullHistory: [Float]) -> [Double] {
        let h = Array(fullHistory.suffix(window))
        let n = h.count
        let valid = h.filter { $0 >= 0 }.map(Double.init)

        func lossRate(_ s: ArraySlice<Float>) -> Double {
            s.isEmpty ? 0 : Double(s.filter { $0 < 0 }.count) / Double(s.count)
        }
        func mean(_ x: [Double]) -> Double? {
            x.isEmpty ? nil : x.reduce(0, +) / Double(x.count)
        }
        func std(_ x: [Double], _ m: Double) -> Double {
            x.isEmpty ? 0 : (x.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(x.count)).squareRoot()
        }
        func median(_ x: [Double]) -> Double? {
            guard !x.isEmpty else { return nil }
            let s = x.sorted()
            return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        }

        // Loss: overall, recent, recency-weighted, and its shape.
        let lossAll = lossRate(h[...])
        let loss16 = lossRate(h.suffix(16))
        var ewLoss = 0.0, ewTotal = 0.0, w = 1.0
        for s in h.reversed() {
            ewLoss += s < 0 ? w : 0
            ewTotal += w
            w *= 0.9
        }
        let lossEW = ewTotal > 0 ? ewLoss / ewTotal : 0
        var longestRun = 0, runs = 0, run = 0
        for s in h.suffix(64) {
            if s < 0 {
                run += 1
                if run == 1 { runs += 1 }
                longestRun = max(longestRun, run)
            } else {
                run = 0
            }
        }
        let lastFailed: Double = (h.last ?? 0) < 0 ? 1 : 0
        let sinceFail = Double(h.reversed().firstIndex { $0 < 0 } ?? n)

        // Latency: level, spread, tail — overall and now.
        let sorted = valid.sorted()
        let meanAll = mean(valid) ?? deadRTT
        let medianAll = median(valid) ?? deadRTT
        let minAll = sorted.first ?? deadRTT
        let p90All = sorted.isEmpty ? deadRTT : sorted[Int((Double(sorted.count - 1) * 0.9).rounded())]
        let stdAll = std(valid, meanAll)
        let recent16 = h.suffix(16).filter { $0 >= 0 }.map(Double.init)
        let mean16 = mean(recent16) ?? meanAll
        let std16 = recent16.isEmpty ? stdAll : std(recent16, mean16)
        let mean4 = mean(Array(valid.suffix(4))) ?? meanAll

        // Recency-weighted level and absolute deviation over successful probes.
        var ewMean = 0.0, ewWeight = 0.0
        w = 1.0
        for x in valid.reversed() {
            ewMean += w * x
            ewWeight += w
            w *= 0.85
        }
        ewMean = ewWeight > 0 ? ewMean / ewWeight : deadRTT
        var ewDev = 0.0
        w = 1.0
        for x in valid.reversed() {
            ewDev += w * abs(x - ewMean)
            w *= 0.85
        }
        ewDev = ewWeight > 0 ? ewDev / ewWeight : 0

        // Drift and level shifts.
        let slopeAll = ServerScoring.slope(valid)
        let slope32 = ServerScoring.slope(h.suffix(32).filter { $0 >= 0 }.map(Double.init))
        let recentOverAll = mean16 / max(meanAll, 1)
        let prior = h.dropLast(16).filter { $0 >= 0 }.map(Double.init)
        let levelShift = (median(recent16) ?? mean16) - (median(prior) ?? medianAll)

        // The hand-built views, as features the trees can correct.
        let scoreAll = min(scoreCap, ServerScoring.rankingScore(h))
        let score32 = min(scoreCap, ServerScoring.rankingScore(Array(h.suffix(horizon))))
        let stability = ServerScoring.stability(h)

        return [
            Double(n), lossAll, loss16, lossEW, Double(longestRun),
            Double(runs), meanAll, medianAll, minAll, p90All,
            stdAll, mean16, std16, mean4, ewMean,
            ewDev, slopeAll, slope32, recentOverAll, scoreAll,
            score32, stability, lastFailed, min(sinceFail, Double(window)), levelShift,
        ]
    }
}
