package app.anemia.ui

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Checkbox
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import app.anemia.data.AppBypass
import app.anemia.data.SessionStarter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

/**
 * Обход VPN по приложениям — то, чего на iOS нет физически. Список строится из
 * пакетов с ленчер-иконкой, а выбранное уезжает в `Builder.addDisallowedApplication`
 * при следующем `establish()` (см. `ConfigApplier.apply`).
 */
class AppsActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                Surface(Modifier.fillMaxSize()) {
                    AppsScreen(onBack = { finish() })
                }
            }
        }
    }
}

@Composable
private fun AppsScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    var selected by remember { mutableStateOf(AppBypass.selected().toSet()) }
    var installed by remember { mutableStateOf<List<AppBypass.Entry>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var trouble by remember { mutableStateOf<String?>(null) }

    var up by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        // Список чужих пакетов — это обход ленчера по сотням записей, на
        // главной нити он стоил бы кадру с пустым экраном.
        // `runCatching` здесь не для красоты: без него отказ
        // `queryIntentActivities` оставлял экран с «собираю список приложений…»
        // навсегда, потому что `loading = false` до следующей строки не доходит.
        val found = runCatching {
            withContext(Dispatchers.IO) { AppBypass.launchable(context, context.packageName) }
        }
        installed = found.getOrDefault(emptyList())
        trouble = found.exceptionOrNull()?.let { "список приложений не собрался: ${it.message}" }
        loading = false
    }
    LaunchedEffect(Unit) {
        // Живой ли туннель нельзя прочитать один раз при открытии: лестница
        // поднимает его под уже открытым экраном, и подпись «применится при
        // следующем подключении» осталась бы правдой только на первый взгляд.
        // Это binder-вызов, поэтому и он вне главной нити.
        while (true) {
            up = withContext(Dispatchers.IO) { SessionStarter.tunnelUp(context) }
            delay(2_000)
        }
    }

    val listed = installed.map { it.pkg }.toSet()
    // Пока список не собран, «не среди установленных» — это про каждое выбранное
    // приложение: предупреждение появлялось на доли секунды и единственное, что
    // человек успевал прочитать перед выходом.
    val missing = if (loading) emptyList() else selected.filterNot { it in listed }.sorted()

    Column(
        Modifier.fillMaxSize().safeDrawingPadding().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = onBack) { Text("← Назад") }
            Text("Мимо VPN: приложения", style = MaterialTheme.typography.headlineSmall)
        }
        Text(
            when {
                loading -> "собираю список приложений…"
                else -> "Обходят туннель: " + counted(selected.size, "приложение", "приложения", "приложений")
            },
            style = MaterialTheme.typography.bodyMedium,
        )
        Text(
            "Выбранные приложения ходят в сеть напрямую, даже когда туннель поднят. " +
                if (up) "Сейчас туннель жив — список применится при следующем подключении."
                else "Применяется при подключении.",
            style = MaterialTheme.typography.bodySmall,
        )
        trouble?.let {
            Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
        }
        if (missing.isNotEmpty()) {
            Column {
                Text(
                    "Эти пакеты не среди установленных — обход к ним не применится:\n" +
                        missing.joinToString("\n"),
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = FontFamily.Monospace,
                )
            }
        }
        installed.forEach { entry ->
            val checked = entry.pkg in selected
            Row(
                Modifier.fillMaxWidth()
                    .clickable {
                        val next = if (checked) selected - entry.pkg else selected + entry.pkg
                        selected = next
                        trouble = AppBypass.set(context, next)
                    }
                    .padding(vertical = 6.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Checkbox(checked = checked, onCheckedChange = {
                    val next = if (it) selected + entry.pkg else selected - entry.pkg
                    selected = next
                    trouble = AppBypass.set(context, next)
                })
                Column(Modifier.weight(1f)) {
                    Text(entry.label, style = MaterialTheme.typography.bodyLarge)
                    Text(entry.pkg, style = MaterialTheme.typography.bodySmall)
                }
            }
        }
    }
}
