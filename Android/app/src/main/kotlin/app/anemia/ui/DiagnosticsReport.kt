package app.anemia.ui

import android.content.Context
import android.os.Build
import app.anemia.vpn.Engine
import java.io.File
import java.io.RandomAccessFile
import java.util.Locale

internal data class DiagnosticsReport(
    val appVersion: String,
    val androidVersion: String,
    val engineVersion: String,
    val recentEvents: List<String>,
) {
    fun shareText(connection: String, lockdown: Boolean?): String = buildString {
        appendLine("Anemia $appVersion")
        appendLine(androidVersion)
        appendLine("Движок: $engineVersion")
        appendLine("VPN: $connection")
        appendLine("Блокировка без VPN: ${when (lockdown) {
            true -> "включена"
            false -> "выключена"
            null -> "статус недоступен"
        }}")
        appendLine()
        appendLine("Последние события движка")
        if (recentEvents.isEmpty()) appendLine("Нет событий.")
        else recentEvents.forEach { appendLine(it) }
    }

    companion object {
        fun read(context: Context): DiagnosticsReport {
            @Suppress("DEPRECATION")
            val info = context.packageManager.getPackageInfo(context.packageName, 0)
            val version = runCatching { Engine.version }.getOrNull()
                ?.takeIf { EngineVersion.matches(it) } ?: "недоступно"
            return DiagnosticsReport(
                appVersion = "${info.versionName ?: "—"} (${info.longVersionCode})",
                androidVersion = "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
                engineVersion = version,
                recentEvents = publicEngineEvents(context.getFileStreamPath("engine.log")),
            )
        }
    }
}

private val EngineVersion = Regex("[a-zA-Z0-9 .,()+_-]{1,150}")

internal fun publicEngineEvents(log: File): List<String> {
    if (!log.isFile) return emptyList()
    val tail = runCatching {
        RandomAccessFile(log, "r").use { reader ->
            val length = reader.length()
            val count = minOf(length, 24_576).toInt()
            reader.seek(length - count)
            ByteArray(count).also { reader.readFully(it) }.toString(Charsets.UTF_8)
        }
    }.getOrDefault("")
    // Exports fixed messages only. Engine logs can carry addresses, config values and URLs.
    return tail.lineSequence().mapNotNull(::publicEngineEvent).toList().takeLast(20)
}

private fun publicEngineEvent(line: String): String? {
    val event = line.lowercase(Locale.ROOT)
    return when {
        "[anemia] xray started" in event -> "Xray запущен"
        "[anemia] xray stopped" in event -> "Xray остановлен"
        "[anemia] amneziawg started" in event -> "AmneziaWG запущен"
        "[anemia] amneziawg stopped" in event -> "AmneziaWG остановлен"
        "[anemia] health check failed" in event -> "Проверка туннеля не прошла"
        "rebind after network change" in event -> "Не удалось перепривязать AmneziaWG после смены сети"
        "handshake did not complete" in event -> "Не завершено рукопожатие"
        "certificate" in event -> "Событие проверки сертификата"
        "timeout" in event || "deadline exceeded" in event -> "Истекло время ожидания"
        "[warning]" in event -> "Предупреждение движка"
        "[error]" in event -> "Ошибка движка"
        else -> null
    }
}
