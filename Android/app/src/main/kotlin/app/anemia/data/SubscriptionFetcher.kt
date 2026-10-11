package app.anemia.data

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import android.os.SystemClock

/**
 * Сетевая половина `AppState.refresh(_:)`: эфемерная сессия с таймерами 20/30,
 * `User-Agent` панели и правилом «не-2xx — это отказ загрузки, а не пустой
 * список серверов».
 *
 * Тексты ошибок оставлены английскими, как в macOS: они доходят до пользователя
 * в одном и том же месте двух платформ, и расхождение заметил бы он, а не мы.
 * Хвост после «Fetch failed: » — платформенный: `URLError.localizedDescription`
 * и сообщение `HttpURLConnection` совпадать не могут по построению.
 */
object SubscriptionFetcher {
    /** Большинство панелей (3x-ui, Marzban, RealityEZPZ) пускают только известные клиенты. */
    const val USER_AGENT = "v2rayN/6.26"

    private const val REQUEST_TIMEOUT_MS = 20_000
    private const val RESOURCE_TIMEOUT_MS = 30_000
    private const val MAX_REDIRECTS = 5

    /**
     * Потолок ответа. На macOS его нет, но там тело читает Foundation; на
     * телефоне страница перехватившей сеть сети (captive portal) или зеркало с
     * мегабайтами мусора не должны стоить процессу памяти.
     */
    private const val MAX_BYTES = 8L shl 20

    class Response(val status: Int, val body: String, val headers: Map<String, String>)

    /** То, что Swift показывает как «Fetch failed: …» / «Bad subscription URL». */
    class FetchError(message: String) : Exception(message)

    fun fetch(text: String): Response {
        val url = runCatching { URL(text) }.getOrNull()
            ?: throw FetchError("Bad subscription URL")
        if (url.protocol !in setOf("http", "https")) throw FetchError("Bad subscription URL")
        val deadline = SystemClock.elapsedRealtime() + RESOURCE_TIMEOUT_MS
        var location = url
        var hop = 0
        while (true) {
            val response = attempt(location, deadline)
            if (response.status !in setOf(301, 302, 303, 307, 308)) return response
            // HTTP-заголовки регистронезависимы, а `headerFields` сохраняет то
            // написание, что пришло по проводам: у http/2 это «location».
            val next = response.headers.entries.firstOrNull { it.key.equals("location", true) }?.value
                ?: throw FetchError("Fetch failed: redirect without a target")
            val target = runCatching { URL(location, next) }.getOrNull()
                ?: throw FetchError("Fetch failed: bad redirect URL")
            // Падение с https на http — это не переадресация, а снятие защиты:
            // панель, которую увидели по TLS, не должна продолжаться открытым
            // текстом. Обратный ход (http → https) оставляем: он безобиден.
            if (location.protocol == "https" && target.protocol == "http") {
                throw FetchError("Fetch failed: redirect from https to http")
            }
            if (hop++ >= MAX_REDIRECTS) throw FetchError("Fetch failed: too many redirects")
            location = target
        }
    }

    private fun remainingMs(deadline: Long) = (deadline - SystemClock.elapsedRealtime()).coerceAtLeast(1L)

    private fun attempt(url: URL, deadline: Long): Response {
        val connection = (url.openConnection() as? HttpURLConnection)
            ?: throw FetchError("Bad subscription URL")
        try {
            connection.requestMethod = "GET"
            connection.instanceFollowRedirects = false
            // 20 с на запрос и 30 с на всю выдачу — как пара таймеров
            // `URLSession`: остаток общего бюджета не даёт одному медленному
            // зеркалу съесть весь круг автообновления.
            val budget = minOf(REQUEST_TIMEOUT_MS.toLong(), remainingMs(deadline)).toInt()
            connection.connectTimeout = budget
            connection.readTimeout = budget
            connection.useCaches = false
            connection.setRequestProperty("User-Agent", USER_AGENT)
            connection.setRequestProperty("Cache-Control", "no-cache")
            val status = connection.responseCode
            // `URLSession` бросает только на сетевом сбое: 403 на просроченном
            // токене и 502 на перезапускающейся панели приходят как ответ.
            val body = readBody(connection, status, deadline)
            return Response(status, body, headers(connection))
        } catch (error: FetchError) {
            throw error
        } catch (error: Exception) {
            throw FetchError("Fetch failed: ${error.message ?: error.javaClass.simpleName}")
        } finally {
            connection.disconnect()
        }
    }

    private fun readBody(connection: HttpURLConnection, status: Int, deadline: Long): String {
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
                if (SystemClock.elapsedRealtime() > deadline) throw FetchError("Fetch failed: timed out")
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

    private fun headers(connection: HttpURLConnection): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        for ((key, values) in connection.headerFields) {
            // У `HttpURLConnection` поля заголовков приходят со null-ключом.
            if (key == null) continue
            values?.firstOrNull()?.let { out[key] = it }
        }
        return out
    }
}
