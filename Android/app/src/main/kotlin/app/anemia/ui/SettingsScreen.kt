package app.anemia.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.ScrollableTabRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import app.anemia.core.MaskingProfile
import app.anemia.core.PersistedState
import app.anemia.core.SplitTunnelParser
import app.anemia.data.ServerStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private enum class SettingsSection(val title: String) {
    General("Общие"),
    Protection("Защита"),
    Network("Сеть"),
    Diagnostics("Диагностика"),
    About("О приложении"),
}

@Composable
internal fun SettingsScreen(
    store: ServerStore,
    state: PersistedState,
    autoSwitch: Boolean,
    adBlock: Boolean,
    lockdown: Boolean?,
    connection: String,
    bypassDraft: String,
    onBypassDraft: (String) -> Unit,
    onSaveBypass: () -> Unit,
    onSaved: () -> Unit,
    onBack: () -> Unit,
    onServers: () -> Unit,
    onAutoSwitch: (Boolean) -> Unit,
    onAdBlock: (Boolean) -> Unit,
    onVpnSettings: () -> Unit,
    onApps: () -> Unit,
    onTransfer: () -> Unit,
    onLeaks: () -> Unit,
) {
    val context = LocalContext.current
    var section by rememberSaveable { mutableStateOf(SettingsSection.General) }
    var logRevision by remember { mutableIntStateOf(0) }
    var notice by remember { mutableStateOf<String?>(null) }
    val showReport = section == SettingsSection.Diagnostics || section == SettingsSection.About
    var reportResult by remember { mutableStateOf<Result<DiagnosticsReport>?>(null) }
    LaunchedEffect(showReport, logRevision) {
        reportResult = if (showReport) withContext(Dispatchers.IO) {
            runCatching { DiagnosticsReport.read(context.applicationContext) }
        } else null
    }
    val report = reportResult?.getOrNull()
    val colors = MaterialTheme.colorScheme

    Column(Modifier.fillMaxSize().safeDrawingPadding().imePadding().padding(horizontal = 16.dp)) {
        ManagementHeader("Настройки", onBack)
        ScrollableTabRow(
            selectedTabIndex = section.ordinal,
            edgePadding = 0.dp,
            containerColor = Color.Transparent,
            contentColor = colors.onSurface,
        ) {
            SettingsSection.entries.forEach { item ->
                Tab(
                    selected = item == section,
                    onClick = { section = item; notice = null },
                    text = { Text(item.title, maxLines = 1) },
                )
            }
        }
        key(section) {
            Column(
                Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(top = 16.dp, bottom = 24.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                when (section) {
                    SettingsSection.General -> {
                        SettingsCard {
                            SettingsAction("Серверы и подписки", "Импорт, выбор сервера и обновление списков",
                                "Открыть", onServers)
                            SettingsDivider()
                            SettingsSwitch("Автообновление подписок", "Для HTTPS-подписок, пока Anemia работает",
                                state.subscriptionAutoRefresh) {
                                store.setSubscriptionAutoRefresh(it)
                                onSaved()
                            }
                        }
                        SettingsCard {
                            SettingsAction("Перенос Anemia", "Импорт и экспорт серверов и настроек",
                                "Открыть", onTransfer)
                        }
                    }
                    SettingsSection.Protection -> {
                        SettingsCard {
                            SettingsAction(
                                "Блокировка без VPN",
                                if (lockdown == true) "Включена в настройках Android"
                                else "Постоянный VPN и запрет соединений без него",
                                "Настроить", onVpnSettings,
                            )
                            SettingsDivider()
                            SettingsSwitch("Блокировка рекламы", "AdGuard DNS через туннель", adBlock, onAdBlock)
                            SettingsDivider()
                            MaskingSetting(state.maskingProfile) {
                                store.setMasking(it)
                                onSaved()
                            }
                        }
                    }
                    SettingsSection.Network -> {
                        NetworkSettings(state.splitTunnel.enabled, bypassDraft, onBypassDraft,
                            onToggle = {
                                store.setBypassEnabled(it)
                                onSaved()
                                notice = "Изменение применится при следующем подключении"
                            },
                            onSave = {
                                onSaveBypass()
                                notice = "Правила сохранены. Они применятся при следующем подключении."
                            },
                            onApps = onApps,
                        )
                        SettingsCard {
                            SettingsSwitch(
                                "Автовосстановление",
                                "Переподключаться при обрыве и менять сервер при потере связи",
                                autoSwitch, onAutoSwitch,
                            )
                        }
                    }
                    SettingsSection.Diagnostics -> {
                        SettingsCard {
                            SettingRow("Состояние VPN", connection) {}
                            SettingsDivider()
                            SettingsAction("Проверка утечек", "Выходной IP, IPv6 и DNS", "Проверить", onLeaks)
                        }
                        SettingsCard {
                            SettingsAction("Последние события движка",
                                "Сводка исключает данные серверов и содержимое журналов.",
                                "Обновить", { logRevision++ })
                            report?.recentEvents?.takeIf { it.isNotEmpty() }?.forEach { event ->
                                SettingsDivider()
                                Text(event, style = MaterialTheme.typography.bodySmall,
                                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 8.dp))
                            } ?: Text(when {
                                reportResult == null -> "Загружаем события…"
                                reportResult?.isFailure == true -> "События недоступны"
                                else -> "Событий нет"
                            }, style = MaterialTheme.typography.bodySmall,
                                color = colors.onSurfaceVariant,
                                modifier = Modifier.padding(horizontal = 14.dp, vertical = 8.dp))
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            TextButton(enabled = report != null, onClick = {
                                val text = report?.shareText(connection, lockdown) ?: return@TextButton
                                val clipboard = context.getSystemService(ClipboardManager::class.java)
                                clipboard?.setPrimaryClip(ClipData.newPlainText("Anemia", text))
                                notice = if (clipboard != null) "Отчёт скопирован" else "Буфер обмена недоступен"
                            }) { Text("Скопировать отчёт") }
                            TextButton(enabled = report != null, onClick = {
                                val text = report?.shareText(connection, lockdown) ?: return@TextButton
                                val intent = Intent(Intent.ACTION_SEND).setType("text/plain")
                                    .putExtra(Intent.EXTRA_SUBJECT, "Диагностика Anemia")
                                    .putExtra(Intent.EXTRA_TEXT, text)
                                context.startActivity(Intent.createChooser(intent, "Поделиться отчётом"))
                            }) { Text("Поделиться") }
                        }
                    }
                    SettingsSection.About -> SettingsCard {
                        SettingRow("Anemia", report?.appVersion) {}
                        SettingsDivider()
                        SettingRow("Система", report?.androidVersion) {}
                        SettingsDivider()
                        SettingRow("Движок VPN", report?.engineVersion) {}
                    }
                }
                notice?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant) }
            }
        }
    }
}

@Composable
private fun NetworkSettings(
    enabled: Boolean,
    draft: String,
    onDraft: (String) -> Unit,
    onToggle: (Boolean) -> Unit,
    onSave: () -> Unit,
    onApps: () -> Unit,
) {
    val rejected = remember(draft) { SplitTunnelParser.parse(draft).rejected }
    SettingsCard {
        SettingsSwitch("Раздельное туннелирование", "Перечисленные адреса идут мимо VPN", enabled, onToggle)
        SettingsDivider()
        Column(Modifier.padding(horizontal = 14.dp, vertical = 10.dp)) {
            OutlinedTextField(
                value = draft,
                onValueChange = onDraft,
                label = { Text("Домены, IP-адреса и сети") },
                placeholder = { Text("example.org, 192.0.2.0/24") },
                supportingText = {
                    if (rejected.isNotEmpty()) {
                        Text(rejected.joinToString("\n") { "${it.line}: ${it.reason}" })
                    }
                },
                minLines = 2,
                maxLines = 6,
                modifier = Modifier.fillMaxWidth(),
            )
            TextButton(onClick = onSave) { Text("Сохранить правила") }
        }
        SettingsDivider()
        SettingsAction("Обход по приложениям", "Выбранные приложения используют обычное соединение",
            "Выбрать", onApps)
    }
}

@Composable
private fun MaskingSetting(profile: MaskingProfile, onChange: (MaskingProfile) -> Unit) {
    var open by remember { mutableStateOf(false) }
    SettingRow("Маскирование", "Профиль для следующего подключения") {
        androidx.compose.foundation.layout.Box {
            TextButton(onClick = { open = true }) { Text(profile.title) }
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                MaskingProfile.entries.forEach { option ->
                    DropdownMenuItem(text = { Text(option.title) },
                        onClick = { open = false; onChange(option) })
                }
            }
        }
    }
}

@Composable
private fun SettingsCard(content: @Composable () -> Unit) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        color = MaterialTheme.colorScheme.surfaceContainer,
        shape = RoundedCornerShape(12.dp),
    ) {
        Column { content() }
    }
}

@Composable
private fun SettingsDivider() {
    HorizontalDivider(modifier = Modifier.padding(horizontal = 14.dp),
        color = MaterialTheme.colorScheme.outlineVariant)
}

@Composable
private fun SettingsAction(
    title: String,
    caption: String,
    label: String,
    onClick: () -> Unit,
) {
    SettingRow(title, caption) {
        TextButton(onClick = onClick) { Text(label) }
    }
}

@Composable
private fun SettingsSwitch(
    title: String,
    caption: String,
    checked: Boolean,
    onChecked: (Boolean) -> Unit,
) {
    SettingRow(title, caption) {
        Switch(checked = checked, onCheckedChange = onChecked,
            modifier = Modifier.padding(start = 8.dp))
    }
}

@Composable
private fun SettingRow(title: String, caption: String?, action: @Composable () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f).padding(end = 4.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = MaterialTheme.typography.titleSmall)
            caption?.let { Text(it, style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
        action()
    }
}
