import Foundation

/// Когда туннелю можно в очередной раз спросить здоровье — и живо ли ещё то,
/// что он ответил.
///
/// Проверка — это настоящий запрос наружу: DNS, TCP, TLS через выход, каждые
/// полчаса-минут. На телефоне, который лежит в кармане, такая гонка стоит и
/// батареи, и трафика, а полезна ровно пока кто-то на туннель смотрит. Поэтому
/// правило живёт здесь, а не в двух местах: на iOS оно было разбросано по циклу
/// `startMonitor()` в расширении (у которого нет тест-хоста, и проверить его
/// можно было только глазами на устройстве), а Android обязан сойтись с ним
/// числами.
///
/// Включён ли режим «переключаться самому» отдельным флагом здесь не передаётся:
/// на iOS приложение поднимает `wantsHealth` только когда режим включён, так что
/// отказ от опроса приходит сам собой — через `wantedAge`.
public struct HealthSchedule: Equatable, Sendable {
    /// Сколько ещё считается, что приложение следит за туннелем.
    public var watchedWindow: TimeInterval
    /// Сколько ещё считается его просьба мерить здоровье.
    public var wantedWindow: TimeInterval
    /// Как часто проверку разрешено повторять.
    public var interval: TimeInterval
    /// После этого счётчик отказов считается устаревшим.
    public var staleAfter: TimeInterval

    public init(watchedWindow: TimeInterval = 60, wantedWindow: TimeInterval = 60,
                interval: TimeInterval = 30, staleAfter: TimeInterval = 90) {
        self.watchedWindow = watchedWindow
        self.wantedWindow = wantedWindow
        self.interval = interval
        self.staleAfter = staleAfter
    }

    /// Ages — возраст соответствующих событий в секундах на момент решения;
    /// nil означает «этого ещё не было»: nil у `watched`/`wanted` — «не
    /// следят» (на iOS там `Date.distantPast`), nil у `checked` — «ещё не
    /// мерили», то есть пора.
    ///
    /// Отрицательный возраст `checked` (часы шагнули назад, разрыв нельзя
    /// измерить) — это «не пора», а не «пора»: расширение крутит цикл каждые
    /// пять секунд, и «неизвестно = мерить» превратило бы скачок времени в
    /// запрос на каждом витке. Замороженный счётчик при этом перестаёт быть
    /// доказательством — см. [signalFresh].
    public func healthDue(watchedAge: TimeInterval?, wantedAge: TimeInterval?, checkedAge: TimeInterval?) -> Bool {
        guard let watchedAge, watchedAge < watchedWindow else { return false }
        guard let wantedAge, wantedAge < wantedWindow else { return false }
        guard let checkedAge else { return true }
        return checkedAge >= interval
    }

    /// живо ли ещё показание, записанное `checkedAge` секунд назад.
    ///
    /// Это защита от молчаливой заморозки: `healthFailures` — поле отчёта, и
    /// когда проверки встают — скачок часов назад, ушедший экран, молчащий
    /// движок, — последнее значение осталось бы «двумя отказами подряд»
    /// навсегда. А «два отказа подряд» — ровно тот порог, на который смотрит
    /// решение о переключении: без этого вопроса оно начинало бы охоту за
    /// сервером по данным, которым ничего не известно.
    ///
    /// Отрицательный возраст — тоже «не свежо»: разрыв нельзя измерить, и
    /// честно промолчать дешевле, чем переключаться по непроверяемым данным.
    public func signalFresh(checkedAge: TimeInterval?) -> Bool {
        guard let checkedAge else { return false }
        return checkedAge >= 0 && checkedAge <= staleAfter
    }
}
