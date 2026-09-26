import Foundation
import Testing
@testable import LoaderHelper

/// The server bypass pin decides whether the engine's own dial can leave the
/// machine once the tunnel's /1 routes are up. Fixtures are `route -n get`
/// output shapes: an exact host entry, and the best-match answers that must
/// never be mistaken for one (the default route, a tunnel /1).
struct BypassRouteTests {

    @Test func pinnedHostRouteViaPhysicalInterface() {
        let output = """
           route to: 203.0.113.7
        destination: 203.0.113.7
            gateway: 192.168.0.1
          interface: en0
              flags: <UP,GATEWAY,HOST,DONE,STATIC,PRCLONING>
        """
        #expect(SystemCommand.isHostRoutePinned(output, host: "203.0.113.7", inet6: false))
    }

    @Test func defaultRouteMatchIsNotAPin() {
        let output = """
           route to: 203.0.113.7
        destination: default
               mask: default
            gateway: 192.168.0.1
          interface: en0
              flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
        """
        #expect(!SystemCommand.isHostRoutePinned(output, host: "203.0.113.7", inet6: false))
    }

    @Test func tunnelSplitRouteMatchIsNotAPin() {
        let output = """
           route to: 203.0.113.7
        destination: 128.0.0.0
               mask: 128.0.0.0
          interface: utun90
              flags: <UP,DONE,STATIC>
        """
        #expect(!SystemCommand.isHostRoutePinned(output, host: "203.0.113.7", inet6: false))
    }

    @Test func hostEntryOnATunnelIsNotAPin() {
        let output = """
           route to: 203.0.113.7
        destination: 203.0.113.7
          interface: utun4
              flags: <UP,HOST,DONE,STATIC>
        """
        #expect(!SystemCommand.isHostRoutePinned(output, host: "203.0.113.7", inet6: false))
    }

    @Test func ipv6DestinationComparedByValue() {
        let output = """
           route to: 2001:db8::7
        destination: 2001:db8::7
            gateway: fe80::1%en0
          interface: en0
              flags: <UP,GATEWAY,HOST,DONE,STATIC>
        """
        #expect(SystemCommand.isHostRoutePinned(output, host: "2001:0db8:0:0::0007", inet6: true))
    }

    @Test func routeErrorIsNotAPin() {
        let output = "route: writing to routing socket: not in table"
        #expect(!SystemCommand.isHostRoutePinned(output, host: "203.0.113.7", inet6: false))
    }

    // MARK: - amneziawg-go WG_TUN_NAME_FILE

    @Test func tunNameFileAcceptsKernelAssignedUtun() {
        #expect(SystemCommand.parseTunNameFile("utun7\n") == "utun7")
        #expect(SystemCommand.parseTunNameFile("utun123") == "utun123")
    }

    @Test func tunNameFileRejectsAnythingElse() {
        #expect(SystemCommand.parseTunNameFile("") == nil)
        #expect(SystemCommand.parseTunNameFile("utun") == nil)
        #expect(SystemCommand.parseTunNameFile("awg0") == nil)
        #expect(SystemCommand.parseTunNameFile("utun7/../../etc") == nil)
        #expect(SystemCommand.parseTunNameFile("utun1234567890123") == nil)
    }
}
