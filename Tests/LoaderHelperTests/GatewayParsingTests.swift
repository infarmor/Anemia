import Foundation
import Testing
@testable import LoaderHelper

/// Regression tests for the gateway-parsing code paths that decide whether the
/// system tunnel can come up at all. The fixtures below are real captured
/// outputs: the utun-default-route case is the exact shape that caused the
/// original "connect works but everything falls" bug (a third-party VPN held
/// the default route, `route get default` printed no `gateway:` line, and the
/// helper gave up).
struct GatewayParsingTests {

    // MARK: - route -n get default

    /// The normal case: physical default route via en0 with a real gateway.
    @Test func testRouteGetPhysicalGateway() {
        let output = """
           route to: default
        destination: default
           gateway: 192.168.1.1
            interface: en0
              flags: <UP,GATEWAY,DONE,STATIC>
        """
        let parsed = SystemCommand.parseRouteGet(output)
        #expect(parsed.gateway == "192.168.1.1")
        #expect(parsed.interface == "en0")
    }

    /// The original bug: a foreign TUN owns the default route, so the route is
    /// a bare interface route — there is no `gateway:` line at all.
    @Test func testRouteGetTunDefaultRouteHasNoGateway() {
        let output = """
           route to: default
        destination: default
            interface: utun8
              flags: <UP,DONE,STATIC>
        """
        let parsed = SystemCommand.parseRouteGet(output)
        #expect(parsed.gateway == nil, "a bare interface route must not parse as having a gateway")
        #expect(parsed.interface == "utun8")
    }

    /// Point-to-point TUN routes can report `link#N` as the gateway — that's
    /// the interface itself, not a hop.
    @Test func testRouteGetLinkGatewayIsRejected() {
        let output = """
           route to: default
        destination: default
           gateway: link#12
            interface: utun3
              flags: <UP,DONE,STATIC>
        """
        let parsed = SystemCommand.parseRouteGet(output)
        #expect(parsed.gateway == nil)
    }

    @Test func testRouteGetEmptyOutput() {
        let parsed = SystemCommand.parseRouteGet("")
        #expect(parsed.gateway == nil)
        #expect(parsed.interface == nil)
    }

    // MARK: - netstat -rn physical-gateway fallback

    /// The fallback that fixed the original bug: the physical default route
    /// is still visible in `netstat -rn` behind the TUN's default route.
    @Test func testNetstatFindsPhysicalGatewayBehindTunDefault() {
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
        #expect(gw == "192.168.1.1")
    }

    /// Normal single-default-route machine.
    @Test func testNetstatNormalCase() {
        let output = """
        Routing tables

        Internet:
        Destination        Gateway            Flags        Netif Expire
        default            192.168.1.1        UGScg         en0
        192.168.1          link#2             UCS            en0
        """
        let gw = SystemCommand.parseNetstatPhysicalGateway(output)
        #expect(gw == "192.168.1.1")
    }

    /// Only tunneled default routes — no physical gateway exists (must return
    /// nil, not a tunnel peer).
    @Test func testNetstatOnlyTunnelDefaults() {
        let output = """
        Routing tables

        Internet:
        Destination        Gateway            Flags        Netif Expire
        default            198.18.0.2         UGScg       utun90
        default            utun8              UGScg       utun8
        """
        #expect(SystemCommand.parseNetstatPhysicalGateway(output) == nil)
    }

    /// IPv6: gateways are addresses, and tunnel prefixes must be skipped.
    @Test func testNetstatIPv6() {
        let output = """
        Routing tables

        Internet6:
        Destination                             Gateway                         Flags         Netif Expire
        default                                 fe80::1%en0                     UGcI            en0
        default                                 fe80::42:ff:fe:aa:bb:cc%utun3    UGcIg         utun3
        """
        let gw = SystemCommand.parseNetstatPhysicalGateway(output)
        #expect(gw == "fe80::1%en0")
    }

    @Test func testNetstatEmptyOutput() {
        #expect(SystemCommand.parseNetstatPhysicalGateway("") == nil)
    }

    // MARK: - stale split-route sweep

    /// Only dead-utun rows are swept — a live foreign client holding the same
    /// prefixes on its own interface must keep them.
    @Test func testStaleSplitRoutesScopedToDeadUtuns() {
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
        #expect(rows.map(\.destination) == ["0.0.0.0/1", "128.0.0.0/1"])
        #expect(rows.allSatisfy { $0.iface == "utun91" })
    }

    @Test func testStaleSplitRoutesIPv6() {
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
        #expect(rows.map(\.destination) == ["::/1", "8000::/1"])
        #expect(rows.allSatisfy { $0.inet6 })
    }

    /// Physical rows (en0) and unknown prefixes are never touched.
    @Test func testStaleSplitRoutesIgnoresPhysicalAndUnknownRows() {
        let output = """
        0/1                192.168.1.1        UGScg         en0
        10.0.0/24          link#2             UCS           en0
        """
        let rows = SystemCommand.parseStaleSplitRoutes(output, inet6: false,
                                                        isDeadInterface: { _ in true })
        #expect(rows.isEmpty)
    }

    // MARK: - DNS / proxy state capture (settings backup)

    @Test func testParseDNSServersManualResolvers() {
        let output = """
        1.1.1.1
        192.168.1.5
        """
        #expect(SystemCommand.parseDNSServers(output) == ["1.1.1.1", "192.168.1.5"])
    }

    @Test func testParseDNSServersAutomaticMeansEmpty() {
        let output = "There aren't any DNS Servers set on Wi-Fi. DNS Servers set elsewhere may take precedence."
        #expect(SystemCommand.parseDNSServers(output) == [])
    }

    @Test func testParseSocksProxyStates() {
        let enabled = """
        Enabled: Yes
        Server: 127.0.0.1
        Port: 10808
        Authenticated Proxy Enabled: 0
        """
        let p1 = SystemCommand.parseSocksProxy(enabled)
        #expect(p1?.enabled == true)
        #expect(p1?.host == "127.0.0.1")
        #expect(p1?.port == "10808")

        let disabled = """
        Enabled: No
        Server:
        Port:
        """
        let p2 = SystemCommand.parseSocksProxy(disabled)
        #expect(p2?.enabled == false)
    }

    // MARK: - interface classification

    @Test func testTunnelInterfaceClassification() {
        #expect(SystemCommand.isTunnelInterface("utun90"))
        #expect(SystemCommand.isTunnelInterface("ipsec0"))
        #expect(SystemCommand.isTunnelInterface("ppp0"))
        #expect(SystemCommand.isTunnelInterface("awdl0"))
        #expect(SystemCommand.isTunnelInterface("llw0"))
        #expect(SystemCommand.isTunnelInterface("lo0"))
        #expect(!SystemCommand.isTunnelInterface("en0"))
        #expect(!SystemCommand.isTunnelInterface("en5"))
        #expect(!SystemCommand.isTunnelInterface("bridge0"))
    }
}