package app.anemia.core

/**
 * Port of `Sources/LoaderCore/HysteriaConfigBuilder.swift`: the client YAML for
 * the standalone hysteria engine. Xray can't dial hysteria (QUIC, its own
 * framing), so a hysteria server runs as its own process next to xray and the
 * xray config routes through a local SOCKS bridge — this is the pure half, the
 * validation and the config text.
 */
class HysteriaBuildException(message: String) : Exception(message) {
    companion object {
        /** Same sentences as `BuilderError.errorDescription`. */
        const val MISSING_AUTH =
            "Hysteria server carries no auth/password — re-import the link."

        fun unsupported(protocol: String): String =
            "Hysteria protocol v1 is not supported by the bundled engine path — " +
                "use a hysteria2 (hy2://) link. ($protocol)"
    }
}

object HysteriaConfigBuilder {

    /** Up-front problems that would otherwise fail only silently on the wire. */
    fun validate(server: ProxyServer): List<String> {
        val problems = ArrayList<String>()
        if (server.credential.isEmpty()) problems.add("auth/password is empty")
        if (server.port !in 1..65535) problems.add("port ${server.port} is out of range")
        if (server.address.isEmpty()) problems.add("server address is empty")
        val hop = server.userData?.get("portHopping")
        if (!hop.isNullOrEmpty() && !ShareLinkParser.isValidPortSpec(hop)) {
            problems.add("port hopping spec '$hop' is not a port list like 443,20000-50000")
        }
        if (server.proto == ProxyProtocol.HYSTERIA) {
            // The v1 YAML below is generated for completeness, but the bundled
            // binary is the v2 engine: it would reject the config — or worse,
            // parse it wrongly. Say it at import/connect.
            problems.add("hysteria protocol v1 requires the legacy hysteria v1 client binary")
        }
        return problems
    }

    /**
     * The client YAML. `socksPort` is the local bridge port the controller
     * picked — the same port xray's socks outbound must target. No bandwidth
     * section: without one hysteria2 uses BBR, which beats guessed rate limits.
     */
    fun makeClientConfig(server: ProxyServer, socksPort: Int): String {
        if (server.credential.isEmpty()) throw HysteriaBuildException(HysteriaBuildException.MISSING_AUTH)
        val host = if (server.address.contains(':') && !server.address.startsWith("["))
            "[${server.address}]" else server.address
        val endpoint = "$host:${portSpec(server)}"
        val lines = ArrayList<String>()
        when (server.proto) {
            ProxyProtocol.HYSTERIA2 -> {
                lines.add("server: ${yaml(endpoint)}")
                lines.add("auth: ${yaml(server.credential)}")
                lines.add("tls:")
                server.sni?.takeIf { it.isNotEmpty() }?.let { lines.add("  sni: ${yaml(it)}") }
                if (server.allowInsecure) lines.add("  insecure: true")
                if (server.alpn.isNotEmpty()) lines.add("  alpn: ${yaml(server.alpn.joinToString(","))}")
                // The client's field is `pinSHA256`; the old `pinnedSHA256`
                // spelling was silently ignored, so a link's pin never applied.
                server.userData?.get("pinSHA256")?.takeIf { it.isNotEmpty() }?.let {
                    lines.add("  pinSHA256: ${yaml(it)}")
                }
                val obfs = server.userData?.get("obfs")?.takeIf { it.isNotEmpty() }
                val password = server.userData?.get("obfsPassword")?.takeIf { it.isNotEmpty() }
                if (obfs != null && password != null) {
                    lines.add("obfs:")
                    lines.add("  type: ${yaml(obfs)}")
                    lines.add("  salamander:")
                    lines.add("    password: ${yaml(password)}")
                }
            }
            ProxyProtocol.HYSTERIA -> {
                lines.add("server: ${yaml(endpoint)}")
                lines.add("protocol: ${yaml(server.userData?.get("protocol") ?: "udp")}")
                server.userData?.get("upmbps")?.let { lines.add("up: ${yaml("$it Mbps")}") }
                server.userData?.get("downmbps")?.let { lines.add("down: ${yaml("$it Mbps")}") }
                lines.add("auth_str: ${yaml(server.credential)}")
                lines.add("tls:")
                server.sni?.takeIf { it.isNotEmpty() }?.let { lines.add("  sni: ${yaml(it)}") }
                if (server.allowInsecure) lines.add("  insecure: true")
                if (server.alpn.isNotEmpty()) lines.add("  alpn: ${yaml(server.alpn.joinToString(","))}")
                val obfs = server.userData?.get("obfs")?.takeIf { it.isNotEmpty() }
                if (obfs != null) {
                    lines.add("obfs: ${yaml(obfs)}")
                    server.userData?.get("obfsPassword")?.takeIf { it.isNotEmpty() }?.let {
                        lines.add("obfs_param: ${yaml(it)}")
                    }
                }
            }
            else -> throw HysteriaBuildException(
                HysteriaBuildException.unsupported(server.proto.raw))
        }
        lines.add("socks5:")
        lines.add("  listen: ${yaml("127.0.0.1:$socksPort")}")
        return lines.joinToString("\n") + "\n"
    }

    /** `443`, `20000-50000`, `443,20000-50000` — every port 1…65535, ranges ascending. */
    fun isValidPortSpec(spec: String): Boolean = ShareLinkParser.isValidPortSpec(spec)

    /**
     * The client's port field: the link's port, widened by its hopping spec —
     * the hysteria client hops across every listed port, so a spec that already
     * covers the port replaces it and one that doesn't is joined with it.
     */
    internal fun portSpec(server: ProxyServer): String {
        val hop = server.userData?.get("portHopping")
        if (server.proto != ProxyProtocol.HYSTERIA2 || hop.isNullOrEmpty() ||
            !isValidPortSpec(hop)
        ) {
            return server.port.toString()
        }
        val covers = hop.split(',').any { item ->
            val bounds = item.split('-').mapNotNull(::swiftInt)
            when (bounds.size) {
                1 -> bounds[0] == server.port
                2 -> bounds[0] <= server.port && server.port <= bounds[1]
                else -> false
            }
        }
        return if (covers) hop else "${server.port},$hop"
    }

    /**
     * A YAML scalar as a double-quoted string — YAML accepts the JSON string
     * grammar, so a hostile password (quotes, colons, newlines, `#`) can't break
     * the document's structure.
     */
    private fun yaml(value: String): String = Json.write(value)
}
