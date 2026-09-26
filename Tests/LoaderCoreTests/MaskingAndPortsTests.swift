import Foundation
import Testing
import Darwin
@testable import LoaderCore

struct PortFinderTests {
    @Test func testFreePortInRange() throws {
        guard let p = PortFinder.freePort() else { Issue.record("no free port"); return }
        #expect(p > 0)
        #expect(p < 65536)
    }

    @Test func testPickAvoidsExcluded() throws {
        guard let a = PortFinder.freePort() else { Issue.record("no port"); return }
        let picked = PortFinder.pick(preferred: a, exclude: [a])
        #expect(picked != a, "excluded preferred port must not be returned")
    }

    /// canConnect must see a live listener …
    @Test func testCanConnectDetectsListener() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #expect(fd >= 0)
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
        #expect(bound == 0)
        #expect(listen(fd, 1) == 0)

        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        #expect(PortFinder.canConnect(port))
    }

    /// … and must not see one where there is none.
    @Test func testCanConnectRejectsClosedPort() throws {
        guard let port = PortFinder.freePort() else {
            return /* skipped: precondition unavailable */
        }
        #expect(!PortFinder.canConnect(port))
        #expect(!PortFinder.canConnect(0))
        #expect(!PortFinder.canConnect(70000))
    }
}

struct MaskingProfileTests {
    @Test func testMaximumIsMoreAggressive() throws {
        let max = MaskingProfile.maximum.options
        #expect(max.fragment != nil)
        #expect(max.noises.count >= 2)
        #expect(max.fingerprint == "randomized")
    }

    @Test func testOffHasNoObfuscation() throws {
        let off = MaskingProfile.off.options
        #expect(off.fragment == nil)
        #expect(off.noises.isEmpty)
    }

    @Test func testFingerprintFromOptionsUsedWhenServerHasNone() throws {
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
        #expect(reality["fingerprint"] as? String == "firefox")
    }

    @Test func testDoHDNSPresent() throws {
        let cfg = try XrayConfigBuilder().makeConfig(server:
            ProxyServer(name: "S", proto: .shadowsocks, address: "s.com", port: 8388,
                        credential: "p", method: "aes-256-gcm"), anti: .off)
        let dns = cfg["dns"] as! [String: Any]
        let servers = dns["servers"] as! [String]
        #expect(servers.contains { $0.hasPrefix("https://") }, "DoH resolver expected")
    }
}

struct RussiaStealthTests {

    /// RU aliases must collapse onto real uTLS IDs — xray would reject
    /// "yandex"/"vk" as unknown ClientHello names.
    @Test func testFingerprintAliases() throws {
        #expect(AntiCensorshipOptions.utlsFingerprint("yandex") == "chrome")
        #expect(AntiCensorshipOptions.utlsFingerprint("vk") == "android")
        #expect(AntiCensorshipOptions.utlsFingerprint("firefox") == "firefox")
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
    @Test func testMimicrySNIAppliedWhenLinkHasNone() throws {
        let anti = AntiCensorshipOptions.russiaYandex
        let reality = try realitySettings(anti)
        let sni = reality["serverName"] as? String
        #expect(sni != nil, "stealth SNI expected")
        #expect(anti.mimicry.contains(sni!), "SNI must come from the mimicry pool")
        #expect(reality["fingerprint"] as? String == "chrome", "alias must map to a real uTLS ID")
    }

    /// An explicit link SNI always wins over the mimicry pool.
    @Test func testExplicitSNIWinsOverMimicry() throws {
        var server = realityServer()
        server.sni = "explicit.example.com"
        let cfg = try XrayConfigBuilder().makeConfig(server: server, anti: .russiaVK)
        let proxy = (cfg["outbounds"] as! [[String: Any]]).first { $0["tag"] as? String == "proxy" }!
        let reality = (proxy["streamSettings"] as! [String: Any])["realitySettings"] as! [String: Any]
        #expect(reality["serverName"] as? String == "explicit.example.com")
        #expect(reality["fingerprint"] as? String == "android")
    }

    /// Without a mimicry pool (old presets) no SNI is invented.
    @Test func testBalancedInventsNoSNI() throws {
        let reality = try realitySettings(.balanced)
        #expect(reality["serverName"] == nil)
    }

    private func tlsSettings(_ server: ProxyServer, _ anti: AntiCensorshipOptions) throws -> [String: Any] {
        let cfg = try XrayConfigBuilder().makeConfig(server: server, anti: anti)
        let proxy = (cfg["outbounds"] as! [[String: Any]]).first { $0["tag"] as? String == "proxy" }!
        return (proxy["streamSettings"] as! [String: Any])["tlsSettings"] as! [String: Any]
    }

    /// A validated TLS server (allowInsecure=false) with no link SNI must NOT
    /// borrow a mimicry host: a mismatched serverName would fail cert validation
    /// and break the handshake. xray defaults serverName to the address instead.
    @Test func testMimicryNotAppliedToValidatedTLS() throws {
        let server = ProxyServer(name: "T", proto: .trojan, address: "real.example.com",
                                 port: 443, credential: "p", network: .tcp, security: .tls)
        let tls = try tlsSettings(server, .russiaYandex)
        #expect(tls["serverName"] == nil, "validated TLS must not borrow a stealth SNI")
    }

    /// Xray-core 26.x removed `allowInsecure` — emitting `true` is a fatal
    /// config error. The builder must not emit the key at all, and since cert
    /// validation can no longer be skipped, an insecure-flagged server must
    /// not borrow a mimicry SNI either (it would fail validation).
    @Test func testAllowInsecureNotEmittedAndBorrowsNoSNI() throws {
        var server = ProxyServer(name: "T", proto: .trojan, address: "real.example.com",
                                 port: 443, credential: "p", network: .tcp, security: .tls)
        server.allowInsecure = true
        let tls = try tlsSettings(server, .russiaYandex)
        #expect(tls["allowInsecure"] == nil, "26.x removed allowInsecure — never emit it")
        #expect(tls["serverName"] == nil, "certs are always validated now — no mimicry borrow")
    }

    /// Persisted state from before `mimicry` existed must still decode — a
    /// synthesized decoder would fail and Persistence would wipe the store.
    @Test func testLegacyAntiOptionsDecode() throws {
        let legacy = """
        {"fragment": {"packets":"tlshello","length":"100-200","interval":"10-20"},
         "noises": [], "muxEnabled": false, "muxConcurrency": 8,
         "tcpFastOpen": true, "fingerprint": "chrome"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AntiCensorshipOptions.self, from: legacy)
        #expect(decoded.mimicry.isEmpty)
        #expect(decoded.fingerprint == "chrome")
        #expect(decoded.fragment?.length == "100-200")
    }

    /// Masking escalation walks lightest → heaviest and tops out at nil, so the
    /// recovery ladder can't loop.
    @Test func testMaskingEscalationLadder() throws {
        #expect(MaskingProfile.off.escalated == .balanced)
        #expect(MaskingProfile.balanced.escalated == .maximum)
        #expect(MaskingProfile.maximum.escalated == .ruYandex)
        #expect(MaskingProfile.ruYandex.escalated == .ruVK)
        #expect(MaskingProfile.ruVK.escalated == nil)
        // Every profile reaches the top in a bounded number of steps.
        var p: MaskingProfile? = .off, steps = 0
        while let cur = p { p = cur.escalated; steps += 1; #expect(steps < 10) }
    }

    /// Both RU presets pass xray's acceptance criteria: fragment + noise wired.
    @Test func testRussiaPresetsAreComplete() throws {
        for preset in [AntiCensorshipOptions.russiaYandex, .russiaVK] {
            #expect(preset.fragment != nil)
            #expect(preset.noises.count >= 2)
            #expect(!preset.mimicry.isEmpty)
            #expect(AntiCensorshipOptions.utlsFingerprint(preset.fingerprint) != preset.fingerprint, "RU presets must use alias fingerprints")
        }
    }
}

/// Regression tests for the two production connection failures found in the
/// field (2026-09): xray's "failed to apply socket options > invalid
/// argument" killing every dial, and the engine's own connection being
/// swallowed by a TUN (ours mid-race, or a third-party VPN on 198.18.0.1),
/// surfacing as "connection reset by peer" right after the FRAGMENT line.
struct SockoptSafetyTests {

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
    @Test func testNoTcpFastOpenAnywhere() throws {
        for anti in [AntiCensorshipOptions.off, .balanced, .maximum, .russiaYandex, .russiaVK] {
            #expect(anti.tcpFastOpen, "presets still carry the (now inert) flag")
            for s in sockopts(try outbounds(XrayConfigBuilder(), anti)) {
                #expect(s["tcpFastOpen"] == nil, "tcpFastOpen must not reach xray on Darwin")
            }
        }
    }

    /// xray's Darwin keepalive code applies Idle/Interval swapped — emitting
    /// only Idle leaves a zero write on TCP_KEEPALIVE. Both must be present
    /// (and non-zero) on the physical dialer.
    @Test func testKeepalivePairAlwaysPresent() throws {
        for anti in [AntiCensorshipOptions.off, .balanced, .russiaYandex] {
            let sk = physicalSockopts(try outbounds(XrayConfigBuilder(), anti))
            #expect(!sk.isEmpty)
            for s in sk {
                #expect(s["tcpNoDelay"] as? Bool == true)
                #expect((s["tcpKeepAliveIdle"] as? Int ?? 0) > 0)
                #expect((s["tcpKeepAliveInterval"] as? Int ?? 0) > 0)
            }
        }
    }

    /// The interface pin must land on the physical dialer: the fragment
    /// outbound when fragmenting, the proxy outbound otherwise.
    @Test func testInterfacePinOnPhysicalDialer() throws {
        var builder = XrayConfigBuilder()
        builder.dialerInterface = "en0"

        // No fragment → pin on the proxy outbound.
        let sk = sockopts(try outbounds(builder, .off))
        #expect(sk.contains { $0["interface"] as? String == "en0" })

        // Fragment → pin on the fragment dialer (owner of the real socket);
        // the proxy outbound only carries dialerProxy, never the pin.
        let cfg = try outbounds(builder, .balanced)
        let fragment = cfg.first { $0["tag"] as? String == "fragment" }!
        let fSk = (fragment["streamSettings"] as! [String: Any])["sockopt"] as! [String: Any]
        #expect(fSk["interface"] as? String == "en0")
        let proxy = cfg.first { $0["tag"] as? String == "proxy" }!
        let pSk = (proxy["streamSettings"] as! [String: Any])["sockopt"] as! [String: Any]
        #expect(pSk["interface"] == nil)
        #expect(pSk["dialerProxy"] as? String == "fragment")
    }

    /// No pin detected → no "interface" key at all (never guess).
    @Test func testNoPinWhenUndetected() throws {
        #expect(XrayConfigBuilder().dialerInterface == nil)
        for s in sockopts(try outbounds(XrayConfigBuilder(), .balanced)) {
            #expect(s["interface"] == nil)
        }
    }

    /// Smoke: the detector must find SOME non-tunnel interface on this Mac.
    @Test func testPhysicalInterfaceDetection() throws {
        let name = PhysicalInterface.primary()
        #expect(name != nil, "expected a physical interface on this machine")
        if let name {
            #expect(!name.hasPrefix("utun"), "must never pin to a tunnel: \(name)")
            #expect(!(name == "lo0"))
        }
    }
}