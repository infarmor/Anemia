package app.anemia.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import app.anemia.core.Formatting
import app.anemia.data.SpeedTest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Замер скорости: фаза, живой курс, результат и прошлые замеры — нижняя секция
 * `StatsView` на iOS, с теми же словами о расходе трафика.
 *
 * `revision` — номер перерисовки, который поднимает экран, когда `SpeedTest`
 * сообщает о новом шаге: его поля живут в рабочем потоке замера и Compose о них
 * сам не узнаёт.
 */
@Composable
internal fun SpeedSection(
    speed: SpeedTest,
    revision: Int,
    onStart: () -> Unit,
    onStop: () -> Unit,
) {
    val state = remember(revision) {
        View(
            running = speed.isRunning,
            phase = speed.phase,
            live = speed.live,
            latency = speed.latency,
            download = speed.download,
            upload = speed.upload,
            failure = speed.failure,
            history = speed.history,
        )
    }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Скорость", Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
            if (state.running) {
                OutlinedButton(onClick = onStop) { Text("Остановить") }
            } else {
                OutlinedButton(onClick = onStart) {
                    Text(if (state.phase == SpeedTest.Phase.DONE) "Ещё раз" else "Начать")
                }
            }
        }
        Text(
            when {
                state.phase == SpeedTest.Phase.LATENCY -> "Проверяю задержку…"
                state.phase == SpeedTest.Phase.DOWNLOAD -> "Приём · ${Formatting.speed(state.live)}"
                state.phase == SpeedTest.Phase.UPLOAD -> "Отдача · ${Formatting.speed(state.live)}"
                state.phase == SpeedTest.Phase.FAILED -> state.failure ?: "Замер не удался"
                state.download == null -> "Не замерено"
                else -> "Готово"
            },
            style = MaterialTheme.typography.titleMedium,
            fontFamily = FontFamily.Monospace,
        )
        Row(Modifier.fillMaxWidth().padding(vertical = 2.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Metric("задержка", state.latency?.let { "$it мс" }, state.running)
            Metric("приём", state.download?.let { Formatting.speed(it) }, state.running)
            Metric("отдача", state.upload?.let { Formatting.speed(it) }, state.running)
        }
        Text(
            "Замер идёт через серверы Cloudflare, до 10 секунд в каждую сторону, и расходует " +
                "не больше 225 МБ трафика.",
            style = MaterialTheme.typography.bodySmall,
        )
        if (state.history.isNotEmpty()) {
            Text("Прошлые замеры", style = MaterialTheme.typography.labelLarge)
            state.history.forEach { result ->
                Row(Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
                    Column(Modifier.weight(1f)) {
                        Text(result.server ?: "Без VPN", style = MaterialTheme.typography.bodyMedium)
                        Text(DATE.format(Date(result.at)), style = MaterialTheme.typography.bodySmall)
                    }
                    Text(
                        buildString {
                            result.latency?.let { append("$it мс · ") }
                            append("↓ ${Formatting.speed(result.download)}")
                            result.upload?.let { append(" · ↑ ${Formatting.speed(it)}") }
                        },
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace,
                    )
                }
            }
        }
    }
}

/** Снимок состояния замера, чтобы секция рисовала один миг, а не девять полей из двух потоков. */
private class View(
    val running: Boolean,
    val phase: SpeedTest.Phase,
    val live: Double,
    val latency: Int?,
    val download: Double?,
    val upload: Double?,
    val failure: String?,
    val history: List<SpeedTest.Result>,
)

@Composable
private fun Metric(title: String, value: String?, active: Boolean) {
    Column {
        Text(title, style = MaterialTheme.typography.labelSmall)
        Text(
            if (active && value == null) "…" else (value ?: "—"),
            style = MaterialTheme.typography.bodyMedium,
            fontFamily = FontFamily.Monospace,
        )
    }
}

private val DATE = SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.ROOT)
