package app.anemia.core

/** One counter from the engine's stats service. */
data class XrayStat(val name: String, val value: Long)

/**
 * Port of the wire half of `Sources/LoaderCore/XrayStatsAPI.swift`: the
 * gRPC-over-h2c request bytes for `QueryStats`, and the protobuf reader for the
 * answer. The socket itself is app business — but the engine's loopback stats
 * port is unauthenticated, so anything may answer there, and the reader's
 * hostility handling is exactly the part two platforms must agree on.
 */
object StatsWire {
    private const val PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
    private const val PATH = "/xray.app.stats.command.StatsService/QueryStats"

    /** Preface + SETTINGS + a large WINDOW_UPDATE + HEADERS + DATA(END_STREAM). */
    fun requestBytes(port: Int, pattern: String?): ByteArray {
        val out = java.io.ByteArrayOutputStream(512)
        out.write(PREFACE.toByteArray(Charsets.UTF_8))
        out.write(frame(0x4, 0, 0, ByteArray(0)))                              // SETTINGS (empty)
        out.write(frame(0x8, 0, 0, byteArrayOf(0x00, 0x0F, 0x42, 0x40)))       // +1 MiB of window
        var headers = ByteArray(0)
        for ((name, value) in listOf(
            ":method" to "POST", ":scheme" to "http", ":path" to PATH,
            ":authority" to "127.0.0.1:$port", "content-type" to "application/grpc",
            "te" to "trailers", "user-agent" to "anemia-stats/1",
        )) {
            headers += header(name, value)
        }
        out.write(frame(0x1, 0x4, 1, headers))                                 // HEADERS + END_HEADERS
        // QueryStatsRequest { string pattern = 1 } — an empty message when nil.
        var body = ByteArray(0)
        if (pattern != null) {
            val bytes = pattern.toByteArray(Charsets.UTF_8)
            body = byteArrayOf(0x0A) + encodeVarint(bytes.size.toLong()) + bytes
        }
        // gRPC: one compression flag byte plus a fixed 4-byte big-endian length.
        val length = body.size
        val grpc = byteArrayOf(
            0x00, (length shr 24).toByte(), (length shr 16).toByte(),
            (length shr 8).toByte(), length.toByte(),
        ) + body
        out.write(frame(0x0, 0x1, 1, grpc))                                    // DATA + END_STREAM
        return out.toByteArray()
    }

    internal fun encodeVarint(value: Long): ByteArray {
        var v = value.toULong()
        val out = ArrayList<Byte>()
        while (true) {
            var b = (v and 0x7FU).toUByte()
            v = v shr 7
            if (v != 0UL) b = b or 0x80u.toUByte()
            out.add(b.toByte())
            if (v == 0UL) break
        }
        return out.toByteArray()
    }

    /** 24-bit big-endian length + type + flags + 32-bit stream id. */
    internal fun frame(type: Int, flags: Int, stream: Int, payload: ByteArray): ByteArray {
        val n = payload.size
        return byteArrayOf(
            ((n shr 16) and 0xFF).toByte(), ((n shr 8) and 0xFF).toByte(), (n and 0xFF).toByte(),
            type.toByte(), flags.toByte(),
            (stream shr 24).toByte(), (stream shr 16).toByte(), (stream shr 8).toByte(), stream.toByte(),
        ) + payload
    }

    /**
     * HPACK literal header field without indexing, no Huffman — a stateless
     * encoding both sides can decode without table bookkeeping.
     */
    internal fun header(name: String, value: String): ByteArray {
        fun str(text: String): ByteArray {
            val bytes = text.toByteArray(Charsets.UTF_8)
            if (bytes.size < 127) return byteArrayOf(bytes.size.toByte()) + bytes
            val out = java.io.ByteArrayOutputStream()
            out.write(0x7F)
            var n = bytes.size - 127
            while (n >= 128) {
                out.write((n and 0x7F) or 0x80)
                n = n shr 7
            }
            out.write(n)
            out.write(bytes)
            return out.toByteArray()
        }
        return byteArrayOf(0x00) + str(name) + str(value)
    }

    /**
     * QueryStatsResponse { repeated Stat stat = 1 }, Stat { string name = 1;
     * int64 value = 2 }. Anything unexpected ends the walk with what was read:
     * the engine's answer is the only thing we trust to be well-formed here.
     */
    fun parseProtobuf(data: ByteArray): List<XrayStat> {
        val stats = ArrayList<XrayStat>()

        /**
         * One cursor over one buffer — a nested `Stat` is walked inside its own
         * bytes, exactly as Swift's `varint(in: sub, &j)` does. Sharing the outer
         * array instead would read the length of a message as an offset into the
         * whole response and return the wrong slice.
         */
        class Reader(private val bytes: ByteArray) {
            var at = 0

            fun varint(): ULong {
                var v = 0UL
                var shift = 0
                while (at < bytes.size) {
                    val b = bytes[at].toInt() and 0xFF
                    at += 1
                    v = v or ((b.toULong() and 0x7Fu) shl shift)
                    if (b and 0x80 == 0) break
                    shift += 7
                }
                return v
            }

            fun lengthDelimited(): ByteArray? {
                // The length stays a ULong and is bounded against what is left
                // before any narrowing: a hostile 10-byte varint from whatever is
                // listening on the loopback stats port must not size a read past
                // the buffer.
                val raw = varint()
                if (raw > (bytes.size - at).toULong()) return null
                val len = raw.toInt()
                val sub = bytes.copyOfRange(at, at + len)
                at += len
                return sub
            }
        }

        val outer = Reader(data)
        while (outer.at < data.size) {
            when (outer.varint()) {
                (1UL shl 3) or 2UL -> {
                    val sub = outer.lengthDelimited() ?: return stats
                    var name = ""
                    var value = 0L
                    val inner = Reader(sub)
                    while (inner.at < sub.size) {
                        when (inner.varint()) {
                            (1UL shl 3) or 2UL -> {
                                val bytes = inner.lengthDelimited() ?: return stats
                                name = utf8(bytes) ?: return stats
                            }
                            (2UL shl 3) or 0UL -> value = inner.varint().toLong()
                            else -> return stats
                        }
                    }
                    stats.add(XrayStat(name, value))
                }
                else -> return stats
            }
        }
        return stats
    }
}
