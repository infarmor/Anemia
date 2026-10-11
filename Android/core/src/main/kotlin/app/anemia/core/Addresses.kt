package app.anemia.core

/**
 * Address literals, judged the way the resolver would judge them. Port of the
 * matching helpers in `Sources/LoaderCore/DirectResolver.swift`.
 */
object Addresses {
    /**
     * A dotted-quad IPv4 literal. Octets must be plain ASCII digits without a
     * leading zero: `Int("+4")` accepts a sign, and BSD's `inet_aton` reads
     * `010.0.0.1` as octal 8.0.0.1 — either way the address that gets
     * programmed differs from the string that was validated.
     */
    fun isIPv4(text: String): Boolean {
        val parts = text.split('.')
        if (parts.size != 4) return false
        return parts.all { part ->
            if (part.isEmpty() || !part.all { it in '0'..'9' }) return false
            if (part.length > 1 && part[0] == '0') return false
            val value = part.toIntOrNull() ?: return false
            value in 0..255
        }
    }

    /**
     * An IPv6 literal, checked structurally. `InetAddress.getByName` would
     * answer the same question but falls back to a DNS lookup for anything it
     * cannot parse — in a config parser that means a network call (and a
     * stall) on every malformed link.
     *
     * Accepted: up to eight colon-separated hex groups with at most one `::`
     * run, and the IPv4-tail form (`::ffff:10.0.0.1`). Rejected: a zone id
     * (`%en0`), which is not an address a profile can assign.
     */
    fun isIPv6(text: String): Boolean {
        if (text.isEmpty() || !text.contains(':') || text.contains('%')) return false
        var body = text
        // An IPv4 tail stands in for the last two groups.
        val lastColon = body.lastIndexOf(':')
        if (lastColon >= 0 && body.indexOf('.') > lastColon) {
            if (!isIPv4(body.substring(lastColon + 1))) return false
            body = body.substring(0, lastColon) + ":0:0"
        }
        val groups: List<String>
        val doubleColon = body.indexOf("::")
        if (doubleColon >= 0) {
            if (body.indexOf("::", doubleColon + 1) >= 0) return false
            val left = body.substring(0, doubleColon).split(':').filter { it.isNotEmpty() }
            val right = body.substring(doubleColon + 2).split(':').filter { it.isNotEmpty() }
            if (left.size + right.size > 7) return false
            groups = left + right
        } else {
            groups = body.split(':')
            if (groups.size != 8) return false
        }
        return groups.all { group ->
            group.length in 1..4 && group.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }
        }
    }

    fun isIPAddress(text: String): Boolean = isIPv4(text) || isIPv6(text)

    /**
     * Inside 198.18.0.0/15 — the fake-IP pool a sing-box/clash/mihomo client
     * hands out from its own DNS. Such an answer is never a real destination:
     * pinning it as the engine's server would send the encrypted connection into
     * that VPN, or nowhere. Only a literal dotted-quad can be one, so a hostname
     * that merely starts with `198.18.` stays a hostname.
     */
    fun isFakeIP(text: String): Boolean {
        if (!text.all { it == '.' || it in '0'..'9' }) return false
        return text.startsWith("198.18.") || text.startsWith("198.19.")
    }
}
