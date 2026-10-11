import Foundation
import Testing

@testable import LoaderApp

/// The ping history is the kxc model's time-series, and `history.json` is the
/// only place it lives: the first ping round of a launch saves what it has, so
/// whatever the file held before that save is gone with it.
struct HistoryStoreTests {
    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("anemia-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("history.json")
    }

    /// One value the decoder can't read is enough to lose the *document*, and
    /// with it every server's series — that is the case the backup exists for.
    @Test func unreadableHistoryIsKeptAsideBeforeItIsReplaced() throws {
        let file = try temporaryFile()
        let poisoned = #"{"schema":2,"series":{"A":[1.5,"two"],"B":[9,9]}"#
        try Data(poisoned.utf8).write(to: file)
        let store = HistoryStore(fileURL: file)
        #expect(store.load().isEmpty, "a whole unreadable document still decoded")

        let backups = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
            .filter { $0.hasPrefix("history.corrupt-") && $0.hasSuffix(".bak") }
        let name = try #require(backups.first, "unreadable history was dropped without a copy: \(backups)")
        let bytes = try Data(contentsOf: file.deletingLastPathComponent().appendingPathComponent(name))
        #expect(String(decoding: bytes, as: UTF8.self) == poisoned)

        // …and the save that replaces the file leaves the copy alone.
        store.save(["B": [9, 9]])
        #expect(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().appendingPathComponent(name).path))
        #expect(store.load()["B"] == [9, 9])
    }

    /// A file from the other methodology is thrown away on purpose, and should
    /// not be mistaken for corruption.
    @Test func otherSchemaIsDiscardedWithoutACopy() throws {
        let file = try temporaryFile()
        try Data(#"{"schema":1,"series":{"A":[0.1]}}"#.utf8).write(to: file)
        #expect(HistoryStore(fileURL: file).load().isEmpty)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
            .filter { $0.contains("corrupt") }
        #expect(leftovers.isEmpty, "a deliberate schema drop was backed up as corruption: \(leftovers)")
    }

    @Test func seriesAreCappedToTheNewestSamples() throws {
        let file = try temporaryFile()
        let store = HistoryStore(maxSamples: 3, fileURL: file)
        store.save(["A": [1, 2, 3, 4, 5]])
        #expect(store.load()["A"] == [3, 4, 5])
    }
}
