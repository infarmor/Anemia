package app.anemia.data

import android.os.SystemClock
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL

/**
 * Сетевая половина `AppState.refresh(_:)`: эфемерная сессия с таймерами 20/30,
 * `User-Agent` панели и правилом «не-2xx — это отказ загрузки, а не пустой
 * список серверов».
 *
 * Anemia's installation identifier is sent only to the original HTTPS origin.
 */
object SubscriptionFetcher {
    /** Большинство панелей (3x-ui, Marzban, RealityEZPZ) пускают только известные клиенты. */
    const val USER_AGENT = "v2rayN/6.26"

    private const val REQUEST_TIMEOUT_MS = 20_000
    private const val RESOURCE_TIMEOUT_MS = 30_000
    private const val MAX_REDIRECTS = 5
    private val redirectStatuses = setOf(301, 302, 303, 307, 308)

    /**
     * Потолок ответа. На macOS его нет, но там тело читает Foundation; на
     * телефоне страница перехватившей сеть сети (captive portal) или зеркало с
     * мегабайтами мусора не должны стоить процессу памяти.
     */
    private const val MAX_BYTES = 8L shl 20

    class Response(val status: Int, val body: String, val headers: Map<String, String>)

    /** То, что Swift показывает как «Fetch failed: …» / «Bad subscription URL». */
    class FetchError(message: String) : Exception(message)

    internal fun fetch(
        text: String,
        deviceId: () -> String? = { null },
        elapsedMs: () -> Long = SystemClock::elapsedRealtime,
        openConnection: (URL) -> HttpURLConnection? = { it.openConnection() as? HttpURLConnection },
    ): Response {
        val url = runCatching { URL(text) }.getOrNull()
            ?: throw FetchError("Bad subscription URL")
        if (url.protocol !in setOf("http", "https")) throw FetchError("Bad subscription URL")
        val deadline = elapsedMs() + RESOURCE_TIMEOUT_MS
        var hwid = if (url.protocol == "https") deviceId() else null
        var location = url
        var hop = 0
        while (true) {
            val response = attempt(location, deadline, hwid, elapsedMs, openConnection)
            if (response.status !in redirectStatuses) return response
            // HTTP-заголовки регистронезависимы, а `headerFields` сохраняет то
            // написание, что пришло по проводам: у http/2 это «location».
            val next = response.headers.entries.firstOrNull { it.key.equals("location", true) }?.value
                ?: throw FetchError("Fetch failed: redirect without a target")
            val target = runCatching { URL(location, next) }.getOrNull()
                ?: throw FetchError("Fetch failed: bad redirect URL")
            if (target.protocol !in setOf("http", "https")) throw FetchError("Fetch failed: bad redirect URL")
            // Падение с https на http — это не переадресация, а снятие защиты:
            // панель, которую увидели по TLS, не должна продолжаться открытым
            // текстом. Обратный ход (http → https) оставляем: он безобиден.
            if (location.protocol == "https" && target.protocol == "http") {
                throw FetchError("Fetch failed: redirect from https to http")
            }
            if (hop++ >= MAX_REDIRECTS) throw FetchError("Fetch failed: too many redirects")
            // Once a request leaves the provider's origin, even a redirect back
            // stays anonymous. Compare host and effective port without resolving DNS.
            if (!url.sameHttpsOrigin(target)) hwid = null
            location = target
        }
    }

    private fun URL.sameHttpsOrigin(target: URL): Boolean =
        protocol == "https" && target.protocol == "https" && host.equals(target.host, ignoreCase = true) &&
            effectivePort() == target.effectivePort()

    private fun URL.effectivePort(): Int = if (port == -1) defaultPort else port

    private fun attempt(
        url: URL,
        deadline: Long,
        hwid: String?,
        elapsedMs: () -> Long,
        openConnection: (URL) -> HttpURLConnection?,
    ): Response {
        val connection = openConnection(url)
            ?: throw FetchError("Bad subscription URL")
        try {
            connection.requestMethod = "GET"
            connection.instanceFollowRedirects = false
            // 20 с на запрос и 30 с на всю выдачу — как пара таймеров
            // `URLSession`: остаток общего бюджета не даёт одному медленному
            // зеркалу съесть весь круг автообновления.
            val budget = minOf(REQUEST_TIMEOUT_MS.toLong(), (deadline - elapsedMs()).coerceAtLeast(1L)).toInt()
            connection.connectTimeout = budget
            connection.readTimeout = budget
            connection.useCaches = false
            connection.setRequestProperty("User-Agent", USER_AGENT)
            connection.setRequestProperty("Cache-Control", "no-cache")
            if (hwid != null) {
                connection.setRequestProperty("x-hwid", hwid)
                connection.setRequestProperty("x-device-os", "Android")
            }
            val status = connection.responseCode
            val responseHeaders = connection.headerFields
            deviceRejection(responseHeaders)?.let { throw FetchError(it) }
            // `URLSession` бросает только на сетевом сбое: 403 на просроченном
            // токене и 502 на перезапускающейся панели приходят как ответ.
            val body = if (status in redirectStatuses) "" else readBody(connection, status, deadline, elapsedMs)
            return Response(status, body, headers(responseHeaders))
        } catch (error: FetchError) {
            throw error
        } catch (error: Exception) {
            throw FetchError("Fetch failed: ${error.javaClass.simpleName}")
        } finally {
            connection.disconnect()
        }
    }

    private fun readBody(connection: HttpURLConnection, status: Int, deadline: Long, elapsedMs: () -> Long): String {
        val stream = if (status >= 400) connection.errorStream else connection.inputStream
        val length = connection.contentLengthLong
        if (length > MAX_BYTES) throw FetchError("Fetch failed: response too large")
        val output = ByteArrayOutputStream()
        stream?.use { input ->
            val buffer = ByteArray(8 * 1024)
            while (true) {
                // Медленная капля (по байту на чтение) не должна держать
                // загрузку открытой дольше общего бюджета: readTimeout меряет
                // одно чтение, а не ответ целиком.
                if (elapsedMs() > deadline) throw FetchError("Fetch failed: timed out")
                val read = input.read(buffer)
                if (read < 0) break
                if (output.size() + read > MAX_BYTES) throw FetchError("Fetch failed: response too large")
                output.write(buffer, 0, read)
            }
        }
        // `String(data:encoding:.utf8)` в Swift на не-UTF-8 даёт nil, и дальше
        // идёт пустая строка. `String(bytes, UTF_8)` вместо этого заменяет
        // битые байты на U+FFFD — то есть тело-мусор мог импортироваться с
        // кракозябрами в именах вместо честного отказа.
        val decoder = Charsets.UTF_8.newDecoder()
            .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
            .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
        return runCatching { decoder.decode(java.nio.ByteBuffer.wrap(output.toByteArray())).toString() }
            .getOrDefault("")
    }

    private fun headers(fields: Map<String?, List<String>?>): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        for ((key, values) in fields) {
            // У `HttpURLConnection` поля заголовков приходят со null-ключом.
            if (key == null) continue
            values?.firstOrNull()?.let { out[key] = it }
        }
        return out
    }

    private fun deviceRejection(headers: Map<String?, List<String>?>): String? {
        fun isTrue(name: String): Boolean = headers.any { (key, value) ->
            key.equals(name, ignoreCase = true) &&
                value?.any { it.trim().equals("true", ignoreCase = true) } == true
        }
        return when {
            isTrue("x-hwid-not-supported") ->
                "Провайдер не получил идентификатор устройства. Проверьте HTTPS-ссылку подписки или обратитесь к провайдеру."
            isTrue("x-hwid-max-devices-reached") || isTrue("x-hwid-limit") ->
                "Достигнут лимит устройств подписки. Освободите место у провайдера."
            else -> null
        }
    }
}
