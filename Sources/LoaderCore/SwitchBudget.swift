import Foundation

/// Учитывает уходы туннеля на другой сервер, чтобы `AutoSwitchPolicy` мог
/// сказать «хватит».
///
/// Раньше этот список держался руками на каждом месте вызова: iOS резал его по
/// окну, добавлял отметку и — отдельной строкой, уже после того как отказ
/// случился — снимал её, если эпизод не начался. Именно эта последняя строка и
/// была багом: холостые срабатывания съедали слоты бюджета, и три столкновения
/// подряд глушили автопереключение на четверть часа. Здесь и отсечение по окну,
/// и возврат слота — один код на обе платформы, закреплены золотом
/// `switch/budget.golden.txt`.
///
/// Отметки — абсолютные секунды какого-то одного монотонного часового пояса
/// (iOS: `Date.timeIntervalSince1970`, Android: `elapsedRealtime` в секундах).
/// Сам предикат работает с возрастом; перевод делает `ages(at:)`.
public struct SwitchBudget: Equatable, Sendable {
    /// Сколько летят отметки: старше окна они не должны ни считаться по бюджету,
    /// ни тем более занимать память всё время жизни процесса.
    public var window: TimeInterval
    public private(set) var marks: [TimeInterval]

    public init(window: TimeInterval = 15 * 60, marks: [TimeInterval] = []) {
        self.window = window
        self.marks = marks
    }

    /// Сбросить старое и записать новый уход.
    public mutating func note(_ now: TimeInterval) {
        prune(now)
        marks.append(now)
    }

    /// Снять уход, если он никуда не привёл (эпизод не начался). Снимается
    /// ровно одна отметка — не «все похожие»: два решения в одну миллисекунду
    /// различаются тем, что одно из них состоялось.
    public mutating func refund(_ now: TimeInterval) {
        guard let index = marks.lastIndex(of: now) else { return }
        marks.remove(at: index)
    }

    /// Ages для предиката: отсечённые по окну, отсортированных порядок не
    /// требуется — `AutoSwitchPolicy` меряет паузу по самому свежему.
    /// Отрицательные (часы шагнули) остаются как есть: предикат трактует их как
    /// «только что», и это безопасная сторона.
    public func ages(at now: TimeInterval) -> [TimeInterval] {
        marks.filter { now - $0 <= window }.map { now - $0 }
    }

    /// Только те отметки, что ещё считаются по окну. Намеренно то же условие,
    /// что в [ages(at:)] — иначе «список» и «возраст для предиката» могли бы
    /// разойтись, и золотая сверка ловила бы это только на одном из двух.
    public mutating func prune(_ now: TimeInterval) {
        marks = marks.filter { now - $0 <= window }
    }
}
