import Foundation
import LoaderShared
import Testing

@testable import LoaderHelper

/// The ledger is the only thing that can put a Mac's resolver and proxy back
/// after a crash, so two failures matter more than anywhere else in the app: an
/// unreadable file reading as "nothing to restore", and that empty reading then
/// being saved over the real file.
struct JournalDecodeTests {
    private func store() -> NetworkJournalStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("anemia-journal-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return NetworkJournalStore(directory: directory.path)
    }

    private func asideFiles(_ store: NetworkJournalStore) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: store.directory))?
            .filter { $0.contains("unreadable-") } ?? []
    }

    private func write(_ store: NetworkJournalStore, _ json: String) throws {
        try Data(json.utf8).write(to: URL(fileURLWithPath: store.path))
    }

    /// One service's record with a `prior` that isn't a list of strings used to
    /// take the whole `dns` array down with it.
    @Test func oneUnreadableEntryCostsOnlyItself() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(atPath: store.directory) }
        try write(store, """
            {"version":1,"dns":[
              {"service":"Wi-Fi","prior":["1.1.1.1"],"applied":["172.28.0.2"]},
              {"service":"Thunderbolt Bridge","prior":42,"applied":["172.28.0.2"]},
              {"service":"USB 10/100/1000 LAN","prior":[],"applied":[]}
            ],"proxy":[]}
            """)
        let journal = store.load()
        #expect(journal.dns.count == 2, "the poisoned entry took the whole ledger: \(journal.dns)")
        #expect(journal.dns.map(\.service) == ["Wi-Fi", "USB 10/100/1000 LAN"])
    }

    /// Losing records is worth a copy; a healthy ledger must not spawn one on
    /// every boot, or the directory fills up and the copies mean nothing.
    @Test func droppedEntriesAreKeptAsideAndHealthyOnesAreNot() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(atPath: store.directory) }
        try write(store, #"{"version":1,"dns":[{"service":"Wi-Fi","prior":["1.1.1.1"],"applied":[]}],"proxy":[]}"#)
        #expect(store.load().dns.count == 1)
        #expect(asideFiles(store).isEmpty, "a complete ledger was copied aside anyway")

        try write(store, #"{"version":1,"dns":[{"service":"Wi-Fi","prior":42}],"proxy":[]}"#)
        #expect(store.load().dns.isEmpty)
        let copies = asideFiles(store)
        #expect(copies.count == 1, "records were dropped with no copy kept: \(copies)")
        let kept = try String(contentsOf: URL(fileURLWithPath: store.directory + "/" + copies[0]), encoding: .utf8)
        #expect(kept.contains("\"prior\":42"), "the copy is not the file that was lost")
    }

    /// A ledger written by a newer helper is read as far as this one can, and
    /// copied aside before anything can re-save it at the older version.
    @Test func newerFormatIsRestoredButCopiedAside() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(atPath: store.directory) }
        try write(store, #"{"version":2,"dns":[{"service":"Wi-Fi","prior":["1.1.1.1"],"applied":[]}],"proxy":[]}"#)
        let journal = store.load()
        #expect(journal.dns.count == 1, "a newer ledger was thrown away instead of restored")
        #expect(asideFiles(store).count == 1)
    }
}
