package app.anemia.vpn

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.VpnService
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.util.Log
import app.anemia.core.Addresses
import app.anemia.core.Formatting
import app.anemia.core.HealthSchedule
import app.anemia.core.HealthState
import app.anemia.core.StatePersistence
import app.anemia.core.TrafficCounters
import app.anemia.core.TunnelHealth
import app.anemia.data.ServerStore
import app.anemia.data.TrafficStore
import app.anemia.data.TunnelSetup
import java.io.File
import java.net.InetAddress
import java.net.NetworkInterface
import java.util.Collections
import java.util.UUID
import kotlin.concurrent.thread

/**
 * Туннель. Аналог `iOS/AnemiaTunnel/PacketTunnelProvider.swift`.
 *
 * Живёт в отдельном процессе (`:vpn`): убийство интерфейса не роняет туннель,
 * и память движка не считается вместе с Compose. Дескриптор отдаётся движку
 * как есть — `engine.go` дублирует его сам (`dupNonblocking`) и закрывает
 * свою копию на остановке, а эту мы держим открытой всё подключение.
 *
 * Подъём — операция не быстрая: резолв имён обхода (до 4 с), ожидание снятого
 * предыдущего интерфейса (до 4 с), старт Go-движка. Всё это на отдельном
 * потоке: на главной нити сервиса такой набор упирается в ANR, а
 * `startForeground` к тому моменту уже выполнен в `onStartCommand`.
 */
class AnemiaVpnService : VpnService() {

    private var tunnel: ParcelFileDescriptor? = null
    private var connectivity: ConnectivityManager? = null
    private var callback: ConnectivityManager.NetworkCallback? = null
    private val workerThread = HandlerThread("tunnel").apply { start() }
    private val worker = Handler(workerThread.looper)
    @Volatile private var session = "Anemia"

    /** Пишется на рабочем потоке (разбор в `tick`), читается на главном
     * (`onDestroy`). Без отметки порядок не гарантирован, и `onDestroy` снял бы
     * уведомление, которое как раз для пользователя и ставился. */
    @Volatile private var endedInFailure = false

    /**
     * Сервер, через который живёт туннель. Нужен, чтобы заметить, как панель
     * убрала его из списка: на macOS это разрыв сессии
     * (`refreshAllSubscriptions` зовёт `disconnect()`), а без такого же
     * правила здесь «подключено» может висеть над выходом, который провайдер
     * отозвал, — и трафик в него продолжает идти.
     */
    private var sessionSetup: TunnelSetup? = null

    /** Когда в последний раз сверялись со списком (не каждый тик). */
    private var listingCheckedAt = 0L

    /** Поднимался ли туннель в этой сессии. Отличает обрыв (отказ после
     * `establish()`) от ошибки в конфигурации: лестница заводится на первое. */
    @Volatile private var tunnelWasUp = false

    /** Сколько тиков подряд интерфейс пропал при живом дескрипторе. */
    private var tunnelMisses = 0

    /**
     * Ряды трафика. Пишутся отсюда и только отсюда: счётчики снимает этот
     * процесс, и второй писатель с другой копией ряда откатил бы чужие минуты.
     */
    private val traffic by lazy { TrafficStore(File(filesDir, TrafficStore.FILE_NAME)) }

    /**
     * Старт текущего запуска движка в секундах от эпохи — «идентичность»
     * связки отсчётов для `TrafficLedger`. Берётся из `uptime` самого движка на
     * первом тике и больше не меняется: считать его как `сейчас − uptime` на
     * каждом тике — значит получать новое значение каждые три секунды, а тогда
     * каждый отсчёт станет разницей с нулём, то есть накопленным итогом.
     */
    @Volatile private var runStartedAt = 0.0

    /** Последний доставленный startId: `stopSelf()` без него убил бы сессию,
     * которую пользователь успел запустить пока мы разбирались. */
    @Volatile private var lastStartId = 0

    /**
     * Здоровье сессии. Считается здесь и только отчитывает числом подряд
     * неудачных проверок: решение «уводить ли выход» принимает экран, ровно как
     * на iOS, где расширение отказы считает, а приложение их читает.
     *
     * Проверка идёт на том же рабочем потоке, что поднимает и рвёт туннель:
     * `AnemiaCheckActive` работает с живым экземпляром xray, который
     * `AnemiaStop` закрывает, — один обработчик снимает вопрос о гонке с
     * закрывающимся движком. Плата — отключение иногда ждёт завершающийся
     * запрос, и она ограничена `HEALTH_TIMEOUT_MS`.
     */
    private var sessionKind: ConfigApplier.Kind? = null
    private var sessionStart = 0L
    private var healthFailures = 0
    private var healthCheckedAt = 0L
    private var lastTraffic: TrafficCounters? = null

    /** Когда экран последний раз сказал, что смотрит. Тот же смысл, что
     * `healthWanted` на iOS: без зрителя туннель не проверяется. */
    private var healthWantedAt = 0L

    private val healthRules = TunnelHealth()
    private val healthSchedule = HealthSchedule()

    /**
     * Опрос движка идёт на рабочем потоке, а не на главном: `AnemiaStatus()`
     * берёт мьютекс движка, который `startXray`/`stopLocked` держит секунды
     * (`xray.Close()` и `FreeOSMemory`), — на главной нити это ANR ровно
     * посреди подключения.
     */
    private val healthTick = object : Runnable {
        override fun run() {
            // Рабочий поток сервиса — это `Looper`, а необработанное исключение
            // из сообщения заканчивает гибелью процесса: туннель снят, `traffic`
            // не записан, причины наружу нет. Отказ одной проверки не стоит
            // соединения.
            runCatching { checkHealth() }.onFailure { Log.w(TAG, "проверка здоровья: ${it.message}") }
            // Только если сессия ещё жива: `closeTunnel()` снимает этот callback,
            // а перепост «на всякий случай» оживил бы его сразу после разбора.
            if (sessionKind != null) worker.postDelayed(this, HEALTH_CHECK_MS)
        }
    }

    /** Один шаг опроса: `HealthSchedule` решает, пора ли мерить, а правило — что засчитать. */
    private fun checkHealth() {
        val kind = sessionKind ?: return
        val now = SystemClock.elapsedRealtime()
        // На iOS часов два — «приложение опрашивает статус» и «приложение
        // просит здоровье»; здесь оба свёрнуты в одну отметку экрана —
        // на Android это одно и то же наблюдение.
        val watched = if (healthWantedAt == 0L) null else (now - healthWantedAt) / 1000.0
        if (healthSchedule.healthDue(
                watchedAge = watched,
                wantedAge = watched,
                checkedAge = if (healthCheckedAt == 0L) null else (now - healthCheckedAt) / 1000.0,
            )) {
            checkHealth(kind, now)
        }
    }

    /** Порт `PacketTunnelProvider.checkHealth`: xray — настоящий запрос через
     * живое соединение, AmneziaWG — дельты счётчиков. */
    private fun checkHealth(kind: ConfigApplier.Kind, now: Long) {
        val outcome = when (kind) {
            ConfigApplier.Kind.Xray ->
                healthRules.request(Engine.checkActive(HEALTH_URL, HEALTH_TIMEOUT_MS)?.toInt())
            ConfigApplier.Kind.AmneziaWG -> {
                // Молчание движка — не «проверка не состоялась, забываем время»:
                // `healthCheckedAt` не обновляется, и следующая попытка будет
                // через тик сервиса, а не через полчаса.
                val status = Engine.status ?: return
                // Но `status == null` такого молчания не ловит: `AnemiaStatus`
                // отвечает всегда и всеми восемью ключами — даже когда движка нет
                // (`engine` пустой), а `awgTraffic` превращает сорвавшийся
                // `IpcGet` в тройку нулей. Нуль, записанный базовой линией, стоит
                // дорого: следующая дельта равна уже накопленным байтам, `received
                // > 0` в `TunnelHealth.counters` идёт первым условием, полоса
                // отказов обнуляется — и при AmneziaWG переключение не наступило
                // бы никогда. Тот же страж стоит в iOS-`checkHealth`; без него
                // здесь ещё и `healthCheckedAt` штамповался бы по нулям, то есть
                // `signalFresh` вечно врал бы про свежее показание.
                // Правило — в `AwgReading`: оно переживает только устройству,
                // пока живёт внутри сервиса, поэтому вынесено и проверено тестом.
                val counters = TrafficCounters(status.up, status.down)
                AwgReading.refusal(status.engine, status.missingKeys, counters, lastTraffic)?.let {
                    Log.w(TAG, "показание AmneziaWG не засчитано: $it")
                    return
                }
                healthRules.counters(counters, lastTraffic, null).also { lastTraffic = counters }
            }
        }
        healthCheckedAt = now
        val state = healthRules.apply(outcome, HealthState(failures = healthFailures))
        if (state.failures > healthFailures) {
            Log.i(TAG, "health: туннель не пропустил проверку (подряд ${state.failures})")
        }
        healthFailures = state.failures
    }

    private val tick = object : Runnable {
        override fun run() {
            runCatching { statusTick() }.onFailure { Log.w(TAG, "тик статуса: ${it.message}") }
            // Ветка «сервер исчез из подписки» и ветка «система сняла туннель»
            // рвут соединение изнутри `statusTick` и снимают этот callback через
            // `closeTunnel()`; до переработки они ещё и не перепостили себя.
            // Слепой перестановка оживила бы тикатель после разбора — он бы
            // публиковал статус несуществующей сессии до самого `onDestroy`.
            if (tunnel != null || sessionSetup != null) worker.postDelayed(this, REFRESH_MS)
        }
    }

    private fun statusTick() {
        val setup = sessionSetup
        val now = android.os.SystemClock.elapsedRealtime()
        val status = Engine.status
        // Замороженный счётчик наружу не уходит: `signalFresh` отвечает
        // «нет данных», и экран не начинает переключаться по показанию,
        // которое перестало обновляться (ушёл экран, часы шагнули назад).
        val fresh = healthSchedule.signalFresh(
            checkedAge = if (healthCheckedAt == 0L) null else (now - healthCheckedAt) / 1000.0
        )
        StatusChannel.publish(
            this@AnemiaVpnService, session, statusText(status),
            tunnelUp = tunnel != null, sessionId = setup?.server?.id?.toString(),
            healthFailures = if (fresh && tunnel != null) healthFailures else null,
            sessionStart = if (tunnel != null) sessionStart else null,
        )
        countTraffic(status, setup)
        if (setup != null && now - listingCheckedAt >= LISTING_CHECK_MS) {
            listingCheckedAt = now
            val live = liveServerIds()
            // Ряды удалённых серверов чистятся здесь же, где и проверка
            // списка: второй писатель `traffic.json` интерфейсу не положен.
            if (live != null) traffic.forgetExcept(live)
            if (live != null && setup.server.id !in live) {
                // Рвём туннель, а не только `stopSelf()`: пока дескриптор
                // жив, стек держит привязку к сервису, и «подключено»
                // осталось бы висеть над отозванным выходом.
                endedInFailure = true
                Engine.stop()
                closeTunnel()
                StatusChannel.fail(
                    this@AnemiaVpnService, session,
                    "Сервер исчез из подписки — соединение разорвано",
                    sessionId = setup.server.id.toString(),
                    dropped = tunnelWasUp,
                )
                sessionSetup = null
                stopSelf(lastStartId)
                return
            }
        }
        // «Система сняла туннель» — порт того же наблюдения с macOS: при
        // чужом VPN поверх нас и при умершей подложке дескриптор остаётся
        // открытым, движок отвечает, счётчики идут, а маршрутов нет. Два
        // пропуска подряд, а не один: снятие и создание интерфейса при
        // переподключении асинхронные, и один тик мог показать пустоту.
        if (tunnel != null && setup != null) {
            if (tunnelNames().isEmpty()) tunnelMisses += 1 else tunnelMisses = 0
            if (tunnelMisses >= TUNNEL_MISS_LIMIT) {
                tunnelMisses = 0
                endedInFailure = true
                Engine.stop()
                closeTunnel()
                StatusChannel.fail(
                    this@AnemiaVpnService, session, "Система сняла туннель",
                    sessionId = setup.server.id.toString(), dropped = true,
                )
                sessionSetup = null
                stopSelf(lastStartId)
                return
            }
        }
    }

    override fun onStartCommand(command: Intent?, flags: Int, startId: Int): Int {
        if (command?.action == ACTION_FETCH) {
            // Просьба интерфейса: один GET сквозь туннель. Отвечает этот
            // процесс, потому что его и может сделать движок — сокет
            // приложения идёт мимо VPN (см. `TunnelFetch`). Рабочий поток не
            // из-за мьютекса: `AnemiaFetch` берёт `mu` только чтобы списать
            // указатель на экземпляр и отпускает его до запроса
            // (iOS/Engine/probe.go). Он здесь по той же причине, что и проверка
            // здоровья: `stopLocked()` закрывает экземпляр, пока запрос идёт.
            // Плата тоже та же — «Отключить» может подождать уходящий ход до
            // `timeoutMs`.
            val id = command.getLongExtra(StatusChannel.EXTRA_FETCH_ID, -1L)
            val url = command.getStringExtra(StatusChannel.EXTRA_FETCH_URL)
            val timeout = command.getIntExtra(StatusChannel.EXTRA_FETCH_TIMEOUT_MS, 12_000)
            val maxBytes = command.getIntExtra(StatusChannel.EXTRA_FETCH_MAX_BYTES, 16 * 1024)
            worker.post {
                fetchAndReply(id, url, timeout, maxBytes)
                // Без туннеля процесс поднят только ради отказа: ответ ушёл, и
                // собственный startId обязан освободиться — как в ветках «смотрю»
                // и «сбрось статистику», иначе интерфейс с опущенным туннелем
                // оставлял бы `:vpn` висеть стартованным.
                if (tunnel == null) stopSelf(startId)
            }
            return START_NOT_STICKY
        }
        // START_REDELIVER_INTENT: OEM-убийцы процессов (Miui, Samsung) снимают
        // сервис чаще, чем iOS убивает расширение. Sticky для переподключения
        // не годится — он доставляет null, а без setup'а подключаться нечем.
        if (command?.getBooleanExtra(EXTRA_WATCH, false) == true) {
            // «Экран смотрит, здоровье можно мерить» — аналог iOS-owego
            // `wantsHealth`. Ничего не переподключается; без живой сессии
            // освобождается собственный startId, иначе открытый экран оставил
            // бы процесс висеть стартованным.
            worker.post {
                healthWantedAt = SystemClock.elapsedRealtime()
                if (tunnel == null) stopSelf(startId)
            }
            return START_NOT_STICKY
        }
        if (command?.getBooleanExtra(EXTRA_RESET_TRAFFIC, false) == true) {
            // Сброс статистики шлётся сюда, а не пишется из интерфейса: у ряда
            // один писатель, и его память вернула бы удалённые минуты обратно
            // при ближайшей записи. Процесс для команды поднимается и без
            // живого туннеля — так у сброса остаётся один путь.
            worker.post {
                traffic.reset()
                // Гасим себя, только если сессии нет: `stopSelf(startId)` при
                // живом туннеле оборвал бы соединение, которое пользователь
                // запустил этим же сообщением чуть раньше.
                if (tunnel == null) stopSelf(startId)
            }
            return START_NOT_STICKY
        }
        if (command?.getBooleanExtra(EXTRA_DISCONNECT, false) == true) {
            // `stopService()` туннель не рвёт: пока интерфейс жив, сетевой стек
            // держит свою привязку к сервису. Дескриптор закрываем сами и
            // только потом просим систему нас убить.
            worker.post {
                sessionSetup = null
                Engine.stop()
                closeTunnel()
                StatusChannel.stop(this)
                stopSelf(startId)
            }
            return START_NOT_STICKY
        }
        val setup = TunnelSetup.fromJson(command?.getStringExtra(EXTRA_SETUP))
        if (setup == null) {
            // Нас подняли как foreground-сервис: если выйти до
            // `startForeground()`, через 5 с система убьёт процесс
            // RemoteServiceException без единой строчки для пользователя.
            session = "Anemia"
            StatusChannel.start(this, session)
            endedInFailure = true
            StatusChannel.fail(this, session, "Сообщение туннеля не читается")
            stopSelf(startId)
            return START_NOT_STICKY
        }
        // Сервер мог быть удалён из списка, пока процесс лежал мёртвым в
        // ожидании пересылки: redeliver приносит старый setup, и молча
        // подключаться к нему нельзя — но проверяет это рабочий поток, а не
        // главный: перечитать и разобрать `state.json` на главном — это ANR
        // ровно на том месте, где у сервиса ещё нет foreground-обещания.
        session = setup.server.name.ifEmpty { "Anemia" }
        lastStartId = startId
        StatusChannel.start(this, session)
        worker.post {
            openTunnel(command, startId)?.let { reason ->
                // id умершего сервера читается ДО обнуления: без него лестница
                // не знает, кто именно отказал, и вынуждена гадать по выбору.
                val lost = sessionSetup?.server?.id?.toString()
                sessionSetup = null
                Engine.stop()
                closeTunnel()
                endedInFailure = true
                StatusChannel.fail(
                    this, session, reason,
                    sessionId = lost, dropped = tunnelWasUp,
                )
                // `stopSelf(startId)`, а не `stopSelf()`: пока мы ждали,
                // пользователь мог успеть нажать другой сервер, и голый
                // stopSelf() убил бы уже новую сессию.
                stopSelf(startId)
            }
        }
        return START_REDELIVER_INTENT
    }

    /** null — туннель поднялся; иначе причина, которую надо показать. */
    private fun openTunnel(command: Intent?, startId: Int): String? {
        val setup = TunnelSetup.fromJson(command?.getStringExtra(EXTRA_SETUP))
            ?: return "Сообщение туннеля потерялось"
        sessionSetup = setup
        listingCheckedAt = android.os.SystemClock.elapsedRealtime()
        tunnelWasUp = false
        tunnelMisses = 0
        if (!stillListed(setup)) {
            return "Сервера больше нет в списке — подключение отменено"
        }
        if (prepare(applicationContext) != null) {
            return "Разрешите Anemia создавать VPN-подключения"
        }
        if (!Engine.available) {
            return "Движок не загружен (libanemia.so отсутствует)"
        }
        if (tunnel != null) {
            // Второй `establish()` поверх живого туннеля система принимает и
            // даже выдаёт дескриптор, но интерфейс при этом тонет: снятие
            // предыдущего асинхронное (замерено на эмуляторе). Рвём текущий, а
            // ждать снятия — ниже, перед `establish()`.
            StatusChannel.publish(this, session, "переподключение…", tunnelUp = false, sessionId = null)
            Engine.stop()
            closeTunnel()
        }
        // Единственный способ увидеть, с каким маскированием поехали: конфиг в
        // лог движка не попадает целиком, а спорить о выученном профиле без
        // этой строки можно только по косвенным признакам. Версия движка здесь
        // же, как `report.engineVersion` на iOS: APK уходит на телефон в обход
        // магазина, и «у меня не работает» без строки сборки различается с
        // «у меня старый движок» только по этой строке.
        Log.i(TAG, "connect ${setup.server.name} with masking ${setup.masking.name} · ${Engine.version}")
        val plan = try {
            ConfigApplier.plan(
                setup = setup,
                logFile = getFileStreamPath("engine.log").absolutePath,
                resolver = ::lookup,
            )
        } catch (error: Exception) {
            return error.message ?: "Конфиг не собрался"
        }

        // Всё, что ниже, может бросить: `establish()` — на отказ системы,
        // `addAddress`/`addDnsServer` — на мусор в профиле. Без обёртки это
        // гибель процесса без единой строчки пользователю.
        return try {
            Engine.setLogDirectory(filesDir.absolutePath)
            Engine.setMemoryLimit(MEMORY_LIMIT_BYTES)
            waitUntil(TUNNEL_GONE_MS) { tunnelNames().isEmpty() }
            val builder = Builder().apply {
                // `setBlocking(true)` — это и есть kill switch Android: пока
                // туннель жив, вне него не едет ничего, кроме UID приложения.
                // Отдельный флаг `killSwitchEnabled` из состояния здесь не
                // читается намеренно: на macOS он включает правила pf в
                // привилегированном помощнике (когда туннеля нет вовсе), а
                // аналога «нет туннеля — нет сети» у обычного приложения на
                // Android нет. `autoConnectOnLaunch` тоже не реализован:
                // переподключение после убийства делает START_REDELIVER_INTENT,
                // а «подключаться при запуске интерфейса» — очередь UI.
                ConfigApplier.apply(this, plan, packageName).setBlocking(true)
            }
            val fd = builder.establish() ?: return "Система не дала туннель"
            tunnel = fd
            endedInFailure = false
            // Новый запуск движка — новая связка отсчётов: счётчики обнуляются
            // вместе с прогоном, и смешивать их с прошлым нельзя.
            runStartedAt = 0.0
            when (plan.kind) {
                ConfigApplier.Kind.Xray -> Engine.startXray(plan.argument, fd.fd)
                ConfigApplier.Kind.AmneziaWG -> Engine.startAwg(plan.argument, fd.fd)
            }
            // Интерфейс обязан появиться: без этой проверки мёртвый туннель
            // выглядит живым — движок отвечает, счётчики идут, а маршрутов нет.
            if (!waitUntil(TUNNEL_UP_MS) { tunnelNames().isNotEmpty() }) {
                // Движок отвечает, счётчики идут, а маршрутов нет — это и есть
                // «живой с виду мёртвый туннель». Отказ, а не предупреждение.
                Engine.stop()
                closeTunnel()
                return "Интерфейс туннеля не появился — система не отдала маршруты"
            }
            tunnelWasUp = true
            sessionKind = plan.kind
            sessionStart = SystemClock.elapsedRealtime()
            healthFailures = 0
            healthCheckedAt = 0L
            lastTraffic = null
            watchNetwork()
            worker.post(tick)
            worker.postDelayed(healthTick, HEALTH_CHECK_MS)
            null
        } catch (error: Exception) {
            Engine.stop()
            closeTunnel()
            error.message ?: "Туннель не поднялся"
        }
    }

    /**
     * Обходимые имена резолвятся *до* подъёма туннеля. У `InetAddress` нет
     * своего таймера, а чёрная дыра в DNS стоит полминуты на каждое имя —
     * отсюда потолок: потерянный пункт обхода отправит в туннель один сайт,
     * потерянное окно не оставит туннеля вовсе.
     */
    private fun lookup(name: String, timeoutMs: Long): List<String> {
        if (!name.matches(Regex("[A-Za-z0-9._-]+"))) return emptyList()
        var found: List<String> = emptyList()
        val thread = thread(start = true) {
            found = runCatching {
                InetAddress.getAllByName(name).map { it.hostAddress ?: "" }
                    // Ответы fake-IP чужого VPN (198.18.0.0/15) отбрасываются:
                    // иначе пин сервера или пункт обхода указал бы на адрес из
                    // чужого туннеля — «подключено», а трафик в никуда.
                    .filter { Addresses.isIPv4(it) && !Addresses.isFakeIP(it) }
            }.getOrDefault(emptyList())
        }
        thread.join(timeoutMs.coerceAtLeast(0))
        // Прерывание `getAllByName` не останавливает: поток ещё будет висеть в
        // резолвере — тот же след остаётся и на iOS (работа на очереди
        // диспетчера). Это цена отказа от ANR, и она ограничена числом имён.
        if (thread.isAlive) thread.interrupt()
        return found
    }

    /** Wi-Fi ↔ мобильная сеть: AmneziaWG перепривязывает сокеты. */
    private fun watchNetwork() {
        val manager = getSystemService(ConnectivityManager::class.java) ?: return
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                Engine.networkChanged()
            }
        }
        // Предыдущий callback обязан уйти: иначе он остаётся зарегистрированным
        // на старый экземпляр сервиса и зовёт `Engine.networkChanged()` в
        // новую сессию, а `registerDefaultNetworkCallback` на лимите
        // NetworkRequest просто молча не даст нам перепривязку AWG.
        releaseNetworkWatch()
        connectivity = manager
        this.callback = callback
        // Дефолтная сеть, а не «любоя»: запрос без транспорта совпал бы и с
        // туннелем, который мы сами же поднимаем, и перепривязка началась бы
        // на каждое его перерождение.
        //
        // Обработчик — тот же `worker`, а не «как повезёт»: без него система
        // несёт события в главный поток процесса, а `AmneziaNetworkChanged`
        // стоит в мьютексе движка, который `startXray`/`stopLocked` держат
        // секунды. Ровно от этого вся остальная опрос-разбор-проводка уже
        // уведена на рабочий поток; здесь это было единственное исключение.
        runCatching { manager.registerDefaultNetworkCallback(callback, worker) }
            .onFailure { Log.w(TAG, "перепривязка сети недоступна: ${it.message}") }
    }

    /**
     * Один тик в ряд трафика. `runStartedAt` снимается ровно один раз за запуск
     * движка — из `uptime` самого движка, чтобы имя связки не менялось на каждом
     * тике (см. поле выше), и пустой ответ движка рядом не становится: без
     * отсчёта просто нечего складывать.
     */
    private fun countTraffic(status: Engine.Status?, setup: TunnelSetup?) {
        if (tunnel == null || status == null || setup == null) return
        val now = System.currentTimeMillis() / 1000.0
        if (runStartedAt == 0.0) runStartedAt = now - status.uptime
        traffic.record(runStartedAt, status.down, status.up, setup.server.id to setup.server.name)
    }

    /**
     * Живые id серверов из `state.json`; null — список не прочитался или пуст.
     * И то, и другое — «мы ничего не знаем»: испорченный, заблокированный или
     * ещё не записанный файл не должен ни рвать живой туннель, ни стирать ряды
     * трафика.
     */
    private fun liveServerIds(): Set<UUID>? {
        val stored = runCatching {
            ServerStore(StatePersistence(File(filesDir, "state.json"))).reload()
        }.getOrNull() ?: return null
        if (stored.allServers.isEmpty()) return null
        return stored.allServers.map { it.id }.toSet()
    }

    /**
     * Система забирает туннель: вышел другой VPN или пользователь отозвал
     * разрешение. Реализация по умолчанию — `stopSelf()`, а он, как установлено
     * выше, туннель не рвёт; закрываем сами.
     */
    override fun onRevoke() {
        // Причина — в уведомлении, а не в молчании.
        endedInFailure = true
        worker.post {
            Engine.stop()
            closeTunnel()
            StatusChannel.fail(
                this, session, "Система забрала туннель",
                sessionId = sessionSetup?.server?.id?.toString(),
                dropped = tunnelWasUp,
            )
        }
        workerThread.quitSafely()
        super.onRevoke()
    }

    /**
     * Жив ли ещё сервер в списке. `--es link` в список не пишет, поэтому
     * проверяется только выбор, пришедший из него.
     */
    private fun stillListed(setup: TunnelSetup): Boolean =
        liveServerIds()?.contains(setup.server.id) ?: true

    private fun statusText(status: Engine.Status?): String {
        if (status == null) return "нет ответа движка"
        if (status.missingKeys.isNotEmpty()) {
            // Как на iOS: пришедшие поля показываются, ушедшие — в лог.
            // Заменить счётчики сообщением о схеме — значит потерять трафик
            // из вида при одном переименованном ключе.
            Log.w(TAG, "в ответе движка нет ключей: ${status.missingKeys.joinToString()}")
        }
        return "${status.engine} · ${Formatting.bytes(status.up + status.down)} · ${status.uptime.toLong()} с"
    }

    /** Имена `tunN`: интерфейс создаёт система, мы только смотрим в его сторону. */
    private fun tunnelNames(): List<String> =
        Collections.list(NetworkInterface.getNetworkInterfaces())
            .map { it.name }.filter { TUNNEL_NAME.matches(it) }

    /** Опрос условия с паузами; false, если время вышло. */
    private fun waitUntil(timeoutMs: Long, condition: () -> Boolean): Boolean {
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (!condition()) {
            if (SystemClock.elapsedRealtime() >= deadline) return false
            Thread.sleep(POLL_MS)
        }
        return true
    }

    private fun releaseNetworkWatch() {
        callback?.let { c -> runCatching { connectivity?.unregisterNetworkCallback(c) } }
        callback = null
        connectivity = null
    }

    private fun closeTunnel() {
        worker.removeCallbacks(tick)
        worker.removeCallbacks(healthTick)
        sessionKind = null
        lastTraffic = null
        healthFailures = 0
        healthCheckedAt = 0L
        releaseNetworkWatch()
        // Закрытие не должно уронить процесс: из `onDestroy` исключение
        // дошло бы до системного обработчика.
        val fd = tunnel
        tunnel = null
        runCatching { fd?.close() }
        // Дескриптор закрыт — связка отсчётов кончилась: следующий тик обязан
        // начать новую, а не считать разницу с прошлым прогоном.
        if (fd != null) traffic.stopped()
    }

    override fun onDestroy() {
        // Разбор — на том же потоке, где `establish()` и старт движка: иначе
        // главный поток закрывает дескриптор, а рабочий в этот момент его
        // дублирует. `quitSafely` добирает поставленное в очередь.
        worker.post {
            Engine.stop()
            closeTunnel()
        }
        // Никакой `removeCallbacksAndMessages(null)`: двумя строками выше он
        // стирал бы только что поставленный разбор — движок оставался бы
        // живым с дубликом туннельного дескриптора, а `quitSafely` добирает
        // очередь сам.
        workerThread.quitSafely()
        // Уведомление об ошибке живёт после сервиса: снимать его — значит
        // оставить пользователя без причины отказа.
        if (!endedInFailure) StatusChannel.stop(this)
        super.onDestroy()
    }

    /**
     * Один ход через движок и обратно в интерфейс. Пустой ответ — «туннеля нет
     * или символ старой сборки»: экран обязан показать это как «не измерено», а
     * не как «утечек нет».
     */
    private fun fetchAndReply(id: Long, url: String?, timeoutMs: Int, maxBytes: Int) {
        val answer = if (url.isNullOrEmpty()) null else Engine.fetch(url, timeoutMs, maxBytes)
        // Причина отказа должна быть видна: экран про честность, а «движок не
        // ответил» без различения «символа нет», «туннеля нет» и «ход не вышел»
        // чинится вслепую.
        Log.i(TAG, "fetch ${url ?: "без url"} → " + when {
            answer == null -> "пусто (туннель не поднят или символа нет в libanemia.so)"
            answer.error != null -> "ошибка: ${answer.error}"
            else -> "${answer.ms} мс, ${answer.bytes} байт, тело ${answer.body.length}"
        })
        sendBroadcast(Intent(StatusChannel.ACTION_FETCH_REPLY).setPackage(packageName).apply {
            putExtra(StatusChannel.EXTRA_FETCH_ID, id)
            when {
                answer == null -> putExtra(StatusChannel.EXTRA_FETCH_ERROR, "движок не ответил")
                answer.error != null -> putExtra(StatusChannel.EXTRA_FETCH_ERROR, answer.error)
                else -> putExtra(StatusChannel.EXTRA_FETCH_BODY, answer.body)
            }
            putExtra(StatusChannel.EXTRA_FETCH_MS, answer?.ms ?: 0L)
            putExtra(StatusChannel.EXTRA_FETCH_BYTES, answer?.bytes ?: 0L)
        })
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        /** То же сообщение, что iOS кладёт в `providerConfiguration`. */
        const val EXTRA_SETUP = "app.anemia.extra.SETUP"
        const val EXTRA_DISCONNECT = "app.anemia.extra.DISCONNECT"
        /** Сброс статистики трафика: ряд принадлежит этому процессу, и
         * записанная из интерфейса пустота вернулась бы через полминуты. */
        const val EXTRA_RESET_TRAFFIC = "app.anemia.extra.RESET_TRAFFIC"

        /** «Интерфейс открыт, здоровье можно мерить» — аналог `wantsHealth`. */
        const val EXTRA_WATCH = "app.anemia.extra.WATCH"

        /** GET сквозь туннель по просьбе интерфейса; ответ — `FETCH_REPLY`. */
        const val ACTION_FETCH = "app.anemia.action.FETCH"

        private const val REFRESH_MS = 3_000L

        /** Тот же адрес, что у iOS (`EngineProbe.url`). */
        private const val HEALTH_URL = "https://www.gstatic.com/generate_204"
        private const val HEALTH_CHECK_MS = 30_000L

        /** 4 с вместо iOS-ных 8 при пороге «медленнее 3 с» — вердикт тот же
         * (всё, что дольше трёх секунд, брак в обеих формулировках), а держать
         * рабочий поток, а значит и отключение, дольше четырёх секунд незачем. */
        private const val HEALTH_TIMEOUT_MS = 4_000

        /** Раз в минуту сверить, что живой выход ещё в списке. */
        private const val LISTING_CHECK_MS = 60_000L

        /** Сколько тиков подряд интерфейс должен пропасть, чтобы счесть туннель
         * снятым: один пропуск — это гонка снятия и создания, а не обрыв. */
        private const val TUNNEL_MISS_LIMIT = 2
        private const val TAG = "Anemia"

        /** Потолки ожидания: снятия старого интерфейса и появления нового.
         * 2 с на новый интерфейс однажды не хватило на эмуляторе (отказ
         * «Интерфейс туннеля не появился» при поднявшемся через 4 с tun0), и
         * это ложный отказ на ровно том месте, где лестница ещё не заведена. */
        private const val TUNNEL_GONE_MS = 4_000L
        private const val TUNNEL_UP_MS = 4_000L
        private const val POLL_MS = 100L

        /** Имя интерфейса туннеля. `tunl0` и `ip6tnl0` живут в системе всегда. */
        private val TUNNEL_NAME = Regex("tun\\d+")

        /**
         * Куча Go под мягким лимитом. На iOS он считается из доступного
         * расширения и зажат 16–40 МБ — там за превышением стоит убийство
         * процесса; здесь такой оценки нет, и 64 МБ выбрано по другому
         * основанию: пустой xray занимает единицы, а lowmemorykiller смотрит на
         * RSS процесса, в котором больше ничего не живёт.
         */
        private const val MEMORY_LIMIT_BYTES = 64L shl 20
    }
}
