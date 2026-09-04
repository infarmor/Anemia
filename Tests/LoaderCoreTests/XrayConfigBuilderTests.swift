import XCTest
@testable import LoaderCore

final class XrayConfigBuilderTests: XCTestCase {

    private func realityServer() -> ProxyServer {
        ProxyServer(
            name: "R", proto: .vless, address: "example.com", port: 443,
            credential: "uuid-1", network: .tcp, security: .reality,
            sni: "www.microsoft.com", fingerprint: "chrome",
            realityPublicKey: "PBK", realityShortId: "abcd", flow: "xtls-rprx-vision"
        )
    }

    func testInboundsPresent() throws {
        let builder = XrayConfigBuilder(socksPort: 10808, httpPort: 10809, apiPort: nil)
        let cfg = builder.makeConfig(server: realityServer(), anti: .off)
        let inbounds = cfg["inbounds"] as! [[String: Any]]
        XCTAssertEqual(inbounds.count, 2)   // no api inbound when apiPort == nil
        XCTAssertEqual(inbounds[0]["port"] as? Int, 10808)
        XCTAssertEqual(inbounds[1]["port"] as? Int, 10809)
    }

    func testStatsApiInboundAndPolicy() throws {
        let cfg = XrayConfigBuilder(apiPort: 10812).makeConfig(server: realityServer(), anti: .off)
        let inbounds = cfg["inbounds"] as! [[String: Any]]
        XCTAssertTrue(inbounds.contains { $0["tag"] as? String == "api-in" })
        XCTAssertEqual((cfg["api"] as? [String: Any])?["tag"] as? String, "api")
        XCTAssertNotNil(cfg["stats"])
        XCTAssertNotNil(cfg["policy"])
        XCTAssertNotNil(cfg["dns"])   // anti-leak DNS always present
    }

    func testRealityOutbound() throws {
        let cfg = XrayConfigBuilder().makeConfig(server: realityServer(), anti: .off)
        let outbounds = cfg["outbounds"] as! [[String: Any]]
        let proxy = outbounds.first { $0["tag"] as? String == "proxy" }!
        let stream = proxy["streamSettings"] as! [String: Any]
        XCTAssertEqual(stream["security"] as? String, "reality")
        let reality = stream["realitySettings"] as! [String: Any]
        XCTAssertEqual(reality["publicKey"] as? String, "PBK")
        XCTAssertEqual(reality["serverName"] as? String, "www.microsoft.com")

        // Vision flow present on user.
        let settings = proxy["settings"] as! [String: Any]
        let vnext = settings["vnext"] as! [[String: Any]]
        let users = vnext[0]["users"] as! [[String: Any]]
        XCTAssertEqual(users[0]["flow"] as? String, "xtls-rprx-vision")
    }

    func testFragmentAndNoiseInjected() throws {
        let cfg = XrayConfigBuilder().makeConfig(server: realityServer(), anti: .recommended)
        let outbounds = cfg["outbounds"] as! [[String: Any]]

        // Fragment outbound exists and carries junk noises + TFO.
        let fragment = outbounds.first { $0["tag"] as? String == "fragment" }
        XCTAssertNotNil(fragment, "fragment dialer outbound should be present")
        let fragStream = fragment!["streamSettings"] as! [String: Any]
        let fragSockopt = fragStream["sockopt"] as! [String: Any]
        XCTAssertEqual(fragSockopt["tcpFastOpen"] as? Bool, true)
        XCTAssertNotNil(fragSockopt["noises"], "junk noises should be present")

        // Proxy chains into the fragment dialer.
        let proxy = outbounds.first { $0["tag"] as? String == "proxy" }!
        let proxyStream = proxy["streamSettings"] as! [String: Any]
        let proxySockopt = proxyStream["sockopt"] as! [String: Any]
        XCTAssertEqual(proxySockopt["dialerProxy"] as? String, "fragment")
    }

    func testVisionDisablesMux() throws {
        var anti = AntiCensorshipOptions.recommended
        anti.muxEnabled = true
        let cfg = XrayConfigBuilder().makeConfig(server: realityServer(), anti: anti)
        let outbounds = cfg["outbounds"] as! [[String: Any]]
        let proxy = outbounds.first { $0["tag"] as? String == "proxy" }!
        XCTAssertNil(proxy["mux"], "mux must be disabled under XTLS-Vision")
    }

    func testShadowsocksOutbound() throws {
        let s = ProxyServer(name: "S", proto: .shadowsocks, address: "ss.example.com", port: 8388,
                            credential: "pw", method: "aes-256-gcm")
        let cfg = XrayConfigBuilder().makeConfig(server: s, anti: .off)
        let outbounds = cfg["outbounds"] as! [[String: Any]]
        let proxy = outbounds.first { $0["tag"] as? String == "proxy" }!
        XCTAssertEqual(proxy["protocol"] as? String, "shadowsocks")
        let servers = (proxy["settings"] as! [String: Any])["servers"] as! [[String: Any]]
        XCTAssertEqual(servers[0]["method"] as? String, "aes-256-gcm")
    }

    func testSerializesToValidJSON() throws {
        let data = try XrayConfigBuilder().makeConfigData(server: realityServer(), anti: .recommended)
        let roundtrip = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(roundtrip?["outbounds"])
    }
}

final class SubscriptionParserTests: XCTestCase {
    func testParsesBase64Blob() {
        let links = [
            "vless://uuid-a@a.example.com:443?encryption=none&security=reality&pbk=P&type=tcp#A",
            "trojan://pw@b.example.com:443?type=tcp#B"
        ].joined(separator: "\n")
        let blob = Data(links.utf8).base64EncodedString()
        let result = SubscriptionParser.parse(blob)
        XCTAssertEqual(result.servers.count, 2)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.servers[0].proto, .vless)
        XCTAssertEqual(result.servers[1].proto, .trojan)
    }

    func testSkipsBadLinesButKeepsGood() {
        let text = """
        vless://uuid-a@a.example.com:443?encryption=none&type=tcp#A
        not-a-link
        garbage://x
        """
        let result = SubscriptionParser.parse(text)
        XCTAssertEqual(result.servers.count, 1)
        XCTAssertEqual(result.failures.count, 1)  // "garbage://" is a failed parse; "not-a-link" is skipped
    }
}
