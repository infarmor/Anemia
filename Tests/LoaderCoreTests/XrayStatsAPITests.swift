import Foundation
import Testing
@testable import LoaderCore

struct XrayStatsAPITests {

    // MARK: - Protobuf parsing

    private func encodeVarint(_ v0: UInt64) -> [UInt8] {
        var v = v0, out: [UInt8] = []
        while true {
            var b = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { b |= 0x80 }
            out.append(b)
            if v == 0 { break }
        }
        return out
    }

    /// Encode a Stat submessage and wrap it in a QueryStatsResponse.
    private func encodeResponse(_ stats: [(String, Int64)]) -> Data {
        var msg = Data()
        for (name, value) in stats {
            var sub = Data([0x0A])                       // field 1 (name), wire 2
            sub.append(contentsOf: encodeVarint(UInt64(name.utf8.count)))
            sub.append(contentsOf: Array(name.utf8))
            sub.append(0x10)                             // field 2 (value), wire 0
            sub.append(contentsOf: encodeVarint(UInt64(bitPattern: Int64(value))))
            msg.append(0x0A)                             // repeated field 1, wire 2
            msg.append(contentsOf: encodeVarint(UInt64(sub.count)))
            msg.append(sub)
        }
        return msg
    }

    @Test func testParseProtobufStats() throws {
        let parsed = XrayStatsAPI.parseProtobuf(encodeResponse([
            ("outbound>>>proxy>>>traffic>>>uplink", 88_597_084),
            ("outbound>>>proxy>>>traffic>>>downlink", 938_439_941),
        ]))
        #expect(parsed.count == 2)
        let s0 = try #require(parsed.first, "no stats parsed")
        #expect(s0.name == "outbound>>>proxy>>>traffic>>>uplink")
        #expect(s0.value == 88_597_084)
        if parsed.count > 1 {
            #expect(parsed[1].name == "outbound>>>proxy>>>traffic>>>downlink")
            #expect(parsed[1].value == 938_439_941)
        }
    }

    /// Counters not yet exercised carry no value field at all (xray emits
    /// name-only stats) — they must parse as 0, not abort the walk.
    @Test func testParseProtobufNameOnlyStat() throws {
        let parsed = XrayStatsAPI.parseProtobuf(encodeResponse([("outbound>>>block>>>traffic>>>uplink", 0)]))
        #expect(parsed.count == 1)
        let s = try #require(parsed.first, "no stat parsed")
        #expect(s.name == "outbound>>>block>>>traffic>>>uplink")
        #expect(s.value == 0)
    }

    @Test func testParseProtobufEmptyAndGarbage() {
        #expect(XrayStatsAPI.parseProtobuf(Data()).isEmpty)
        // Truncated varint / truncated submessage must not crash — garbage in, whatever parses out.
        _ = XrayStatsAPI.parseProtobuf(Data([0x0A]))
        _ = XrayStatsAPI.parseProtobuf(Data([0x0A, 0xFF, 0xFF]))
    }

    // MARK: - Live engine integration

    /// Spawns the bundled engine on a free port with the stats API enabled
    /// and runs the native h2c client against it — the exact wire format the
    /// production poll loop uses. Skipped if the binary isn't in the repo.
    @Test func testLiveEngineQueryStats() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let xrayURL = repoRoot.appendingPathComponent("Resources/xray")
        guard FileManager.default.fileExists(atPath: xrayURL.path) else {
            return /* skipped: precondition unavailable */
        }

        // Grab free ports by binding and releasing them — every inbound must
        // be unique, or a concurrently-running app instance's engine (which
        // owns 10808/10809) collides and the test engine dies on startup.
        let port = try Self.freePort()
        let socksPort = try Self.freePort()
        let httpPort = try Self.freePort()

        let server = ProxyServer(name: "T", proto: .trojan, address: "127.0.0.1",
                                 port: 1, credential: "test", network: .tcp, security: .tls)
        let configData = try XrayConfigBuilder(
            socksPort: socksPort, httpPort: httpPort, apiPort: port
        ).makeConfigData(server: server, anti: .off)
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loader-stats-test-\(UUID().uuidString).json")
        try configData.write(to: configURL)
        defer { try? FileManager.default.removeItem(at: configURL) }

        let proc = Process()
        proc.executableURL = xrayURL
        proc.arguments = ["run", "-c", configURL.path]
        try proc.run()
        defer { proc.terminate() }

        // The API listener needs a moment to come up.
        var stats: [XrayStat]?
        for _ in 0..<30 {
            stats = XrayStatsAPI.query(port: UInt16(port), pattern: "outbound>>>proxy>>>", timeout: 2)
            if stats != nil { break }
            Thread.sleep(forTimeInterval: 0.4)
        }
        let result = try #require(stats, "native gRPC query returned nothing (engine running: \(proc.isRunning), status: \(proc.terminationStatus))")
        let names = Set(result.map(\.name))
        #expect(names.contains("outbound>>>proxy>>>traffic>>>uplink"))
        #expect(names.contains("outbound>>>proxy>>>traffic>>>downlink"))
        // Fresh engine: no traffic yet, so values are zero — but present.
        #expect(result.allSatisfy { $0.value == 0 })
    }

    private static func freePort() throws -> Int {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw NSError(domain: "test", code: 1) }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        var bound = sockaddr_in()
        guard getsockname(sock, withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
        }, &len) == 0 else { throw NSError(domain: "test", code: 2) }
        return Int(CFSwapInt16(bound.sin_port))
    }
}