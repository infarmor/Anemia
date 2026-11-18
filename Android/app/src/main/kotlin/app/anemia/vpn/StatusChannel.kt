package app.anemia.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import app.anemia.R

/**
 * Статус туннеля: уведомление foreground-сервиса и широковещательное
 * сообщение для интерфейса.
 *
 * На iOS Live Activity кормит из приложения, потому что расширение не может
 * ничего рисовать. Здесь процесс туннеля сам владеет уведомлением: снимает
 * счётчики у движка в своём процессе и сам их показывает — без таймера в UI
 * и без «а живо ли ещё приложение».
 */
object StatusChannel {
    /** Только внутри приложения: наружу статус не уходит. */
    const val ACTION = "app.anemia.STATUS"
    const val EXTRA_TEXT = "app.anemia.extra.TEXT"
    /** Жив ли туннель *сейчас* и какой сервер его несёт — экрану этого не
     * видно, а от обоих зависит, куда девать замеры задержки. */
    const val EXTRA_TUNNEL_UP = "app.anemia.extra.UP"
    const val EXTRA_SESSION_ID = "app.anemia.extra.SESSION"
    const val EXTRA_UP_BYTES = "app.anemia.extra.UP_BYTES"
    const val EXTRA_DOWN_BYTES = "app.anemia.extra.DOWN_BYTES"
    const val EXTRA_LOCKDOWN = "app.anemia.extra.LOCKDOWN"
    /** false — обычный тик, true — сессия умерла: лестница восстановления
     * заводится только на второе. */
    const val EXTRA_FAILED = "app.anemia.extra.FAILED"
    /**
     * Подряд неудачных проверок здоровья и момент подъёма сессии
     * (`SystemClock.elapsedRealtime`, он в обоих процессах отсчитывается от
     * одной загрузки). Решение «уводить ли туннель» принимает экран, а не
     * сервис — ровно как на iOS, где расширение только считает отказы.
     *
     * Отсутствующий `EXTRA_HEALTH_FAILURES` означает «свежей проверки не было»,
     * и это не «ноль отказов»: без такого различия замёрзший счётчик уводил бы
     * выход на каждом тике.
     */
    const val EXTRA_HEALTH_FAILURES = "app.anemia.extra.HEALTH_FAILURES"
    const val EXTRA_SESSION_START = "app.anemia.extra.SESSION_START"
    /** true — туннель до этого поднимался, то есть отказ стал обрывом живой
     * сессии. Первый отказ ещё не поднявшегося подключения — ошибка в
     * конфигурации, и на macOS лестница для неё тоже не заводится. */
    const val EXTRA_DROPPED = "app.anemia.extra.DROPPED"

    /** true — сессию остановили по команде, а не уронили. Отложенная ступенька
     * лестницы обязана на это сняться: иначе приложение поднимет туннель через
     * пару секунд после того, как человек нажал «Отключить» (плиткой — так вообще
     * без всякого экрана). */
    const val EXTRA_STOPPED = "app.anemia.extra.STOPPED"

    // — запрос интерфейса к процессу туннеля: один GET сквозь VPN. Ответ
    // возвращается широким сообщением, потому что другого общего канала у
    // процессов нет (bind-сервиса здесь намеренно нет).
    const val ACTION_FETCH_REPLY = "app.anemia.FETCH_REPLY"
    const val EXTRA_FETCH_ID = "app.anemia.extra.FETCH_ID"
    const val EXTRA_FETCH_URL = "app.anemia.extra.FETCH_URL"
    const val EXTRA_FETCH_TIMEOUT_MS = "app.anemia.extra.FETCH_TIMEOUT"
    const val EXTRA_FETCH_MAX_BYTES = "app.anemia.extra.FETCH_MAX"
    const val EXTRA_FETCH_MS = "app.anemia.extra.FETCH_MS"
    const val EXTRA_FETCH_BYTES = "app.anemia.extra.FETCH_BYTES"
    const val EXTRA_FETCH_BODY = "app.anemia.extra.FETCH_BODY"
    const val EXTRA_FETCH_ERROR = "app.anemia.extra.FETCH_ERROR"

    private const val CHANNEL_ID = "tunnel"
    private const val NOTIFICATION_ID = 1

    fun start(service: Service, session: String) {
        val manager = service.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Туннель", NotificationManager.IMPORTANCE_LOW)
                .apply { description = "Состояние и трафик Anemia" },
        )
        // Один и тот же объект и в `notify`, и в `startForeground`: два
        // одинаковых уведомления система приняла бы как разные, а `build()` —
        // это ещё и разбор ресурса с иконкой.
        val notification = build(service, session, "подключение…")
        manager.notify(NOTIFICATION_ID, notification)
        service.startForeground(NOTIFICATION_ID, notification)
    }

    /** Обновляет уведомление и будит интерфейс (если он открыт). */
    fun publish(
        context: Context,
        session: String,
        text: String,
        tunnelUp: Boolean,
        sessionId: String?,
        healthFailures: Int? = null,
        sessionStart: Long? = null,
        upBytes: Long? = null,
        downBytes: Long? = null,
        lockdown: Boolean? = null,
    ) {
        context.getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, build(context, session, text))
        context.sendBroadcast(Intent(ACTION).apply {
            setPackage(context.packageName)
            putExtra(EXTRA_TEXT, text)
            putExtra(EXTRA_TUNNEL_UP, tunnelUp)
            putExtra(EXTRA_SESSION_ID, sessionId)
            putExtra(EXTRA_FAILED, false)
            healthFailures?.let { putExtra(EXTRA_HEALTH_FAILURES, it) }
            sessionStart?.let { putExtra(EXTRA_SESSION_START, it) }
            upBytes?.let { putExtra(EXTRA_UP_BYTES, it) }
            downBytes?.let { putExtra(EXTRA_DOWN_BYTES, it) }
            lockdown?.let { putExtra(EXTRA_LOCKDOWN, it) }
        })
    }

    /**
     * Ошибка: уведомление остаётся в шторе, но перестаёт быть foreground —
     * иначе сервис обязан жить, пока его не снимут, и «подключение…» висело бы
     * вечно. Такое уведомление можно смахнуть.
     */
    fun fail(
        service: Service,
        session: String,
        text: String,
        sessionId: String? = null,
        dropped: Boolean = false,
    ) {
        // Причина отказа должна остаться в logcat, а не только в уведомлении:
        // лестница переподключается за секунды, и без отметки в момент
        // широковещания не проверить, успел ли «Отключить» попасть в паузу.
        android.util.Log.w("Anemia", "fail: $text (dropped=$dropped, session=$sessionId)")
        service.getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, build(service, session, text, ongoing = false))
        service.stopForeground(Service.STOP_FOREGROUND_DETACH)
        // Тот же канал, что и у тиков: иначе экран остаётся с «подключение…»,
        // когда причина уже решена.
        service.sendBroadcast(Intent(ACTION).apply {
            setPackage(service.packageName)
            putExtra(EXTRA_TEXT, text)
            putExtra(EXTRA_TUNNEL_UP, false)
            // Без этих двух экран не узнает ни кто умер, ни что умер: флаг
            // отказа читается с дефолтом false, и лестница не заводилась вовсе.
            putExtra(EXTRA_SESSION_ID, sessionId)
            putExtra(EXTRA_FAILED, true)
            putExtra(EXTRA_DROPPED, dropped)
        })
    }

    fun stop(service: Service) {
        service.getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_ID)
        service.stopForeground(Service.STOP_FOREGROUND_REMOVE)
        // Экран должен узнать об этом сразу, а не через 12 с молчания: иначе
        // «подключено» переживает disconnect ещё на один тик.
        service.sendBroadcast(Intent(ACTION).apply {
            setPackage(service.packageName)
            putExtra(EXTRA_TEXT, "отключено")
            putExtra(EXTRA_TUNNEL_UP, false)
            putExtra(EXTRA_FAILED, false)
            putExtra(EXTRA_STOPPED, true)
        })
    }

    private fun build(
        context: Context,
        session: String,
        text: String,
        ongoing: Boolean = true,
    ): Notification = Notification.Builder(context, CHANNEL_ID)
        .setSmallIcon(R.drawable.ic_stat_anemia)
        .setContentTitle("Anemia: $session")
        .setContentText(text)
        .setOngoing(ongoing)
        .build()
}
