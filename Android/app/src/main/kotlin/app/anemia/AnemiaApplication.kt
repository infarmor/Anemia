package app.anemia

import android.app.Application
import android.util.Log
import app.anemia.data.AppBypass
import app.anemia.ui.sharedStore
import kotlin.concurrent.thread

/**
 * Круг автообновления подписок — порт `startSubscriptionAutoRefresh` с macOS:
 * первый раунд через 10 с после старта процесса, дальше проверка каждые 5 мин,
 * а решение «трогать ли панель» целиком в [app.anemia.core.Subscription.refreshIsDue]
 * (без TLS — никогда; интервал — тот, что попросила панель, но не чаще часа и
 * не реже суток). Пока круг ничего не должен, он не ходит в сеть вовсе.
 *
 * WorkManager здесь сознательно нет: он означал бы смену списка серверов у
 * выключенного приложения, чего на iOS и macOS нет — там автообновление живёт,
 * пока живо приложение. Тот же смысл и здесь; с появлением фоновой работы
 * первым условием остаётся `tlsProtected`.
 */
class AnemiaApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // Список приложений «Мимо VPN» читает процесс туннеля при `establish()`,
        // а `Application` создаётся и там, и в интерфейсе — отсюда инициализация
        // до проверки имени процесса.
        AppBypass.init(this)
        // Сервис живёт в процессе `:vpn`, и `Application` там создаётся тоже.
        // Без этой проверки раундов было бы два, и оба писали бы один
        // `state.json`: последний победитель стирал бы запись первого.
        val process = Application.getProcessName()
        if (process != packageName) {
            // Молчаливый отказ здесь означал бы «автообновление чудесным
            // образом не работает» — имя процесса это то, что спросят первым.
            Log.i(TAG, "not the UI process ($process), no refresh timer")
            return
        }
        // Состояние читается на этом же потоке: `Application.onCreate` —
        // главный поток, и первый запуск процесса не должен ждать диск.
        val store by lazy { sharedStore(this) }
        thread(name = "subs", isDaemon = true) {
            Thread.sleep(FIRST_ROUND_MS)
            while (true) {
                // Падение здесь — не конец света, но и не тишина: без строки в
                // logcat таймер молча умирал бы до конца жизни процесса.
                // `Throwable`, а не `Exception`: слушатель-представление на
                // мёртвом окне бросает `Error`-подобное, и круг после этого
                // обязан жить дальше.
                runCatching { store.refreshStale() }.onSuccess { round ->
                    if (round != null) {
                        Log.i(
                            TAG, "auto-refresh: ready=${round.checked} loaded=${round.loaded} " +
                                "skipped-no-tls=${round.skippedInsecure}",
                        )
                    }
                }.onFailure { Log.w(TAG, "auto-refresh round failed: ${it.message}") }
                Thread.sleep(ROUND_INTERVAL_MS)
            }
        }
    }
}

private const val TAG = "anemia"

/** Как на macOS: дасть приложению отрисоваться и прочитать состояние. */
private const val FIRST_ROUND_MS = 10_000L

/** Частота проверок, а не перезагрузок: между проверками панель трогает только её срок. */
private const val ROUND_INTERVAL_MS = 5 * 60_000L
