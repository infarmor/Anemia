package app.anemia.core

/** Счётчики живого движка: байты вверх и вниз с момента запуска ранa. */
data class TrafficCounters(val up: Long, val down: Long)

/**
 * Что сказала одна проверка здоровья. `Measured` несёт число, которое обязано
 * попасть в отчёт, — и это не всегда -1 при отказе: запрос, ответивший за пять
 * секунд, отвечен, и отчёт обязан показать пять секунд, и это всё равно отказ.
 */
sealed interface HealthOutcome {
    object Silence : HealthOutcome
    data class Measured(val ms: Int, val failed: Boolean) : HealthOutcome
}

/** Состояние здоровья, которое туннель хранит о себе. */
data class HealthState(val health: Int? = null, val failures: Int = 0)

/**
 * Порт `Sources/LoaderCore/TunnelHealth.swift` — правил из
 * `PacketTunnelProvider.checkHealth`, вынутых из расширения: у tunnel-таргета
 * тестового хоста нет, и внутри расширения эти строки было видно только глазами
 * на устройстве. Теперь они проверяются здесь так же, как остальное `:core`.
 *
 * Два движка — два вопроса. У xray есть dialer: один настоящий запрос через
 * живое соединение. У AmneziaWG его нет, и остаётся смотреть на счётчики: если
 * телефон отправляет, а в ответ за целый интервал ничего не пришло — рукопожатие
 * в порядке, а путь нет.
 */
class TunnelHealth(
    /** Крошечный запрос, который едет дольше этого, — туннель, который ничего
     * не пропускает, как бы вежливо он ни отвечал. */
    var requestLimitMs: Int = 3_000,
    /** AmneziaWG нужно доказательство, что телефон вообще пытался: с погасшим
     * экраном не отправляется ничего, и тишина — не отказ. */
    var sendFloorBytes: Long = 2_000,
) {
    /** Xray: null — запрос не завершился вовсе (в том числе «движок не
     * работает»): это туннель, который ничего не пропускает. */
    fun request(ms: Int?): HealthOutcome {
        if (ms == null) return HealthOutcome.Measured(-1, true)
        return HealthOutcome.Measured(ms, ms > requestLimitMs)
    }

    /**
     * AmneziaWG по двум чтениям одного и того же рана.
     *
     * `counters == null` — движок не ответил: ничего не утверждается, и
     * вызывающий обязан оставить прежний снимок до следующего раза (потерянное
     * чтение расширяет следующий интервал, а не выдумывает простстой). То же
     * «молчание» возвращается для первого чтения, для сброшенных счётчиков и
     * для телефона, который ничего не отправлял.
     */
    fun counters(
        counters: TrafficCounters?,
        previous: TrafficCounters?,
        latency: Int?,
    ): HealthOutcome {
        if (counters == null || previous == null) return HealthOutcome.Silence
        val sent = counters.up - previous.up
        val received = counters.down - previous.down
        if (received > 0) return HealthOutcome.Measured(latency ?: 1, false)
        // Отрицательная дельта — это перезапуск движка, а не молчание сервера.
        if (sent > sendFloorBytes) return HealthOutcome.Measured(-1, true)
        return HealthOutcome.Silence
    }

    /** Что вердикт меняет в отчёте и в счётчике подряд: именно `failures`
     * потом читает [AutoSwitchPolicy], поэтому «два подряд» живёт здесь, а не у
     * того, кто вызывает проверку. */
    fun apply(outcome: HealthOutcome, state: HealthState): HealthState = when (outcome) {
        HealthOutcome.Silence -> state
        is HealthOutcome.Measured ->
            HealthState(outcome.ms, if (outcome.failed) state.failures + 1 else 0)
    }
}
