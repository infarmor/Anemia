package app.anemia.core

import java.math.BigInteger

/**
 * Множества сетей для `VpnService`.
 *
 * iOS позволяет сказать туннелю «всё, кроме этих сетей» (`excludedRoutes`), а
 * Android умеет только перечислять то, что *входит*: `addRoute(address, bits)`.
 * Поэтому обход VPN приходится вычитать руками — иначе список обхода
 * превращается в молчаливое «весь трафик в туннель».
 *
 * Считается по битам адреса: `subtract` делит сеть пополам до тех пор, пока
 * оставшиеся куски не перестанут пересекаться с вычитаемой сетью.
 */
object Routes {
    data class Prefix(val value: BigInteger, val bits: Int, val ipv6: Boolean) {
        val width: Int get() = if (ipv6) 128 else 32

        /** Сеть в каноническом виде: `10.0.0.0/8`, `::/0`. */
        fun format(): String = (if (ipv6) format6(network()) else format4(network())) + "/$bits"

        /** Адрес без хост-бит. */
        fun network(): BigInteger = value.and(hostMask().not())

        /** Попадает ли [other] внутрь этой сети. */
        fun contains(other: Prefix): Boolean =
            other.bits >= bits && other.value.and(hostMask().not()) == network()

        /** Младшие `width - bits` бит — то, что в адресе сети обнуляется. */
        private fun hostMask(): BigInteger =
            if (bits >= width) BigInteger.ZERO
            else BigInteger.ONE.shiftLeft(width - bits).subtract(BigInteger.ONE)

        /** Ровно `width/8` байт сети, старший байт первым: у BigInteger может
            быть ведущий байт знака, а младшие байты — короче. */
        private fun bytes(v: BigInteger): ByteArray {
            val raw = v.toByteArray()
            val width = this.width / 8
            val out = ByteArray(width)
            val source = if (raw.size > width) raw.copyOfRange(raw.size - width, raw.size) else raw
            System.arraycopy(source, 0, out, width - source.size, source.size)
            return out
        }

        private fun format4(v: BigInteger): String =
            bytes(v).joinToString(".") { (it.toInt() and 0xFF).toString() }

        private fun format6(v: BigInteger): String {
            val raw = bytes(v)
            val groups = (0 until 8).map { ((raw[it * 2].toInt() and 0xFF) shl 8) or (raw[it * 2 + 1].toInt() and 0xFF) }
            // Сжатие как в inet_ntop: самый длинный прогон нулей; одна нулевая
            // группа не сжимается.
            var bestStart = -1
            var bestLength = 0
            var start = -1
            for (i in groups.indices) {
                if (groups[i] == 0) {
                    if (start < 0) start = i
                    if (i - start + 1 > bestLength) { bestLength = i - start + 1; bestStart = start }
                } else {
                    start = -1
                }
            }
            if (bestLength < 2) return groups.joinToString(":") { it.toString(16) }
            val head = groups.subList(0, bestStart).joinToString(":") { it.toString(16) }
            val tail = groups.subList(bestStart + bestLength, groups.size)
                .joinToString(":") { it.toString(16) }
            return "$head::$tail"
        }
    }

    /** `null` для мусора и для домена: вычитать можно только сети. */
    fun parse(text: String): Prefix? {
        val body = text.trim()
        val head = body.substringBefore('/', body)
        val suffix = body.substringAfter('/', "")
        val bits = if (suffix.isEmpty()) null else suffix.toIntOrNull()
        val v4 = Addresses.isIPv4(head)
        val v6 = !v4 && Addresses.isIPv6(head)
        if (!v4 && !v6) return null
        val width = if (v6) 128 else 32
        val length = bits ?: width
        if (length < 0 || length > width) return null
        return Prefix(valueOf(head, v6), length, v6)
    }

    private fun valueOf(text: String, ipv6: Boolean): BigInteger {
        if (!ipv6) {
            var value = BigInteger.ZERO
            for (part in text.split('.')) value = value.shiftLeft(8).add(BigInteger.valueOf(part.toLong()))
            return value
        }
        val compressed = text.contains("::")
        fun words(chunk: String): List<BigInteger> =
            if (chunk.isEmpty()) emptyList()
            else chunk.split(':').filter { it.isNotEmpty() }.map { BigInteger(it, 16) }
        val head = words(if (compressed) text.substringBefore("::") else text)
        val tail = if (compressed) words(text.substringAfter("::")) else emptyList()
        val groups = if (compressed) {
            val fill = 8 - head.size - tail.size
            head + List(if (fill > 0) fill else 0) { BigInteger.ZERO } + tail
        } else head
        var value = BigInteger.ZERO
        for (group in groups) value = value.shiftLeft(16).or(group)
        return value
    }

    /** Части [from], не покрытые [excluding]; пусто, если [excluding] съедает её целиком. */
    fun subtract(from: Prefix, excluding: Prefix): List<Prefix> {
        if (from.ipv6 != excluding.ipv6) return listOf(from)
        if (!from.contains(excluding) && !excluding.contains(from)) return listOf(from)
        if (excluding.contains(from)) return emptyList()
        if (from.bits == from.width) return emptyList()
        val childBits = from.bits + 1
        val step = BigInteger.ONE.shiftLeft(from.width - childBits)
        return subtract(Prefix(from.network(), childBits, from.ipv6), excluding) +
            subtract(Prefix(from.network().add(step), childBits, from.ipv6), excluding)
    }

    /**
     * Разрешённые сети минус обход — строки, готовые для `addRoute`.
     * IPv4 идёт до IPv6, внутри — по возрастанию маски.
     */
    fun included(allowed: List<String>, excluded: List<String>): List<String> {
        var pieces = allowed.mapNotNull(::parse)
        for (gap in excluded.mapNotNull(::parse)) {
            pieces = pieces.flatMap { subtract(it, gap) }
        }
        return pieces
            .sortedWith(compareBy({ !it.ipv6 }, { it.bits }, { it.network() }))
            .distinctBy { "${it.ipv6}:${it.network()}:${it.bits}" }
            .map { it.format() }
    }
}
