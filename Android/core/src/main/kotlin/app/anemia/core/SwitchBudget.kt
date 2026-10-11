package app.anemia.core

/**
 * Порт `Sources/LoaderCore/SwitchBudget.swift` — учёт уходов на другой сервер,
 * чтобы `AutoSwitchPolicy` мог сказать «хватит». Отметки — абсолютные секунды
 * одних и тех же часов (Android: `elapsedRealtime() / 1000`).
 *
 * На iOS этот список держался руками в трёх местах, и именно в месте «снять
 * отметку, если эпизод не начался» сидел баг: холостые срабатывания съедали
 * слоты бюджета. Здесь правило одно, и оно закреплено золотом
 * `switch/budget.golden.txt`.
 */
class SwitchBudget(
    val window: Double = 15 * 60.0,
    marks: List<Double> = emptyList(),
) {
    var marks: List<Double> = marks
        private set

    /** Сбросить старое и записать новый уход. */
    fun note(now: Double) {
        prune(now)
        marks = marks + now
    }

    /** Снять уход, который никуда не привёл. Ровно одну отметку, не «все
     * похожие»: два решения в одну миллисекунду различаются тем, что одно из
     * них состоялось. */
    fun refund(now: Double) {
        val index = marks.lastIndexOf(now)
        if (index >= 0) marks = marks.toMutableList().also { it.removeAt(index) }
    }

    /** Только те отметки, что ещё считаются по окну. */
    fun prune(now: Double) {
        marks = marks.filter { now - it <= window }
    }

    /** Возраст для предиката: то же условие окна, что в [prune] (иначе «список»
     * и «возраст» разошлись бы, а золото проверяло бы одно из двух).
     * Отрицательный возраст остаётся как есть — предикат читает его как
     * «только что», и это безопасная сторона. */
    fun ages(now: Double): List<Double> = marks.filter { now - it <= window }.map { now - it }
}
