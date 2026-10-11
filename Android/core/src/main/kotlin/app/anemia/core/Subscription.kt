package app.anemia.core

/**
 * Port of `Sources/LoaderCore/SubscriptionParser.swift` and
 * `SubscriptionInfo.swift`: the body a panel returns, and what it says about
 * the account in its response headers.
 *
 * The arithmetic here is written with overflow in mind because the Swift side
 * trapped twice on it — a header `total` beyond `Int64.max`, and `remaining`
 * subtracting a negative counter — and `Scripts/golden-sub.sh` pins both.
 */
data class SubscriptionResult(
    val servers: List<ProxyServer>,
    /** Lines that did not parse: the link text and the error, for the UI. */
    val failures: List<Pair<String, String>>,
)

object SubscriptionParser {

    /**
     * One entry per distinct server; a body that decodes to nothing is garbage
     * rather than an empty subscription, and reporting it as empty let a
     * refresh wipe a good list.
     */
    fun parse(body: String): SubscriptionResult {
        val trimmed = trimSpaceLike(body)
        if (trimmed.isEmpty()) return SubscriptionResult(emptyList(), emptyList())

        var undecodable = false
        val text = if (trimmed.contains("://")) trimmed
        else Base64.decodeToString(trimmed) ?: run { undecodable = true; trimmed }

        val servers = ArrayList<ProxyServer>()
        val failures = ArrayList<Pair<String, String>>()
        val seen = HashSet<String>()
        var start = 0
        while (start <= text.length) {
            var end = start
            while (end < text.length && !isSwiftNewline(text[end])) end += 1
            val line = trimFoundationSpaces(text.substring(start, end))
            // A line that came from a lone CR inside a CRLF is empty, and Swift's
            // `split` drops those — same here.
            if (line.isNotEmpty() && line.contains("://")) {
                try {
                    val server = ShareLinkParser.parse(line)
                    if (seen.add(server.identityKey)) servers.add(server)
                } catch (error: ProxyParseException) {
                    failures.add(line to error.describe())
                }
            }
            if (end == text.length) break
            start = end + 1
        }

        if (undecodable && servers.isEmpty() && failures.isEmpty()) {
            failures.add(trimmed.take(80) to
                "malformedURI(\"subscription body is not decodable base64 and contains no share links\")")
        }
        return SubscriptionResult(servers, failures)
    }

    /**
     * Carry server IDs across a refresh: the entry whose identity (link text)
     * was already listed keeps that entry's id, so the selection and the ping
     * history survive an update. Each old id is handed out at most once —
     * duplicate ids break every id-keyed list. Extra copies keep their own.
     */
    fun carryingIDs(old: List<ProxyServer>, fresh: List<ProxyServer>): List<ProxyServer> {
        val pool = HashMap<String, ArrayDeque<java.util.UUID>>()
        for (server in old) pool.getOrPut(server.identityKey) { ArrayDeque() }.addLast(server.id)
        val used = HashSet<java.util.UUID>()
        return fresh.map { server ->
            val ids = pool[server.identityKey]
            var carried = server
            while (ids != null && ids.isNotEmpty()) {
                val id = ids.removeFirst()
                if (used.add(id)) {
                    carried = server.copy(id = id)
                    break
                }
            }
            carried
        }
    }
}

/**
 * Swift splits the decoded body with `Character.isNewline`, and that is not the
 * same as testing for `'\n'` — `"\r\n"` is a single grapheme cluster in Swift,
 * which equals neither half. Splitting on each character of that set gives the
 * same pieces: a CRLF becomes one separator with an empty line dropped next to it.
 */
private fun isSwiftNewline(char: Char): Boolean =
    char == '\n' || char == '\r' || char == '\u000B' || char == '\u000C' ||
        char == '\u0085' || char == '\u2028' || char == '\u2029'

/** What a panel (3x-ui, Marzban, Remnawave…) says about a subscription. */
data class SubscriptionInfo(
    val title: String? = null,
    val uploaded: Long? = null,
    val downloaded: Long? = null,
    /** Bytes allowed; nil or 0 means unlimited. */
    val total: Long? = null,
    /** Epoch seconds. */
    val expires: Long? = null,
    /** How often the panel wants the list refreshed, seconds. */
    val updateInterval: Double? = null,
    val supportUrl: String? = null,
    val webPageUrl: String? = null,
    val announcement: String? = null,
) {
    /** Bytes spent. A panel may answer with sizes near `Long.MAX_VALUE`, so
     * the sum clamps instead of wrapping. */
    val used: Long?
        get() {
            if (uploaded == null && downloaded == null) return null
            val a = uploaded ?: 0
            val b = downloaded ?: 0
            val sum = a + b
            return if ((a xor sum) and (b xor sum) < 0) Long.MAX_VALUE else sum
        }

    val isUnlimited: Boolean get() = (total ?: 0) <= 0

    val remaining: Long?
        get() {
            val allowed = total ?: return null
            if (allowed <= 0) return null
            // A negative counter is a lie, not a credit; clamping first keeps
            // the subtraction in range instead of overflowing upward.
            return maxOf(allowed - maxOf(used ?: 0, 0L), 0L)
        }

    /** 0…1 of the allowance used; null when unlimited. */
    val usedFraction: Double?
        get() {
            val allowed = total ?: return null
            if (allowed <= 0) return null
            // Обе границы: `used` бывает отрицательным (панель отвечает
            // upload=-99999999999999999999, парсер ограничивает его Int64.MIN),
            // а эту дробь умножают на 100 и показывают. Верхняя граница была,
            // нижней не хватало — ровно то, что уже поправлено в Swift.
            return ((used ?: 0).toDouble() / allowed.toDouble()).coerceIn(0.0, 1.0)
        }

    /** Worth a word: out of time within three days, or at 90 % of traffic. */
    fun needsAttention(nowEpochSeconds: Long = System.currentTimeMillis() / 1000): Boolean {
        expires?.let { if (it - nowEpochSeconds < 3 * 86_400) return true }
        // `>=`, как в Swift (`SubscriptionInfo.needsAttention`): планировщик
        // напоминаний и отметка «уже предупреждали» тоже считают от 90 %.
        usedFraction?.let { if (it >= 0.9) return true }
        return false
    }

    companion object {
        /** From raw response headers, any capitalization; null when all empty. */
        fun parse(headers: Map<String, String>): SubscriptionInfo? {
            val lowered = LinkedHashMap<String, String>()
            for ((key, value) in headers) lowered.putIfAbsent(key.lowercase(), value)
            fun value(name: String): String? =
                lowered[name]?.let { trimSpaceLike(it) }?.takeIf { it.isNotEmpty() }

            var uploaded: Long? = null
            var downloaded: Long? = null
            var total: Long? = null
            var expires: Long? = null
            value("subscription-userinfo")?.split(';')?.forEach { pair ->
                if (!pair.contains('=')) return@forEach
                val parts = pair.split('=', limit = 2)
                val number = SwiftDouble.parse(trimFoundationSpaces(parts[1])) ?: return@forEach
                if (!number.isFinite()) return@forEach
                val amount = roundToLong(number)
                when (trimFoundationSpaces(parts[0]).lowercase()) {
                    "upload" -> uploaded = amount
                    "download" -> downloaded = amount
                    "total" -> total = amount
                    // Swift присваивает без условия: второй `expire=0`
                    // сбрасывает срок, а не оставляет предыдущее значение.
                    "expire" -> expires = amount.takeIf { it > 0 }
                }
            }
            // Как Swift: `> 0` пропускает inf («profile-update-interval:
            // 1e400»), а бесконечность в этих заголовках ломает их сохранение
            // на macOS и iOS — JSONEncoder падает на всём словаре, молча
            // теряя данные каждой панели.
            val interval = value("profile-update-interval")?.let(SwiftDouble::parse)
                ?.takeIf { it > 0 }?.let { it * 3600 }?.takeIf { it.isFinite() }
            val info = SubscriptionInfo(
                title = value("profile-title")?.let { text(it) },
                uploaded = uploaded, downloaded = downloaded, total = total, expires = expires,
                updateInterval = interval,
                supportUrl = value("support-url")?.let { link(it) },
                webPageUrl = value("profile-web-page-url")?.let { link(it) },
                announcement = value("announce")?.let { text(it) },
            )
            return if (info == SubscriptionInfo()) null else info
        }

        /**
         * `base64:…` or plain text, sometimes percent-encoded; header values
         * arrive decoded as Latin-1 while panels send UTF-8.
         */
        fun text(raw: String): String {
            val value = repairedUtf8(raw)
            if (value.lowercase().startsWith("base64:")) {
                var payload = value.substring(7).replace('-', '+').replace('_', '/')
                payload += "=".repeat((4 - payload.length % 4) % 4)
                val decoded = runCatching { java.util.Base64.getDecoder().decode(payload) }.getOrNull()
                    ?.let { utf8(it) }
                if (decoded != null) return trimSpaceLike(decoded)
            }
            return percentDecoded(value) ?: value
        }

        /** Swift's `number.rounded()` then a clamped `Int64` — no trap. */
        internal fun roundToLong(number: Double): Long {
            val rounded = if (number >= 0) kotlin.math.floor(number + 0.5)
                else kotlin.math.ceil(number - 0.5)           // half away from zero, as Swift's rounded()
            return when {
                rounded >= Long.MAX_VALUE.toDouble() -> Long.MAX_VALUE
                rounded < Long.MIN_VALUE.toDouble() -> Long.MIN_VALUE
                else -> rounded.toLong()
            }
        }

        /** Latin-1-looking text that is really UTF-8 bytes read one byte each. */
        private fun repairedUtf8(value: String): String {
            if (!value.any { it.code > 0x7F }) return value
            if (value.any { it.code > 0xFF }) return value
            val bytes = ByteArray(value.length) { value[it].code.toByte() }
            return utf8(bytes) ?: value
        }

        private val LINK_SCHEMES = setOf("https", "http", "tg")

        /** `URL(string:)` plus the scheme allowlist the Swift side applies. */
        private fun link(raw: String): String? {
            if (raw.any { it <= ' ' || it == '\u007F' }) return null
            val colon = raw.indexOf(':')
            if (colon <= 0) return null
            val scheme = raw.substring(0, colon)
            if (!scheme.matches(Regex("[A-Za-z][A-Za-z0-9+.-]*"))) return null
            return if (scheme.lowercase() in LINK_SCHEMES) raw else null
        }
    }
}
