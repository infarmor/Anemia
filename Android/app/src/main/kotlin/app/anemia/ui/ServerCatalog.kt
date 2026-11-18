package app.anemia.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.anemia.core.Country
import app.anemia.core.Formatting
import app.anemia.core.MaskingProfile
import app.anemia.core.ProxyServer
import app.anemia.core.Subscription
import app.anemia.core.SubscriptionInfo
import app.anemia.data.ProbeStore
import app.anemia.data.ServerStore
import app.anemia.data.ServerTrafficCheck
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun ServerCatalog(
    store: ServerStore,
    probes: ProbeStore,
    revision: Int,
    selected: UUID?,
    active: UUID?,
    best: UUID?,
    connecting: Boolean,
    notice: String?,
    busy: UUID?,
    draft: String,
    incoming: String?,
    subscriptionUrl: String,
    onDraft: (String) -> Unit,
    onSubscriptionUrl: (String) -> Unit,
    onBack: () -> Unit,
    onMeasure: () -> Unit,
    onFastest: () -> Unit,
    onSelect: (ProxyServer) -> Unit,
    onConnect: (ProxyServer) -> Unit,
    onRemoveServer: (UUID) -> Unit,
    onRefreshAll: () -> Unit,
    onRefresh: (UUID) -> Unit,
    onRemoveSubscription: (UUID) -> Unit,
    onAddSubscription: () -> Unit,
    onImport: () -> Boolean,
) {
    var query by rememberSaveable { mutableStateOf("") }
    var add by rememberSaveable { mutableStateOf(draft.isNotBlank()) }
    var addSubscription by rememberSaveable { mutableStateOf(false) }
    var addingSubscription by remember { mutableStateOf(false) }
    var removal by remember { mutableStateOf<Pair<String, () -> Unit>?>(null) }
    val checkScope = rememberCoroutineScope()
    var trafficJob by remember { mutableStateOf<Job?>(null) }
    var checked by remember { mutableIntStateOf(0) }
    var checkTotal by remember { mutableIntStateOf(0) }
    var checkNotice by remember { mutableStateOf<String?>(null) }
    val verdicts = remember { mutableStateMapOf<TrafficCheckKey, ServerTrafficCheck.Verdict>() }
    val search = query.trim()
    val snapshot = remember(revision) { store.state }
    val hasServers = remember(snapshot) { snapshot.allServers.isNotEmpty() }
    val checkCandidates = remember(snapshot) { snapshot.allServers.filter { ServerTrafficCheck.supports(it) } }
    val profile = snapshot.maskingProfile
    val probing = remember(revision) { probes.running }
    val manual = remember(snapshot, search) { snapshot.servers.filter { it.matches(search) } }
    val groups = remember(revision, search) {
        snapshot.subscriptions.mapNotNull { subscription ->
            val panel = store.infoOf(subscription.id)
            val name = panel?.title?.takeIf(String::isNotBlank) ?: subscription.name
            val matchesName = name.contains(search, ignoreCase = true)
            val servers = if (matchesName) subscription.servers else subscription.servers.filter { it.matches(search) }
            if (servers.isEmpty() && !matchesName) null else SubscriptionGroup(subscription, panel, name, servers)
        }
    }
    val colors = MaterialTheme.colorScheme
    LaunchedEffect(incoming) {
        if (!incoming.isNullOrBlank() && draft.isNotBlank()) {
            add = true
            addSubscription = false
        }
    }
    LaunchedEffect(busy, subscriptionUrl) {
        if (addingSubscription && busy == null) {
            addingSubscription = false
            if (subscriptionUrl.isBlank()) add = false
        }
    }
    LaunchedEffect(profile) {
        trafficJob?.cancel()
        checkNotice = null
    }

    fun toggleTrafficCheck() {
        trafficJob?.let { it.cancel(); return }
        if (checkCandidates.isEmpty()) return
        checked = 0
        checkTotal = checkCandidates.size
        checkNotice = null
        checkCandidates.forEach { verdicts.remove(TrafficCheckKey(it.copy(name = ""), profile)) }
        val job = checkScope.launch(start = CoroutineStart.LAZY) {
            try {
                ServerTrafficCheck.check(checkCandidates, profile) { server, verdict ->
                    verdicts[TrafficCheckKey(server.copy(name = ""), profile)] = verdict
                    checked++
                }
                checkNotice = "Проверено $checked из $checkTotal"
            } catch (cancelled: CancellationException) {
                checkNotice = "Проверка остановлена"
                throw cancelled
            } catch (_: Exception) {
                checkNotice = "Не удалось завершить проверку серверов"
            } finally {
                trafficJob = null
            }
        }
        trafficJob = job
        job.start()
    }

    Column(Modifier.fillMaxSize().safeDrawingPadding().imePadding().padding(horizontal = 16.dp)) {
        ManagementHeader("Серверы", onBack) {
            Button(onClick = { add = true }) { Text("Добавить") }
        }
        OutlinedTextField(
            value = query,
            onValueChange = { query = it },
            label = { Text("Название, страна или адрес") },
            singleLine = true,
            trailingIcon = if (query.isNotEmpty()) ({
                TextButton(onClick = { query = "" }, modifier = Modifier.semantics {
                    contentDescription = "Очистить поиск"
                }) { Text("×") }
            }) else null,
            modifier = Modifier.fillMaxWidth(),
        )
        FlowRow(
            Modifier.fillMaxWidth().padding(vertical = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            TextButton(enabled = hasServers && !probing, onClick = onMeasure) {
                Text(if (probing) "Замеряем…" else "Замерить")
            }
            TextButton(enabled = hasServers && !connecting && !probing,
                onClick = onFastest) { Text("Лучший") }
            TextButton(
                enabled = trafficJob != null || checkCandidates.isNotEmpty(),
                onClick = ::toggleTrafficCheck,
            ) {
                Text(if (trafficJob == null) "Проверить трафик" else "Остановить проверку")
            }
            if (snapshot.subscriptions.isNotEmpty()) {
                TextButton(enabled = busy == null, onClick = onRefreshAll) { Text("Обновить всё") }
            }
        }
        val trafficNotice = when {
            trafficJob != null -> "Проверено $checked из $checkTotal"
            hasServers && checkCandidates.isEmpty() -> "Проверка трафика недоступна для этих протоколов"
            else -> checkNotice
        }
        listOfNotNull(trafficNotice, notice).forEach {
            Text(it, modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp),
                style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant)
        }
        HorizontalDivider(color = colors.outlineVariant)
        LazyColumn(Modifier.weight(1f)) {
            if (manual.isEmpty() && groups.isEmpty()) {
                item("empty") {
                    Text(
                        if (search.isEmpty()) "Добавьте ссылку, конфигурацию или подписку."
                        else "Серверы не найдены",
                        Modifier.padding(vertical = 24.dp),
                        style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant,
                    )
                }
            }
            if (manual.isNotEmpty()) {
                item("manual") { CatalogHeading("Добавленные вручную") }
                items(manual, key = { "manual:${it.id}" }) { server ->
                    CatalogServer(server, selected, active, best, probes, revision,
                        verdicts[TrafficCheckKey(server.copy(name = ""), profile)], onSelect, onConnect) {
                        removal = server.name to { onRemoveServer(server.id) }
                    }
                }
            }
            for (group in groups) {
                val id = group.subscription.id
                item("subscription:$id") {
                    SubscriptionHeading(
                        group, busy == id, busy == null,
                        onRefresh = { onRefresh(id) },
                        onRemove = { removal = group.name to { onRemoveSubscription(id) } },
                    )
                }
                items(group.servers, key = { "$id:${it.id}" }) { server ->
                    CatalogServer(server, selected, active, best, probes, revision,
                        verdicts[TrafficCheckKey(server.copy(name = ""), profile)], onSelect, onConnect) {
                        removal = server.name to { onRemoveServer(server.id) }
                    }
                }
            }
        }
    }

    if (add) {
        AlertDialog(
            onDismissRequest = { add = false },
            title = { Text("Добавить серверы") },
            text = {
                Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        TextButton(onClick = { addSubscription = false }, enabled = addSubscription) {
                            Text("Серверы")
                        }
                        TextButton(onClick = { addSubscription = true }, enabled = !addSubscription) {
                            Text("Подписка")
                        }
                    }
                    if (addSubscription) {
                        OutlinedTextField(
                            subscriptionUrl, onSubscriptionUrl, label = { Text("URL подписки") },
                            singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                            modifier = Modifier.fillMaxWidth(),
                        )
                    } else {
                        OutlinedTextField(
                            draft, onDraft, label = { Text("Ссылки или конфигурация") },
                            minLines = 3, maxLines = 8, modifier = Modifier.fillMaxWidth(),
                        )
                    }
                    notice?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                }
            },
            confirmButton = {
                val hasInput = if (addSubscription) subscriptionUrl.isNotBlank() else draft.isNotBlank()
                Button(enabled = hasInput && busy == null, onClick = {
                    if (addSubscription) {
                        addingSubscription = true
                        onAddSubscription()
                    }
                    else if (onImport()) add = false
                }) {
                    Text(if (addingSubscription) "Добавляем…" else "Добавить")
                }
            },
            dismissButton = { TextButton(onClick = { add = false }) { Text("Закрыть") } },
        )
    }
    removal?.let { (name, remove) ->
        AlertDialog(
            onDismissRequest = { removal = null },
            title = { Text("Удалить «$name»?") },
            confirmButton = {
                TextButton(onClick = { remove(); removal = null }) { Text("Удалить", color = colors.error) }
            },
            dismissButton = { TextButton(onClick = { removal = null }) { Text("Отмена") } },
        )
    }
}

@Composable
internal fun ManagementHeader(title: String, onBack: () -> Unit, actions: @Composable () -> Unit = {}) {
    Row(
        Modifier.fillMaxWidth().padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        TextButton(onClick = onBack, modifier = Modifier.semantics { contentDescription = "Назад" }) {
            Text("←", style = MaterialTheme.typography.titleLarge)
        }
        Text(title, Modifier.weight(1f), style = MaterialTheme.typography.headlineSmall,
            fontFamily = FontFamily.Serif)
        actions()
    }
}

private data class SubscriptionGroup(
    val subscription: Subscription,
    val panel: SubscriptionInfo?,
    val name: String,
    val servers: List<ProxyServer>,
)

private data class TrafficCheckKey(val server: ProxyServer, val profile: MaskingProfile)

private fun ProxyServer.matches(query: String): Boolean =
    query.isEmpty() || name.contains(query, ignoreCase = true) ||
        address.contains(query, ignoreCase = true) || proto.raw.contains(query, ignoreCase = true) ||
        Country.code(name)?.let { Country.name(it).contains(query, ignoreCase = true) } == true

@Composable
private fun CatalogHeading(title: String, subtitle: String? = null, actions: @Composable () -> Unit = {}) {
    Row(
        Modifier.fillMaxWidth().padding(top = 12.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f).padding(start = 4.dp)) {
            Text(title, style = MaterialTheme.typography.titleSmall, maxLines = 2, overflow = TextOverflow.Ellipsis)
            subtitle?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        actions()
    }
}

@Composable
private fun SubscriptionHeading(
    group: SubscriptionGroup,
    refreshing: Boolean,
    canRefresh: Boolean,
    onRefresh: () -> Unit,
    onRemove: () -> Unit,
) {
    val subscription = group.subscription
    val details = buildString {
        append(counted(subscription.servers.size, "сервер", "сервера", "серверов"))
        if (!subscription.tlsProtected) append(" · без шифрования")
        group.panel?.remaining?.let { append(" · осталось ${Formatting.bytes(it)}") }
        val date = SimpleDateFormat("yyyy-MM-dd", Locale.ROOT)
        group.panel?.expires?.takeIf { it in 1..4_102_444_800L }?.let {
            append(" · до ${date.format(Date(it * 1000))}")
        }
        subscription.lastUpdatedEpochSeconds?.takeIf { it > 0 }?.let {
            append(" · обновлена ${date.format(Date((it * 1000).toLong()))}")
        }
    }
    CatalogHeading(group.name, if (refreshing) "Обновляем подписку…" else details) {
        CatalogMenu("Действия подписки ${group.name}") { close ->
            DropdownMenuItem(text = { Text("Обновить") }, enabled = canRefresh,
                onClick = { close(); onRefresh() })
            DropdownMenuItem(text = { Text("Удалить подписку") }, enabled = !refreshing,
                onClick = { close(); onRemove() })
        }
    }
}

@Composable
private fun CatalogServer(
    server: ProxyServer,
    selected: UUID?,
    active: UUID?,
    best: UUID?,
    probes: ProbeStore,
    revision: Int,
    trafficVerdict: ServerTrafficCheck.Verdict?,
    onSelect: (ProxyServer) -> Unit,
    onConnect: (ProxyServer) -> Unit,
    onRemove: () -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    val country = Country.code(server.name)
    val latency = remember(server.id, revision) {
        val ping = probes.pingOf(server.id)
        when {
            probes.isMeasuring(server.id) -> "…" to false
            ping != null -> "$ping мс" to false
            probes.measured(server.id) -> "Нет ответа" to true
            else -> "—" to false
        }
    }
    val badge = when (server.id) {
        active -> "Подключён"
        selected -> "Выбран"
        best -> "Лучший"
        else -> null
    }
    Column {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            Row(
                Modifier.weight(1f)
                    .clickable(role = Role.Button, onClickLabel = "Выбрать сервер") { onSelect(server) }
                    .padding(vertical = 10.dp, horizontal = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(country?.let(Country::flag) ?: "·", style = MaterialTheme.typography.titleMedium)
                Column(Modifier.weight(1f)) {
                    Text(server.name, style = MaterialTheme.typography.bodyMedium,
                        maxLines = 2, overflow = TextOverflow.Ellipsis)
                    Text("${server.proto.raw} · ${server.address}:${server.port}",
                        style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant,
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                    trafficVerdict?.let { verdict ->
                        val result = verdict.label + (verdict.latency?.let { " · $it мс" } ?: "")
                        Text(result, style = MaterialTheme.typography.bodySmall,
                            color = if (verdict.latency == null) colors.onSurfaceVariant else colors.primary)
                    }
                }
                Column(horizontalAlignment = Alignment.End) {
                    Text(
                        latency.first,
                        style = MaterialTheme.typography.bodySmall,
                        color = if (latency.second) colors.error else colors.onSurfaceVariant,
                    )
                    badge?.let { Text(it, style = MaterialTheme.typography.labelSmall, color = colors.primary) }
                }
            }
            CatalogMenu("Действия сервера ${server.name}") { close ->
                DropdownMenuItem(text = { Text("Подключить") }, onClick = { close(); onConnect(server) })
                DropdownMenuItem(text = { Text("Удалить") }, onClick = { close(); onRemove() })
            }
        }
        HorizontalDivider(color = colors.outlineVariant)
    }
}

@Composable
private fun CatalogMenu(label: String, items: @Composable (() -> Unit) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        TextButton(onClick = { open = true }, modifier = Modifier.semantics { contentDescription = label }) {
            Text("⋯", style = MaterialTheme.typography.titleMedium)
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            items { open = false }
        }
    }
}
