import Foundation
import Testing
@testable import LoaderHelper

/// What may be a next-hop. `route get` and `netstat -rn` were guarded
/// differently and both got it wrong in opposite directions: the strict
/// address test threw away a real IPv6 link-local gateway (`netstat` writes
/// every one of them with its zone — `fe80::%utunN`, measured on this Mac),
/// while the netstat path accepted the *interface name* that an
/// interface-scoped route prints in the gateway column, and that string went
/// into `route add -host …` as if it were an address.
struct GatewayShapeTests {
    @Test func addressesAndZonedIPv6AreGateways() {
        #expect(SystemCommand.isGatewayAddress("192.168.1.1"))
        #expect(SystemCommand.isGatewayAddress("fe80::1%en0"))
        #expect(SystemCommand.isGatewayAddress("2001:db8::1"))
    }

    @Test func namesAndMarkersAreNot() {
        for text in ["en0", "utun90", "link#2", "index: 25 utun90", "", "%en0"] {
            #expect(!SystemCommand.isGatewayAddress(text), "«\(text)” taken for a next-hop")
        }
    }

    /// The row a machine without a next-hop prints (`default utun90 … utun90`
    /// is exactly what `netstat -rn -f inet` shows on this Mac right now). For
    /// a *physical* interface the name used to be returned as the gateway.
    @Test func interfaceScopedRouteHasNoGateway() {
        let output = """
        Internet:
        Destination        Gateway            Flags       Netif Expire
        default            en0                USCs          en0
        """
        #expect(SystemCommand.parseNetstatPhysicalGateway(output) == nil)
    }

    /// The other direction: a link-local IPv6 next-hop is usable and must
    /// survive the shape check — dropping it is what made `defaultGateway`
    /// answer nil on an IPv6-only network.
    @Test func routeGetKeepsALinkLocalIPv6Gateway() {
        let output = """
            route to: default
        destination: default
             gateway: fe80::1%en0
           interface: en0
        """
        let parsed = SystemCommand.parseRouteGet(output)
        #expect(parsed.gateway == "fe80::1%en0")
        #expect(parsed.interface == "en0")
    }
}
