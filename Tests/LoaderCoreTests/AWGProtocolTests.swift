import Foundation
import Testing
@testable import LoaderCore

/// AmneziaWG 2.0 / 3.0 / 3.1 against the engine's real contract
/// (amneziawg-go device/uapi.go, amneziawg-tools config.c).
struct AWGProtocolTests {
    private let privateKey = "yAnz5TF+fT28A5vH0vGcC8pVXqv5ZfV0+0P4Rn1v5HE="
    private let publicKey = "Ox5vDWfJ9yfkXcUuJ2XgKlQSmGvvnBB0qR9vK3F2zV0="
    private let protectionKey = "zAnz5TF+fT28A5vH0vGcC8pVXqv5ZfV0+0P4Rn1v5HA="

    private func v31Conf(extra: String = "") -> String {
        """
        [Interface]
        PrivateKey = \(privateKey)
        Address = 10.8.1.2/32
        MTU = 1280
        Jc = 4
        Jmin = 40
        Jmax = 70
        S1 = 32
        S2 = 48
        S3 = 24
        S4 = 16
        H1 = 100000-100200
        H2 = 200000-200200
        H3 = 300000-300200
        H4 = 400000-400200
        I1 = <r 128>
        HeaderProtectionKey = \(protectionKey)
        ContentPaddingAddition = 10-40
        RekeyAfterTime = 110-130
        RekeyTimeout = 4-6
        RejectAfterTime = 170-190
        KeepaliveTimeout = 9-11
        MaxHandshakeAttempts = 18-22
        RandomTrailers = on
        DisableCookies = off
        \(extra)

        [Peer]
        PublicKey = \(publicKey)
        AllowedIPs = 0.0.0.0/0
        Endpoint = awg.example.com:443
        PersistentKeepalive = 25
        """
    }

    @Test func parsesTheFull31ParameterSet() throws {
        let s = try ShareLinkParser.parseConfigText(v31Conf())
        let o = try #require(s.awg)
        #expect(s.proto == .amnezia)
        #expect(o.specialHandshakes == ["<r 128>"])
        #expect(o.contentPaddingAddition == "10-40")
        #expect(o.rekeyAfterTime == "110-130")
        #expect(o.rekeyTimeout == "4-6")
        #expect(o.rejectAfterTime == "170-190")
        #expect(o.keepaliveTimeout == "9-11")
        #expect(o.maxHandshakeAttempts == "18-22")
        #expect(o.randomTrailers == true)        // "on"
        #expect(o.disableCookies == false)       // "off"
        #expect(AWGVersion.detect(from: o) == .v31)
        #expect(AmneziaWGConfigBuilder.validate(server: s, mtu: 1280) == [])
    }

    @Test func uapiScriptSpeaksTheEnginesFormat() throws {
        let s = try ShareLinkParser.parseConfigText(v31Conf())
        let script = try AmneziaWGConfigBuilder.makeUAPISetScript(server: s)
        let lines = Set(script.split(separator: "\n").map(String.init))
        let hex = { (key: String) in AmneziaWGConfigBuilder.hexKey(key)! }
        #expect(lines.contains("private_key=\(hex(privateKey))"))
        #expect(lines.contains("public_key=\(hex(publicKey))"))
        #expect(lines.contains("header_protection_key=\(hex(protectionKey))"))
        #expect(lines.contains("content_padding_addition=10-40"))
        #expect(lines.contains("rekey_after_time=110-130"))
        #expect(lines.contains("rekey_timeout=4-6"))
        #expect(lines.contains("reject_after_time=170-190"))
        #expect(lines.contains("keepalive_timeout=9-11"))
        #expect(lines.contains("max_handshake_attempts=18-22"))
        #expect(lines.contains("random_trailers=true"))
        #expect(lines.contains("disable_cookies=false"))
        #expect(lines.contains("i1=<r 128>"))
        #expect(lines.contains("h1=100000-100200"))
        for key in [privateKey, publicKey, protectionKey] {
            #expect(!script.contains(key), "base64 key leaked into UAPI: \(key)")
        }
    }

    @Test func hexKeyConversion() {
        let hex = AmneziaWGConfigBuilder.hexKey(privateKey)
        #expect(hex?.count == 64)
        #expect(hex == hex?.lowercased())
        #expect(AmneziaWGConfigBuilder.hexKey(hex!) == hex)                 // already hex
        #expect(AmneziaWGConfigBuilder.hexKey(hex!.uppercased()) == hex)
        #expect(AmneziaWGConfigBuilder.hexKey("not-a-key") == nil)
        #expect(AmneziaWGConfigBuilder.hexKey("AAAA") == nil)               // 3 bytes
        #expect(Data(base64Encoded: privateKey)?.first.map { String(format: "%02x", $0) } == String(hex!.prefix(2)))
    }

    @Test func headerProtectionNeedsEveryPaddingAtTwelve() throws {
        var s = try ShareLinkParser.parseConfigText(v31Conf())
        s.awg?.initPadding = 8
        s.awg?.cookiePadding = nil
        let problems = AmneziaWGConfigBuilder.validate(server: s, mtu: 1280)
        #expect(problems.contains { $0.contains("S1–S4 ≥ 12") && $0.contains("S1 = 8") && $0.contains("S3 = unset") }, "\(problems)")
    }

    @Test func badRangesAndKeysAreCaught() throws {
        var s = try ShareLinkParser.parseConfigText(v31Conf())
        s.awg?.contentPaddingAddition = "40-10"
        s.awg?.rekeyTimeout = "70000"
        s.awg?.headerProtectionKey = "short"
        let problems = AmneziaWGConfigBuilder.validate(server: s, mtu: 1280)
        #expect(problems.contains { $0.contains("ContentPaddingAddition") })
        #expect(problems.contains { $0.contains("RekeyTimeout") })
        #expect(problems.contains { $0.contains("HeaderProtectionKey") })
        #expect(throws: (any Error).self) { try AmneziaWGConfigBuilder.makeUAPISetScript(server: s) }
    }

    /// 1.0 configs often set junk and padding only — unset H1–H4 keep
    /// WireGuard's defaults and must not block the connection.
    @Test func unsetHeadersAreLegal() throws {
        let s = try ShareLinkParser.parseConfigText("""
        [Interface]
        PrivateKey = \(privateKey)
        Jc = 3
        Jmin = 50
        Jmax = 1000
        S1 = 20
        S2 = 30

        [Peer]
        PublicKey = \(publicKey)
        Endpoint = 198.51.100.4:51820
        """)
        #expect(AWGVersion.detect(from: s.awg) == .v1)
        #expect(AmneziaWGConfigBuilder.validate(server: s) == [])
        let script = try AmneziaWGConfigBuilder.makeUAPISetScript(server: s)
        #expect(!script.contains("h1="))
    }

    /// amneziawg-go#186: RandomTrailers + wide H1–H3 ranges drop packets.
    @Test func randomTrailersWideRangeWarning() throws {
        var s = try ShareLinkParser.parseConfigText(v31Conf())
        #expect(AmneziaWGConfigBuilder.warnings(server: s) == [])          // narrow ranges: fine
        s.awg?.header1 = "100000000-400000000"
        s.awg?.header2 = "500000000-900000000"
        let warnings = AmneziaWGConfigBuilder.warnings(server: s)
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("#186") == true)
        s.awg?.randomTrailers = false
        #expect(AmneziaWGConfigBuilder.warnings(server: s) == [])
    }

    @Test func queryLinkCarries3xKeys() throws {
        let link = "amnezia://\(privateKey)@203.0.113.5:51820?publickey=\(publicKey)" +
            "&s1=20&s2=40&s3=20&s4=20&contentpaddingaddition=5-15&rekeyaftertime=100-140" +
            "&randomtrailers=1&i1=%3Cr%2064%3E"
        let s = try ShareLinkParser.parse(link)
        #expect(s.awg?.contentPaddingAddition == "5-15")
        #expect(s.awg?.rekeyAfterTime == "100-140")
        #expect(s.awg?.randomTrailers == true)
        #expect(s.awg?.specialHandshakes == ["<r 64>"])
        #expect(s.awgVersion == .v31)
    }

    /// State saved before 3.x ranges were modeled stored an integer.
    @Test func legacySavedPaddingAdditionStillDecodes() throws {
        let legacy = #"{"specialHandshakes":[],"contentPaddingAddition":12,"initPadding":20}"#
        let o = try JSONDecoder().decode(AWGObfuscation.self, from: Data(legacy.utf8))
        #expect(o.contentPaddingAddition == "12")
        #expect(o.initPadding == 20)
        let roundTrip = try JSONDecoder().decode(AWGObfuscation.self, from: JSONEncoder().encode(o))
        #expect(roundTrip == o)
        let minimal = try JSONDecoder().decode(AWGObfuscation.self, from: Data("{}".utf8))
        #expect(minimal.isEmpty)
    }
}
