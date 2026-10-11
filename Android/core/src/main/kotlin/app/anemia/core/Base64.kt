package app.anemia.core

import java.nio.ByteBuffer
import java.util.Base64 as JavaBase64

/**
 * Port of `Sources/LoaderCore/Base64.swift`, plus the strict UTF-8 read Swift
 * does with `String(data:encoding:.utf8)` — a lossy decode would turn a broken
 * blob into mojibake instead of the parse failure the caller expects.
 */
object Base64 {

    /** Standard or URL-safe base64, with or without padding. */
    fun decodeFlexible(input: String): ByteArray? {
        val trimmed = trimSpaceLike(input)
        if (trimmed.isEmpty()) return null
        val normalized =
            if (trimmed.any { it == '-' || it == '_' }) {
                trimmed.replace('-', '+').replace('_', '/')
            } else trimmed
        // Padding is computed over the alphabet-only view: the decoder drops
        // anything outside it, so counting a stray character would mis-pad a
        // blob that would otherwise decode.
        val alphabetOnly = buildString(normalized.length) {
            for (char in normalized) if (char.isBase64AlphabetChar()) append(char)
        }
        if (alphabetOnly.isEmpty()) {
            // Foundation decodes a blob of nothing to empty input only when the
            // raw length fills whole 4-char groups; `###` fails and `####` is
            // empty. Not a rule anyone would invent, just the one it has.
            return if (trimmed.length % 4 == 0) ByteArray(0) else null
        }
        val remainder = alphabetOnly.length % 4
        val padded =
            if (remainder == 0) alphabetOnly else alphabetOnly + "=".repeat(4 - remainder)
        return decodeGroups(padded)
    }

    /** Flexible base64 to a UTF-8 string, if both steps decode. */
    fun decodeToString(input: String): String? =
        decodeFlexible(input)?.let { utf8(it) }

    /**
     * Group-at-a-time decode matching Foundation's
     * `Data(base64Encoded:, .ignoreUnknownCharacters)`: surplus bits in the
     * last character are dropped, a group that carries padding ends the
     * stream, and junk after padding is an error rather than a shorter answer.
     */
    private fun decodeGroups(text: String): ByteArray? {
        val out = java.io.ByteArrayOutputStream(text.length / 4 * 3)
        var index = 0
        while (index < text.length) {
            val values = IntArray(4)
            var padAt = -1
            for (offset in 0..3) {
                val char = text[index + offset]
                when {
                    char == '=' -> if (padAt < 0) padAt = offset
                    padAt >= 0 -> return null
                    else -> values[offset] = VALUE[char.code]
                }
            }
            val data = if (padAt < 0) 4 else padAt
            if (data == 1) return null
            if (data == 0) {
                // Padding-only groups are accepted while nothing but padding
                // follows; `AAAA====AA==` is not a padded tail.
                if (out.size() == 0) return null
                if (text.substring(index).any { it != '=' }) return null
                return out.toByteArray()
            }
            val bits = (values[0] shl 18) or (values[1] shl 12) or (values[2] shl 6) or values[3]
            out.write(bits shr 16)
            if (data >= 3) out.write(bits shr 8)
            if (data == 4) out.write(bits)
            if (padAt >= 0) return out.toByteArray()
            index += 4
        }
        return out.toByteArray()
    }

    private val VALUE = IntArray(128).apply {
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
            .forEachIndexed { position, char -> this[char.code] = position }
    }
}

private fun Char.isBase64AlphabetChar(): Boolean =
    this in 'a'..'z' || this in 'A'..'Z' || this in '0'..'9' ||
        this == '-' || this == '_' || this == '+' || this == '/' || this == '='

/** UTF-8 bytes → String, or null when they aren't valid UTF-8. */
internal fun utf8(bytes: ByteArray): String? =
    runCatching { Charsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(bytes)).toString() }
        .getOrNull()

/**
 * `%XX` escapes decoded; `+` stays a plus. Null when an escape is malformed or
 * the bytes aren't valid UTF-8 — the same `nil` Swift's `removingPercentEncoding`
 * returns, which callers must not paper over with the raw text.
 */
internal fun percentDecoded(text: String): String? {
    if (!text.contains('%')) return text
    val result = StringBuilder(text.length)
    val bytes = java.io.ByteArrayOutputStream(text.length)
    var index = 0
    tail@ while (index < text.length) {
        if (text[index] != '%') {
            val start = index
            while (index < text.length && text[index] != '%') index += 1
            // Literal runs go in as text so surrogate pairs survive; escaped
            // runs are bytes, flushed as one UTF-8 sequence.
            if (bytes.size() > 0) {
                val decoded = utf8(bytes.toByteArray()) ?: return null
                result.append(decoded)
                bytes.reset()
            }
            result.append(text, start, index)
            continue@tail
        }
        if (index + 2 >= text.length) return null
        val high = hexDigit(text[index + 1]) ?: return null
        val low = hexDigit(text[index + 2]) ?: return null
        bytes.write(high * 16 + low)
        index += 3
    }
    if (bytes.size() > 0) {
        val decoded = utf8(bytes.toByteArray()) ?: return null
        result.append(decoded)
    }
    return result.toString()
}

private fun hexDigit(char: Char): Int? = when (char) {
    in '0'..'9' -> char - '0'
    in 'a'..'f' -> char - 'a' + 10
    in 'A'..'F' -> char - 'A' + 10
    else -> null
}

/**
 * Mirrors `trimmingCharacters(in: .whitespacesAndNewlines)`: the Unicode space
 * separators plus tab, the C0 controls 09…0D, NEL, LS and PS — measured scalar
 * by scalar against `CharacterSet` (`base64/trim-sets.tsv`), not guessed from a
 * name. `Char.isWhitespace()` cannot stand in for it: which characters it
 * counts as space is JDK-version dependent (this build's JVM trims NBSP,
 * Android's libcore does not), so the set is written out here and is the same
 * on every runtime. NBSP is the character a link picked up from a messenger
 * carries, and leaving it in place breaks the scheme.
 */
fun trimSpaceLike(text: String): String = trimWith(text, ::isSpaceLike)

/**
 * `trimmingCharacters(in: .whitespaces)` — what Foundation uses for conf keys,
 * values and route entries: Zs (NBSP, ZWSP U+200B …) plus tab, and *not*
 * newline, vertical tab, form feed, CR, NEL, LS or PS, which the set above
 * does. Both halves of that difference are observable — a zero-width space left
 * in an `allowed_ip` makes the engine reject the whole IpcSet, and a `\n` left
 * in a pin list is a length error on iOS but would parse on a JVM that trims
 * newlines away.
 */
fun trimFoundationSpaces(text: String): String = trimWith(text, ::isFoundationSpace)

private fun trimWith(text: String, matches: (Char) -> Boolean): String {
    var start = 0
    var end = text.length
    while (start < end && matches(text[start])) start += 1
    while (end > start && matches(text[end - 1])) end -= 1
    return text.substring(start, end)
}

internal fun isSpaceLike(char: Char): Boolean =
    char == ' ' || char in '\u0009'..'\u000D' || char == '\u0085' || char == '\u00A0' ||
        char == '\u1680' || char in '\u2000'..'\u200B' || char == '\u2028' ||
        char == '\u2029' || char == '\u202F' || char == '\u205F' || char == '\u3000'

internal fun isFoundationSpace(char: Char): Boolean =
    char == ' ' || char == '\u0009' || char == '\u00A0' ||
        char == '\u1680' || char in '\u2000'..'\u200B' || char == '\u202F' ||
        char == '\u205F' || char == '\u3000'
