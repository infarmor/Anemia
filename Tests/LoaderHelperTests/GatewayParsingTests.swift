import XCTest
@testable import LoaderHelper

/// Regression tests for the gateway-parsing code paths that decide whether the
/// system tunnel can come up at all. The fixtures below are real captured
/// outputs: the utun-default-route case is the exact shape that caused the
/// original "connect works but everything falls" bug (a third-party VPN held
/// the default route, `route get default` printed no `gateway:` line, and the
/// helper gave up).
final class GatewayParsingTests: XCTestCase {

    // MARK: - route -n get default

    /// The normal case: physical default route via en0 with a real gateway.
    func testRouteGetPhysicalGateway() {
        let output = """
           route to: default
        destination: default
           gateway: 192.168.1.1
            interface: en0
              flags: <UP,GATEWAY,DONE,STATIC>
        """
        let parsed = SystemCommand.parseRouteGet(output)
        XCTAssertEqual(parsed.gateway, "192.168.1.1")
        XCTAssertEqual(parsed.interface, "en0")
    }

    /// The original bug: a foreign TUN owns the default route, so the route is
    /// a bare interface route — there is no `gateway:` line at all.
    func testRouteGetTunDefaultRouteHasNoGateway() {
        let output = """
           route to: default
        destination: default
            interface: utun8
              flags: <UP,DONE,STATIC>
        """
        let parsed = SystemCommand.parseRouteGet(output)
        XCTAssertNil(parsed.gateway, "a bare interface route must not parse as having a gateway")
        XCTAssertEqual(parsed.interface, "utun8")
    }

    /// Point-to-point TUN routes can report `link#N` as the gateway — that's
    /// the interface itself, not a hop.
    func testRouteGetLinkGatewayIsRejected() {
        let output = """
           route to: default
        destination: default
           gateway: link#12
            interface: utun3
              flags: <UP,DONE,STATIC>
        """
        let parsed = SystemCommand.parseRouteGet(output)
        XCTAssertNil(parsed.gateway)
    }

    func testRouteGetEmptyOutput() {
        let parsed = SystemCommand.parseRouteGet("")
        XCTAssertNil(parsed.gateway)
        XCTAssertNil(parsed.interface)
    }

    // MARK: - netstat -rn physical-gateway fallback

    /// The fallback that fixed the original bug: the physical default route
    /// is still visible in `netstat -rn` behind the TUN's default route.
    func testNetstatFindsPhysicalGatewayBehindTunDefault() {
        let output = """
        Routing tables

        Internet:
        Destination        Gateway            Flags        Netif Expire
        default            utun8              UGScg       utun8
        default            192.168.1.1        UGScg         en0
        127                127.0.0.1          UCS            lo0
        192.168.1          link#2             UCS            en0      <- nope
        """
        let gw = SystemCommand.parseNetstatPhysicalGateway(output)
        XCTAssertEqual(gw, "192.168.1.1")
    }

    /// Normal single-default-route machine.
    func testNetstatNormalCase() {
        let output = """
        Routing tables

        Internet:
        Destination        Gateway            Flags        Netif Expire
        default            192.168.1.1        UGScg         en0
        192.168.1          link#2             UCS            en0
        """
        let gw = SystemCommand.parseNetstatPhysicalGateway(output)
        XCTAssertEqual(gw, "192.168.1.1")
    }

    /// Only tunneled default routes — no physical gateway exists (must return
    /// nil, not a tunnel peer).
    func testNetstatOnlyTunnelDefaults() {
        let output = """
        Routing tables

        Internet:
        Destination        Gateway            Flags        Netif Expire
        default            198.18.0.2         UGScg       utun90
        default            utun8              UGScg       utun8
        """
        XCTAssertNil(SystemCommand.parseNetstatPhysicalGateway(output))
    }

    /// IPv6: gateways are addresses, and tunnel prefixes must be skipped.
    func testNetstatIPv6() {
        let output = """
        Routing tables

        Internet6:
        Destination                             Gateway                         Flags         Netif Expire
        default                                 fe80::1%en0                     UGcI            en0
        default                                 fe80::42:ff:fe:aa:bb:cc%utun3    UGcIg         utun3
        """
        let gw = SystemCommand.parseNetstatPhysicalGateway(output)
        XCTAssertEqual(gw, "fe80::1%en0")
    }

    func testNetstatEmptyOutput() {
        XCTAssertNil(SystemCommand.parseNetstatPhysicalGateway(""))
    }

    // MARK: - stale split-route sweep

    /// Only dead-utun rows are swept — a live foreign client holding the same
    /// prefixes on its own interface must keep them.
    func testStaleSplitRoutesScopedToDeadUtuns() {
        let output = """
        Routing tables

        Internet:
        Destination        Gateway            Flags        Netif Expire
        default            192.168.1.1        UGScg         en0
        0/1                utun91             UGScg       utun91
        128.0.0.0/1        utun91             UGScg       utun91
        0/1                utun5              UGScg       utun5
        """
        // utun91 is dead, utun5 is alive.
        let rows = SystemCommand.parseStaleSplitRoutes(output, inet6: false,
                                                        isDeadInterface: { $0 == "utun91" })
        XCTAssertEqual(rows.map(\.destination), ["0.0.0.0/1", "128.0.0.0/1"])
        XCTAssertTrue(rows.allSatisfy { $0.iface == "utun91" })
    }

    func testStaleSplitRoutesIPv6() {
        let output = """
        Routing tables

        Internet6:
        Destination                             Gateway              Flags     Netif Expire
        ::/1                                    fd00:1972::2        UGScg     utun91
        8000::/1                                fd00:1972::2        UGScg     utun91
        default                                 fe80::1%en0         UGcI        en0
        """
        let rows = SystemCommand.parseStaleSplitRoutes(output, inet6: true,
                                                        isDeadInterface: { _ in true })
        XCTAssertEqual(rows.map(\.destination), ["::/1", "8000::/1"])
        XCTAssertTrue(rows.allSatisfy { $0.inet6 })
    }

    /// Physical rows (en0) and unknown prefixes are never touched.
    func testStaleSplitRoutesIgnoresPhysicalAndUnknownRows() {
        let output = """
        0/1                192.168.1.1        UGScg         en0
        10.0.0/24          link#2             UCS           en0
        """
        let rows = SystemCommand.parseStaleSplitRoutes(output, inet6: false,
                                                        isDeadInterface: { _ in true })
        XCTAssertTrue(rows.isEmpty)
    }

    // MARK: - DNS / proxy state capture (settings backup)

    func testParseDNSServersManualResolvers() {
        let output = """
        1.1.1.1
        192.168.1.5
        """
        XCTAssertEqual(SystemCommand.parseDNSServers(output), ["1.1.1.1", "192.168.1.5"])
    }

    func testParseDNSServersAutomaticMeansEmpty() {
        let output = "There aren't any DNS Servers set on Wi-Fi. DNS Servers set elsewhere may take precedence."
        XCTAssertEqual(SystemCommand.parseDNSServers(output), [])
    }

    func testParseSocksProxyStates() {
        let enabled = """
        Enabled: Yes
        Server: 127.0.0.1
        Port: 10808
        Authenticated Proxy Enabled: 0
        """
        let p1 = SystemCommand.parseSocksProxy(enabled)
        XCTAssertEqual(p1?.enabled, true)
        XCTAssertEqual(p1?.host, "127.0.0.1")
        XCTAssertEqual(p1?.port, "10808")

        let disabled = """
        Enabled: No
        Server:
        Port:
        """
        let p2 = SystemCommand.parseSocksProxy(disabled)
        XCTAssertEqual(p2?.enabled, false)
    }

    // MARK: - interface classification

    func testTunnelInterfaceClassification() {
        XCTAssertTrue(SystemCommand.isTunnelInterface("utun90"))
        XCTAssertTrue(SystemCommand.isTunnelInterface("ipsec0"))
        XCTAssertTrue(SystemCommand.isTunnelInterface("ppp0"))
        XCTAssertTrue(SystemCommand.isTunnelInterface("awdl0"))
        XCTAssertTrue(SystemCommand.isTunnelInterface("llw0"))
        XCTAssertTrue(SystemCommand.isTunnelInterface("lo0"))
        XCTAssertFalse(SystemCommand.isTunnelInterface("en0"))
        XCTAssertFalse(SystemCommand.isTunnelInterface("en5"))
        XCTAssertFalse(SystemCommand.isTunnelInterface("bridge0"))
    }
}