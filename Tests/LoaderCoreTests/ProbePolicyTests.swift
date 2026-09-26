import Foundation
import Testing
@testable import LoaderCore

/// The portable half of the latency probe — what a round dials and when it
/// gives up. `Android/core/…/Probing.kt` is compared against these same rules
/// byte for byte (`Scripts/golden-leak.sh`), so behaviour has to be pinned here
/// as well: a rule that drifts in Swift silently changes which servers the app
/// calls alive.
struct ProbePolicyTests {

    @Test func targetRejectsUnusableAddresses() {
        #expect(!LatencyProbe.target(host: "", port: 443, sni: nil, tls: true).usable)
        #expect(!LatencyProbe.target(host: "host", port: 0, sni: nil, tls: true).usable)
        #expect(!LatencyProbe.target(host: "host", port: -1, sni: "sni", tls: true).usable)
        #expect(!LatencyProbe.target(host: "host", port: 65_536, sni: nil, tls: true).usable)
        let edge = LatencyProbe.target(host: "host", port: 65_535, sni: nil, tls: false)
        #expect(edge.usable && edge.tls == false)
    }

    @Test func serverNameOnlyForDNSNames() {
        // An address must not become SNI: several servers fail such a handshake,
        // and `decide` is the only place that rule lives.
        #expect(LatencyProbe.target(host: "203.0.113.9", port: 443, sni: nil, tls: true).serverName == nil)
        #expect(LatencyProbe.target(host: "203.0.113.9", port: 443, sni: "203.0.113.9", tls: true).serverName == nil)
        #expect(LatencyProbe.target(host: "fd42::1", port: 443, sni: "fd42::2", tls: true).serverName == nil)
        #expect(LatencyProbe.target(host: "host", port: 443, sni: "", tls: true).serverName == nil)
        #expect(LatencyProbe.target(host: "nl.example.com", port: 443, sni: nil, tls: true).serverName
                == "nl.example.com")
        #expect(LatencyProbe.target(host: "203.0.113.9", port: 443, sni: "www.microsoft.com", tls: true).serverName
                == "www.microsoft.com")
    }

    @Test func roundStopsOnADeadServerButNotOnASlowOne() async {
        // Every attempt fails: three of five, then the round gives up.
        let dead = await LatencyProbe.collect(count: 5, earlyAbortAfterFails: 3) { _ in nil }
        #expect(dead.count == 3)
        #expect(dead.allSatisfy { $0 == nil })

        // A success in the middle resets the streak, so the whole round runs.
        let outcomes: [Int?] = [nil, nil, 40, nil, nil]
        let mixed = await LatencyProbe.collect(count: 5, earlyAbortAfterFails: 3) { attempt in
            outcomes[min(attempt, outcomes.count - 1)]
        }
        #expect(mixed.count == 5)
        #expect(mixed[2] == 40)

        // No limit means the round always spends its five slots.
        let unlimited = await LatencyProbe.collect(count: 5, earlyAbortAfterFails: nil) { _ in nil }
        #expect(unlimited.count == 5)
        // And a zero count still measures once rather than reporting nothing.
        #expect(await LatencyProbe.collect(count: 0, earlyAbortAfterFails: 2) { _ in nil }.count == 1)
    }
}
