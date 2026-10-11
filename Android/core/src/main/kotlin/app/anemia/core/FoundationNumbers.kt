package app.anemia.core

/**
 * Foundation's `Double(_ string: String)` — C's `strtod`, not JSON's number
 * grammar and not tolerant of whitespace. The port needs it because
 * `String.toDoubleOrNull()` (Java's `Double.parseDouble`) disagrees in ways a
 * panel header can reach:
 *
 *   * Java skips leading and trailing whitespace, `strtod` accepts none —
 *     `upload =\u000B10` is a quota on a JVM and no quota on iOS, and a
 *     vertical tab survives `.whitespaces` trimming on both sides;
 *   * Java has no hex floats, `strtod` does (`0x10` is 16, `0x1.8p1` is 3);
 *   * Java spells the specials `NaN`/`Infinity` case-sensitively, `strtod`
 *     takes `inf`, `INF`, `Infinity`, `nan`, `nan(1)`.
 *
 * The grammar is checked here, character by character; only a text that passes
 * is handed to `parseDouble` for the arithmetic, so both sides end up with the
 * same correctly-rounded bits. `sub/numbers.tsv` pins every case against what
 * Swift's `Double(_:)` itself returns.
 */
internal object SwiftDouble {
    /** `null` wherever Foundation would return nil. */
    fun parse(text: String): Double? {
        var start = 0
        var negative = false
        if (text.isNotEmpty() && (text[0] == '-' || text[0] == '+')) {
            negative = text[0] == '-'
            start = 1
        }
        val rest = text.substring(start)
        if (rest.isEmpty()) return null

        special(rest)?.let { return if (negative) -it else it }

        val normalized = (if (rest.startsWith("0x")) hexFloat(rest) else decimalFloat(rest))
            ?: return null
        return (if (negative) "-$normalized" else normalized).toDoubleOrNull()
    }

    /** `inf`, `infinity`, `nan`, `nan(<C integer literal>)`; null otherwise. */
    private fun special(rest: String): Double? {
        val lower = rest.lowercase()
        if (lower == "inf" || lower == "infinity") return Double.POSITIVE_INFINITY
        if (lower == "nan") return Double.NaN
        if (rest.length >= 5 && lower.startsWith("nan(") && rest.endsWith(")") &&
            integerLiteral(rest.substring(4, rest.length - 1))
        ) return Double.NaN
        return null
    }

    /**
     * What Foundation accepts between `nan(` and `)`: a C integer literal —
     * empty is fine (`nan()` is nan), `0x…` is hex with a lowercase `x`
     * (`nan(0X1)` is nil), a leading `0` means octal (so `nan(0123456789)` is
     * nil because 8 and 9 are not octal digits), otherwise decimal digits.
     * Measured case by case; the value is discarded either way, so the only
     * thing at stake is whether the whole string parses at all.
     */
    private fun integerLiteral(text: String): Boolean = when {
        text.isEmpty() -> true
        text.startsWith("0x") -> text.substring(2).all {
            it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F'
        }
        text.length > 1 && text[0] == '0' -> text.all { it in '0'..'7' }
        else -> text.all { it in '0'..'9' }
    }

    /**
     * `0x1f`, `0x1.8p1`, `0x.8p1` — and `0x10` without an exponent, which the
     * JVM wants spelled `0x10p0`. The prefix is lowercase only (Foundation
     * rejects `0X10`); the exponent letter may be either case.
     */
    private fun hexFloat(rest: String): String? {
        var mantissa = rest.substring(2)
        var exponent = "p0"
        val p = mantissa.indexOfFirst { it == 'p' || it == 'P' }
        if (p >= 0) {
            exponent = "p" + mantissa.substring(p + 1)
            mantissa = mantissa.substring(0, p)
        }
        if (mantissa.isEmpty() || !digitsOk(mantissa, ::isAsciiHexDigit)) return null
        if (!isInteger(exponent.substring(1))) return null
        return "0x$mantissa$exponent"
    }

    private fun decimalFloat(rest: String): String? {
        val e = rest.indexOfFirst { it == 'e' || it == 'E' }
        val mantissa = if (e >= 0) rest.substring(0, e) else rest
        val exponent = if (e >= 0) rest.substring(e + 1) else null
        if (!digitsOk(mantissa, ::isAsciiDigit)) return null
        if (exponent != null && !isInteger(exponent)) return null
        return mantissa + (exponent?.let { "e$it" } ?: "")
    }

    /** Mantissa: digits, at most one dot, at least one digit. */
    private fun digitsOk(text: String, isDigit: (Char) -> Boolean): Boolean {
        if (text.count { it == '.' } > 1) return false
        val digits = text.replace(".", "")
        return digits.isNotEmpty() && digits.all { isDigit(it) }
    }

    /** Exponent: an integer, signed or not, at least one ASCII digit. */
    private fun isInteger(text: String): Boolean {
        val body = if (text.startsWith("+") || text.startsWith("-")) text.substring(1) else text
        return body.isNotEmpty() && body.all { it in '0'..'9' }
    }

    private fun isAsciiDigit(char: Char): Boolean = char in '0'..'9'

    private fun isAsciiHexDigit(char: Char): Boolean =
        char in '0'..'9' || char in 'a'..'f' || char in 'A'..'F'
}

/**
 * Foundation's `Int(_ string: String)` — and with it `UInt8`/`UInt16`/`UInt32`
 * through the same initializer. Unlike `String.toIntOrNull()` this grammar is
 * ASCII-only: Java's parser runs every character through `Character.digit`, so
 * «1٠» (an ASCII one followed by an Extended Arabic-Indic zero) becomes 10 on a
 * JVM while Foundation returns nil. Width follows Swift too — `Int` there is
 * 64-bit, so a caller that stores the result in a 32-bit field has to say so
 * with an explicit range check, which every real call site already does.
 */
internal object SwiftInt {
    /** `null` wherever Foundation would return nil. */
    fun parse(text: String): Long? {
        var index = 0
        var negative = false
        if (text.isNotEmpty() && (text[0] == '-' || text[0] == '+')) {
            negative = text[0] == '-'
            index = 1
        }
        val digits = text.substring(index)
        if (digits.isEmpty() || !digits.all { it in '0'..'9' }) return null
        // Ведущие нули разрешены («0010» — это 10), переполнение отдаёт nil,
        // как `Int(String)` на Swift.
        val value = digits.toLongOrNull(10) ?: return null
        return if (negative) -value else value
    }

    /** То же для `UInt32(t)`/`UInt16(t)`: отрицательное — не число. */
    fun parseUnsigned(text: String, max: Long): Long? =
        parse(text)?.takeIf { it >= 0 && it <= max }
}

/** `Int(text)` из Foundation, зауженный до 32-битного Kotlin-овского `Int`. */
internal fun swiftInt(text: String): Int? = SwiftInt.parse(text)
    ?.takeIf { it >= Int.MIN_VALUE.toLong() && it <= Int.MAX_VALUE.toLong() }
    ?.toInt()
