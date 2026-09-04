import Foundation
import CoreML

/// Live ping status for a server, surfaced in the UI.
enum PingResult: Equatable, Sendable {
    case measuring
    case ms(Int)
    case failed

    var value: Int? { if case .ms(let v) = self { return v } else { return nil } }
}

/// Per-server latency features: a chronological RTT history (ms; a failed probe
/// is stored as -1). Both the heuristic and the kxc model score this series, so
/// they see trends and loss bursts — not just a single average.
struct ServerFeatures: Sendable, Equatable {
    var history: [Float]

    var validRTTs: [Double] { history.filter { $0 >= 0 }.map(Double.init) }
    var attempts: Int { history.count }
}

/// Ranks servers by a "badness" score — lower is better.
///
/// `score` is async so the neural-engine inference never blocks the caller:
/// the app keeps its UI, tunnel setup, and packet path fully responsive while
/// kxc scores server histories on the ANE.
protocol ServerRanker: Sendable {
    func score(_ f: ServerFeatures) async -> Double
    var backend: String { get }
}

/// The exact scoring target kxc is trained on, and the fallback when the model
/// isn't available. Considers best/average latency, jitter (weighted more at
/// high latency), worst-case tail, packet loss (super-linear), and — the
/// temporal part — a rising-latency trend.
func rankingScore(_ f: ServerFeatures) -> Double {
    let v = f.validRTTs
    guard !v.isEmpty else { return 100_000 }
    let mean = v.reduce(0, +) / Double(v.count)
    let mn = v.min() ?? mean
    let mx = v.max() ?? mean
    let std = (v.map { pow($0 - mean, 2) }.reduce(0, +) / Double(v.count)).squareRoot()
    let loss = f.attempts > 0 ? Double(f.attempts - v.count) / Double(f.attempts) : 0
    let trend = slope(v)
    return 0.6 * mean + 0.4 * mn
         + std * (1 + mean / 200)
         + max(0, mx - mean) * 0.3
         + 1000 * loss * (1 + loss)
         + max(0, trend) * Double(v.count) * 0.5
}

/// Linear-regression slope of a series (ms per step); positive = worsening.
private func slope(_ y: [Double]) -> Double {
    let n = y.count
    guard n > 1 else { return 0 }
    let xs = (0..<n).map(Double.init)
    let mx = xs.reduce(0, +) / Double(n)
    let my = y.reduce(0, +) / Double(n)
    var num = 0.0, den = 0.0
    for i in 0..<n { num += (xs[i] - mx) * (y[i] - my); den += pow(xs[i] - mx, 2) }
    return den == 0 ? 0 : num / den
}

/// Plain average RTT (used when ML ranking is switched off in settings).
func averagePingScore(_ history: [Float]) -> Double {
    let ok = history.filter { $0 >= 0 }
    guard !ok.isEmpty else { return 100_000 }
    return Double(ok.reduce(0, +)) / Double(ok.count)
}

struct HeuristicRanker: ServerRanker {
    var backend: String { "heuristic" }
    func score(_ f: ServerFeatures) async -> Double { rankingScore(f) }
}

/// "kxc" — a temporal convolutional network that reads a server's ping history.
/// Shipped as an fp16 mlprogram with static shapes so Core ML runs its conv
/// stack on the Apple Neural Engine.
///
/// Lifecycle (never blocks anything):
///  * `init` only schedules the model load on a background task — first-run
///    ANE compilation can take seconds, so the app starts instantly and
///    scores with the heuristic until kxc is ready.
///  * Loading retries with backoff; if the bundle is absent or the model
///    fails repeatedly, kxc stays in `unavailable` and the heuristic is used.
///  * Core ML persists its ANE-compile cache under ~/Library/Caches, so a
///    relaunch (including a system-driven restart) loads in milliseconds.
///  * Predictions use the async Core ML API and run entirely off the main
///    actor — inference never touches the tunnel/packet path.
final class CoreMLRanker: ServerRanker, @unchecked Sendable {
    static let name = "kxc"

    private enum LoadState {
        case loading
        case ready(MLModel)
        case unavailable
    }

    private let lock = NSLock()
    private var state: LoadState = .loading
    private let modelURL: URL?
    private var inputName: String?
    private var outputName: String?
    /// [1, C, H, W] — the ANE-friendly grid layout kxc trains on.
    private var inputShape: [NSNumber]?
    /// Legacy path for division-free exports (kxc_head_bias metadata): the
    /// graph emitted `Wh·maskedSum` and the host completed the masked mean:
    ///   score = raw / max(sampleCount, 1) + headBias.
    /// Current models divide in-graph (real_div lands on the ANE at CH≥128)
    /// and carry no metadata — score is read straight from the output.
    private var headBias: Double?

    private let fallback = HeuristicRanker()

    /// Human-readable status for the settings pane.
    var status: String {
        switch loadedState {
        case .loading:      return "loading…"
        case .ready:        return "kxc (CoreML)"
        case .unavailable:  return modelURL == nil
            ? "heuristic (kxc not bundled)"
            : "heuristic (kxc failed to load)"
        }
    }

    var isLoaded: Bool {
        if case .ready = loadedState { return true }
        return false
    }

    var backend: String { status }

    private var loadedState: LoadState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    init() {
        modelURL = Bundle.module.url(forResource: "kxc", withExtension: "mlmodelc")
        guard let modelURL else {
            lock.lock(); state = .unavailable; lock.unlock()
            return
        }
        // Load off the main actor: MLModel(contentsOf:) may trigger a one-time
        // ANE compilation (seconds on first run, cached afterwards).
        Task.detached(priority: .userInitiated) { [weak self, modelURL] in
            self?.load(from: modelURL)
        }
    }

    /// Load with bounded retry (resilient to transient failures, e.g. a busy
    /// ANE right after launch). Gives up after 3 attempts. Synchronous on
    /// purpose — it runs inside a detached task, and keeping the lock
    /// mutations out of async contexts is required on the macOS 27 SDK.
    private func load(from url: URL) {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuAndNeuralEngine
        for attempt in 1...3 {
            if let m = try? MLModel(contentsOf: url, configuration: cfg) {
                let inName = m.modelDescription.inputDescriptionsByName.keys.first ?? "seq"
                let outName = m.modelDescription.outputDescriptionsByName.keys.first ?? "score"
                let shape = m.modelDescription.inputDescriptionsByName[inName]?
                    .multiArrayConstraint?.shape ?? [1, 3, 1, 256]
                // Legacy: division-free exports carried the folded head bias
                // in metadata (current models divide in-graph and don't).
                let biasStr = m.modelDescription.metadata
                    .first { $0.key.rawValue == "kxc_head_bias" }?.value as? String
                let bias = biasStr.flatMap { Double($0) }
                setReady(m, input: inName, output: outName, shape: shape, bias: bias)
                return
            }
            if attempt < 3 { Thread.sleep(forTimeInterval: TimeInterval(attempt)) }
        }
        setUnavailable()
    }

    /// Lock-guarded state transitions (sync, so they're legal to call from
    /// anywhere).
    private func setReady(_ m: MLModel, input: String, output: String, shape: [NSNumber], bias: Double?) {
        lock.lock()
        state = .ready(m)
        inputName = input
        outputName = output
        inputShape = shape
        headBias = bias
        lock.unlock()
    }

    private func setUnavailable() {
        lock.lock()
        state = .unavailable
        lock.unlock()
    }

    func score(_ f: ServerFeatures) async -> Double {
        guard let model = readyModel, let inputName, let outputName,
              let shape = inputShape, shape.count == 4 else {
            return await fallback.score(f)
        }
        guard let arr = Self.makeInput(for: f, shape: shape),
              let input = try? MLDictionaryFeatureProvider(dictionary: [inputName: arr]) else {
            return await fallback.score(f)
        }
        // Sync Core ML API: an fp16 conv net over [1,3,1,256] scores in
        // microseconds-milliseconds, and this already runs inside a TaskGroup
        // child task, so blocking it is fine. (The async overload of
        // `prediction` is not actually async on this SDK — compiler warns.)
        guard let out = try? model.prediction(from: input, options: MLPredictionOptions()),
              let raw = out.featureValue(for: outputName)?.multiArrayValue else {
            return await fallback.score(f)
        }
        // The graph divides in-graph (masked mean), so the output is the
        // final badness score already. Legacy division-free exports carried
        // kxc_head_bias metadata — complete the masked mean host-side for
        // those only.
        guard let bias = self.currentHeadBias else { return raw[0].doubleValue }
        let window = shape[2].intValue * shape[3].intValue   // H*W samples per channel
        let count = min(f.history.count, window)
        return raw[0].doubleValue / max(Double(count), 1) + bias
    }

    private var currentHeadBias: Double? {
        lock.lock(); defer { lock.unlock() }
        return headBias
    }

    private var readyModel: MLModel? {
        lock.lock(); defer { lock.unlock() }
        if case .ready(let m) = state { return m }
        return nil
    }

    /// Zero-fill, then write the most-recent samples right-aligned in
    /// row-major grid order — exactly the layout the training generator
    /// produces (sample t -> cell (t / H, t % H... W)); MLMultiArray is
    /// contiguous so linear indexing is identical for both [1,3,1,256] and
    /// [1,3,16,16] layouts:
    ///   ch0 = normalized RTT (min(1, ms/300); failed → 0)
    ///   ch1 = loss flag (failed → 1)
    ///   ch2 = valid-sample mask (1)
    static func makeInput(for f: ServerFeatures, shape: [NSNumber]) -> MLMultiArray? {
        guard shape.count == 4,
              let arr = try? MLMultiArray(shape: shape, dataType: .float32) else { return nil }
        let channels = shape[1].intValue
        let window = shape[2].intValue * shape[3].intValue   // samples per channel
        for i in 0..<arr.count { arr[i] = 0 }
        let recent = Array(f.history.suffix(window))
        let pad = window - recent.count
        for (j, s) in recent.enumerated() {
            let t = pad + j
            let rtt: Float = s >= 0 ? min(1, s / 300) : 0     // ch0: normalized RTT
            arr[t] = NSNumber(value: rtt)
            if channels > 1 { arr[window + t] = NSNumber(value: s < 0 ? Float(1) : Float(0)) }  // ch1: loss
            if channels > 2 { arr[2 * window + t] = NSNumber(value: Float(1)) }                // ch2: valid mask
        }
        return arr
    }

    /// Where Core ML actually places kxc (Neural Engine / GPU / CPU) — decided
    /// via MLComputePlan over the meaningful ops (casts and consts excluded).
    func detectComputeDevice() async -> String? {
        guard let modelURL, #available(macOS 14.4, *) else { return nil }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuAndNeuralEngine
        guard let plan = try? await MLComputePlan.load(contentsOf: modelURL, configuration: cfg),
              case let .program(program) = plan.modelStructure,
              let main = program.functions["main"] else { return nil }
        var counts: [String: Int] = [:]
        for op in main.block.operations {
            let name = op.operatorName.lowercased()
            guard name.contains("conv") || name.contains("relu") || name.contains("mul")
                  || name.contains("reduce") || name.contains("div") else { continue }
            guard let usage = plan.deviceUsage(for: op) else { continue }
            switch usage.preferred {
            case .neuralEngine: counts["Neural Engine", default: 0] += 1
            case .gpu:         counts["GPU", default: 0] += 1
            default:           counts["CPU", default: 0] += 1
            }
        }
        return counts.max { $0.value < $1.value }?.key
    }
}