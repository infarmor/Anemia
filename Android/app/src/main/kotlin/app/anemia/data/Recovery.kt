package app.anemia.data

import app.anemia.core.Country
import app.anemia.core.MaskingProfile
import app.anemia.core.ProxyServer
import java.util.UUID

/**
 * Лестница восстановления — порт `attemptReconnect()` из `AppState.swift`:
 *
 *   попытка 1 — повторить тот же сервер с тем же маскированием (большинство
 *              обрывов — мигание канала, а не сервер);
 *   попытка 2 — тот же сервер, но на ступень сильнее маскированием (похоже на DPI);
 *   попытка 3+ — переключиться на следующий неподобранный сервер.
 *   вне очереди — «нет линка»: пауза 5 с, та же ступенька, попытка не расходуется.
 *
 * Порядок ступеней, потолок `maxReconnects + 5` и обратные отсечки 1→2→4 с
 * (дальше по 4) — как на macOS: серия отказов не должна крутиться вечно.
 *
 * Порядок кандидатов — по рейтинговому скору из истории замеров (тот же
 * `ServerScoring.rankingScore`, что и у кнопки «Лучший», и то же, чем ранжирует
 * macOS), а не по последнему пингу: один удачный коннект не должен уводить
 * переключение на сервер, который в истории хуже.
 *
 * Два отличия названы вслух. macOS берёт следующего кандидата только из серверов
 * с известным quality-скором, потому что у него замеры идут фоном каждые
 * несколько минут; на Android фонового замера нет, поэтому кандидатами становятся
 * и те, кого ещё не мерили, — иначе после чистой установки переключаться было бы
 * «не на что». И здоровье сессии (iOS `AutoSwitch`: ≥2 отказа проверки здоровья)
 * здесь не проверяется: android-сборка движка ответа о здоровье не даёт, это
 * ждёт решения по пробам в `probe.go`.
 */
class Recovery(private val maxReconnects: Int = 3, private val maxHolds: Int = 12) {

    /** Профиль вызывающий берёт сам (выученный или глобальный); лестница решает
     * «кто» и «сильнее ли маскировать», а не «как именно». */
    sealed interface Step {
        /** Без линка переподключаться некуда: пауза, ступенька не расходуется. */
        data class Hold(val delayMs: Long) : Step
        data class Same(val delayMs: Long) : Step
        data class Escalate(val profile: MaskingProfile, val delayMs: Long) : Step
        data class Switch(val server: ProxyServer, val delayMs: Long) : Step
        data class GiveUp(val reason: String) : Step
    }

    private val tried = mutableSetOf<UUID>()
    private var attempts = 0
    private var holds = 0
    private var escalated: MaskingProfile? = null

    /** Идёт ли эпизод (экран по этому признаку не считает отказ новым). */
    val inProgress: Boolean get() = attempts > 0

    /**
     * Начать эпизод или шагнуть в нём. `losing` — сервер, на котором всё умерло;
     * в самом начале он заносится в «пробованные», иначе лестница крутилась бы
     * вокруг него же. Повтор здесь не подавляется: у сервиса ровно один отказ на
     * попытку, а заглушить шаг означало бы оставить эпизод без назначенной
     * переподготовки — потолок попыток от этого никуда не девается.
     */
    fun begin(losing: UUID?) {
        if (!inProgress) losing?.let { tried.add(it) }
        attempts += 1
    }

    /**
     * Ступенька эпизода. `candidates` — серверы вместе с рейтинговым скором из
     * истории замеров (`ProbeStore.score`, меньше — лучше; null — «мерить
     * нечего»): быстрее → медленнее → не мерили, среди равных — порядок списка.
     * `online` — есть ли физический линк: без него attempt не расходуется (то же
     * делает macOS через `holdForNetwork`), иначе за время поездки в метро
     * лестница выгорела бы до `GiveUp`.
     */
    fun step(
        current: ProxyServer?,
        currentProfile: MaskingProfile,
        candidates: List<Pair<ProxyServer, Double?>>,
        online: Boolean = true,
    ): Step {
        if (!online && holds < maxHolds) {
            attempts = (attempts - 1).coerceAtLeast(0)
            holds += 1
            return Step.Hold(HOLD_MS)
        }
        // Дольше `maxHolds` пауз молчать нельзя: оценка «линк есть» — это взгляд
        // ConnectivityManager, а не проверка доставки. Настоящая проверка —
        // attempt: `establish()` либо даёт туннель, либо нет. Так ошибка в
        // оценке стоит одну лишнюю паузу, а не зависший эпизод.
        holds = 0
        if (attempts > maxReconnects + 5) return Step.GiveUp("соединение потеряно")
        if (attempts == 2 && escalated == null) {
            val stronger = currentProfile.escalated
            if (stronger != null) {
                escalated = stronger
                return Step.Escalate(stronger, backoff())
            }
        }
        if (attempts >= 2) {
            val target = candidates
                .filter { (server, _) -> server.id != current?.id && server.id !in tried && !isRussianExit(server) }
                .minByOrNull { (_, score) -> score ?: Double.MAX_VALUE }
                ?.first
            if (target == null) return Step.GiveUp("нет рабочего сервера")
            tried.add(target.id)
            // Новый сервер — свой профиль, не чужая эскалация.
            escalated = null
            return Step.Switch(target, backoff())
        }
        return Step.Same(backoff())
    }

    /** Конец эпизода: успех или отказ. */
    fun reset() {
        attempts = 0
        holds = 0
        tried.clear()
        escalated = null
    }

    /** Профиль, который лестница навязала текущему серверу (null — обычный). */
    fun forcedProfile(): MaskingProfile? = escalated

    /** Выход внутри России не обходит Russian DPI — тот же блок с обеих сторон. */
    private fun isRussianExit(server: ProxyServer): Boolean =
        Country.code(server.name)?.uppercase() == "RU"

    /** 1→2→4 с, дальше по 4 — ровно те же числа, что у macOS. */
    private fun backoff(): Long = 1_000L * minOf(4, 1 shl (attempts - 1).coerceIn(0, 3))

    private companion object {
        /** Пауза «жду сеть»: достаточно короткая, чтобы линк после выхода из
         * лифта не ждал полминуты, и достаточно длинная, чтобы не будить
         * радиомодуль каждые несколько секунд. `maxHolds` таких — минута, после
         * чего лестница всё равно пробует подключить: попытка и есть настоящая
         * проверка линка. */
        const val HOLD_MS = 5_000L
    }
}
