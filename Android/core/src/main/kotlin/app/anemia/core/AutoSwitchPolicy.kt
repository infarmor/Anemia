package app.anemia.core

/**
 * Порт `Sources/LoaderCore/AutoSwitchPolicy.swift` — решение «уводить ли
 * живой туннель на другой сервер» после отказов проверки здоровья.
 *
 * Тот же текст правил, что держит iOS в `AutoSwitch.evaluate()`, и то же
 * золото: `switch/due.golden.txt` — ответы Swift-предиката на фикстуру
 * `switch/due.txt`, сверка здесь (проверка «вердикт переключения совпадает со
 * Swift») прогоняет кейсы через Kotlin и обязана получить те же строки,
 * включая отказ разбора кривой строки.
 */
enum class SwitchVerdict(val label: String) {
    Off("off"),
    NotConnected("notConnected"),
    Busy("busy"),
    Unproven("unproven"),
    Throttled("throttled"),
    Go("go"),
}

class AutoSwitchPolicy(
    /** Сколько подряд неудачных проверок здоровья нужно, чтобы пошевелиться. */
    val failuresToAct: Int = 2,
    /** Моложе этого сессия ещё не считается: первые проверки только что
     * поднятого туннеля падают по причинам, которые туннель сам и лечит. */
    val minSessionAge: Double = 60.0,
    /** Сколько далеко назад смотрит бюджет. */
    val window: Double = 15 * 60.0,
    /** Сколько переключений бюджет вообще терпит. */
    val maxSwitches: Int = 3,
    /** Пауза между двумя переключениями. */
    val minGap: Double = 3 * 60.0,
) {
    /**
     * `recentSwitches` — возраст прошлых переключений в секундах, в любом
     * порядке: пауза считается по самому свежему, и несортированный список не
     * может прочитаться как «давным-давно». Отрицательный возраст (часы шагнули
     * назад) — «только что», то есть пауза, а не обход паузы.
     *
     * `healthFailures` = null означает «здоровья ещё не мерили»: это не
     * «сервер в порядке» и не «сервер мёртв».
     */
    fun decide(
        enabled: Boolean,
        connected: Boolean,
        busy: Boolean,
        serverCount: Int,
        healthFailures: Int?,
        sessionAge: Double,
        recentSwitches: List<Double>,
    ): SwitchVerdict {
        if (!enabled || serverCount <= 1) return SwitchVerdict.Off
        if (!connected) return SwitchVerdict.NotConnected
        if (busy) return SwitchVerdict.Busy
        if (healthFailures == null || healthFailures < failuresToAct) return SwitchVerdict.Unproven
        // Сравнение с NaN ложно всегда — неизвестный возраст это «не трогать».
        if (!(sessionAge > minSessionAge)) return SwitchVerdict.Unproven
        val kept = retained(recentSwitches)
        if (kept.size >= maxSwitches) return SwitchVerdict.Throttled
        if (kept.any { !(it > minGap) }) return SwitchVerdict.Throttled
        return SwitchVerdict.Go
    }

    /** Записи, которые всё ещё считаются по бюджету; экран чистит свой список
     * этим же, иначе он растёт всё время жизни процесса. */
    fun retained(recentSwitches: List<Double>): List<Double> =
        recentSwitches.filter { it <= window }
}
