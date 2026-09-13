import XCTest
import Darwin
@testable import LoaderCore

final class PortFinderTests: XCTestCase {
    func testFreePortInRange() throws {
        guard let p = PortFinder.freePort() else { return XCTFail("no free port") }
        XCTAssertGreaterThan(p, 0)
        XCTAssertLessThan(p, 65536)
    }

    func testPickAvoidsExcluded() throws {
        guard let a = PortFinder.freePort() else { return XCTFail("no port") }
        let picked = PortFinder.pick(preferred: a, exclude: [a])
        XCTAssertNotEqual(picked, a, "excluded preferred port must not be returned")
    }

    /// canConnect must see a live listener …
    func testCanConnectDetectsListener() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(fd, 1), 0)

        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        XCTAssertTrue(PortFinder.canConnect(port))
    }

    /// … and must not see one where there is none.
    func testCanConnectRejectsClosedPort() throws {
        guard let port = PortFinder.freePort() else {
            throw XCTSkip("no free port available")
        }
        XCTAssertFalse(PortFinder.canConnect(port))
        XCTAssertFalse(PortFinder.canConnect(0))
        XCTAssertFalse(PortFinder.canConnect(70000))
    }
}

final class MaskingProfileTests: XCTestCase {
    func testMaximumIsMoreAggressive() throws {
        let max = MaskingProfile.maximum.options
        XCTAssertNotNil(max.fragment)
        XCTAssertGreaterThanOrEqual(max.noises.count, 2)
        XCTAssertEqual(max.fingerprint, "randomized")
    }

    func testOffHasNoObfuscation() throws {
        let off = MaskingProfile.off.options
        XCTAssertNil(off.fragment)
        XCTAssertTrue(off.noises.isEmpty)
    }

    func testFingerprintFromOptionsUsedWhenServerHasNone() throws {
        // Server without an explicit fingerprint → builder uses anti.fingerprint.
        let server = ProxyServer(name: "R", proto: .vless, address: "e.com", port: 443,
                                 credential: "u", network: .tcp, security: .reality,
                                 realityPublicKey: "PBK")
        var anti = AntiCensorshipOptions.balanced
        anti.fingerprint = "firefox"
        let cfg = try XrayConfigBuilder().makeConfig(server: server, anti: anti)
        let outbounds = cfg["outbounds"] as! [[String: Any]]
        let proxy = outbounds.first { $0["tag"] as? String == "proxy" }!
        let reality = (proxy["streamSettings"] as! [String: Any])["realitySettings"] as! [String: Any]
        XCTAssertEqual(reality["fingerprint"] as? String, "firefox")
    }

    func testDoHDNSPresent() throws {
        let cfg = try XrayConfigBuilder().makeConfig(server:
            ProxyServer(name: "S", proto: .shadowsocks, address: "s.com", port: 8388,
                        credential: "p", method: "aes-256-gcm"), anti: .off)
        let dns = cfg["dns"] as! [String: Any]
        let servers = dns["servers"] as! [String]
        XCTAssertTrue(servers.contains { $0.hasPrefix("https://") }, "DoH resolver expected")
    }
}

final class RussiaStealthTests: XCTestCase {

    /// RU aliases must collapse onto real uTLS IDs — xray would reject
    /// "yandex"/"vk" as unknown ClientHello names.
    func testFingerprintAliases() throws {
        XCTAssertEqual(AntiCensorshipOptions.utlsFingerprint("yandex"), "chrome")
        XCTAssertEqual(AntiCensorshipOptions.utlsFingerprint("vk"), "android")
        XCTAssertEqual(AntiCensorshipOptions.utlsFingerprint("firefox"), "firefox")
    }

    private func realityServer() -> ProxyServer {
        ProxyServer(name: "R", proto: .vless, address: "e.com", port: 443,
                    credential: "u", network: .tcp, security: .reality,
                    realityPublicKey: "PBK")
    }

    private func realitySettings(_ anti: AntiCensorshipOptions) throws -> [String: Any] {
        let cfg = try XrayConfigBuilder().makeConfig(server: realityServer(), anti: anti)
        let outbounds = cfg["outbounds"] as! [[String: Any]]
        let proxy = outbounds.first { $0["tag"] as? String == "proxy" }!
        return (proxy["streamSettings"] as! [String: Any])["realitySettings"] as! [String: Any]
    }

    /// No link SNI + RU preset → handshake borrows a host from the mimicry pool.
    func testMimicrySNIAppliedWhenLinkHasNone() throws {
        let anti = AntiCensorshipOptions.russiaYandex
        let reality = try realitySettings(anti)
        let sni = reality["serverName"] as? String
        XCTAssertNotNil(sni, "stealth SNI expected")
        XCTAssertTrue(anti.mimicry.contains(sni!), "SNI must come from the mimicry pool")
        XCTAssertEqual(reality["fingerprint"] as? String, "chrome", "alias must map to a real uTLS ID")
    }

    /// An explicit link SNI always wins over the mimicry pool.
    func testExplicitSNIWinsOverMimicry() throws {
        var server = realityServer()
        server.sni = "explicit.example.com"
        let cfg = try XrayConfigBuilder().makeConfig(server: server, anti: .russiaVK)
        let proxy = (cfg["outbounds"] as! [[String: Any]]).first { $0["tag"] as? String == "proxy" }!
        let reality = (proxy["streamSettings"] as! [String: Any])["realitySettings"] as! [String: Any]
        XCTAssertEqual(reality["serverName"] as? String, "explicit.example.com")
        XCTAssertEqual(reality["fingerprint"] as? String, "android")
    }

    /// Without a mimicry pool (old presets) no SNI is invented.
    func testBalancedInventsNoSNI() throws {
        let reality = try realitySettings(.balanced)
        XCTAssertNil(reality["serverName"])
    }

    private func tlsSettings(_ server: ProxyServer, _ anti: AntiCensorshipOptions) throws -> [String: Any] {
        let cfg = try XrayConfigBuilder().makeConfig(server: server, anti: anti)
        let proxy = (cfg["outbounds"] as! [[String: Any]]).first { $0["tag"] as? String == "proxy" }!
        return (proxy["streamSettings"] as! [String: Any])["tlsSettings"] as! [String: Any]
    }

    /// A validated TLS server (allowInsecure=false) with no link SNI must NOT
    /// borrow a mimicry host: a mismatched serverName would fail cert validation
    /// and break the handshake. xray defaults serverName to the address instead.
    func testMimicryNotAppliedToValidatedTLS() throws {
        let server = ProxyServer(name: "T", proto: .trojan, address: "real.example.com",
                                 port: 443, credential: "p", network: .tcp, security: .tls)
        let tls = try tlsSettings(server, .russiaYandex)
        XCTAssertNil(tls["serverName"], "validated TLS must not borrow a stealth SNI")
    }

    /// Xray-core 26.x removed `allowInsecure` — emitting `true` is a fatal
    /// config error. The builder must not emit the key at all, and since cert
    /// validation can no longer be skipped, an insecure-flagged server must
    /// not borrow a mimicry SNI either (it would fail validation).
    func testAllowInsecureNotEmittedAndBorrowsNoSNI() throws {
        var server = ProxyServer(name: "T", proto: .trojan, address: "real.example.com",
                                 port: 443, credential: "p", network: .tcp, security: .tls)
        server.allowInsecure = true
        let tls = try tlsSettings(server, .russiaYandex)
        XCTAssertNil(tls["allowInsecure"], "26.x removed allowInsecure — never emit it")
        XCTAssertNil(tls["serverName"], "certs are always validated now — no mimicry borrow")
    }

    /// Persisted state from before `mimicry` existed must still decode — a
    /// synthesized decoder would fail and Persistence would wipe the store.
    func testLegacyAntiOptionsDecode() throws {
        let legacy = """
        {"fragment": {"packets":"tlshello","length":"100-200","interval":"10-20"},
         "noises": [], "muxEnabled": false, "muxConcurrency": 8,
         "tcpFastOpen": true, "fingerprint": "chrome"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AntiCensorshipOptions.self, from: legacy)
        XCTAssertTrue(decoded.mimicry.isEmpty)
        XCTAssertEqual(decoded.fingerprint, "chrome")
        XCTAssertEqual(decoded.fragment?.length, "100-200")
    }

    /// Masking escalation walks lightest → heaviest and tops out at nil, so the
    /// recovery ladder can't loop.
    func testMaskingEscalationLadder() throws {
        XCTAssertEqual(MaskingProfile.off.escalated, .balanced)
        XCTAssertEqual(MaskingProfile.balanced.escalated, .maximum)
        XCTAssertEqual(MaskingProfile.maximum.escalated, .ruYandex)
        XCTAssertEqual(MaskingProfile.ruYandex.escalated, .ruVK)
        XCTAssertNil(MaskingProfile.ruVK.escalated)
        // Every profile reaches the top in a bounded number of steps.
        var p: MaskingProfile? = .off, steps = 0
        while let cur = p { p = cur.escalated; steps += 1; XCTAssertLessThan(steps, 10) }
    }

    /// Both RU presets pass xray's acceptance criteria: fragment + noise wired.
    func testRussiaPresetsAreComplete() throws {
        for preset in [AntiCensorshipOptions.russiaYandex, .russiaVK] {
            XCTAssertNotNil(preset.fragment)
            XCTAssertGreaterThanOrEqual(preset.noises.count, 2)
            XCTAssertFalse(preset.mimicry.isEmpty)
            XCTAssertNotEqual(AntiCensorshipOptions.utlsFingerprint(preset.fingerprint),
                              preset.fingerprint, "RU presets must use alias fingerprints")
        }
    }
}

/// Regression tests for the two production connection failures found in the
/// field (2026-09): xray's "failed to apply socket options > invalid
/// argument" killing every dial, and the engine's own connection being
/// swallowed by a TUN (ours mid-race, or a third-party VPN on 198.18.0.1),
/// surfacing as "connection reset by peer" right after the FRAGMENT line.
final class SockoptSafetyTests: XCTestCase {

    private func server() -> ProxyServer {
        ProxyServer(name: "S", proto: .vless, address: "e.com", port: 443,
                    credential: "u", network: .tcp, security: .none)
    }

    private func outbounds(_ builder: XrayConfigBuilder, _ anti: AntiCensorshipOptions) throws -> [[String: Any]] {
        try builder.makeConfig(server: server(), anti: anti)["outbounds"] as! [[String: Any]]
    }

    private func sockopts(_ cfg: [[String: Any]]) -> [[String: Any]] {
        cfg.compactMap {
            (($0["streamSettings"] as? [String: Any])?["sockopt"]) as? [String: Any]
        }
    }

    /// Sockopts of the outbound that owns the physical socket: the fragment
    /// dialer when fragmenting (the proxy outbound there only carries
    /// `dialerProxy`), the proxy outbound otherwise.
    private func physicalSockopts(_ cfg: [[String: Any]]) -> [[String: Any]] {
        sockopts(cfg).filter { $0["dialerProxy"] == nil }
    }

    /// Xray-core#989: on Darwin, "tcpFastOpen": true makes xray's TFO
    /// setsockopt fail with EINVAL — fatal per dial, log spam "failed to
    /// apply socket options > invalid argument". The builder must never emit
    /// it, no matter which preset requests it (`.off` historically did!).
    func testNoTcpFastOpenAnywhere() throws {
        for anti in [AntiCensorshipOptions.off, .balanced, .maximum, .russiaYandex, .russiaVK] {
            XCTAssertTrue(anti.tcpFastOpen, "presets still carry the (now inert) flag")
            for s in sockopts(try outbounds(XrayConfigBuilder(), anti)) {
                XCTAssertNil(s["tcpFastOpen"], "tcpFastOpen must not reach xray on Darwin")
            }
        }
    }

    /// xray's Darwin keepalive code applies Idle/Interval swapped — emitting
    /// only Idle leaves a zero write on TCP_KEEPALIVE. Both must be present
    /// (and non-zero) on the physical dialer.
    func testKeepalivePairAlwaysPresent() throws {
        for anti in [AntiCensorshipOptions.off, .balanced, .russiaYandex] {
            let sk = physicalSockopts(try outbounds(XrayConfigBuilder(), anti))
            XCTAssertFalse(sk.isEmpty)
            for s in sk {
                XCTAssertEqual(s["tcpNoDelay"] as? Bool, true)
                XCTAssertGreaterThan(s["tcpKeepAliveIdle"] as? Int ?? 0, 0)
                XCTAssertGreaterThan(s["tcpKeepAliveInterval"] as? Int ?? 0, 0)
            }
        }
    }

    /// The interface pin must land on the physical dialer: the fragment
    /// outbound when fragmenting, the proxy outbound otherwise.
    func testInterfacePinOnPhysicalDialer() throws {
        var builder = XrayConfigBuilder()
        builder.dialerInterface = "en0"

        // No fragment → pin on the proxy outbound.
        let sk = sockopts(try outbounds(builder, .off))
        XCTAssertTrue(sk.contains { $0["interface"] as? String == "en0" })

        // Fragment → pin on the fragment dialer (owner of the real socket);
        // the proxy outbound only carries dialerProxy, never the pin.
        let cfg = try outbounds(builder, .balanced)
        let fragment = cfg.first { $0["tag"] as? String == "fragment" }!
        let fSk = (fragment["streamSettings"] as! [String: Any])["sockopt"] as! [String: Any]
        XCTAssertEqual(fSk["interface"] as? String, "en0")
        let proxy = cfg.first { $0["tag"] as? String == "proxy" }!
        let pSk = (proxy["streamSettings"] as! [String: Any])["sockopt"] as! [String: Any]
        XCTAssertNil(pSk["interface"])
        XCTAssertEqual(pSk["dialerProxy"] as? String, "fragment")
    }

    /// No pin detected → no "interface" key at all (never guess).
    func testNoPinWhenUndetected() throws {
        XCTAssertNil(XrayConfigBuilder().dialerInterface)
        for s in sockopts(try outbounds(XrayConfigBuilder(), .balanced)) {
            XCTAssertNil(s["interface"])
        }
    }

    /// Smoke: the detector must find SOME non-tunnel interface on this Mac.
    func testPhysicalInterfaceDetection() throws {
        let name = PhysicalInterface.primary()
        XCTAssertNotNil(name, "expected a physical interface on this machine")
        if let name {
            XCTAssertFalse(name.hasPrefix("utun"), "must never pin to a tunnel: \(name)")
            XCTAssertFalse(name == "lo0")
        }
    }
}