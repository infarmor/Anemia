package app.anemia.core

/**
 * Port of `Sources/LoaderCore/XrayConfigBuilder.swift` for the shape both
 * packet-tunnel platforms hand the engine: iOS today (Xray inside the
 * NetworkExtension) and Android (Xray in the `VpnService` process). The
 * macOS-only branches are deliberately absent — local SOCKS/HTTP inbounds, the
 * hysteria SOCKS bridge and `sockopt.interface`, none of which exist where the
 * provider's own sockets already bypass the tunnel.
 *
 * `Scripts/golden-xray.sh` captures what the Swift builder produces with
 * `LoaderTool emit-tun`, so every key, every default and every refusal word is
 * compared, not remembered.
 */
class XrayConfigBuilder(
    private val logLevel: String = "warning",
    private val enableSniffing: Boolean = true,
    /** Nil in packet-tunnel mode: the app reads the counters in-process. */
    private val apiPort: Int? = null,
    var remoteDNS: List<String> = listOf(
        "https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query", "1.1.1.1",
    ),
    private val blockQUIC: Boolean = true,
    private val hijackDNS: Boolean = true,
    private val bufferSizeKB: Int = 512,
    var dnsHosts: MutableMap<String, String> = mutableMapOf(),
    var dnsQueryStrategy: String = "UseIP",
    var collectsStats: Boolean = false,
    var logFile: String? = null,
    var bypass: List<BypassEntry> = emptyList(),
    var bypassResolver: String? = null,
    var mtu: Int = 1500,
) {
    companion object {
        /** Tag the engine wrapper looks the tun inbound up by. */
        const val tunnelInboundTag = "tun-in"

        /**
         * The ciphers the bundled Xray-core accepts, measured against the
         * shipped binary with `xray run -c … -test`; matching is case-insensitive.
         */
        val supportedCiphers = setOf(
            "aes-128-gcm", "aes-256-gcm", "chacha20-poly1305", "chacha20-ietf-poly1305",
            "xchacha20-ietf-poly1305", "none",
            "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305",
        )

        private val xhttpModes = setOf("auto", "packet-up", "stream-up", "stream-one")

        /**
         * Grammar of a VLESS Encryption value, from `infra/conf/vless.go` of the
         * pinned engine: `mlkem768x25519plus.{native|xorpub|random}.{1rtt|0rtt}.`
         * then base64url keys of 32 (x25519) or 1184 (mlkem768) bytes; shorter
         * trailing parts are the padding prefix, not keys.
         */
        fun isVlessEncryptionKey(value: String): Boolean {
            val parts = value.split('.')
            if (parts.size < 4 || parts[0] != "mlkem768x25519plus" ||
                parts[1] !in setOf("native", "xorpub", "random") ||
                parts[2] !in setOf("1rtt", "0rtt")
            ) return false
            var keys = 0
            for (part in parts.drop(3)) {
                if (part.length < 20) continue
                val bytes = base64UrlBytes(part) ?: return false
                if (bytes.size != 32 && bytes.size != 1184) return false
                keys += 1
            }
            return keys > 0
        }

        /** Strict unpadded URL-safe base64, as Go's `base64.RawURLEncoding`. */
        private fun base64UrlBytes(text: String): ByteArray? {
            val out = ArrayList<Int>()
            var bits = 0
            var count = 0
            for (char in text) {
                val value = when (char) {
                    in 'A'..'Z' -> char - 'A'
                    in 'a'..'z' -> char - 'a' + 26
                    in '0'..'9' -> char - '0' + 52
                    '-' -> 62
                    '_' -> 63
                    else -> return null
                }
                bits = bits shl 6 or value
                count += 6
                if (count >= 8) {
                    count -= 8
                    out.add(bits shr count and 0xFF)
                }
            }
            return out.map { it.toByte() }.toByteArray()
        }

        /**
         * What the engine accepts (`infra/conf/transport_internet.go`): pins
         * separated by commas, each optional-colon hex of 32 bytes.
         */
        fun isSha256PinList(pin: String): Boolean {
            var found = false
            for (item in pin.split(',')) {
                val hex = trimFoundationSpaces(item).replace(":", "")
                if (hex.isEmpty()) continue
                if (hex.length != 64 || !hex.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) return false
                found = true
            }
            return found
        }

        /**
         * FNV-1a over the UTF-8 bytes. Swift's `String.hashValue` is seeded per
         * process, so a pick derived from it reshuffles at every launch; this
         * one is stable across launches and machines — and the sign bit is
         * masked, because a negative fold indexed out of the mimicry pool.
         */
        fun stableHash(text: String): Long {
            var h = 0xcbf29ce484222325uL
            for (byte in text.encodeToByteArray()) {
                h = h xor byte.toUByte().toULong()
                h *= 0x100000001b3uL
            }
            return (h and 0x7FFF_FFFF_FFFF_FFFFuL).toLong()
        }
    }

    /** Config as the engine's JSON: same keys, same order of assembly as Swift. */
    fun makeConfig(server: ProxyServer, anti: AntiCensorshipOptions = AntiCensorshipOptions.recommended)
        : Map<String, Any?> {
        val outbounds = ArrayList<Map<String, Any?>>()
        // Both features the dial carries — ClientHello fragmentation and junk
        // packets — live on ONE `freedom` outbound that the proxy chains to
        // through `sockopt.dialerProxy`, and both in its `settings`:
        // `settings.fragment` and `settings.noises` (`infra/conf/freedom.go` of
        // 26.3.27). There is no `sockopt.noises`: the engine ignores an unknown
        // socket option, so emitting them there gave every profile except `off`
        // a knob that did nothing while the UI named it. Both keys are read
        // strictly, so whatever the engine would refuse to load is filtered out
        // (`emittableNoises`/`emittableFragment`): one poisoned record must cost
        // its own junk packet, not the tunnel.
        val maskNoises = anti.emittableNoises
        val maskFragment = anti.emittableFragment
        val viaMaskDialer = maskFragment != null || maskNoises.isNotEmpty()
        val pinDial = pinsServerDial(server)
        if (viaMaskDialer) {
            val settings = linkedMapOf<String, Any?>("domainStrategy" to "AsIs")
            maskFragment?.let { frag ->
                settings["fragment"] = linkedMapOf(
                    "packets" to frag.packets, "length" to frag.length, "interval" to frag.interval,
                )
            }
            if (maskNoises.isNotEmpty()) {
                settings["noises"] = maskNoises.map {
                    linkedMapOf("type" to it.type, "packet" to it.packet, "delay" to it.delay)
                }
            }
            val fragment = linkedMapOf<String, Any?>(
                "tag" to "fragment",
                "protocol" to "freedom",
                "settings" to settings,
            )
            makeSockopt(anti, dialerProxy = null, pinServerDial = pinDial)?.let {
                fragment["streamSettings"] = mapOf("sockopt" to it)
            }
            outbounds.add(fragment)
        }

        outbounds.add(0, makeProxyOutbound(server, anti, viaMaskDialer))
        outbounds.add(linkedMapOf(
            "tag" to "direct", "protocol" to "freedom",
            "settings" to mapOf("domainStrategy" to "UseIP"),
        ))

        // The provider's sockets never enter its own tunnel, so a bypassed
        // destination can go direct without an interface pin.
        val bypassActive = bypass.isNotEmpty()
        val bypassDomains = bypass.filter { it.isDomain }.map { "domain:${it.value}" }
        val resolver = bypassResolver?.takeIf { Addresses.isIPv4(it) }
        if (bypassActive) {
            outbounds.add(linkedMapOf(
                "tag" to "bypass", "protocol" to "freedom",
                "settings" to mapOf("domainStrategy" to "UseIP"),
            ))
        }
        outbounds.add(linkedMapOf(
            "tag" to "block", "protocol" to "blackhole", "settings" to emptyMap<String, Any?>(),
        ))
        if (hijackDNS) {
            outbounds.add(linkedMapOf(
                "tag" to "dns-out", "protocol" to "dns", "settings" to emptyMap<String, Any?>(),
            ))
        }

        val sniff = if (enableSniffing) linkedMapOf<String, Any?>(
            "enabled" to true, "destOverride" to listOf("http", "tls", "quic"), "routeOnly" to false,
        ) else null
        val inbounds = ArrayList<Map<String, Any?>>()
        inbounds.add(linkedMapOf<String, Any?>(
            "tag" to tunnelInboundTag, "protocol" to "tun", "port" to 0,
            "settings" to linkedMapOf("MTU" to mtu),
        ).also { if (sniff != null) it["sniffing"] = sniff })
        val trafficInboundTags = listOf(tunnelInboundTag)
        if (apiPort != null) {
            inbounds.add(linkedMapOf(
                "tag" to "api-in", "protocol" to "dokodemo-door", "listen" to "127.0.0.1",
                "port" to apiPort, "settings" to linkedMapOf("address" to "127.0.0.1"),
            ))
        }

        val rules = ArrayList<Map<String, Any?>>()
        if (apiPort != null) {
            rules.add(linkedMapOf<String, Any?>("type" to "field", "inboundTag" to listOf("api-in"), "outboundTag" to "api"))
        }
        // The DNS hijack comes before the LAN-direct rule: an ISP resolver
        // answering inside the tunnel is exactly what poisons the answers.
        // Scoped to the traffic inbounds, or the DNS module's own queries to a
        // plain resolver would loop back into `dns-out` forever.
        if (hijackDNS) {
            rules.add(linkedMapOf<String, Any?>(
                "type" to "field", "inboundTag" to trafficInboundTags, "port" to 53, "outboundTag" to "dns-out",
            ))
        }
        if (bypassActive) {
            val networks = bypass.filter { !it.isDomain }.map { it.value }
            if (bypassDomains.isNotEmpty()) {
                rules.add(linkedMapOf<String, Any?>("type" to "field", "outboundTag" to "bypass", "domain" to bypassDomains))
            }
            if (networks.isNotEmpty()) {
                rules.add(linkedMapOf<String, Any?>("type" to "field", "outboundTag" to "bypass", "ip" to networks))
            }
            if (resolver != null && bypassDomains.isNotEmpty()) {
                rules.add(linkedMapOf<String, Any?>(
                    "type" to "field", "outboundTag" to "bypass", "ip" to listOf("$resolver/32"),
                ))
            }
        }
        // mDNS and router names must be answered on the local network: a
        // resolver abroad has never heard of them.
        rules.add(linkedMapOf<String, Any?>(
            "type" to "field", "outboundTag" to "direct",
            "domain" to listOf("domain:local", "domain:lan", "domain:home.arpa", "domain:internal"),
        ))
        rules.add(linkedMapOf<String, Any?>(
            "type" to "field", "outboundTag" to "direct", "ip" to privateCIDRs,
        ))
        // Multicast and broadcast can't traverse the tunnel at all; blocking
        // them keeps the engine from burning a worker on a doomed dial.
        rules.add(linkedMapOf<String, Any?>(
            "type" to "field", "outboundTag" to "block",
            "ip" to listOf("224.0.0.0/4", "255.255.255.255/32", "ff00::/8"),
        ))
        if (blockQUIC) {
            rules.add(linkedMapOf<String, Any?>(
                "type" to "field", "outboundTag" to "block", "network" to "udp", "port" to 443,
            ))
        }

        var dnsServers: List<Any?> = remoteDNS
        if (bypassActive && resolver != null && bypassDomains.isNotEmpty()) {
            // Exclusive for the bypassed names, and never a fallback for others.
            dnsServers = listOf(linkedMapOf<String, Any?>(
                "address" to resolver, "domains" to bypassDomains,
                "skipFallback" to true, "finalQuery" to true,
            )) + remoteDNS
        }
        val dns = linkedMapOf<String, Any?>(
            "servers" to dnsServers,
            "queryStrategy" to dnsQueryStrategy,
            "disableCache" to false,
            "enableParallelQuery" to true,
            "serveStale" to true,
            "serveExpiredTTL" to 3600,
        )
        if (dnsHosts.isNotEmpty()) dns["hosts"] = dnsHosts.toMap()

        val log = linkedMapOf<String, Any?>("loglevel" to logLevel)
        logFile?.let {
            // Per-connection access lines would drown the errors in a file
            // nobody rotates.
            log["error"] = it
            log["access"] = "none"
        }

        val config = linkedMapOf<String, Any?>(
            "log" to log, "dns" to dns, "inbounds" to inbounds,
            "outbounds" to outbounds,
            "routing" to linkedMapOf<String, Any?>("domainStrategy" to "AsIs", "rules" to rules),
        )

        var policy: MutableMap<String, Any?> = linkedMapOf(
            "levels" to mapOf("0" to linkedMapOf(
                "handshake" to 4, "connIdle" to 300, "bufferSize" to bufferSizeKB,
            )),
        )
        if (apiPort != null) config["api"] = linkedMapOf<String, Any?>("tag" to "api", "services" to listOf("StatsService"))
        if (apiPort != null || collectsStats) {
            config["stats"] = emptyMap<String, Any?>()
            policy["system"] = linkedMapOf(
                "statsInboundUplink" to true, "statsInboundDownlink" to true,
                "statsOutboundUplink" to true, "statsOutboundDownlink" to true,
            )
        }
        config["policy"] = policy
        return config
    }

    /** Validated JSON text — what the engine is actually handed. */
    fun makeConfigString(server: ProxyServer, anti: AntiCensorshipOptions = AntiCensorshipOptions.recommended): String {
        // Refuse before serializing anything the engine can't run: 26.x removed
        // the HTTP/2 and QUIC transports, and a config carrying them dies at
        // start with a core-side message the user cannot act on.
        if (server.network == NetworkType.HTTP || server.network == NetworkType.QUIC) {
            throw XrayConfigException.transportRemovedByEngine(server.network.raw)
        }
        if (server.security == StreamSecurity.REALITY && server.realityPublicKey == null) {
            throw XrayConfigException.realityMissingPublicKey()
        }
        if (server.network == NetworkType.XHTTP) {
            server.xhttpMode?.let {
                if (it !in xhttpModes) throw XrayConfigException.invalidXHTTPMode(it)
            }
            server.xhttpExtra?.let {
                if (runCatching { Json.parse(it) as? Map<*, *> }.getOrNull() == null) {
                    throw XrayConfigException.invalidXHTTPExtra()
                }
            }
        }
        return Json.write(makeConfig(server, anti))
    }

    /**
     * Whether the socket dialing the server must resolve its domain through the
     * engine's DNS module — the only place `dns.hosts` answers. Without the pin
     * the dial hands the name to the system resolver, which by then asks the
     * tunnel: the loop the pin exists to break. Emitted only while a pin
     * exists, or the module would resolve the server over DoH through the proxy
     * it is trying to reach.
     */
    fun pinsServerDial(server: ProxyServer): Boolean =
        !server.proto.isHysteriaFamily && dnsHosts[server.address] != null

    // MARK: - Outbound

    private fun makeProxyOutbound(
        server: ProxyServer, anti: AntiCensorshipOptions, viaMaskDialer: Boolean,
    ): Map<String, Any?> {
        // Xray's wireguard outbound speaks the plain handshake and would strip
        // every AmneziaWG parameter; that family belongs to the other engine.
        if (server.proto.isWireGuardFamily) {
            throw XrayConfigException.wireGuardNotOnXray(server.proto.raw)
        }
        if (server.proto.isHysteriaFamily) return makeNativeHysteriaOutbound(server)

        if (server.proto == ProxyProtocol.SHADOWSOCKS) {
            // The cipher is the one field there is no fallback for: the engine
            // refuses to start the config on an empty or removed one.
            val method = trimFoundationSpaces(server.method ?: "")
            if (method.isEmpty()) throw XrayConfigException.shadowsocksMethodMissing()
            if (method.lowercase() !in supportedCiphers) {
                throw XrayConfigException.shadowsocksMethodUnsupported(method)
            }
        }
        if (server.proto == ProxyProtocol.VLESS) {
            val encryption = server.vlessEncryption ?: "none"
            if (encryption != "none" && !isVlessEncryptionKey(encryption)) {
                throw XrayConfigException.vlessEncryptionUnsupported(encryption)
            }
        }
        server.flow?.takeIf { it.isNotEmpty() }?.let {
            if (it != "xtls-rprx-vision" && it != "xtls-rprx-vision-udp443") {
                throw XrayConfigException.vlessFlowUnsupported(it)
            }
        }
        if (server.network == NetworkType.KCP) {
            // 26.x rejects any header/seed in kcpSettings, and dialing plain
            // mKCP at a server that expects obfuscation is worse: silence.
            val header = trimFoundationSpaces(server.headerType ?: "")
            if (header.isNotEmpty() && header.lowercase() != "none") {
                throw XrayConfigException.mkcpObfuscationUnsupported("header=$header")
            }
            server.userData?.get("kcpSeed")?.takeIf { it.isNotEmpty() }?.let {
                throw XrayConfigException.mkcpObfuscationUnsupported("seed is set")
            }
        }

        val outbound = linkedMapOf<String, Any?>(
            "tag" to "proxy",
            "protocol" to server.proto.xrayProtocolName,
            "settings" to makeProxySettings(server),
        )
        outbound["streamSettings"] = makeStreamSettings(server, anti, viaMaskDialer)
        // Not with XTLS-Vision (incompatible and slower), and not over XHTTP,
        // which multiplexes on its own.
        val vision = (server.flow ?: "").contains("vision")
        if (anti.muxEnabled && !vision && server.network != NetworkType.XHTTP) {
            outbound["mux"] = linkedMapOf(
                "enabled" to true, "concurrency" to anti.muxConcurrency,
                "xudpConcurrency" to 8, "xudpProxyUDP443" to "reject",
            )
        }
        return outbound
    }

    /** Xray's built-in Hysteria 2 client: endpoint in settings, auth in hysteriaSettings. */
    private fun makeNativeHysteriaOutbound(server: ProxyServer): Map<String, Any?> {
        if (server.proto != ProxyProtocol.HYSTERIA2) throw XrayConfigException.hysteriaV1Unsupported()
        if (server.credential.isEmpty()) throw XrayConfigException.hysteriaMissingAuth()
        val pin = server.userData?.get("pinSHA256")?.takeIf { it.isNotEmpty() }
        if (server.allowInsecure && pin == null) throw XrayConfigException.hysteriaInsecureWithoutPin()

        val tls = linkedMapOf<String, Any?>()
        server.sni?.takeIf { it.isNotEmpty() }?.let { tls["serverName"] = it }
        if (pin != null && !isSha256PinList(pin)) throw XrayConfigException.hysteriaPinMalformed(pin)
        if (pin != null) tls["pinnedPeerCertSha256"] = pin
        val stream = linkedMapOf<String, Any?>(
            "network" to "hysteria", "security" to "tls", "tlsSettings" to tls,
            "hysteriaSettings" to linkedMapOf("version" to 2, "auth" to server.credential),
        )
        val finalmask = linkedMapOf<String, Any?>()
        if (server.userData?.get("obfs") == "salamander") {
            server.userData?.get("obfsPassword")?.takeIf { it.isNotEmpty() }?.let {
                finalmask["udp"] = listOf(linkedMapOf(
                    "type" to "salamander", "settings" to linkedMapOf("password" to it),
                ))
            }
        }
        server.userData?.get("portHopping")?.takeIf { it.isNotEmpty() && ShareLinkParser.isValidPortSpec(it) }?.let {
            finalmask["quicParams"] = mapOf("udpHop" to mapOf("ports" to portSpec(server)))
        }
        if (finalmask.isNotEmpty()) stream["finalmask"] = finalmask

        return linkedMapOf(
            "tag" to "proxy", "protocol" to "hysteria",
            "settings" to linkedMapOf("version" to 2, "address" to server.address, "port" to server.port),
            "streamSettings" to stream,
        )
    }

    /** The link's port widened by its hopping spec — the client hops across all of them. */
    private fun portSpec(server: ProxyServer): String =
        server.userData?.get("portHopping")?.takeIf { it.isNotEmpty() } ?: server.port.toString()

    private fun makeProxySettings(server: ProxyServer): Map<String, Any?> = when (server.proto) {
        ProxyProtocol.VLESS -> {
            val user = linkedMapOf<String, Any?>(
                "id" to server.credential,
                "encryption" to (server.vlessEncryption ?: "none"),
                "level" to 0,
            )
            server.flow?.takeIf { it.isNotEmpty() }?.let { user["flow"] = it }
            mapOf("vnext" to listOf(linkedMapOf(
                "address" to server.address, "port" to server.port, "users" to listOf(user),
            )))
        }
        ProxyProtocol.VMESS -> mapOf("vnext" to listOf(linkedMapOf(
            "address" to server.address, "port" to server.port,
            // The link's `scy` is what the panel's security setting says; a
            // server fixed to `zero` rejects a client that asks for `auto`.
            "users" to listOf(linkedMapOf<String, Any?>(
                "id" to server.credential, "alterId" to server.alterId,
                "security" to (server.vmessCipher ?: "auto"), "level" to 0,
            )),
        )))
        ProxyProtocol.TROJAN -> {
            val srv = linkedMapOf<String, Any?>(
                "address" to server.address, "port" to server.port,
                "password" to server.credential, "level" to 0,
            )
            server.flow?.takeIf { it.isNotEmpty() }?.let { srv["flow"] = it }
            mapOf("servers" to listOf(srv))
        }
        ProxyProtocol.SHADOWSOCKS -> mapOf("servers" to listOf(linkedMapOf<String, Any?>(
            "address" to server.address, "port" to server.port,
            "method" to (server.method ?: "aes-256-gcm"), "password" to server.credential,
            "uot" to true, "level" to 0,
        )))
        else -> emptyMap()
    }

    private fun makeStreamSettings(
        server: ProxyServer, anti: AntiCensorshipOptions, viaMaskDialer: Boolean,
    ): Map<String, Any?> {
        val stream = linkedMapOf<String, Any?>("network" to server.network.raw)

        // An explicit link SNI always wins; otherwise a host from the mimicry
        // pool is borrowed, but only for Reality — where camouflage SNI is the
        // whole point. A TLS certificate is name-validated now (26.x removed
        // allowInsecure), so a borrowed name there fails the handshake.
        // The pick is hashed off the server's identity rather than random, so a
        // reconnect keeps the same camouflage host: flapping SNI is itself a
        // correlation signal.
        val mimicrySNI = anti.mimicry
            .takeIf { it.isNotEmpty() }
            ?.let { it[(stableHash(server.identityKey) % it.size).toInt()] }
        val fingerprint = AntiCensorshipOptions.utlsFingerprint(server.fingerprint ?: anti.fingerprint)

        when (server.security) {
            StreamSecurity.REALITY -> {
                stream["security"] = "reality"
                val reality = linkedMapOf<String, Any?>("show" to false)
                (server.sni ?: mimicrySNI)?.let { reality["serverName"] = it }
                reality["fingerprint"] = fingerprint
                server.realityPublicKey?.let { reality["publicKey"] = it }
                server.realityShortId?.let { reality["shortId"] = it }
                if (server.alpn.isNotEmpty()) reality["alpn" ] = server.alpn
                reality["spiderX"] = server.realitySpiderX ?: "/"
                stream["realitySettings"] = reality
            }
            StreamSecurity.TLS, StreamSecurity.XTLS -> {
                stream["security"] = "tls"
                // `allowInsecure` is not emitted at all: 26.x removed the
                // option, and `true` is a fatal config error there.
                val tls = linkedMapOf<String, Any?>()
                // CDN links carry no `sni`, only the fronting `host`; using the
                // address (an IP) as serverName gets the handshake cut.
                (server.sni ?: server.host)?.let { tls["serverName"] = it }
                if (server.alpn.isNotEmpty()) tls["alpn"] = server.alpn
                tls["fingerprint"] = fingerprint
                stream["tlsSettings"] = tls
            }
            StreamSecurity.NONE -> stream["security"] = "none"
        }

        when (server.network) {
            NetworkType.WS -> {
                val ws = linkedMapOf<String, Any?>()
                server.path?.let { ws["path"] = it }
                server.host?.let { ws["headers"] = mapOf("Host" to it) }
                stream["wsSettings"] = ws
            }
            NetworkType.HTTPUPGRADE -> {
                val hu = linkedMapOf<String, Any?>()
                server.path?.let { hu["path"] = it }
                server.host?.let { hu["host"] = it }
                stream["httpupgradeSettings"] = hu
            }
            NetworkType.GRPC -> {
                val grpc = linkedMapOf<String, Any?>()
                server.path?.let { grpc["serviceName"] = it }
                server.host?.takeIf { it.isNotEmpty() }?.let { grpc["authority"] = it }
                if (server.grpcMultiMode == true) grpc["multiMode"] = true
                stream["grpcSettings"] = grpc
            }
            NetworkType.HTTP -> {
                // Unreachable through makeConfigString (refused there); kept so
                // makeConfig stays total.
                val h2 = linkedMapOf<String, Any?>()
                server.path?.let { h2["path"] = it }
                server.host?.let { h2["host"] = listOf(it) }
                stream["httpSettings"] = h2
            }
            NetworkType.TCP -> if (server.headerType == "http") {
                // Without an explicit `request`, Xray substitutes a bare
                // default and the link's path/Host are lost.
                stream["tcpSettings"] = mapOf("header" to linkedMapOf(
                    "type" to "http",
                    "request" to linkedMapOf<String, Any?>(
                        "version" to "1.1", "method" to "GET",
                        "path" to listOf(server.path ?: "/"),
                        "headers" to mapOf("Host" to listOf(server.host ?: server.address)),
                    ),
                ))
            }
            NetworkType.XHTTP -> {
                val xhttp = linkedMapOf<String, Any?>()
                server.path?.let { xhttp["path"] = it }
                server.host?.let { xhttp["host"] = it }
                server.xhttpMode?.let { xhttp["mode"] = it }
                server.xhttpExtra?.let { extra ->
                    (runCatching { Json.parse(extra) as? Map<*, *> }.getOrNull())?.let { xhttp["extra"] = it }
                }
                stream["xhttpSettings"] = xhttp
            }
            NetworkType.KCP -> stream["kcpSettings"] = emptyMap<String, Any?>()
            NetworkType.QUIC -> Unit
        }

        // With masking the dialer outbound owns the physical socket, so the
        // keepalive knobs ride there and we only chain.
        if (viaMaskDialer) {
            stream["sockopt"] = mapOf("dialerProxy" to "fragment")
        } else {
            makeSockopt(anti, dialerProxy = null, pinServerDial = pinsServerDial(server))
                ?.let { stream["sockopt"] = it }
        }
        return stream
    }

    private fun makeSockopt(anti: AntiCensorshipOptions, dialerProxy: String?, pinServerDial: Boolean): Map<String, Any?>? {
        val sockopt = linkedMapOf<String, Any?>(
            // Nagle would coalesce the small fragmented ClientHello writes the
            // DPI evasion depends on.
            "tcpNoDelay" to true,
            // Xray's Darwin sockopt code applies Idle/Interval swapped, so emit
            // both: a lone Idle leaves a zero write on the other option.
            "tcpKeepAliveIdle" to 30,
            "tcpKeepAliveInterval" to 10,
        )
        // tcpFastOpen is deliberately not emitted: xray's TFO setsockopt fails
        // with EINVAL on Darwin (Xray-core#989) and kills the whole dial.
        if (pinServerDial) sockopt["domainStrategy"] = "UseIPv4"
        // `noises` deliberately absent: xray reads junk packets from the masking
        // freedom outbound's `settings.noises`, never from a socket option.
        if (dialerProxy != null) sockopt["dialerProxy"] = dialerProxy
        return sockopt
    }

    /** LAN, loopback and link-local ranges, so no geoip.dat is needed. */
    private val privateCIDRs = listOf(
        "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
        "172.16.0.0/12", "192.168.0.0/16", "::1/128", "fc00::/7", "fe80::/10",
    )
}

/**
 * The refusals of `ConfigBuilderError`, with Swift's `errorDescription` word
 * for word: these strings reach the user in both apps, and the golden compares
 * them. The factory names mirror the Swift cases.
 */
class XrayConfigException(message: String) : Exception(message) {
    companion object {
        fun transportRemovedByEngine(name: String) = XrayConfigException(
            "Transport '$name' is no longer supported by the bundled Xray-core " +
                "(removed in 26.x). Ask the provider for a ws/grpc/tcp variant of this server."
        )

        fun realityMissingPublicKey() = XrayConfigException(
            "This Reality server carries no public key (pbk=) — the handshake cannot " +
                "authenticate. Re-import the share link from the panel so it includes the key."
        )

        fun wireGuardNotOnXray(proto: String) = XrayConfigException(
            "$proto servers run on the AmneziaWG engine, not Xray."
        )

        fun invalidXHTTPMode(mode: String) = XrayConfigException(
            "XHTTP mode '$mode' is not one the engine knows (auto, packet-up, stream-up, stream-one)."
        )

        fun invalidXHTTPExtra() = XrayConfigException(
            "The link's XHTTP 'extra' settings are not valid JSON — re-import it from the panel."
        )

        fun hysteriaV1Unsupported() = XrayConfigException(
            "Hysteria v1 servers are not supported here — ask the provider for a hysteria2 (hy2://) link."
        )

        fun hysteriaMissingAuth() = XrayConfigException(
            "Hysteria server carries no auth/password — re-import the link."
        )

        fun hysteriaInsecureWithoutPin() = XrayConfigException(
            "This Hysteria server uses an untrusted certificate (insecure=1) without " +
                "pinSHA256 — the bundled Xray-core can't skip certificate checks. " +
                "Ask the provider for a link with pinSHA256."
        )

        fun shadowsocksMethodMissing() = XrayConfigException(
            "The Shadowsocks link carries no cipher method (ss://:password@host) — " +
                "re-import it from the panel, which writes e.g. aes-256-gcm:password."
        )

        fun shadowsocksMethodUnsupported(method: String) = XrayConfigException(
            "Cipher '$method' is not supported by the bundled Xray-core (the legacy " +
                "stream ciphers were removed). Ask the provider for an AEAD cipher such " +
                "as aes-256-gcm or chacha20-ietf-poly1305."
        )

        fun hysteriaPinMalformed(pin: String) = XrayConfigException(
            "pinSHA256 '$pin' is not a 32-byte SHA-256 written in hex (64 digits, " +
                "':' separators allowed, several pins separated by ',') — re-import the link " +
                "from the panel."
        )

        fun vlessEncryptionUnsupported(value: String) = XrayConfigException(
            "The link asks for VLESS Encryption '$value', which the bundled Xray-core " +
                "cannot use: the value must be a mlkem768x25519plus group key in " +
                "native/xorpub/random 1rtt/0rtt form. Ask the provider for a plain " +
                "(encryption=none) link, or update the app's engine."
        )

        fun vlessFlowUnsupported(flow: String) = XrayConfigException(
            "Flow '$flow' is not supported by the bundled Xray-core (only " +
                "xtls-rprx-vision and xtls-rprx-vision-udp443) — re-import the link " +
                "or ask for a ws/tcp variant."
        )

        fun mkcpObfuscationUnsupported(detail: String) = XrayConfigException(
            "mKCP header obfuscation and seed were removed from Xray-core 26.x " +
                "($detail) — this server needs a ws/grpc/tcp variant."
        )
    }
}
