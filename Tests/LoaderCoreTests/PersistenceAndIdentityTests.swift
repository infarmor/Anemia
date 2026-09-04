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
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("bak"))
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
        XCTAssertTrue(files.contains { $0.hasPrefix(url.deletingPathExtension().lastPathComponent + ".json.corrupt-") },
                      "a .corrupt-*.bak backup of the malformed store must exist")
    }

    func testRoundTripPreservesState() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = ProxyServer(name: "n", proto: .trojan, address: "h", port: 1, credential: "p")
        let original = PersistedState(servers: [server], selectedServerID: server.id)
        try StatePersistence(fileURL: url).save(original)
        XCTAssertEqual(StatePersistence(fileURL: url).load(), original)
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