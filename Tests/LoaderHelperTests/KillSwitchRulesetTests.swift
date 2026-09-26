import Foundation
import Testing
@testable import LoaderHelper

/// The kill switch's whole guarantee is "if anything dies, egress is blocked —
/// and nothing of ours ever outlives the helper". The ruleset is pure text:
/// assert the shape the guarantee depends on, and let the real pfctl parser
/// validate the syntax (`pfctl -n` needs no root).
struct KillSwitchRulesetTests {

    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") }
    }

    @Test func testEveryRuleIsQuickAndBlockComesLast() {
        let rules = lines(KillSwitch.ruleset(utun: "utun90", serverV4: ["1.2.3.4"], serverV6: ["2001:db8::1"]))
        // Inside an anchor, only `quick` ends the evaluation of the whole
        // ruleset — a non-quick rule could be overridden by a later anchor.
        #expect(rules.allSatisfy { $0.contains(" quick ") })
        #expect(rules.last == "block drop out quick all")
        #expect(rules.contains("pass out quick on utun90 all no state"))
        #expect(rules.contains { $0.contains("1.2.3.4") && $0.hasPrefix("pass out quick inet ") })
        #expect(rules.contains { $0.contains("2001:db8::1") && $0.hasPrefix("pass out quick inet6 ") })
    }

    @Test func testPassRulesAreStatelessSoPreexistingFlowsSurvive() {
        let rules = lines(KillSwitch.ruleset(utun: "utun90", serverV4: ["1.2.3.4"], serverV6: []))
        // A pass rule with the default `flags S/SA keep state` never matches
        // mid-stream packets: the engine's already-open server connection
        // would be cut the moment the kill switch arms.
        #expect(rules.filter { $0.hasPrefix("pass") }.allSatisfy { $0.hasSuffix("no state") })
    }

    @Test func testAnchorSafeSyntaxOnly() {
        let text = KillSwitch.ruleset(utun: "utun90", serverV4: [], serverV6: [])
        // `set` options are main-ruleset-only; in an anchor they fail the load.
        #expect(!text.contains("set skip"))
        #expect(!text.contains("set block-policy"))
        // Loopback must be passed explicitly instead.
        #expect(text.contains("pass out quick on lo0 all no state"))
    }

    @Test func testRulesetSkipsEmptyServerLists() {
        let text = KillSwitch.ruleset(utun: "utun90", serverV4: [], serverV6: [])
        #expect(!text.contains("{  }"))
        #expect(!text.contains("{ }"))
    }

    @Test func testLinkHousekeepingStaysOpen() {
        let text = KillSwitch.ruleset(utun: "utun90", serverV4: [], serverV6: [])
        #expect(text.contains("10.0.0.0/8"))
        #expect(text.contains("255.255.255.255"))       // DHCP
        #expect(text.contains("fe80::/10"))              // IPv6 link-local
        #expect(text.contains("neighbradv"))             // NDP replies
        // No blanket port pass: "to any port 67" let apps exfiltrate past it.
        #expect(!text.contains("to any port"))
    }

    @Test func testRealPfctlAcceptsTheRuleset() throws {
        let pfctl = "/sbin/pfctl"
        guard FileManager.default.isExecutableFile(atPath: pfctl) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("anemia-ks-\(UUID().uuidString).conf")
        defer { try? FileManager.default.removeItem(at: url) }
        let text = KillSwitch.ruleset(utun: "utun90",
                                      serverV4: ["203.0.113.7", "198.51.100.1", "10.20.0.0/16"],
                                      serverV6: ["2001:db8::1", "2001:db8:1::/48"])
        try text.write(to: url, atomically: true, encoding: .utf8)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pfctl)
        proc.arguments = ["-n", "-a", KillSwitch.anchor, "-f", url.path]
        let pipe = Pipe()
        proc.standardError = pipe
        proc.standardOutput = pipe
        try proc.run()
        proc.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(proc.terminationStatus == 0, "pfctl rejected the ruleset: \(output)")
    }

    @Test func testParseEnableToken() {
        #expect(KillSwitch.parseEnableToken("pf enabled\nToken : 13817429536940426575\n") == "13817429536940426575")
        #expect(KillSwitch.parseEnableToken("pfctl: pf already enabled\n") == nil)
    }

    @Test func testPfStatus() {
        #expect(KillSwitch.pfIsEnabled("Status: Enabled for 0 days 00:01:02           Debug: Urgent\n"))
        #expect(!KillSwitch.pfIsEnabled("Status: Disabled for 3 days 01:00:00         Debug: Urgent\n"))
    }

    @Test func testAppleAnchorHookDetection() {
        let stock = """
        scrub-anchor "com.apple/*" all fragment reassemble
        anchor "com.apple/*" all
        """
        #expect(KillSwitch.hasAppleAnchorHook(stock))
        // The pre-0.8 helper replaced the main ruleset wholesale.
        let legacy = """
        block drop out all
        pass out quick on utun90 all flags S/SA keep state
        """
        #expect(!KillSwitch.hasAppleAnchorHook(legacy))
        #expect(KillSwitch.hasAppleAnchorHook((try? String(contentsOfFile: "/etc/pf.conf", encoding: .utf8)) ?? stock))
    }

    @Test func testAnchorIsEvaluatedByTheStockHook() {
        // Our anchor must live under the wildcard /etc/pf.conf evaluates.
        #expect(KillSwitch.anchor.hasPrefix("com.apple/"))
        #expect(!KillSwitch.anchor.dropFirst("com.apple/".count).contains("/"))
    }
}
