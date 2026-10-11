package app.anemia.core

/**
 * AmneziaWG: the obfuscation set a profile names, the protocol generation it
 * implies, the interface addresses and the `set=1` script the engine reads.
 *
 * Port of `Sources/LoaderCore/AmneziaWG.swift`. Key names and value shapes are
 * exactly what amneziawg-go's UAPI parser (`device/uapi.go`) accepts — that
 * list was checked against the pinned v3.1.20260828, and the two files have to
 * move together: a key this object emits and the engine does not know fails
 * the whole `IpcSet`, not just that parameter.
 */

/**
 * Each version extends the previous one's obfuscation set:
 *   1.0  junk packets (Jc/Jmin/Jmax) + handshake padding (S1/S2) + fixed magic
 *        headers H1–H4
 *   1.5  + CPS special-handshake chain I1–I5 (client side only)
 *   2.0  + cookie/transport padding S3/S4; H1–H4 became random ranges
 *   3.0  + header protection (ChaCha20 over header fields) and
 *        ContentPaddingAddition; randomized protocol timers
 *   3.1  + RandomTrailers (pad to MTU), DisableCookies
 */
enum class AwgVersion(val label: String) {
    V1("1.0"), V15("1.5"), V2("2.0"), V3("3.0"), V31("3.1");

    companion object {
        /**
         * The highest generation whose markers the set actually uses. A
         * config that only ever sets S1/S2/H1–H4 is 1.0 even though a 3.1
         * engine accepts it: the version describes the config, not the peer.
         */
        fun detect(o: AwgObfuscation?): AwgVersion {
            if (o == null) return V1
            if (o.randomTrailers == true || o.disableCookies == true) return V31
            if (o.headerProtectionKey != null || o.contentPaddingAddition != null ||
                o.hasTimingOverrides
            ) return V3
            if (o.cookiePadding != null || o.transportPadding != null ||
                listOf(o.header1, o.header2, o.header3, o.header4).any { it?.contains('-') == true }
            ) return V2
            if (o.specialHandshakes.isNotEmpty()) return V15
            return V1
        }
    }
}

/** A WireGuard/AmneziaWG peer profile: everything but the obfuscation. */
data class WireGuardProfile(
    val peerPublicKey: String,
    val presharedKey: String? = null,
    val allowedIPs: List<String> = listOf("0.0.0.0/0", "::/0"),
    val dns: List<String> = emptyList(),
    val mtu: Int? = null,
    val keepAlive: Int? = null,
) {
    /**
     * Резолверы, которые туннель действительно может поставить: адресные
     * записи `dns`, в порядке профиля.
     *
     * Строка `DNS =` у wg-quick смешанная: адреса уходят в `nameserver`, а
     * имена — в `search`, и то и другое законно. `VpnService.Builder
     * .addDnsServer` принимает только числовой адрес, поэтому имя в списке
     * означает отказ подъёма туннеля целиком; то же правило на iOS
     * (`NEDNSSettings.servers` — строки адресов, и объект имя не отвергает),
     * и оно же в Swift-оригинале (`WireGuardProfile.resolverAddresses`).
     */
    val resolverAddresses: List<String>
        get() = dns.filter { Addresses.isIPAddress(it) }
}

/** The server as the tunnel needs it: keys, endpoint, routes, obfuscation. */
data class WgServer(
    val name: String,
    val address: String,
    val port: Int,
    val privateKey: String,
    val profile: WireGuardProfile,
    val obfuscation: AwgObfuscation?,
    /** The profile's own `Address` list, normalized, as written. */
    val addresses: String?,
    /** Which flavor was asked for — `amnezia://` downgrades to `wg` when nothing obfuscates. */
    val proto: ProxyProtocol = ProxyProtocol.AMNEZIA,
) {
    companion object {
        /**
         * Обратное к [proxyServer]: сервер из подписки или из `state.json` —
         * это `ProxyServer`, а конфигураторам нужен `WgServer`. Без этого
         * моста приложение не могло ни собрать UAPI, ни запросить замечания
         * валидатора для сервера, который не пришёл из conf-файла.
         */
        fun of(server: ProxyServer): WgServer? = server.wgProfile?.let { profile ->
            WgServer(
                name = server.name,
                address = server.address,
                port = server.port,
                privateKey = server.credential,
                profile = profile,
                obfuscation = server.awg,
                addresses = server.userData?.get("wgAddress"),
                proto = server.proto,
            )
        }
    }

    /** The canonical model the server list and the engine config builders read. */
    fun proxyServer(name: String? = null): ProxyServer = ProxyServer(
        name = name?.takeIf { it.isNotEmpty() } ?: this.name,
        proto = proto,
        address = address,
        port = port,
        credential = privateKey,
        awg = obfuscation,
        wgProfile = profile,
        userData = mapOf("wgAddress" to (addresses ?: "")),
    )
}

data class AwgObfuscation(
    var junkPackets: Int? = null,
    var junkMin: Int? = null,
    var junkMax: Int? = null,
    var initPadding: Int? = null,
    var responsePadding: Int? = null,
    var cookiePadding: Int? = null,
    var transportPadding: Int? = null,
    var header1: String? = null,
    var header2: String? = null,
    var header3: String? = null,
    var header4: String? = null,
    var specialHandshakes: List<String> = emptyList(),
    var headerProtectionKey: String? = null,
    /**
     * Padding and the protocol timers are a value *or* a random range
     * ("10", "10-40"), so they stay strings — parsing them as numbers would
     * throw away the range form that 3.0+ configs use to hide the rhythm.
     */
    var contentPaddingAddition: String? = null,
    var rekeyAfterTime: String? = null,
    var rekeyTimeout: String? = null,
    var rejectAfterTime: String? = null,
    var keepaliveTimeout: String? = null,
    var maxHandshakeAttempts: String? = null,
    var randomTrailers: Boolean? = null,
    var disableCookies: Boolean? = null,
) {
    /** Randomized timers: a classifier can no longer lock onto the rhythm. */
    val hasTimingOverrides: Boolean
        get() = listOf(rekeyAfterTime, rekeyTimeout, rejectAfterTime, keepaliveTimeout,
                      maxHandshakeAttempts).any { it != null }

    /** No parameter at all — plain WireGuard on the wire. */
    val isEmpty: Boolean get() = this == AwgObfuscation()
}

/** A conf or link that is structurally unusable — missing key, bad endpoint. */
class AwgConfigException(reason: String) : Exception(PREFIX + reason) {
    /**
     * Префикс compose'ится здесь, как `ParseError.awgConfig(_:)` в Swift:
     * `.malformedURI("AmneziaWG config: \(reason)")`. Пока он добавлялся
     * только на выходе из парсера ссылок, конфиг, собранный при подключении,
     * приходил в интерфейс без него — то есть на iOS «Конфиг AmneziaWG: …»,
     * а на Android голое «private key is not …».
     */
    companion object { const val PREFIX = "AmneziaWG config: " }
    val reason: String get() = requireNotNull(message).removePrefix(PREFIX)
}

object AmneziaWg {
    /**
     * The range used when a profile names no IPv4 address of its own. The
     * server may refuse it — this is "connect anyway", not a guess that
     * usually works; re-importing the full config is the real fix. Shared
     * with the iOS tunnel and the macOS helper by the same value.
     */
    const val FALLBACK_TUN_ADDRESS = "172.29.0.1"

    /**
     * The interface address list of a profile, kept whole:
     * `Address = 10.8.1.2/32, fd42::2/128` means the peer has both, and
     * dropping either family leaves it routed into a tunnel with no address of
     * its own. Bare entries get the host prefix `wg-quick` assumes; entries
     * whose address or prefix the tunnel settings cannot express are dropped.
     */
    fun interfaceAddressList(list: String?): String? {
        if (list.isNullOrBlank()) return null
        val entries = list.split(',').mapNotNull { part ->
            val text = trimFoundationSpaces(part)
            if (text.isEmpty()) return@mapNotNull null
            // Swift splits on the first '/' and trims ONLY the whole entry:
            // "10.7.0.2/" still names a host address (the empty prefix part is
            // dropped by `omittingEmptySubsequences`), while "10.7.0.2 / 32" is
            // not an address at all and must not be quietly cleaned up.
            val slash = text.indexOf('/')
            val head = if (slash >= 0) text.substring(0, slash) else text
            val prefixPart = if (slash >= 0 && slash + 1 < text.length) text.substring(slash + 1) else null
            when {
                prefixPart != null -> {
                    val prefix = prefixPart?.let(::swiftInt)
                    if (!Addresses.isIPAddress(head) || prefix == null) return@mapNotNull null
                    val limit = if (head.contains(':')) 128 else 32
                    if (prefix !in 0..limit) return@mapNotNull null
                    text
                }
                Addresses.isIPv4(head) -> "$head/32"
                Addresses.isIPv6(head) -> "$head/128"
                else -> null
            }
        }
        return if (entries.isEmpty()) null else entries.joinToString(", ")
    }

    /** The entries a profile names, as written (with their prefixes). */
    fun tunnelAddresses(addresses: String?): List<String> =
        (addresses ?: "").split(',').map { trimFoundationSpaces(it) }.filter { it.isNotEmpty() }

    private fun addressPart(entry: String): String =
        trimFoundationSpaces(entry.substringBefore('/', entry))

    /**
     * The IPv4 the utun must carry, without its prefix: the server accepts
     * inner packets only from the addresses it assigned this peer. Loopback,
     * this-network and multicast/reserved are refused. The list is scanned,
     * not just its head — a dual-stack profile may name IPv6 first.
     */
    fun tunnelIPv4(addresses: String?): String? {
        for (entry in tunnelAddresses(addresses)) {
            val ip = addressPart(entry)
            if (!Addresses.isIPv4(ip)) continue
            val first = ip.substringBefore('.').toIntOrNull() ?: continue
            if (first == 0 || first == 127 || first >= 224) continue
            return ip
        }
        return null
    }

    /** The profile's own IPv6 address with its prefix, or null. */
    fun tunnelIPv6(addresses: String?): String? =
        tunnelAddresses(addresses).firstOrNull { addressPart(it).contains(':') }

    /** Один адрес туннельного интерфейса: как выдал профиль, со своим префиксом. */
    data class TunAddress(val address: String, val prefix: Int, val ipv6: Boolean)

    /**
     * Все адреса, которые профиль выдал этому peer, — IPv4 первыми, порядок
     * внутри семьи сохранён. Порт `TunnelPlan.amneziaWG`: там список режется по
     * запятым и каждый элемент доходит до `addAddress` со своим префиксом, а не
     * первым IPv4 без него: `10.8.0.5/24` — это не `10.8.0.5/32`, и dual-stack
     * конфиг с одним IPv4 оставляет IPv6 в туннеле без собственного адреса.
     * Отбор тут строже, чем в [tunnelIPv4]: тот отвечает за UAPI, где loopback
     * адрес бессмысленен, а туннель обязан выставить ровно то, что выдал
     * сервер, — иначе он расходится с профилем.
     */
    fun tunnelInterfaceAddresses(addresses: String?): List<TunAddress> {
        val parsed = tunnelAddresses(addresses).mapNotNull { entry ->
            val host = addressPart(entry)
            val ipv6 = host.contains(':')
            val width = if (ipv6) 128 else 32
            val valid = if (ipv6) Addresses.isIPv6(host) else Addresses.isIPv4(host)
            if (!valid) return@mapNotNull null
            // Префикс либо отсутствует совсем (тогда полная длина адреса), либо
            // обязан разбираться числом: `10.8.0.5/` — это не «/32», а отказ,
            // как у Swift `CIDR(_:)`.
            val suffix = entry.substringAfter('/', "")
            val prefix = suffix.toIntOrNull()
            if (entry.contains('/') && (prefix == null || prefix !in 0..width)) return@mapNotNull null
            TunAddress(host, prefix ?: width, ipv6)
        }
        return parsed.filter { !it.ipv6 } + parsed.filter { it.ipv6 }
    }

    /**
     * A WireGuard key as the engine wants it: lowercase hex. Conf files carry
     * base64; the conversion is what the `awg` tool does on the way in, and a
     * base64 key handed to UAPI is rejected outright (`FromHex`) — no session,
     * and no clue in the log.
     */
    fun hexKey(raw: String): String? {
        val text = trimFoundationSpaces(raw)
        if (text.length == 64 && text.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) {
            return text.lowercase()
        }
        val data = runCatching { java.util.Base64.getDecoder().decode(text) }.getOrNull()
        if (data == null || data.size != 32) return null
        return data.joinToString("") { String.format(java.util.Locale.ROOT, "%02x", it.toInt() and 0xFF) }
    }

    /**
     * The `set=1` script for a running device. Empty parameters are omitted
     * rather than sent blank: the engine rejects `h1=` with an empty value,
     * and a plain-WireGuard server needs the obfuscation lines absent, not
     * present-but-empty.
     *
     * [endpointAddress] replaces the server's own address on the `endpoint=`
     * line — the engine parses that value with `netip.ParseAddrPort`, so a
     * hostname there fails the whole set.
     */
    /**
     * Точка входа, которую зовёт приложение: сервер из подписки или из
     * `state.json` — это `ProxyServer`, а `WgServer` существует только у
     * разбора conf-файла. Swift умеет ровно так (`makeUAPISetScript(server:
     * ProxyServer, …)`), и без этой перегрузки порт не мог собрать UAPI для
     * сервера, который не пришёл из файла, — то есть для любого сервера из
     * подписки.
     */
    fun uapiScript(server: ProxyServer, endpointAddress: String? = null): String {
        val wg = WgServer.of(server) ?: throw AwgConfigException("no peer profile")
        return uapiScript(wg, endpointAddress)
    }

    fun uapiScript(server: WgServer, endpointAddress: String? = null): String {
        val privateKey = hexKey(server.privateKey)
            ?: throw AwgConfigException("private key is not a 32-byte base64 key")
        val publicKey = hexKey(server.profile.peerPublicKey)
            ?: throw AwgConfigException("peer public key is not a 32-byte base64 key")
        val lines = mutableListOf("set=1", "private_key=$privateKey")

        server.obfuscation?.let { o ->
            fun num(key: String, value: Int?) {
                if (value != null) lines.add("$key=$value")
            }
            fun text(key: String, value: String?) {
                if (!value.isNullOrEmpty()) lines.add("$key=$value")
            }
            num("jc", o.junkPackets); num("jmin", o.junkMin); num("jmax", o.junkMax)
            num("s1", o.initPadding); num("s2", o.responsePadding)
            num("s3", o.cookiePadding); num("s4", o.transportPadding)
            for ((index, raw) in listOf(o.header1, o.header2, o.header3, o.header4).withIndex()) {
                text("h${index + 1}", raw)
            }
            for ((index, raw) in o.specialHandshakes.take(5).withIndex()) {
                text("i${index + 1}", raw)
            }
            o.headerProtectionKey?.let { raw ->
                if (raw.isNotEmpty()) {
                    val key = hexKey(raw) ?: throw AwgConfigException("HeaderProtectionKey is not a 32-byte key")
                    lines.add("header_protection_key=$key")
                }
            }
            text("content_padding_addition", o.contentPaddingAddition)
            text("rekey_after_time", o.rekeyAfterTime)
            text("rekey_timeout", o.rekeyTimeout)
            text("reject_after_time", o.rejectAfterTime)
            text("keepalive_timeout", o.keepaliveTimeout)
            text("max_handshake_attempts", o.maxHandshakeAttempts)
            o.randomTrailers?.let { lines.add("random_trailers=$it") }
            o.disableCookies?.let { lines.add("disable_cookies=$it") }
        }

        lines.add("replace_peers=true")
        lines.add("public_key=$publicKey")
        server.profile.presharedKey?.takeIf { it.isNotEmpty() }?.let { raw ->
            val key = hexKey(raw) ?: throw AwgConfigException("preshared key is not a 32-byte base64 key")
            lines.add("preshared_key=$key")
        }
        val host = endpointAddress ?: server.address
        val endpoint = if (host.contains(':')) "[$host]:${server.port}" else "$host:${server.port}"
        lines.add("endpoint=$endpoint")
        server.profile.keepAlive?.let { lines.add("persistent_keepalive_interval=$it") }
        lines.add("replace_allowed_ips=true")
        server.profile.allowedIPs.filter { it.isNotEmpty() }
            .forEach { lines.add("allowed_ip=$it") }
        lines.add("protocol_version=1")
        // UAPI scripts end with a blank line.
        return lines.joinToString("\n", postfix = "\n\n")
    }
}
