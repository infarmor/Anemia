package app.anemia.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.Dispatchers
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import app.anemia.core.SyncBundle
import app.anemia.data.Qr
import app.anemia.data.ServerStore
import app.anemia.data.SyncTransfer
import kotlin.concurrent.thread

/**
 * Перенос на другое устройство — порт `iOS/Anemia/Transfer.swift`. Открывается
 * из долгого нажатия на значок (App Shortcuts), из чужого файла `.anemia`, по
 * ссылке `anemia://sync/…` и из плитки-ярлыка.
 *
 * Отдельная активность, а не ещё одна секция экрана: экран в этом проходе
 * правит другой, и втиснуть сюда кнопку — значит столкнуть два прохода в одном
 * файле.
 */
class TransferActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                Surface(Modifier.fillMaxSize()) {
                    val app = applicationContext
                    // Принесённый файл читается вне главной нити: `onCreate`
                    // вызывается ещё до первого кадра, а «Поделиться» может
                    // прислать файл переноса в несколько мегабайт (потолок мы
                    // держим, но и под него читать диск на главной — тот же
                    // грех, что в остальных экранах).
                    var received by remember { mutableStateOf<Received?>(null) }
                    LaunchedEffect(Unit) {
                        received = withContext(Dispatchers.IO) { receivedOf(app, intent) }
                    }
                    val ready = received
                    if (ready == null) {
                        Text(
                            "читаю принятые данные…",
                            Modifier.padding(16.dp),
                            style = MaterialTheme.typography.bodyMedium,
                        )
                    } else {
                        TransferScreen(sharedStore(app), ready, onBack = { finish() })
                    }
                }
            }
        }
    }
}

/** Что принёс интент: бандль на разбор, текст отказа или ничего. */
internal class Received(val bundle: SyncBundle?, val reason: String?)

private fun receivedOf(context: Context, intent: Intent?): Received {
    val text = when (intent?.action) {
        Intent.ACTION_VIEW -> intent.dataString
        Intent.ACTION_SEND -> intent.getStringExtra(Intent.EXTRA_TEXT)
            ?: intent.getParcelableExtra<android.net.Uri>(Intent.EXTRA_STREAM)?.let {
                // `null` здесь — это «не открылся» или «больше потолка»; и то,
                // и другое надо сказать, иначе экран выглядит как обычный экспорт.
                SyncTransfer.textOf(context, it)
                    ?: return Received(null, "принятый файл не прочитался или слишком велик")
            }
        else -> null
    } ?: return Received(null, null)
    // «Не похоже на перенос» обязано быть сказано словами: иначе экран
    // молча выглядит как обычный экспорт, и человек не понимает, что ему
    // прислали не файл переноса (или тот оказался больше потолка).
    if (!SyncBundle.looksLikeBundle(text)) {
        return Received(null, "принесённое не похоже на файл переноса Anemia")
    }
    return runCatching { SyncTransfer.incoming(text) }
        .fold(
            onSuccess = { Received(it, null) },
            onFailure = { Received(null, SyncTransfer.failure(it)) },
        )
}

@Composable
private fun TransferScreen(store: ServerStore, received: Received, onBack: () -> Unit) {
    val context = LocalContext.current
    val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    var notice by remember { mutableStateOf<String?>(null) }
    var draft by remember { mutableStateOf("") }
    var pending by remember { mutableStateOf(received.bundle) }
    var working by remember { mutableStateOf(false) }

    val view = LocalView.current
    val scope = rememberCoroutineScope()
    var revision by remember { mutableIntStateOf(0) }
    DisposableEffect(store) {
        // Магазин — не Compose-состояние: без подписки экран держал бы бандль,
        // собранный при открытии. А этот экран сам же и догружает подписки
        // (`store.refresh`), и принимает перенос — ссылка, QR и «Сохранить
        // файлом» молча расходились бы с тем, что действительно на телефоне.
        val stop = store.observeChanges { view.post { revision++ } }
        onDispose { stop() }
    }

    val bundle = remember(revision) {
        SyncTransfer.bundle(store.state, prefs.getBoolean(PREF_ADBLOCK, false))
    }
    // Ссылка и картинка помнятся тем, что из них рождается: без `remember`
    // каждое слово в поле «Принять» пересобирало бандль (`deflate` + base64 по
    // всему состоянию) и заново разворачивало матрицу QR в bitmap — при сотнях
    // серверов это мегабайты на кадр.
    val link = remember(bundle) { runCatching { bundle.link() }.getOrNull() }
    val qr = remember(link) { link?.let { Qr.matrix(it) } }

    val save = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument(MIME)) { uri ->
        notice = uri?.let { SyncTransfer.write(context, it, bundle) ?: "файл записан" } ?: "файл не выбран"
    }
    val open = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        val text = uri?.let { SyncTransfer.textOf(context, it) }
        when {
            text == null -> notice = "файл не прочитался"
            !SyncBundle.looksLikeBundle(text) -> notice = "это не файл переноса"
            else -> runCatching { SyncTransfer.incoming(text) }.fold(
                onSuccess = { found ->
                    pending = found
                    notice = if (found == null) "это не файл переноса" else null
                },
                onFailure = { notice = SyncTransfer.failure(it) },
            )
        }
    }

    Column(
        Modifier.fillMaxSize().safeDrawingPadding().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            TextButton(onClick = onBack) { Text("← Назад") }
            Text("Перенос на другое устройство", style = MaterialTheme.typography.headlineSmall)
        }
        if (received.reason != null) {
            Text(received.reason, style = MaterialTheme.typography.bodySmall,
                fontFamily = FontFamily.Monospace)
        }
        Text(
            "${counted(bundle.servers.size, "сервер", "сервера", "серверов")} · " +
                counted(bundle.subscriptions.size, "подписка", "подписки", "подписок") + " · настройки",
            style = MaterialTheme.typography.bodySmall,
        )
        Text(
            "Серверы, подписки и настройки — для Anemia на Mac или другом телефоне. " +
                "В файле приватные ключи серверов: не публикуйте его.",
            style = MaterialTheme.typography.bodySmall,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlinedButton(onClick = { save.launch("Anemia.anemia") }) { Text("Сохранить файлом") }
            OutlinedButton(onClick = {
                val uri = SyncTransfer.shareFile(context, bundle)
                notice = if (uri == null) "файл для отправки не получился" else {
                    context.startActivity(
                        Intent.createChooser(
                            Intent(Intent.ACTION_SEND)
                                .setType(MIME)
                                .putExtra(Intent.EXTRA_STREAM, uri)
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
                            "Отправить серверы Anemia",
                        ),
                    )
                    "открываю список приложений"
                }
            }) { Text("Отправить") }
            OutlinedButton(
                enabled = link != null,
                onClick = {
                    val manager = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    manager.setPrimaryClip(ClipData.newPlainText("Anemia", link))
                    notice = "ссылка скопирована"
                },
            ) { Text("Скопировать ссылку") }
        }
        val code = remember(qr) { qr?.let { bitmapOf(it) } }
        if (code != null) {
            Image(
                bitmap = code,
                contentDescription = "QR-код переноса",
                modifier = Modifier.size(280.dp),
                contentScale = ContentScale.Fit,
                filterQuality = FilterQuality.None,
            )
            Text(
                "Откройте Anemia на другом устройстве: «Перенос → Принять» и вставьте ссылку " +
                    "или прочитайте файл. Камерой код здесь пока не читается.",
                style = MaterialTheme.typography.bodySmall,
            )
        } else {
            Text("Не помещается в QR-код", style = MaterialTheme.typography.titleSmall)
            Text(
                "Серверов слишком много. Отправьте их файлом — «Отправить» или «Сохранить файлом».",
                style = MaterialTheme.typography.bodySmall,
            )
        }

        OutlinedTextField(
            value = draft,
            onValueChange = { draft = it },
            label = { Text("Принять: ссылка anemia://sync/… или JSON файла") },
            minLines = 2,
            modifier = Modifier.fillMaxWidth(),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            TextButton(onClick = {
                runCatching { SyncTransfer.incoming(draft) }.fold(
                    onSuccess = { found ->
                        pending = found
                        notice = if (found == null) "это не перенос" else null
                    },
                    onFailure = { notice = SyncTransfer.failure(it) },
                )
            }) { Text("Разобрать") }
            TextButton(onClick = { open.launch(arrayOf(MIME)) }) { Text("Выбрать файл…") }
        }
        notice?.let { Text(it, style = MaterialTheme.typography.bodySmall) }

        pending?.let { received ->
            ImportCard(
                store = store,
                bundle = received,
                working = working,
                onDismiss = { pending = null },
                onAccept = { applySettings ->
                    working = true
                    // Отмена после того, как слилось: состояние уже записано, и
                    // откатывать его молча нельзя — поэтому «Добавить» остаётся
                    // одной операцией, а не задачей, которую снимают.
                    scope.launch {
                        val outcome = runCatching {
                            // Слияние с записью `state.json` — вне главной нити:
                            // после переноса состоянием бывают сотни серверов, а
                            // здесь оно ещё и пишется. Пока это делалось прямо в
                            // колбэке, `working` не успевал отрисоваться ни разу,
                            // а отказ бросал исключение из композиции.
                            withContext(Dispatchers.IO) { store.applySync(received, applySettings) }
                        }
                        working = false
                        val summary = outcome.getOrNull()
                        if (summary == null) {
                            // Карточка закрывается, причина остаётся: иначе
                            // экран стоял бы с неактивными кнопками над
                            // непринятым переносом.
                            pending = null
                            notice = "перенос не применился: " +
                                (outcome.exceptionOrNull()?.message ?: "неизвестная причина")
                            return@launch
                        }
                        if (applySettings) {
                            received.settings?.adBlock?.let {
                                prefs.edit().putBoolean(PREF_ADBLOCK, it).apply()
                            }
                        }
                        val urls = summary.newSubscriptions.map { SyncTransfer.normalized(it.url) }.toSet()
                        val ids = store.subscriptionIdsFor(urls)
                        pending = null
                        notice = "добавлено " +
                            counted(summary.addedServers, "сервер", "сервера", "серверов") + ", уже было " +
                            counted(summary.knownServers, "сервер", "сервера", "серверов") +
                            if (applySettings && received.settings != null) ", настройки взяты" else ""
                        // Панели грузятся уже после сохранения: одна из них может
                        // держать соединение 30 с, и вешать на неё шторку после
                        // «Добавить» — значит показывать спиннер над записанными
                        // данными. Тот же смысл, что на iOS.
                        if (ids.isNotEmpty()) thread(start = true, isDaemon = true) {
                            for (id in ids) store.refresh(id)
                        }
                    }
                },
            )
        }
    }
}

@Composable
private fun ImportCard(
    store: ServerStore,
    bundle: SyncBundle,
    working: Boolean,
    onDismiss: () -> Unit,
    onAccept: (Boolean) -> Unit,
) {
    var applySettings by remember { mutableStateOf(true) }
    val withSettings = applySettings && bundle.settings != null
    val preview = bundle.preview(store.state, withSettings)
    Column(
        Modifier.fillMaxWidth().padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text("Перенос", style = MaterialTheme.typography.titleMedium)
        Text("Откуда: ${bundle.device}", style = MaterialTheme.typography.bodySmall)
        Text(
            "Новых серверов: ${preview.addedServers} · уже есть: ${preview.knownServers}",
            style = MaterialTheme.typography.bodySmall,
        )
        Text(
            "Новых подписок: ${preview.newSubscriptions.size} · уже есть: ${preview.knownSubscriptions}",
            style = MaterialTheme.typography.bodySmall,
        )
        if (bundle.settings != null) {
            TextButton(onClick = { applySettings = !applySettings }) {
                Text(if (applySettings) "Настройки: взять (маскировка, «Мимо VPN», выученное)"
                     else "Настройки: оставить свои")
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            TextButton(
                enabled = !working && !preview.addsNothing,
                onClick = { onAccept(withSettings) },
            ) { Text(if (working) "…" else "Добавить") }
            TextButton(enabled = !working, onClick = onDismiss) { Text("Отмена") }
        }
        Text(
            "Серверы, которые уже есть (тот же адрес и ключ), не дублируются. Подписки " +
                "загрузятся заново на этом устройстве.",
            style = MaterialTheme.typography.bodySmall,
        )
    }
}

/**
 * Матрица в растр. Белый фон обязателен: сканер читает контраст, а прозрачный
 * фон поверх тёмной темы дал бы код, который нечем прочитать.
 *
 * `setPixels` — аргументы в порядке `colors, offset, stride, x, y, width,
 * height`: перепутанные оси рисуют белый квадрат вместо кода, и на экране это
 * заметно только когда код действительно сканируют.
 */
private fun bitmapOf(matrix: Array<BooleanArray>): ImageBitmap {
    val (pixels, width) = Qr.pixels(matrix)
    val height = pixels.size / width
    return Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        .apply { setPixels(pixels, 0, width, 0, 0, width, height) }
        .asImageBitmap()
}

private const val PREFS = "anemia"
private const val PREF_ADBLOCK = "adBlock"
private const val MIME = "application/octet-stream"
