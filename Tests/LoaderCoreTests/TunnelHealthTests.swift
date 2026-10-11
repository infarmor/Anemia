import Foundation
import Testing

@testable import LoaderCore

/// Границы правил здоровья — тот же `TunnelHealth`, который вызывает
/// `PacketTunnelProvider.checkHealth`, и он же золотом сверяется с Kotlin
/// (`health/cases.golden.txt`). Красным обязан стать и здесь: у tunnel-таргета
/// тестового хоста нет, и без этого теста правила проверялись бы только глазами
/// на устройстве.
private let rules = TunnelHealth()

@Test func testHealthRequestResetsTheStreakOnlyWhenItAnswers() {
    #expect(rules.request(nil) == .measured(ms: -1, failed: true))
    #expect(rules.request(42) == .measured(ms: 42, failed: false))
    // Порог строгий: три секунды — ещё «ответило», 3001 мс — «нет».
    #expect(rules.request(3_000) == .measured(ms: 3_000, failed: false))
    #expect(rules.request(3_001) == .measured(ms: 3_001, failed: true))
    // Медленный ответ остаётся медленным ответом в отчёте, а не -1.
    let slow = rules.apply(rules.request(5_000), to: HealthState())
    #expect(slow.health == 5_000)
    #expect(slow.failures == 1)
}

@Test func testHealthCountersNeedTwoReadingsOfTheSameRun() {
    let base = TrafficCounters(up: 100, down: 100)
    #expect(rules.counters(nil, previous: base, latency: nil) == .silence)
    #expect(rules.counters(base, previous: nil, latency: nil) == .silence)
    // Пришло хоть что-то — туннель живой; число в отчёте — задержка сервера.
    #expect(rules.counters(TrafficCounters(up: 100, down: 101), previous: base, latency: nil)
            == .measured(ms: 1, failed: false))
    #expect(rules.counters(TrafficCounters(up: 100, down: 150), previous: base, latency: 88)
            == .measured(ms: 88, failed: false))
    // Отправил и ничего не получил — отказ. Граница floor'а строгая.
    #expect(rules.counters(TrafficCounters(up: 2_100, down: 100), previous: base, latency: nil)
            == .silence)
    #expect(rules.counters(TrafficCounters(up: 2_101, down: 100), previous: base, latency: nil)
            == .measured(ms: -1, failed: true))
    // Пришедшее важнее отправленного.
    #expect(rules.counters(TrafficCounters(up: 6_000, down: 101), previous: base, latency: nil)
            == .measured(ms: 1, failed: false))
    // Отрицательные дельты — это перезапуск движка, а не молчание сервера.
    #expect(rules.counters(TrafficCounters(up: 50, down: 10), previous: base, latency: nil)
            == .silence)
}

@Test func testHealthStreakGrowsResetsAndHolds() {
    func apply(_ outcome: HealthOutcome, from: Int) -> Int {
        rules.apply(outcome, to: HealthState(failures: from)).failures
    }
    #expect(apply(.measured(ms: -1, failed: true), from: 2) == 3)
    #expect(apply(.measured(ms: 42, failed: false), from: 9) == 0)
    // Молчание не имеет права ни накопить отказ, ни сбросить накопленное.
    #expect(apply(.silence, from: 4) == 4)
    let untouched = rules.apply(.silence, to: HealthState(health: 77, failures: 4))
    #expect(untouched == HealthState(health: 77, failures: 4))
    // Пороги — часть политики, а не числа по месту вызова.
    #expect(TunnelHealth(requestLimitMs: 500).request(800) == .measured(ms: 800, failed: true))
    #expect(TunnelHealth(sendFloorBytes: 10)
        .counters(TrafficCounters(up: 111, down: 100), previous: TrafficCounters(up: 100, down: 100),
                  latency: nil) == .measured(ms: -1, failed: true))
}
