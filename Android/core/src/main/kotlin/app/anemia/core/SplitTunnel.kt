package app.anemia.core

/**
 * Split tunneling ("Мимо VPN"): destinations that leave through the physical
 * network. Port of `Sources/LoaderCore/SplitTunnel.swift`.
 *
 * The user's raw lines are what persists, so nothing typed is lost when the
 * validation rules move; this parser turns them into [BypassEntry] at connect
 * time. IPv6 text is produced by [inetNtop6] here rather than by the platform
 * (Java's `Inet6Address` and C's `inet_ntop` do not agree), and
 * `Scripts/golden-xray.sh` compares the canonical form with Swift's.
 */
data class SplitTunnelRules(val enabled: Boolean = true, val entries: List<String> = emptyList()) {
    /** The validated destinations this rule set routes around the VPN. */
    val activeEntries: List<BypassEntry> get() = if (enabled) SplitTunnelParser.parse(entries).entries else emptyList()
}

/** One validated, normalized bypass destination. */
sealed class BypassEntry {
    abstract val value: String
    val isDomain: Boolean get() = this is Domain

    /** IPv4 network in canonical CIDR form ("203.0.113.0/24", "198.51.100.7/32"). */
    data class IPv4(override val value: String) : BypassEntry()

    /** IPv6 network in canonical CIDR form ("2001:db8::/32"). */
    data class IPv6(override val value: String) : BypassEntry()

    /** Lowercase ASCII domain (IDN labels in punycode); covers subdomains. */
    data class Domain(override val value: String) : BypassEntry()
}

data class Rejection(val line: String, val reason: String)

data class SplitTunnelResult(val entries: List<BypassEntry>, val rejected: List<Rejection>)

object SplitTunnelParser {
    /** Narrowest prefixes accepted: broader would route most of the internet around the tunnel. */
    const val minimumIPv4Prefix = 8
    const val minimumIPv6Prefix = 16

    private data class Reserved(val network: Long, val prefix: Int, val reason: String)

    /** Loopback (never tunneled anyway) and the tunnel's own ranges. */
    private val reservedIPv4 = listOf(
        Reserved(0x7F00_0000, 8, "loopback never goes through the VPN"),
        Reserved(0xAC1C_0000, 24, "that range is the VPN tunnel itself"),
        Reserved(0xAC1D_0000, 24, "that range is the VPN tunnel itself"),
    )

    /** A free-form paste: newlines, commas, semicolons and spaces separate; `#` starts a comment. */
    fun parse(text: String): SplitTunnelResult {
        // Swift режет вставку по `\.isNewline` — это ещё VT, FF, NEL, LS и PS
        // (переносы, которые приходят вместе с текстом из PDF или страницы).
        val lines = splitOnNewlines(text).flatMap { line ->
            val code = line.substringBefore('#')
            code.split(',', ';', ' ', '\t').filter { it.isNotEmpty() }
        }.toList()
        return parse(lines)
    }

    /** Stored lines, one destination each. Duplicates collapse, order is kept. */
    fun parse(lines: List<String>): SplitTunnelResult {
        val entries = ArrayList<BypassEntry>()
        val seen = HashSet<BypassEntry>()
        val rejected = ArrayList<Rejection>()
        for (raw in lines) {
            val line = trimSpaceLike(raw)
            if (line.isEmpty() || line.startsWith("#")) continue
            val parsed = runCatching { entry(line) }
            val value = parsed.getOrNull()
            if (value == null) {
                rejected.add(Rejection(line, parsed.exceptionOrNull()!!.message ?: ""))
            } else if (seen.add(value)) {
                entries.add(value)
            }
        }
        return SplitTunnelResult(entries, rejected)
    }

    /** What the tunnel routes by address, and what it must resolve first. */
    fun partition(entries: List<BypassEntry>): Pair<List<String>, List<String>> =
        entries.partition { !it.isDomain }.let { it.first.map { e -> e.value } to it.second.map { e -> e.value } }

    private class BypassException(message: String) : Exception(message)

    internal fun entry(input: String): BypassEntry {
        var s = input.lowercase()
        val scheme = s.indexOf("://")
        if (scheme >= 0) s = s.substring(scheme + 3)
        val at = s.lastIndexOf('@')
        if (at >= 0) s = s.substring(at + 1)

        if (s.startsWith("[") && s.contains("]")) {
            return ipv6(s.substring(1, s.indexOf(']')), null)
        }
        val slashParts = splitOnce(s, '/')
        val head = slashParts.first
        val tail = slashParts.second
        if (head.contains(':') && head.count { it == ':' } > 1) return ipv6(head, tail)
        val hostPort = splitOnce(head, ':')
        val host = hostPort.first
        // A prefix only belongs to a bare address, not to host:port or a path.
        if (isIPv4Literal(host)) return ipv4(host, if (hostPort.second == null) tail else null)
        return domain(host)
    }

    private fun splitOnce(text: String, separator: Char): Pair<String, String?> {
        val index = text.indexOf(separator)
        return if (index < 0) text to null else text.substring(0, index) to text.substring(index + 1)
    }

    internal fun isIPv4Literal(text: String): Boolean {
        val parts = text.split('.')
        return parts.size == 4 && parts.all { part ->
            part.isNotEmpty() && part.all { it.code < 128 } && part.all { it.isDigit() }
        }
    }

    private fun ipv4(address: String, prefix: String?): BypassEntry {
        var value = 0L
        for (part in address.split('.')) {
            val octet = swiftInt(part)
            if (part.length > 3 || octet == null || octet > 255 || (part.length > 1 && part[0] == '0')) {
                throw BypassException("not a valid IPv4 address")
            }
            value = (value shl 8) or octet.toLong()
        }
        var bits = 32
        if (prefix != null) {
            val p = swiftInt(prefix)
            if (p == null || p !in 0..32) throw BypassException("prefix length must be 0–32")
            bits = p
        }
        if (bits < minimumIPv4Prefix) {
            throw BypassException(
                "too broad — /$bits would send most traffic around the VPN (use /$minimumIPv4Prefix or narrower)"
            )
        }
        val mask = if (bits == 0) 0L else (0xFFFF_FFFFL shl (32 - bits)) and 0xFFFF_FFFFL
        val network = value and mask
        for (reserved in reservedIPv4) {
            val common = minOf(bits, reserved.prefix)
            val commonMask = if (common == 0) 0L else (0xFFFF_FFFFL shl (32 - common)) and 0xFFFF_FFFFL
            if (network and commonMask == reserved.network and commonMask) {
                throw BypassException(reserved.reason)
            }
        }
        val dotted = listOf(24, 16, 8, 0).joinToString(".") { "${(network shr it) and 0xFF}" }
        return BypassEntry.IPv4("$dotted/$bits")
    }

    private fun ipv6(address: String, prefix: String?): BypassEntry {
        val bytes = if (address.contains('%')) null else inetPton6(address)
        if (bytes == null) throw BypassException("not a valid IPv6 address")
        var bits = 128
        if (prefix != null) {
            val p = swiftInt(prefix)
            if (p == null || p !in 0..128) throw BypassException("prefix length must be 0–128")
            bits = p
        }
        if (bits < minimumIPv6Prefix) {
            throw BypassException(
                "too broad — /$bits would send most IPv6 traffic around the VPN (use /$minimumIPv6Prefix or narrower)"
            )
        }
        if (bytes.copyOf(15).all { it == 0.toByte() } && bytes[15] == 1.toByte()) {
            throw BypassException("loopback never goes through the VPN")
        }
        for (i in 0..15) {
            val keep = maxOf(0, minOf(8, bits - i * 8))
            if (keep < 8) bytes[i] = (bytes[i].toInt() and (0xFF shl (8 - keep) and 0xFF)).toByte()
        }
        return BypassEntry.IPv6("${inetNtop6(bytes)}/$bits")
    }

    /** RFC 4291 text, `::` and an IPv4 tail; returns 16 bytes or null. */
    internal fun inetPton6(text: String): ByteArray? {
        val doubleColon = text.indexOf("::")
        if (doubleColon >= 0 && text.indexOf("::", doubleColon + 1) >= 0) return null
        val head = if (doubleColon >= 0) text.substring(0, doubleColon) else text
        val tail = if (doubleColon >= 0) text.substring(doubleColon + 2) else ""
        val left = groups(head, allowIPv4Tail = doubleColon < 0) ?: return null
        val fill = ArrayList<Int>()
        if (doubleColon < 0) {
            fill.addAll(left)
        } else {
            val right = groups(tail) ?: return null
            val missing = 8 - left.size - right.size
            if (missing < 0) return null
            fill.addAll(left)
            repeat(missing) { fill.add(0) }
            fill.addAll(right)
        }
        if (fill.size != 8) return null
        val bytes = ByteArray(16)
        for ((index, group) in fill.withIndex()) {
            bytes[index * 2] = ((group shr 8) and 0xFF).toByte()
            bytes[index * 2 + 1] = (group and 0xFF).toByte()
        }
        return bytes
    }

    /**
     * Colon-separated groups; a dotted IPv4 in the last position stands for
     * two of them (16 bits each), which is why the return is pairs of ints.
     * `allowIPv4Tail` is off for the half that precedes `::` — C's `inet_pton`
     * ends the address at a dotted quad, so `1.2.3.4::` is not an address.
     */
    private fun groups(text: String, allowIPv4Tail: Boolean = true): List<Int>? {
        if (text.isEmpty()) return emptyList()
        val parts = text.split(':')
        val out = ArrayList<Int>()
        for ((index, part) in parts.withIndex()) {
            if (allowIPv4Tail && index == parts.size - 1 && part.contains('.')) {
                val octets = part.split('.')
                if (octets.size != 4 || !isIPv4Literal(part)) return null
                var packed = 0
                for (octet in octets) {
                    val value = swiftInt(octet) ?: return null
                    if (octet.length > 3 || value > 255 || (octet.length > 1 && octet[0] == '0')) return null
                    packed = packed shl 8 or value
                }
                out.add(packed shr 16)
                out.add(packed and 0xFFFF)
            } else {
                if (part.isEmpty() || part.length > 4) return null
                var value = 0
                for (digit in part) {
                    val d = when (digit) {
                        in '0'..'9' -> digit - '0'
                        in 'a'..'f' -> digit - 'a' + 10
                        in 'A'..'F' -> digit - 'A' + 10
                        else -> return null
                    }
                    value = value * 16 + d
                }
                out.add(value)
            }
        }
        return out
    }

    /**
     * Compression as C's `inet_ntop(AF_INET6,)` renders it: the longest run of
     * at least two zero groups becomes `::`, the first such run on a tie, and a
     * single zero group is spelled out.
     */
    internal fun inetNtop6(bytes: ByteArray): String {
        val groups = IntArray(8) { ((bytes[it * 2].toInt() and 0xFF) shl 8) or (bytes[it * 2 + 1].toInt() and 0xFF) }
        var bestStart = -1
        var bestLength = 0
        var start = 0
        while (start < 8) {
            if (groups[start] != 0) {
                start += 1
                continue
            }
            var end = start
            while (end < 8 && groups[end] == 0) end += 1
            if (end - start > bestLength) {
                bestStart = start
                bestLength = end - start
            }
            start = end
        }
        if (bestLength < 2) bestStart = -1
        // Measured against the same addresses through Swift's parser: only a
        // leading run of six groups — or five plus `ffff' — is written as a
        // dotted IPv4 tail, anything else keeps hex groups.
        if (bestStart == 0 &&
            (bestLength == 6 || (bestLength == 5 && groups[5] == 0xFFFF))
        ) {
            val quad = "${bytes[12].toInt() and 0xFF}.${bytes[13].toInt() and 0xFF}." +
                "${bytes[14].toInt() and 0xFF}.${bytes[15].toInt() and 0xFF}"
            return if (bestLength == 6) "::$quad" else "::ffff:$quad"
        }
        val text = StringBuilder()
        var i = 0
        while (i < 8) {
            if (i == bestStart) {
                text.append("::")
                i += bestLength
                if (i >= 8) break
                continue
            }
            if (text.isNotEmpty() && !text.endsWith(":")) text.append(':')
            text.append(groups[i].toString(16))
            i += 1
        }
        return text.toString()
    }

    private fun domain(input: String): BypassEntry {
        var host = input.removePrefix("*.")
        if (host.startsWith(".")) host = host.substring(1)
        if (host.endsWith(".")) host = host.substring(0, host.length - 1)
        if (host.isEmpty()) throw BypassException("empty domain")
        val labels = ArrayList<String>()
        for (label in host.split('.')) {
            if (label.isEmpty()) throw BypassException("not a valid domain")
            val ascii = Punycode.encodeLabel(label) ?: throw BypassException("not a valid domain")
            val ok = ascii.length <= 63 && ascii.all { (it.code < 128 && (it.isLetter() || it.isDigit())) || it == '-' } && ascii.first() != '-' && ascii.last() != '-'
            if (!ok) throw BypassException("not a valid domain")
            labels.add(ascii)
        }
        val joined = labels.joinToString(".")
        if (joined.length > 253) throw BypassException("domain is too long")
        if (labels.all { label -> label.all { it.isDigit() } }) {
            throw BypassException("not a valid IP address or domain")
        }
        return BypassEntry.Domain(joined)
    }
}

/**
 * RFC 3492 Punycode for one label ("пример" → "xn--e1afmkfd"): the tunnel rules
 * match the ASCII form a TLS ClientHello carries, so a Cyrillic domain the user
 * typed has to be converted. Port of `Punycode` in `SplitTunnel.swift`.
 */
object Punycode {
    private const val base = 36
    private const val tMin = 1
    private const val tMax = 26
    private const val skew = 38
    private const val damp = 700
    private const val initialBias = 72
    private const val initialN = 128

    /** ASCII labels pass through unchanged; null means the value overflowed. */
    fun encodeLabel(label: String): String? {
        val scalars = label.codePoints().toArray().toList()
        if (scalars.none { it >= initialN }) return label
        val output = StringBuilder()
        scalars.filter { it < initialN }.forEach { output.appendCodePoint(it) }
        val basicCount = output.length
        var handled = basicCount
        if (basicCount > 0) output.append('-')
        var n = initialN
        var delta = 0L
        var bias = initialBias
        while (handled < scalars.size) {
            val m = scalars.filter { it >= n }.minOrNull() ?: return null
            val step = (m - n).toLong() * (handled + 1).toLong()
            if (step > Long.MAX_VALUE - delta) return null
            delta += step
            n = m
            for (c in scalars) {
                if (c < n) delta += 1
                if (c != n) continue
                var q = delta
                var k = base
                while (true) {
                    val t = if (k <= bias) tMin else if (k >= bias + tMax) tMax else k - bias
                    if (q < t) break
                    output.append(digit((t + (q - t) % (base - t)).toInt()))
                    q = (q - t) / (base - t)
                    k += base
                }
                output.append(digit(q.toInt()))
                bias = adapt(delta, handled + 1, handled == basicCount)
                delta = 0
                handled += 1
            }
            delta += 1
            n += 1
        }
        return "xn--$output"
    }

    private fun adapt(delta: Long, points: Int, first: Boolean): Int {
        var d = if (first) delta / damp else delta / 2
        d += d / points
        var k = 0
        while (d > (base - tMin).toLong() * tMax / 2) {
            d /= (base - tMin).toLong()
            k += base
        }
        return k + ((base - tMin + 1).toLong() * d / (d + skew)).toInt()
    }

    /** 0-25 → a-z, 26-35 → 0-9, exactly as Swift's `97 + d` / `22 + d`. */
    private fun digit(d: Int): Char = if (d < 26) ('a' + d) else ('0' + (d - 26))
}
