package app.anemia.data

import android.os.SystemClock
import app.anemia.core.AtomicWrite
import app.anemia.core.Json
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.max
import kotlin.math.min

/**
 * Порт `Sources/LoaderCore/SpeedTester.swift` + `iOS/Anemia/SpeedTest.swift`:
 * латентность, download и upload по тому маршруту, куда идёт трафик процесса,
 * то есть через туннель, когда он поднят.
 *
 * Числа взяты у Swift один в один, потому что сравнимые показания двух
 * платформ — это и есть цель:
 *  - латентность — медиана пяти маленьких запросов по одномуkeep-alive,
 *    первый (он же поднимает соединение) не считается;
 *  - каждое направление — до 10 с или пока не уйдёт бюджет (150 МБ вниз,
 *    75 МБ вверх), тремя потоками: один TCP-стрим редко заполняет канал,
 *    тем более через туннель;
 *  - итог считается от «прогретой» отметки (после первой секунды), а не с нуля:
 *    разгон TCP иначе выглядел бы как медленный канал;
 *  - живой курс — сглаживание `live·0,6 + rate·0,4`, как в `measure`.
 *
 * Формулы не закреплены эталоном: их можно сверить только живым замером
 * (локальный сервер с известной скоростью), и этот замер сделан на эмуляторе —
 * см. Android/README.md.
 */
class SpeedTester(private val endpoints: Endpoints = Endpoints()) {

    data class Endpoints(
        val base: String = "https://speed.cloudflare.com",
        /** Один запрос вниз: размер ответа в байтах. */
        val chunkBytes: Int = 50_000_000,
    )

    class Limits(
        val windowMs: Long = 10_000,
        val downloadBudget: Long = 150_000_000,
        val uploadBudget: Long = 75_000_000,
        val streams: Int = 3,
    )

    /** `SpeedTester.Result` */
    data class Result(val latency: Int?, val download: Double, val upload: Double?)

    /** Куда и с какой скоростью идёт текущий замер — то же, что `Event` у Swift. */
    enum class Direction { LATENCY, DOWNLOAD, UPLOAD }

    class Cancelled : InterruptedException()

    @Volatile var cancelled: AtomicBoolean = AtomicBoolean(false)

    fun run(limits: Limits = Limits(), events: (Direction, Double, Boolean) -> Unit): Result {
        events(Direction.LATENCY, 0.0, false)
        val latency = measureLatency() ?: throw IllegalStateException("Сервер теста не ответил")
        events(Direction.LATENCY, latency.toDouble(), true)
        val download = measure(upload = false, limits, events)
        events(Direction.DOWNLOAD, download, true)
        val upload = runCatching { measure(upload = true, limits, events) }.getOrNull()
        if (upload != null) events(Direction.UPLOAD, upload, true)
        return Result(latency, download, upload)
    }

    /** Медиана пяти ответов нулевого размера по одному соединению. */
    private fun measureLatency(): Int? {
        val url = "${endpoints.base}/__down?bytes=0"
        val times = ArrayList<Long>()
        for (attempt in 0 until 6) {
            if (cancelled.get()) throw Cancelled()
            val started = SystemClock.elapsedRealtime()
            // Одно keep-alive соединение на все шесть: Swift меряет латентность
            // так, а `Connection: close` превратил бы медиану пяти прогретых
            // ответов в медиану шести рукопожатий.
            //
            // Таймаут — восемь секунд, как `timeoutInterval: 8` у Swift, а не
            // тридцать из общего `open`: на чёрной дыре шесть попыток по полминуты
            // заняли бы полторы минуты, и «Остановить» отозвалось бы только после
            // них — `Cancelled` проверяется между попытками.
            val code = runCatching { request(url, keepAlive = true) }.getOrNull()
            if (code == null) return null
            if (attempt > 0) times.add(SystemClock.elapsedRealtime() - started)
        }
        times.sort()
        return if (times.isEmpty()) null else times[times.size / 2].toInt()
    }

    /**
     * Одно направление несколькими потоками; счётчик байтов общий, живой курс
     * считается раз в 250 мс, как в Swift.
     */
    private fun measure(upload: Boolean, limits: Limits, events: (Direction, Double, Boolean) -> Unit): Double {
        val bytes = AtomicLong(0)
        val failure = AtomicReference<Exception?>()
        val stop = AtomicBoolean(false)
        // Потоки — демонические: `shutdownNow()` не рвёт блокирующий сокет, и
        // обычный пул держал бы три нити (с 25 МБ тела в каждой) до конца
        // `readTimeout` после того, как экран ушёл.
        val pool = Executors.newFixedThreadPool(max(limits.streams, 1)) { runnable ->
            Thread(runnable, "speed-stream").apply { isDaemon = true }
        }
        val url = if (upload) "${endpoints.base}/__up"
        else "${endpoints.base}/__down?bytes=${endpoints.chunkBytes}"
        val payload = if (upload) ByteArray(25_000_000) else null
        val started = SystemClock.elapsedRealtime()
        repeat(max(limits.streams, 1)) {
            pool.execute {
                while (!stop.get() && !cancelled.get()) {
                    val moved = runCatching { transfer(url, upload, payload, bytes, stop) }
                        .onFailure { error -> if (error !is Cancelled) failure.compareAndSet(null, error as? Exception) }
                        .getOrDefault(0L)
                    // Ответ дошёл до конца — поток берёт следующий, пока окно
                    // и бюджет не кончились (Cloudflare отдаёт не больше 50 МБ).
                    if (moved == 0L || stop.get()) break
                }
            }
        }
        val budget = if (upload) limits.uploadBudget else limits.downloadBudget
        var live = 0.0
        var previous = (started to 0L)
        var warm: Pair<Long, Long>? = null
        try {
            while (SystemClock.elapsedRealtime() - started < limits.windowMs && bytes.get() < budget) {
                if (cancelled.get()) throw Cancelled()
                Thread.sleep(250)
                if (failure.get() != null && bytes.get() == 0L) break
                val now = SystemClock.elapsedRealtime()
                val total = bytes.get()
                val elapsed = max(now - previous.first, 50L) / 1000.0
                // `max(0, …)`: поток, которому сервер отказал, снимает свои байты из
            // общего счётчика (см. `transfer`), и разница двух наблюдений
            // может уйти в минус — экран показал бы «-8 Мбит/с» как измерение.
            val rate = max((total - previous.second) * 8.0 / elapsed, 0.0)
                live = if (live == 0.0) rate else live * 0.6 + rate * 0.4
                events(if (upload) Direction.UPLOAD else Direction.DOWNLOAD, live, false)
                previous = now to total
                if (warm == null && now - started >= 1_000) warm = now to total
            }
        } finally {
            // Без этого отказа ниже цикла (исключение в `events`, прерванный
            // `sleep`) потоки оставались крутиться до конца окна: `stop` ставят
            // только нормальные выходы.
            stop.set(true)
            pool.shutdownNow()
        }
        val total = bytes.get()
        if (total == 0L) {
            throw failure.get() ?: IllegalStateException("Сервер теста не ответил")
        }
        val from = warm ?: (started to 0L)
        val seconds = max((SystemClock.elapsedRealtime() - from.first) / 1000.0, 0.25)
        // Итог тоже не бывает отрицательным: «прогретая» отметка могла быть
        // снята до того, как отказавший поток вернул свои байты обратно.
        return max((total - from.second) * 8.0 / seconds, 0.0)
    }

    /**
     * Один ход направления: считает байты, возвращается при `stop`.
     *
     * Байты засчитываются только если сервер ответ принял (2xx): отказ с кодом
     * 4xx/5xx означает, что ушли они впустую, а «скорость» из них — цифра,
     * которой не было. Отдельно это важно для загрузки: `inputStream` на отказ
     * бросает, поэтому код надо читать до тела, иначе проверка статуса была бы
     * недостижима.
     */
    private fun transfer(url: String, upload: Boolean, payload: ByteArray?, bytes: AtomicLong, stop: AtomicBoolean): Long {
        val connection = open(url, if (upload) "POST" else "GET", keepAlive = false, readTimeoutMs = BULK_TIMEOUT_MS)
        var counted = 0L
        var accepted = false
        try {
            var sent = 0L
            if (payload != null) {
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/octet-stream")
                connection.setFixedLengthStreamingMode(payload.size)
                connection.outputStream.use { output ->
                    // По чанкам, а не одним `write(payload)`: потоковый режим
                    // блокируется на сокете, и байты считаются по мере ухода, а
                    // не в момент, когда их приняло ядро.
                    var offset = 0
                    while (offset < payload.size && !stop.get() && !cancelled.get()) {
                        val size = min(CHUNK, payload.size - offset)
                        output.write(payload, offset, size)
                        output.flush()
                        offset += size
                        bytes.addAndGet(size.toLong())
                        counted += size
                        sent += size
                    }
                }
                if (sent < payload.size) return sent
            }
            val code = connection.responseCode
            accepted = code in 200..299
            if (!accepted) {
                // Читаем `errorStream`, а не `inputStream`: на отказе второй
                // бросает, и настоящий текст ответа терялся бы вместе с ним.
                // `readNBytes` для этого не берётся — он с API 33, а сборка
                // начинается с 28.
                runCatching {
                    connection.errorStream?.use { input ->
                        val skip = ByteArray(MAX_ERROR_BODY)
                        var got = 0
                        while (got < MAX_ERROR_BODY) {
                            val read = input.read(skip, got, MAX_ERROR_BODY - got)
                            if (read < 0) break
                            got += read
                        }
                    }
                }
                failure("HTTP $code")
            }
            val moved = connection.inputStream.use { input ->
                val buffer = ByteArray(CHUNK)
                var sum = 0L
                while (!stop.get() && !cancelled.get()) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    sum += read
                    bytes.addAndGet(read.toLong())
                    counted += read
                }
                sum
            }
            return sent + moved
        } catch (error: Exception) {
            // Ответ не принят — снятые байты были не скоростью, а трафиком в
            // никуда. Что дошло под 2xx, остаётся в счётчике: те байты прошли.
            if (!accepted && counted != 0L) bytes.addAndGet(-counted)
            throw error
        } finally {
            connection.disconnect()
        }
    }

    private fun failure(message: String): Nothing = throw IllegalStateException(message)

    private fun request(url: String, keepAlive: Boolean): Int? {
        val connection = open(url, "GET", keepAlive, readTimeoutMs = LATENCY_TIMEOUT_MS)
        try {
            val code = connection.responseCode
            connection.inputStream.use { input ->
                val buffer = ByteArray(8 * 1024)
                while (input.read(buffer) >= 0) { /* ответ читаем целиком */ }
            }
            return if (code in 200..299) code else null
        } catch (error: Exception) {
            return null
        } finally {
            connection.disconnect()
        }
    }

    /**
     * `keepAlive = false` — чтобы пул сокетов JVM не переиспользовал соединение,
     * проросшее из другого состояния VPN: после подъёма или падения туннеля
     * замер обязан идти по новому маршруту, как по `.ephemeral` на iOS.
     */
    private fun open(url: String, method: String, keepAlive: Boolean, readTimeoutMs: Int): HttpURLConnection =
        (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = 8_000
            readTimeout = readTimeoutMs
            useCaches = false
            instanceFollowRedirects = false
            if (!keepAlive) setRequestProperty("Connection", "close")
        }

    companion object {
        /** Размер чанка: им же меряется и отдача, и приём. */
        private const val CHUNK = 64 * 1024

        /** Латентность: `timeoutInterval: 8` у Swift. */
        private const val LATENCY_TIMEOUT_MS = 8_000

        /** Направления: `timeoutInterval: 30` у Swift. */
        private const val BULK_TIMEOUT_MS = 30_000

        /** Сколько читать из отказного ответа — он нужен для лога, а не для скорости. */
        private const val MAX_ERROR_BODY = 8 * 1024
    }
}

/**
 * Состояние экрана вокруг [SpeedTester]: фаза, живой курс для циферблата и
 * последние десять замеров на диске. Порт `iOS/Anemia/SpeedTest.swift`.
 *
 * Сервер, через который реально прошли байты, читается в *конце* замера: туннель
 * мог упасть на середине, и запись обязана сказать «Без VPN», а не «Через VPN».
 */
class SpeedTest(
    private val file: java.io.File,
    private val endpoints: SpeedTester.Endpoints = SpeedTester.Endpoints(),
) {
    enum class Phase { IDLE, LATENCY, DOWNLOAD, UPLOAD, DONE, FAILED }

    data class Result(
        val at: Long,
        val server: String?,
        val latency: Int?,
        val download: Double,
        val upload: Double?,
    )

    @Volatile var phase: Phase = Phase.IDLE
        private set
    @Volatile var latency: Int? = null
        private set
    @Volatile var download: Double? = null
        private set
    @Volatile var upload: Double? = null
        private set
    @Volatile var live: Double = 0.0
        private set
    @Volatile var failure: String? = null
        private set
    @Volatile var history: List<Result> = load()
        private set

    /**
     * Кто сейчас несёт трафик — экран передаёт провайдера, а не строку.
     * Пишется с главного потока, читается с потока замера: без отметки второй
     * поток мог увидеть провайдера предыдущей `MainActivity`.
     */
    @Volatile var serverProvider: () -> String? = { null }

    private val tester = AtomicReference<SpeedTester?>()

    /** Номер текущего замера: отмена не останавливает сокет мгновенно. */
    private val round = AtomicLong(0)

    val isRunning: Boolean
        get() = phase == Phase.LATENCY || phase == Phase.DOWNLOAD || phase == Phase.UPLOAD

    fun start(onChanged: () -> Unit) {
        if (isRunning) return
        // Один атомарный шаг: `incrementAndGet()` отдельно и `get()` отдельно
        // позволили бы второму потоку сдвинуть номер между ними, и круг писал бы
        // под чужой отметкой.
        val mine = round.incrementAndGet()
        latency = null
        download = null
        upload = null
        live = 0.0
        failure = null
        phase = Phase.LATENCY
        val engine = SpeedTester(endpoints)
        tester.set(engine)
        onChanged()
        val thread = Thread({ finish(mine, engine, onChanged) }, "speed-test")
        thread.isDaemon = true
        thread.start()
    }

    fun stop() {
        tester.getAndSet(null)?.cancelled?.set(true)
        round.incrementAndGet()
        if (!isRunning) return
        live = 0.0
        // Не `IDLE`: экран на «Готово» имеет право только после завершённого
        // круга, а здесь остались цифры из оборванного — считать их итогом
        // значит показать несделанное сделанным.
        failure = "замер остановлен"
        phase = Phase.FAILED
    }

    private fun finish(mine: Long, engine: SpeedTester, onChanged: () -> Unit) {
        try {
            val result = engine.run { direction, value, measured ->
                if (mine != round.get()) return@run
                when {
                    measured && direction == SpeedTester.Direction.LATENCY -> latency = value.toInt()
                    measured && direction == SpeedTester.Direction.DOWNLOAD -> {
                        download = value; live = 0.0
                    }
                    measured -> upload = value
                    direction == SpeedTester.Direction.LATENCY -> phase = Phase.LATENCY
                    direction == SpeedTester.Direction.DOWNLOAD -> {
                        phase = Phase.DOWNLOAD; live = value
                    }
                    else -> {
                        phase = Phase.UPLOAD; live = value
                    }
                }
                onChanged()
            }
            if (mine != round.get()) return
            latency = result.latency
            download = result.download
            upload = result.upload
            live = 0.0
            phase = Phase.DONE
            record(Result(System.currentTimeMillis(), serverProvider(), result.latency,
                           result.download, result.upload))
        } catch (error: SpeedTester.Cancelled) {
            if (mine == round.get()) {
                live = 0.0
                phase = Phase.IDLE
            }
        } catch (error: InterruptedException) {
            if (mine == round.get()) {
                live = 0.0
                phase = Phase.IDLE
            }
        } catch (error: Exception) {
            if (mine != round.get()) return
            live = 0.0
            failure = "Сервер теста не ответил: ${error.message}"
            phase = Phase.FAILED
        }
        tester.compareAndSet(engine, null)
        onChanged()
    }

    private fun record(result: Result) {
        val kept = (listOf(result) + history).take(10)
        history = kept
        write(kept)
    }

    private fun load(): List<Result> = runCatching {
        val root = Json.parse(file.readText()) as? List<*> ?: return@runCatching emptyList()
        root.mapNotNull { item ->
            val entry = item as? Map<*, *> ?: return@mapNotNull null
            val download = entry["download"] as? Double ?: return@mapNotNull null
            Result(
                at = (entry["date"] as? Double)?.toLong() ?: return@mapNotNull null,
                server = entry["server"] as? String,
                latency = (entry["latency"] as? Double)?.toInt(),
                download = download,
                upload = entry["upload"] as? Double,
            )
        }
    }.getOrDefault(emptyList())

    private fun write(results: List<Result>) {
        // Общий атомарный писец из `:core`: полдокумента вместо истории замеров
        // здесь так же неудобно, как в состоянии, и 0600 прилагается.
        runCatching {
            AtomicWrite.write(file, Json.write(arrayOf(results)).toByteArray(Charsets.UTF_8))
        }
    }

    private fun arrayOf(results: List<Result>): List<Any?> = results.map {
        linkedMapOf<String, Any?>(
            "date" to it.at.toDouble(),
            "server" to it.server,
            "latency" to it.latency,
            "download" to it.download,
            "upload" to it.upload,
        )
    }

    companion object {
        const val FILE = "speed.json"
    }
}
