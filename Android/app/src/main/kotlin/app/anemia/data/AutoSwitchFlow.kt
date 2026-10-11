package app.anemia.data

import android.content.Intent
import android.os.SystemClock
import app.anemia.core.AutoSwitchPolicy
import app.anemia.core.SwitchBudget
import app.anemia.vpn.StatusChannel
import java.util.UUID

/**
 * Решение «увести ли живой туннель, потому что он перестал пропускавать».
 *
 * Пороги и бюджет живут в `AutoSwitchPolicy` (он же золото
 * `switch/due.golden.txt`, он же вызывает iOS-`AutoSwitch`), а здесь — только
 * процессные часы и память о последних уходах. Разделено именно так, потому
 * что на iOS решение принимает приложение, а отказы считает расширение: здесь
 * роль расширения играет `:vpn`, и его вердикт приходит широковещательным
 * сообщением.
 *
 * Объект процесса, а не состояние композиции: `remember` после поворота экрана
 * обнулил бы бюджет, и три ухода за четверть часа превратились бы в «по три на
 * каждый поворот».
 */
object AutoSwitchFlow {
    private val policy = AutoSwitchPolicy()

    /** Отметки уходов; правило окна — в `SwitchBudget`, он же у iOS. */
    private val budget = SwitchBudget(window = policy.window)

    /**
     * Проверить тик. Возвращает true, если переключение началось, — экрану это
     * нужно ровно для одного: снять отметку, когда эпизод не сложился (давать
     * холостому нажатию тратить слоты бюджета — то же, что на iOS уже
     * починено: три столкновения глушили автопереключение на 15 минут).
     */
    fun evaluate(
        message: Intent?,
        enabled: Boolean,
        serverCount: Int,
        busy: Boolean,
        onSwitch: (UUID?) -> Boolean,
    ): Boolean {
        val up = message?.getBooleanExtra(StatusChannel.EXTRA_TUNNEL_UP, false) == true
        val failures =
            if (message?.hasExtra(StatusChannel.EXTRA_HEALTH_FAILURES) == true) {
                message.getIntExtra(StatusChannel.EXTRA_HEALTH_FAILURES, 0)
            } else {
                null
            }
        val start =
            if (message?.hasExtra(StatusChannel.EXTRA_SESSION_START) == true) {
                message.getLongExtra(StatusChannel.EXTRA_SESSION_START, 0L)
            } else {
                null
            }
        val now = SystemClock.elapsedRealtime()
        val seconds = now / 1000.0
        val verdict = policy.decide(
            enabled = enabled,
            connected = up,
            busy = busy,
            serverCount = serverCount,
            healthFailures = failures,
            sessionAge = start?.let { (now - it) / 1000.0 } ?: 0.0,
            recentSwitches = budget.ages(seconds),
        )
        if (verdict != app.anemia.core.SwitchVerdict.Go) return false
        budget.note(seconds)
        val session = message?.getStringExtra(StatusChannel.EXTRA_SESSION_ID)
            ?.let { runCatching { UUID.fromString(it) }.getOrNull() }
        if (!onSwitch(session)) budget.refund(seconds)
        return true
    }
}
