package app.anemia.data

import android.util.Log
import app.anemia.core.ProxyServer
import app.anemia.core.ServerScoring
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID
import java.util.concurrent.Executors

/**
 * История замеров: `uuid сервера → ряд миллисекунд`, неудачная попытка — `-1`.
 * Ровно та же оболочка, что у `HistoryStore` на macOS (`schema` + `series`), и та
 * же схема `2` — это «время TLS-хэндшейка». Единица была «обычный TCP-коннект»,
 * на который система отвечала за 0 мс из своего fake-IP-туннеля; смешивать ряды
 * двух методик нельзя, они меряют разные величины, — файл с чужой схемой
 * выбрасывается, а не дописывается.
 *
 * Отдельный файл, а не поле в `state.json`: формат состояния общий со Swift, и
 * лишние ключи в нём означали бы расхождение контракта ради данных, которые
 * Swift всё равно не читает.
 */
class ProbeHistory(private val file: File) {

    /** Ряды по живым серверам; пустой список — очищает файл. */
    fun load(): Map<UUID, List<Float>> {
        val text = runCatching { file.readText() }.getOrNull() ?: return emptyMap()
        val root = runCatching { JSONObject(text) }.getOrNull() ?: return emptyMap()
        if (root.optInt("schema") != SCHEMA) return emptyMap()
        val series = root.optJSONObject("series") ?: return emptyMap()
        val out = LinkedHashMap<UUID, List<Float>>()
        for (key in series.keys()) {
            val id = parseId(key) ?: continue
            val row = series.optJSONArray(key) ?: continue
            val values = ArrayList<Float>(row.length())
            var junk = false
            for (i in 0 until row.length()) {
                // `JSONObject.NULL` — это «нет ответа», и он частью ряда остаётся:
                // по такому показанию сервер не хвалит `Scoring`, ровно как при
                // `-1`, который пишет сюда и круг (тот же код отказа, что у macOS:
                // «a failed probe is -1»). Откуда `null` в файле — неизвестно: ни
                // одна из трёх платформ его не пишет, остаётся считать его чужой
                // рукой и не выбрасывать из-за него весь ряд. А `optDouble` из
                // org.json превращает в 0.0 всё, что числом не является (строку,
                // `true`, вложенный объект): дописанный вручную файл дал бы ряд «0
                // мс» — лучшее из возможных показаний, — и «Лучший» выбрал бы по
                // нему сервер. Swift декодирует `[Double]` и отвергает документ
                // целиком, поэтому здесь отвергается ряд этого сервера.
                val cell = row.opt(i)
                if (cell === JSONObject.NULL) {
                    values.add(Float.NaN)
                } else if (cell is Number) {
                    values.add(cell.toFloat())
                } else {
                    junk = true
                }
            }
            if (junk) continue
            out[id] = values.takeLast(MAX_SAMPLES)
        }
        return out
    }

    fun save(history: Map<UUID, List<Float>>) {
        val series = JSONObject()
        for ((id, row) in history) {
            val array = JSONArray()
            row.takeLast(MAX_SAMPLES).forEach {
                array.put(if (it.isNaN()) JSONObject.NULL else it.toDouble())
            }
            series.put(id.toString().uppercase(), array)
        }
        val root = JSONObject()
        root.put("schema", SCHEMA)
        root.put("series", series)
        writeAtomically(root.toString())
    }

    private fun writeAtomically(text: String) {
        val directory = file.parentFile
        if (directory != null && !directory.isDirectory && !directory.mkdirs()) {
            throw IOException("Не удалось создать каталог ${directory.path}")
        }
        val temporary = File.createTempFile("${file.name}.", ".tmp", directory)
        try {
            temporary.writeText(text)
            try {
                Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE)
            } catch (error: AtomicMoveNotSupportedException) {
                // Редкий отказ ФС: обрыв здесь стоит одного ряда, а не списка.
                Files.move(temporary.toPath(), file.toPath())
            }
        } catch (error: Exception) {
            temporary.delete()
            throw error
        }
    }

    /** Тот же отказ принимать «0-0-0-0-0», что и в codec состояния. */
    private fun parseId(text: String): UUID? {
        if (!UUID_PATTERN.matches(text)) return null
        return runCatching { UUID.fromString(text) }.getOrNull()
    }

    companion object {
        const val SCHEMA = 2

        /** Потолок ряда: дальше старые отсчёты только утяжеляют статистику. */
        const val MAX_SAMPLES = 256
        private val UUID_PATTERN =
            Regex("[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
    }
}

/**
 * Круг замеров и всё, что из него видно экрану: задержка каждого сервера, рейтинг
 * по истории, лучший сервер. Правила замера — в [LatencyProber], скор —
 * `ServerScoring.rankingScore` из `:core`, та же функция, что у Swift, и тоже
 * закреплённая золотом.
 *
 * Модель kxc (нативный ранжер macOS) на Android не перенесена: «лучший»
 * считается эвристикой, а не обученной моделью — это осознанный пробел порта, а
 * не другое чтение тех же чисел.
 *
 * Файл истории читается и пишется на отдельном потоке: на macOS это detached-
 * задача «чтобы большой ряд не подвешивал интерфейс», и экран Android тем более
 * не должен ждать диска ни при запуске, ни по нажатию.
 */
class ProbeStore(private val history: ProbeHistory) {

    private val monitor = Any()
    private var series: MutableMap<UUID, MutableList<Float>> = mutableMapOf()
    private val pings = HashMap<UUID, Int?>()
    private var measuring: Set<UUID> = emptySet()

    /** true — круг идёт; экран блокирует кнопку по этому же признаку. */
    @Volatile var running = false
        private set

    /**
     * Поколение круга. Потоки прежнего круга могут его пережить — сокет по
     * требованию не бросается, — и обязаны молчать, когда круг уже другой:
     * иначе два круга дописывают одни и те же ряды, ровно то, от чего на macOS
     * защищает `isPinging`.
     */
    @Volatile private var generation = 0

    /** Один поток на чтение и запись: порядок сохраняется, главный не ждёт. */
    private val io = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "probe-io").apply { isDaemon = true }
    }

    /** Диск прочитан; до этого рядов на экране нет, и это честно. */
    @Volatile private var loaded = false

    init {
        io.execute {
            val stored = runCatching { history.load() }
                .onFailure { Log.w(TAG, "история не читается: ${it.message}") }
                .getOrNull() ?: emptyMap()
            synchronized(monitor) {
                for ((id, row) in stored) {
                    val live = series[id] ?: emptyList()
                    // Круг уже писал, пока диск дочитывался: присвоение файла
                    // вернуло бы ряд к состоянию на момент запуска и потеряло
                    // круг. `onResult` перечитывает `series` на каждый ответ, так
                    // что заменённый список он увидит.
                    if (live.isEmpty() && row.isNotEmpty()) series[id] = row.toMutableList()
                    else if (live.isNotEmpty()) {
                        series[id] = mergedHistory(row, live).toMutableList()
                    }
                }
                loaded = true
            }
        }
    }

    /**
     * Ряд после дочитки диска: история встаёт перед тем, что круг уже записал, и
     * потолок ряда держится на обоих концах. Функция отдельная потому, что сама
     * дочитка живёт на потоке и без круга не воспроизводится — проверить правило
     * иначе можно только на глаз.
     */
    internal fun mergedHistory(disk: List<Float>, live: List<Float>): List<Float> =
        (disk + live).takeLast(ProbeHistory.MAX_SAMPLES)

    fun pingOf(id: UUID): Int? = synchronized(monitor) { pings[id] }

    /** Различает «мерили и не дошли» с «ещё не мерили»: первое — отказ, второе —
     * прочерк; путать их на экране нельзя. */
    fun measured(id: UUID): Boolean = synchronized(monitor) { pings.containsKey(id) }

    fun isMeasuring(id: UUID): Boolean = synchronized(monitor) { id in measuring }

    /** Ряд сервера; пустой, пока история не прочитана. */
    fun samples(id: UUID): List<Float> = synchronized(monitor) {
        if (!loaded) emptyList() else series[id]?.toList() ?: emptyList()
    }

    /**
     * Запустить круг. false — не запустился: серверов нет или уже идёт другой
     * (два переплетённых круга искажают и джиттер, и потерю).
     *
     * Пока туннель поднят, проба идёт через него: клиент → текущий выход →
     * сервер. Такие отсчёты показываются, но в историю пишутся только для
     * подключённого сервера — двойной прыжок смещал рейтинг в его пользу, и
     * macOS делает ровно так же (`probeServers` в `AppState.swift`).
     * `tunnelLive` и `directServerId` приходят из широковещательного сообщения
     * сервиса ([app.anemia.vpn.StatusChannel]), а не из догадок экрана.
     */
    fun start(
        servers: List<ProxyServer>,
        tunnelLive: Boolean,
        directServerId: UUID? = null,
        onChanged: () -> Unit,
    ): Boolean {
        if (servers.isEmpty()) return false
        val mine: Int = synchronized(monitor) {
            if (running) return false
            running = true
            generation += 1
            measuring = servers.map { it.id }.toSet()
            generation
        }
        val roundIds = servers.map { it.id }.toSet()
        // Ряды серверов, которых больше нет в списке, не должны вечно жить в
        // файле: круг — естественное место, где это заметить.
        retain(servers)
        return try {
            Thread({
                try {
                    LatencyProber.round(servers = servers, cancelled = {
                        synchronized(monitor) { generation != mine }
                    }) { server, results ->
                        onResult(mine, server, results, roundIds, tunnelLive, directServerId, onChanged)
                    }
                } catch (error: Throwable) {
                    Log.w(TAG, "probe round failed: ${error.message}")
                } finally {
                    if (synchronized(monitor) { generation == mine }) {
                        synchronized(monitor) {
                            measuring = emptySet()
                            running = false
                        }
                        persist()
                        onChanged()
                    }
                }
            }, "probe").apply { isDaemon = true; start() }
            true
        } catch (error: Throwable) {
            // Потока не будет (потолок нитей процесса) — флаг обязан вернуться,
            // иначе замер умерает молча и навсегда.
            synchronized(monitor) {
                measuring = emptySet()
                running = false
            }
            Log.w(TAG, "круг не начался: ${error.message}")
            false
        }
    }

    private fun onResult(
        mine: Int,
        server: ProxyServer,
        results: List<Int?>,
        roundIds: Set<UUID>,
        tunnelLive: Boolean,
        directServerId: UUID?,
        onChanged: () -> Unit,
    ) {
        val alive = results.filterNotNull()
        val ping = if (alive.isEmpty()) null else average(alive)
        val keep = !tunnelLive || server.id == directServerId
        val fresh = synchronized(monitor) {
            if (generation != mine) {
                // Поздний ответ прежнего круга: чужому он не писало.
                false
            } else {
                pings[server.id] = ping
                measuring = measuring - server.id
                if (keep && server.id in roundIds) {
                    val row = series.getOrPut(server.id) { mutableListOf() }
                    results.forEach { row.add(it?.toFloat() ?: -1f) }
                    while (row.size > ProbeHistory.MAX_SAMPLES) row.removeAt(0)
                }
                true
            }
        }
        if (fresh) onChanged()
    }

    /** Отменить круг: экран закрылся, а тратить на него таймауты незачем. */
    fun cancel() {
        synchronized(monitor) {
            if (!running) return
            generation += 1
            measuring = emptySet()
            running = false
        }
        persist()
    }

    /** Лучший по рейтингу: минимум скорa среди тех, у кого был хотя бы успех. */
    fun bestServer(servers: List<ProxyServer>): ProxyServer? =
        servers.mapNotNull { server ->
            val row = samples(server.id)
            if (row.none { it >= 0 }) null else server to ServerScoring.rankingScore(row)
        }.minByOrNull { it.second }?.first

    /** Эвристика скорa для строки экрана; null — мерить ещё нечего. */
    fun score(id: UUID): Double? {
        val row = samples(id)
        if (row.isEmpty() || row.none { it >= 0 }) return null
        return ServerScoring.rankingScore(row)
    }

    /** Ряды мёртвых серверов не должны вечно раздувать файл. */
    fun retain(servers: List<ProxyServer>) {
        val ids = servers.map { it.id }.toSet()
        val changed = synchronized(monitor) {
            val seriesBefore = series.size
            val pingsBefore = pings.size
            series.keys.retainAll(ids)
            pings.keys.retainAll(ids)
            series.size != seriesBefore || pings.size != pingsBefore
        }
        if (changed) persist()
    }

    /** Снимок под замком, запись на `io`: главный поток диска не ждёт. */
    private fun persist() {
        val snapshot: Map<UUID, List<Float>> = synchronized(monitor) {
            series.mapValues { it.value.toList() }
        }
        io.execute {
            runCatching { history.save(snapshot) }
                .onFailure { Log.w(TAG, "история не сохранилась: ${it.message}") }
        }
    }

    private fun average(values: List<Int>): Int =
        values.sum().toDouble().div(values.size).let { kotlin.math.round(it).toInt() }

    private companion object {
        const val TAG = "anemia"
    }
}
