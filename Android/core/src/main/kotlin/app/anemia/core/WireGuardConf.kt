package app.anemia.core

/**
 * The wg-quick `[Interface]`/`[Peer]` conf — the interchange format of the
 * Amnezia app, wg-quick itself and every panel's export.
 *
 * Port of `parseConfigText` in `Sources/LoaderCore/ShareLinkParser.swift`.
 * Keys are matched case-insensitively, and the obfuscation keys accept the
 * wiki's CamelCase (`Jc`, `H1`), the UAPI's lowercase (`jc`, `h1`) and
 * v2rayN's verbose aliases, so output from any generator imports.
 */
object WireGuardConf {

    fun parse(raw: String, proto: ProxyProtocol = ProxyProtocol.AMNEZIA): WgServer {
        // A UTF-8 BOM (normal for .conf files exported on Windows, or pasted
        // from an editor that emits one) is not whitespace to a line scan: it
        // hid the leading "[Interface]" and the whole section was silently
        // dropped, failing with a misleading "missing PrivateKey".
        var text = raw
        if (text.isNotEmpty() && text[0] == '\uFEFF') text = text.substring(1)
        text = trimSpaceLike(text)
        val lower = text.lowercase()
        if (!lower.contains("[interface]") && !lower.contains("[peer]")) {
            throw AwgConfigException("not a WireGuard config (no [Interface]/[Peer] section)")
        }

        var section = ""
        val iface = mutableMapOf<String, String>()
        val peer = mutableMapOf<String, String>()
        for (line in splitOnNewlines(text)) {
            val entry = trimFoundationSpaces(line)
            if (entry.startsWith("[")) {
                section = entry.lowercase()
                continue
            }
            if (section.isEmpty()) continue
            val equals = entry.indexOf('=')
            if (equals < 0) continue
            val key = trimFoundationSpaces(entry.substring(0, equals)).lowercase()
            val value = trimFoundationSpaces(entry.substring(equals + 1))
            when (section) {
                "[interface]" -> iface[key] = value
                "[peer]" -> peer[key] = value
            }
        }

        val privateKey = iface["privatekey"]?.takeIf { it.isNotEmpty() }
            ?: throw AwgConfigException("missing PrivateKey")
        val publicKey = peer["publickey"]?.takeIf { it.isNotEmpty() }
            ?: throw AwgConfigException("missing peer PublicKey")
        val endpoint = peer["endpoint"]?.takeIf { it.isNotEmpty() }
            ?: throw AwgConfigException("missing Endpoint in [Peer]")

        val host = hostOf(endpoint)
        val port = portOf(endpoint)
            ?: throw AwgConfigException("Endpoint must be host:port — got $endpoint")

        val obfuscation = obfuscationFrom(iface)
        val profile = WireGuardProfile(
            peerPublicKey = publicKey,
            presharedKey = peer["presharedkey"]?.takeIf { it.isNotEmpty() },
            // An empty `AllowedIPs =` keeps the full-tunnel default rather than
            // becoming a tunnel that routes nothing.
            allowedIPs = peer["allowedips"]?.takeIf { it.isNotEmpty() }?.let { list ->
                list.split(',').map { trimFoundationSpaces(it) }.filter { it.isNotEmpty() }
            } ?: listOf("0.0.0.0/0", "::/0"),
            dns = (iface["dns"] ?: "").split(',').map { trimFoundationSpaces(it) }.filter { it.isNotEmpty() },
            mtu = iface["mtu"]?.let(::swiftInt),
            // Both spellings are tried until one parses, the way Swift's
            // `flatMap(Int.init) ?? …` does: an unusable `PersistentKeepalive`
            // must not hide a good `PersistentKeepaliveInterval`.
            keepAlive = peer["persistentkeepalive"]?.let(::swiftInt)
                ?: peer["persistentkeepaliveinterval"]?.let(::swiftInt),
        )
        // Any parameter at all makes it AmneziaWG: a 2.x/3.x conf whose only
        // obfuscation key is, say, ContentPaddingAddition must not be
        // downgraded to plain WireGuard — the handshake would fail silently.
        // The reverse also holds: an `amnezia://` conf with no obfuscation at
        // all is WireGuard in disguise, and the engine choice should match.
        val actualProto =
            if (proto == ProxyProtocol.AMNEZIA && obfuscation == null) ProxyProtocol.WIREGUARD else proto
        return WgServer(
            name = host,
            address = host,
            port = port,
            privateKey = privateKey,
            profile = profile,
            obfuscation = obfuscation,
            addresses = AmneziaWg.interfaceAddressList(iface["address"]),
            proto = actualProto,
        )
    }

    /** `Endpoint = [fd42::1]:51820`, `host:port`, or a `host:port/path`. */
    private fun hostOf(endpoint: String): String {
        var value = endpoint
        val slash = value.indexOf('/')
        if (slash >= 0) value = value.substring(0, slash)
        if (value.startsWith("[") && value.contains("]")) {
            return value.substring(1, value.indexOf(']'))
        }
        val colon = value.lastIndexOf(':')
        return if (colon >= 0) value.substring(0, colon) else value
    }

    private fun portOf(endpoint: String): Int? {
        var value = endpoint
        val slash = value.indexOf('/')
        if (slash >= 0) value = value.substring(0, slash)
        val colon = value.lastIndexOf(':')
        if (colon < 0) return null
        return swiftInt(value.substring(colon + 1))?.takeIf { it in 1..65535 }
    }

    /**
     * Obfuscation parameters from a map of already-lowercased keys — an
     * `[Interface]` section or a `wireguard://` query, which use the same
     * names. Conf files spell the headers `H1 = 1234567-1234599` and the
     * timers `RekeyAfterTime = 60-120`; ranges stay strings, parsing them as
     * numbers would drop the range form.
     */
    internal fun obfuscationFrom(fields: Map<String, String>): AwgObfuscation? {
        fun intKey(vararg keys: String): Int? =
            keys.firstNotNullOfOrNull { fields[it]?.let(::swiftInt) }

        fun strKey(vararg keys: String): String? =
            keys.firstNotNullOfOrNull { fields[it]?.takeIf { v -> v.isNotEmpty() } }

        val o = AwgObfuscation(
            junkPackets = intKey("jc", "junkpacketcount"),
            junkMin = intKey("jmin", "junkpacketminsize"),
            junkMax = intKey("jmax", "junkpacketmaxsize"),
            initPadding = intKey("s1", "initpacketjunksize"),
            responsePadding = intKey("s2", "responsepacketjunksize"),
            cookiePadding = intKey("s3", "cookiepacketjunksize"),
            transportPadding = intKey("s4", "transportpacketjunksize"),
            header1 = strKey("h1", "magicheader1"),
            header2 = strKey("h2", "magicheader2"),
            header3 = strKey("h3", "magicheader3"),
            header4 = strKey("h4", "magicheader4"),
            specialHandshakes = (1..5).mapNotNull { strKey("i$it") },
            headerProtectionKey = strKey("headerprotectionkey"),
            contentPaddingAddition = strKey("contentpaddingaddition"),
            rekeyAfterTime = strKey("rekeyaftertime"),
            rekeyTimeout = strKey("rekeytimeout"),
            rejectAfterTime = strKey("rejectaftertime"),
            keepaliveTimeout = strKey("keepalivetimeout"),
            maxHandshakeAttempts = strKey("maxhandshakeattempts"),
            randomTrailers = fields["randomtrailers"]?.let { flag(it) },
            disableCookies = fields["disablecookies"]?.let { flag(it) },
        )
        return if (o.isEmpty) null else o
    }

    /** Conf booleans: `on`/`off` (amneziawg-tools), `1`/`0`, `true`/`false`. */
    internal fun flag(raw: String): Boolean =
        trimFoundationSpaces(raw).lowercase() in setOf("1", "true", "on", "yes")
}
