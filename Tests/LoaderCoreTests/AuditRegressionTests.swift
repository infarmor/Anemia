import XCTest
@testable import LoaderCore

/// Regression tests for the 2026-09-13 full-audit findings. Each test pins
/// one specific defect (see the comment) so it cannot silently regress.
final class AuditRegressionTests: XCTestCase {

    private let privateKey = "yAnz5TF+fT28A5vH0vGcC8pVXqv5ZfV0+0P4Rn1v5HE="
    private let publicKey = "Ox5vDWfJ9yfkXcUuJ2XgKlQSmGvvnBB0qR9vK3F2zV0="

    // MARK: Finding 1 — UTF-8 BOM before [Interface] voided the whole section

    func testConfWithBOMParses() throws {
        let conf = "\u{FEFF}[Interface]\nPrivateKey = \(privateKey)\n\n[Peer]\n" +
            "PublicKey = \(publicKey)\nEndpoint = 203.0.113.7:51820\n"
        let s = try ShareLinkParser.parseConfigText(conf)
        XCTAssertEqual(s.credential, privateKey)
        XCTAssertEqual(s.proto, .wireguard)
    }

    // MARK: Finding 2 — undecodable subscription body parsed as "0 servers,
    // 0 failures" and the refresh path wiped the saved list

    func testUndecodableSubscriptionSurfacesFailure() {
        let blob = "\u{FEFF}" + Data("vless://u@a.example.com:443?type=tcp#A".utf8)
            .base64EncodedString().prefix(20)   // truncated → garbage
        let r = SubscriptionParser.parse(String(blob))
        XCTAssertTrue(r.servers.isEmpty)
        XCTAssertFalse(r.failures.isEmpty, "garbage must be reported, not silently dropped")
    }

    func testBOMPrefixedSubscriptionStillDecodes() throws {
        let links = "vless://u@a.example.com:443?type=tcp#A"
        let blob = "\u{FEFF}" + Data(links.utf8).base64EncodedString()
        let r = SubscriptionParser.parse(blob)
        XCTAssertEqual(r.servers.count, 1)
        XCTAssertTrue(r.failures.isEmpty)
    }

    // MARK: Finding 3 — padding computed over non-alphabet characters

    func testBase64WithStrayInteriorChar() {
        // "AB\u{200B}CDEFG" → alphabet "ABCDEFG" → payload "ABCDEFG".
        let payload = Data("ABCDEFG".utf8).base64EncodedString()
        let padded = payload.dropLast()   // unpad so the %4 matters
        let r = Base64.decodeFlexible("\u{200B}" + padded + "\u{200B}")
        XCTAssertEqual(r.map { String(decoding: $0, as: UTF8.self) }, "ABCDEFG")
    }

    func testMultiLineSubscriptionBlobKeepsLinesSeparate() throws {
        let links = [
            "vless://u-a@a.example.com:443?type=tcp#A",
            "trojan://p@b.example.com:443?type=tcp#B"
        ].joined(separator: "\n")
        let r = SubscriptionParser.parse(Data(links.utf8).base64EncodedString())
        XCTAssertEqual(r.servers.count, 2)
    }

    // MARK: Finding 4 — malformed varint length trapped (Int(UInt64.max))

    func testParseProtobufSurvivesHugeVarintLength() {
        // 0x0a = field 1, wire type 2; a 10-byte varint of UInt64.max as the
        // length used to trap "not enough bits to represent".
        let hostile = Data([0x0a, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01])
        XCTAssertEqual(XrayStatsAPI.parseProtobuf(hostile), [])
    }

    // MARK: Finding 5 — bracketed IPv6 in wireguard:// query links

    func testWGQueryLinkWithBracketedIPv6() throws {
        let link = "wireguard://\(privateKey)@[2001:db8::1]:51820?publickey=\(publicKey)"
        let s = try ShareLinkParser.parse(link)
        XCTAssertEqual(s.address, "2001:db8::1")
        XCTAssertEqual(s.port, 51820)
    }

    // MARK: Finding 6 — obfuscation-only keys outside the old subset were
    // dropped entirely (conf with just ContentPaddingAddition)

    func testContentPaddingOnlyConfKeepsAWG() throws {
        let conf = """
        [Interface]
        PrivateKey = \(privateKey)
        ContentPaddingAddition = 8

        [Peer]
        PublicKey = \(publicKey)
        Endpoint = 203.0.113.7:51820
        """
        let s = try ShareLinkParser.parseConfigText(conf)
        XCTAssertEqual(s.proto, .amnezia)
        XCTAssertEqual(s.awg?.contentPaddingAddition, 8)
    }

    // MARK: Finding 7 — unbracketed IPv6 authority silently misparsed

    func testUnbracketedIPv6AuthorityIsRejected() {
        // The last hextet must not become the port.
        XCTAssertThrowsError(try ShareLinkParser.parse("vless://uuid@2001:db8::1?security=tls#a"))
    }

    // MARK: Finding 9 — leading-zero octets (BSD octal interpretation)

    func testIsIPv4RejectsLeadingZeros() {
        XCTAssertFalse(DirectResolver.isIPv4("010.0.0.1"))
        XCTAssertFalse(DirectResolver.isIPv4("017.0.0.1"))
        XCTAssertTrue(DirectResolver.isIPv4("10.0.0.1"))
        XCTAssertTrue(DirectResolver.isIPv4("0.0.0.0"))
    }
}