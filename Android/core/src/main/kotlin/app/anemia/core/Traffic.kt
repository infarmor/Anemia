package app.anemia.core

/**
 * Port of `Sources/LoaderCore/TrafficLedger.swift`: how much went through the
 * tunnel per day and per server, from a running engine's cumulative counters.
 *
 * The counters restart with every engine run, so a reading is only ever a
 * difference against the previous reading of the *same* run; the connected
 * seconds are the gap between two readings, capped at [TrafficLedger.MAX_STEP]
 * because a gap nobody was counting is not time in the tunnel.
 */
class TrafficLedger {

    data class Day(
        val id: String,
        var received: Long = 0,
        var sent: Long = 0,
        var time: Double = 0.0,
    ) {
        val total: Long get() = saturated(received, sent)
    }

    data class ServerTotal(
        val id: java.util.UUID,
        var name: String,
        var received: Long = 0,
        var sent: Long = 0,
        var lastUsed: Double = NEGATIVE_INFINITY_EPOCH,
    ) {
        val total: Long get() = saturated(received, sent)

        companion object {
            /** `Date.distantPast` as epoch seconds — what an unused server shows. */
            const val NEGATIVE_INFINITY_EPOCH = -62_135_769_600.0
        }
    }

    val days = LinkedHashMap<String, Day>()
    val servers = LinkedHashMap<java.util.UUID, ServerTotal>()
    private var lastRun: Pair<Double, Pair<Long, Long>>? = null
    private var lastReading: Double? = null

    /** Приватные для Swift поля — то, что [fromJson] восстанавливает из документа. */
    internal fun restore(run: Pair<Double, Pair<Long, Long>>?, reading: Double?) {
        lastRun = run
        lastReading = reading
    }

    /** One reading of a run's counters (bytes since `runStartedAt`). */
    fun record(
        runStartedAt: Double,
        received: Long,
        sent: Long,
        server: Pair<java.util.UUID, String>?,
        at: Double,
        timeZone: java.util.TimeZone,
    ) {
        var newReceived = received
        var newSent = sent
        val previous = lastRun
        if (previous != null && previous.first == runStartedAt) {
            newReceived = maxOf(received - previous.second.first, 0)
            newSent = maxOf(sent - previous.second.second, 0)
        }
        lastRun = runStartedAt to (received to sent)
        val step = lastReading?.let { minOf(maxOf(at - it, 0.0), MAX_STEP) } ?: 0.0
        lastReading = at

        val key = dayKey(at, timeZone)
        val day = days.getOrPut(key) { Day(key) }
        day.received += newReceived
        day.sent += newSent
        day.time += step

        if (server != null && newReceived + newSent > 0) {
            val total = servers.getOrPut(server.first) { ServerTotal(server.first, server.second) }
            total.name = server.second
            total.received += newReceived
            total.sent += newSent
            total.lastUsed = at
        }
        prune()
    }

    /** The engine stopped: the next reading starts a new connected stretch. */
    fun stopped() {
        lastReading = null
    }

    fun reset() {
        days.clear()
        servers.clear()
    }

    /** Drops the totals of servers that no longer exist. */
    fun forget(ids: Set<java.util.UUID>) {
        for (id in ids) servers.remove(id)
    }

    /** Keeps only the most recently used server totals, and the newest days. */
    private fun prune() {
        if (days.size > KEEP_DAYS) {
            val keep = days.keys.sorted().takeLast(KEEP_DAYS).toHashSet()
            days.keys.retainAll(keep)
        }
        if (servers.size > KEEP_SERVERS) {
            val keep = servers.values.sortedWith(newestFirst())
                .take(KEEP_SERVERS).map { it.id }.toHashSet()
            servers.keys.retainAll(keep)
        }
    }

    /** The last `count` days, oldest first, empty days filled in. */
    fun recentDays(count: Int, now: Double, timeZone: java.util.TimeZone): List<Day> =
        (count - 1 downTo 0).map { offset ->
            val key = dayKey(midnightOf(now, timeZone, -offset), timeZone)
            days[key] ?: Day(key)
        }

    fun today(now: Double, timeZone: java.util.TimeZone): Day {
        val key = dayKey(now, timeZone)
        return days[key] ?: Day(key)
    }

    /** The calendar month of `now`, summed. */
    fun month(now: Double, timeZone: java.util.TimeZone): Day {
        val prefix = dayKey(now, timeZone).take(7)
        val sum = Day(prefix)
        for (day in days.values.filter { it.id.startsWith(prefix) }) {
            sum.received += day.received
            sum.sent += day.sent
            sum.time += day.time
        }
        return sum
    }

    val topServers: List<ServerTotal>
        get() = servers.values.sortedWith(
            compareByDescending<ServerTotal> { it.total }.thenBy { it.name },
        )

    /** Тот же порядок, что у Swift: сравнявшиеся значения не должны переставляться. */
    internal fun newestFirst(): Comparator<ServerTotal> =
        compareByDescending<ServerTotal> { it.lastUsed }.thenBy { it.id.toString().uppercase() }

    /**
     * Документ в том же виде, что пишет `JSONEncoder` для `TrafficLedger`.
     * Две его особенности видно только по факту:
     *
     *  - даты — секунды от reference date Foundation (2001-01-01 UTC), а не от
     *    эпохи Unix; сдвиг проверяется третьим контуром (`verify-traffic.sh`),
     *    потому что на own-round-trip он не заметен вообще;
     *  - `servers` — словарь с UUID-ключами, а такой Foundation пишет плоским
     *    массивом «ключ, значение, ключ, значение», а не объектом.
     *
     * Ключи словарей пишутся в порядке вставки, у Swift — в порядке словаря,
     * поэтому сверяется каноническое значение, а не байты.
     */
    fun toJson(): String {
        val dayValues = LinkedHashMap<String, Any?>()
        for ((key, day) in days) {
            dayValues[key] = linkedMapOf(
                "id" to day.id,
                "received" to day.received,
                "sent" to day.sent,
                "time" to day.time,
            )
        }
        val serverValues = ArrayList<Any?>()
        for ((id, total) in servers) {
            // `uuidString` — заглавными, как печатает Foundation.
            val key = id.toString().uppercase()
            serverValues.add(key)
            serverValues.add(linkedMapOf(
                "id" to key,
                "name" to total.name,
                "received" to total.received,
                "sent" to total.sent,
                "lastUsed" to total.lastUsed - REFERENCE_EPOCH,
            ))
        }
        // Ключа нет совсем, а не `null`: `JSONEncoder` опущенный optional не
        // пишет, и «явно null» было бы другим документом — третья сверка
        // (`verify-traffic.sh`) перечитывает файл настоящим Swift-декодером, и
        // различать эти два состояния он умеет.
        val document = linkedMapOf<String, Any?>(
            "days" to dayValues,
            "servers" to serverValues,
        )
        lastRun?.let { (startedAt, bytes) ->
            document["lastRun"] = linkedMapOf(
                "startedAt" to startedAt - REFERENCE_EPOCH,
                "received" to bytes.first,
                "sent" to bytes.second,
            )
        }
        lastReading?.let { document["lastReading"] = it - REFERENCE_EPOCH }
        return Json.write(document)
    }

    companion object {
        /** `Date` без `dateEncodingStrategy`: секунды от 2001-01-01 UTC. */
        const val REFERENCE_EPOCH = 978_307_200.0

        /** Обратное к [toJson]; null — документ не читается, как `try?` на Swift. */
        fun fromJson(text: String): TrafficLedger? {
            val root = runCatching { Json.parse(text) }.getOrNull() as? Map<*, *> ?: return null
            val ledger = TrafficLedger()
            val days = root["days"] as? Map<*, *> ?: return null
            for ((key, value) in days) {
                val day = value as? Map<*, *> ?: return null
                val id = Json.string(day["id"]) ?: key as? String ?: return null
                ledger.days[id] = TrafficLedger.Day(
                    id = id,
                    received = whole(day["received"]) ?: return null,
                    sent = whole(day["sent"]) ?: return null,
                    time = real(day["time"]) ?: return null,
                )
            }
            val serverValues = root["servers"] as? List<*> ?: return null
            if (serverValues.size % 2 != 0) return null
            for (pair in serverValues.chunked(2)) {
                val total = pair[1] as? Map<*, *> ?: return null
                val id = Json.string(pair[0]) ?: Json.string(total["id"]) ?: return null
                val uuid = runCatching { java.util.UUID.fromString(id) }.getOrNull() ?: return null
                ledger.servers[uuid] = ServerTotal(
                    id = uuid,
                    name = Json.string(total["name"]) ?: return null,
                    received = whole(total["received"]) ?: return null,
                    sent = whole(total["sent"]) ?: return null,
                    lastUsed = real(total["lastUsed"])?.plus(REFERENCE_EPOCH) ?: return null,
                )
            }
            var run: Pair<Double, Pair<Long, Long>>? = null
            (root["lastRun"] as? Map<*, *>)?.let { record ->
                val startedAt = real(record["startedAt"]) ?: return null
                val received = whole(record["received"]) ?: return null
                val sent = whole(record["sent"]) ?: return null
                run = startedAt + REFERENCE_EPOCH to (received to sent)
            }
            // Ключа нет — `nil`; есть, но не число — документ не читается, как
            // он не читается и у Swift: молча обнулённый `lastReading` начал бы
            // новую связку отсчётов там, где она ещё идёт.
            val raw = root["lastReading"]
            val reading = when {
                raw == null -> null
                else -> real(raw)?.plus(REFERENCE_EPOCH) ?: return null
            }
            ledger.restore(run, reading)
            return ledger
        }

        /** Целое из JSON-числа: дробное Swift-декодер тоже отвергает (`Int64` из `4.5`). */
        private fun whole(value: Any?): Long? {
            val number = value as? Double ?: return null
            if (number.isNaN() || number.isInfinite()) return null
            return if (number == Math.floor(number) && Math.abs(number) < 9.0e18) number.toLong() else null
        }

        private fun real(value: Any?): Double? = value as? Double

        const val KEEP_DAYS = 120
        const val KEEP_SERVERS = 200
        const val MAX_STEP = 10.0

        /** Local calendar day, "2026-09-17". */
        fun dayKey(seconds: Double, timeZone: java.util.TimeZone): String {
            val calendar = calendar(timeZone)
            calendar.timeInMillis = (seconds * 1000).toLong()
            return String.format(java.util.Locale.ROOT, "%04d-%02d-%02d",
                calendar.get(java.util.Calendar.YEAR),
                calendar.get(java.util.Calendar.MONTH) + 1,
                calendar.get(java.util.Calendar.DAY_OF_MONTH),
            )
        }

        /** Local midnight of `seconds`. */
        private fun startOfDay(seconds: Double, timeZone: java.util.TimeZone): Long {
            val calendar = calendar(timeZone)
            calendar.timeInMillis = (seconds * 1000).toLong()
            calendar.set(java.util.Calendar.HOUR_OF_DAY, 0)
            calendar.set(java.util.Calendar.MINUTE, 0)
            calendar.set(java.util.Calendar.SECOND, 0)
            calendar.set(java.util.Calendar.MILLISECOND, 0)
            return calendar.timeInMillis / 1000
        }

        /** Local midnight `days` earlier — DST-aware, like `Calendar.date(byAdding: .day)`. */
        private fun midnightOf(seconds: Double, timeZone: java.util.TimeZone, days: Int): Double {
            val calendar = calendar(timeZone)
            calendar.timeInMillis = startOfDay(seconds, timeZone) * 1000
            calendar.add(java.util.Calendar.DAY_OF_MONTH, days)
            return calendar.timeInMillis / 1000.0
        }

        /** The day a key names, or null when it isn't a real date. */
        fun dateOfDay(key: String, timeZone: java.util.TimeZone): Double? {
            val match = DAY_PATTERN.matchEntire(key) ?: return null
            val (year, month, day) = match.groupValues.drop(1).map { it.toInt() }
            if (month !in 1..12 || day !in 1..31) return null
            val calendar = calendar(timeZone)
            calendar.clear()
            calendar.set(year, month - 1, day)
            if (calendar.get(java.util.Calendar.MONTH) + 1 != month ||
                calendar.get(java.util.Calendar.DAY_OF_MONTH) != day
            ) {
                return null            // 31 April rolls into May — that is not a date
            }
            return calendar.timeInMillis / 1000.0
        }

        private val DAY_PATTERN = Regex("^(\\d{4})-(\\d{2})-(\\d{2})$")

        private fun calendar(timeZone: java.util.TimeZone): java.util.Calendar =
            java.util.GregorianCalendar(timeZone).apply { isLenient = true }
    }
}

/**
 * Сумма накопленных счётчиков без переполнения. `state.json` может нести что
 * угодно, а `Long + Long` в Kotlin оборачивается в отрицательное число — там,
 * где Swift падал ловушкой. Порт считает так же (`saturated` в
 * TrafficLedger.swift): потолок по знаку слагаемых, чтобы «итого за день» не
 * становилось отрицательным ни на одной платформе.
 */
private fun saturated(a: Long, b: Long): Long {
    val sum = a + b
    if (((a xor sum) and (b xor sum)) < 0L) return if (a < 0) Long.MIN_VALUE else Long.MAX_VALUE
    return sum
}
