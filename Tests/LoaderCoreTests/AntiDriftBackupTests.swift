import Foundation
import Testing

@testable import LoaderCore

/// `AntiCensorshipOptions` decodes per field on purpose, and two of its shapes
/// lose more than the field that broke: a `noises` list nothing can read costs
/// every junk generator, and `fragment` — one all-or-nothing struct — costs
/// ClientHello fragmentation as a whole. Both are invisible in the worst way:
/// the UI keeps naming the anti-DPI profile while the engine gets less of it,
/// and the connection simply fails somewhere else. So the drift detector has to
/// see them and keep the file aside before the next save overwrites it.
struct AntiDriftBackupTests {
    private func tempURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("anemia-anti-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("state.json")
    }

    /// Write `json` as the store, load it, and report what the decode recovered
    /// next to how many backup files the load left behind. Backups from an
    /// earlier case are removed first, so every expectation is 0 or 1.
    private func read(_ json: String, _ url: URL) -> (state: PersistedState, backups: [String]) {
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            where name.hasPrefix(base + ".json.corrupt-") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        try? Data(json.utf8).write(to: url)
        let state = StatePersistence(fileURL: url).load()
        let backups = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasPrefix(base + ".json.corrupt-") }) ?? []
        return (state, backups)
    }

    @Test func unreadableNoiseEntriesAreBackedUp() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        defer {
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
                where name.hasPrefix(base + ".json.corrupt-") {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }

        // Control: the same shape with readable noises must not be called
        // corrupt — otherwise every ordinary load would write a backup.
        let clean = read(#"{"servers":[],"anti":{"noises":[{"type":"rand","packet":"50-100","delay":"10-16"}]}}"#, url)
        #expect(clean.state.anti.noises.count == 1)
        #expect(clean.backups.isEmpty, "a healthy store was reported as corrupt")

        // A `packet` that arrived as a number kills that entry; with only that
        // one entry in the list, the whole array is gone.
        let drifted = read(#"{"servers":[],"anti":{"noises":[{"type":"rand","packet":5,"delay":"10-16"}]}}"#, url)
        #expect(drifted.state.anti.noises.isEmpty, "the poisoned entry decoded after all — nothing to back up")
        #expect(drifted.backups.count == 1, "anti-DPI options were dropped without a copy: \(drifted.backups)")

        // The per-element decode keeps the readable generator… which is exactly
        // why counting matters: a partial loss must still be called a loss.
        let partial = read(#"{"servers":[],"anti":{"noises":[{"type":"rand","packet":5,"delay":"10-16"},{"type":"str","packet":"hi","delay":"10"}]}}"#, url)
        #expect(partial.state.anti.noises.count == 1, "the good entry should survive")
        #expect(partial.backups.count == 1, "one entry short is still data loss: \(partial.backups)")
    }

    /// `fragment` is not a list, so no count compares it — and its decoder is
    /// all-or-nothing: one field of the wrong type and the ClientHello
    /// fragmentation is gone while the profile name stays. A `"fragment": null`
    /// is the user switching it off and must stay quiet.
    @Test func unreadableFragmentIsBackedUpButAnAbsentOneIsNot() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let healthy = read(#"{"servers":[],"anti":{"fragment":{"packets":"tlshello","length":"100-200","interval":"10-20"}}}"#, url)
        #expect(healthy.state.anti.fragment?.length == "100-200")
        #expect(healthy.backups.isEmpty, "a readable fragment was reported as corrupt")

        let off = read(#"{"servers":[],"anti":{"fragment":null,"noises":[]}}"#, url)
        #expect(off.state.anti.fragment == nil)
        #expect(off.backups.isEmpty, "turning fragmentation off is not corruption")

        let broken = read(#"{"servers":[],"anti":{"fragment":{"packets":"tlshello","length":200,"interval":"10-20"}}}"#, url)
        #expect(broken.state.anti.fragment == nil, "the fragment decoded after all — nothing to back up")
        #expect(broken.backups.count == 1, "fragmentation vanished without a copy: \(broken.backups)")
    }
}
