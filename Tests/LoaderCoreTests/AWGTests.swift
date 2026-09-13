import XCTest
@testable import LoaderCore

/// AmneziaWG / WireGuard support: conf parsing, share-link parsing, UAPI
/// script generation and the silent-failure validators.
final class AWGTests: XCTestCase {

    // MARK: Conf parsing

    // 44-char base64 (32-byte) keys — the real-world shape validators check.
    private let privateKey = "yAnz5TF+fT28A5vH0vGcC8pVXqv5ZfV0+0P4Rn1v5HE="
    private let publicKey = "Ox5vDWfJ9yfkXcUuJ2XgKlQSmGvvnBB0qR9vK3F2zV0="
    private let psk = "zAnz5TF+fT28A5vH0vGcC8pVXqv5ZfV0+0P4Rn1v5HA="

    private let v2Conf = """
    [Interface]
    PrivateKey = KEY_PRIVATE
    Address = 10.8.1.2/24
    DNS = 1.1.1.1, 8.8.8.8
    MTU = 1280
    Jc = 5
    Jmin = 40
    Jmax = 70
    S1 = 86
    S2 = 100
    S3 = 39
    S4 = 68
    H1 = 1234567-1234599
    H2 = 7654321
    H3 = 1122334455
    H4 = 4444444

    [Peer]
    PublicKey = KEY_PUBLIC
    PresharedKey = KEY_PSK
    AllowedIPs = 0.0.0.0/0, ::/0
    Endpoint = 203.0.113.7:51820
    PersistentKeepalive = 25
    """

    private func conf(_ template: String) -> String {
        template
            .replacingOccurrences(of: "KEY_PRIVATE", with: privateKey)
            .replacingOccurrences(of: "KEY_PUBLIC", with: publicKey)
            .replacingOccurrences(of: "KEY_PSK", with: psk)
    }

    private func v2Server() throws -> ProxyServer {
        try ShareLinkParser.parseConfigText(conf(v2Conf))
    }

    private let plainConf = """
    [Interface]
    PrivateKey = KEY_PRIVATE

    [Peer]
    PublicKey = KEY_PUBLIC
    Endpoint = 10.0.0.1:51820
    """

    func testParseV2Conf() throws {
        let s = try v2Server()
        XCTAssertEqual(s.proto, .amnezia)
        XCTAssertEqual(s.address, "203.0.113.7")
        XCTAssertEqual(s.port, 51820)
        XCTAssertEqual(s.credential, privateKey)
        let o = try XCTUnwrap(s.awg)
        XCTAssertEqual(o.junkPackets, 5)
        XCTAssertEqual(o.junkMin, 40)
        XCTAssertEqual(o.junkMax, 70)
        XCTAssertEqual(o.initPadding, 86)
        XCTAssertEqual(o.responsePadding, 100)
        XCTAssertEqual(o.cookiePadding, 39)
        XCTAssertEqual(o.transportPadding, 68)
        XCTAssertEqual(o.header1, "1234567-1234599")
        XCTAssertEqual(o.header2, "7654321")
        XCTAssertEqual(o.header3, "1122334455")
        XCTAssertEqual(o.header4, "4444444")
        XCTAssertEqual(AWGVersion.detect(from: o), .v2)
        let p = try XCTUnwrap(s.wgProfile)
        XCTAssertEqual(p.peerPublicKey, publicKey)
        XCTAssertEqual(p.presharedKey, psk)
        XCTAssertEqual(p.keepAlive, 25)
        XCTAssertEqual(p.mtu, 1280)
        XCTAssertEqual(p.dns, ["1.1.1.1", "8.8.8.8"])
    }

    func testV31ConfDetection() throws {
        let s = try ShareLinkParser.parseConfigText("""
        [Interface]
        PrivateKey = \(privateKey)
        HeaderProtectionKey = 00112233445566778899aabbccddeeff
        RandomTrailers = true
        DisableCookies = true

        [Peer]
        PublicKey = \(publicKey)
        Endpoint = awg.example.com:443
        """)
        XCTAssertEqual(AWGVersion.detect(from: s.awg), .v31)
        XCTAssertEqual(s.address, "awg.example.com")
        XCTAssertEqual(s.port, 443)
        XCTAssertEqual(s.awg?.randomTrailers, true)
        XCTAssertEqual(s.awg?.disableCookies, true)
    }

    func testPlainConfBecomesWireGuard() throws {
        let s = try ShareLinkParser.parseConfigText(conf(plainConf))
        XCTAssertEqual(s.proto, .wireguard)
        XCTAssertNil(s.awg)
    }

    func testMissingKeysFailLoudly() {
        XCTAssertThrowsError(try ShareLinkParser.parseConfigText("[Interface]\nMTU = 1280"))
        let noPeerKey = """
        [Interface]
        PrivateKey = \(privateKey)

        [Peer]
        Endpoint = 10.0.0.1:51820
        """
        XCTAssertThrowsError(try ShareLinkParser.parseConfigText(noPeerKey))
        let noEndpoint = """
        [Interface]
        PrivateKey = \(privateKey)

        [Peer]
        PublicKey = \(publicKey)
        """
        XCTAssertThrowsError(try ShareLinkParser.parseConfigText(noEndpoint))
    }

    // MARK: Share links

    func testAmneziaBase64Link() throws {
        let b64 = Data(conf(v2Conf).utf8).base64EncodedString()
        let s = try ShareLinkParser.parse("amnezia://\(b64)#My%20AWG")
        XCTAssertEqual(s.proto, .amnezia)
        XCTAssertEqual(s.name, "My AWG")
        XCTAssertEqual(s.port, 51820)
        XCTAssertEqual(s.credential, privateKey)
    }

    func testWireGuardQueryLink() throws {
        let link = "wireguard://\(privateKey)@203.0.113.9:51820" +
            "?publickey=\(publicKey)&presharedKey=\(psk)&allowedips=0.0.0.0/0,::/0" +
            "&mtu=1280&keepalive=25" +
            "&junkPacketCount=7&junkPacketMinSize=40&junkPacketMaxSize=70&initPacketJunkSize=86" +
            "&responsePacketJunkSize=100&magicHeader1=1234&magicHeader4=5678"
        let s = try ShareLinkParser.parse(link)
        XCTAssertEqual(s.proto, .wireguard)
        XCTAssertEqual(s.address, "203.0.113.9")
        XCTAssertEqual(s.port, 51820)
        let o = try XCTUnwrap(s.awg)
        XCTAssertEqual(o.junkPackets, 7)
        XCTAssertEqual(o.junkMin, 40)
        XCTAssertEqual(o.junkMax, 70)
        XCTAssertEqual(o.initPadding, 86)
        XCTAssertEqual(o.responsePadding, 100)
        XCTAssertEqual(o.header1, "1234")
        XCTAssertEqual(o.header4, "5678")
        XCTAssertEqual(s.wgProfile?.peerPublicKey, publicKey)
        XCTAssertEqual(s.wgProfile?.mtu, 1280)
        XCTAssertEqual(s.wgProfile?.keepAlive, 25)
    }

    func testAmneziaQueryLinkWithoutParamsStillParses() throws {
        let link = "amnezia://\(privateKey)@203.0.113.5:51820?publickey=\(publicKey)"
        let s = try ShareLinkParser.parse(link)
        XCTAssertEqual(s.proto, .amnezia)
        XCTAssertNotNil(s.awg)   // explicit empty obfuscation set
        XCTAssertEqual(s.wgProfile?.peerPublicKey, publicKey)
    }

    // MARK: UAPI script

    func testUAPIScriptKeys() throws {
        let s = try v2Server()
        let script = try AmneziaWGConfigBuilder.makeUAPISetScript(server: s)
        XCTAssertTrue(script.hasPrefix("set=1\n"))
        XCTAssertTrue(script.contains("private_key=\(privateKey)"))
        XCTAssertTrue(script.contains("jc=5"))
        XCTAssertTrue(script.contains("jmin=40"))
        XCTAssertTrue(script.contains("jmax=70"))
        XCTAssertTrue(script.contains("s1=86"))
        XCTAssertTrue(script.contains("s2=100"))
        XCTAssertTrue(script.contains("s3=39"))
        XCTAssertTrue(script.contains("s4=68"))
        XCTAssertTrue(script.contains("h1=1234567-1234599"))
        XCTAssertTrue(script.contains("h4=4444444"))
        XCTAssertTrue(script.contains("public_key=\(publicKey)"))
        XCTAssertTrue(script.contains("preshared_key=\(psk)"))
        XCTAssertTrue(script.contains("endpoint=203.0.113.7:51820"))
        XCTAssertTrue(script.contains("persistent_keepalive_interval=25"))
        XCTAssertTrue(script.contains("replace_allowed_ips=true"))
        XCTAssertTrue(script.contains("allowed_ip=0.0.0.0/0"))
        XCTAssertTrue(script.contains("allowed_ip=::/0"))
        XCTAssertTrue(script.contains("protocol_version=1"))
    }

    func testPlainWireGuardScriptHasNoObfuscationKeys() throws {
        let plain = try ShareLinkParser.parseConfigText(conf(plainConf))
        XCTAssertEqual(plain.proto, .wireguard)
        let script = try AmneziaWGConfigBuilder.makeUAPISetScript(server: plain)
        XCTAssertFalse(script.contains("jc="))
        XCTAssertFalse(script.contains("h1="))
        XCTAssertFalse(script.contains("s1="))
        XCTAssertTrue(script.contains("private_key="))
        XCTAssertTrue(script.contains("protocol_version=1"))
    }

    // MARK: Silent-failure validation

    func testS1Plus56Trap() throws {
        var s = try v2Server()
        var o = s.awg!
        o.initPadding = 44
        o.responsePadding = 100   // 44 + 56 = 100
        s.awg = o
        let problems = AmneziaWGConfigBuilder.validate(server: s)
        XCTAssertTrue(problems.contains { $0.contains("indistinguishable") }, "\(problems)")
    }

    func testOverlappingHeaderRanges() throws {
        var s = try v2Server()
        var o = s.awg!
        o.header1 = "100-200"
        o.header2 = "150-180"     // overlaps H1
        s.awg = o
        let problems = AmneziaWGConfigBuilder.validate(server: s)
        XCTAssertTrue(problems.contains { $0.contains("overlaps") }, "\(problems)")
    }

    func testJmaxAboveMTUFlagged() throws {
        var s = try v2Server()
        var o = s.awg!
        o.junkMax = 1500          // ≥ 1420 MTU
        s.awg = o
        let problems = AmneziaWGConfigBuilder.validate(server: s, mtu: 1420)
        XCTAssertTrue(problems.contains { $0.contains("fragmented") }, "\(problems)")
    }

    func testValidConfigHasNoProblems() throws {
        let s = try v2Server()
        XCTAssertEqual(AmneziaWGConfigBuilder.validate(server: s, mtu: 1280), [])
    }

    // MARK: Xray rejection

    func testXrayConfigBuilderRejectsWireGuardFamily() throws {
        let builder = XrayConfigBuilder()
        let s = try v2Server()
        XCTAssertThrowsError(try builder.makeConfigData(server: s, anti: AntiCensorshipOptions())) { error in
            XCTAssertTrue(error.localizedDescription.contains("AmneziaWG"), "unexpected: \(error)")
        }
    }

    // MARK: Netstat counters

    func testNetstatParsing() {
        let output = """
        Name  Mtu   Network       Address        Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
        lo0   16384 <Link#1>                       1234     0    1234567     1234     0    1234567     0
        utun5 1380  <Link#18>                     2000     0  1000000000     1500     0   50000000     0
        utun6 1380  <Link#19>                       10     0       1000       10     0       2000     0
        """
        let r = AmneziaWGConfigBuilder.parseNetstatCounters(output, interface: "utun5")
        XCTAssertEqual(r?.down, 1_000_000_000)
        XCTAssertEqual(r?.up, 50_000_000)
        XCTAssertNil(AmneziaWGConfigBuilder.parseNetstatCounters(output, interface: "utun99"))
    }

    // MARK: Header range parsing

    func testHeaderRangeParsing() {
        XCTAssertEqual(AmneziaWGConfigBuilder.parseHeaderRange("1234567"), 1_234_567...1_234_567)
        XCTAssertEqual(AmneziaWGConfigBuilder.parseHeaderRange("100-200"), 100...200)
        XCTAssertEqual(AmneziaWGConfigBuilder.parseHeaderRange("0x1F"), 31...31)
        XCTAssertNil(AmneziaWGConfigBuilder.parseHeaderRange("abc"))
        XCTAssertNil(AmneziaWGConfigBuilder.parseHeaderRange("200-100"))
    }
}