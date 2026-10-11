package app.anemia.core

/**
 * A small strict JSON reader for what comes out of share links and Amnezia
 * envelopes: `Map<String, Any?>`, `List<Any?>`, `String`, `Double`, `Boolean`
 * and `null`. Anything malformed throws [JsonException] — the callers turn that
 * into a parse error, so leniency here would import garbage as a server.
 *
 * The value readers mirror Swift's `NSNumber` bridging, which vmess panels hit
 * in every combination: `"port": 443`, `"port": "443"` and `"tls": true` all
 * appear in the wild, and reading a number as a string has to produce the same
 * text Foundation does (`443`, not `443.0`).
 */
class JsonException(message: String) : Exception(message)

object Json {
    fun parse(text: String): Any? {
        val reader = Reader(text)
        reader.skipSpace()
        val value = reader.value()
        reader.skipSpace()
        if (!reader.atEnd()) throw JsonException("данные после значения")
        return value
    }

    /** A JSON string, or an number/boolean the way `NSNumber.stringValue` says it. */
    fun string(value: Any?): String? = when (value) {
        is String -> value
        is Boolean -> if (value) "1" else "0"
        is Double -> if (value == Math.floor(value) && !value.isInfinite() &&
            Math.abs(value) < 1e15
        ) value.toLong().toString() else value.toString()
        else -> null
    }

    /** `NSNumber.intValue`: doubles truncate toward zero, strings must be plain integers. */
    fun int(value: Any?): Int? = when (value) {
        is Boolean -> null
        is Double -> value.toInt().takeIf { !value.isInfinite() && !value.isNaN() }
        is String -> swiftInt(value)   // `Int(s)` на Swift: без пробелов, без не-ASCII цифр
        else -> null
    }

    /** Real JSON booleans only — a numeric `1` is not `true` to Swift either. */
    fun boolean(value: Any?): Boolean? = value as? Boolean

    /**
     * Compact JSON, the shape `JSONSerialization.data(withJSONObject:)` writes:
     * integers stay integers and only what JSON requires is escaped, so a
     * document re-parsed from this text reads back the same on both platforms.
     */
    fun write(value: Any?): String {
        val out = StringBuilder()
        emit(value, out)
        return out.toString()
    }

    private fun emit(value: Any?, out: StringBuilder) {
        when (value) {
            null -> out.append("null")
            is Boolean -> out.append(if (value) "true" else "false")
            is Double -> out.append(
                if (value.isNaN() || value.isInfinite()) "null"
                else if (value == Math.floor(value) && Math.abs(value) < 1e15) value.toLong().toString()
                else plainDouble(value)
            )
            is Number -> out.append(value.toString())
            is String -> quote(value, out)
            is Map<*, *> -> {
                out.append('{')
                value.entries.forEachIndexed { index, entry ->
                    if (index > 0) out.append(',')
                    quote(entry.key.toString(), out)
                    out.append(':')
                    emit(entry.value, out)
                }
                out.append('}')
            }
            is List<*> -> {
                out.append('[')
                value.forEachIndexed { index, item ->
                    if (index > 0) out.append(',')
                    emit(item, out)
                }
                out.append(']')
            }
            else -> quote(value.toString(), out)
        }
    }

    /** Shortest round-trip digits, plain rather than `1.2E8` — what Foundation writes. */
    /**
     * `JSONEncoder` with `[.prettyPrinted, .sortedKeys]` — the readable file
     * form the apps export. Foundation indents two spaces per level, puts a
     * space before every colon, and leaves an empty collection as a blank line
     * between its brackets; a bundle file has no floating point in it, so the
     * bytes are worth matching rather than only the values.
     */
    fun writePretty(value: Any?): String {
        val out = StringBuilder()
        emitPretty(value, out, 0)
        return out.toString()
    }

    private fun emitPretty(value: Any?, out: StringBuilder, depth: Int) {
        val pad = "  ".repeat(depth)
        when (value) {
            is Map<*, *> -> {
                if (value.isEmpty()) {
                    out.append("{\n\n").append(pad).append('}')
                    return
                }
                out.append("{\n")
                for ((index, entry) in value.entries.withIndex()) {
                    if (index > 0) out.append(",\n")
                    out.append(pad).append("  ")
                    quote(entry.key.toString(), out)
                    out.append(" : ")
                    emitPretty(entry.value, out, depth + 1)
                }
                out.append("\n").append(pad).append('}')
            }
            is List<*> -> {
                if (value.isEmpty()) {
                    out.append("[\n\n").append(pad).append(']')
                    return
                }
                out.append("[\n")
                for ((index, item) in value.withIndex()) {
                    if (index > 0) out.append(",\n")
                    out.append(pad).append("  ")
                    emitPretty(item, out, depth + 1)
                }
                out.append("\n").append(pad).append(']')
            }
            else -> emit(value, out)
        }
    }

    private fun plainDouble(value: Double): String =
        java.math.BigDecimal(value.toString()).stripTrailingZeros().toPlainString()

    private fun quote(text: String, out: StringBuilder) {
        out.append('"')
        for (char in text) {
            when {
                char == '"' -> out.append("\\\"")
                char == '\\' -> out.append("\\\\")
                // Foundation escapes every solidus, which is what Amnezia's
                // re-serialized `last_config` looks like — and whether it
                // contains "://" decides how the vpn:// parser reads it.
                char == '/' -> out.append("\\/")
                char == '\n' -> out.append("\\n")
                char == '\r' -> out.append("\\r")
                char == '\t' -> out.append("\\t")
                char < ' ' -> out.append("\\").append(String.format(java.util.Locale.ROOT, "u%04x", char.code))
                else -> out.append(char)
            }
        }
        out.append('"')
    }

    private class Reader(private val text: String) {
        private var index = 0

        fun atEnd() = index >= text.length

        fun skipSpace() {
            while (index < text.length && text[index].let { it == ' ' || it == '\t' || it == '\n' || it == '\r' }) {
                index += 1
            }
        }

        fun value(): Any? {
            if (atEnd()) throw JsonException("пустой ввод")
            return when (text[index]) {
                '{' -> obj()
                '[' -> array()
                '"' -> string()
                't' -> literal("true", true)
                'f' -> literal("false", false)
                'n' -> literal("null", null)
                else -> number()
            }
        }

        private fun expect(char: Char) {
            if (atEnd() || text[index] != char) throw JsonException("ожидался «$char»")
            index += 1
        }

        private fun literal(word: String, result: Any?): Any? {
            if (!text.startsWith(word, index)) throw JsonException("не литерал")
            index += word.length
            return result
        }

        private fun obj(): Map<String, Any?> {
            expect('{')
            val result = LinkedHashMap<String, Any?>()
            skipSpace()
            if (!atEnd() && text[index] == '}') {
                index += 1
                return result
            }
            while (true) {
                skipSpace()
                val key = string()
                skipSpace()
                expect(':')
                skipSpace()
                val parsed = value()
                // Foundation keeps the first of two identical keys, so a panel
                // that emits `"add":"a","add":"b"` resolves to "a" on both
                // platforms.
                if (key !in result) result[key] = parsed
                skipSpace()
                if (atEnd()) throw JsonException("незакрытый объект")
                when (text[index]) {
                    ',' -> index += 1
                    '}' -> {
                        index += 1
                        return result
                    }

                    else -> throw JsonException("ожидался «,» или «}»")
                }
            }
        }

        private fun array(): List<Any?> {
            expect('[')
            val result = ArrayList<Any?>()
            skipSpace()
            if (!atEnd() && text[index] == ']') {
                index += 1
                return result
            }
            while (true) {
                skipSpace()
                result.add(value())
                skipSpace()
                if (atEnd()) throw JsonException("незакрытый массив")
                when (text[index]) {
                    ',' -> index += 1
                    ']' -> {
                        index += 1
                        return result
                    }

                    else -> throw JsonException("ожидался «,» или «]»")
                }
            }
        }

        private fun string(): String {
            expect('"')
            val builder = StringBuilder()
            while (true) {
                if (atEnd()) throw JsonException("незакрытая строка")
                val char = text[index]
                index += 1
                when (char) {
                    '"' -> return builder.toString()
                    '\\' -> builder.append(escape())
                    else -> {
                        if (char < ' ') throw JsonException("управляющий символ в строке")
                        builder.append(char)
                    }
                }
            }
        }

        private fun escape(): Char {
            if (atEnd()) throw JsonException("обрыв escape")
            val kind = text[index]
            index += 1
            return when (kind) {
                '"' -> '"'
                '\\' -> '\\'
                '/' -> '/'
                'b' -> '\b'
                'f' -> '\u000C'
                'n' -> '\n'
                'r' -> '\r'
                't' -> '\t'
                'u' -> {
                    if (index + 4 > text.length) throw JsonException("обрыв последовательности \\u")
                    var code = 0
                    for (offset in 0..3) {
                        val digit = Character.digit(text[index + offset], 16)
                        if (digit < 0) throw JsonException("не hex в \\u")
                        code = code * 16 + digit
                    }
                    index += 4
                    code.toChar()
                }

                else -> throw JsonException("неизвестный escape «\\$kind»")
            }
        }

        private fun number(): Double {
            val start = index
            if (!atEnd() && text[index] == '-') index += 1
            var digits = 0
            while (!atEnd() && text[index] in '0'..'9') {
                index += 1; digits += 1
            }
            if (digits == 0) throw JsonException("не число")
            if (!atEnd() && text[index] == '.') {
                index += 1
                var fraction = 0
                while (!atEnd() && text[index] in '0'..'9') {
                    index += 1; fraction += 1
                }
                if (fraction == 0) throw JsonException("обрыв дроби")
            }
            if (!atEnd() && (text[index] == 'e' || text[index] == 'E')) {
                index += 1
                if (!atEnd() && (text[index] == '+' || text[index] == '-')) index += 1
                var exponent = 0
                while (!atEnd() && text[index] in '0'..'9') {
                    index += 1; exponent += 1
                }
                if (exponent == 0) throw JsonException("обрыв показателя")
            }
            return text.substring(start, index).toDoubleOrNull()
                ?: throw JsonException("не число")
        }
    }
}
