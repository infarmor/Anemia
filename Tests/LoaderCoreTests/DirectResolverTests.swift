import XCTest
@testable import LoaderCore

/// Tests for the direct resolver's pure predicates: the fake-IP filter that
/// keeps a concurrently running sing-box/clash client from poisoning the
/// engine's server pin, and the IPv4 literal check that skips resolution.
final class DirectResolverTests: XCTestCase {

    func testFakeIPDetection() {
        // sing-box/clash fake-IP pool: the whole 198.18.0.0/15.
        XCTAssertTrue(DirectResolver.isFakeIP("198.18.0.1"))
        XCTAssertTrue(DirectResolver.isFakeIP("198.19.255.254"))
        // Real addresses — server, LAN, public — must pass.
        XCTAssertFalse(DirectResolver.isFakeIP("13.143.140.2"))
        XCTAssertFalse(DirectResolver.isFakeIP("192.168.1.24"))
        XCTAssertFalse(DirectResolver.isFakeIP("172.28.0.1"))
        // Prefix bleeding: 198.190.x is public space, not the pool.
        XCTAssertFalse(DirectResolver.isFakeIP("198.190.0.1"))
        XCTAssertFalse(DirectResolver.isFakeIP("198.180.0.1"))
        // Hostnames that merely START with the pool's octets are real,
        // resolvable domains — the old bare prefix test treated them as
        // fake-IP answers and made ipv4() refuse to even look them up.
        XCTAssertFalse(DirectResolver.isFakeIP("198.18.mirror.example.com"))
        XCTAssertFalse(DirectResolver.isFakeIP("198.19.com"))
    }

    func testIPv4LiteralCheck() {
        XCTAssertTrue(DirectResolver.isIPv4("13.143.140.2"))
        XCTAssertTrue(DirectResolver.isIPv4("198.18.0.1"))
        XCTAssertFalse(DirectResolver.isIPv4("ee.ascl.dev"))
        XCTAssertFalse(DirectResolver.isIPv4("1.2.3"))
        XCTAssertFalse(DirectResolver.isIPv4("1.2.3.999"))
        XCTAssertFalse(DirectResolver.isIPv4("::1"))
        // Empty octets: count one way, validate the other — these must NOT
        // pass as valid literals.
        XCTAssertFalse(DirectResolver.isIPv4("1..2.3"))
        XCTAssertFalse(DirectResolver.isIPv4("1.2.3."))
        XCTAssertFalse(DirectResolver.isIPv4(".1.2.3.4"))
        // Signed octets: Int("+4") parses, so a "+1.2.3.4" from a malformed
        // link must not masquerade as a resolvable literal.
        XCTAssertFalse(DirectResolver.isIPv4("+1.2.3.4"))
        XCTAssertFalse(DirectResolver.isIPv4("1.2.3.+4"))
        // Out-of-range values in disguise.
        XCTAssertFalse(DirectResolver.isIPv4("1.2.3.256"))
        XCTAssertFalse(DirectResolver.isIPv4("300.2.3.4"))
    }
}
