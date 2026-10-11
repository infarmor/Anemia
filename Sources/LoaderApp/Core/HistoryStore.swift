import Foundation

/// Persists a rolling per-server ping history (RTT ms; a failed probe is -1)
/// across launches, so kxc's temporal model has a real time-series to read.
///
/// The file is versioned by *probe methodology*. When the way we measure
/// latency changes — e.g. the switch from a raw TCP connect (which a system
/// fake-IP TUN answers in ~0 ms) to a TLS handshake (a true round-trip) — the
/// old series are on a different scale and would corrupt averages and the
/// model. Bumping `Self.schema` makes `load()` discard any file that isn't on
/// the current methodology, so rankings restart from clean, comparable data.
struct HistoryStore {
    let fileURL: URL
    let maxSamples: Int

    /// 2 = TLS-handshake latencies. (1 = the legacy TCP-connect era, discarded.)
    static let schema = 2

    private struct Envelope: Codable {
        var schema: Int
        var series: [String: [Float]]
    }

    init(maxSamples: Int = 256, fileURL: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        self.fileURL = fileURL ?? base.appendingPathComponent("Loader/history.json")
        self.maxSamples = maxSamples
    }

    func load() -> [String: [Float]] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        // Current, versioned format: keep only if the methodology matches.
        if let env = try? JSONDecoder().decode(Envelope.self, from: data) {
            return env.schema == Self.schema ? env.series : [:]
        }
        // Unreadable is not the same thing as absent: the next ping round
        // saves what it has, and that write replaces this file — so every
        // series in it would go out with it and nothing else holds them.
        // Same rule as the state store, which keeps a corrupt document aside
        // before it is overwritten (`StatePersistence.backUp`).
        backUpUnreadable(data)
        // Legacy bare-dictionary file (pre-versioning, TCP era): discard it so
        // stale near-zero samples can't leak into the new TLS-based rankings.
        return [:]
    }

    /// `<name>.corrupt-<ms>.bak` next to the file. Milliseconds, because two
    /// launches inside one second would otherwise overwrite the earlier copy.
    private func backUpUnreadable(_ raw: Data) {
        let directory = fileURL.deletingLastPathComponent()
        let stem = fileURL.deletingPathExtension().lastPathComponent
        let url = directory.appendingPathComponent("\(stem).corrupt-\(Int(Date().timeIntervalSince1970 * 1000)).bak")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? raw.write(to: url)
    }

    func save(_ history: [String: [Float]]) {
        // Cap each series to the most recent `maxSamples`.
        let capped = history.mapValues { Array($0.suffix(maxSamples)) }
        let env = Envelope(schema: Self.schema, series: capped)
        guard let data = try? JSONEncoder().encode(env) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic])
    }
}
