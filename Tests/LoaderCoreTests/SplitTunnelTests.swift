import Foundation
import Testing
@testable import LoaderCore

struct PunycodeTests {
    /// Known encodings (RFC 3492 examples and the IANA IDN test domains).
    @Test func testKnownVectors() {
        #expect(Punycode.encodeLabel("пример") == "xn--e1afmkfd")
        #expect(Punycode.encodeLabel("испытание") == "xn--80akhbyknj4f")
        #expect(Punycode.encodeLabel("рф") == "xn--p1ai")
        #expect(Punycode.encodeLabel("bücher") == "xn--bcher-kva")
        #expect(Punycode.encodeLabel("münchen") == "xn--mnchen-3ya")
        #expect(Punycode.encodeLabel("例え") == "xn--r8jz45g")
        #expect(Punycode.encodeLabel("example") == "example")
    }
}

struct SplitTunnelParserTests {

    private func one(_ line: String) -> BypassEntry? {
        let r = SplitTunnelParser.parse([line])
        return r.entries.count == 1 ? r.entries[0] : nil
    }

    private func reason(_ line: String) -> String? {
        SplitTunnelParser.parse([line]).rejected.first?.reason
    }

    @Test func testIPv4AddressesAndNetworksAreCanonical() {
        #expect(one("203.0.113.7") == .ipv4("203.0.113.7/32"))
        #expect(one("10.8.0.0/16") == .ipv4("10.8.0.0/16"))
        // Host bits are cleared: the route is installed for the network.
        #expect(one("192.168.77.130/25") == .ipv4("192.168.77.128/25"))
        #expect(one(" 198.51.100.1 ") == .ipv4("198.51.100.1/32"))
    }

    @Test func testIPv6AddressesAndNetworksAreCanonical() {
        #expect(one("2001:db8::1") == .ipv6("2001:db8::1/128"))
        #expect(one("2001:DB8:0:0::/32") == .ipv6("2001:db8::/32"))
        #expect(one("[2001:db8::5]:443") == .ipv6("2001:db8::5/128"))
    }

    @Test func testDomainsFromWildcardsURLsAndIDN() {
        #expect(one("Bank.RU") == .domain("bank.ru"))
        #expect(one("*.gosuslugi.ru") == .domain("gosuslugi.ru"))
        #expect(one(".example.com.") == .domain("example.com"))
        #expect(one("https://online.sberbank.ru:443/login?x=1") == .domain("online.sberbank.ru"))
        #expect(one("пример.испытание") == .domain("xn--e1afmkfd.xn--80akhbyknj4f"))
        #expect(one("nas") == .domain("nas"))
    }

    @Test func testRejectsDestinationsThatWouldDefeatTheVPN() {
        #expect(reason("0.0.0.0/0")?.contains("too broad") == true)
        #expect(reason("128.0.0.0/1")?.contains("too broad") == true)
        #expect(reason("2000::/3")?.contains("too broad") == true)
        #expect(reason("127.0.0.1")?.contains("loopback") == true)
        #expect(reason("::1")?.contains("loopback") == true)
        // The helper's own tunnel ranges.
        #expect(reason("172.28.0.2")?.contains("tunnel") == true)
        #expect(reason("172.29.0.0/24")?.contains("tunnel") == true)
        #expect(reason("172.16.0.0/12")?.contains("tunnel") == true)   // contains 172.28.0.0/24
        #expect(one("172.30.0.0/16") == .ipv4("172.30.0.0/16"))
    }

    @Test func testRejectsGarbage() {
        #expect(reason("300.1.1.1") != nil)
        #expect(reason("010.0.0.1") != nil)       // BSD would read octal
        #expect(reason("1.2.3.4/33") != nil)
        #expect(reason("-bad-.com") != nil)
        #expect(reason("1.2.3") != nil)
        #expect(reason("a..b") != nil)
        #expect(reason("bad_name.com") != nil)
    }

    @Test func testFreeFormPasteCommentsAndDuplicates() {
        let text = """
        # work
        10.20.0.0/16, 10.20.1.1
        bank.ru; bank.ru
        *.bank.ru   gov.ru # government
        """
        let r = SplitTunnelParser.parse(text: text)
        #expect(r.entries == [.ipv4("10.20.0.0/16"), .ipv4("10.20.1.1/32"), .domain("bank.ru"), .domain("gov.ru")])
        #expect(r.rejected.isEmpty)
        let parts = SplitTunnelParser.partition(r.entries)
        #expect(parts.networks == ["10.20.0.0/16", "10.20.1.1/32"])
        #expect(parts.domains == ["bank.ru", "gov.ru"])
    }

    @Test func testDisabledRulesProduceNothing() {
        #expect(SplitTunnelRules(enabled: false, entries: ["bank.ru"]).activeEntries.isEmpty)
        #expect(SplitTunnelRules(enabled: true, entries: ["bank.ru", "0.0.0.0/0"]).activeEntries == [.domain("bank.ru")])
    }

    @Test func testRulesSurvivePersistence() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("anemia-split-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = StatePersistence(fileURL: url)
        var state = PersistedState()
        state.splitTunnel = SplitTunnelRules(enabled: false, entries: ["bank.ru", "10.0.0.0/8"])
        try store.save(state)
        #expect(store.load().splitTunnel == state.splitTunnel)
        // State saved before split tunneling existed decodes to the default.
        try Data(#"{"servers":[],"subscriptions":[]}"#.utf8).write(to: url)
        #expect(store.load().splitTunnel == SplitTunnelRules())
    }
}

struct SplitTunnelConfigTests {

    private func server() -> ProxyServer {
        ProxyServer(name: "t", proto: .vless, address: "vpn.example.com", port: 443,
                    credential: "00000000-0000-4000-8000-000000000000",
                    network: .tcp, security: .tls, sni: "vpn.example.com")
    }

    private let entries: [BypassEntry] = [.ipv4("10.20.0.0/16"), .ipv6("2001:db8::/32"), .domain("bank.ru")]

    @Test func testBypassGoesThroughThePinnedOutboundAheadOfTheQUICBlock() throws {
        var builder = XrayConfigBuilder()
        builder.dialerInterface = "en0"
        builder.bypass = entries
        let config = try builder.makeConfig(server: server(), anti: .off)
        let outbounds = try #require(config["outbounds"] as? [[String: Any]])
        #expect(outbounds.first?["tag"] as? String == "proxy")   // still the default
        let bypass = try #require(outbounds.first { $0["tag"] as? String == "bypass" })
        let sockopt = (bypass["streamSettings"] as? [String: Any])?["sockopt"] as? [String: Any]
        #expect(sockopt?["interface"] as? String == "en0")

        let rules = try #require((config["routing"] as? [String: Any])?["rules"] as? [[String: Any]])
        let domainRule = try #require(rules.firstIndex { $0["outboundTag"] as? String == "bypass" && $0["domain"] != nil })
        let ipRule = try #require(rules.firstIndex { $0["outboundTag"] as? String == "bypass" && $0["ip"] != nil })
        #expect(rules[domainRule]["domain"] as? [String] == ["domain:bank.ru"])
        #expect(rules[ipRule]["ip"] as? [String] == ["10.20.0.0/16", "2001:db8::/32"])
        let quicBlock = try #require(rules.firstIndex {
            $0["network"] as? String == "udp" && $0["outboundTag"] as? String == "block"
        })
        #expect(domainRule < quicBlock && ipRule < quicBlock)
    }

    @Test func testNoBypassWithoutAPhysicalInterfacePin() throws {
        var builder = XrayConfigBuilder()
        builder.bypass = entries
        let config = try builder.makeConfig(server: server(), anti: .off)
        let outbounds = try #require(config["outbounds"] as? [[String: Any]])
        #expect(!outbounds.contains { $0["tag"] as? String == "bypass" })
        let rules = try #require((config["routing"] as? [String: Any])?["rules"] as? [[String: Any]])
        #expect(!rules.contains { $0["outboundTag"] as? String == "bypass" })
    }

    /// The bundled engine itself must accept the generated routing rules.
    @Test func testRealEngineAcceptsTheBypassConfig() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let xray = root.appendingPathComponent("Resources/xray")
        guard FileManager.default.isExecutableFile(atPath: xray.path) else { return }
        var builder = XrayConfigBuilder()
        builder.dialerInterface = "en0"
        builder.bypass = entries
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("anemia-bypass-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try builder.makeConfigData(server: server(), anti: .recommended).write(to: url)
        let proc = Process()
        proc.executableURL = xray
        proc.arguments = ["run", "-c", url.path, "-test"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(proc.terminationStatus == 0, "xray rejected the config: \(output)")
    }
}
