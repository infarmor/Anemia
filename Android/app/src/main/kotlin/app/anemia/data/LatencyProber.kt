package app.anemia.data

import app.anemia.core.Addresses
import app.anemia.core.Probing
import app.anemia.core.StreamSecurity
import app.anemia.core.ProxyServer
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.security.SecureRandom
import java.util.concurrent.Callable
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.ThreadFactory
import java.util.concurrent.TimeUnit
import javax.net.ssl.SNIHostName
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

/**
 * Порт `Sources/LoaderCore/LatencyProbe.swift`: та же методика — TLS-хэндшейк
 * целиком для серверов с TLS и один TCP-коннект для остальных. Правила, которые
 * решают «жив ли сервер» (что отправлять в SNI, когда сдаваться), живут в `:core`
 * (`Probing.target`, `Probing.collect`) и сверяются с Swift золотом; здесь ровно
 * то, чего ядро не умеет, — сокет.
 *
 * Сертификат не проверяется намеренно: замеряется время рукопожатия, а
 * маскирующие и самоподписанные сертификаты у таких серверов — норма. Отказ в
 * доверии стоил бы нам измерения, а не защиты: по этому соединению мы ничего не
 * передаём.
 */
object LatencyProber {

    /** Как на macOS: 5 попыток по 4 с, мёртвый сервер — отказ после двух промахов. */
    const val SAMPLES = 5
    const val TIMEOUT_MS = 4_000
    const val EARLY_ABORT_AFTER_FAILS = 2

    /** Сколько серверов лезем одновременно — больше значит SYN-шторм и самопомеху. */
    const val CONCURRENCY = 6

    /** Столько же, сколько попытка: дольше имя не ждём никогда. */
    private const val DNS_BUDGET_MS = 4_000L

    /**
     * Одна попытка: `null` — не дошло (отказ, таймаут или пустой ответ DNS),
     * иначе миллисекунды. Соединяемся с адресом сервера: имя SNI — это имя, а не
     * адрес, и подставлять одно вместо другого значит ломать хэндшейк.
     */
    fun ping(server: ProxyServer, timeoutMs: Int = TIMEOUT_MS, cancelled: () -> Boolean = { false }): Int? {
        if (cancelled()) return null
        val name = server.sni ?: server.host ?: server.address
        val dial = Probing.target(
            host = server.address,
            port = server.port,
            sni = name,
            tls = server.security != StreamSecurity.NONE,
        )
        if (!dial.usable) return null
        // Контекст собирается до старта отсчёта: на macOS `NWProtocolTLS.Options`
        // строятся до `DispatchTime.now()`, и инициализация conscrypt не должна
        // входить в измеренное время — иначе TLS-серверы систематически дороже,
        // чем их же TCP-соседи в том же ряду истории.
        val context = if (dial.tls) runCatching { tlsContext() }.getOrNull() ?: return null else null
        val started = System.nanoTime()
        val addresses = resolve(server.address, remainingMs(started, timeoutMs)) ?: return null
        for (address in addresses) {
            if (cancelled()) return null
            val left = remainingMs(started, timeoutMs)
            if (left <= 0) return null
            val socket = Socket()
            try {
                socket.connect(InetSocketAddress(address, dial.port), left)
                if (context == null) return report(started, timeoutMs)
                val ssl = context.socketFactory
                    .createSocket(socket, address.hostAddress, dial.port, true) as SSLSocket
                val handshakeBudget = remainingMs(started, timeoutMs)
                if (handshakeBudget <= 0) return null
                applyTlsOptions(ssl, dial.serverName)
                ssl.soTimeout = handshakeBudget
                ssl.startHandshake()
                return report(started, timeoutMs)
            } catch (error: Throwable) {
                // Не только IOException: обёртка TLS бросает и своё, а пропустить
                // такое — значит оставить сервер вовсе без записи («не мерили»
                // вместо «нет ответа») и без -1 в ряду.
                if (error is Error) throw error
            } finally {
                runCatching { socket.close() }
            }
        }
        return null
    }

    /**
     * Круг по списку: пул из `CONCURRENCY` воркеров, внутри сервера попытки идут
     * последовательно. `onServerDone` — чтобы экран обновлялся по мере
     * готовности, а не в конце. `cancelled` возвращает true, когда круг больше не
     * нужен: он обязан перестать тратить таймауты.
     */
    fun round(
        servers: List<ProxyServer>,
        samples: Int = SAMPLES,
        timeoutMs: Int = TIMEOUT_MS,
        concurrency: Int = CONCURRENCY,
        cancelled: () -> Boolean = { false },
        onServerDone: (ProxyServer, List<Int?>) -> Unit = { _, _ -> },
    ): Map<ProxyServer, List<Int?>> {
        val out = ConcurrentHashMap<ProxyServer, List<Int?>>()
        if (servers.isEmpty()) return out
        val pool = Executors.newFixedThreadPool(
            minOf(concurrency, servers.size),
            DaemonThreads("probe-worker"),
        )
        try {
            val futures = servers.map { server ->
                pool.submit(Callable {
                    val results = Probing.collect(
                        count = samples,
                        earlyAbortAfterFails = EARLY_ABORT_AFTER_FAILS,
                        cancelled = cancelled,
                        attempt = { _ -> if (cancelled()) null else ping(server, timeoutMs, cancelled) },
                    )
                    out[server] = results
                    onServerDone(server, results)
                })
            }
            // Сверху всё равно стоит потолок попытки, а DNS ограничен отдельно;
            // запас нужен на то, что поток уже был в разборе имени.
            val budget = (samples * timeoutMs.toLong()) + DNS_BUDGET_MS + 5_000L
            futures.forEach { runCatching { it.get(budget, TimeUnit.MILLISECONDS) } }
        } finally {
            pool.shutdownNow()
        }
        return out
    }

    /**
     * Разрешение имени внутри измеренного окна (так же делает `NWConnection`),
     * но с потолком: `connect` таймаутит только само соединение, а чёрная дыра в
     * DNS стоила бы бюджет попытки до того, как она начнётся. IPv4 вперёд — как
     * у движка (`dnsQueryStrategy = "UseIPv4"`): адрес IPv6 без работающего
     * маршрута иначе убивал бы все пять попыток подряд.
     */
    private fun resolve(host: String, budgetMs: Int): List<InetAddress>? {
        if (budgetMs <= 0) return null
        if (host.contains(':')) return runCatching { listOf(InetAddress.getByName(host)) }.getOrNull()
        if (Addresses.isIPv4(host)) return runCatching { listOf(InetAddress.getByName(host)) }.getOrNull()
        val work = DNS.submit(Callable {
            runCatching {
                val all = InetAddress.getAllByName(host).toList()
                all.filter { it.address.size == 4 } + all.filter { it.address.size != 4 }
            }.getOrNull()
        })
        return try {
            work.get(budgetMs.toLong(), TimeUnit.MILLISECONDS)?.takeIf { it.isNotEmpty() }
        } catch (error: Exception) {
            // Живой резолвер не прерывается, но ждать дольше бюджета мы не
            // обязаны. Пул ограничен именно поэтому: «новая нить на попытку»
            // при чёрной дыре в DNS оставала сотни висящих потоков на круг из
            // пятидесяти серверов, а очередь честно отвечает «не дошло».
            work.cancel(true)
            null
        }
    }

    /** Результат не переваливает за бюджет: на таймаут Swift отвечает nil. */
    private fun report(startedNanos: Long, timeoutMs: Int): Int? {
        val ms = elapsedMs(startedNanos)
        return if (ms > timeoutMs) null else ms
    }

    private fun elapsedMs(startedNanos: Long): Int =
        ((System.nanoTime() - startedNanos) / 1_000_000L).toInt()

    private fun remainingMs(startedNanos: Long, timeoutMs: Int): Int =
        timeoutMs - elapsedMs(startedNanos)

    private fun tlsContext(): SSLContext {
        val context = SSLContext.getInstance("TLS")
        context.init(null, arrayOf<TrustManager>(AcceptEverything), SecureRandom())
        return context
    }

    /**
     * Клиентский режим, имя и никакой проверки сертификата. Билетного кэша нет в
     * принципе: контекст на круг свой, резюмации взяться неоткуда, и все попытки
     * меряют одно и то же — полный хэндшейк, сравнимый джиттер.
     */
    private fun applyTlsOptions(ssl: SSLSocket, serverName: String?) {
        val params = ssl.sslParameters
        params.endpointIdentificationAlgorithm = null
        if (serverName != null && !serverName.contains(':') && !Addresses.isIPv4(serverName)) {
            // `SNIHostName` бросает на имя, которое не имя; без SNI хэндшейк всё
            // равно измеряется, просто не steer'ится на нужный сайт.
            runCatching { params.serverNames = listOf(SNIHostName(serverName)) }
        }
        ssl.sslParameters = params
        ssl.useClientMode = true
    }

    /** Не больше четырёх ждущих резолверов на процесс — см. [resolve]. */
    private val DNS = Executors.newFixedThreadPool(4, DaemonThreads("probe-dns"))

    /** Воркеры круга — daemon: переживший круг не держит процесс живым. */
    private class DaemonThreads(private val prefix: String) : ThreadFactory {
        override fun newThread(runnable: Runnable): Thread =
            Thread(runnable, prefix).apply { isDaemon = true }
    }

    /**
     * Lint ругается на собственный `X509TrustManager` — здесь это и есть
     * задумано: замер рукопожатия, а не канал для данных. Аннотация стоит
     * именно поэтому, а не чтобы убрать шум.
     */
    @android.annotation.SuppressLint("CustomX509TrustManager")
    private object AcceptEverything : X509TrustManager {
        override fun checkClientTrusted(
            chain: Array<java.security.cert.X509Certificate?>?,
            authType: String?,
        ) = Unit

        override fun checkServerTrusted(
            chain: Array<java.security.cert.X509Certificate?>?,
            authType: String?,
        ) = Unit

        override fun getAcceptedIssuers(): Array<java.security.cert.X509Certificate> = emptyArray()
    }
}
