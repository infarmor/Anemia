package app.anemia.data

import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.SystemClock
import android.util.Log
import app.anemia.core.LeakCheck
import app.anemia.core.trimSpaceLike
import app.anemia.vpn.engineFetch
import java.io.ByteArrayOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.URL
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/**
 * Порт `iOS/Anemia/LeakChecker.swift`: какой адрес видит интернет и кто
 * отвечает на запросы имён, плюс приговор над этим. Разбором ответов и
 * суждением занят `LeakCheck` из `:core` — его показания сверены со Swift
 * эталонами; здесь остаётся сеть, а в ней три хода, которые на Android нельзя
 * взять как на iOS.
 *
 *  - Адрес через туннель — обычный сокет: собственное приложение защищено
 *    собственным туннелем, его трафик идёт в `tun`.
 *  - Адрес провайдера — сокет, привязанный к сети *без* VPN
 *    (`NET_CAPABILITY_NOT_VPN`): на iOS это делает расширение туннеля, чьи
 *    сокеты идут мимо туннеля по построению. Здесь расширения нет, и без
 *    привязки «сравнение» было бы двойным измерением одного и того же хода.
 *  - IPv6: ответ обязан быть адресом IPv6. IPv4-ответ на просьбу IPv6 значит,
 *    что запрос ушёл по IPv4 — показать его в строке IPv6 значит спрятать
 *    настоящую утечку. То же правило легло в `LeakCheck.publicAddress` на Swift.
 *  - DNS: `InetAddress.getAllByName` — тот же резолвер, чем пользуются другие
 *    приложения, поэтому bash.ws показывает, кто реально отвечал.
 *
 * Потоки: замер живёт на своём потоке, результат отдаётся в `onChanged`;
 * `cancel()` нужен — без него ушедший экран оставлял бы висеть четыре хода по
 * 12 с каждый и один `requestNetwork`.
 */
class LeakChecker(
    private val connectivity: ConnectivityManager,
    private val endpoints: Endpoints = Endpoints(),
) {

    /**
     * Как на iOS: адреса сервисов — параметр, а не текст внутри кода.
     *
     * `ipDirect`/`traceDirect` нужны только проверке: в сети ход вне туннеля
     * отвечает *другой* адрес, потому что его видит другой наблюдатель, а не
     * потому что путь другой. Без отдельного адреса заглушка отвечала бы на
     * оба хода одинаково, и экран всегда говорил бы «трафик идёт мимо VPN».
     */
    data class Endpoints(
        val ip: String = "https://api-ipv4.ip.sb/geoip",
        val ipv6: String = "https://api-ipv6.ip.sb/geoip",
        val trace: String = "https://www.cloudflare.com/cdn-cgi/trace",
        val bashId: String = "https://bash.ws/id",
        /** Подстановка `{id}` — имя, по которому сервис ищет ответы. */
        val bashLeak: String = "https://bash.ws/dnsleak/test/{id}?json",
        val bashDomain: String = "bash.ws",
        val ipDirect: String? = null,
        val traceDirect: String? = null,
    )

    /** Порт `LeakChecker.Report`; null в `dns`/`ipv6` — «не было ответа», не «пусто». */
    data class Report(
        val checkedAt: Long,
        val serverId: UUID?,
        val exit: LeakCheck.IPInfo? = null,
        val direct: LeakCheck.IPInfo? = null,
        val ipv6: LeakCheck.IPInfo? = null,
        val dns: List<LeakCheck.DNSServer>? = null,
        val findings: List<LeakCheck.Finding> = emptyList(),
        /**
         * Сеть туннеля не дала привязать сокет: трафик самого приложения вынесен
         * из VPN (`ConfigApplier` → `addDisallowedApplication`), и Android
         * отказывает такому UID в выходе в туннель — замерено на устройстве,
         * `Binding socket to network N failed: EPERM`. Адрес выхода измерить
         * из этого процесса нельзя; врать «утечек нет» или валить на ip.sb
         * одинаково неправильно, поэтому экран называет причину.
         */
        val exitUnmeasurable: Boolean = false,
    ) {
        enum class Verdict { UNPROTECTED, FAILED, UNKNOWN, LEAKS, CLEAN, INCOMPLETE }

        val verdict: Verdict
            get() = when {
                exit == null -> Verdict.FAILED
                serverId == null -> Verdict.UNPROTECTED
                findings.isNotEmpty() -> Verdict.LEAKS
                direct == null -> Verdict.UNKNOWN
                dns == null -> Verdict.INCOMPLETE
                else -> Verdict.CLEAN
            }

        /** Тесты, которые не ответили, названные так же, как их зовёт экран. */
        val missing: List<String>
            get() = buildList {
                if (dns == null) add("DNS")
                if (ipv6 == null) add("IPv6")
            }

        val bypassed: Boolean get() = findings.contains(LeakCheck.Finding.TunnelBypassed)

        val ipv6Leak: LeakCheck.IPInfo?
            get() = findings.filterIsInstance<LeakCheck.Finding.Ipv6Leak>().firstOrNull()?.info

        val dnsLeak: List<LeakCheck.DNSServer>
            get() = findings.filterIsInstance<LeakCheck.Finding.DnsLeak>()
                .firstOrNull()?.servers ?: emptyList()

        /**
         * Выход в той же стране, что и провайдер. `findings` в этом случае
         * резолверы и IPv6 не сравнивает вовсе (правило в `LeakCheck.findings`),
         * значит и галочку «через VPN» рисовать нечем: экран обязан показать
         * «не проверено», а не тихое «чисто». То же поле есть у iOS.
         */
        val sameCountryAsHome: Boolean
            get() {
                val home = direct?.countryCode?.uppercase()
                val away = exit?.countryCode?.uppercase()
                return home != null && home == away
            }
    }

    @Volatile var report: Report? = null
        private set

    /** Что делает текущий замер; null — простоя нет. */
    @Volatile var step: String? = null
        private set

    /**
     * Состояние одного круга. Общих полей для этого не годилось: `cancel()` не
     * останавливает сокет мгновенно, а `run()` при возврате на экран сбрасывал
     * флаг отмены — и разоружал ещё живой прошлый круг. Тот дочитывал ходы сквозь
     * туннель (то есть чужой, уже не нужный, платный трафик) и поздним отказом
     * помечал «измерить нечем» уже новый отчёт.
     */
    private class Round(val id: Long) {
        val threads = java.util.concurrent.CopyOnWriteArrayList<Thread>()
        val unmeasured = AtomicBoolean(false)
        /** Поток круга прервали: показание не опубликовать, но и не «не измеримо». */
        @Volatile var interrupted = false
    }

    /**
     * Круг, который экран считает идущим. Отдельного флага «занято» здесь нет
     * ровно потому, что он расходился с действительностью: `cancel()` гасит круг
     * сразу (тот уже ничего не опубликует и не напишет — всё его состояние
     * принадлежит ему), а потоки его досматривают секунды. Ждать их означало бы
     * «ушёл и вернулся — и 20 с не могу запустить проверку», а плодить два
     * параллельных прогона теперь нечем: общего между кругами не осталось.
     */
    private val current = AtomicReference<Round?>()

    val isRunning: Boolean get() = current.get() != null

    /** Круг ещё актуален: его не отменили и не сменили новым. */
    private fun alive(round: Round) = round.id == generation.get()

    /** Поток, принадлежащий кругу: `cancel()` обязан дойти и до него. */
    private fun spawn(round: Round, name: String, body: () -> Unit): Thread {
        val thread = Thread(body, name)
        thread.isDaemon = true
        round.threads.add(thread)
        return thread
    }

    /** Отказ, который значит «ход не состоялся», а не «ответ не разобрался». */
    private class NoAnswer(message: String) : Exception(message)

    /**
     * Последний отчёт ещё про это соединение: тот же сервер, то же состояние
     * VPN, не старше получаса — как `isCurrent` на iOS.
     */
    fun isCurrent(tunnelUp: Boolean, sessionId: UUID?): Boolean {
        val report = report ?: return false
        val server = if (tunnelUp) sessionId else null
        return report.serverId == server &&
            SystemClock.elapsedRealtime() - report.checkedAt < CURRENT_MS
    }

    /**
     * Номер круга. `cancel()` не останавливает сокет мгновенно: поток ещё
     * досматривает ход до 12 с, и без номера он опубликовал бы старый отчёт
     * поверх нового — экран, открытый второй раз, показывал бы прошлое.
     */
    private val generation = AtomicLong(0)

    /**
     * `onChanged` приходит из рабочего потока: экран сам решает, как себя
     * перерисовать (в Compose — `view.post`).
     *
     * Один GET сквозь поднятый туннель делает движок: сокет самого приложения
     * идёт мимо VPN (`ConfigApplier` выносит его UID), а привязаться к сети
     * туннеля система не даёт — замерено, EPERM. Контекст нужен только на время
     * прогона (стартовать сервис и слушать ответ), поэтому он параметр, а не
     * поле: синглтон на процесс держали бы Activity.
     */
    fun run(
        context: android.content.Context,
        tunnelUp: Boolean,
        sessionId: UUID?,
        onChanged: () -> Unit,
    ) {
        val application = context.applicationContext
        val engine: ((String) -> String?)? = { url -> engineFetch(application, url)?.body }
        // Занятый круг — отказ: два тапа плодят два параллельных прогона одних и
        // тех же четырёх ходов. Проверка и запись идут с потока интерфейса (его
        // зовут кнопка экрана и `LaunchedEffect`), так что между ними никто не
        // влезает; атомарность здесь нужна читателю из рабочего потока.
        if (current.get() != null) return
        val round = Round(generation.incrementAndGet())
        current.set(round)
        step = "Узнаю адрес…"
        onChanged()
        val thread = spawn(round, "leak-check") { measure(round, tunnelUp, sessionId, engine, onChanged) }
        try {
            thread.start()
        } catch (error: Throwable) {
            // Нить не поднялась — слот занят быть не может, освобождать его
            // некому: `measure` никогда не исполнится.
            finish(round, onChanged)
            throw error
        }
    }

    private fun measure(
        round: Round,
        tunnelUp: Boolean,
        sessionId: UUID?,
        throughTunnel: ((String) -> String?)?,
        onChanged: () -> Unit,
    ) {
        val viaVpn = tunnelUp
        var fresh = Report(
            checkedAt = SystemClock.elapsedRealtime(),
            serverId = if (viaVpn) sessionId else null,
        )
        try {
            // Собственный сокет Anemia идёт *мимо* туннеля: `ConfigApplier`
            // выносит UID приложения из VPN (`addDisallowedApplication`), как на
            // iOS — трафик расширения. Значит адрес выхода, IPv6 и резолверы
            // надо просить у сети самого туннеля, иначе экран сравнил бы
            // провайдера с самим собой и всегда показал бы «трафик идёт мимо
            // VPN». Заявка живёт всё время всех трёх ходов: снятая раньше —
            // привязка сокетов не проходит (замерено: EPERM).
            val inside = if (viaVpn) hops(round, throughTunnel, null, onChanged)
            else hops(round, null, null, onChanged)
            if (viaVpn && inside == null) Log.w(TAG, "движок не ответил — адрес выхода не измерен")
            if (!alive(round)) {
                // Ранний выход обязан снять флаг круга: иначе `run()` навсегда
                // откажется запускать следующий прогон, и экран останется с
                // «идёт проверка» при уже мёртвых потоках.
                finish(round, onChanged)
                return
            }
            val direct = if (viaVpn) {
                withNetwork(round, outsideVpnRequest, ::isOutside) { network ->
                    address(
                        round,
                        endpoints.ipDirect ?: endpoints.ip,
                        endpoints.traceDirect ?: endpoints.trace,
                        // Вторым наблюдателем здесь именно сокет вне туннеля:
                        // движок для этого хода и не годится — он и есть туннель.
                        null, network, ipv6Asked = false,
                    )
                }
            } else null
            fresh = fresh.copy(
                exit = inside?.exit, ipv6 = inside?.ipv6,
                direct = if (viaVpn) direct else fresh.exit,
            )
            onChanged()
            fresh = fresh.copy(dns = inside?.dns)
            if (viaVpn) {
                fresh = fresh.copy(
                    findings = LeakCheck.findings(
                        exit = fresh.exit, direct = fresh.direct,
                        ipv6 = fresh.ipv6, dns = fresh.dns ?: emptyList(),
                    ),
                )
            }
        } catch (error: InterruptedException) {
            round.interrupted = true
        } catch (error: Throwable) {
            // Не `Exception`, а `Throwable`: `hops` поднимает до девяти потоков
            // за круг, и на пределе нитей JVM бросает `OutOfMemoryError` —
            // `Error`, который сквозь `catch (Exception)` ушёл бы мимо
            // освобождения слота, и синглтон на весь процесс остался бы
            // «идёт проверка» без единой живой проверки.
            //
            // Частичный отчёт полезнее пустого: `verdict` скажет, какой именно
            // тест молчал, вместо «проверка не удалась».
            Log.w(TAG, "leak check: ${error.message}")
        }
        try {
            if (!round.interrupted && alive(round)) {
                val unmeasurable = viaVpn && fresh.exit == null && round.unmeasured.get()
                report = fresh.copy(exitUnmeasurable = unmeasurable)
                // Одна строка с итогом: экран можно проверить и без клавиатуры, но
                // «проверка прошла» без неё ничем не доказать.
                val published = report
                Log.i(TAG, "leak: ${published?.verdict} выход=${published?.exit?.ip ?: "нет"} " +
                    "провайдер=${published?.direct?.ip ?: "нет"} ipv6=${published?.ipv6?.ip ?: "нет"} " +
                    "dns=${published?.dns?.size ?: "нет"} утечек=${published?.findings?.size ?: 0} " +
                    "не_измеримо=${published?.exitUnmeasurable}")
            }
        } finally {
            finish(round, onChanged)
        }
    }

    /**
     * Круг кончился: только теперь экран может запустить следующий. Подпись
     * гасится, лишь бы её не переселил новый круг (тот пишет свою), поток-
     * владелец снимается с дежурства, и `onChanged` зовётся всегда — даже если
     * отказ случился в самом конце.
     */
    private fun finish(round: Round, onChanged: () -> Unit) {
        if (alive(round)) step = null
        // Снимает с дежурства только самого себя: если экран уже запустил новый
        // круг, его слот трогать нельзя.
        current.compareAndSet(round, null)
        onChanged()
    }

    /**
     * Три хода, относящиеся к одной сети: адрес выхода, IPv6 и резолверы.
     *
     * Через движок они идут ПОСЛЕДОВАТЕЛЬНО, хотя у iOS это `async let`.
     * Причина не во вкусе, а в том, как устроен Android-ход: каждый запрос —
     * заявка процессу `:vpn`, а тот обслуживает fetch'и на одном рабочем
     * потоке (`AnemiaVpnService.worker`, и свести его в очередь нельзя —
     * `AnemiaFetch` держит экземпляр движка, который `stopLocked()` закрывает).
     * Два «параллельных» хода просто встают в одну очередь, а терпение
     * просителя (`timeoutMs + REPLY_GRACE_MS`, см. `TunnelFetch`) этого не
     * покрывает: второй возвращался null'ом, и здоровый выход показывался бы
     * как «не измерено». Голым сокетом (движка нет) ходить некому — там
     * параллельность настоящая и она остаётся.
     */
    private fun hops(
        round: Round,
        engine: ((String) -> String?)?,
        network: Network?,
        onChanged: () -> Unit,
    ): Hops? {
        // `AtomicReference`, а не ячейка массива: `join(потолок)` имеет право
        // вернуться до того, как поток допишет ответ, и немой чтение тогда не
        // обязано увидеть записанное — а «не увидел» экран трактует как
        // «сервер молчал».
        val exit = AtomicReference<LeakCheck.IPInfo?>()
        val six = AtomicReference<LeakCheck.IPInfo?>()
        if (engine != null) {
            exit.set(address(round, endpoints.ip, endpoints.trace, engine, network, ipv6Asked = false))
            if (!alive(round)) return null
            six.set(address(round, endpoints.ipv6, null, engine, network, ipv6Asked = true))
        } else {
            val threads = listOf(
                spawn(round, "leak-exit") {
                    exit.set(address(round, endpoints.ip, endpoints.trace, engine, network, ipv6Asked = false))
                },
                spawn(round, "leak-ipv6") {
                    six.set(address(round, endpoints.ipv6, null, engine, network, ipv6Asked = true))
                },
            )
            threads.forEach { it.start() }
            threads.forEach { it.join(HOP_GRACE_MS) }
        }
        if (!alive(round)) return null
        // Вторая фаза, как на iOS: без неё подпись стоит «Узнаю адрес…» все
        // полторы минуты, пока идут шесть резолвингов и отчёт bash.ws.
        step = "Проверяю DNS…"
        onChanged()
        return Hops(exit.get(), six.get(), dnsServers(round, engine, network))
    }

    private data class Hops(
        val exit: LeakCheck.IPInfo?,
        val ipv6: LeakCheck.IPInfo?,
        val dns: List<LeakCheck.DNSServer>?,
    )

    fun cancel() {
        // Круг снимается отметкой поколения: проверяющие потоки сравнивают свой
        // номер с текущим и на ближайшей границе (чтение чанка, ожидание ответа
        // движка, join резолвинга) уходят сами. `interrupt()` — попытка ускорить
        // это, а не единственный механизм: сокет он не разрывает.
        generation.incrementAndGet()
        // Слот освобождается сразу: круг после отметки поколения уже ничего не
        // опубликует и не напишет, а держать экран «занято» на те секунды, что
        // его потоки досматривают ход, значило бы «вернулся на экран и 20 с не
        // могу начать проверку».
        current.getAndSet(null)?.let { round ->
            round.threads.forEach { it.interrupt() }
        }
        // Подпись гасится сразу: человек ушёл с экрана.
        step = null
    }

    /**
     * Один замер адреса. `network` — сеть без VPN; null — как обычно, то есть
     * через туннель. IPv4-ответ на просьбу IPv6 отбрасывается: это не адрес
     * выхода, а след того, что запрос ушёл не тем семейством.
     */
    private fun address(
        round: Round,
        url: String,
        fallback: String?,
        engine: ((String) -> String?)?,
        network: Network?,
        ipv6Asked: Boolean,
    ): LeakCheck.IPInfo? {
        var reason: Throwable? = null
        val primary = runCatching {
            LeakCheck.parseIPSB(body(round, url, engine, network))
        }.onFailure { reason = it }.getOrNull()
        val info = primary ?: fallback?.let { second ->
            runCatching { LeakCheck.parseTrace(body(round, second, engine, network)) }
                .onFailure { reason = it }.getOrNull()
        }
        if (info == null) {
            // «Неизмеримо» — это ровно два случая: движок не ответил вовсе и
            // система отказала в привязке сокета. Мусорный ответ, отвал TLS или
            // слишком большой ответ — отказ *сервиса*, и объяснять его «сетью
            // туннеля, которая не дала сокет» значит показывать пользователю
            // диагноз, которого не было.
            if (reason is NoAnswer || reason?.message?.contains("EPERM") == true) {
                round.unmeasured.set(true)
            }
            // Без этой строки экран говорит «не ответили», а почему — молчит:
            // неподходящая сеть, отвал TLS или мусорный ответ одинаково
            // выглядят для пользователя и для того, кто это правит.
            Log.w(TAG, "адрес не получен ($url, сеть ${describe(network)}): ${reason?.message}")
            return null
        }
        if (ipv6Asked && !info.ip.contains(":")) {
            Log.i(TAG, "IPv6 проба получила IPv4 ${info.ip} — не засчитана")
            return null
        }
        return info
    }

    /**
     * Текст ответа: спрашивает движок, а если того нет — сокет, привязанный к
     * данной сети. Исключение наружу: зовущий различает «не было ответа» и
     * «ответ не разобрался» по нему же.
     */
    private fun body(round: Round, url: String, engine: ((String) -> String?)?, network: Network?): String {
        if (!alive(round)) throw InterruptedException("круг снят")
        if (engine == null) return read(round, url, network) { it }
        // Тихого отката на сокет здесь быть не может: прямой сокет этого
        // приложения идёт мимо VPN, и его ответ, выданный за адрес выхода,
        // был бы ровно той ложью, ради которой экран и делается.
        val text = runCatching { engine(url) }.getOrNull()
        if (text.isNullOrEmpty()) {
            throw NoAnswer("движок не ответил ($url)")
        }
        return text
    }

    /** Какая сеть досталась ходу: `null` — обычный путь процесса, `VPN` — туннель. */
    private fun describe(network: Network?): String {
        if (network == null) return "обычная"
        val capabilities = runCatching { connectivity.getNetworkCapabilities(network) }.getOrNull()
        val transports = listOf(
            NetworkCapabilities.NET_CAPABILITY_NOT_VPN to "не-VPN",
            NetworkCapabilities.NET_CAPABILITY_VALIDATED to "проверенная",
        ).filter { capabilities?.hasCapability(it.first) == true }.map { it.second }
        return if (transports.isEmpty()) "без флагов" else transports.joinToString("+")
    }

    /**
     * Заявка на сеть и ход под ней. Привязать сокет к сети можно, только пока
     * `NetworkCallback` зарегистрирован: снятая в `finally` до самого хода
     * давала `Binding socket to network N failed: EPERM` на ровном месте —
     * замеры на устройстве это и показали.
     */
    private fun <T> withNetwork(
        round: Round,
        request: NetworkRequest,
        expect: (NetworkCapabilities) -> Boolean,
        block: (Network) -> T?,
    ): T? {
        val latch = CountDownLatch(1)
        val found = AtomicReference<Network?>()
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                found.set(network)
                latch.countDown()
            }

            override fun onLost(network: Network) {
                if (found.get() == network) found.set(null)
            }

            override fun onUnavailable() = latch.countDown()
        }
        return try {
            val requested = runCatching { connectivity.requestNetwork(request, callback, NETWORK_WAIT_MS) }
            if (requested.isFailure) {
                Log.w(TAG, "requestNetwork не прошёл: ${requested.exceptionOrNull()?.message}")
                return null
            }
            if (!latch.await(NETWORK_WAIT_MS.toLong(), TimeUnit.MILLISECONDS)) return null
            val network = found.get() ?: return null
            // Проверка на месте: `NOT_VPN` в заявке — обещание системы, а не
            // факт. Привязаться к туннелю и назвать это «адресом провайдера»
            // значит всегда получать «утечки нет».
            val capabilities = runCatching { connectivity.getNetworkCapabilities(network) }.getOrNull()
            if (capabilities == null || !expect(capabilities)) {
                Log.w(TAG, "сеть $network не та, что просили")
                return null
            }
            if (!alive(round)) return null
            block(network)
        } finally {
            runCatching { connectivity.unregisterNetworkCallback(callback) }
        }
    }

    /** Заявка на интернет *вне* туннеля. */
    private val outsideVpnRequest: NetworkRequest = NetworkRequest.Builder()
        .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
        .build()

    private fun isOutside(capabilities: NetworkCapabilities) =
        capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)

    /**
     * DNS-тест bash.ws: имя выдаёт сам сервис, шесть запросов идут через
     * резолвер *той сети, о которой спрашиваем*, отчёт приходит с его
     * авторитативного сервера. `network = null` — когда туннеля нет.
     */
    private fun dnsServers(
        round: Round,
        engine: ((String) -> String?)?,
        network: Network?,
    ): List<LeakCheck.DNSServer>? {
        if (!alive(round)) return null
        val id = runCatching { trimSpaceLike(body(round, endpoints.bashId, engine, network)) }.getOrNull()
        if (id.isNullOrEmpty() || !id.all { it.isLetterOrDigit() }) return null
        // Те же шесть имён, что у iOS: один запрос резолвер мог кэшировать.
        // Спрашивать надо так, чтобы имя разобралось *внутри* проверяемого
        // пути: с движком — HTTP-ходом по самому имени (xray резолвит сам и
        // именно его резолвер видит bash.ws), без движка — резолвером данной
        // сети, а не процесса.
        // Просят они ровно одного — чтобы резолвер их увидел. iOS делает это
        // `withTaskGroup` одновременно; здесь способ зависит от того, кем спрашиваем
        // (см. ниже), потому что у движка очередь одна.
        // Шесть имён через движок тоже идут по очереди — по той же причине,
        // что и `hops`: в очереди процесса `:vpn` параллельные заявки только
        // отнимают друг у друга время ожидания, а тут важно, чтобы КАЖДЫЙ
        // запрос успел дойти до резолвера до того, как мы спросим bash.ws.
        // Голым резолвером (когда туннеля нет) просят одновременно.
        val deadline = SystemClock.elapsedRealtime() + DNS_PHASE_MS
        val names = (1..6).map { index -> "$index.$id.${endpoints.bashDomain}" }
        val asked = ArrayList<Thread>()
        if (engine != null) {
            for (name in names) {
                if (!alive(round) || SystemClock.elapsedRealtime() > deadline) break
                val one = spawn(round, "leak-dns") {
                    runCatching { engine("http://$name/") }
                }
                one.start()
                one.join(LOOKUP_GRACE_MS)
                asked.add(one)
            }
        } else {
            names.forEach { name ->
                val one = spawn(round, "leak-dns") {
                    runCatching {
                        if (!alive(round)) return@runCatching null
                        if (network != null) network.getAllByName(name) else InetAddress.getAllByName(name)
                    }
                }
                asked.add(one)
                one.start()
            }
            asked.forEach { it.join(LOOKUP_GRACE_MS) }
        }
        asked.forEach { if (it.isAlive) it.interrupt() }
        if (!alive(round)) return null
        val url = endpoints.bashLeak.replace("{id}", id)
        return runCatching { LeakCheck.parseBashWS(body(round, url, engine, network)) }.getOrNull()
    }

    /**
     * Чтение с потолком по размеру: ответ перехватившей сети страницы или
     * зеркало с мегабайтами мусора не должны стоить процессу памяти.
     * `Connection: close` — чтобы пул сокетов JVM не переиспользовал соединение,
     * проросшее из предыдущего состояния VPN (на iOS для этого `.ephemeral`).
     * Redirectы разрешены: ip.sb и bash.ws отвечают перенаправлением, и отказ
     * следовать ему показался бы пользователю «тест не ответил».
     */
    private fun <T> read(round: Round, url: String, network: Network?, parse: (String) -> T): T {
        val connection = (network?.openConnection(URL(url)) ?: URL(url).openConnection()) as HttpURLConnection
        try {
            connection.connectTimeout = TIMEOUT_MS
            connection.readTimeout = TIMEOUT_MS
            connection.instanceFollowRedirects = true
            connection.useCaches = false
            connection.setRequestProperty("Connection", "close")
            connection.setRequestProperty("User-Agent", "Anemia")
            if (connection.responseCode !in 200..299) throw IllegalStateException("HTTP ${connection.responseCode}")
            val body = connection.inputStream.use { input ->
                val out = ByteArrayOutputStream()
                val buffer = ByteArray(8 * 1024)
                var total = 0L
                while (true) {
                    if (!alive(round)) throw InterruptedException("круг снят")
                    val read = input.read(buffer)
                    if (read < 0) break
                    total += read
                    if (total > MAX_BYTES) throw IllegalStateException("ответ больше ${MAX_BYTES / 1024} КБ")
                    out.write(buffer, 0, read)
                }
                out.toString("UTF-8")
            }
            return parse(body)
        } finally {
            connection.disconnect()
        }
    }

    companion object {
        private const val TAG = "Anemia"

        /** Ход: 12 с, как два запроса bash.ws на iOS. */
        private const val TIMEOUT_MS = 12_000

        /**
         * Потолок ожидания двух параллельных ходов. Каждый ограничен таймаутом
         * движка (`12 с` плюс запас на ответ между процессами), а `join()` без
         * числа оставил бы круг висеть навсегда, если один из ходов не дойдёт, —
         * и экран не смог бы запустить следующий.
         */
        private const val HOP_GRACE_MS = 35_000L

        /** Сколько ждать сеть по запросу: туннель поднимается секунды. */
        private const val NETWORK_WAIT_MS = 8_000

        /**
         * Потолок ожидания резолвинга: сам ход ограничен таймаутом движка,
         * здесь — плюс запас на дорогу ответа между процессами.
         */
        private const val LOOKUP_GRACE_MS = 18_000L

        /**
         * Потолок всей DNS-фазы: шесть ходов по 15 с — это полторы минуты, а
         * экран ожидания столько не стоит. Перебрав потолок, круг честно
         * идёт спрашивать отчёт о том, что уже успело дойти.
         */
        private const val DNS_PHASE_MS = 60_000L
        private const val MAX_BYTES = 512L * 1024

        /** Сколько отчёт считается «про это соединение» — 30 минут, как на iOS. */
        private const val CURRENT_MS = 30 * 60 * 1000L
    }
}
