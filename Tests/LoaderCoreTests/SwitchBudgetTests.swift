import Foundation
import Testing

@testable import LoaderCore

/// Учёт уходов: те же правила, что закреплены золотом `switch/budget.golden.txt`
/// и что Android читает из своего зеркала.
@Test func testBudgetPrunesThenRecords() {
    var budget = SwitchBudget(window: 900, marks: [10, 999])
    budget.note(1000)
    #expect(budget.marks == [999, 1000])
    #expect(budget.ages(at: 1000) == [1, 0])
    // Граница окна включительно: «900 с назад» ещё платит по бюджету.
    var edge = SwitchBudget(window: 900, marks: [100])
    edge.note(1000)
    #expect(edge.marks == [100, 1000])
}

@Test func testBudgetRefundsOneMarkOnly() {
    // Холостое срабатывание не имеет права съесть слот: ровно ту отметку, что
    // поставила этот вызов, и ровно один раз.
    var budget = SwitchBudget(window: 900, marks: [500, 500])
    budget.refund(500)
    #expect(budget.marks == [500])
    budget.refund(500)
    #expect(budget.marks == [])
    budget.refund(500)          // снимать уже нечего, и это не ошибка
    #expect(budget.marks == [])
    // Возврат не чистит окно: снятие отметки — не «проверить, не устарело ли».
    var stale = SwitchBudget(window: 900, marks: [5, 1000])
    stale.refund(1000)
    #expect(stale.marks == [5])
}

@Test func testBudgetAgesMatchPruneRule() {
    let budget = SwitchBudget(window: 900, marks: [50, 900, 999, 2000])
    // Отрицательный возраст (часы шагнули вперёд относительно отметки)
    // остаётся: предикат читает его как «только что», и это безопасная
    // сторона. Просроченная же отметка (50 → возраст 950) из возраста
    // выбрасывается тем же условием, что и из списка.
    #expect(budget.ages(at: 1000) == [100, 1, -1000])
    var pruned = SwitchBudget(window: 900, marks: [50, 900, 999, 2000])
    pruned.prune(1000)
    #expect(pruned.marks == [900, 999, 2000])
    #expect(pruned.ages(at: 1000) == budget.ages(at: 1000))
}
