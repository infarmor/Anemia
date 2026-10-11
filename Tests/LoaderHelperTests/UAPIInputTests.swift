import Foundation
import LoaderCore
import Testing

@testable import LoaderHelper

/// The helper's own shape check on the script it pipes to a root-spawned
/// engine. Two directions matter: a document that isn't a well-formed
/// `set=1` payload must be refused, and the real builder's output must never
/// be — a false refusal here is a tunnel that stops coming up.
struct UAPIInputTests {
    private static let conf = """
        [Interface]
        PrivateKey = yAnz5TF+fT28A5vH0vGcC8pVXqv5ZfV0+0P4Rn1v5HE=
        Address = 10.8.1.2/32
        MTU = 1280
        Jc = 2
        Jmin = 20
        Jmax = 30
        S1 = 10
        S2 = 20
        I1 = <r 64>

        [Peer]
        PublicKey = Ox5vDWfJ9yfkXcUuJ2XgKlQSmGvvnBB0qR9vK3F2zV0=
        AllowedIPs = 0.0.0.0/0, ::/0
        Endpoint = 203.0.113.5:51820
        PersistentKeepalive = 25
        """

    /// The positive control: whatever `AmneziaWGConfigBuilder` really produces
    /// has to pass, or the guard is a connect failure waiting to happen. The
    /// free-text `I1 = <r 64>` line is the part worth pinning — chain specs are
    /// the only obfuscation values nothing else parses.
    @Test func buildersOwnScriptIsAccepted() throws {
        let server = try ShareLinkParser.parseConfigText(Self.conf)
        let script = try AmneziaWGConfigBuilder.makeUAPISetScript(server: server)
        #expect(UAPIInput.problem(script) == nil, "the helper refused the script its own app builds: \(UAPIInput.problem(script) ?? "")")
        #expect(script.hasPrefix("set=1\n") && script.hasSuffix("\n"))
        #expect(script.contains("i1=<r 64>\n"))
    }

    @Test func shapeViolationsAreRefused() {
        #expect(UAPIInput.problem("") != nil)
        #expect(UAPIInput.problem("get=1\n") != nil)                       // not a set document
        #expect(UAPIInput.problem("set=1\nprivate_key=00") != nil)         // last line unfinished
        #expect(UAPIInput.problem("set=1\r\nprivate_key=00\r\n") != nil)   // CR inside a value
        #expect(UAPIInput.problem("set=1\nprivate_key=0\t0\n") != nil)     // tab is not printable
        #expect(UAPIInput.problem("set=1\nprivate_key=\u{0}00\n") != nil)  // NUL ends a C string
        let huge = "set=1\n" + String(repeating: "a", count: 64 << 10)
        #expect(UAPIInput.problem(huge) != nil)
    }

    /// What this check deliberately does NOT claim: a newline is the script's
    /// own structure, so an injected line cannot be told from a directive the
    /// builder meant to write. Newline-free values are the builder's rule
    /// (`makeUAPISetScript`'s control-character sweep); this test exists so the
    /// difference stays written down instead of being read into the guard.
    @Test func newlineIsTheFormatNotAFinding() {
        #expect(UAPIInput.problem("set=1\nprivate_key=00\n") == nil)
    }
}
