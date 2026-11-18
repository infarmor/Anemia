package app.anemia.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import app.anemia.core.Country
import app.anemia.core.Formatting
import app.anemia.core.TrafficLedger
import app.anemia.data.SpeedTest
import app.anemia.data.TrafficStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Трафик через туннель — порт `iOS/Anemia/StatsView.swift`: сегодня, этот
 * месяц, две недели столбиками и «кто носил».
 *
 * Файл читается, а не приходит из магазина процесса: ряд пишет `:vpn`, а здесь
 * мы только смотрим. Потолок на частоту чтения (5 с) — не экономия, а то же
 * правило, что у записи: 300 отсчётов в секунду с диска никому не нужны.
 */
@Composable
fun StatsScreen(
    file: File,
    speed: SpeedTest,
    onBack: () -> Unit,
    onReset: () -> Unit,
) {
    // Пустой снимок, а не прочитанный с диска: `traffic.json` переписывает
    // процесс туннеля, и разбор его на главной нити ровно в первый кадр — то
    // самое, что запрещает цикл ниже. Через полсекунды `LaunchedEffect`
    // догонит настоящие цифры.
    var snapshot by remember { mutableStateOf(TrafficStore.snapshot(TrafficLedger())) }
    var confirming by remember { mutableStateOf(false) }
    var speedPage by rememberSaveable { mutableStateOf(false) }
    // Номер перерисовки для замера: его состояние живёт в рабочем потоке, и
    // Compose о нём сам не узнаёт.
    var revision by remember { mutableIntStateOf(0) }
    val view = LocalView.current
    DisposableEffect(speed) {
        // Ушли с экрана — замер остановлен: без этого он досчитал бы до
        // бюджета в 225 МБ трафика, которого никто не видит.
        onDispose { speed.stop() }
    }

    LaunchedEffect(file) {
        while (true) {
            // Чтение — вне композиции: файл переписывает другой процесс, и
            // разбор его на главном нити был бы ANR-окном раз в пять секунд.
            snapshot = withContext(Dispatchers.IO) { TrafficStore.snapshot(file) }
            delay(READ_MS)
        }
    }

    Column(
        Modifier.fillMaxSize().safeDrawingPadding().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = onBack) { Text("← Назад") }
            Text("Статистика", style = MaterialTheme.typography.headlineSmall)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FilterChip(selected = !speedPage, onClick = { speedPage = false }, label = { Text("Трафик") })
            FilterChip(selected = speedPage, onClick = { speedPage = true }, label = { Text("Скорость") })
        }
        if (speedPage) {
            SpeedSection(
                speed = speed,
                revision = revision,
                onStart = { speed.start { view.post { revision++ } } },
                onStop = { speed.stop(); view.post { revision++ } },
            )
            return@Column
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Summary("Сегодня", snapshot.today, Modifier.weight(1f))
            Summary("Этот месяц", snapshot.month, Modifier.weight(1f))
        }
        Column {
            Text("Две недели", style = MaterialTheme.typography.titleSmall)
            Days(snapshot.days)
            Text(
                "Считается только то, что прошло через туннель, пока процесс туннеля жив: " +
                    "ряды пишет `:vpn`, и без поднятого соединения они не растут.",
                style = MaterialTheme.typography.bodySmall,
            )
        }
        if (snapshot.top.isNotEmpty()) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Серверы", style = MaterialTheme.typography.titleSmall)
                snapshot.top.forEach { server ->
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        val code = Country.code(server.name)
                        Text(
                            if (code != null) Country.flag(code) else "·",
                            style = MaterialTheme.typography.bodyMedium,
                        )
                        Column(Modifier.weight(1f)) {
                            Text(server.name, style = MaterialTheme.typography.bodyMedium)
                            Text(
                                "↓ ${Formatting.bytes(server.received)} · ↑ ${Formatting.bytes(server.sent)}",
                                style = MaterialTheme.typography.bodySmall,
                                fontFamily = FontFamily.Monospace,
                            )
                        }
                        Text(
                            Formatting.bytes(server.total),
                            style = MaterialTheme.typography.bodyMedium,
                            fontFamily = FontFamily.Monospace,
                        )
                    }
                }
            }
        }
        OutlinedButton(onClick = { confirming = true }) { Text("Сбросить статистику") }
    }

    if (confirming) {
        AlertDialog(
            onDismissRequest = { confirming = false },
            title = { Text("Сбросить всю статистику трафика?") },
            confirmButton = {
                TextButton(onClick = {
                    confirming = false
                    onReset()
                }) { Text("Сбросить") }
            },
            dismissButton = {
                TextButton(onClick = { confirming = false }) { Text("Отмена") }
            },
        )
    }
}

@Composable
private fun Summary(title: String, day: TrafficLedger.Day, modifier: Modifier = Modifier) {
    Column(modifier) {
        Text(title, style = MaterialTheme.typography.labelMedium)
        Text(Formatting.bytes(day.total), style = MaterialTheme.typography.headlineMedium)
        Text(
            "↓ ${Formatting.bytes(day.received)} · ↑ ${Formatting.bytes(day.sent)}",
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
        )
        // Тот же порог, что у iOS: минуты счётчика интересны, когда их видно.
        if (day.time >= 60) Text("в сети ${Formatting.sessionLength(day.time)}",
            style = MaterialTheme.typography.bodySmall)
    }
}

/**
 * Столбики за 14 дней. Даты подписываются числом из самого ключа ряда
 * (`2026-09-27` → `27.09`), а не через `SimpleDateFormat`: названия месяцев
 * между CLDR Apple и CLDR JVM расходятся, и сверять из-за подписи оси то, что
 * и так известно, — только плодить расхождения.
 */
@Composable
private fun Days(days: List<TrafficLedger.Day>) {
    val down = MaterialTheme.colorScheme.primary
    val up = MaterialTheme.colorScheme.outline
    val peak = days.maxOf { it.total }.coerceAtLeast(1)
    Column {
        Canvas(Modifier.fillMaxWidth().height(140.dp)) {
            val slot = size.width / days.size
            val bar = slot * 0.32f
            days.forEachIndexed { index, day ->
                val left = index * slot + slot * 0.12f
                val hDown = size.height * (day.received.toFloat() / peak)
                val hUp = size.height * (day.sent.toFloat() / peak)
                drawRoundRect(
                    down, Offset(left, size.height - hDown), Size(bar, hDown),
                    CornerRadius(2f, 2f),
                )
                drawRoundRect(
                    up, Offset(left + bar + slot * 0.06f, size.height - hUp), Size(bar, hUp),
                    CornerRadius(2f, 2f),
                )
            }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            days.firstOrNull()?.let { Text(dayLabel(it.id), style = MaterialTheme.typography.labelSmall) }
            Text(
                "максимум ${Formatting.bytes(peak)}",
                style = MaterialTheme.typography.labelSmall,
                color = Color.Gray,
            )
            days.lastOrNull()?.let { Text(dayLabel(it.id), style = MaterialTheme.typography.labelSmall) }
        }
    }
}

private fun dayLabel(key: String): String =
    if (key.length == 10) "${key.substring(8)}.${key.substring(5, 7)}" else key

private const val READ_MS = 5_000L
