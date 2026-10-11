package app.anemia.data

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.net.VpnService
import androidx.core.content.ContextCompat
import java.net.NetworkInterface
import java.net.SocketException
import app.anemia.core.ProxyServer
import app.anemia.ui.RecoveryEpisode
import app.anemia.ui.sharedStore
import app.anemia.vpn.AnemiaVpnService

/**
 * Подключение без экрана: плитке Quick Settings нужна ровно та же пара шагов,
 * что делает кнопка «Подключить» — взять выбранный сервер, собрать `TunnelSetup`,
 * попросить систему поднять сервис.
 *
 * Файл отдельный не потому, что таких мест два, а потому, что экран в этом
 * заходе правит другой проход. Когда до экрана дойдёт очередь, его
 * `startSession` обязан вызвать [start]: две ветки, из которых одна знает про
 * обход по приложениям и выученное маскирование, а другая нет, разъедутся
 * обязательно.
 *
 * Лестница восстановления по-прежнему не заводится отсюда: она живёт в
 * обработчике широковещательного сообщения ([app.anemia.ui.RecoveryEpisode]),
 * и без открытого экрана переподключением по отказу руководить некому. Снять
 * же начатый где-то в другом месте эпизод остановка обязана — см. [stop]:
 * иначе туннель вернётся через секунду после нажатия плитки.
 */
object SessionStarter {
    private const val PREFS = "anemia"

    /** Имя интерфейса туннеля; `tunl0` и `ip6tnl0` живут в системе всегда. */
    private val TUNNEL_NAME = Regex("tun\\d+")

    /** То же имя ключа, что у экрана (`PREF_ADBLOCK`): приватную константу отсюда
     * не видно, а два разных значения одного флага хуже, чем одно имя в двух
     * местах. */
    private const val PREF_ADBLOCK = "adBlock"

    /**
     * Жив ли туннель. «Процесс `:vpn` существует» признаком не было и не будет:
     * после `stopSelf()` процесс ещё минуты два висит в кэше (замерено: pid
     * 3719 жив, `tun0` нет), и плитка на это вешалась — нажатие вместо
     * подключения звало `stop()`, и подключиться из шторки было нельзя. Отсюда
     * две необходимые части: процесс жив И интерфейс `tunN` на месте.
     *
     * Оставшаяся щель названа вслух: если в то короткое время, пока наш процесс
     * ещё не убили, поднимется чужой VPN, его интерфейс тоже пройдёт проверку.
     * Владелец туннеля наружу не отдаётся (`NetworkCapabilities.getOwnerUid` —
     * @SystemApi), так что это потолок доступной точности.
     */
    fun tunnelUp(context: Context): Boolean {
        if (!processAlive(context)) return false
        val names = try {
            java.util.Collections.list(NetworkInterface.getNetworkInterfaces()).map { it.name }
        } catch (error: SocketException) {
            // Список интерфейсов не прочитан — честнее сказать «не подключено»,
            // чем врать про живой туннель.
            android.util.Log.w("Anemia", "интерфейсы не читаются: ${error.message}")
            return false
        }
        return names.any { TUNNEL_NAME.matches(it) }
    }

    /** Жив ли процесс туннеля. С Android 8 `getRunningAppProcesses()` возвращает
     * только собственные процессы приложения — ровно то, что здесь и нужно. */
    fun processAlive(context: Context): Boolean {
        val manager = context.getSystemService(ActivityManager::class.java) ?: return false
        val processes = manager.runningAppProcesses ?: return false
        val name = context.packageName + ":vpn"
        return processes.any { it.processName == name }
    }

    /** Интент согласия на VPN, если оно ещё не выдано; null — можно подключаться. */
    fun consent(context: Context): Intent? = VpnService.prepare(context)

    /** Имя выбранного сервера — подпись плитки. `—`, если выбора нет. */
    fun selectedName(context: Context): String =
        sharedStore(context.applicationContext).selected()?.name?.takeIf { it.isNotBlank() } ?: "—"

    /**
     * Запросить подключение. Текст — причина отказа, который надо показать
     * человеку; null — сообщение ушло в `:vpn`.
     */
    fun start(context: Context): String? {
        val app = context.applicationContext
        val store = sharedStore(app)
        val server: ProxyServer = store.selected() ?: return "Нет выбранного сервера"
        if (consent(app) != null) return "Разрешите Anemia создавать VPN-подключения"
        val setup = TunnelSetup(
            server = server,
            masking = store.maskingFor(server),
            splitTunnel = store.state.splitTunnel,
            adBlock = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getBoolean(PREF_ADBLOCK, false),
        )
        ContextCompat.startForegroundService(
            app,
            Intent(app, AnemiaVpnService::class.java).putExtra(AnemiaVpnService.EXTRA_SETUP, setup.toJson()),
        )
        return null
    }

    /** Команда «отключись» самому сервису: `stopService()` туннель не рвёт. */
    fun stop(context: Context) {
        val app = context.applicationContext
        // Снять эпизод здесь, а не только по широковещанию об остановке: экран
        // может быть закрыт, его приёмник тогда не зарегистрирован, а
        // отложенная ступенька лестницы живёт в процессе и подняла бы туннель
        // через секунду после того, как человек нажал плитку.
        RecoveryEpisode.abort()
        app.startService(
            Intent(app, AnemiaVpnService::class.java)
                .putExtra(AnemiaVpnService.EXTRA_DISCONNECT, true),
        )
    }

    /** То же переключение, что делает нажатие плитки: вверх — вниз, вниз — вверх. */
    fun toggle(context: Context): String? {
        if (tunnelUp(context)) {
            stop(context)
            return null
        }
        return start(context)
    }
}
