package app.anemia.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.dp
import app.anemia.data.LeakChecker
import kotlinx.coroutines.withContext
import java.util.UUID

/** Сколько ждать первый тик процесса `:vpn`: тик идёт каждые 3 с. */
private const val TICK_WAIT_MS = 4_000L

/**
 * Экран проверки утечек. Живёт отдельно от списка серверов, как `LeakCheckView`
 * на iOS: проверка ходит в сеть четыре раза и занимает десяток секунд — держать
 * из-за этого список на одном экране значило бы терять его прокрутку.
 *
 * `LeakChecker` отдаёт результат из своего потока, а Compose-state в нём нет
 * (он не знает про окно): поэтому счётчик перерисовки держит экран, а не
 * магазин. Состояние туннеля читается лениво: `TunnelLive` обновляется в тот
 * момент, когда замер запускается, а не в тот, когда экран открылся.
 */
@Composable
internal fun LeakScreen(
    checker: LeakChecker,
    tunnelUp: () -> Boolean,
    sessionId: () -> UUID?,
    onBack: () -> Unit,
) {
    val view = LocalView.current
    val context = LocalContext.current
    var revision by remember { mutableIntStateOf(0) }
    val onChanged: () -> Unit = { view.post { revision++ } }
    DisposableEffect(checker) {
        // Ушедший экран не должен оставлять висящие ходы и запрос сети.
        onDispose { checker.cancel() }
    }
    LaunchedEffect(Unit) {
        val opened = System.currentTimeMillis()
        // Первый тик может догонять экран: без ожидания проверка успевала
        // объявить «VPN выключен» над уже поднятым туннелем (замерено).
        while (TunnelLive.at < opened && System.currentTimeMillis() - opened < TICK_WAIT_MS) {
            kotlinx.coroutines.delay(200)
        }
        // `tunnelUp` — binder-вызов к `ActivityManager` и перечисление
        // интерфейсов; `LaunchedEffect` исполняется на нити композиции, а
        // экран открывается ровно тогда, когда туннель только что сменил
        // состояние.
        val (up, id) = withContext(kotlinx.coroutines.Dispatchers.IO) { tunnelUp() to sessionId() }
        if (!checker.isCurrent(up, id)) checker.run(context, up, id, onChanged)
        view.post { revision++ }
    }
    Column(
        Modifier.fillMaxSize().safeDrawingPadding().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        TextButton(onClick = onBack) { Text("← Назад") }
        Text("Проверка утечек", style = MaterialTheme.typography.headlineSmall)
        LeakSection(checker, revision) { checker.run(context, tunnelUp(), sessionId(), onChanged) }
    }
}
