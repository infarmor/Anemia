// kxc v4 trainer — run through Scripts/train-kxc.sh.
//
// kxc's job is to pick the server that will work best NEXT, not to describe
// the pings it has already seen. v2 (the conv net this replaces) was trained
// to reproduce the hand-built score of the visible window — at best an
// expensive copy of the heuristic the app falls back to. v4 forecasts the
// hand-built score of the next `horizon` probes from engineered history
// features (Sources/LoaderCore/KxcFeatures.swift), with a boosted tree
// ensemble trained here by CreateML: no Python, no downloads.
//
// The data is synthetic, generated with persistent server character — a
// flaky link stays flaky, a throttle step stays until it recovers, a block
// is sticky — and calibrated to the app's real probe history (TLS-handshake
// RTTs around 250–500 ms, ~1% loss, occasional dead servers). The scoreboard
// is honest: held-out synthetic data against the heuristic (naive-full), the
// heuristic over the recent tail (naive-recent) and the shipped model, plus a
// rolling-origin backtest on the real history file when there is one.
// `--install` refuses unless v4 beats every one of them.

import CoreML
import CreateML
import Foundation
import TabularData

// MARK: - Arguments

var arguments = CommandLine.arguments.dropFirst()
var repo = FileManager.default.currentDirectoryPath
var outDir = "/tmp/loader-build/kxc"
var install = false
var trainCount = 60_000
var validationCount = 15_000
while let arg = arguments.popFirst() {
    switch arg {
    case "--repo": repo = arguments.popFirst() ?? repo
    case "--out": outDir = arguments.popFirst() ?? outDir
    case "--install": install = true
    case "--train": trainCount = Int(arguments.popFirst() ?? "") ?? trainCount
    default:
        print("unknown argument \(arg)")
        exit(64)
    }
}
let out = URL(fileURLWithPath: outDir)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let horizon = KxcFeatures.horizon
let cap = KxcFeatures.scoreCap

// MARK: - Deterministic randomness

struct Rng {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
    mutating func uniform(_ a: Double, _ b: Double) -> Double { a + (b - a) * uniform() }
    /// Integer in [a, b).
    mutating func int(_ a: Int, _ b: Int) -> Int { a + Int(next() % UInt64(max(1, b - a))) }
    mutating func chance(_ p: Double) -> Bool { uniform() < p }
    mutating func normal() -> Double {
        let u1 = max(uniform(), 1e-12), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
    mutating func exponential(mean: Double) -> Double { -mean * log(max(uniform(), 1e-12)) }
}

// MARK: - Server simulator

enum Regime { case stable, noisy, bursty, step, recover, block }

/// One server's probe series (RTT ms, −1 = failed). The character — base
/// latency, jitter scale, loss scale — is drawn once and every regime
/// perturbs it; state changes (throttle steps, recoveries, blocks) persist
/// across regimes, so the past genuinely informs the future.
func simulateServer(length: Int, rng: inout Rng) -> [Float] {
    var base = min(1200, max(25, exp(log(240.0) + 0.5 * rng.normal())))
    let jitterFraction = rng.uniform(0.015, 0.2)
    let tier = rng.uniform()
    let characterLoss = tier < 0.72 ? rng.uniform(0, 0.02)
        : (tier < 0.94 ? rng.uniform(0.02, 0.15) : rng.uniform(0.15, 0.45))
    var jitter = base * jitterFraction
    var blocked = false
    var series = [Float](repeating: 0, count: length)
    var ar = 0.0
    var i = 0
    while i < length {
        let r = rng.uniform()
        let regime: Regime
        if blocked {
            regime = r < 0.2 ? .recover : .block
        } else if r < 0.30 { regime = .stable
        } else if r < 0.54 { regime = .noisy
        } else if r < 0.68 { regime = .bursty
        } else if r < 0.80 { regime = .step
        } else if r < 0.95 { regime = .recover
        } else { regime = .block }

        let lo = max(8, length / 10), hi = max(lo + 1, length / 2)
        let segment = min(length - i, rng.int(lo, hi))
        var segJitter = jitter, segLoss = characterLoss, trend = 0.0, gilbert = false
        switch regime {
        case .stable:
            segJitter = jitter * 0.25
            segLoss = characterLoss * 0.1
            trend = rng.uniform(-0.05, 0.05)
        case .noisy:
            segJitter = jitter * rng.uniform(0.8, 2.0)
            segLoss = min(0.6, characterLoss * rng.uniform(0.6, 2.0))
            trend = rng.uniform(-0.3, 0.8)
        case .bursty:
            segJitter = jitter * rng.uniform(0.6, 1.4)
            segLoss = min(0.6, characterLoss * rng.uniform(1.5, 3.5) + 0.03)
            gilbert = true
            trend = rng.uniform(-0.2, 0.5)
        case .step:
            base = min(1500, base + rng.uniform(40, 280))
            jitter = base * jitterFraction * rng.uniform(1.3, 2.5)
            segJitter = jitter
            segLoss = min(0.6, characterLoss * rng.uniform(0.8, 2))
            trend = rng.uniform(-0.2, 0.6)
        case .recover:
            blocked = false
            base = max(25, base * rng.uniform(0.45, 0.8))
            jitter = base * jitterFraction
            segJitter = jitter * 0.6
            segLoss = characterLoss * rng.uniform(0, 0.6)
            trend = rng.uniform(-1.2, -0.1)
        case .block:
            blocked = true
            segLoss = rng.uniform(0.9, 1.0)
        }
        var badState = false
        for k in 0..<segment {
            ar = 0.8 * ar + rng.normal() * segJitter * 0.6
            var v = base + trend * Double(k) + ar
            if rng.chance(0.015) { v += rng.exponential(mean: base * 0.7) }   // tail spikes
            let failed: Bool
            if gilbert {
                if rng.chance(0.25) { badState.toggle() }
                failed = rng.chance(badState ? min(1, segLoss * 1.6) : segLoss * 0.2)
            } else {
                failed = rng.chance(segLoss)
            }
            series[i + k] = failed ? -1 : Float(max(1, v))
        }
        i += segment
    }
    return series
}

// MARK: - Examples

struct Example {
    let past: [Float]
    let features: [Double]
    let truth: Double
    let naiveFull: Double
    let naiveRecent: Double
}

func example(past: [Float], future: [Float]) -> Example? {
    // The app never ranks a server without one successful probe.
    guard past.contains(where: { $0 >= 0 }) else { return nil }
    return Example(past: past,
                   features: KxcFeatures.extract(past),
                   truth: min(cap, ServerScoring.rankingScore(future)),
                   naiveFull: min(cap, ServerScoring.rankingScore(past)),
                   naiveRecent: min(cap, ServerScoring.rankingScore(Array(past.suffix(horizon)))))
}

func makeExamples(_ count: Int, seed: UInt64) -> [Example] {
    var rng = Rng(seed: seed)
    var examples: [Example] = []
    examples.reserveCapacity(count)
    while examples.count < count {
        let r = rng.uniform()
        let visible = r < 0.18 ? KxcFeatures.window : (r < 0.42 ? rng.int(8, 48) : rng.int(8, KxcFeatures.window + 1))
        let series = simulateServer(length: visible + horizon, rng: &rng)
        if let e = example(past: Array(series[..<visible]), future: Array(series[visible...])) {
            examples.append(e)
        }
    }
    return examples
}

// MARK: - Predictors

func predictV4(_ model: MLModel, _ rows: [[Double]]) throws -> [Double] {
    let providers: [MLFeatureProvider] = try rows.map { row in
        var dict: [String: MLFeatureValue] = [:]
        for (j, name) in KxcFeatures.names.enumerated() { dict[name] = MLFeatureValue(double: row[j]) }
        return try MLDictionaryFeatureProvider(dictionary: dict)
    }
    let result = try model.predictions(fromBatch: MLArrayBatchProvider(array: providers))
    return (0..<result.count).map { i in
        min(cap, max(0, expm1(result.features(at: i).featureValue(for: "target")?.doubleValue ?? 0)))
    }
}

/// The shipped conv model, fed exactly as CoreMLRanker.makeInput feeds it.
func predictGridModel(_ model: MLModel, _ pasts: [[Float]]) throws -> [Double] {
    let description = model.modelDescription
    guard let inName = description.inputDescriptionsByName.keys.first,
          let outName = description.outputDescriptionsByName.keys.first,
          let shape = description.inputDescriptionsByName[inName]?.multiArrayConstraint?.shape,
          shape.count == 4 else { throw NSError(domain: "kxc", code: 1) }
    let creator = description.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
    let decay = creator["kxc_decay"].flatMap(Double.init)
    let bias = creator["kxc_head_bias"].flatMap(Double.init)
    let channels = shape[1].intValue
    let window = shape[2].intValue * shape[3].intValue
    var results: [Double] = []
    results.reserveCapacity(pasts.count)
    for start in stride(from: 0, to: pasts.count, by: 512) {
        let slice = pasts[start..<min(pasts.count, start + 512)]
        let providers: [MLFeatureProvider] = try slice.map { past in
            let array = try MLMultiArray(shape: shape, dataType: .float32)
            let buffer = array.dataPointer.assumingMemoryBound(to: Float.self)
            buffer.update(repeating: 0, count: array.count)
            let recent = past.suffix(window)
            let pad = window - recent.count
            for (j, s) in recent.enumerated() {
                let t = pad + j
                buffer[t] = s >= 0 ? min(1, s / 300) : 0
                if channels > 1 { buffer[window + t] = s < 0 ? 1 : 0 }
                if channels > 2 { buffer[2 * window + t] = Float(pow(decay ?? 1, Double(recent.count - 1 - j))) }
            }
            return try MLDictionaryFeatureProvider(dictionary: [inName: MLFeatureValue(multiArray: array)])
        }
        let result = try model.predictions(fromBatch: MLArrayBatchProvider(array: providers))
        for (k, past) in slice.enumerated() {
            let raw = result.features(at: k).featureValue(for: outName)?.multiArrayValue?[0].doubleValue ?? 0
            let score = bias.map { raw / Double(max(1, min(past.count, window))) + $0 } ?? raw
            results.append(min(cap, max(0, score)))
        }
    }
    return results
}

// MARK: - Metrics

func meanAbsoluteError(_ p: [Double], _ y: [Double]) -> Double {
    zip(p, y).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(p.count)
}

/// Average ranks (ties share their mean rank).
func ranks(_ values: [Double]) -> [Double] {
    let order = values.indices.sorted { values[$0] < values[$1] }
    var result = [Double](repeating: 0, count: values.count)
    var i = 0
    while i < order.count {
        var j = i
        while j + 1 < order.count, values[order[j + 1]] == values[order[i]] { j += 1 }
        let rank = Double(i + j) / 2
        for k in i...j { result[order[k]] = rank }
        i = j + 1
    }
    return result
}

func spearman(_ a: [Double], _ b: [Double]) -> Double {
    let ra = ranks(a), rb = ranks(b)
    let n = Double(ra.count)
    let ma = ra.reduce(0, +) / n, mb = rb.reduce(0, +) / n
    var num = 0.0, da = 0.0, db = 0.0
    for i in ra.indices {
        num += (ra[i] - ma) * (rb[i] - mb)
        da += (ra[i] - ma) * (ra[i] - ma)
        db += (rb[i] - mb) * (rb[i] - mb)
    }
    return num / max((da * db).squareRoot(), 1e-12)
}

/// The decision the app actually makes: pick one server out of a list.
/// Regret = how much worse (future score) the pick is than the best in the
/// group; a miss = a pick more than 20% (and 30 points) worse than the best.
func pickQuality(_ predicted: [Double], _ truth: [Double], groupSize: Int = 10, groups: Int = 20_000) -> (regret: Double, miss: Double) {
    var rng = Rng(seed: 2026)
    var regret = 0.0, misses = 0
    for _ in 0..<groups {
        let group = (0..<groupSize).map { _ in rng.int(0, truth.count) }
        guard let pick = group.min(by: { predicted[$0] < predicted[$1] }),
              let best = group.map({ truth[$0] }).min() else { continue }
        let r = truth[pick] - best
        regret += r
        if r > max(30, best * 0.2) { misses += 1 }
    }
    return (regret / Double(groups), Double(misses) / Double(groups))
}

struct Score {
    let name: String
    let mae: Double
    let rho: Double
    let regret: Double
    let miss: Double
}

func score(_ name: String, _ predicted: [Double], _ truth: [Double], decisions: Bool = true) -> Score {
    let q = decisions ? pickQuality(predicted, truth) : (regret: .nan, miss: .nan)
    return Score(name: name, mae: meanAbsoluteError(predicted, truth), rho: spearman(predicted, truth),
                 regret: q.regret, miss: q.miss)
}

func printBoard(_ title: String, _ rows: [Score], count: Int) {
    print("\n\(title) (\(count) forecasts, horizon \(horizon) probes)")
    print("  predictor          MAE   spearman   pick regret   miss rate")
    for r in rows {
        let regret = r.regret.isNaN ? "        —" : String(format: "%9.1f", r.regret)
        let miss = r.miss.isNaN ? "       —" : String(format: "%7.1f%%", r.miss * 100)
        let name = r.name.padding(toLength: 15, withPad: " ", startingAt: 0)
        print("  " + name + String(format: "%7.1f   %8.3f   ", r.mae, r.rho) + regret + "     " + miss)
    }
}

// MARK: - Train

var clock = Date()
let train = makeExamples(trainCount, seed: 11)
let validation = makeExamples(validationCount, seed: 977)
print(String(format: "generated %d training + %d validation series in %.1f s",
             train.count, validation.count, Date().timeIntervalSince(clock)))

var frame = DataFrame()
for (j, name) in KxcFeatures.names.enumerated() {
    frame.append(column: Column<Double>(name: name, contents: train.map { $0.features[j] }))
}
// Log target: ranking cares about order across a 30…4000 range, and squared
// error on the raw scale would spend the whole model on the dead-server tail.
frame.append(column: Column<Double>(name: "target", contents: train.map { log1p($0.truth) }))

clock = Date()
let parameters = MLBoostedTreeRegressor.ModelParameters(
    validation: .none, maxDepth: 6, maxIterations: 500, minLossReduction: 0,
    minChildWeight: 8, randomSeed: 7, stepSize: 0.06, earlyStoppingRounds: nil,
    rowSubsample: 0.8, columnSubsample: 0.8)
let regressor = try MLBoostedTreeRegressor(trainingData: frame, targetColumn: "target",
                                           featureColumns: KxcFeatures.names, parameters: parameters)
print(String(format: "trained boosted trees in %.1f s (train rmse %.4f in log space)",
             Date().timeIntervalSince(clock), regressor.trainingMetrics.rootMeanSquaredError))

let modelURL = out.appendingPathComponent("kxc-v4.mlmodel")
try? FileManager.default.removeItem(at: modelURL)
try regressor.write(to: modelURL, metadata: MLModelMetadata(
    author: "Anemia",
    shortDescription: "kxc v4 — forecasts a server's next-\(horizon)-probe quality from its probe history",
    version: "4.0",
    additional: ["kxc_input": "features-v4", "kxc_target": "log1p", "kxc_version": "4",
                 "kxc_horizon": String(horizon), "kxc_features": String(KxcFeatures.count)]))
let compiledURL = out.appendingPathComponent("kxc.mlmodelc")
try? FileManager.default.removeItem(at: compiledURL)
try FileManager.default.moveItem(at: try MLModel.compileModel(at: modelURL), to: compiledURL)
let v4 = try MLModel(contentsOf: compiledURL)

// MARK: - Scoreboard

let truth = validation.map(\.truth)
var board = [
    score("heuristic", validation.map(\.naiveFull), truth),
    score("heuristic/tail", validation.map(\.naiveRecent), truth),
]
let previousURL = out.appendingPathComponent("kxc-previous.mlmodelc")
var previous: MLModel?
if FileManager.default.fileExists(atPath: previousURL.path) {
    previous = try MLModel(contentsOf: previousURL)
    board.append(score("kxc (shipped)", try predictGridModel(previous!, validation.map(\.past)), truth))
}
let v4Validation = try predictV4(v4, validation.map(\.features))
let v4Score = score("kxc v4", v4Validation, truth)
board.append(v4Score)
printBoard("synthetic hold-out", board, count: validation.count)

let wins = board.dropLast().allSatisfy { other in
    v4Score.mae < other.mae && v4Score.rho > other.rho && v4Score.regret < other.regret
}
print("\nKXC_V4_BEATS_ALL=\(wins ? "yes" : "NO")")

// MARK: - Real history backtest

let historyURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Loader/history.json")
if let data = try? Data(contentsOf: historyURL),
   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let series = object["series"] as? [String: [Double]] {
    var real: [Example] = []
    for values in series.values {
        let s = values.map(Float.init)
        guard s.count >= 16 + horizon else { continue }
        for t in stride(from: 16, through: s.count - horizon, by: 8) {
            if let e = example(past: Array(s[..<t]), future: Array(s[t..<(t + horizon)])) { real.append(e) }
        }
    }
    if real.count >= 8 {
        let realTruth = real.map(\.truth)
        var realBoard = [
            score("heuristic", real.map(\.naiveFull), realTruth, decisions: false),
            score("heuristic/tail", real.map(\.naiveRecent), realTruth, decisions: false),
        ]
        if let previous {
            realBoard.append(score("kxc (shipped)", try predictGridModel(previous, real.map(\.past)), realTruth, decisions: false))
        }
        realBoard.append(score("kxc v4", try predictV4(v4, real.map(\.features)), realTruth, decisions: false))
        printBoard("real probe history, rolling origins (\(series.count) servers; small sample — a sanity check)",
                   realBoard, count: real.count)
    } else {
        print("\nreal probe history: too short for a backtest (\(real.count) windows)")
    }
}

print("\nSAVED_OK \(compiledURL.path)")

// MARK: - Install

if install {
    guard wins else {
        print("INSTALL REFUSED: kxc v4 does not beat every baseline on MAE, Spearman and pick regret")
        exit(2)
    }
    let dest = URL(fileURLWithPath: repo).appendingPathComponent("Sources/LoaderApp/Resources/kxc.mlmodelc")
    try? FileManager.default.removeItem(at: dest)
    try FileManager.default.copyItem(at: compiledURL, to: dest)
    // iCloud-managed tree: scrub extended attributes so codesign accepts it.
    let xattr = Process()
    xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
    xattr.arguments = ["-cr", dest.path]
    try xattr.run()
    xattr.waitUntilExit()
    print("INSTALLED_OK \(dest.path)")
}
