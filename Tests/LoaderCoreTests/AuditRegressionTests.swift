import Foundation
import Testing
@testable import LoaderCore

/// Regression tests for the 2026-09-13 full-audit findings. Each test pins
/// one specific defect (see the comment) so it cannot silently regress.
struct AuditRegressionTests {

    private let privateKey = "yAnz5TF+fT28A5vH0vGcC8pVXqv5ZfV0+0P4Rn1v5HE="
    private let publicKey = "Ox5vDWfJ9yfkXcUuJ2XgKlQSmGvvnBB0qR9vK3F2zV0="

    // MARK: Finding 1 — UTF-8 BOM before [Interface] voided the whole section

    @Test func testConfWithBOMParses() throws {
        let conf = "\u{FEFF}[Interface]\nPrivateKey = \(privateKey)\n\n[Peer]\n" +
            "PublicKey = \(publicKey)\nEndpoint = 203.0.113.7:51820\n"
        let s = try ShareLinkParser.parseConfigText(conf)
        #expect(s.credential == privateKey)
        #expect(s.proto == .wireguard)
    }

    // MARK: Finding 2 — undecodable subscription body parsed as "0 servers,
    // 0 failures" and the refresh path wiped the saved list

    @Test func testUndecodableSubscriptionSurfacesFailure() {
        let blob = "\u{FEFF}" + Data("vless://u@a.example.com:443?type=tcp#A".utf8)
            .base64EncodedString().prefix(20)   // truncated → garbage
        let r = SubscriptionParser.parse(String(blob))
        #expect(r.servers.isEmpty)
        #expect(!r.failures.isEmpty, "garbage must be reported, not silently dropped")
    }

    @Test func testBOMPrefixedSubscriptionStillDecodes() throws {
        let links = "vless://u@a.example.com:443?type=tcp#A"
        let blob = "\u{FEFF}" + Data(links.utf8).base64EncodedString()
        let r = SubscriptionParser.parse(blob)
        #expect(r.servers.count == 1)
        #expect(r.failures.isEmpty)
    }

    // MARK: Finding 3 — padding computed over non-alphabet characters

    @Test func testBase64WithStrayInteriorChar() {
        // "AB\u{200B}CDEFG" → alphabet "ABCDEFG" → payload "ABCDEFG".
        let payload = Data("ABCDEFG".utf8).base64EncodedString()
        let padded = payload.dropLast()   // unpad so the %4 matters
        let r = Base64.decodeFlexible("\u{200B}" + padded + "\u{200B}")
        #expect(r.map { String(decoding: $0, as: UTF8.self) } == "ABCDEFG")
    }

    @Test func testMultiLineSubscriptionBlobKeepsLinesSeparate() throws {
        let links = [
            "vless://u-a@a.example.com:443?type=tcp#A",
            "trojan://p@b.example.com:443?type=tcp#B"
        ].joined(separator: "\n")
        let r = SubscriptionParser.parse(Data(links.utf8).base64EncodedString())
        #expect(r.servers.count == 2)
    }

    @Test func testCRLFSubscriptionSplitsIntoServers() throws {
        // A CRLF is one grapheme cluster, so comparing each line separator to
        // "\n"/"\r" never matched one: a body served with Windows line endings
        // collapsed into a single "link" whose name swallowed every server
        // after the first.
        let links = [
            "vless://u-a@a.example.com:443?type=tcp#A",
            "trojan://p@b.example.com:443?type=tcp#B",
            "ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ@1.2.3.4:8388#C"
        ].joined(separator: "\r\n")
        #expect(SubscriptionParser.parse(Data(links.utf8).base64EncodedString()).servers.count == 3)
        let plain = SubscriptionParser.parse(links)
        #expect(plain.servers.map(\.name) == ["A", "B", "C"])
    }


    // MARK: Finding 4 — malformed varint length trapped (Int(UInt64.max))

    @Test func testParseProtobufSurvivesHugeVarintLength() {
        // 0x0a = field 1, wire type 2; a 10-byte varint of UInt64.max as the
        // length used to trap "not enough bits to represent".
        let hostile = Data([0x0a, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01])
        #expect(XrayStatsAPI.parseProtobuf(hostile) == [])
    }

    // MARK: Finding 5 — bracketed IPv6 in wireguard:// query links

    @Test func testWGQueryLinkWithBracketedIPv6() throws {
        let link = "wireguard://\(privateKey)@[2001:db8::1]:51820?publickey=\(publicKey)"
        let s = try ShareLinkParser.parse(link)
        #expect(s.address == "2001:db8::1")
        #expect(s.port == 51820)
    }

    // MARK: Finding 6 — obfuscation-only keys outside the old subset were
    // dropped entirely (conf with just ContentPaddingAddition)

    @Test func testContentPaddingOnlyConfKeepsAWG() throws {
        let conf = """
        [Interface]
        PrivateKey = \(privateKey)
        ContentPaddingAddition = 8

        [Peer]
        PublicKey = \(publicKey)
        Endpoint = 203.0.113.7:51820
        """
        let s = try ShareLinkParser.parseConfigText(conf)
        #expect(s.proto == .amnezia)
        #expect(s.awg?.contentPaddingAddition == "8")   // 3.x: a value or a range
    }

    // MARK: Finding 7 — unbracketed IPv6 authority silently misparsed

    @Test func testUnbracketedIPv6AuthorityIsRejected() throws {
        // The last hextet must not become the port.
        #expect(throws: (any Error).self) { try ShareLinkParser.parse("vless://uuid@2001:db8::1?security=tls#a") }
    }

    // MARK: Finding 9 — leading-zero octets (BSD octal interpretation)

    @Test func testIsIPv4RejectsLeadingZeros() {
        #expect(!DirectResolver.isIPv4("010.0.0.1"))
        #expect(!DirectResolver.isIPv4("017.0.0.1"))
        #expect(DirectResolver.isIPv4("10.0.0.1"))
        #expect(DirectResolver.isIPv4("0.0.0.0"))
    }

    // MARK: 2026-09-24 — found while porting the parser to Kotlin (the golden
    // comparison is what surfaced all four)

    @Test func testSubscriptionDeduplicatesIdenticalLinks() throws {
        // Two identical lines used to become two rows with two ids: every probe
        // ran twice, and each refresh grew the list again.
        let line = "vless://u-a@a.example.com:443?type=tcp#A"
        let blob = Data("\(line)\n\(line)\n".utf8).base64EncodedString()
        let r = SubscriptionParser.parse(blob)
        #expect(r.servers.count == 1)
        #expect(r.servers.first?.name == "A")
    }

    @Test func testBarePercentInCredentialIsKept() throws {
        // Panels hand out random ASCII passwords, and a "%" that is not part of
        // an escape made removingPercentEncoding return nil — the import then
        // reported missingField("password") for a link that carried one.
        let server = try ShareLinkParser.parse("trojan://ab%cd@example.com:443")
        #expect(server.credential == "ab%cd")
    }

    @Test func testCollidingQueryCaseDoesNotTrap() throws {
        // Dictionary(uniqueKeysWithValues:) trapped on keys that collide after
        // lowercasing: one such link in a subscription crashed the app during
        // import. The lowercase spelling now wins, deterministically.
        let forward = try ShareLinkParser.parse("hysteria2://t@example.com:443?Obfs=x&obfs=y#A")
        let reversed = try ShareLinkParser.parse("hysteria2://t@example.com:443?obfs=y&Obfs=x#A")
        #expect(forward.userData?["obfs"] == "y")
        #expect(reversed.userData?["obfs"] == "y")
    }

    @Test func testHysteriaObfsSpellingIsDeterministic() throws {
        // The winner used to depend on Swift's per-launch dictionary order, so
        // the same link imported with one password or the other.
        let server = try ShareLinkParser.parse(
            "hysteria2://t@example.com:443?obfsPassword=a&obfs-password=b#A")
        #expect(server.userData?["obfsPassword"] == "b")
    }

    @Test func testHysteriaPinMustBeHexSha256() throws {
        // The engine's own rule (infra/conf/transport_internet.go): commas
        // separate pins, colons are the OpenSSL spelling, 32 bytes are not
        // negotiable. A panel that hands out a short pin used to produce a
        // config the engine refused at start with a Go line.
        let pin = String(repeating: "aa3f", count: 16)
        #expect(XrayConfigBuilder.isSha256PinList(pin))
        #expect(XrayConfigBuilder.isSha256PinList(pin.enumerated().map { "\($0.offset % 2 == 0 ? "" : ":")\($0.element)" }.joined()))
        #expect(XrayConfigBuilder.isSha256PinList("\(pin),\(pin)"))
        #expect(!XrayConfigBuilder.isSha256PinList("zz3f"))
        #expect(!XrayConfigBuilder.isSha256PinList("qz-v_hgJfD02b0x0a4zZ3FzKvGJ2Y3F4YjY4ZWhfMnE"))
        #expect(!XrayConfigBuilder.isSha256PinList(""))
    }

    @Test func testVlessEncryptionGrammar() {
        // From infra/conf/vless.go of the pinned engine; verified end to end by
        // running every golden config through `xray run -test`.
        let key = "OLTmUuRlCZOJdLBFXchZUXaILBmMjEYyQnHlJXKvY5o"      // 32 bytes, unpadded URL-safe
        #expect(XrayConfigBuilder.isVlessEncryptionKey("mlkem768x25519plus.native.1rtt.\(key)"))
        #expect(XrayConfigBuilder.isVlessEncryptionKey("mlkem768x25519plus.xorpub.0rtt.\(key).\(key)"))
        #expect(!XrayConfigBuilder.isVlessEncryptionKey("1b232a42dc540bc1"))
        #expect(!XrayConfigBuilder.isVlessEncryptionKey("mlkem768x25519plus.native.2rtt.\(key)"))
        #expect(!XrayConfigBuilder.isVlessEncryptionKey("mlkem768x25519plus.ec.1rtt.\(key)"))
        #expect(!XrayConfigBuilder.isVlessEncryptionKey("mlkem768x25519plus.native.1rtt.\(key)=="))
    }
}
