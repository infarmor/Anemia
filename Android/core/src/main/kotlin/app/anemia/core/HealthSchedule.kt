package app.anemia.core

/**
 * Порт `Sources/LoaderCore/HealthSchedule.swift` — когда туннелю можно спросить
 * здоровье и живо ли ещё ответ. Числа здесь не «наши, близкие»: это те же 60/60/30/90,
 * что держат iOS-расширение, и их сверка — золото `health/run.golden.txt`.
 */
class HealthSchedule(
    var watchedWindow: Double = 60.0,
    var wantedWindow: Double = 60.0,
    var interval: Double = 30.0,
    var staleAfter: Double = 90.0,
) {
    /** nil — «этого ещё не было»: без зрителя проверка не идёт, без прежнего
     * замера — идёт. Отрицательный `checkedAge` (часы шагнули назад) — «не
     * пора»: цикл расширения крутится каждые пять секунд, и «неизвестно =
     * мерить» превратило бы скачок времени в запрос на каждом витке. */
    fun healthDue(watchedAge: Double?, wantedAge: Double?, checkedAge: Double?): Boolean {
        if (watchedAge == null || !(watchedAge < watchedWindow)) return false
        if (wantedAge == null || !(wantedAge < wantedWindow)) return false
        if (checkedAge == null) return true
        return checkedAge >= interval
    }

    /** Замёрзший счётчик отказов — не доказательство: «два подряд» из последнего
     * замершего показания запускало бы охоту за сервером вечно. */
    fun signalFresh(checkedAge: Double?): Boolean {
        val age = checkedAge ?: return false
        return age >= 0 && age <= staleAfter
    }
}
