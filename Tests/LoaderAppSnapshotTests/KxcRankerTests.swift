import Foundation
import Testing
@testable import LoaderApp

/// The bundled kxc model loads and orders servers sensibly through the app's
/// own inference path — metadata detection, input encoding, output mapping.
struct KxcRankerTests {
    @Test func bundledModelLoadsAndRanks() async throws {
        let ranker = CoreMLRanker()
        for _ in 0..<300 where !ranker.isLoaded {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(ranker.isLoaded, "kxc did not load: \(ranker.backend)")

        let steady = ServerFeatures(history: (0..<64).map { 110 + Float($0 % 5) })
        let lossy = ServerFeatures(history: (0..<64).map { $0 % 3 == 0 ? -1 : 180 + Float($0 % 7) * 20 })
        let dead = ServerFeatures(history: [-1, -1, -1, -1])
        let steadyScore = await ranker.score(steady)
        let lossyScore = await ranker.score(lossy)
        let deadScore = await ranker.score(dead)
        #expect(steadyScore.isFinite && steadyScore >= 0)
        #expect(steadyScore < lossyScore)
        #expect(lossyScore < deadScore)
    }
}
