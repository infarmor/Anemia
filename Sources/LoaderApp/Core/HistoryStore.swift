import Foundation

/// Persists a rolling per-server ping history (RTT ms; a failed probe is -1)
/// across launches, so kxc's temporal model has a real time-series to read.
struct HistoryStore {
    let fileURL: URL
    let maxSamples: Int

    init(maxSamples: Int = 256) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        fileURL = base.appendingPathComponent("Loader/history.json")
        self.maxSamples = maxSamples
    }

    func load() -> [String: [Float]] {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: [Float]].self, from: data) else { return [:] }
        return dict
    }

    func save(_ history: [String: [Float]]) {
        // Cap each series to the most recent `maxSamples`.
        let capped = history.mapValues { Array($0.suffix(maxSamples)) }
        guard let data = try? JSONEncoder().encode(capped) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic])
    }
}
