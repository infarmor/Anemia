import Foundation
import Testing
@testable import LoaderCore

/// Tests for the direct resolver's pure predicates: the fake-IP filter that
/// keeps a concurrently running sing-box/clash client from poisoning the
/// engine's server pin, and the IPv4 literal check that skips resolution.
struct DirectResolverTests {

    @Test func testFakeIPDetection() {
        // sing-box/clash fake-IP pool: the whole 198.18.0.0/15.
        #expect(DirectResolver.isFakeIP("198.18.0.1"))
        #expect(DirectResolver.isFakeIP("198.19.255.254"))
        // Real addresses — server, LAN, public — must pass.
        #expect(!DirectResolver.isFakeIP("13.143.140.2"))
        #expect(!DirectResolver.isFakeIP("192.168.1.24"))
        #expect(!DirectResolver.isFakeIP("172.28.0.1"))
        // Prefix bleeding: 198.190.x is public space, not the pool.
        #expect(!DirectResolver.isFakeIP("198.190.0.1"))
        #expect(!DirectResolver.isFakeIP("198.180.0.1"))
        // Hostnames that merely START with the pool's octets are real,
        // resolvable domains — the old bare prefix test treated them as
        // fake-IP answers and made ipv4() refuse to even look them up.
        #expect(!DirectResolver.isFakeIP("198.18.mirror.example.com"))
        #expect(!DirectResolver.isFakeIP("198.19.com"))
    }

    @Test func testIPv4LiteralCheck() {
        #expect(DirectResolver.isIPv4("13.143.140.2"))
        #expect(DirectResolver.isIPv4("198.18.0.1"))
        #expect(!DirectResolver.isIPv4("ee.ascl.dev"))
        #expect(!DirectResolver.isIPv4("1.2.3"))
        #expect(!DirectResolver.isIPv4("1.2.3.999"))
        #expect(!DirectResolver.isIPv4("::1"))
        // Empty octets: count one way, validate the other — these must NOT
        // pass as valid literals.
        #expect(!DirectResolver.isIPv4("1..2.3"))
        #expect(!DirectResolver.isIPv4("1.2.3."))
        #expect(!DirectResolver.isIPv4(".1.2.3.4"))
        // Signed octets: Int("+4") parses, so a "+1.2.3.4" from a malformed
        // link must not masquerade as a resolvable literal.
        #expect(!DirectResolver.isIPv4("+1.2.3.4"))
        #expect(!DirectResolver.isIPv4("1.2.3.+4"))
        // Out-of-range values in disguise.
        #expect(!DirectResolver.isIPv4("1.2.3.256"))
        #expect(!DirectResolver.isIPv4("300.2.3.4"))
    }
}
