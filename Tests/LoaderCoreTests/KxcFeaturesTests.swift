import Foundation
import Testing
@testable import LoaderCore

/// The feature vector is the model's whole contract: the trainer compiles
/// this same code, so these tests pin what each position means.
struct KxcFeaturesTests {
    @Test func vectorMatchesTheModelInputs() {
        #expect(KxcFeatures.names.count == KxcFeatures.count)
        #expect(Set(KxcFeatures.names).count == KxcFeatures.count)
        #expect(KxcFeatures.names.first == "f00")
        #expect(KxcFeatures.extract([120, 118, -1, 125]).count == KxcFeatures.count)
    }

    @Test func degenerateHistoriesStayFinite() {
        let histories: [[Float]] = [[], [-1], [-1, -1, -1], [0], Array(repeating: 250, count: 400)]
        for h in histories {
            let f = KxcFeatures.extract(h)
            #expect(f.count == KxcFeatures.count)
            #expect(f.allSatisfy { $0.isFinite }, "non-finite feature for \(h.prefix(4))")
        }
    }

    @Test func looksAtTheLastWindowOnly() {
        let old = [Float](repeating: -1, count: 300)
        let recent = [Float](repeating: 100, count: KxcFeatures.window)
        let f = KxcFeatures.extract(old + recent)
        #expect(f[0] == Double(KxcFeatures.window))   // sample count
        #expect(f[1] == 0)                            // the old failures fell out of the window
    }

    /// Same overall loss, opposite futures: only the recency features can
    /// tell a server that recovered from one that is failing right now.
    @Test func recencySeparatesRecoveredFromFailing() {
        let clean = [Float](repeating: 120, count: 64)
        let failing = [Float](repeating: -1, count: 16)
        let recovered = KxcFeatures.extract(failing + clean)
        let deteriorating = KxcFeatures.extract(clean + failing)
        #expect(recovered[1] == deteriorating[1])     // loss over the window
        #expect(recovered[2] == 0)                    // loss over the last 16
        #expect(deteriorating[2] == 1)
        #expect(recovered[3] < deteriorating[3])      // recency-weighted loss
        #expect(recovered[22] == 0)                   // last probe failed
        #expect(deteriorating[22] == 1)
    }

    @Test func handBuiltScoresAreFeatures() {
        let h: [Float] = [200, 210, -1, 190, 205, 400, 198]
        let f = KxcFeatures.extract(h)
        #expect(f[19] == min(KxcFeatures.scoreCap, ServerScoring.rankingScore(h)))
        #expect(f[21] == ServerScoring.stability(h))
    }
}

struct ServerScoringTests {
    @Test func badnessOrdersTheObviousCases() {
        #expect(ServerScoring.rankingScore([-1, -1]) == 100_000)
        let fast = ServerScoring.rankingScore([80, 82, 79, 81, 80])
        let lossy = ServerScoring.rankingScore([80, -1, 79, -1, 80])
        let slow = ServerScoring.rankingScore([300, 310, 295, 305, 300])
        #expect(fast < slow)
        #expect(fast < lossy)
    }

    @Test func averageAndStability() {
        #expect(ServerScoring.averagePing([100, -1, 200]) == 150)
        #expect(ServerScoring.averagePing([-1]) == 100_000)
        let steady = ServerScoring.stability([100, 101, 99, 100, 102])
        #expect(steady > 0.8 && steady <= 1)
        #expect(ServerScoring.stability([-1, -1]) == 0)
        #expect(ServerScoring.stability([100, 100, -1, -1]) < steady)
    }
}
