import CoreML
import Foundation
import LoaderCore
import os

/// kxc, the Mac app's server-quality model, on the iPhone: a boosted-tree
/// ensemble that forecasts how a server will behave over its next probes from
/// engineered features of its ping history — LoaderCore's KxcFeatures, the
/// same code its trainer compiles. Tree ensembles run on the CPU in
/// microseconds per server.
///
/// The model (Resources/kxc.mlmodelc, a copy of the Mac app's) loads in the
/// background; until it is ready — or if it is missing or of an older kind —
/// the hand-built score stands in, so ranking never waits for it.
final class Kxc: @unchecked Sendable {
    static let shared = Kxc()

    private let lock = NSLock()
    private var model: MLModel?
    private var outputName = "score"
    private var logTarget = false
    private var versionLabel: String?
    private var failed = false

    private init() {
        guard let url = Bundle.main.url(forResource: "kxc", withExtension: "mlmodelc") else {
            failed = true
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            self?.load(url)
        }
    }

    /// "kxc v4", or what stands in for it.
    var status: String {
        lock.lock()
        defer { lock.unlock() }
        if let versionLabel, model != nil { return versionLabel }
        return failed ? "эвристика (kxc недоступна)" : "загружается…"
    }

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return model != nil
    }

    /// The forecast "badness" of the next probes — milliseconds of latency
    /// plus penalties for jitter and loss, lower is better. Nil while the
    /// model isn't there, or without a single successful probe.
    func forecast(_ history: [Float]) -> Double? {
        guard history.contains(where: { $0 >= 0 }) else { return nil }
        lock.lock()
        let (model, output, logTarget) = (self.model, outputName, self.logTarget)
        lock.unlock()
        guard let model else { return nil }
        var features: [String: MLFeatureValue] = [:]
        for (name, value) in zip(KxcFeatures.names, KxcFeatures.extract(history)) {
            features[name] = MLFeatureValue(double: value)
        }
        guard let input = try? MLDictionaryFeatureProvider(dictionary: features),
              let result = try? model.prediction(from: input),
              let raw = result.featureValue(for: output)?.doubleValue
        else { return nil }
        return max(0, logTarget ? expm1(raw) : raw)
    }

    private func load(_ url: URL) {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        guard let model = try? MLModel(contentsOf: url, configuration: configuration) else {
            markFailed()
            return
        }
        let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        // Only v4 feature models: the older grid-input conv models need the
        // Mac app's encoder, and the iPhone never shipped with them.
        guard metadata["kxc_input"] == "features-v4" else {
            markFailed()
            return
        }
        lock.lock()
        self.model = model
        outputName = model.modelDescription.outputDescriptionsByName.keys.first ?? "score"
        logTarget = metadata["kxc_target"] == "log1p"
        versionLabel = "kxc v\(metadata["kxc_version"] ?? "4")"
        lock.unlock()
        // The first prediction loads the ensemble: do it now, off the main thread.
        let sample = forecast([80, 82, 79, 81]).map { String(format: "%.0f", $0) } ?? "—"
        Logger(subsystem: "Anemia", category: "kxc").notice("\(self.status, privacy: .public) ready, sample forecast \(sample, privacy: .public)")
    }

    private func markFailed() {
        lock.lock()
        failed = true
        lock.unlock()
        Logger(subsystem: "Anemia", category: "kxc").error("kxc unavailable, the heuristic ranks servers")
    }
}
