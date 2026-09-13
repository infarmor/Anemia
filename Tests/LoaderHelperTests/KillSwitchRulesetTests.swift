import XCTest
@testable import LoaderHelper

/// The kill switch's whole guarantee is "if anything dies, egress is blocked".
/// The ruleset is pure text assembly — assert the order and shape that the
/// guarantee depends on.
final class KillSwitchRulesetTests: XCTestCase {

    func testRulesetBlocksEverythingFirst() {
        let text = KillSwitch.ruleset(utun: "utun90", serverV4: ["1.2.3.4"], serverV6: [])
        let lines = text.split(separator: "\n").map(String.init)
        // Block before passes: a `pass` before `block out all` would never be
        // reached... and a block that comes last would override them anyway —
        // pf takes the first match, so `block out all` must come first.
        XCTAssertEqual(lines.firstIndex(of: "block out all"), 2)
        XCTAssertTrue(lines.contains("pass out quick on utun90 all"))
        // The VPN server must stay reachable, or the engine can never dial it.
        XCTAssertTrue(lines.contains { $0.contains("1.2.3.4") })
    }

    func testRulesetSkipsEmptyServerLists() {
        let text = KillSwitch.ruleset(utun: "utun90", serverV4: [], serverV6: [])
        // The `pass out quick inet from any to { }` form would be a pf syntax
        // error — empty lists must produce no line at all.
        XCTAssertFalse(text.contains("{}"))
    }

    func testRulesetSkipsLoopbackAndKeepsDHCP() {
        let text = KillSwitch.ruleset(utun: "utun90", serverV4: [], serverV6: [])
        XCTAssertTrue(text.contains("set skip on lo0"))
        XCTAssertTrue(text.contains("port 67"))
        XCTAssertTrue(text.contains("10.0.0.0/8"))
        // The DHCP pass must be destination-restricted: an unrestricted
        // "to any port 67:68" let any app exfiltrate to arbitrary internet
        // hosts on those ports straight past the kill switch.
        XCTAssertFalse(text.contains("to any port"))
    }
}