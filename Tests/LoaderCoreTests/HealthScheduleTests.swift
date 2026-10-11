import Foundation
import Testing

@testable import LoaderCore

/// Границы расписания: тот же `HealthSchedule`, что вызывает цикл
/// `startMonitor()` в iOS-расширении, и он же золотом сверяется с Kotlin
/// (`health/run.golden.txt`).
private func due(_ s: HealthSchedule = HealthSchedule(), watched: TimeInterval?, wanted: TimeInterval?,
                 checked: TimeInterval?) -> Bool {
    s.healthDue(watchedAge: watched, wantedAge: wanted, checkedAge: checked)
}

@Test func testHealthNeedsAWatcherAndARequest() {
    // Ни один из часов ещё не бил — проверка не нужна вовсе.
    #expect(!due(watched: nil, wanted: 10, checked: nil))
    #expect(!due(watched: 10, wanted: nil, checked: nil))
    #expect(due(watched: 10, wanted: 10, checked: nil))
    // Окна сравнены строго: ровно 60 с — уже «не следят».
    #expect(due(watched: 59.9, wanted: 10, checked: 90))
    #expect(!due(watched: 60, wanted: 10, checked: 90))
    #expect(due(watched: 10, wanted: 59.9, checked: 90))
    #expect(!due(watched: 10, wanted: 60, checked: 90))
    // Отказ от «переключаться самому» приходит через wanted: приложение просто
    // перестаёт поднимать флаг, и просроченная просьба сама ничего не мерит.
    #expect(!due(watched: 10, wanted: 10_000, checked: nil))
}

@Test func testHealthIntervalIsNotTooEager() {
    #expect(!due(watched: 10, wanted: 10, checked: 29.9))
    #expect(due(watched: 10, wanted: 10, checked: 30))
    #expect(due(watched: 10, wanted: 10, checked: 100_000))
    // Отрицательный разрыв (часы шагнули назад) — «не пора»: цикл расширения
    // крутится каждые пять секунд, и «неизвестно = мерить» дало бы запрос на
    // каждом витке.
    #expect(!due(watched: -5, wanted: -1, checked: -1))
    // Пороги — часть политики.
    let custom = HealthSchedule(watchedWindow: 120, wantedWindow: 150, interval: 10)
    #expect(due(custom, watched: 100, wanted: 100, checked: 15))
    #expect(!due(custom, watched: 121, wanted: 100, checked: 15))
    #expect(!due(custom, watched: 100, wanted: 151, checked: 15))
    #expect(!due(custom, watched: 100, wanted: 100, checked: 9))
}

@Test func testFrozenHealthReadingStopsBeingEvidence() {
    let s = HealthSchedule()
    #expect(s.signalFresh(checkedAge: nil) == false)
    #expect(s.signalFresh(checkedAge: 89.9) == true)
    #expect(s.signalFresh(checkedAge: 90) == true)
    #expect(s.signalFresh(checkedAge: 90.1) == false)
    // Отрицательный возраст — тоже не доказательство: разрыв нельзя измерить.
    #expect(s.signalFresh(checkedAge: -1) == false)
    #expect(HealthSchedule(staleAfter: 60).signalFresh(checkedAge: 61) == false)
    // Именно эта пара не даёт «замёрзшему» счётчику выглядеть двумя отказами
    // подряд: пора мерить — но старое показание уже не аргумент.
    #expect(due(watched: 10, wanted: 10, checked: 100_000))
    #expect(!s.signalFresh(checkedAge: 100_000))
}
