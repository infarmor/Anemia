import Foundation
import Testing

@testable import LoaderCore

/// The two places a panel's byte counters turn into a judgement: the 0…1
/// fraction the UI multiplies by 100, and the 90 % line that decides whether
/// the subscription is worth a word.
struct SubscriptionFractionsTests {
    private func info(_ uploaded: Int64, _ downloaded: Int64, _ total: Int64) -> SubscriptionInfo {
        SubscriptionInfo(uploaded: uploaded, downloaded: downloaded, total: total)
    }

    /// A panel answering a negative counter (the parser bounds it to
    /// `Int64.min`, it does not reject it) used to make the fraction about
    /// −9.2e18 — and `Int(fraction * 100)` in the subscription row trapped on
    /// it. The fraction belongs to the same 0…1 range the doc promises.
    @Test func negativeCountersReadAsNothingUsed() {
        let hostile = info(.min, 0, 1)
        #expect(hostile.usedFraction == 0)
        #expect(!hostile.needsAttention(now: Date(timeIntervalSince1970: 1_800_000_000)))

        let ordinary = info(-500, 0, 1000)
        #expect(ordinary.usedFraction == 0)
        // Top end still clamps: a panel may report more used than allowed.
        #expect(info(2000, 0, 1000).usedFraction == 1)
    }

    /// `needsAttention` and the reminder planner are read by different views
    /// for the same question; with `>` against `>=` a subscription at exactly
    /// 90 % was marked as already warned by the filter and never planned, so
    /// the badge stayed grey for a reminder that could no longer fire.
    @Test func theNinetyPercentLineIsOneLine() {
        let id = UUID()
        let atTheLine = [(id: id, name: "at 90 %", info: info(450, 450, 1000))]
        #expect(atTheLine[0].info.usedFraction == 0.9)
        #expect(atTheLine[0].info.needsAttention(now: Date(timeIntervalSince1970: 1_800_000_000)))
        let planned = SubscriptionReminders.plan(atTheLine, alreadyWarned: [],
                                                now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(planned.contains { $0.subscriptionID == id }, "the row says worth attention, the planner disagrees")

        // And just below it neither of them fires.
        let below = [(id: id, name: "89 %", info: info(445, 445, 1000))]
        #expect(!below[0].info.needsAttention(now: Date(timeIntervalSince1970: 1_800_000_000)))
        #expect(SubscriptionReminders.plan(below, alreadyWarned: [],
                                           now: Date(timeIntervalSince1970: 1_800_000_000)).isEmpty)
    }

    /// Restored counters near the ceiling: `+` traps in Swift and wraps in
    /// Kotlin; both ports now saturate, so a day total is never a negative
    /// number in the stats sheet.
    @Test func ledgerTotalsSaturate() {
        #expect(TrafficLedger.Day(id: "2026-09-27", received: .max, sent: 5).total == .max)
        #expect(TrafficLedger.Day(id: "2026-09-27", received: .min, sent: -5).total == .min)
        #expect(TrafficLedger.Day(id: "2026-09-27", received: 5, sent: 6).total == 11)
        let server = TrafficLedger.ServerTotal(id: UUID(), name: "s", received: .max, sent: 1)
        #expect(server.total == .max)
    }
}
