package app.anemia.core

/**
 * Port of `Sources/LoaderCore/SyncBundle.swift`: the file (AirDrop, Files) and
 * the QR form one Anemia hands another. Servers and subscription addresses
 * travel; the selection stays behind, because each device picks its own exit.
 *
 * Two wire formats, worth matching in different ways: the file form is readable
 * JSON with no floating point in it, so its bytes can and do match; the link
 * form is that JSON raw-deflated and base64url'd, where two deflate encoders
 * never agree byte for byte and the contract is instead that each side reads
 * what the other wrote — which `Scripts/verify-sync.sh` checks against the real
 * Swift decoder.
 */
data class SyncBundle(
    val version: Int = FORMAT_VERSION,
    /** Seconds since the Unix epoch; the file form writes it as ISO8601. */
    val exportedAt: Double,
    val device: String,
    val servers: List<ProxyServer>,
    val subscriptions: List<SubscriptionEntry>,
    val settings: Settings? = null,
) {
    /** A subscription as it travels: its address only, never its fetched servers. */
    data class SubscriptionEntry(val name: String, val url: String)

    /** Settings travel as optionals: a field one app lacks keeps the other side's value. */
    data class Settings(
        val maskingProfile: MaskingProfile? = null,
        val killSwitchEnabled: Boolean? = null,
        val splitTunnel: SplitTunnelRules? = null,
        val learnedMasking: Map<String, String>? = null,
        val subscriptionAutoRefresh: Boolean? = null,
        val adBlock: Boolean? = null,
        val autoReconnect: Boolean? = null,
        val autoSwitch: Boolean? = null,
        val adaptiveMasking: Boolean? = null,
    )

    data class Summary(
        val addedServers: Int = 0,
        /** Servers the other side already had — same endpoint and credentials. */
        val knownServers: Int = 0,
        val newSubscriptions: List<SubscriptionEntry> = emptyList(),
        val knownSubscriptions: Int = 0,
        val settingsApplied: Boolean = false,
    ) {
        val addsNothing: Boolean
            get() = addedServers == 0 && newSubscriptions.isEmpty() && !settingsApplied
    }

    // MARK: - Writing

    /** The file form: readable JSON, sorted keys — what a `.anemia` file holds. */
    fun fileData(): String = Json.writePretty(document())

    /** The same document compact; the link form deflates this. */
    fun json(): String = Json.write(document())

    fun link(): String = LINK_PREFIX + base64URL(deflate(json().toByteArray(Charsets.UTF_8)))

    private fun document(): Map<String, Any?> {
        val fields = linkedMapOf<String, Any?>(
            "version" to version,
            "exportedAt" to Iso8601.format(exportedAt),
            "device" to device,
            "servers" to servers.map { StateCodec.serverValue(it) },
            "subscriptions" to subscriptions.map {
                StateCodec.sorted(mapOf("name" to it.name, "url" to it.url))
            },
            "settings" to settings?.let { settingsValue(it) },
        )
        return StateCodec.sorted(fields)
    }

    private fun settingsValue(settings: Settings): Map<String, Any?> = StateCodec.sorted(
        mapOf(
            "maskingProfile" to settings.maskingProfile?.name,
            "killSwitchEnabled" to settings.killSwitchEnabled,
            "splitTunnel" to settings.splitTunnel?.let {
                StateCodec.sorted(mapOf("enabled" to it.enabled, "entries" to it.entries))
            },
            "learnedMasking" to settings.learnedMasking,
            "subscriptionAutoRefresh" to settings.subscriptionAutoRefresh,
            "adBlock" to settings.adBlock,
            "autoReconnect" to settings.autoReconnect,
            "autoSwitch" to settings.autoSwitch,
            "adaptiveMasking" to settings.adaptiveMasking,
        ),
    )

    // MARK: - Merging

    /** What [mergeInto] would do, without doing it. */
    fun preview(state: PersistedState, applySettings: Boolean): Summary =
        mergeInto(state, applySettings).first

    /**
     * Adds what `state` lacks — servers by identity (endpoint and credentials),
     * subscriptions by address — and, with `applySettings`, takes over the
     * settings the bundle carries. New subscriptions arrive empty (never
     * fetched), for the caller to refresh.
     */
    fun mergeInto(state: PersistedState, applySettings: Boolean): Pair<Summary, PersistedState> {
        var added = 0
        var known = 0
        var result = state
        val identities = state.allServers.map { it.identityKey }.toHashSet()
        val ids = state.allServers.map { it.id }.toHashSet()
        val fresh = ArrayList<ProxyServer>()
        for (server in servers) {
            if (!identities.add(server.identityKey)) {
                known += 1
                continue
            }
            // The same server edited on both sides keeps both copies apart: a
            // duplicate id breaks every id-keyed list on both platforms.
            var carried = server
            if (!ids.add(carried.id)) {
                carried = carried.copy(id = java.util.UUID.randomUUID())
                ids.add(carried.id)
            }
            fresh.add(carried)
            added += 1
        }
        if (fresh.isNotEmpty()) result = result.copy(servers = result.servers + fresh)

        var newSubscriptions = listOf<SubscriptionEntry>()
        var knownSubscriptions = 0
        val urls = result.subscriptions.map { normalizedUrl(it.url) }.toHashSet()
        val addedSubscriptions = ArrayList<Subscription>()
        for (entry in subscriptions) {
            if (!urls.add(normalizedUrl(entry.url))) {
                knownSubscriptions += 1
                continue
            }
            addedSubscriptions.add(Subscription(name = entry.name, url = entry.url))
            newSubscriptions = newSubscriptions + entry
        }
        if (addedSubscriptions.isNotEmpty()) {
            result = result.copy(subscriptions = result.subscriptions + addedSubscriptions)
        }

        var settingsApplied = false
        val carried = if (applySettings) settings else null
        if (carried != null) {
            carried.maskingProfile?.let { result = result.copy(maskingProfile = it) }
            carried.killSwitchEnabled?.let { result = result.copy(killSwitchEnabled = it) }
            carried.splitTunnel?.let { result = result.copy(splitTunnel = it) }
            carried.learnedMasking?.let { learned ->
                val union = LinkedHashMap(result.learnedMasking)
                for ((key, value) in learned) union[key] = value
                result = result.copy(learnedMasking = union)
            }
            carried.subscriptionAutoRefresh?.let {
                result = result.copy(subscriptionAutoRefresh = it)
            }
            settingsApplied = true
        }

        if (result.selectedServerID == null) {
            result = result.copy(selectedServerID = result.allServers.firstOrNull()?.id)
        }
        return Summary(added, known, newSubscriptions, knownSubscriptions, settingsApplied) to result
    }

    private fun normalizedUrl(url: String): String = trimSpaceLike(url).lowercase().trim('/')

    companion object {
        const val FORMAT_VERSION = 1
        const val FILE_EXTENSION = "anemia"
        const val LINK_PREFIX = "anemia://sync/"

        /** Whether the text is a bundle at all — a link, or the file's JSON. */
        fun looksLikeBundle(text: String): Boolean {
            val trimmed = trimSpaceLike(text)
            if (trimmed.lowercase().startsWith(LINK_PREFIX)) return true
            return trimmed.startsWith("{") && trimmed.contains("\"exportedAt\"") &&
                trimmed.contains("\"device\"")
        }

        /** The file form or the link form, whichever the bytes are. */
        fun decode(data: String): SyncBundle {
            val text = trimSpaceLike(data)
            if (text.startsWith(LINK_PREFIX)) return fromLink(text)
            val bundle = runCatching { read(data) }.getOrNull()
                ?: throw newerOrNot(data)
            if (bundle.version > FORMAT_VERSION) throw SyncDecodeException("newerVersion", bundle.version)
            return bundle
        }

        /** `anemia://sync/` + base64url(raw deflate of the JSON). */
        fun fromLink(text: String): SyncBundle {
            val trimmed = trimSpaceLike(text)
            // Swift tests the prefix case-sensitively in `decode` and
            // lowercased in `fromLink`; an uppercase link therefore only ever
            // arrives here through `decode`'s own check, and one that came
            // directly here must still be one of ours.
            if (!trimmed.lowercase().startsWith(LINK_PREFIX)) throw SyncDecodeException("notABundle")
            val payload = trimmed.substring(LINK_PREFIX.length)
            val base64 = payload.replace('-', '+').replace('_', '/') +
                "=".repeat((4 - payload.length % 4) % 4)
            val packed = runCatching { java.util.Base64.getDecoder().decode(base64) }.getOrNull()
                ?: throw SyncDecodeException("notABundle")
            val json = runCatching { inflate(packed) }.getOrNull()?.let { utf8(it) }
                ?: throw SyncDecodeException("notABundle")
            val bundle = runCatching { read(json) }.getOrNull() ?: throw SyncDecodeException("notABundle")
            if (bundle.version > FORMAT_VERSION) throw SyncDecodeException("newerVersion", bundle.version)
            return bundle
        }

        /** Telling "written by a newer Anemia" apart from "not ours at all". */
        private fun newerOrNot(data: String): SyncDecodeException {
            val version = runCatching {
                ((Json.parse(data) as? Map<*, *>)?.get("version") as? Double)?.toInt()
            }.getOrNull()
            return if (version != null && version > FORMAT_VERSION && data.contains("\"device\"")) {
                SyncDecodeException("newerVersion", version)
            } else {
                SyncDecodeException("notABundle")
            }
        }

        /** One document, strictly: anything malformed is "not a bundle". */
        internal fun read(text: String): SyncBundle {
            val root = Json.parse(text) as? Map<*, *> ?: throw SyncDecodeException("notABundle")
            val version = (required(root, "version") as? Double)?.toInt()
                ?: throw SyncDecodeException("notABundle")
            val stamp = Iso8601.parse(required(root, "exportedAt") as? String
                ?: throw SyncDecodeException("notABundle"))
                ?: throw SyncDecodeException("notABundle")
            val servers = (required(root, "servers") as? List<*> ?: throw SyncDecodeException("notABundle"))
                .map { StateCodec.server(it) }
            val subscriptions = (required(root, "subscriptions") as? List<*>
                ?: throw SyncDecodeException("notABundle")).map { item ->
                val entry = objectMap(item)
                SubscriptionEntry(
                    name = entry["name"] as? String ?: throw SyncDecodeException("notABundle"),
                    url = entry["url"] as? String ?: throw SyncDecodeException("notABundle"),
                )
            }
            val settings = root["settings"]?.let { settings(objectMap(it)) }
            return SyncBundle(
                version = version,
                exportedAt = stamp,
                device = required(root, "device") as? String ?: throw SyncDecodeException("notABundle"),
                servers = servers,
                subscriptions = subscriptions,
                settings = settings,
            )
        }

        private fun settings(map: Map<*, *>): Settings = Settings(
            maskingProfile = map["maskingProfile"]?.let { raw ->
                MaskingProfile.entries.firstOrNull { it.name == raw }
                    ?: throw SyncDecodeException("notABundle")
            },
            killSwitchEnabled = map["killSwitchEnabled"] as? Boolean,
            splitTunnel = map["splitTunnel"]?.let { StateCodec.splitTunnel(it) },
            learnedMasking = (map["learnedMasking"] as? Map<*, *>)?.let { masks ->
                LinkedHashMap<String, String>().apply {
                    for ((key, value) in masks) {
                        if (key !is String || value !is String) throw SyncDecodeException("notABundle")
                        put(key, value)
                    }
                }
            },
            subscriptionAutoRefresh = map["subscriptionAutoRefresh"] as? Boolean,
            adBlock = map["adBlock"] as? Boolean,
            autoReconnect = map["autoReconnect"] as? Boolean,
            autoSwitch = map["autoSwitch"] as? Boolean,
            adaptiveMasking = map["adaptiveMasking"] as? Boolean,
        )

        private fun required(map: Map<*, *>, key: String): Any? =
            map[key] ?: throw SyncDecodeException("notABundle")

        private fun objectMap(value: Any?): Map<*, *> =
            value as? Map<*, *> ?: throw SyncDecodeException("notABundle")
    }
}

/** The bundle text wasn't ours, or was written by a newer Anemia. */
class SyncDecodeException(val kind: String, val version: Int? = null) : Exception(
    if (version == null) kind else "$kind($version)"
) {
    fun describe(): String = message ?: kind
}

/**
 * Apple's `.zlib` container is raw DEFLATE — RFC 1951 with no zlib header and no
 * adler trailer, which is what `Deflater(_, true)` and `Inflater(true)` speak.
 */
internal fun deflate(bytes: ByteArray): ByteArray {
    val deflater = java.util.zip.Deflater(java.util.zip.Deflater.DEFAULT_COMPRESSION, true)
    deflater.setInput(bytes)
    deflater.finish()
    val out = java.io.ByteArrayOutputStream(bytes.size / 2 + 64)
    val buffer = ByteArray(8192)
    while (!deflater.finished()) {
        val written = deflater.deflate(buffer)
        if (written == 0) break
        out.write(buffer, 0, written)
    }
    deflater.end()
    return out.toByteArray()
}

/** The deflated bytes, or null when they aren't a raw DEFLATE stream at all. */
internal fun inflate(bytes: ByteArray): ByteArray? {
    val inflater = java.util.zip.Inflater(true)
    inflater.setInput(bytes)
    val out = java.io.ByteArrayOutputStream(bytes.size * 4 + 64)
    val buffer = ByteArray(8192)
    return try {
        while (!inflater.finished()) {
            val read = inflater.inflate(buffer)
            if (read == 0) {
                if (inflater.finished() || inflater.needsDictionary() || inflater.needsInput()) {
                    if (!inflater.finished()) return null
                }
            }
            out.write(buffer, 0, read)
        }
        out.toByteArray()
    } catch (error: java.util.zip.DataFormatException) {
        null
    } finally {
        inflater.end()
    }
}

private fun base64URL(bytes: ByteArray): String =
    java.util.Base64.getEncoder().encodeToString(bytes)
        .replace('+', '-').replace('/', '_').trimEnd('=')

/**
 * The ISO8601 Swift's JSON codecs use, measured rather than assumed: exactly
 * `yyyy-MM-dd'T'HH:mm:ss`, a zone that is mandatory, a fraction of any length,
 * and *lenient* fields — 2026-02-30 and 25:00:00 roll over instead of failing,
 * while month 13 doesn't parse at all. Writing floors to whole seconds, which is
 * what `JSONEncoder` does.
 */
internal object Iso8601 {
    private val PATTERN = Regex(
        "^(\\d{4})-(\\d{2})-(\\d{2})T(\\d{2}):(\\d{2}):(\\d{2})(?:\\.(\\d+))?" +
            "(Z|[+-]\\d{2}:?\\d{2})$"
    )

    fun format(seconds: Double): String {
        val calendar = java.util.GregorianCalendar(java.util.TimeZone.getTimeZone("UTC"))
        calendar.timeInMillis = kotlin.math.floor(seconds).toLong() * 1000L
        fun part(field: Int, width: Int = 2): String =
            calendar.get(field).toString().padStart(width, '0')

        /** [part] pads, so the month is padded before the 1-based shift. */
        fun month(): String = (calendar.get(java.util.Calendar.MONTH) + 1).toString().padStart(2, '0')
        return "${part(java.util.Calendar.YEAR, 4)}-${month()}-" +
            "${part(java.util.Calendar.DAY_OF_MONTH)}T${part(java.util.Calendar.HOUR_OF_DAY)}:" +
            "${part(java.util.Calendar.MINUTE)}:${part(java.util.Calendar.SECOND)}Z"
    }

    fun parse(text: String): Double? {
        val match = PATTERN.matchEntire(text) ?: return null
        val groups = match.groupValues
        val month = groups[2].toInt()
        if (month !in 1..12) return null
        // Основание — длина дроби, а не «три цифры»: Foundation принимает и
        // `.25Z`, и `.250000Z`, и только переводы строк без зоны отвергает.
        val digits = groups[7]
        val fraction = if (digits.isEmpty()) 0.0 else digits.toDouble() / Math.pow(10.0, digits.length.toDouble())
        val offset = groups[8]
        val zone = if (offset == "Z") 0 else {
            val digits = offset.substring(1).replace(":", "")
            val sign = if (offset.first() == '-') -1 else 1
            sign * (digits.substring(0, 2).toInt() * 3600 + digits.substring(2).toInt() * 60)
        }
        val calendar = java.util.GregorianCalendar(java.util.TimeZone.getTimeZone("UTC"))
        // Swift's parser rolls an overflowing field over rather than rejecting
        // it — 2026-02-30 is 1 March, 25:00:00 is tomorrow one o'clock.
        calendar.isLenient = true
        calendar.clear()
        calendar.set(groups[1].toInt(), month - 1, groups[3].toInt(),
                     groups[4].toInt(), groups[5].toInt(), groups[6].toInt())
        calendar.set(java.util.Calendar.MILLISECOND, (fraction * 1000).toInt())
        return calendar.timeInMillis / 1000.0 - zone
    }
}
