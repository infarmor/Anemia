import XCTest
@testable import LoaderCore

final class PortFinderTests: XCTestCase {
    func testFreePortInRange() {
        guard let p = PortFinder.freePort() else { return XCTFail("no free port") }
        XCTAssertGreaterThan(p, 0)
        XCTAssertLessThan(p, 65536)
    }

    func testPickAvoidsExcluded() {
        guard let a = PortFinder.freePort() else { return XCTFail("no port") }
        let picked = PortFinder.pick(preferred: a, exclude: [a])
        XCTAssertNotEqual(picked, a, "excluded preferred port must not be returned")
    }
}

final class MaskingProfileTests: XCTestCase {
    func testMaximumIsMoreAggressive() {
        let max = MaskingProfile.maximum.options
        XCTAssertNotNil(max.fragment)
        XCTAssertGreaterThanOrEqual(max.noises.count, 2)
        XCTAssertEqual(max.fingerprint, "randomized")
    }

    func testOffHasNoObfuscation() {
        let off = MaskingProfile.off.options
        XCTAssertNil(off.fragment)
        XCTAssertTrue(off.noises.isEmpty)
    }

    func testFingerprintFromOptionsUsedWhenServerHasNone() {
        // Server without an explicit fingerprint → builder uses anti.fingerprint.
        let server = ProxyServer(name: "R", proto: .vless, address: "e.com", port: 443,
                                 credential: "u", network: .tcp, security: .reality,
                                 realityPublicKey: "PBK")
        var anti = AntiCensorshipOptions.balanced
        anti.fingerprint = "firefox"
        let cfg = XrayConfigBuilder().makeConfig(server: server, anti: anti)
        let outbounds = cfg["outbounds"] as! [[String: Any]]
        let proxy = outbounds.first { $0["tag"] as? String == "proxy" }!
        let reality = (proxy["streamSettings"] as! [String: Any])["realitySettings"] as! [String: Any]
        XCTAssertEqual(reality["fingerprint"] as? String, "firefox")
    }

    func testDoHDNSPresent() {
        let cfg = XrayConfigBuilder().makeConfig(server:
            ProxyServer(name: "S", proto: .shadowsocks, address: "s.com", port: 8388,
                        credential: "p", method: "aes-256-gcm"), anti: .off)
        let dns = cfg["dns"] as! [String: Any]
        let servers = dns["servers"] as! [String]
        XCTAssertTrue(servers.contains { $0.hasPrefix("https://") }, "DoH resolver expected")
    }
}
