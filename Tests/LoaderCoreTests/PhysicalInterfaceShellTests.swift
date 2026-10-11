import Foundation
import Testing

@testable import LoaderCore

/// `PhysicalInterface.shell` is the connect path's guard against a wedged
/// child, and the guard has to be measured in elapsed time: the wall clock
/// moves (NTP after sleep, a manual change), and both directions were wrong —
/// backwards made "give up after 2 seconds" never give up, forwards abandoned a
/// healthy `route -n get` before it answered.
struct PhysicalInterfaceShellTests {
    @Test func aLiveCommandReturnsItsOutput() {
        let started = DispatchTime.now()
        let out = PhysicalInterface.shell("/bin/echo", ["hi"], timeout: 5)
        #expect(out?.trimmingCharacters(in: .whitespacesAndNewlines) == "hi")
        // The bound must not become the wait: a command that finishes in
        // milliseconds must not be held until the timeout.
        #expect(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds < 2_000_000_000)
    }

    /// A child that outruns the bound is terminated and reported as no answer —
    /// and the call returns *in the bound*, which is the whole point.
    @Test func aWedgedChildIsGivenUpOnWithinTheBound() {
        let started = DispatchTime.now()
        let out = PhysicalInterface.shell("/bin/sleep", ["30"], timeout: 0.2)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000_000
        #expect(out == nil, "a child that outlived its timeout still answered")
        #expect(elapsed < 3, "the wait was not bounded: \(elapsed) s for a 0.2 s timeout")
    }

    @Test func aMissingExecutableIsNoAnswerRatherThanACrash() {
        #expect(PhysicalInterface.shell("/no/such/helper", [], timeout: 1) == nil)
    }
}
