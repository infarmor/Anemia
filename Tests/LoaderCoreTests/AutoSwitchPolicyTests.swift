import Foundation
import Testing

@testable import LoaderCore

/// Границы решения «уводить ли туннель на другой сервер» — тот же предикат,
/// что золотом сверяется с Kotlin (`switch/due.golden.txt`), и красным он обязан
/// стать и на Swift-стороне: iOS вызывает именно его из `AutoSwitch.evaluate()`.
private func verdict(
    _ policy: AutoSwitchPolicy = AutoSwitchPolicy(),
    enabled: Bool = true,
    connected: Bool = true,
    busy: Bool = false,
    serverCount: Int = 2,
    failures: Int? = 2,
    sessionAge: TimeInterval = 120,
    recent: [TimeInterval] = []
) -> SwitchVerdict {
    policy.decide(
        enabled: enabled, connected: connected, busy: busy, serverCount: serverCount,
        healthFailures: failures, sessionAge: sessionAge, recentSwitches: recent
    )
}

@Test func testAutoSwitchNeedsTwoFailures() {
    // Единичный отказ — это потерянный пакет, а не мёртвый выход.
    #expect(verdict(failures: nil) == .unproven)
    #expect(verdict(failures: 0) == .unproven)
    #expect(verdict(failures: 1) == .unproven)
    #expect(verdict(failures: 2) == .go)
    #expect(verdict(failures: 9) == .go)
    // Порог меняется вместе с политикой — не «два», потому что так получилось.
    #expect(verdict(AutoSwitchPolicy(failuresToAct: 3), failures: 2) == .unproven)
    #expect(verdict(AutoSwitchPolicy(failuresToAct: 3), failures: 3) == .go)
}

@Test func testAutoSwitchGivesAFreshSessionTimeToSettle() {
    // Ровно минута — ещё не «отсидел»: сравнение строгое.
    #expect(verdict(sessionAge: 60) == .unproven)
    #expect(verdict(sessionAge: 61) == .go)
    #expect(verdict(sessionAge: -5) == .unproven)
    // Возраст без числа (часы уехали) не читается как «сессия вечная».
    #expect(verdict(sessionAge: .nan) == .unproven)
}

@Test func testAutoSwitchBudgetIsThreePerQuarterHour() {
    #expect(verdict(recent: [300, 600]) == .go)
    #expect(verdict(recent: [300, 600, 800]) == .throttled)
    // За окном записи уже не считаются: иначе список никогда не пустеет. Граница
    // окна — включительно, «900 с назад» ещё платит по бюджету.
    #expect(verdict(recent: [901, 300, 400]) == .go)
    #expect(verdict(recent: [900, 300, 400]) == .throttled)
    // От последнего переключения обязано пройти три минуты; порядок списка не
    // решает ничего — считается ближайшая запись.
    #expect(verdict(recent: [179]) == .throttled)
    #expect(verdict(recent: [180]) == .throttled)
    #expect(verdict(recent: [181]) == .go)
    #expect(verdict(recent: [1000, 100]) == .throttled)
    // Отрицательный возраст (часы шагнули назад) — «только что», а не обход паузы.
    #expect(verdict(recent: [-1]) == .throttled)
}

@Test func testAutoSwitchYieldsToWhateverOwnsTheTunnel() {
    #expect(verdict(enabled: false) == .off)
    #expect(verdict(serverCount: 1) == .off)
    #expect(verdict(serverCount: 0) == .off)
    #expect(verdict(connected: false) == .notConnected)
    #expect(verdict(busy: true) == .busy)
    // Порядок гейтов виден на кейсе, где они спорят: выключенный режим важнее
    // занятости туннеля, иначе экран показывал бы «занято» при выключенной опции.
    #expect(verdict(enabled: false, busy: true, serverCount: 1) == .off)
    #expect(verdict(connected: false, busy: true) == .notConnected)
}

@Test func testAutoSwitchPrunesItsOwnBudget() {
    let policy = AutoSwitchPolicy()
    #expect(policy.retained(recentSwitches: [100, 900, 901, 5_000]) == [100, 900])
    #expect(policy.retained(recentSwitches: []) == [])
}
