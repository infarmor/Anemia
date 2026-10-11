package app.anemia.core

/**
 * Share links → [ProxyServer]. Port of `ShareLinkParser` in
 * `Sources/LoaderCore/ShareLinkParser.swift`.
 *
 * Covered here: every scheme the Swift parser accepts — `vless://`,
 * `trojan://`, `vmess://`, `ss://`, `hysteria2://`/`hy2://`, `hysteria://`,
 * the WireGuard family (`amnezia://`, `awg://`, `wireguard://`, `wg://`, in
 * both the base64-conf and the query-parameter encoding) and the Amnezia
 * `vpn://` container. Raw `[Interface]`/`[Peer]` text is handled by
 * [WireGuardConf].
 */
object ShareLinkParser {

    fun parse(raw: String): ProxyServer {
        val link = trimSpaceLike(raw)
        if (link.isEmpty()) throw ProxyParseException("emptyInput")
        val separator = link.indexOf("://")
        if (separator < 0) throw ProxyParseException("malformedURI", link)
        return when (val scheme = link.substring(0, separator).lowercase()) {
            "vless" -> parseVless(link)
            "trojan" -> parseTrojan(link)
            "ss" -> parseShadowsocks(link)
            "vmess" -> parseVmess(link)
            "hysteria2", "hy2" -> parseHysteria(link, 2)
            "hysteria" -> parseHysteria(link, 1)
            "amnezia", "awg" -> parseAwgLink(link, scheme, ProxyProtocol.AMNEZIA)
            "wireguard", "wg" -> parseAwgLink(link, scheme, ProxyProtocol.WIREGUARD)
            "vpn" -> parseVpnLink(link)
            else -> throw ProxyParseException("unsupportedScheme", scheme)
        }
    }

    // MARK: - VLESS / Trojan

    private fun parseVless(link: String): ProxyServer {
        val uri = UriParts(link)
        val uuid = uri.userInfo?.takeIf { it.isNotEmpty() }
            ?: throw ProxyParseException("missingField", "uuid")
        val host = uri.host ?: throw ProxyParseException("missingField", "host/port")
        val port = uri.port ?: throw ProxyParseException("missingField", "host/port")
        validatePort(port, link)
        val q = uri.query
        var server = ProxyServer(
            name = uri.fragment ?: host,
            proto = ProxyProtocol.VLESS,
            address = host,
            port = port,
            credential = uuid,
            network = networkType(q["type"]),
            security = securityValue(q["security"], StreamSecurity.NONE),
            flow = q["flow"]?.takeIf { it.isNotEmpty() },
        )
        // VLESS Encryption: a server with `decryption` set refuses plain
        // clients, so the link's string has to reach the outbound.
        server = server.copy(
            vlessEncryption = q["encryption"]?.takeIf { it.isNotEmpty() && it.lowercase() != "none" }
        )
        return applyStreamParams(server, q)
    }

    private fun parseTrojan(link: String): ProxyServer {
        val uri = UriParts(link)
        val password = uri.userInfo?.takeIf { it.isNotEmpty() }
            ?: throw ProxyParseException("missingField", "password")
        val host = uri.host ?: throw ProxyParseException("missingField", "host/port")
        val port = uri.port ?: throw ProxyParseException("missingField", "host/port")
        validatePort(port, link)
        val q = uri.query
        // Trojan defaults to TLS even when `security` is omitted, and carries
        // no `flow`: a stray `flow=` would reach the trojan outbound where
        // Xray rejects unknown flow values at config validation.
        val server = ProxyServer(
            name = uri.fragment ?: host,
            proto = ProxyProtocol.TROJAN,
            address = host,
            port = port,
            credential = password,
            network = networkType(q["type"]),
            security = securityValue(q["security"], StreamSecurity.TLS),
        )
        return applyStreamParams(server, q)
    }

    // MARK: - Hysteria

    private fun parseHysteria(rawLink: String, version: Int): ProxyServer {
        // Port hopping lives in the authority (`host:443,20000-50000`), which
        // no URL grammar accepts; it used to swallow the whole spec into the
        // host name.
        val (link, portSpec) = splitHysteriaPorts(rawLink)
        val uri = UriParts(link)
        val host = uri.host?.takeIf { it.isNotEmpty() }
            ?: throw ProxyParseException("malformedURI", link)
        val port = uri.port ?: if (version == 2) 443 else 80
        validatePort(port, link)
        // Query keys arrive in their original case (obfsParam, UpMbps…), and
        // panels mix spellings freely.
        val q = lowerCased(uri.query)
        // Hysteria 2 carries the password in the userinfo, v1 in the query;
        // either spot is accepted, but an empty one is a missing field.
        val auth = uri.userInfo ?: q["auth"]
        if (auth.isNullOrEmpty()) {
            throw ProxyParseException(
                "missingField",
                if (version == 2) "auth (userinfo password)" else "auth query"
            )
        }
        val extras = linkedMapOf("hysteriaVersion" to version.toString())
        if (portSpec != null) extras["portHopping"] = portSpec
        val name = uri.fragment ?: host

        if (version == 2) {
            q["obfs"]?.let { extras["obfs"] = it }
            // Swift walks a dictionary here, so a link carrying both
            // spellings has no defined winner; the port prefers the
            // hyphenated, standard one.
            (q["obfs-password"] ?: q["obfsparam"])?.let { extras["obfsPassword"] = it }
            q["pinsha256"]?.let { extras["pinSHA256"] = it }
            if (!extras.containsKey("portHopping")) {
                (q["mport"] ?: q["ports"])?.let { extras["portHopping"] = it }
            }
            // Тот же `alpn`, что умеет ветка v1 ниже: оба написания уходят в
            // один YAML-билдер, а `HysteriaConfigBuilder` печатает `alpn:` из
            // поля сервера — потерянный здесь параметр означал рукопожатие с
            // дефолтным `h3` там, где сервер просит `http/1.1`, и ни одной
            // ошибки в конфиге. Разбивка та же, что у v1: пустые поля остаются.
            val hy2Alpn = if ((q["alpn"] ?: "").isEmpty()) emptyList() else commaList(q["alpn"]!!, keepEmpty = true)
            return ProxyServer(
                name = name, proto = ProxyProtocol.HYSTERIA2, address = host, port = port,
                credential = auth, security = StreamSecurity.TLS,
                sni = q["sni"] ?: q["peer"], alpn = hy2Alpn,
                allowInsecure = boolParam(q["insecure"]),
                userData = extras,
            )
        }
        (q["obfsparam"] ?: q["obfs-param"])?.let { extras["obfsPassword"] = it }
        q["obfs"]?.let { extras["obfs"] = it }
        (q["upmbps"] ?: q["up"])?.let { extras["upmbps"] = it }
        (q["downmbps"] ?: q["down"])?.let { extras["downmbps"] = it }
        q["protocol"]?.let { extras["protocol"] = it }
        // v1 splits with `components(separatedBy:)`, which keeps empty fields —
        // `alpn=h3,,h2` is three entries here and two for a VLESS link.
        val alpn = if ((q["alpn"] ?: "").isEmpty()) emptyList() else commaList(q["alpn"]!!, keepEmpty = true)
        return ProxyServer(
            name = name, proto = ProxyProtocol.HYSTERIA, address = host, port = port,
            credential = auth, security = StreamSecurity.TLS,
            sni = q["peer"] ?: q["sni"], alpn = alpn,
            allowInsecure = boolParam(q["insecure"]),
            userData = extras,
        )
    }

    /** `scheme://auth@host:443,20000-50000/?…` → link with one port, plus the spec. */
    internal fun splitHysteriaPorts(link: String): Pair<String, String?> {
        val separator = link.indexOf("://")
        if (separator < 0) return link to null
        val rest = link.substring(separator + 3)
        val authorityEnd = rest.indexOfFirst { it == '/' || it == '?' || it == '#' }
        val authority = if (authorityEnd < 0) rest else rest.substring(0, authorityEnd)
        val hostStart = authority.lastIndexOf('@').let { if (it < 0) 0 else it + 1 }
        val hostPort = authority.substring(hostStart)
        val colon = if (hostPort.startsWith("[")) {
            val close = hostPort.indexOf(']')
            // Only the colon right after the brackets is a port separator; the
            // ones inside an IPv6 literal are part of the address.
            if (close >= 0 && close + 1 < hostPort.length && hostPort[close + 1] == ':') close + 1 else -1
        } else {
            hostPort.lastIndexOf(':')
        }
        if (colon < 0) return link to null
        val specStart = separator + 3 + hostStart + colon + 1
        val spec = hostPort.substring(colon + 1)
        if (!spec.any { it == ',' || it == '-' } || !isValidPortSpec(spec)) return link to null
        val first = spec.split(',', '-').firstOrNull { it.isNotEmpty() } ?: return link to null
        return (link.substring(0, specStart) + first +
            (if (authorityEnd < 0) "" else rest.substring(authorityEnd))) to spec
    }

    /** A port list like `443`, `20000-50000`, `443,8443` — as the engine validates it. */
    internal fun isValidPortSpec(spec: String): Boolean =
        spec.split(',').all { item ->
            val bounds = item.split('-')
            bounds.size in 1..2 &&
                bounds.map { field ->
                    field.takeIf { it.isNotEmpty() && it.length <= 5 && it.all { char -> char in '0'..'9' } }
                        ?.let(::swiftInt)?.takeIf { it in 1..65535 }
                }.let { ports ->
                    ports.all { it != null } &&
                        (ports.size == 1 || (ports[0] ?: 0) <= (ports[1] ?: 0))
                }
        }

    // MARK: - Amnezia vpn:// container

    /**
     * The Amnezia app's config-share format: `vpn://` + base64url (unpadded) of
     * either a Qt `qCompress` blob (4-byte big-endian uncompressed-length
     * header, then a zlib stream) or, uncompressed, plain base64 of the JSON
     * itself. The JSON is an envelope whose containers carry either a wg-quick
     * INI — which [WireGuardConf] eats — or a share link for the ordinary
     * parser.
     */
    private fun parseVpnLink(link: String): ProxyServer {
        var payload = trimSpaceLike(link.substringAfter("://", link))
        if (payload.isEmpty()) throw ProxyParseException("malformedURI", link)
        // A trailing fragment (#Name) is decoration some generators add.
        payload = payload.substringBefore('#')
        var data = Base64.decodeFlexible(payload) ?: throw ProxyParseException("invalidBase64")

        // qUncompress by hand: peel the 4-byte length header and the 2-byte
        // zlib wrapper (CMF 0x78 + FLG, FCHECK makes CMF<<8|FLG divisible by
        // 31), inflate the rest and leave the 4-byte Adler-32 tail unread. Only
        // attempted when the header really looks like qCompress, because Amnezia
        // also exports the JSON uncompressed.
        val wrapper =
            if (data.size > 6) (data[4].toInt() and 0xFF) * 256 + (data[5].toInt() and 0xFF) else -1
        if (data.size > 6 && (data[4].toInt() and 0xFF) == 0x78 && wrapper % 31 == 0) {
            val expected = ((data[0].toInt() and 0xFF) shl 24) or
                ((data[1].toInt() and 0xFF) shl 16) or
                ((data[2].toInt() and 0xFF) shl 8) or
                (data[3].toInt() and 0xFF)
            if (expected in 1..16_000_000) {
                val inflated = inflateRaw(data.copyOfRange(6, data.size), expected)
                if (inflated != null && inflated.size == expected) data = inflated
            }
        }

        // The Amnezia JSON envelope first: its double-serialized last_config
        // also *contains* the literal "[Interface]", so checking for the INI
        // first swallowed every real Amnezia export.
        val text = utf8(data)
        @Suppress("UNCHECKED_CAST")
        val envelope = text?.let { runCatching { Json.parse(it) }.getOrNull() } as? Map<String, Any?>
        if (envelope != null) return serverFromEnvelope(envelope, link)
        // 3x-ui and other panels put the verbatim wg-quick conf straight into
        // the payload — base64url of the INI text, not the Amnezia envelope.
        if (text != null && text.contains("[Interface]")) {
            return parseWgConf(text, ProxyProtocol.AMNEZIA).proxyServer()
        }
        throw ProxyParseException("malformedURI", "vpn link: not an Amnezia config (undecodable JSON)")
    }

    @Suppress("UNCHECKED_CAST")
    private fun serverFromEnvelope(env: Map<String, Any?>, link: String): ProxyServer {
        val listed = (env["containers"] as? List<*>)
            ?.takeIf { list -> list.all { it is Map<*, *> } } as? List<Map<String, Any?>> ?: emptyList()
        // Prefer the container defaultContainer names; else the first
        // protocol-shaped one in document order.
        val wanted = env["defaultContainer"] as? String
        val container = wanted?.let { id -> listed.firstOrNull { (it["container"] as? String) == id } }
            ?: listed.firstOrNull()

        if (container != null) {
            val kind = (container["container"] as? String)?.lowercase() ?: ""
            if (!kind.contains("xray")) {
                for (key in listOf("awg", "wireguard")) {
                    val cfg = container[key] as? Map<String, Any?> ?: continue
                    var ini = lastConfigString(cfg)?.let { iniFromLastConfig(it) }
                    // Older exports store the INI directly under the container.
                    if (ini == null) {
                        val direct = container["config"] as? String
                        if (direct != null && direct.contains("[Interface]")) ini = direct
                    }
                    if (ini == null) {
                        throw ProxyParseException(
                            "malformedURI", "vpn link: WireGuard container without a usable config"
                        )
                    }
                    var conf = ini
                    // The envelope is authoritative for DNS when the INI is silent.
                    val dns = listOf(env["dns1"], env["dns2"]).filterIsInstance<String>()
                        .filter { it.isNotEmpty() }
                    if (dns.isNotEmpty() && !conf.lowercase().contains("dns")) {
                        conf += "\nDNS = ${dns.joinToString(", ")}"
                    }
                    return parseWgConf(
                        conf, if (kind.contains("awg")) ProxyProtocol.AMNEZIA else ProxyProtocol.WIREGUARD
                    ).proxyServer(name = (env["description"] as? String)?.takeIf { it.isNotEmpty() })
                }
            }
            if (kind.contains("xray")) {
                for (key in listOf("xray", "vless")) {
                    val cfg = container[key] as? Map<String, Any?> ?: continue
                    val inner = lastConfigString(cfg) ?: continue
                    val trimmed = trimSpaceLike(inner)
                    if (trimmed.lowercase().contains("://")) return parse(trimmed)
                    // A raw JSON xray config: fish the vless link out of it.
                    @Suppress("UNCHECKED_CAST")
                    val config = runCatching { Json.parse(trimmed) }.getOrNull() as? Map<String, Any?>
                    val found = config?.values?.firstOrNull {
                        it is String && it.lowercase().startsWith("vless://")
                    }
                    if (found != null) return parse(found as String)
                }
                throw ProxyParseException("unsupportedScheme", "vpn link: xray container without a vless link")
            }
        }

        // No containers at all: the JSON itself may already be a last_config,
        // because some generators skip the envelope.
        iniFromLastConfig(Json.write(env))?.let {
            return parseWgConf(it, ProxyProtocol.AMNEZIA).proxyServer()
        }
        throw ProxyParseException(
            "unsupportedScheme", "vpn link: no supported container (amnezia-awg / wireguard / xray)"
        )
    }

    /** `last_config` is a JSON string, or a double-serialized JSON object. */
    private fun lastConfigString(obj: Map<String, Any?>): String? = when (val raw = obj["last_config"]) {
        is String -> raw
        is Map<*, *> -> Json.write(raw)
        else -> null
    }

    /**
     * The wg-quick INI inside a `last_config` value: it may already BE the INI,
     * or a JSON object whose `config` field holds it. JSON is tried first — the
     * double-serialized form still *contains* the literal `[Interface]` inside a
     * JSON string, and handing that blob to the INI parser failed on "missing
     * PrivateKey".
     */
    private fun iniFromLastConfig(raw: String): String? {
        val trimmed = trimSpaceLike(raw)
        if (trimmed.isEmpty()) return null
        if (trimmed.startsWith("{")) {
            @Suppress("UNCHECKED_CAST")
            val obj = runCatching { Json.parse(trimmed) }.getOrNull() as? Map<String, Any?>
            val conf = obj?.get("config") as? String
            if (conf != null && conf.lowercase().contains("[interface]")) return conf
        }
        return if (trimmed.lowercase().contains("[interface]")) trimmed else null
    }

    /** Raw-DEFLATE inflate of a zlib stream with the wrapper already peeled off. */
    private fun inflateRaw(bytes: ByteArray, expectedBytes: Int): ByteArray? {
        val inflater = java.util.zip.Inflater(true)
        val out = ByteArray(expectedBytes)
        return try {
            inflater.setInput(bytes)
            var written = 0
            while (written < expectedBytes && !inflater.finished()) {
                val step = inflater.inflate(out, written, expectedBytes - written)
                if (step == 0) break
                written += step
            }
            if (written > 0) out.copyOf(written) else null
        } catch (error: java.util.zip.DataFormatException) {
            null
        } finally {
            inflater.end()
        }
    }

    // MARK: - AmneziaWG / WireGuard

    /**
     * Two encodings exist:
     *   * `amnezia://BASE64` — base64 of a whole wg-quick conf (the Amnezia
     *     app's export; `awg://` likewise), and
     *   * `wireguard://privkey@host:port?publickey=…&junkPacketCount=…` — the
     *     query-parameter form panels emit (Hiddify/v2rayN naming).
     * The base64 alphabet never contains "://", so the two are told apart by
     * the presence of an `@host` authority or a leading `?`.
     */
    private fun parseAwgLink(link: String, scheme: String, proto: ProxyProtocol): ProxyServer {
        var body = link.substring(scheme.length + 3)
        var name: String? = null
        val hash = body.indexOf('#')
        if (hash >= 0) {
            name = percentDecoded(body.substring(hash + 1))?.let { displayNameFromFragment(it) }
            body = body.substring(0, hash)
        }
        val hasAuthority = hasLeadingAuthority(body)
        val looksLikeQuery = body.contains('?')
        if ((hasAuthority || looksLikeQuery) && !body.contains("[Interface]")) {
            return parseAwgQueryLink(body, proto, name, link)
        }
        // Base64 of a whole conf, possibly percent-wrapped by the exporter.
        val unescaped = percentDecodedOrRaw(body)
        val decoded = Base64.decodeToString(body) ?: Base64.decodeToString(unescaped)
        if (decoded == null || !decoded.contains("[Interface]") && !decoded.contains("[Peer]")) {
            throw ProxyParseException("malformedURI", link)
        }
        return parseWgConf(decoded, proto).proxyServer(name)
    }

    /** `^[^/?#]+@` — the authority form, without the regex the Swift uses. */
    private fun hasLeadingAuthority(body: String): Boolean {
        var index = 0
        while (index < body.length && body[index] != '/' && body[index] != '?' && body[index] != '#') {
            // Swift's regex is `^[^/?#]+@`, and "@" itself is in that class:
            // "@@host" matches (the first "@" is the run, the second the
            // separator), so any "@" inside the leading run means authority.
            if (body[index] == '@') return true
            index += 1
        }
        return false
    }

    /**
     * `wireguard://` / `wg://` with query parameters — both the lowercase
     * UAPI-ish names (`publickey`, `allowedips`, `junkPacketCount`) and
     * v2rayN's CamelCase aliases, case-insensitively.
     */
    private fun parseAwgQueryLink(
        body: String, proto: ProxyProtocol, name: String?, link: String,
    ): ProxyServer {
        var rest = if (body.startsWith("?")) body.substring(1) else body
        var authority = rest
        var queryRaw = ""
        val question = rest.indexOf('?')
        if (question >= 0) {
            queryRaw = rest.substring(question + 1)
            authority = rest.substring(0, question)
        }
        val q = mutableMapOf<String, String>()
        for (pair in queryRaw.split('&').filter { it.isNotEmpty() }) {
            q[pair.substringBefore('=').lowercase()] = percentDecodedOrRaw(pair.substringAfter('=', ""))
        }

        var privateKey = ""
        var host = ""
        var port = 0
        val at = authority.lastIndexOf('@')
        if (at >= 0) {
            val userRaw = authority.substring(0, at)
            // Doubly-encoded userinfo — base64 OF the 44-character key, so the
            // payload is those 44 ASCII bytes — unwrapped here; anything else
            // is the key itself, percent-unescaped.
            privateKey = Base64.decodeFlexible(userRaw)
                ?.takeIf { it.size == 44 }
                ?.let { utf8(it) }
                ?.takeIf { it.length == 44 }
                ?: percentDecodedOrRaw(userRaw)
            authority = authority.substring(at + 1)
        }
        if (privateKey.isEmpty()) privateKey = q["privatekey"] ?: ""
        if (privateKey.isEmpty()) throw ProxyParseException("missingField", "private key")
        val colon = authority.lastIndexOf(':')
        if (colon >= 0) {
            val parsed = swiftInt(authority.substring(colon + 1))
            if (parsed != null && parsed in 1..65535) {
                // IPv6 literals arrive bracketed in authority position; a stored
                // "[2001:db8::1]" fails getaddrinfo at connect.
                var head = authority.substring(0, colon)
                if (head.length > 2 && head.startsWith("[") && head.endsWith("]")) {
                    head = head.substring(1, head.length - 1)
                }
                host = head
                port = parsed
            }
        }
        if (host.isEmpty() || port <= 0) throw ProxyParseException("missingField", "host/port")

        val profile = WireGuardProfile(
            peerPublicKey = q["publickey"] ?: "",
            presharedKey = q["presharedkey"]?.takeIf { it.isNotEmpty() },
            allowedIPs = (q["allowedips"] ?: "0.0.0.0/0, ::/0")
                .split(',').map { trimFoundationSpaces(it) }.filter { it.isNotEmpty() },
            dns = (q["dns"] ?: "").split(',').map { trimFoundationSpaces(it) }.filter { it.isNotEmpty() },
            mtu = q["mtu"]?.let(::swiftInt),
            keepAlive = q["keepalive"]?.let(::swiftInt)
                ?: q["persistentkeepaliveinterval"]?.let(::swiftInt),
        )
        var server = ProxyServer(
            name = name ?: host, proto = proto, address = host, port = port,
            credential = privateKey,
            awg = WireGuardConf.obfuscationFrom(q),
            wgProfile = profile,
        )
        if (proto == ProxyProtocol.AMNEZIA && server.awg == null) {
            // An amnezia:// query link with no obfuscation parameters at all
            // would be indistinguishable from plain WireGuard — keep the AWG
            // label but let the engine run the unobfuscated handshake.
            server = server.copy(awg = AwgObfuscation())
        }
        // The interface address (v2rayN `address`, sing-box `ip`,
        // `localaddress`): like a conf's Address, the only source the server
        // accepts inner packets from.
        val address = (q["address"] ?: q["ip"] ?: q["localaddress"])
            ?.let { AmneziaWg.interfaceAddressList(it) }
        if (address != null) server = server.copy(userData = mapOf("wgAddress" to address))
        return server
    }

    /**
     * `ShareLinkParser.parseConfigText(_:proto:)` — wg-quick конфиг как сервер.
     * Публичный вход для импорта текста из буфера или файла.
     */
    fun parseConfigText(raw: String, proto: ProxyProtocol = ProxyProtocol.AMNEZIA): ProxyServer =
        parseWgConf(raw, proto).proxyServer()

    /** Тот же разбор, что и выше, но профилем наружу: тот же текст ошибок Swift. */
    private fun parseWgConf(raw: String, proto: ProxyProtocol): WgServer =
        try {
            WireGuardConf.parse(raw, proto)
        } catch (error: AwgConfigException) {
            throw ProxyParseException("malformedURI", error.message ?: "")
        }

    // MARK: - Shadowsocks

    /**
     * Two encodings:
     *   legacy:  `ss://base64(method:password@host:port)#name`, and
     *   SIP002:  `ss://base64(method:password)@host:port/?plugin=…#name`.
     */
    private fun parseShadowsocks(link: String): ProxyServer {
        var body = link.substring("ss://".length)
        var name: String? = null
        val hash = body.indexOf('#')
        if (hash >= 0) {
            name = percentDecoded(body.substring(hash + 1))?.let { displayNameFromFragment(it) }
            body = body.substring(0, hash)
        }
        // The query is kept rather than dropped: panels append parameters to
        // legacy links too, where a leftover `?…` tail would shift the base64
        // decode, and the SIP002 branch reads it for a load-bearing plugin.
        var query: String? = null
        val question = body.indexOf('?')
        if (question >= 0) {
            query = body.substring(question + 1)
            body = body.substring(0, question)
        }

        if (!body.contains('@')) {
            val decoded = Base64.decodeToString(body)
                ?: throw ProxyParseException("invalidBase64")
            val at = decoded.lastIndexOf('@')
            if (at < 0) throw ProxyParseException("malformedURI", link)
            return shadowsocks(name, decoded.substring(0, at), decoded.substring(at + 1), link)
        }

        query?.let { spec ->
            // A SIP003 plugin (obfs-local, v2ray-plugin, shadow-tls) is
            // obfuscation the engine cannot run; importing the link as plain
            // Shadowsocks would look healthy and then fail every handshake
            // with no explanation, so the parse fails loudly instead.
            for (pair in spec.split('&').filter { it.isNotEmpty() }) {
                if (pair.substringBefore('=') != "plugin") continue
                val plugin = percentDecodedOrRaw(pair.substringAfter('=', ""))
                if (plugin.isNotEmpty()) {
                    throw ProxyParseException("unsupportedTransport", "plugin: ${
                        plugin.split(';').firstOrNull { it.isNotEmpty() } ?: plugin
                    }")
                }
            }
        }
        val at = body.lastIndexOf('@')
        if (at < 0) throw ProxyParseException("malformedURI", link)
        val userInfoRaw = body.substring(0, at)
        // SIP002 generators commonly percent-encode the base64 userinfo itself
        // (`…d29yZA%3D%3D`), but the encoded form must not reach the base64
        // decoder first: the hex digits of `%3D` are alphabet characters, so
        // `…cGFzc3dvcmQ%3D%3D` would decode as `…password7p` — a wrong password
        // that imports cleanly and fails every handshake.
        val unescaped = percentDecodedOrRaw(userInfoRaw)
        val spellings =
            if (unescaped == userInfoRaw) listOf(userInfoRaw) else listOf(unescaped, userInfoRaw)
        val userInfo = spellings.firstNotNullOfOrNull { candidate ->
            Base64.decodeToString(candidate)?.takeIf { it.contains(':') }
        } ?: unescaped
        return shadowsocks(name, userInfo, body.substring(at + 1), link)
    }

    // MARK: - VMess

    private fun parseVmess(link: String): ProxyServer {
        // Some generators append a `#remarks` fragment or a query to the base64
        // body. The base64 alphabet never contains '#' or '?', so anything from
        // the first one is decoration — but the flexible decoder ignores unknown
        // characters, so a fragment's letters would be swallowed into the
        // payload, shift the stream and corrupt the JSON.
        var body = link.substring("vmess://".length)
        val cut = body.indexOfFirst { it == '#' || it == '?' }
        if (cut >= 0) body = body.substring(0, cut)
        @Suppress("UNCHECKED_CAST")
        val obj = Base64.decodeFlexible(body)
            ?.let { utf8(it) }
            ?.let { runCatching { Json.parse(it) }.getOrNull() } as? Map<String, Any?>
            ?: throw ProxyParseException("invalidBase64")
        fun str(key: String): String? = Json.string(obj[key])
        fun intVal(key: String): Int? = Json.int(obj[key])

        val add = str("add")?.takeIf { it.isNotEmpty() }
        val port = intVal("port")?.takeIf { it in 1..65535 }
        val id = str("id")?.takeIf { it.isNotEmpty() }
        if (add == null || port == null || id == null) {
            throw ProxyParseException("missingField", "add/port/id")
        }
        // Panels emit `tls` three ways: a string ("tls"/"reality"/"xtls"/
        // "none"), a JSON boolean, or absent. The boolean must be checked
        // first — NSNumber would read `true` back as the string "1" and fall
        // through to `.none`.
        val tlsName = Json.boolean(obj["tls"])?.let { if (it) "tls" else "none" }
            ?: (str("tls") ?: "none").lowercase()
        val security = when (tlsName) {
            "tls" -> StreamSecurity.TLS
            "reality" -> StreamSecurity.REALITY
            "xtls" -> StreamSecurity.XTLS
            else -> StreamSecurity.NONE
        }
        val net = networkType(str("net"))
        fun blank(key: String): String? = str(key)?.takeIf { it.isNotEmpty() }
        var server = ProxyServer(
            name = str("ps") ?: add,
            proto = ProxyProtocol.VMESS,
            address = add,
            port = port,
            credential = id,
            alterId = intVal("aid") ?: 0,
            network = net,
            security = security,
            vmessCipher = blank("scy"),
            sni = blank("sni"),
            fingerprint = blank("fp"),
            realityPublicKey = blank("pbk"),
            realityShortId = blank("sid"),
            realitySpiderX = blank("spx"),
            path = blank("path"),
            host = blank("host"),
            headerType = blank("type"),
        )
        str("alpn")?.takeIf { it.isNotEmpty() }?.let {
            server = server.copy(alpn = commaList(it, keepEmpty = false))
        }
        // `mode=multi` for gRPC never reaches the stream-params path — the
        // vmess JSON carries it as a top-level field.
        if (net == NetworkType.GRPC) {
            str("mode")?.let { server = server.copy(grpcMultiMode = it.lowercase() == "multi") }
        }
        if (net == NetworkType.XHTTP) {
            server = server.copy(xhttpMode = blank("mode"))
        }
        if (net == NetworkType.KCP) {
            str("seed")?.takeIf { it.isNotEmpty() }?.let {
                server = server.copy(userData = server.userData.orEmpty() + ("kcpSeed" to it))
            }
        }
        return server
    }

    // MARK: - Shared plumbing

    /** The two Shadowsocks encodings share this tail: `method:password` + `host:port`. */
    private fun shadowsocks(name: String?, userInfo: String, hostPort: String, link: String): ProxyServer {
        val (method, password) = splitMethodPassword(userInfo, link)
        val (host, port) = splitHostPort(hostPort, link)
        return ProxyServer(
            name = name ?: host, proto = ProxyProtocol.SHADOWSOCKS, address = host,
            port = port, credential = password, method = method,
        )
    }

    private fun splitMethodPassword(text: String, link: String): Pair<String, String> {
        val colon = text.indexOf(':')
        if (colon < 0) throw ProxyParseException("malformedURI", link)
        return text.substring(0, colon) to text.substring(colon + 1)
    }

    private fun splitHostPort(text: String, link: String): Pair<String, Int> {
        // SIP002 allows (and panels love) a trailing path after the port —
        // `ss://b64@host:8388/?plugin=…`. The query is already peeled, so
        // anything from the first `/` on is decoration, not authority.
        var value = text
        val slash = value.indexOf('/')
        if (slash >= 0) value = value.substring(0, slash)
        val close = value.indexOf(']')
        if (value.startsWith("[") && close >= 0) {
            val rest = value.substring(close + 1)
            val port = if (rest.startsWith(":")) swiftInt(rest.substring(1)) else null
            if (port == null || port !in 1..65535) throw ProxyParseException("malformedURI", link)
            return value.substring(1, close) to port
        }
        val colon = value.lastIndexOf(':')
        if (colon < 0) throw ProxyParseException("malformedURI", link)
        val port = swiftInt(value.substring(colon + 1))
        // An unbracketed IPv6 literal would split into host "2001:db8:" port 1
        // and dial nothing; real hosts never contain a colon.
        if (port == null || port !in 1..65535 || value.substring(0, colon).contains(":")) {
            throw ProxyParseException("malformedURI", link)
        }
        return value.substring(0, colon) to port
    }

    /** The parsed authority, query and fragment of a share link. */
    internal class UriParts(link: String) {
        val userInfo: String?
        val host: String?
        val port: Int?
        val query: Map<String, String>
        val fragment: String?

        init {
            val separator = link.indexOf("://")
            if (separator < 0) throw ProxyParseException("malformedURI", link)
            var rest = link.substring(separator + 3)

            var name: String? = null
            val hash = rest.indexOf('#')
            if (hash >= 0) {
                name = percentDecoded(rest.substring(hash + 1))?.let { displayNameFromFragment(it) }
                rest = rest.substring(0, hash)
            }
            // A bare `#`, or a fragment no percent decoder can read, yields no
            // name: an empty string would surface as a blank label in the UI
            // instead of falling back to the host.
            fragment = name?.takeIf { it.isNotEmpty() }

            val pairs = mutableMapOf<String, String>()
            val question = rest.indexOf('?')
            if (question >= 0) {
                // Swift's `split(separator:)` drops empty subsequences, so a
                // doubled `&&` must not add a keyless entry.
                for (pair in rest.substring(question + 1).split('&').filter { it.isNotEmpty() }) {
                    val equals = pair.indexOf('=')
                    val key = if (equals < 0) pair else pair.substring(0, equals)
                    val value = if (equals < 0) "" else percentDecodedOrRaw(pair.substring(equals + 1))
                    pairs[key] = value
                }
                rest = rest.substring(0, question)
            }
            query = pairs

            // A path after the authority (`host:443/?…`) is not part of
            // host:port — left in, "443/" failed the port check.
            val slash = rest.indexOf('/')
            if (slash >= 0) rest = rest.substring(0, slash)

            var authority = rest
            val at = authority.lastIndexOf('@')
            if (at >= 0) {
                // A stray "%" in a password makes percentDecoded return nil —
                // and a nil userinfo reads as "no credentials in this link",
                // which killed imports of `trojan://ab%cd@…` with
                // missingField("password"). Fall back to the raw text, as every
                // other field here does (and as Swift now does).
                userInfo = percentDecodedOrRaw(authority.substring(0, at))
                authority = authority.substring(at + 1)
            } else {
                userInfo = null
            }

            if (authority.startsWith("[") && authority.contains("]")) {
                val close = authority.indexOf(']')
                host = authority.substring(1, close)
                val tail = authority.substring(close + 1)
                port = if (tail.startsWith(":")) portValue(tail.substring(1)) else null
            } else {
                val colon = authority.lastIndexOf(':')
                val portPart = if (colon >= 0) authority.substring(colon + 1) else ""
                val hostPart = if (colon >= 0) authority.substring(0, colon) else authority
                // Only treat the last colon as a port separator when the tail
                // really is a port and the head cannot be an unbracketed IPv6
                // literal: `vless://u@2001:db8::1` used to parse as address
                // "2001:db8:" port 1 — a server that dials nothing instead of
                // failing at import.
                if (colon >= 0 && portPart.isNotEmpty() && portPart.all { it.isDigit() } &&
                    !hostPart.contains(":")
                ) {
                    host = hostPart
                    port = portValue(portPart)
                } else {
                    host = authority.ifEmpty { null }
                    port = null
                }
            }
        }

        private fun portValue(text: String): Int? =
            swiftInt(text)?.takeIf { it in 1..65535 }
    }

    /**
     * Case-folded query keys, folded in sorted order so that a link carrying
     * both `Obfs` and `obfs` resolves to the lowercase spelling every time —
     * the way Swift's parser now does it too.
     */
    private fun lowerCased(query: Map<String, String>): Map<String, String> {
        val folded = LinkedHashMap<String, String>()
        for ((key, value) in query.entries.sortedBy { it.key }) folded[key.lowercase()] = value
        return folded
    }

    private fun percentDecodedOrRaw(text: String): String = percentDecoded(text) ?: text

    /**
     * A comma-separated list from a link, trimmed of spaces. `keepEmpty`
     * follows whichever Swift split the call site used: `components(separatedBy:)`
     * keeps `h3,,h2` as three entries, `split(separator:)` drops the blank one.
     */
    private fun commaList(raw: String, keepEmpty: Boolean): List<String> =
        (if (keepEmpty) raw.split(',') else raw.split(',').filter { it.isNotEmpty() })
            .map { trimFoundationSpaces(it) }

    /**
     * Port of `ShareLinkParser.displayName(fromFragment:)`: 3x-ui appends
     * Happ's decoration as a query — `#🇫🇷 XHTTP?serverDescription=<base64>` —
     * and the decoded label is what tells two hosts of one inbound apart, so
     * it is appended rather than dropped. A fragment that merely contains "?"
     * and no known key is a name in its own right and is left alone.
     */
    internal fun displayNameFromFragment(raw: String): String {
        val mark = raw.indexOf('?')
        if (mark < 0) return raw
        val base = raw.substring(0, mark)
        val pair = raw.substring(mark + 1).split('&').firstOrNull {
            val kv = it.split('=', limit = 2)
            kv.size == 2 && kv[0].lowercase() == "serverdescription"
        } ?: return raw
        val text = Base64.decodeToString(pair.substringAfter('=')) ?: return base
        val label = trimSpaceLike(text.filterNot { it.isControlChar() })
        if (label.isEmpty()) return base
        return if (base.isEmpty()) label else "$base · ${graphemes(label, 48)}"
    }

    /** `prefix(48)` in Swift counts grapheme clusters, not UTF-16 units. */
    private fun graphemes(text: String, limit: Int): String {
        if (text.codePointCount(0, text.length) <= limit) return text
        val iterator = java.text.BreakIterator.getCharacterInstance()
        iterator.setText(text)
        var end = iterator.first()
        var taken = 0
        while (taken < limit) {
            val next = iterator.next()
            if (next == java.text.BreakIterator.DONE) break
            end = next
            taken += 1
        }
        return text.substring(0, end)
    }

    /** Unicode general category Cc — Swift's `.controlCharacters`. */
    private fun Char.isControlChar(): Boolean =
        Character.getType(this).toByte() == Character.CONTROL

    private fun networkType(raw: String?): NetworkType =
        when ((raw ?: "tcp").lowercase()) {
            "", "tcp", "raw", "none" -> NetworkType.TCP
            "ws", "websocket" -> NetworkType.WS
            "grpc" -> NetworkType.GRPC
            "http", "h2" -> NetworkType.HTTP
            "httpupgrade" -> NetworkType.HTTPUPGRADE
            "quic" -> NetworkType.QUIC
            "kcp", "mkcp" -> NetworkType.KCP
            "xhttp", "splithttp" -> NetworkType.XHTTP
            else -> throw ProxyParseException("unsupportedTransport", (raw ?: "tcp").lowercase())
        }

    /** Case-insensitive: real links carry `TLS`, `Reality`, `REALITY`. */
    private fun securityValue(raw: String?, fallback: StreamSecurity): StreamSecurity {
        if (raw.isNullOrEmpty()) return fallback
        return StreamSecurity.entries.firstOrNull { it.raw == raw.lowercase() } ?: fallback
    }

    private fun boolParam(raw: String?): Boolean =
        raw != null && raw.lowercase() in setOf("1", "true", "yes")

    private fun validatePort(port: Int, link: String) {
        if (port !in 1..65535) throw ProxyParseException("malformedURI", link)
    }

    private fun applyStreamParams(server: ProxyServer, q: Map<String, String>): ProxyServer {
        fun blank(value: String?): String? = value?.takeIf { it.isNotEmpty() }
        var result = server.copy(
            sni = blank(q["sni"]) ?: q["peer"],
            fingerprint = blank(q["fp"]),
            realityPublicKey = blank(q["pbk"]),
            realityShortId = blank(q["sid"]),
            realitySpiderX = blank(q["spx"]),
            allowInsecure = q["allowInsecure"] == "1" || q["allowInsecure"]?.lowercase() == "true",
            headerType = blank(q["headerType"]),
        )
        if (!q["alpn"].isNullOrEmpty()) {
            result = result.copy(alpn = commaList(q["alpn"]!!, keepEmpty = false))
        }
        // gRPC carries serviceName in `path`, the :authority in `host` and its
        // multiplexing mode in `mode`. An empty serviceName must be dropped,
        // not preferred: some panels emit `serviceName=` next to a real
        // `path=`, and Xray cannot dial gRPC without a service name.
        if (result.network == NetworkType.GRPC) {
            result = result.copy(
                path = blank(q["serviceName"]) ?: blank(q["path"]),
                host = blank(q["host"]),
                grpcMultiMode = q["mode"]?.lowercase() == "multi",
            )
        } else {
            result = result.copy(path = blank(q["path"]), host = blank(q["host"]))
        }
        if (result.network == NetworkType.XHTTP) {
            result = result.copy(
                xhttpMode = blank(q["mode"]),
                xhttpExtra = blank(q["extra"]),
            )
        }
        // The model has no field for a kcp `seed`, and 26.x cannot dial with
        // one at all. Carry it so the config builder can refuse the server by
        // name instead of silently dropping the obfuscation.
        if (result.network == NetworkType.KCP) {
            blank(q["seed"])?.let { result = result.copy(userData = result.userData.orEmpty() + ("kcpSeed" to it)) }
        }
        return result
    }
}
