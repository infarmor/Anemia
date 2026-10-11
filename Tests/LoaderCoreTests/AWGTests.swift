import Foundation
import Testing
@testable import LoaderCore

/// AmneziaWG / WireGuard support: conf parsing, share-link parsing, UAPI
/// script generation and the silent-failure validators.
struct AWGTests {

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

    @Test func testParseV2Conf() throws {
        let s = try v2Server()
        #expect(s.proto == .amnezia)
        #expect(s.address == "203.0.113.7")
        #expect(s.port == 51820)
        #expect(s.credential == privateKey)
        let o = try #require(s.awg)
        #expect(o.junkPackets == 5)
        #expect(o.junkMin == 40)
        #expect(o.junkMax == 70)
        #expect(o.initPadding == 86)
        #expect(o.responsePadding == 100)
        #expect(o.cookiePadding == 39)
        #expect(o.transportPadding == 68)
        #expect(o.header1 == "1234567-1234599")
        #expect(o.header2 == "7654321")
        #expect(o.header3 == "1122334455")
        #expect(o.header4 == "4444444")
        #expect(AWGVersion.detect(from: o) == .v2)
        let p = try #require(s.wgProfile)
        #expect(p.peerPublicKey == publicKey)
        #expect(p.presharedKey == psk)
        #expect(p.keepAlive == 25)
        #expect(p.mtu == 1280)
        #expect(p.dns == ["1.1.1.1", "8.8.8.8"])
    }

    @Test func testV31ConfDetection() throws {
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
        #expect(AWGVersion.detect(from: s.awg) == .v31)
        #expect(s.address == "awg.example.com")
        #expect(s.port == 443)
        #expect(s.awg?.randomTrailers == true)
        #expect(s.awg?.disableCookies == true)
    }

    @Test func testPlainConfBecomesWireGuard() throws {
        let s = try ShareLinkParser.parseConfigText(conf(plainConf))
        #expect(s.proto == .wireguard)
        #expect(s.awg == nil)
    }

    @Test func testMissingKeysFailLoudly() throws {
        #expect(throws: (any Error).self) { try ShareLinkParser.parseConfigText("[Interface]\nMTU = 1280") }
        let noPeerKey = """
        [Interface]
        PrivateKey = \(privateKey)

        [Peer]
        Endpoint = 10.0.0.1:51820
        """
        #expect(throws: (any Error).self) { try ShareLinkParser.parseConfigText(noPeerKey) }
        let noEndpoint = """
        [Interface]
        PrivateKey = \(privateKey)

        [Peer]
        PublicKey = \(publicKey)
        """
        #expect(throws: (any Error).self) { try ShareLinkParser.parseConfigText(noEndpoint) }
    }

    // MARK: Share links

    @Test func testAmneziaBase64Link() throws {
        let b64 = Data(conf(v2Conf).utf8).base64EncodedString()
        let s = try ShareLinkParser.parse("amnezia://\(b64)#My%20AWG")
        #expect(s.proto == .amnezia)
        #expect(s.name == "My AWG")
        #expect(s.port == 51820)
        #expect(s.credential == privateKey)
    }

    @Test func testWireGuardQueryLink() throws {
        let link = "wireguard://\(privateKey)@203.0.113.9:51820" +
            "?publickey=\(publicKey)&presharedKey=\(psk)&allowedips=0.0.0.0/0,::/0" +
            "&mtu=1280&keepalive=25" +
            "&junkPacketCount=7&junkPacketMinSize=40&junkPacketMaxSize=70&initPacketJunkSize=86" +
            "&responsePacketJunkSize=100&magicHeader1=1234&magicHeader4=5678"
        let s = try ShareLinkParser.parse(link)
        #expect(s.proto == .wireguard)
        #expect(s.address == "203.0.113.9")
        #expect(s.port == 51820)
        let o = try #require(s.awg)
        #expect(o.junkPackets == 7)
        #expect(o.junkMin == 40)
        #expect(o.junkMax == 70)
        #expect(o.initPadding == 86)
        #expect(o.responsePadding == 100)
        #expect(o.header1 == "1234")
        #expect(o.header4 == "5678")
        #expect(s.wgProfile?.peerPublicKey == publicKey)
        #expect(s.wgProfile?.mtu == 1280)
        #expect(s.wgProfile?.keepAlive == 25)
    }

    @Test func testAmneziaQueryLinkWithoutParamsStillParses() throws {
        let link = "amnezia://\(privateKey)@203.0.113.5:51820?publickey=\(publicKey)"
        let s = try ShareLinkParser.parse(link)
        #expect(s.proto == .amnezia)
        #expect(s.awg != nil)   // explicit empty obfuscation set
        #expect(s.wgProfile?.peerPublicKey == publicKey)
    }

    // MARK: UAPI script

    @Test func testUAPIScriptKeys() throws {
        let s = try v2Server()
        let script = try AmneziaWGConfigBuilder.makeUAPISetScript(server: s)
        #expect(script.hasPrefix("set=1\n"))
        let hex = { (key: String) in AmneziaWGConfigBuilder.hexKey(key)! }
        #expect(script.contains("private_key=\(hex(privateKey))"))
        #expect(!script.contains(privateKey), "UAPI keys must be hex, never base64")
        #expect(script.contains("jc=5"))
        #expect(script.contains("jmin=40"))
        #expect(script.contains("jmax=70"))
        #expect(script.contains("s1=86"))
        #expect(script.contains("s2=100"))
        #expect(script.contains("s3=39"))
        #expect(script.contains("s4=68"))
        #expect(script.contains("h1=1234567-1234599"))
        #expect(script.contains("h4=4444444"))
        #expect(script.contains("public_key=\(hex(publicKey))"))
        #expect(script.contains("preshared_key=\(hex(psk))"))
        #expect(script.contains("endpoint=203.0.113.7:51820"))
        #expect(script.contains("persistent_keepalive_interval=25"))
        #expect(script.contains("replace_allowed_ips=true"))
        #expect(script.contains("allowed_ip=0.0.0.0/0"))
        #expect(script.contains("allowed_ip=::/0"))
        #expect(script.contains("protocol_version=1"))
    }

    @Test func testPlainWireGuardScriptHasNoObfuscationKeys() throws {
        let plain = try ShareLinkParser.parseConfigText(conf(plainConf))
        #expect(plain.proto == .wireguard)
        let script = try AmneziaWGConfigBuilder.makeUAPISetScript(server: plain)
        #expect(!script.contains("jc="))
        #expect(!script.contains("h1="))
        #expect(!script.contains("s1="))
        #expect(script.contains("private_key="))
        #expect(script.contains("protocol_version=1"))
    }

    /// amneziawg-go parses `endpoint=` with netip.ParseAddrPort: a domain
    /// endpoint must reach the engine as its resolved address.
    @Test func testUAPIEndpointUsesResolvedAddress() throws {
        let s = try ShareLinkParser.parseConfigText(conf(v2Conf).replacingOccurrences(
            of: "Endpoint = 203.0.113.7:51820", with: "Endpoint = awg.example.com:51820"))
        #expect(s.address == "awg.example.com")
        let resolved = try AmneziaWGConfigBuilder.makeUAPISetScript(server: s, endpointAddress: "198.51.100.4")
        #expect(resolved.contains("endpoint=198.51.100.4:51820"))
        #expect(!resolved.contains("awg.example.com"))
        let v6 = try AmneziaWGConfigBuilder.makeUAPISetScript(server: s, endpointAddress: "2001:db8::7")
        #expect(v6.contains("endpoint=[2001:db8::7]:51820"))
    }

    /// The server accepts inner packets only from the address it assigned the
    /// peer — the utun must carry the profile's own Address.
    @Test func testTunnelAddressComesFromTheProfile() throws {
        #expect(AmneziaWGConfigBuilder.tunnelIPv4(server: try v2Server()) == "10.8.1.2")
        let plain = try ShareLinkParser.parseConfigText(conf(plainConf))
        #expect(AmneziaWGConfigBuilder.tunnelIPv4(server: plain) == nil)
        var s = try v2Server()
        for bogus in ["127.0.0.1/8", "0.0.0.0/0", "224.0.0.5/32", "fd42::2/128", "010.8.1.2/32", ""] {
            s.userData = ["wgAddress": bogus]
            #expect(AmneziaWGConfigBuilder.tunnelIPv4(server: s) == nil, "\(bogus)")
        }
        let dual = try ShareLinkParser.parseConfigText(conf(v2Conf).replacingOccurrences(
            of: "Address = 10.8.1.2/24", with: "Address = fd42:42:42::2/128, 10.66.66.2/32"))
        #expect(AmneziaWGConfigBuilder.tunnelIPv4(server: dual) == "10.66.66.2")
    }

    @Test func testQueryLinkCarriesInterfaceAddress() throws {
        let link = "wireguard://\(privateKey)@203.0.113.9:51820?publickey=\(publicKey)" +
            "&address=10.7.0.2%2F32,fd00::2%2F128"
        let s = try ShareLinkParser.parse(link)
        #expect(s.userData?["wgAddress"] == "10.7.0.2/32, fd00::2/128")
        #expect(AmneziaWGConfigBuilder.tunnelIPv4(server: s) == "10.7.0.2")
        let bare = try ShareLinkParser.parse("wg://\(privateKey)@203.0.113.9:51820?publickey=\(publicKey)&ip=10.9.0.3")
        #expect(AmneziaWGConfigBuilder.tunnelIPv4(server: bare) == "10.9.0.3")
    }

    /// A dual-stack profile was assigned both addresses, and the order in its
    /// `Address` line means nothing. Keeping only the first IPv4 — what this
    /// code used to do — sent IPv6 into a tunnel with no IPv6 address, and
    /// refused an IPv6-only profile outright.
    @Test func testBothFamiliesSurviveParsing() throws {
        func interface(_ address: String) throws -> ProxyServer {
            try ShareLinkParser.parseConfigText(conf("""
            [Interface]
            PrivateKey = KEY_PRIVATE
            Address = \(address)

            [Peer]
            PublicKey = KEY_PUBLIC
            Endpoint = 203.0.113.7:51820
            """))
        }

        let v6First = try interface("fd42:42:42::2/128, 10.66.66.2/32")
        #expect(AmneziaWGConfigBuilder.tunnelIPv4(server: v6First) == "10.66.66.2")
        #expect(AmneziaWGConfigBuilder.tunnelIPv6(server: v6First) == "fd42:42:42::2/128")

        let v6Only = try interface("fd42:42:42::2/128")
        #expect(AmneziaWGConfigBuilder.tunnelIPv4(server: v6Only) == nil)
        #expect(AmneziaWGConfigBuilder.tunnelIPv6(server: v6Only) == "fd42:42:42::2/128")

        // A bare entry gets the host prefix wg-quick would assume.
        let bare = try ShareLinkParser.parse(
            "wireguard://\(privateKey)@203.0.113.9:51820?publickey=\(publicKey)&address=10.7.0.2,fd00::2")
        #expect(bare.userData?["wgAddress"] == "10.7.0.2/32, fd00::2/128")
        #expect(AmneziaWGConfigBuilder.tunnelIPv6(server: bare) == "fd00::2/128")

        // Garbage entries are dropped rather than reaching the tunnel settings.
        let messy = try interface("not.an.address/32, 10.8.1.2/32, fd42::2/999")
        #expect(messy.userData?["wgAddress"] == "10.8.1.2/32")
    }

    // MARK: Silent-failure validation

    @Test func testS1Plus56Trap() throws {
        var s = try v2Server()
        var o = s.awg!
        o.initPadding = 44
        o.responsePadding = 100   // 44 + 56 = 100
        s.awg = o
        let problems = AmneziaWGConfigBuilder.validate(server: s)
        #expect(problems.contains { $0.contains("indistinguishable") }, "\(problems)")
    }

    @Test func testOverlappingHeaderRanges() throws {
        var s = try v2Server()
        var o = s.awg!
        o.header1 = "100-200"
        o.header2 = "150-180"     // overlaps H1
        s.awg = o
        let problems = AmneziaWGConfigBuilder.validate(server: s)
        #expect(problems.contains { $0.contains("overlaps") }, "\(problems)")
    }

    @Test func testJmaxAboveMTUFlagged() throws {
        var s = try v2Server()
        var o = s.awg!
        o.junkMax = 1500          // ≥ 1420 MTU
        s.awg = o
        let problems = AmneziaWGConfigBuilder.validate(server: s, mtu: 1420)
        #expect(problems.contains { $0.contains("fragmented") }, "\(problems)")
    }

    @Test func testValidConfigHasNoProblems() throws {
        let s = try v2Server()
        #expect(AmneziaWGConfigBuilder.validate(server: s, mtu: 1280) == [])
    }

    @Test func testOversizedPaddingIsReportedNotEvaluated() throws {
        // The S1 + 56 = S2 check is itself arithmetic on values a panel or a
        // hand-edited conf supplies: the range check above it only records a
        // problem and carries on, so `S1 = 9223372036854775807` used to trap
        // the process while it was still composing the refusal.
        var s = try v2Server()
        var o = s.awg!
        o.initPadding = .max
        o.responsePadding = 92
        s.awg = o
        let problems = AmneziaWGConfigBuilder.validate(server: s)
        #expect(problems.contains { $0.contains("S1") }, "\(problems)")
    }

    @Test func testChainSpecCannotAddLinesToTheUAPIScript() throws {
        // I1–I5 are the obfuscation values no parser looks at, and the script
        // they join is line-oriented and goes to a root daemon: a newline in
        // one of them is a second directive, not a payload.
        var s = try v2Server()
        var o = s.awg!
        o.specialHandshakes = ["<r 64>\nprivate_key=0000000000000000000000000000000000000000000000000000000000000000"]
        s.awg = o
        let problems = AmneziaWGConfigBuilder.validate(server: s)
        #expect(problems.contains { $0.contains("I1") }, "\(problems)")
        #expect(throws: (any Error).self) {
            _ = try AmneziaWGConfigBuilder.makeUAPISetScript(server: s)
        }
    }

    @Test func testAllowedIPsAreRoutes() throws {
        #expect(AmneziaWGConfigBuilder.allowedIP("10.8.1.2") == "10.8.1.2/32")   // wg-quick's host route
        #expect(AmneziaWGConfigBuilder.allowedIP(" fd42::2 ") == "fd42::2/128")
        #expect(AmneziaWGConfigBuilder.allowedIP("0.0.0.0/33") == nil)
        #expect(AmneziaWGConfigBuilder.allowedIP("everything") == nil)
        #expect(AmneziaWGConfigBuilder.allowedIP("") == nil)

        var s = try v2Server()
        s.wgProfile?.allowedIPs = ["0.0.0.0/33"]
        let problems = AmneziaWGConfigBuilder.validate(server: s)
        #expect(problems.contains { $0.contains("address/prefix") }, "\(problems)")

        s.wgProfile?.allowedIPs = ["10.8.1.2"]
        let script = try AmneziaWGConfigBuilder.makeUAPISetScript(server: s)
        #expect(script.contains("allowed_ip=10.8.1.2/32"), "\(script)")
    }

    // MARK: Xray rejection

    @Test func testXrayConfigBuilderRejectsWireGuardFamily() throws {
        let builder = XrayConfigBuilder()
        let s = try v2Server()
        if let error = #expect(throws: (any Error).self, performing: { try builder.makeConfigData(server: s, anti: AntiCensorshipOptions()) }) {
            #expect(error.localizedDescription.contains("AmneziaWG"), "unexpected: \(error)")
        }
    }

    // MARK: Netstat counters

    @Test func testNetstatParsing() {
        let output = """
        Name  Mtu   Network       Address        Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
        lo0   16384 <Link#1>                       1234     0    1234567     1234     0    1234567     0
        utun5 1380  <Link#18>                     2000     0  1000000000     1500     0   50000000     0
        utun6 1380  <Link#19>                       10     0       1000       10     0       2000     0
        """
        let r = AmneziaWGConfigBuilder.parseNetstatCounters(output, interface: "utun5")
        #expect(r?.down == 1_000_000_000)
        #expect(r?.up == 50_000_000)
        #expect(AmneziaWGConfigBuilder.parseNetstatCounters(output, interface: "utun99") == nil)
    }

    // MARK: Header range parsing

    @Test func testHeaderRangeParsing() {
        #expect(AmneziaWGConfigBuilder.parseHeaderRange("1234567") == 1_234_567...1_234_567)
        #expect(AmneziaWGConfigBuilder.parseHeaderRange("100-200") == 100...200)
        #expect(AmneziaWGConfigBuilder.parseHeaderRange("0x1F") == 31...31)
        #expect(AmneziaWGConfigBuilder.parseHeaderRange("abc") == nil)
        #expect(AmneziaWGConfigBuilder.parseHeaderRange("200-100") == nil)
    }
}