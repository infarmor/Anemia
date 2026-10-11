package app.anemia.vpn

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import app.anemia.data.SessionStarter
import app.anemia.ui.SessionActivity

/**
 * Плитка Quick Settings: подключить и отключить туннель, не открывая экран.
 *
 * Нажатие не поднимает сервис само — оно запускает [SessionActivity]. Причина
 * не в удобствах: с Android 12 foreground-сервис разрешено стартовать только
 * из состояния «приложение на виду», а из шторки приложение как раз не на виду.
 * Активность-прослойка даёт и это состояние, и окно для системного диалога
 * согласия на VPN, который из `TileService` не показать.
 *
 * Состояние плитки читается из живого процесса `:vpn`, а не из широковещательного
 * сообщения: процесса туннеля может и не быть, когда шторка открывается (экран
 * закрыт, сервис ещё не поднят), а врать про «подключено» плитка не вправе.
 */
class AnemiaTileService : TileService() {

    override fun onStartListening() {
        super.onStartListening()
        render()
    }

    // Поток один на экземпляр сервиса: `selectedName` читает состояние с диска,
    // а шторку открывают с главной нити.
    private val backgroundThread = HandlerThread("tile").apply { start() }
    private val background = Handler(backgroundThread.looper)
    private val reply = Handler(android.os.Looper.getMainLooper())

    private fun render() {
        val tile = qsTile ?: return
        val up = SessionStarter.tunnelUp(this)
        tile.state = if (up) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = if (up) "Anemia: подключено" else "Anemia: отключено"
        // Подпись есть не на всех версиях: на 34+ это имя сервера, на 29—33
        // плитка показывает только label, и молча потерять имя хуже, чем
        // не показать его вовсе — отсюда проверка версии, а не флаг.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // Имя берется из состояния на диске, а `onStartListening` система
            // зовёт на главной нити каждый раз, когда кто-то отворяет шторку:
            // читать `state.json` здесь — это тот же грех, что I/O в композиции
            // экрана. Поэтому счётчик и состояние берутся сразу, а подпись
            // догоняет, когда дочтётся.
            val app = applicationContext
            background.post {
                val name = SessionStarter.selectedName(app)
                reply.post {
                    val current = qsTile ?: return@post
                    current.subtitle = name
                    current.updateTile()
                }
            }
        }
        tile.updateTile()
    }

    override fun onDestroy() {
        backgroundThread.quitSafely()
        super.onDestroy()
    }

    override fun onStopListening() {
        // Плитка больше не видна: нечего и держать очередь фоновых чтений.
        background.removeCallbacksAndMessages(null)
        super.onStopListening()
    }

    override fun onClick() {
        val starter = Intent(this, SessionActivity::class.java)
        when {
            // Порядок этих форм определяет не вкус, а таблицы API: форма с
            // `PendingIntent` появилась только в 34, а форма с `Intent` живёт с
            // 29 и помечена устаревшей как раз с 34-го.
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE ->
                startActivityAndCollapse(pending(starter))
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q -> {
                @Suppress("StartActivityAndCollapseDeprecated")
                startActivityAndCollapse(starter)
            }
            // API 28: collapse-хелпера ещё нет — активность стартует как
            // обычная, шторка закроется сама, когда поверх неё встанет системный
            // диалог согласия.
            else -> runCatching { pending(starter).send() }
        }
    }

    private fun pending(intent: Intent) = PendingIntent.getActivity(
        this, 0, intent,
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )
}
