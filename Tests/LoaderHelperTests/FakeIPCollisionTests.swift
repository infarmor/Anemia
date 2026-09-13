import XCTest
@testable import LoaderHelper

/// Regression tests for the tunnel address-collision gate. The fixtures
/// reproduce the real-world state that motivated it: a sing-box client (Happ)
/// on utun8 holding 198.18.0.1/16 — which was our tunnel endpoint until the
/// move to 172.28.0.0/24 — plus the new coexistence cases: a fake-IP /16
/// foreign VPN must NOT trip the gate anymore, while anything squatting in
/// our /24 (or on our gateway) must.
final class FakeIPCollisionTests: XCTestCase {

    private let fixtures = """
    lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
    \tinet 127.0.0.1 netmask 0xff000000
    en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
    \tinet 192.168.1.24 netmask 0xffffff00 broadcast 192.168.1.255
    utun8: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500
    \tinet 198.18.0.1 --> 198.18.0.1 netmask 0xffff0000
    """

    /// ifconfig parses: physical, loopback and the sing-box /16 all present.
    func testParseInetHolders() {
        let holders = SystemCommand.parseInetHolders(fixtures)
        XCTAssertEqual(holders["lo0"], ["127.0.0.1"])
        XCTAssertEqual(holders["en0"], ["192.168.1.24"])
        XCTAssertEqual(holders["utun8"], ["198.18.0.1"])
    }

    /// The coexistence win: with our tunnel on 172.28.0.0/24, a fake-IP VPN
    /// holding 198.18.0.0/15 is no longer a collision — both must run.
    func testFakeIPRangeNoLongerCollides() {
        let holders = SystemCommand.parseInetHolders(fixtures)
        XCTAssertNil(SystemCommand.tunnelCollision(
            holders, address: "172.28.0.1", gateway: "172.28.0.2"
        ))
    }

    /// The original bug, reproduced: our old addressing collided with the
    /// fake-IP pool — same 198.18.0.1 endpoint.
    func testSameRangeCollides() {
        let holders = SystemCommand.parseInetHolders(fixtures)
        let hit = SystemCommand.tunnelCollision(
            holders, address: "198.18.0.1", gateway: "198.18.0.2"
        )
        XCTAssertEqual(hit?.iface, "utun8")
        XCTAssertEqual(hit?.ip, "198.18.0.1")
    }

    /// Any address inside our /24, not just the exact endpoint, collides.
    func testAnyAddressInsideOur24Collides() {
        let holders = ["utun4": ["172.28.0.9"]]
        XCTAssertEqual(SystemCommand.tunnelCollision(
            holders, address: "172.28.0.1", gateway: "172.28.0.2"
        )?.ip, "172.28.0.9")
    }

    /// The DNS gateway host itself must trip the gate.
    func testGatewayHostCollides() {
        let holders = ["utun5": ["10.0.0.1", "172.28.0.2"]]
        XCTAssertEqual(SystemCommand.tunnelCollision(
            holders, address: "172.28.0.1", gateway: "172.28.0.2"
        )?.iface, "utun5")
    }

    /// Prefixes must not bleed: 172.28.x collides, 172.2.x must not.
    func testPrefixIsExactThreeOctets() {
        let holders = ["utun6": ["172.2.0.1"]]
        XCTAssertNil(SystemCommand.tunnelCollision(
            holders, address: "172.28.0.1", gateway: "172.28.0.2"
        ))
    }

    /// Clean machine: no holders relevant to us — the gate passes.
    func testNoConflict() {
        let holders = SystemCommand.parseInetHolders(fixtures)
        XCTAssertNil(SystemCommand.tunnelCollision(
            holders, address: "172.28.0.1", gateway: "172.28.0.2"
        ))
    }

    /// IPv6 lines and non-inet lines inside an interface block must not
    /// register as IPv4 holders.
    func testIgnoresInet6AndOtherLines() {
        let output = """
        utun8: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 9000
        \tinet6 fe80::1%utun8 prefixlen 64
        \tnd6 options=1<PERFORMNUD>
        utun9: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 8500
        \tinet 10.0.0.1 --> 10.0.0.1 netmask 0xffffffff
        """
        let holders = SystemCommand.parseInetHolders(output)
        XCTAssertNil(holders["utun8"])  // no IPv4 lines under utun8 at all
        XCTAssertEqual(holders["utun9"], ["10.0.0.1"])
        XCTAssertNil(SystemCommand.tunnelCollision(
            holders, address: "172.28.0.1", gateway: "172.28.0.2"
        ))
    }
}
