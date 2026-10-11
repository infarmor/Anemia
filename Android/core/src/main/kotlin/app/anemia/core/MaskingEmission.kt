package app.anemia.core

/**
 * Port of `Sources/LoaderCore/MaskingEmission.swift`: which masking records the
 * pinned engine will actually load.
 *
 * xray 26.3.27 reads junk packets from the masking `freedom` outbound's
 * `settings.noises` and fragmentation from `settings.fragment` — there is no
 * `sockopt.noises` — and it reads both STRICTLY: a record `ParseNoise`
 * dislikes aborts the whole config, so a poisoned entry from a panel would
 * stop the tunnel from starting at all. The verdicts are the engine's own,
 * re-measured by `Scripts/verify-noise-grammar.sh` against
 * `Android/core/src/test/resources/mask/grammar.tsv`; this file is the mirror
 * of that table, not an interpretation of it.
 *
 * The direction of doubt matters: dropping a record the engine would have
 * taken costs one junk packet, emitting one it refuses costs the connection.
 * So the trim set is the ASCII part of Go's `strings.TrimSpace` (Kotlin's
 * `trim()` knows nothing of U+00A0, Go does) — we may salvage less than the
 * engine, never more.
 */

/** The noises to emit, in profile order, minus any the engine would refuse. */
val AntiCensorshipOptions.emittableNoises: List<AntiCensorshipOptions.Noise>
    get() = noises.filter { it.isEmittable }

/** The fragment to emit, or null when the engine would refuse to load it. */
val AntiCensorshipOptions.emittableFragment: AntiCensorshipOptions.Fragment?
    get() = fragment?.takeIf { it.isEmittable }

val AntiCensorshipOptions.Noise.isEmittable: Boolean
    get() {
        // `delay` is an Int32Range: parsed, and NOT trimmed by the engine.
        if (XrayRange.parse(delay) == null) return false
        val payload = packet.trim(*XrayRange.engineWhitespace)
        return when (type) {
            // `rand lengthMin or lengthMax cannot be 0` — checked against the
            // LEFT bound as written: "100-50" and "-5" survive, "0-100" does
            // not. Unlike a delay, a rand length is never reordered.
            "rand" -> XrayRange.parse(payload)?.let { it.first != 0L } == true
            "str" -> true
            // `hex.DecodeString`: an even number of BYTES of hex digits.
            "hex" -> payload.toByteArray(Charsets.UTF_8).let { bytes ->
                bytes.size % 2 == 0 && bytes.all {
                    val b = it.toInt()
                    (b in '0'.code..'9'.code) || (b in 'A'.code..'F'.code) || (b in 'a'.code..'f'.code)
                }
            }
            // `base64.RawURLEncoding.DecodeString` of the packet with '+'→'-',
            // '/'→'_' and every '=' deleted. Raw means unpadded, so a length
            // that leaves one trailing character is the corruption it reports.
            "base64" -> {
                val bytes = payload.toByteArray(Charsets.UTF_8).asList().mapNotNull { b ->
                    when (b) {
                        '+'.code.toByte() -> '-'.code.toByte()
                        '/'.code.toByte() -> '_'.code.toByte()
                        '='.code.toByte() -> null
                        else -> b
                    }
                }
                bytes.size % 4 != 1 && bytes.all {
                    val b = it.toInt()
                    (b in '0'.code..'9'.code) || (b in 'A'.code..'Z'.code) ||
                        (b in 'a'.code..'z'.code) || b == '-'.code || b == '_'.code
                }
            }
            // Case-sensitive, exactly as `ParseNoise` matches them.
            else -> false
        }
    }

val AntiCensorshipOptions.Fragment.isEmittable: Boolean
    get() {
        // `packets` is lower-cased only for the tlshello test; the range branch
        // then reads the original, untrimmed string.
        when (packets.lowercase()) {
            "", "tlshello" -> Unit
            else -> if (XrayRange.parse(packets)?.let { it.first != 0L } != true) return false
        }
        // `length`/`interval` are `*Int32Range`: unparseable or absent is a
        // config error, and a parsed range is REORDERED before the zero check —
        // so "200-0" is as fatal here as "0-200", unlike a rand length.
        val (lo, hi) = XrayRange.parse(length) ?: return false
        if (minOf(lo, hi) == 0L) return false
        return XrayRange.parse(interval) != null
    }

/** `ParseRangeString` from `infra/conf/common.go` of the pinned engine. */
internal object XrayRange {
    /** The ASCII members of Go's `unicode.IsSpace`, spelled out so Swift and
     *  Kotlin trim the same characters. */
    val engineWhitespace = charArrayOf(' ', '\t', '\n', '\u000B', '\u000C', '\r')

    /**
     * A plain integer Go's `strconv.Atoi` accepts (`+10` and `-0` are numbers,
     * ` 10`, `1_0` and a value past 2^63 are not), `""` which the engine reads
     * as zero, or `lo-hi` — where a leading `-` belongs to the low bound and
     * the split happens at the SECOND dash, so `-114-514` is (-114, 514), `-5`
     * is a plain number and `--1` is nothing.
     */
    fun parse(text: String): Pair<Long, Long>? {
        text.toLongOrNull()?.let { return it to it }
        if (text.isEmpty()) return 0L to 0L
        val pair = if (text.startsWith("-")) {
            // splitFromSecondDash: fewer than three fields means no range at all.
            val head = text.split("-", limit = 3)
            if (head.size != 3) return null
            listOf(head[0] + "-" + head[1], head[2])
        } else {
            text.split("-", limit = 2)
        }
        if (pair.size != 2) return null
        val lo = pair[0].toLongOrNull() ?: return null
        val hi = pair[1].toLongOrNull() ?: return null
        return lo to hi
    }
}
