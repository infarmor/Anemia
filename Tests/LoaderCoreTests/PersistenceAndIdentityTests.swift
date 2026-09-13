import XCTest
@testable import LoaderCore

final class PersistenceTests: XCTestCase {
    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("loader-persist-tests-\(UUID().uuidString).json")
    }

    func testLoadMissingFileReturnsDefaults() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let state = StatePersistence(fileURL: url).load()
        XCTAssertTrue(state.servers.isEmpty)
        XCTAssertNil(state.selectedServerID)
    }

    func testMalformedStateIsBackedUpAndReset() throws {
        let url = tempURL()
        let base = url.deletingPathExtension().lastPathComponent
        defer {
            try? FileManager.default.removeItem(at: url)
            // The corrupt-store backup too — a stale .corrupt-*.bak would let
            // a later regression pass via prefix leftovers.
            let fm = FileManager.default
            if let files = try? fm.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) {
                for f in files where f.hasPrefix(base + ".json.corrupt-") {
                    try? fm.removeItem(at: url.deletingLastPathComponent().appendingPathComponent(f))
                }
            }
        }
        let server = ProxyServer(name: "kept", proto: .vless, address: "a.example.com", port: 443, credential: "u")
        let good = PersistedState(servers: [server], selectedServerID: server.id)
        try StatePersistence(fileURL: url).save(good)

        // Corrupt the store in place with JSON the lenient decoder can't map
        // (`{}` alone decodes to defaults — a *type-mismatched* field fails).
        try Data(#"{"servers": 42}"#.utf8).write(to: url)

        let reloaded = StatePersistence(fileURL: url).load()
        XCTAssertTrue(reloaded.servers.isEmpty, "corrupt state must fall back to defaults")

        // …but the previous data is recoverable from the timestamped backup.
        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        let backup = files.first { $0.hasPrefix(base + ".json.corrupt-") }
        XCTAssertNotNil(backup, "a .corrupt-*.bak backup of the malformed store must exist")
        if let backup {
            let raw = try? Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(backup))
            XCTAssertEqual(raw, Data(#"{"servers": 42}"#.utf8),
                           "the backup must contain the raw malformed bytes")
        }
    }

    func testRoundTripPreservesState() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = ProxyServer(name: "n", proto: .trojan, address: "h", port: 1, credential: "p")
        let original = PersistedState(servers: [server], selectedServerID: server.id)
        try StatePersistence(fileURL: url).save(original)
        XCTAssertEqual(StatePersistence(fileURL: url).load(), original)
    }

    /// The learned per-server masking map survives a save/load round-trip, and a
    /// store written before the field existed still decodes (empty map).
    func testLearnedMaskingRoundTripAndLegacyDecode() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = ProxyServer(name: "n", proto: .vless, address: "h", port: 443, credential: "u")
        let original = PersistedState(servers: [server],
                                      learnedMasking: [server.identityKey: MaskingProfile.ruYandex.rawValue])
        try StatePersistence(fileURL: url).save(original)
        let reloaded = StatePersistence(fileURL: url).load()
        XCTAssertEqual(reloaded.learnedMasking[server.identityKey], MaskingProfile.ruYandex.rawValue)

        // Legacy store without the key → empty map, no data loss.
        try #"{"servers":[],"subscriptions":[]}"#.data(using: .utf8)!.write(to: url)
        XCTAssertTrue(StatePersistence(fileURL: url).load().learnedMasking.isEmpty)
    }
}

final class ServerIdentityTests: XCTestCase {
    func testIdentityKeyIgnoresCosmeticFields() {
        let a = ProxyServer(name: "Alpha", proto: .vless, address: "h", port: 443, credential: "u",
                            network: .tcp, security: .tls, sni: "sni.example.com")
        let b = ProxyServer(name: "Beta", proto: .vless, address: "h", port: 443, credential: "u",
                            network: .ws, security: .none, path: "/ws")
        XCTAssertEqual(a.identityKey, b.identityKey, "name/sni/transport must not change identity")
    }

    func testIdentityKeyDistinguishesCredentialsAndProtocols() {
        let base = ProxyServer(name: "A", proto: .vless, address: "h", port: 443, credential: "u1")
        XCTAssertNotEqual(base.identityKey,
                          ProxyServer(name: "A", proto: .vless, address: "h", port: 443, credential: "u2").identityKey)
        XCTAssertNotEqual(base.identityKey,
                          ProxyServer(name: "A", proto: .trojan, address: "h", port: 443, credential: "u1").identityKey)
        XCTAssertNotEqual(base.identityKey,
                          ProxyServer(name: "A", proto: .vless, address: "h", port: 8443, credential: "u1").identityKey)
    }
}