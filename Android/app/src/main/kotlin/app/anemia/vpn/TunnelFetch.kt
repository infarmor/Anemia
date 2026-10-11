package app.anemia.vpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import androidx.core.content.ContextCompat
import app.anemia.core.Json
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/**
 * Просьба к процессу туннеля сходить по URL *через туннель* и вернуть ответ.
 *
 * Отдельный файл и функция с контекстом в аргументах — не аккуратность:
 * `LeakChecker` живёт в синглтоне на процесс, а держать `Context` в статичном
 * поле нельзя (lint ловит это как утечку, и он прав: переживает активити).
 * Здесь контекст передаётся на вызов.
 *
 * Зачем вообще нужно: сокет самого приложения идёт мимо VPN — `ConfigApplier`
 * выносит его UID (`addDisallowedApplication`), а привязаться к сети туннеля
 * система отказывается (замерено: `Binding socket to network N failed: EPERM`,
 * и с `allNetworks`, и с живой заявкой). Смотреть, «что видят сайты», может
 * только тот, кто трафик и выносит — Go-движок.
 */
private val fetchSequence = AtomicLong(0)

/** ms=0, bytes=0, body="", error=null — движок не ответил; error — ответ был, но плохой. */
data class TunnelAnswer(val ms: Long, val bytes: Long, val body: String, val error: String?)

fun engineFetch(context: Context, url: String, timeoutMs: Int = 12_000, maxBytes: Int = 16 * 1024): TunnelAnswer? {
    val id = fetchSequence.incrementAndGet()
    val latch = CountDownLatch(1)
    val answer = AtomicReference<TunnelAnswer?>()
    val receiver = object : BroadcastReceiver() {
        override fun onReceive(sender: Context?, message: Intent?) {
            if (message?.getLongExtra(StatusChannel.EXTRA_FETCH_ID, -1L) != id) return
            val body = message.getStringExtra(StatusChannel.EXTRA_FETCH_BODY)
            val error = message.getStringExtra(StatusChannel.EXTRA_FETCH_ERROR)
            // `hasExtra`, а не «пусто»: отсутствие поля значит, что движок не
            // ответил вовсе, а пустое тело — что ответил пустой страницей.
            if (error == null && body == null) return
            answer.set(
                TunnelAnswer(
                    ms = message.getLongExtra(StatusChannel.EXTRA_FETCH_MS, 0L),
                    bytes = message.getLongExtra(StatusChannel.EXTRA_FETCH_BYTES, 0L),
                    body = body ?: "",
                    error = error,
                ),
            )
            latch.countDown()
        }
    }
    ContextCompat.registerReceiver(
        context, receiver, IntentFilter(StatusChannel.ACTION_FETCH_REPLY),
        ContextCompat.RECEIVER_NOT_EXPORTED,
    )
    return try {
        // Обычный `startService`, не foreground: запрос к уже поднятому туннелю
        // не должен вешать на сервис обязательство уведомления.
        context.startService(
            Intent(context, AnemiaVpnService::class.java)
                .setAction(AnemiaVpnService.ACTION_FETCH)
                .putExtra(StatusChannel.EXTRA_FETCH_ID, id)
                .putExtra(StatusChannel.EXTRA_FETCH_URL, url)
                .putExtra(StatusChannel.EXTRA_FETCH_TIMEOUT_MS, timeoutMs)
                .putExtra(StatusChannel.EXTRA_FETCH_MAX_BYTES, maxBytes),
        )
        // Ответ обязан успеть: сам ход ограничен `timeoutMs` внутри движка,
        // здесь — с запасом на переключение процессов.
        if (!latch.await(timeoutMs.toLong() + REPLY_GRACE_MS, TimeUnit.MILLISECONDS)) {
            android.util.Log.w("Anemia", "процесс туннеля не ответил на fetch за ${timeoutMs + REPLY_GRACE_MS} мс")
            return null
        }
        answer.get()
    } finally {
        runCatching { context.unregisterReceiver(receiver) }
    }
}


/** Запас на дорогу ответа между процессами. */
private const val REPLY_GRACE_MS = 3_000L
