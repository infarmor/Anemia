package app.anemia.core

/**
 * Port of `Sources/LoaderCore/Persistence.swift`: the whole client state as the
 * apps store it in `state.json`, and the lenient decoding rules that keep a
 * schema change from discarding a user's servers.
 *
 * The rules are not a style choice — Swift's `JSONDecoder` is strict about
 * types and about required keys, and every field of [PersistedState] decides on
 * its own what to do when that fails. `killSwitchEnabled: "yes"` falls back to
 * the default; a server whose `port` is a string is dropped alone; one bad
 * entry in `anti.noises` empties the whole array. This file reproduces those
 * choices, and `Scripts/golden-state.sh` pins each of them against the Swift
 * decoder itself.
 */
class StateDecodingException(message: String) : Exception(message)

/** One subscription the user added: its address, and what the last fetch left. */
data class Subscription(
    val id: java.util.UUID = java.util.UUID.randomUUID(),
    val name: String,
    val url: String,
    /**
     * Seconds since 2001-01-01 00:00:00 UTC — the number Swift's default `Date`
     * codec writes. Kept as it is on the wire so a re-encode is byte-equal.
     */
    val lastUpdated: Double? = null,
    val servers: List<ProxyServer> = emptyList(),
) {
    /**
     * Порт `Subscription.tlsProtected`: панель, до которой идут по открытому
     * http, отвечает тому, кто контролирует путь. Автоматические проходы
     * (старт, возврат в foreground, таймер, 6 ч — на macOS и iOS) такие
     * подписки пропускают: подмена списка серверов это будущий трафик через
     * чужой выход. Нажатие «обновить» по-прежнему грузит их, знак «без
     * шифрования» виден в списке.
     */
    val tlsProtected: Boolean get() = url.lowercase().startsWith("https://")

    /** Wall-clock seconds since the Unix epoch, for the app's own arithmetic. */
    val lastUpdatedEpochSeconds: Double? get() = lastUpdated?.plus(REFERENCE_DATE_SECONDS)

    /**
     * Порт `Subscription.refreshMaxAge`: сколько ждать между двумя запросами
     * панели без участия пользователя. Просьба панели (`profile-update-interval`,
     * в секундах) берётся, если она есть, иначе `defaultAgeSeconds`; результат
     * зажат в `[1 ч, 24 ч]`: ползунком чаще часа выносим панель на свалку
     * запросов, а «раз в месяц» означало бы список протухших серверов.
     */
    fun refreshMaxAge(
        panelIntervalSeconds: Double?,
        defaultAgeSeconds: Double = DEFAULT_REFRESH_AGE_SECONDS,
    ): Double {
        // Молчание дороже любого из дефолтов: не-число уступает и просьба
        // панели, и переданный дефолт — иначе сравнение с NaN навсегда ложно.
        val requested = panelIntervalSeconds?.takeIf { it.isFinite() }
            ?: defaultAgeSeconds.takeIf { it.isFinite() }
            ?: DEFAULT_REFRESH_AGE_SECONDS
        return requested.coerceIn(3_600.0, 86_400.0)
    }

    /**
     * Порт `Subscription.refreshIsDue`: можно ли раунду без пользователя
     * перезапросить эту панель. Решение целиком здесь, чтобы macOS, iOS и
     * Kotlin не разошлись в том, когда список имеет право измениться сам.
     * `allowInsecure` отмечает раунд, который нажал человек: без него панель
     * без TLS не готова никогда — её ответ пишет тот, кто контролирует путь.
     */
    fun refreshIsDue(
        nowEpochSeconds: Double,
        panelIntervalSeconds: Double?,
        defaultAgeSeconds: Double = DEFAULT_REFRESH_AGE_SECONDS,
        allowInsecure: Boolean = false,
    ): Boolean {
        if (!tlsProtected && !allowInsecure) return false
        // Swift сравнивает с `Date.distantPast` — датой огромной, но конечной;
        // -∞ даёт то же «давно» и не может перевести сравнение, потому что
        // maxAge после зажатия всегда конечен.
        val fetched = lastUpdatedEpochSeconds ?: Double.NEGATIVE_INFINITY
        // Отметка в будущем — разъехавшиеся часы или бандл с кривого
        // устройства: ждать окончания перекоса нельзя, как и на Swift-стороне.
        if (fetched > nowEpochSeconds) return true
        return nowEpochSeconds - fetched >= refreshMaxAge(panelIntervalSeconds, defaultAgeSeconds)
    }

    companion object {
        /** Seconds between the Unix epoch and Core Foundation's reference date. */
        const val REFERENCE_DATE_SECONDS = 978_307_200.0

        /** `defaultAge:` of the Swift predicate — the automatic round's cadence. */
        const val DEFAULT_REFRESH_AGE_SECONDS = 21_600.0
    }
}

/** The full persisted client state — see `PersistedState` on the Swift side. */
data class PersistedState(
    val servers: List<ProxyServer> = emptyList(),
    val subscriptions: List<Subscription> = emptyList(),
    val selectedServerID: java.util.UUID? = null,
    val anti: AntiCensorshipOptions = AntiCensorshipOptions.recommended,
    val killSwitchEnabled: Boolean = false,
    val maskingProfile: MaskingProfile = MaskingProfile.balanced,
    val autoConnectOnLaunch: Boolean = false,
    val mlRankingEnabled: Boolean = true,
    val systemProxyEnabled: Boolean = false,
    val subscriptionAutoRefresh: Boolean = true,
    val learnedMasking: Map<String, String> = emptyMap(),
    val splitTunnel: SplitTunnelRules = SplitTunnelRules(),
) {
    /** Manual entries first, then the servers the subscriptions fetched. */
    val allServers: List<ProxyServer> get() = servers + subscriptions.flatMap { it.servers }

    fun serverWithId(id: java.util.UUID): ProxyServer? = allServers.firstOrNull { it.id == id }
}

/**
 * The result of reading a store: the state, whether the file was readable at
 * all, and whether the decode recovered fewer entries than the raw JSON still
 * carries — which is what makes [StateCodec] report that a backup is due.
 */
data class LoadedState(
    val state: PersistedState,
    val decoded: Boolean,
    val droppedEntries: Boolean,
) {
    /** Swift's `load()` writes a timestamped copy of the file in this case. */
    val needsBackup: Boolean get() = !decoded || droppedEntries
}

object StateCodec {

    /** Read a `state.json`. Never throws: a store the decoder can't read loads as defaults. */
    fun load(text: String): LoadedState {
        val root = runCatching { Json.parse(text) }
            .getOrNull() as? Map<*, *>
        val state = root?.let { runCatching { persistedState(it) }.getOrNull() }
        if (root == null) return LoadedState(PersistedState(), decoded = false, droppedEntries = true)
        val decoded = state != null
        val value = state ?: PersistedState()
        var dropped = false
        for ((key, count) in listOf(
            "servers" to value.servers.size,
            "subscriptions" to value.subscriptions.size,
            "learnedMasking" to value.learnedMasking.size,
        )) {
            val raw = rawCount(root[key], root.containsKey(key))
            if (raw != null && raw > count) dropped = true
        }
        // Обе вложенные коллекции, которые декодируются снисходительно и
        // теряют молча всё: правила `anti.noises` и `splitTunnel.entries`.
        // По родителю сравнивать нельзя — это объект из двух ключей, а не число
        // записей. Swift считает их тем же способом (`Persistence.load`).
        dropped = dropped or nestedDropped(root, "splitTunnel", "entries", value.splitTunnel.entries.size)
        dropped = dropped or nestedDropped(root, "anti", "noises", value.anti.noises.size)
        return LoadedState(value, decoded, dropped)
    }

    /** Whether the nested array held more records than the decode recovered. */
    private fun nestedDropped(root: Map<*, *>, parent: String, key: String, decoded: Int): Boolean {
        val outer = root[parent] as? Map<*, *> ?: return false
        val raw = rawCount(outer[key], outer.containsKey(key)) ?: return false
        return raw > decoded
    }

    /** The state as the apps decode it — throws when the document isn't an object. */
    fun state(text: String): PersistedState {
        val root = Json.parse(text)
        return persistedState(reader(root))
    }

    /** Compact, key-sorted JSON — the same document `JSONEncoder` writes. */
    fun encode(state: PersistedState): String = Json.write(persistedValue(state))

    fun encode(server: ProxyServer): String = Json.write(serverValue(server))

    /** Один сервер, записанный [encode]: то же значение, что в массиве `servers`. */
    fun server(text: String): ProxyServer = server(Json.parse(text))

    /**
     * A collection that is not a collection still counts as one entry — and so
     * does an explicit `null`: for Swift's drift detector a key that is present
     * but empty *is* a record that the decode failed to recover.
     */
    private fun rawCount(value: Any?, present: Boolean): Int? = when {
        !present -> null
        value == null -> 1
        value is List<*> -> value.size
        value is Map<*, *> -> value.size
        else -> 1
    }

    // MARK: - PersistedState

    private fun persistedState(root: Map<*, *>): PersistedState {
        val map = reader(root)
        return PersistedState(
            servers = lenientArray(map["servers"]) { server(it) },
            subscriptions = lenientArray(map["subscriptions"]) { subscription(it) },
            selectedServerID = tryOrNull { uuid(map, "selectedServerID") },
            anti = tryOrNull { anti(map["anti"]) } ?: AntiCensorshipOptions.recommended,
            killSwitchEnabled = tryOrNull { boolean(map, "killSwitchEnabled") } ?: false,
            maskingProfile = tryOrNull {
                MaskingProfile.valueOf(string(map, "maskingProfile"))
            } ?: MaskingProfile.balanced,
            autoConnectOnLaunch = tryOrNull { boolean(map, "autoConnectOnLaunch") } ?: false,
            mlRankingEnabled = tryOrNull { boolean(map, "mlRankingEnabled") } ?: true,
            systemProxyEnabled = tryOrNull { boolean(map, "systemProxyEnabled") } ?: false,
            subscriptionAutoRefresh = tryOrNull { boolean(map, "subscriptionAutoRefresh") } ?: true,
            learnedMasking = tryOrNull { stringMap(present(map, "learnedMasking"), "learnedMasking") } ?: emptyMap(),
            splitTunnel = tryOrNull { splitTunnel(map["splitTunnel"]) } ?: SplitTunnelRules(),
        )
    }

    /**
     * `[ProxyServer]` element by element: a healthy entry survives even when a
     * neighbour is unreadable. All-or-nothing array decoding used to null every
     * server the user had because of one poisoned entry.
     */
    private fun <T> lenientArray(value: Any?, read: (Map<*, *>) -> T): List<T> {
        val items = value as? List<*> ?: return emptyList()
        return items.mapNotNull { item ->
            val element = item as? Map<*, *> ?: return@mapNotNull null
            runCatching { read(element) }.getOrNull()
        }
    }

    private fun subscription(value: Any?): Subscription {
        val map = reader(value)
        return Subscription(
            id = uuid(map, "id"),
            name = string(map, "name"),
            url = string(map, "url"),
            lastUpdated = doubleIfPresent(map, "lastUpdated"),
            servers = list(map["servers"]).map { server(it) },
        )
    }

    /** Одно значение сервера — элемент `servers` или весь документ. */
    fun server(value: Any?): ProxyServer {
        val map = reader(value)
        return ProxyServer(
            id = uuid(map, "id"),
            name = string(map, "name"),
            proto = protocol(string(map, "proto")),
            address = string(map, "address"),
            port = int(map, "port"),
            credential = string(map, "credential"),
            method = stringIfPresent(map, "method"),
            alterId = int(map, "alterId"),
            vmessCipher = stringIfPresent(map, "vmessCipher"),
            network = network(string(map, "network")),
            security = security(string(map, "security")),
            sni = stringIfPresent(map, "sni"),
            alpn = strings(map, "alpn"),
            fingerprint = stringIfPresent(map, "fingerprint"),
            allowInsecure = boolean(map, "allowInsecure"),
            realityPublicKey = stringIfPresent(map, "realityPublicKey"),
            realityShortId = stringIfPresent(map, "realityShortId"),
            realitySpiderX = stringIfPresent(map, "realitySpiderX"),
            flow = stringIfPresent(map, "flow"),
            path = stringIfPresent(map, "path"),
            host = stringIfPresent(map, "host"),
            headerType = stringIfPresent(map, "headerType"),
            grpcMultiMode = booleanIfPresent(map, "grpcMultiMode"),
            xhttpMode = stringIfPresent(map, "xhttpMode"),
            xhttpExtra = stringIfPresent(map, "xhttpExtra"),
            vlessEncryption = stringIfPresent(map, "vlessEncryption"),
            awg = awg(map["awg"]),
            wgProfile = wgProfile(map["wgProfile"]),
            userData = stringMapIfPresent(map, "userData"),
        )
    }

    /** `AWGObfuscation` decodes with `try`: one wrong type drops the server. */
    private fun awg(value: Any?): AwgObfuscation? {
        val map = mapOrNull(value) ?: return null
        val legacy = runCatching { intOrNull(map, "contentPaddingAddition") }.getOrNull()
        return AwgObfuscation(
            junkPackets = intIfPresent(map, "junkPackets"),
            junkMin = intIfPresent(map, "junkMin"),
            junkMax = intIfPresent(map, "junkMax"),
            initPadding = intIfPresent(map, "initPadding"),
            responsePadding = intIfPresent(map, "responsePadding"),
            cookiePadding = intIfPresent(map, "cookiePadding"),
            transportPadding = intIfPresent(map, "transportPadding"),
            header1 = stringIfPresent(map, "header1"),
            header2 = stringIfPresent(map, "header2"),
            header3 = stringIfPresent(map, "header3"),
            header4 = stringIfPresent(map, "header4"),
            specialHandshakes = stringsOr(map, "specialHandshakes"),
            headerProtectionKey = stringIfPresent(map, "headerProtectionKey"),
            // Saved before the ranges were modeled this was a plain integer; a
            // strict String decode would drop every such server.
            contentPaddingAddition = legacy?.toString() ?: stringIfPresent(map, "contentPaddingAddition"),
            rekeyAfterTime = stringIfPresent(map, "rekeyAfterTime"),
            rekeyTimeout = stringIfPresent(map, "rekeyTimeout"),
            rejectAfterTime = stringIfPresent(map, "rejectAfterTime"),
            keepaliveTimeout = stringIfPresent(map, "keepaliveTimeout"),
            maxHandshakeAttempts = stringIfPresent(map, "maxHandshakeAttempts"),
            randomTrailers = booleanIfPresent(map, "randomTrailers"),
            disableCookies = booleanIfPresent(map, "disableCookies"),
        )
    }

    private fun wgProfile(value: Any?): WireGuardProfile? {
        val map = mapOrNull(value) ?: return null
        return WireGuardProfile(
            peerPublicKey = string(map, "peerPublicKey"),
            presharedKey = stringIfPresent(map, "presharedKey"),
            allowedIPs = strings(map, "allowedIPs"),
            dns = strings(map, "dns"),
            mtu = intIfPresent(map, "mtu"),
            keepAlive = intIfPresent(map, "keepAlive"),
        )
    }

    /** `AntiCensorshipOptions` is lenient per field; its nested arrays are not. */
    private fun anti(value: Any?): AntiCensorshipOptions {
        val map = reader(value)
        // `(try? decodeIfPresent(Fragment…)) ?? nil`: a fragment that is present
        // but incomplete becomes nil, and so does a fragment of the wrong type.
        val fragment = runCatching {
            objectIfPresent(map, "fragment") {
                AntiCensorshipOptions.Fragment(
                    packets = string(it, "packets"), length = string(it, "length"),
                    interval = string(it, "interval"),
                )
            }
        }.getOrNull()
        // Одна кривая запись стоила всего массива: `runCatching` висел над всем
        // `map`, поэтому исключение на одном элементе обнуляло список целиком.
        // Теперь строго по записи — как `Loose<Noise>` в Swift-`AntiCensorship`,
        // и кейс `anti-lenient` в эталоне состояния это закрепляет: из трёх
        // записей выживает та, что читается. Внешнее поведение прежнее: ключ не
        // список — пустой список, а не выброшенное состояние.
        val noiseList = runCatching { listIfPresent(map, "noises") }.getOrNull()
        val noises = noiseList?.mapNotNull { entry ->
            runCatching {
                val n = reader(entry)
                AntiCensorshipOptions.Noise(
                    type = string(n, "type"), packet = string(n, "packet"), delay = string(n, "delay"),
                )
            }.getOrNull()
        } ?: emptyList()
        return AntiCensorshipOptions(
            fragment = fragment,
            noises = noises,
            muxEnabled = tryOrNull { boolean(map, "muxEnabled") } ?: false,
            muxConcurrency = tryOrNull { int(map, "muxConcurrency") } ?: 8,
            tcpFastOpen = tryOrNull { boolean(map, "tcpFastOpen") } ?: true,
            fingerprint = tryOrNull { string(map, "fingerprint") } ?: "chrome",
            // `Loose<String>` в Swift: элемент-не-строка стоит одной записи, а
            // не всего списка алиасов; отсутствующий или не-списочный ключ —
            // пустой список, как и раньше.
            mimicry = runCatching { listIfPresent(map, "mimicry") }.getOrNull()
                ?.mapNotNull { it as? String } ?: emptyList(),
        )
    }

    internal fun splitTunnel(value: Any?): SplitTunnelRules {
        val map = reader(value)
        return SplitTunnelRules(
            enabled = tryOrNull { boolean(map, "enabled") } ?: true,
            entries = tryOrNull { strings(map, "entries") } ?: emptyList(),
        )
    }

    // MARK: - Encoding

    private fun persistedValue(state: PersistedState): Map<String, Any?> = sorted(mapOf(
        "servers" to state.servers.map { serverValue(it) },
        "subscriptions" to state.subscriptions.map { subscriptionValue(it) },
        "selectedServerID" to state.selectedServerID?.let { it.toString().uppercase() },
        "anti" to antiValue(state.anti),
        "killSwitchEnabled" to state.killSwitchEnabled,
        "maskingProfile" to state.maskingProfile.name,
        "autoConnectOnLaunch" to state.autoConnectOnLaunch,
        "mlRankingEnabled" to state.mlRankingEnabled,
        "systemProxyEnabled" to state.systemProxyEnabled,
        "subscriptionAutoRefresh" to state.subscriptionAutoRefresh,
        "learnedMasking" to state.learnedMasking,
        "splitTunnel" to sorted(mapOf(
            "enabled" to state.splitTunnel.enabled,
            "entries" to state.splitTunnel.entries,
        )),
    ))

    private fun subscriptionValue(subscription: Subscription): Map<String, Any?> = sorted(
        mapOf(
            "id" to subscription.id.toString().uppercase(),
            "name" to subscription.name,
            "url" to subscription.url,
            "lastUpdated" to subscription.lastUpdated,
            "servers" to subscription.servers.map { serverValue(it) },
        ),
    )

    /**
     * The keys are exactly the properties Swift encodes: an optional that is nil
     * is left out entirely, while `userData: {}` — present but empty — is not.
     */
    internal fun serverValue(server: ProxyServer): Map<String, Any?> = sorted(
        mapOf(
            "id" to server.id.toString().uppercase(),
            "name" to server.name,
            "proto" to server.proto.raw,
            "address" to server.address,
            "port" to server.port,
            "credential" to server.credential,
            "method" to server.method,
            "alterId" to server.alterId,
            "vmessCipher" to server.vmessCipher,
            "network" to server.network.raw,
            "security" to server.security.raw,
            "sni" to server.sni,
            "alpn" to server.alpn,
            "fingerprint" to server.fingerprint,
            "allowInsecure" to server.allowInsecure,
            "realityPublicKey" to server.realityPublicKey,
            "realityShortId" to server.realityShortId,
            "realitySpiderX" to server.realitySpiderX,
            "flow" to server.flow,
            "path" to server.path,
            "host" to server.host,
            "headerType" to server.headerType,
            "grpcMultiMode" to server.grpcMultiMode,
            "xhttpMode" to server.xhttpMode,
            "xhttpExtra" to server.xhttpExtra,
            "vlessEncryption" to server.vlessEncryption,
            "awg" to server.awg?.let { awgValue(it) },
            "wgProfile" to server.wgProfile?.let { wgProfileValue(it) },
            "userData" to server.userData,
        ),
    )

    private fun awgValue(awg: AwgObfuscation): Map<String, Any?> = sorted(
        mapOf(
            "junkPackets" to awg.junkPackets, "junkMin" to awg.junkMin, "junkMax" to awg.junkMax,
            "initPadding" to awg.initPadding, "responsePadding" to awg.responsePadding,
            "cookiePadding" to awg.cookiePadding, "transportPadding" to awg.transportPadding,
            "header1" to awg.header1, "header2" to awg.header2,
            "header3" to awg.header3, "header4" to awg.header4,
            "specialHandshakes" to awg.specialHandshakes,
            "headerProtectionKey" to awg.headerProtectionKey,
            "contentPaddingAddition" to awg.contentPaddingAddition,
            "rekeyAfterTime" to awg.rekeyAfterTime, "rekeyTimeout" to awg.rekeyTimeout,
            "rejectAfterTime" to awg.rejectAfterTime, "keepaliveTimeout" to awg.keepaliveTimeout,
            "maxHandshakeAttempts" to awg.maxHandshakeAttempts,
            "randomTrailers" to awg.randomTrailers, "disableCookies" to awg.disableCookies,
        ),
    )

    private fun wgProfileValue(profile: WireGuardProfile): Map<String, Any?> = sorted(
        mapOf(
            "peerPublicKey" to profile.peerPublicKey,
            "presharedKey" to profile.presharedKey,
            "allowedIPs" to profile.allowedIPs,
            "dns" to profile.dns,
            "mtu" to profile.mtu,
            "keepAlive" to profile.keepAlive,
        ),
    )

    private fun antiValue(anti: AntiCensorshipOptions): Map<String, Any?> = sorted(
        mapOf(
            "fragment" to anti.fragment?.let {
                sorted(mapOf("packets" to it.packets, "length" to it.length, "interval" to it.interval))
            },
            "noises" to anti.noises.map {
                sorted(mapOf("type" to it.type, "packet" to it.packet, "delay" to it.delay))
            },
            "muxEnabled" to anti.muxEnabled,
            "muxConcurrency" to anti.muxConcurrency,
            "tcpFastOpen" to anti.tcpFastOpen,
            "fingerprint" to anti.fingerprint,
            "mimicry" to anti.mimicry,
        ),
    )

    /** Drops the keys Swift leaves out for a nil optional, and sorts the rest. */
    internal fun sorted(pairs: Map<String, Any?>): Map<String, Any?> {
        val out = java.util.TreeMap<String, Any?>()
        for ((key, value) in pairs) if (value != null) out[key] = value
        return out
    }

    // MARK: - The strict readers Swift applies

    /** `decodeIfPresent` for a nested object: absent or null is nil, anything else is read. */
    private fun <T : Any> objectIfPresent(map: Map<*, *>, key: String, read: (Map<*, *>) -> T): T? {
        if (!map.containsKey(key)) return null
        val value = map[key] ?: return null
        return read(reader(value))
    }

    private fun <T : Any> listIfPresent(map: Map<*, *>, key: String, read: (List<*>) -> T): T? {
        if (!map.containsKey(key)) return null
        val value = map[key] ?: return null
        return read(list(value))
    }

    private fun listIfPresent(map: Map<*, *>, key: String): List<*>? {
        if (!map.containsKey(key)) return null
        val value = map[key] ?: return null
        return list(value)
    }

    private fun reader(value: Any?): Map<*, *> =
        value as? Map<*, *> ?: throw StateDecodingException("ожидался объект JSON")

    private fun mapOrNull(value: Any?): Map<*, *>? = value as? Map<*, *>

    private fun list(value: Any?): List<*> =
        value as? List<*> ?: throw StateDecodingException("ожидался массив JSON")

    private fun present(map: Map<*, *>, key: String): Any? {
        if (!map.containsKey(key)) throw StateDecodingException("нет ключа «$key»")
        return map[key] ?: throw StateDecodingException("«$key» — null")
    }

    private fun string(map: Map<*, *>, key: String): String {
        val value = present(map, key)
        return value as? String ?: throw StateDecodingException("«$key» — не строка")
    }

    private fun stringIfPresent(map: Map<*, *>, key: String): String? {
        if (!map.containsKey(key)) return null
        val value = map[key] ?: return null
        return value as? String ?: throw StateDecodingException("«$key» — не строка")
    }

    /**
     * `try decodeIfPresent([String]) ?? []` — the default covers an absent or
     * null key only; a present but unreadable array throws, and with `try` that
     * takes the whole element down.
     */
    private fun stringsOr(map: Map<*, *>, key: String): List<String> =
        if (map[key] == null) emptyList() else strings(map, key)

    private fun strings(map: Map<*, *>, key: String): List<String> {
        val items = list(present(map, key))
        return items.map { it as? String ?: throw StateDecodingException("«$key» — не массив строк") }
    }

    private fun stringMap(value: Any?, key: String): Map<String, String> {
        val items = value as? Map<*, *> ?: throw StateDecodingException("«$key» — не объект")
        val out = LinkedHashMap<String, String>()
        for ((entryKey, entryValue) in items) {
            if (entryKey !is String || entryValue !is String) {
                throw StateDecodingException("«$key» — не строковые значения")
            }
            out[entryKey] = entryValue
        }
        return out
    }

    /** `[String: String]?` — a missing or null key is nil, a wrong type throws. */
    private fun stringMapIfPresent(map: Map<*, *>, key: String): Map<String, String>? {
        if (!map.containsKey(key)) return null
        val value = map[key] ?: return null
        return stringMap(value, key)
    }

    private fun boolean(map: Map<*, *>, key: String): Boolean {
        val value = present(map, key)
        return value as? Boolean ?: throw StateDecodingException("«$key» — не булево")
    }

    private fun booleanIfPresent(map: Map<*, *>, key: String): Boolean? {
        if (!map.containsKey(key)) return null
        val value = map[key] ?: return null
        return value as? Boolean ?: throw StateDecodingException("«$key» — не булево")
    }

    /** Swift's `Int` accepts a whole number only: `443.0` passes, `"443"` and `443.5` throw. */
    private fun int(map: Map<*, *>, key: String): Int {
        val value = intOrNull(map, key) ?: throw StateDecodingException("«$key» — не целое")
        return value
    }

    private fun intIfPresent(map: Map<*, *>, key: String): Int? {
        if (!map.containsKey(key)) return null
        if (map[key] == null) return null
        return intOrNull(map, key) ?: throw StateDecodingException("«$key» — не целое")
    }

    private fun intOrNull(map: Map<*, *>, key: String): Int? {
        val value = present(map, key) as? Double
            ?: throw StateDecodingException("«$key» — не число")
        if (value != Math.floor(value) || value.isInfinite() || value.isNaN()) {
            throw StateDecodingException("«$key» — не целое")
        }
        // Swift's Int is 64-bit; the model's fields are not, and a port that
        // does not fit is not a port.
        if (value < Int.MIN_VALUE || value > Int.MAX_VALUE) {
            throw StateDecodingException("«$key» — вне диапазона")
        }
        return value.toInt()
    }

    private fun doubleIfPresent(map: Map<*, *>, key: String): Double? {
        if (!map.containsKey(key)) return null
        val value = map[key] ?: return null
        return value as? Double ?: throw StateDecodingException("«$key» — не число")
    }

    private val UUID_PATTERN =
        Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

    private fun uuid(map: Map<*, *>, key: String): java.util.UUID {
        val text = string(map, key)
        if (!UUID_PATTERN.matches(text)) throw StateDecodingException("«$key» — не UUID")
        return java.util.UUID.fromString(text.lowercase())
    }

    private fun protocol(raw: String): ProxyProtocol =
        ProxyProtocol.entries.firstOrNull { it.raw == raw }
            ?: throw StateDecodingException("неизвестный протокол «$raw»")

    private fun network(raw: String): NetworkType =
        NetworkType.entries.firstOrNull { it.raw == raw }
            ?: throw StateDecodingException("неизвестная сеть «$raw»")

    private fun security(raw: String): StreamSecurity =
        StreamSecurity.entries.firstOrNull { it.raw == raw }
            ?: throw StateDecodingException("неизвестная защита «$raw»")

    private inline fun <T : Any> tryOrNull(block: () -> T): T? = try {
        block()
    } catch (error: Exception) {
        null
    }
}
