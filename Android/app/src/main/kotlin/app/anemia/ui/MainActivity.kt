package app.anemia.ui

import android.Manifest
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import app.anemia.core.Country
import app.anemia.core.Formatting
import app.anemia.core.MaskingProfile
import app.anemia.core.ProxyServer
import app.anemia.core.AutoSwitchPolicy
import app.anemia.core.SplitTunnelParser
import app.anemia.core.StatePersistence
import app.anemia.data.TrafficStore
import app.anemia.data.PanelStore
import app.anemia.data.ProbeHistory
import app.anemia.data.ProbeStore
import app.anemia.data.Recovery
import app.anemia.data.AutoSwitchFlow
import app.anemia.data.ServerStore
import app.anemia.data.SessionStarter
import app.anemia.data.LeakChecker
import app.anemia.data.SpeedTest
import app.anemia.data.SpeedTester
import app.anemia.data.TunnelSetup
import app.anemia.core.Subscription
import app.anemia.vpn.AnemiaVpnService
import app.anemia.vpn.StatusChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.concurrent.thread

/**
 * Экран подключения: список серверов, подписки, обход, статус. Аналог
 * `ServersView` + `RootView`, сжатый до одного экрана — карта, диагностика и
 * рейтинг на Android ещё не перенесены.
 *
 * Состояние туннеля здесь не хранится: раз в три секунды его присылает процесс
 * `:vpn` широким сообщением. Свои часы нужны ровно для одного — «нет вестей»
 * должно быть видно: OEM-убийца снимает сервис молча, и без этого последняя
 * строка счётчиков висела бы как живое подключение.
 */
class MainActivity : ComponentActivity() {
    /**
     * Отметка «за туннелем следят», раз в [WATCH_PING_MS]. Без неё `:vpn` не
     * меряет здоровье вовсе — тот же смысл, что у iOS-`wantsHealth`, где
     * расширение проверяет туннель только пока приложение его опрашивает, и та
     * же цена: запрос наружу — это DNS, TCP и TLS через выход, а не бесплатная
     * строчка в логе.
     *
     * `startService`, а не `startForegroundService`: поднимать чужой процесс
     * уведомлением ради отметки незачем, а сервис без живого туннеля сам себя
     * снимает по этому же сообщению.
     */
    private val watch = Handler(Looper.getMainLooper())
    private val watchTick = object : Runnable {
        override fun run() {
            // Источник истины для `TunnelLive` — тот же, что у плитки: процесс
            // `:vpn` И интерфейс `tunN`. Широковещание обновляет поле только
            // когда сервис жив, а значит врать оно умеет в обе стороны: молчащий
            // под OEM-убийцей сервис оставляет `up == true` навсегда, а холодный
            // старт с уже поднятым туннелем — `false` до первого тика. По
            // `up == false` замеры пишут в историю чужие отсчёты, по `up == true`
            // — не пишут ничего (правило «ряд хранит только подключённый сервер»).
            val up = SessionStarter.tunnelUp(this@MainActivity)
            if (TunnelLive.up != up) {
                TunnelLive.up = up
                if (!up) TunnelLive.sessionId = null
            }
            // Разрешение на здоровье — это та же опция, что и на iOS
            // (`tunnel.wantsHealth = { autoSwitch }`): без неё отметка «смотрю»
            // означала бы настоящий DNS+TCP+TLS через выход каждые 30 с, а
            // вердикт не читал бы никто — лестница и `AutoSwitchFlow` gated
            // тем же флагом.
            val wantsHealth = getSharedPreferences(PREFS, MODE_PRIVATE)
                .getBoolean(PREF_AUTOSWITCH, true)
            if (wantsHealth && up) {
                startService(
                    Intent(this@MainActivity, AnemiaVpnService::class.java)
                        .putExtra(AnemiaVpnService.EXTRA_WATCH, true),
                )
            }
            watch.postDelayed(this, WATCH_PING_MS)
        }
    }

    override fun onStart() {
        super.onStart()
        watch.post(watchTick)
    }

    override fun onStop() {
        // Не «подождём, пока экран вернётся»: у окна, ушедшего в фон, проверка
        // здоровья кончается через минуту — как на iOS.
        watch.removeCallbacks(watchTick)
        super.onStop()
    }

    /**
     * Получатель статуса на уровне Activity. Экран списка держит свой (он ещё и
     * ведёт лестницу восстановления), но проверка утечек живёт на другом экране,
     * и без этого `TunnelLive` обновлялся бы только на первом: открытие экрана
     * сразу после подключения давало «VPN выключен» над поднятым туннелем —
     * замерено на эмуляторе.
     */
    private val liveReceiver = object : BroadcastReceiver() {
        override fun onReceive(sender: Context?, message: Intent?) {
            TunnelLive.up = message?.getBooleanExtra(StatusChannel.EXTRA_TUNNEL_UP, false) == true
            TunnelLive.sessionId = message?.getStringExtra(StatusChannel.EXTRA_SESSION_ID)
                ?.let { runCatching { java.util.UUID.fromString(it) }.getOrNull() }
            TunnelLive.at = System.currentTimeMillis()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ContextCompat.registerReceiver(
            this, liveReceiver, IntentFilter(StatusChannel.ACTION), ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        val store = sharedStore(this)
        // Ссылка может прийти извне: `am start --es link …` или переход из
        // мессенджера. Заодно это единственный способ проверить сборку на
        // устройстве без клавиатуры.
        val incoming = intent?.getStringExtra(EXTRA_LINK)?.takeIf { it.isNotBlank() }
            ?: intent?.dataString?.takeIf { it.contains("://") }
        val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
        // Серверы-заглушки для проверки на эмуляторе (только отладочная сборка):
        // без них ни один ход утечек нельзя объяснить локальным fixture'ом.
        val leakBase = debuggableOnly(this, intent, EXTRA_LEAK_BASE)
        val leakDirectBase = debuggableOnly(this, intent, EXTRA_LEAK_DIRECT_BASE)
        val speedBase = debuggableOnly(this, intent, EXTRA_SPEED_BASE)
        val speed = sharedSpeed(this, speedBase)
        // Кто несёт байты на момент *конца* замера: туннель мог упасть в середине,
        // и тогда запись обязана сказать «Без VPN» (то же на iOS).
        // Провайдер живёт в процессном синглтоне, поэтому видит application
        // context, а не Activity: иначе первый же `onCreate` оставил бы её
        // вместе с деревом видов висеть до конца жизни процесса (а зовёт его
        // поток замера — то есть между поворотами экрана он бы ещё и менялся).
        val app = applicationContext
        speed.serverProvider = {
            val id = TunnelLive.sessionId
            val live = TunnelLive.up
            if (live && id != null) {
                sharedStore(app).servers.firstOrNull { it.id == id }?.name
            } else {
                null
            }
        }
        if (debugFlag(this, intent, EXTRA_LEAK_RUN)) {
            // Отладочный прогон без тапов: ждём первый тик сервиса (иначе
            // `TunnelLive.up` ещё false) и запускаем проверку; итог — в logcat.
            val checker = sharedLeaks(this, leakBase, leakDirectBase)
            awaitFirstTick { checker.run(this, TunnelLive.up, TunnelLive.sessionId) { } }
        }
        setContent {
            MaterialTheme {
                Surface(Modifier.fillMaxSize()) {
                    var screen by remember { mutableStateOf(Screen.Main) }
                    when (screen) {
                        Screen.Main -> Connect(
                            store, sharedProbes(this), prefs, incoming,
                            onOpen = { screen = it },
                        )
                        Screen.Stats -> StatsScreen(
                            file = File(applicationContext.filesDir, TrafficStore.FILE_NAME),
                            speed = speed,
                            onBack = { screen = Screen.Main },
                            onReset = { resetTraffic(applicationContext) },
                        )
                        Screen.Leak -> LeakScreen(
                            checker = sharedLeaks(this, leakBase, leakDirectBase),
                            // Не значения, а читалки: тик может прийти уже после
                            // того, как экран открылся, и замер обязан увидеть
                            // актуальное состояние, а не то, что было при
                            // композиции.
                            tunnelUp = { TunnelLive.up },
                            sessionId = { TunnelLive.sessionId },
                            onBack = { screen = Screen.Main },
                        )
                    }
                }
            }
        }
    }

    override fun onDestroy() {
        unregisterReceiver(liveReceiver)
        super.onDestroy()
    }

    /**
     * Первый тик сервиса приходит не сразу (тик каждые 3 с). Отладочный прогон
     * без этого ждал бы вслепую и считал, что VPN выключен.
     */
    private fun awaitFirstTick(action: () -> Unit) {
        val opened = System.currentTimeMillis()
        val handler = android.os.Handler(mainLooper)
        object : Runnable {
            override fun run() {
                if (TunnelLive.at >= opened || System.currentTimeMillis() - opened > LEAK_RUN_WAIT_MS) {
                    action()
                } else {
                    handler.postDelayed(this, 250)
                }
            }
        }.run()
    }
}

/** Экраны одного Activity: список серверов, статистика трафика и замеров, утечки. */
enum class Screen { Main, Stats, Leak }

/**
 * Сброс ряда трафика — командой процессу туннеля, всегда, даже когда
 * соединения нет: иначе у «сбросить» было бы два пути, и второй (запись файла
 * из интерфейса при живом `:vpn`) вернулся бы через полчаса старыми цифрами.
 */
internal fun resetTraffic(context: Context) {
    context.startService(
        Intent(context, AnemiaVpnService::class.java)
            .putExtra(AnemiaVpnService.EXTRA_RESET_TRAFFIC, true),
    )
}

/**
 * Что процесс туннеля сообщил о себе в последнем широковещательном сообщении.
 * Поле процесса, а не состояние композиции: после поворота экрана `remember`
 * обнуляется, а туннель-то живёт, и решение «писать эти замеры в историю или
 * нет» от этого не должно меняться.
 */
internal object TunnelLive {
    @Volatile var up = false
    @Volatile var sessionId: java.util.UUID? = null

    /**
     * Когда приходил последний тик. Экран, который открывается раньше первого
     * широковещания (проверка утечек), по `up == false` решил бы, что VPN
     * выключен, — замерено на эмуляторе.
     */
    @Volatile var at = 0L

}

/**
 * Эпизод восстановления живёт вне композиции. `remember` после поворота экрана
 * обнулился бы вместе со счётчиком попыток и уже поставленной на задержку
 * ступенькой, а в этот момент лестница — единственное, что держит соединение.
 * Отложенный шаг идёт на Main: он только просит систему поднять сервис.
 */
internal object RecoveryEpisode {
    val ladder = Recovery()

    /** Сколько тиков подряд туннель поднят внутри эпизода. Сбрасывается на
     * любом отказе и на конце эпизода. */
    var upTicks = 0

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var pending: Job? = null

    /** Новый шаг снимает предыдущий: два отложенных подъёма хуже одного. */
    fun schedule(delayMs: Long, action: () -> Unit) {
        pending?.cancel()
        upTicks = 0
        pending = scope.launch {
            delay(delayMs)
            action()
        }
    }

    /** Конец эпизода — успех или ручное нажатие: сервис не должен подняться
     * после того, как пользователь уже нажал «Отключить». */
    fun abort() {
        pending?.cancel()
        pending = null
        upTicks = 0
        ladder.reset()
    }
}

/**
 * Физический линк есть? Под собственным туннелем активной считается VPN-сеть,
 * и по ней «сеть появилась» не определить: смотрим на сети без флага VPN.
 * `NOT_VPN` тут — часть имени, а не отрицание смысла: он стоит у сетей, которые
 * VPN не являются. `allNetworks`, а не `activeNetworks`: второго в compile-stubs
 * SDK нет (проверено на 36 и 37 — `activeNetworks` не компилируется).
 */
private fun hasPhysicalLink(context: Context): Boolean {
    val manager = context.getSystemService(ConnectivityManager::class.java) ?: return true
    return manager.allNetworks.any { network ->
        val capabilities = manager.getNetworkCapabilities(network) ?: return@any false
        capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
    }
}

@Composable
private fun Connect(
    store: ServerStore,
    probes: ProbeStore,
    prefs: SharedPreferences,
    incoming: String?,
    onOpen: (Screen) -> Unit,
) {
    val context = LocalContext.current
    var revision by remember { mutableIntStateOf(0) }
    // Поля ввода переживают поворот: в `draft` человек вставляет список из
    // сорока ссылок или wg-quick конфига, и потерять его на повороте экрана
    // значит заставить набирать заново. Ключ — `incoming`: без него сохранённый
    // черновик побеждал ссылку, пришедшую из интента или файла (`am start --es
    // link …`, «Поделиться», `.anemia`), и второй конфиг просто не импортировался
    // — так показал прогон живого AWG-пира. С ключом поворот restores то, что
    // набрано, а новая ссылка открывает себе отдельное место.
    var draft by rememberSaveable(incoming) { mutableStateOf(incoming ?: "") }
    var notice by remember { mutableStateOf<String?>(null) }
    var bypass by rememberSaveable { mutableStateOf(store.state.splitTunnel.entries.joinToString("\n")) }
    var adBlock by remember { mutableStateOf(prefs.getBoolean(PREF_ADBLOCK, false)) }
    var status by remember { mutableStateOf(store.warning ?: "отключено") }
    var subscriptionUrl by rememberSaveable { mutableStateOf("") }
    var busy by remember { mutableStateOf<java.util.UUID?>(null) }
    var lastTick by remember { mutableLongStateOf(0L) }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }

    var autoSwitch by remember { mutableStateOf(prefs.getBoolean(PREF_AUTOSWITCH, true)) }
    // Флаг AdGuard принадлежит настройкам, а не этому экрану: перенос `.anemia`
    // меняет его из `TransferActivity`, пока экран лежит в стеке. Без перечитки
    // на возврате чекбокс показывал старое, и «Подключить» уносил в туннель
    // старое — тогда как плитка в тот же момент читает файл и даёт новое.
    val settingsOwner = LocalLifecycleOwner.current
    DisposableEffect(settingsOwner) {
        val watcher = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) adBlock = prefs.getBoolean(PREF_ADBLOCK, false)
        }
        settingsOwner.lifecycle.addObserver(watcher)
        onDispose { settingsOwner.lifecycle.removeObserver(watcher) }
    }
    // Композиция пересоздаётся при повороте, а обработчик статуса живёт в
    // DisposableEffect(Unit): свежие значения он читает через эти обёртки.
    val currentAdBlock by rememberUpdatedState(adBlock)
    val currentAutoSwitch by rememberUpdatedState(autoSwitch)
    // Порог «два подряд» один на обе платформы — он в предикате, а не здесь.
    val autoSwitchThreshold = AutoSwitchPolicy().failuresToAct

    val servers = remember(revision) { store.servers }
    val selected = remember(revision) { store.selected() }
    val rejected = remember(bypass) { SplitTunnelParser.parse(bypass).rejected }

    fun startSession(server: ProxyServer, masking: MaskingProfile) {
        // ApplicationContext, а не Activity: отложенный шаг лестницы может
        // догнать уже уничтоженную композицию и не обязан её держать.
        val app = context.applicationContext
        val request = Intent(app, AnemiaVpnService::class.java).putExtra(
            AnemiaVpnService.EXTRA_SETUP,
            TunnelSetup(
                server = server,
                masking = masking,
                splitTunnel = store.state.splitTunnel,
                adBlock = currentAdBlock,
            ).toJson(),
        )
        // С 12 Android foreground-сервис разрешено поднимать только видимому
        // приложению, а ступенька лестницы догоняет экран при погашенном
        // телефоне. Без обёртки `ForegroundServiceStartNotAllowedException`
        // приходит из корутины без обработчика — это гибель интерфейса вместе
        // с эпизодом, который как раз и собирался восстанавливать связь.
        val started = runCatching { ContextCompat.startForegroundService(app, request) }
        if (started.isFailure) {
            Log.i(
                "Anemia", "переподключение из фона не разрешено: " +
                    started.exceptionOrNull()?.javaClass?.simpleName,
            )
            RecoveryEpisode.abort()
            status = "нужен открытый экран, чтобы переподключиться"
            revision++
            return
        }
        lastTick = System.currentTimeMillis()
        status = "подключение…"
    }

    /**
     * Ступенька лестницы восстановления (порт `attemptReconnect` с macOS):
     * 1 — тот же сервер, 2 — тот же, но маскирование сильнее, 3+ — следующий
     * неподобранный. Ручное «Подключить»/«Отключить» эпизод обрывает.
     */
    fun recover(losingId: java.util.UUID?, viaHealth: Boolean = false) {
        if (!autoSwitch) return
        val list = store.servers
        val ladder = RecoveryEpisode.ladder
        val losing = losingId?.let { id -> list.firstOrNull { it.id == id } } ?: store.selected()
        if (losing == null) {
            RecoveryEpisode.abort()
            status = "соединение потеряно — восстанавливать нечего"
            revision++
            return
        }
        ladder.begin(losing.id, viaHealth = viaHealth)
        // Порядок — по истории замеров, как у кнопки «Лучший» и как на macOS:
        // разовый удачный пинг не должен уводить переключение на сервер, который
        // в длинном ряду хуже.
        val candidates = list.map { it to probes.score(it.id) }
        val step = ladder.step(
            current = losing,
            currentProfile = store.maskingFor(losing),
            candidates = candidates,
            online = hasPhysicalLink(context),
        )
        val forced = ladder.forcedProfile()
        when (step) {
            is Recovery.Step.Hold -> {
                // Пауза не порождает ни широковещания, ни попытки подключения,
                // и без этой строки эпизод, застрявший в «нет сети», выглядит
                // как молчание: ни причины, ни конца.
                Log.i("Anemia", "hold: линка нет, пробую через ${step.delayMs / 1000} с")
                status = "нет сети — жду линк"
                RecoveryEpisode.schedule(step.delayMs) { recover(losingId) }
            }
            is Recovery.Step.GiveUp -> {
                RecoveryEpisode.abort()
                status = "соединение потеряно — ${step.reason}"
            }
            is Recovery.Step.Same -> {
                status = "восстановление: тот же сервер через ${step.delayMs / 1000} с"
                RecoveryEpisode.schedule(step.delayMs) {
                    startSession(losing, forced ?: store.maskingFor(losing))
                }
            }
            is Recovery.Step.Escalate -> {
                status = "восстановление: маскирование сильнее (${step.profile.name})"
                RecoveryEpisode.schedule(step.delayMs) { startSession(losing, step.profile) }
            }
            is Recovery.Step.Switch -> {
                store.select(step.server.id)
                status = "восстановление: переход на ${step.server.name}"
                RecoveryEpisode.schedule(step.delayMs) {
                    startSession(step.server, store.maskingFor(step.server))
                }
            }
        }
        revision++
    }

    val connect: () -> Unit = {
        val server = selected
        if (server == null) {
            notice = "Сначала выберите сервер"
        } else {
            // Ручное нажатие — новый эпизод: лестница, если она шла, отменяется.
            RecoveryEpisode.abort()
            startSession(server, store.maskingFor(server))
        }
    }

    // Без него на Android 13+ уведомление foreground-сервиса не показывается,
    // и «туннель поднят» остаётся невидимым.
    val notifications = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (!granted) status = "уведомления запрещены — статус туннеля виден только на этом экране"
        connect()
    }
    // Разрешение на VPN системное и выдаётся один раз на приложение.
    val consent = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        // Сюда попадает ПЕРВЫЙ запуск: согласие на VPN спрашивается раньше, чем
        // что-либо успело подняться. Сразу `connect()` здесь означало, что
        // запрос на уведомления не появляется никогда — на свежей установке
        // (замерено на релизном APK) туннель поднят, `isForeground=true` с
        // уведомлением, а в шторке пусто, и пользователю не сказать нечего.
        if (it.resultCode != Activity.RESULT_OK) {
            status = "Разрешение на создание VPN-подключений не выдано"
        } else if (
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            notifications.launch(Manifest.permission.POST_NOTIFICATIONS)
        } else {
            connect()
        }
    }

    DisposableEffect(Unit) {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(sender: Context?, intent: Intent?) {
                intent?.getStringExtra(StatusChannel.EXTRA_TEXT)?.let { status = it }
                TunnelLive.up = intent?.getBooleanExtra(StatusChannel.EXTRA_TUNNEL_UP, false) == true
                TunnelLive.sessionId = intent?.getStringExtra(StatusChannel.EXTRA_SESSION_ID)
                    ?.let { runCatching { java.util.UUID.fromString(it) }.getOrNull() }
                lastTick = System.currentTimeMillis()
                TunnelLive.at = lastTick
                val session = TunnelLive.sessionId
                val failed = intent?.getBooleanExtra(StatusChannel.EXTRA_FAILED, false) == true
                val dropped = intent?.getBooleanExtra(StatusChannel.EXTRA_DROPPED, false) == true
                val stopped = intent?.getBooleanExtra(StatusChannel.EXTRA_STOPPED, false) == true
                // null — свежей проверки не было, и это не «ноль отказов».
                val healthFailures =
                    if (intent?.hasExtra(StatusChannel.EXTRA_HEALTH_FAILURES) == true) {
                        intent.getIntExtra(StatusChannel.EXTRA_HEALTH_FAILURES, 0)
                    } else {
                        null
                    }
                when {
                    // Остановка по команде — не обрыв: снятая из шторки плитка
                    // иначе воскрешала бы туннель через секунду, потому что
                    // отложенная ступенька осталась вооружённой.
                    stopped -> RecoveryEpisode.abort()
                    failed && (dropped || RecoveryEpisode.ladder.inProgress) -> {
                        RecoveryEpisode.upTicks = 0
                        recover(session)
                    }
                    failed -> {
                        // Первый отказ подключения, которое никогда не поднималось,
                        // — ошибка в конфигурации, а не обрыв: на macOS в этом
                        // случае лестница тоже молчит, иначе переподключение
                        // крутилось бы на заведомо нерабочем сервере.
                        RecoveryEpisode.abort()
                    }
                    TunnelLive.up && RecoveryEpisode.ladder.inProgress -> {
                        // «Поднялось» ещё не значит «пошло»: туннель может
                        // встать как ни в чём не бывало и продолжать не
                        // пропускать ничего. Без этой ветки эпизод встал бы на
                        // первой ступеньке — отказов больше нет, широковещания о
                        // смерти нет, а лестницу никто не толкает.
                        if ((healthFailures ?: 0) >= autoSwitchThreshold) {
                            RecoveryEpisode.upTicks = 0
                            recover(session)
                            revision++
                            return
                        }
                        RecoveryEpisode.upTicks += 1
                        if (RecoveryEpisode.upTicks < STABLE_TICKS) return
                        val started = if (intent?.hasExtra(StatusChannel.EXTRA_SESSION_START) == true) {
                            intent.getLongExtra(StatusChannel.EXTRA_SESSION_START, 0L)
                        } else {
                            0L
                        }
                        val young = started > 0L &&
                            android.os.SystemClock.elapsedRealtime() - started < HEALTH_GRACE_MS
                        // Первая проверка новой сессии приходит не раньше 30 с,
                        // поэтому «тихий» тик ничего не доказывает: ждём
                        // показание. Молчание дольше `HEALTH_GRACE_MS` — это не
                        // «доказано», а «дальше ждать нечего».
                        if (healthFailures == null && young) return
                        // Профиль запоминается ТОЛЬКО по свежей проверке, которая
                        // сказала «прошло» (`healthFailures == 0`). Иначе таймер
                        // учил бы его по поднятому, но не пропускающему туннелю:
                        // `signalFresh` гаснет, стоит экрану уйти в фон (отметку
                        //«смотрю» больше не продлевают), и `young` когда-нибудь
                        // стал бы false сам — то есть вывод держался бы на часах,
                        // а не на измерении.
                        val proven = healthFailures == 0
                        val forced = RecoveryEpisode.ladder.forcedProfile()
                        if (proven && forced != null) {
                            session?.let { id ->
                                store.servers.firstOrNull { it.id == id }?.let { store.learnedMasking(forced, it) }
                            }
                        }
                        if (!proven && forced != null) {
                            Log.i("Anemia", "профиль не выучен: туннель поднят, но проверка " +
                                "здоровья его не подтвердила")
                        }
                        RecoveryEpisode.abort()
                    }
                    // Отказов здоровья достаточно, эпизода нет — уходим на
                    // другой сервер. Пороги и бюджет в `AutoSwitchPolicy`; здесь
                    // только то, что эпизод не сложился (лестница не началась) —
                    // тогда слот бюджета возвращается, как на iOS.
                    else -> AutoSwitchFlow.evaluate(
                        message = intent,
                        enabled = currentAutoSwitch,
                        serverCount = store.servers.size,
                        busy = RecoveryEpisode.ladder.inProgress,
                    ) { lost ->
                        // Вердикт `Go` — это «выход не пропускает», а не «обрыв»:
                        // первая ступенька такого эпизода обязана уйти на другой
                        // сервер. Без `viaHealth` `Recovery` начинался бы с
                        // `Same`, то есть с переподключения к тому же мёртвому
                        // выходу, эпизод гас бы на втором тике («поднялось»), а
                        // слот бюджета тратился бы впустую — переключение не
                        // наступало бы никогда.
                        recover(lost, viaHealth = true)
                        RecoveryEpisode.ladder.inProgress
                    }
                }
            }
        }
        ContextCompat.registerReceiver(
            context, receiver, IntentFilter(StatusChannel.ACTION), ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        onDispose { context.unregisterReceiver(receiver) }
    }

    // Автоматический раунд живёт в отдельном потоке процесса и сам экран не
    // перерисует; в Compose из чужого потока тоже нельзя — отсюда post на
    // локальное окно.
    val view = LocalView.current
    DisposableEffect(store) {
        val stop = store.observeChanges { view.post { revision++ } }
        onDispose {
            stop()
            // Экран закрылся — круг обязан перестать тратить таймауты (на
            // это же опирается отмена в `probeServers` у macOS).
            probes.cancel()
        }
    }

    LaunchedEffect(Unit) {
        while (true) {
            delay(1_000)
            now = System.currentTimeMillis()
        }
    }
    val quiet = lastTick != 0L && now - lastTick > STALE_MS

    Column(
        Modifier.fillMaxSize().safeDrawingPadding().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("Anemia", style = MaterialTheme.typography.headlineSmall)

        if (servers.isEmpty()) {
            Text("Серверов пока нет — вставьте ссылку или несколько строк сразу",
                style = MaterialTheme.typography.bodyMedium)
        }
        val best = remember(revision) { probes.bestServer(servers) }
        val probing = probes.running
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                if (probing) "замер…" else counted(servers.size, "сервер", "сервера", "серверов"),
                Modifier.weight(1f),
                style = MaterialTheme.typography.titleSmall,
            )
            OutlinedButton(
                enabled = servers.isNotEmpty() && !probing,
                onClick = {
                    // «tunnelLive» и id сессии — из сообщения сервиса, а не
                    // из догадок: пока туннель поднят, проба идёт клиент →
                    // текущий выход → сервер, и в историю такой отсчёт
                    // попадает только для самого подключённого сервера.
                    probes.start(
                        servers = servers,
                        tunnelLive = TunnelLive.up,
                        directServerId = TunnelLive.sessionId,
                        onChanged = { view.post { revision++ } },
                    )
                    revision++
                },
            ) { Text(if (probing) "идёт замер" else "Замерить") }
            OutlinedButton(
                enabled = best != null,
                onClick = {
                    val target = best
                    if (target != null) {
                        store.select(target.id)
                        // `?: 0` иначе рисовало «0 мс» — лучший из возможных
                        // ответов — для сервера, который в этом процессе ещё
                        // не мерили (ряд-то пришёл из истории на диске).
                        val ping = probes.pingOf(target.id)
                        notice = "выбран лучший: " + target.name +
                            if (ping != null) " · $ping мс" else ""
                    }
                    revision++
                },
            ) { Text("Лучший") }
        }
        servers.forEach { server ->
            ServerRow(
                server = server,
                chosen = server.id == selected?.id,
                ping = probes.pingOf(server.id),
                measured = probes.measured(server.id),
                measuring = probes.isMeasuring(server.id),
                best = server.id == best?.id,
                onPick = { store.select(server.id); revision++ },
                onForget = {
                    store.remove(server.id)
                    probes.retain(store.servers)
                    revision++
                },
            )
        }

        val subscriptions = remember(revision) { store.subscriptions() }
        if (subscriptions.isNotEmpty()) {
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Подписки", Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
                OutlinedButton(
                    enabled = busy == null,
                    onClick = {
                        // Кнопка человека — тот же смысл, что тулбар
                        // «Refresh Subscriptions» на macOS: раунд обходит и
                        // TLS-гейт, и интервал панели.
                        busy = java.util.UUID(0, 0)
                        thread(start = true) {
                            val round = store.refreshStale(allowInsecure = true)
                            val text = round?.let {
                                "обновлено " + counted(it.loaded, "панель", "панели", "панелей") +
                                    if (it.failed == 0) "" else ", отказов: " +
                                        counted(it.failed, "панель", "панели", "панелей")
                            } ?: "круг обновления уже идёт"
                            // В окно — через `post`: `revision++` это
                            // чтение-модификация-запись, и с чужого потока она
                            // теряла обновление (ряд показывал число серверов до
                            // круга), а Compose-состояние вообще пишется из
                            // потока интерфейса.
                            view.post {
                                // Порядок важен: `busy = null` раньше `notice`
                                // оставляло кнопку активную со старым текстом, и
                                // второй клик не дал бы никакого ответа.
                                notice = text
                                revision++
                                busy = null
                            }
                        }
                    },
                ) { Text("Обновить все") }
            }
            subscriptions.forEach { subscription ->
                val panel = store.infoOf(subscription.id)
                val name = panel?.title?.takeIf { it.isNotBlank() } ?: subscription.name
                val details = buildString {
                    append(counted(subscription.servers.size, "сервер", "сервера", "серверов"))
                    if (!subscription.tlsProtected) append(" · без шифрования")
                    panel?.remaining?.let { append(" · осталось ${Formatting.bytes(it)}") }
                    panel?.expires?.takeIf { it in 1..PLAUSIBLE_EPOCH_SECONDS }?.let {
                        append(" · до ${DATE.format(Date(it * 1000))}")
                    }
                    subscription.lastUpdatedEpochSeconds?.takeIf { it > 0 }?.let {
                        append(" · обновлена ${DATE.format(Date((it * 1000).toLong()))}")
                    }
                }
                Row(
                    Modifier.fillMaxWidth().padding(vertical = 4.dp),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(name, style = MaterialTheme.typography.bodyLarge)
                        Text(details, style = MaterialTheme.typography.bodySmall)
                    }
                    TextButton(
                        enabled = busy == null,
                        onClick = {
                            busy = subscription.id
                            // Сеть вне главной нити: панель может держать
                            // соединение до 30 с, и всё это время экран живёт.
                            val id = subscription.id
                            thread(start = true) {
                                val result = store.refresh(id)
                                val text = result.error ?: "обновлено: " +
                                    counted(result.subscription?.servers?.size ?: 0, "сервер", "сервера", "серверов")
                                view.post {
                                    notice = text
                                    revision++
                                    busy = null
                                }
                            }
                        },
                    ) { Text(if (busy == subscription.id) "…" else "обновить") }
                    TextButton(
                        enabled = busy != subscription.id,
                        onClick = { store.removeSubscription(subscription.id); revision++ },
                    ) { Text("удалить") }
                }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                value = subscriptionUrl,
                onValueChange = { subscriptionUrl = it },
                label = { Text("Ссылка подписки (https://…)") },
                singleLine = true,
                modifier = Modifier.weight(1f),
            )
            Button(
                enabled = subscriptionUrl.isNotBlank() && busy == null,
                onClick = {
                    val url = subscriptionUrl.trim()
                    busy = java.util.UUID(0, 0)
                    thread(start = true) {
                        // Подписка добавляется только если загрузка вышла:
                        // опечатка в URL не должна оставлять пустую строку.
                        val result = store.addSubscription("", url)
                        val text = result.error ?: "добавлено: " +
                            counted(result.subscription?.servers?.size ?: 0, "сервер", "сервера", "серверов") +
                            if (result.subscription?.tlsProtected == false)
                                " (http: панель может подменить список)" else ""
                        // И этот круг — в поток интерфейса (см. «Обновить все»).
                        view.post {
                            notice = text
                            revision++
                            // Чистить поле только если за 30 с ожидания человек
                            // ничего не успел в него набрать заново.
                            if (result.error == null && subscriptionUrl.trim() == url) subscriptionUrl = ""
                            busy = null
                        }
                    }
                },
            ) { Text("Подписка") }
        }

        OutlinedTextField(
            value = draft,
            onValueChange = { draft = it },
            label = { Text("Добавить: vless://, ss://, awg://, подписка, wg-quick конфиг") },
            minLines = 2,
            modifier = Modifier.fillMaxWidth(),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Button(
                enabled = draft.isNotBlank(),
                onClick = {
                    val result = store.importLink(draft)
                    val added = counted(result.added.size, "сервер", "сервера", "серверов")
                    notice = result.error ?: when {
                        result.skipped > 0 -> "добавлено $added, пропущено " +
                            counted(result.skipped, "битая строка", "битые строки", "битых строк")
                        else -> "добавлено $added"
                    }
                    if (result.ok) {
                        draft = ""
                        revision++
                    }
                },
            ) { Text("Добавить") }
            notice?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary)
            }
        }

        OutlinedTextField(
            value = bypass,
            onValueChange = { bypass = it },
            label = { Text("Мимо VPN: домены и сети, через запятую или с новой строки") },
            supportingText = {
                if (rejected.isNotEmpty()) {
                    Text(rejected.joinToString("; ") { "${it.line}: ${it.reason}" })
                }
            },
            minLines = 2,
            modifier = Modifier.fillMaxWidth(),
        )
        TextButton(onClick = {
            store.setBypass(bypass)
            revision++
            notice = "список обхода сохранён, применится при следующем подключении"
        }) { Text("Сохранить обход") }

        Row(verticalAlignment = Alignment.CenterVertically) {
            Checkbox(
                checked = adBlock,
                onCheckedChange = {
                    adBlock = it
                    prefs.edit().putBoolean(PREF_ADBLOCK, it).apply()
                },
            )
            Text("Блокировать рекламу (AdGuard DNS)")
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Checkbox(
                checked = autoSwitch,
                onCheckedChange = {
                    autoSwitch = it
                    prefs.edit().putBoolean(PREF_AUTOSWITCH, it).apply()
                    // Выключили посреди эпизода — отложенная ступенька не должна
                    // всё равно поднять сервис.
                    if (!it) RecoveryEpisode.abort()
                },
            )
            Text(
                "Переподключаться сам: при обрыве — тот же сервер, сильнее " +
                    "маскирование, потом сосед; если выход перестал пропускать " +
                    "трафик — сразу сосед.",
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("Маскирование:", style = MaterialTheme.typography.labelLarge)
            MaskingProfile.entries.forEach { profile ->
                if (profile == store.state.maskingProfile) {
                    Text(profile.title, fontFamily = FontFamily.Monospace)
                } else {
                    TextButton(onClick = {
                        store.setMasking(profile)
                        revision++
                    }) { Text(profile.title, fontFamily = FontFamily.Monospace) }
                }
            }
        }

        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(enabled = selected != null, onClick = {
                val ask = VpnService.prepare(context)
                val granted = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                    ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
                    PackageManager.PERMISSION_GRANTED
                when {
                    ask != null -> consent.launch(ask)
                    !granted -> notifications.launch(Manifest.permission.POST_NOTIFICATIONS)
                    else -> connect()
                }
            }) { Text("Подключить") }
            OutlinedButton(onClick = {
                // Не `stopService`, а команда сервису: пока туннель жив, его
                // нельзя остановить извне (см. `EXTRA_DISCONNECT`).
                RecoveryEpisode.abort()
                context.startService(
                    Intent(context, AnemiaVpnService::class.java)
                        .putExtra(AnemiaVpnService.EXTRA_DISCONNECT, true),
                )
                lastTick = 0L
                status = "отключено"
            }) { Text("Отключить") }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = { onOpen(Screen.Stats) }) { Text("Статистика") }
            OutlinedButton(onClick = { onOpen(Screen.Leak) }) { Text("Утечки") }
        }
        Text(
            if (quiet) "$status · процесс туннеля молчит ${((now - lastTick) / 1000).toInt()} с" else status,
            style = MaterialTheme.typography.bodyMedium,
            fontFamily = FontFamily.Monospace,
        )
    }
}

@Composable
private fun ServerRow(
    server: ProxyServer,
    chosen: Boolean,
    ping: Int?,
    measured: Boolean,
    measuring: Boolean,
    best: Boolean,
    onPick: () -> Unit,
    onForget: () -> Unit,
) {
    val code = Country.code(server.name)
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onPick).padding(vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(if (code != null) Country.flag(code) else "·", style = MaterialTheme.typography.titleMedium)
        Column(Modifier.weight(1f)) {
            Text(server.name, style = MaterialTheme.typography.bodyLarge)
            Text(
                "${server.proto.raw} · ${server.address}:${server.port}",
                style = MaterialTheme.typography.bodySmall,
            )
        }
        // Задержка отдельным полем, а не в подписи: она меняется каждый круг,
        // и «нет ответа» должно быть видно так же явно, как 40 мс.
        Text(
            when {
                measuring -> "…"
                ping != null -> "$ping мс"
                !measured -> "—"
                else -> "нет ответа"
            },
            style = MaterialTheme.typography.bodySmall,
            color = if (ping == null && measured && !measuring) MaterialTheme.colorScheme.error
                    else MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (best) Text("лучший", style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.primary)
        if (chosen) Text("выбран", style = MaterialTheme.typography.labelMedium)
        TextButton(onClick = onForget) { Text("убрать") }
    }
}

/**
 * Магазин один на процесс: поворот экрана пересоздаёт активити, а фоновый
 * поток загрузки держит ссылку на старый экземпляр — и записал бы файл
 * исподтишка нового.
 */
internal val storeLock = Any()
internal var shared: ServerStore? = null

internal fun sharedStore(context: Context): ServerStore = synchronized(storeLock) {
    shared ?: ServerStore(
        StatePersistence(File(context.applicationContext.filesDir, STATE_FILE)),
        PanelStore(context.applicationContext.getSharedPreferences(PANELS, Context.MODE_PRIVATE)),
    ).also { it.reload(); shared = it }
}

private val probeLock = Any()
private var sharedProbeStore: ProbeStore? = null

/** Один на процесс: круг живёт в своём потоке, а ряды истории пишет в файл. */
internal fun sharedProbes(context: Context): ProbeStore = synchronized(probeLock) {
    sharedProbeStore ?: ProbeStore(
        ProbeHistory(File(context.applicationContext.filesDir, HISTORY_FILE)),
    ).also { sharedProbeStore = it }
}

/** Один на процесс: отчёт лежит в файле процесса, а тред замера — нет. */
private val speedLock = Any()
private var sharedSpeedTest: SpeedTest? = null

internal fun sharedSpeed(context: Context, base: String? = null): SpeedTest = synchronized(speedLock) {
    sharedSpeedTest ?: SpeedTest(
        file = File(context.applicationContext.filesDir, SpeedTest.FILE),
        endpoints = SpeedTester.Endpoints(base = base ?: SpeedTester.Endpoints().base),
    ).also { sharedSpeedTest = it }
}

private val leakLock = Any()
private var sharedLeakChecker: LeakChecker? = null

/**
 * Один на процесс: четыре хода и запрос `requestNetwork` живут в рабочем потоке
 * и переживают поворот экрана.
 *
 * `base` смещает адреса сервисов на свой сервер — это нужно только отладочной
 * сборке (см. [debuggableOnly]): чужое приложение, запустившее экран с своим
 * адресом, иначе показало бы пользователю «утечек нет» из ответа своего сервера.
 */
internal fun sharedLeaks(context: Context, base: String? = null, directBase: String? = null): LeakChecker =
    synchronized(leakLock) {
        sharedLeakChecker ?: LeakChecker(
            // ApplicationContext, а не Activity: `ConnectivityManager` держит
            // тот контекст, из которого его достали, а синглтон живёт до конца
            // процесса — первый же `MainActivity` виси бы в нём вместе с деревом
            // видов после всех поворотов экрана.
            context.applicationContext.getSystemService(ConnectivityManager::class.java),
            endpoints = if (base == null) LeakChecker.Endpoints() else LeakChecker.Endpoints(
                ip = "$base/geoip",
                ipv6 = "$base/geoip6",
                trace = "$base/trace",
                bashId = "$base/id",
                bashLeak = "$base/dnsleak/test/{id}?json",
                bashDomain = "bash.local",
                // Второй наблюдатель для хода вне туннеля: в сети это разные
                // адресаты, у заглушки — разные пути.
                ipDirect = directBase?.let { "$it/geoip" },
                traceDirect = directBase?.let { "$it/trace" },
            ),
        ).also { sharedLeakChecker = it }
    }

/** Значение extra только для отладочной сборки: релизный APK чужие адреса не принимает. */
private fun debuggableOnly(context: Context, intent: android.content.Intent?, key: String): String? {
    val value = intent?.getStringExtra(key)
    return value?.takeIf { debuggable(context) && (it.startsWith("http://") || it.startsWith("https://")) }
}

/** Флаг отладочной сборки (`--es leak_run 1`); в релизе не действует. */
private fun debugFlag(context: Context, intent: android.content.Intent?, key: String): Boolean =
    debuggable(context) && intent?.getStringExtra(key) == "1"

private val DATE = SimpleDateFormat("yyyy-MM-dd", Locale.ROOT)

/** Дальше этой даты панельные сроки не живут: `Long.MAX_VALUE` из заголовка
    Swift тоже печатает бессмыслицу, а не 1753 год. */
private const val PLAUSIBLE_EPOCH_SECONDS = 4_102_444_800L  // 2100-01-01

private const val STATE_FILE = "state.json"
private const val PREFS = "anemia"

/** Отдельный файл под заголовками панелей: `anemia` — настройки экрана, а это
 * снимок чужого ответа, который можно потерять без всякого ущерба. */
private const val PANELS = "anemia-panels"

/** Ряды замеров — отдельный файл, как `history.json` на macOS. */
private const val HISTORY_FILE = "history.json"

/** То же имя ключа, что у macOS в `UserDefaults` («adBlock»). */
private const val PREF_ADBLOCK = "adBlock"

/** Пусто — включено: на macOS лестница восстановления работает всегда, так что
 * по умолчанию Android ведёт себя так же, а выключает её только тот, кому нужен
 * один подъём и никаких переподключений. */
private const val PREF_AUTOSWITCH = "autoSwitch"
private const val EXTRA_LINK = "link"

/**
 * Адреса сервисов утечек и скорости для отладочной сборки (`--es leak_base …`,
 * `--es speed_base …`): на эмуляторе проверяется и «утечка есть», и «утечки
 * нет» — а для этого ответы сервисов должны быть подконтрольными. Релизный
 * APK эти extras игнорирует.
 */
private const val EXTRA_LEAK_BASE = "leak_base"
private const val EXTRA_LEAK_DIRECT_BASE = "leak_direct_base"
private const val EXTRA_SPEED_BASE = "speed_base"

/**
 * `--es leak_run 1` — проверить утечки сразу при запуске, без тапов: экран
 * иначе нельзя подтвердить на эмуляторе, где никто не ждёт нужную кнопку на
 * нужном месте. Отладочная сборка, как и адреса заглушек.
 */
private const val EXTRA_LEAK_RUN = "leak_run"

/** Сколько ждать первый тик сервиса: до него не известно, поднят ли туннель. */
private const val LEAK_RUN_WAIT_MS = 4_000L

/** Отладочная ли сборка: релизный APK чужие `--es` не слушает. */
private fun debuggable(context: Context) = (context.applicationInfo.flags and
    android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0

/** Три тика сервиса плюс запас на резолвинг имён обхода при переподключении. */
private const val STALE_MS = 12_000L

/** Как часто экран подтверждает, что на туннель смотрят (окно свежести — 60 с). */
private const val WATCH_PING_MS = 20_000L

/** Сколько тиков сервиса (~3 с) сессия должна прожить после ступеньки лестницы,
 * чтобы навязанный профиль считался выученным. */
private const val STABLE_TICKS = 2

/**
 * Сколько секунд эпизод ждёт первое показание здоровья, прежде чем поверить
 * одним тикам. Первая проверка новой сессии приходит не раньше `HEALTH_CHECK_MS`
 * (30 с) плюс пауза «за нами следят» (до 20 с): 60 с — это потолок правдивого
 * ожидания, дальше молчащий движок означает «отвечать нечем», а не «туннель жив».
 */
private const val HEALTH_GRACE_MS = 60_000L
