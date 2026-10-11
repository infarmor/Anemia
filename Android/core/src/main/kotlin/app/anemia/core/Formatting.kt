package app.anemia.core

import java.text.DecimalFormat
import java.text.DecimalFormatSymbols
import java.util.Locale

/**
 * Speeds, byte totals and session lengths the way the app and the Live
 * Activity show them — port of `iOS/Activity/ActivityText.swift`.
 *
 * The rules that matter and are easy to lose in a port:
 *   * units step at 999.5, not at 1024 and not at 1000: a link reporting
 *     999,6 Мбит/с must read "1Г", never "999,6М" rounded to "1000М";
 *   * one decimal below 9.95, none above — "4,2" and "48", never "48,0";
 *   * the separator is a comma (Russian UI), and there is no thousands
 *     grouping, because the ladder keeps every value below 1000.
 */
object Formatting {
    private val units = listOf("Кбит/с", "Мбит/с", "Гбит/с")
    private val compactUnits = listOf("К", "М", "Г")
    private val bytesUnits = listOf("Б", "КБ", "МБ", "ГБ", "ТБ")

    private fun format(value: Double, decimals: Int): String {
        // Разделители — как у Foundation `.number` в ru_RU: запятая в дроби и
        // NBSP в разрядах. Группировку выключать нельзя: на верхней ступени
        // лестницы («1 000 ТБ», «1 000 Гбит/с») число до неё доходит, а Swift
        // печатает его с неразрывным пробелом.
        val symbols = DecimalFormatSymbols(Locale("ru")).apply {
            decimalSeparator = ','
            groupingSeparator = '\u00A0'
        }
        val pattern = if (decimals > 0) "0." + "0".repeat(decimals) else "0"
        return DecimalFormat(pattern, symbols).apply {
            isGroupingUsed = true
            groupingSize = 3
        }.format(value)
    }

    /** bits per second → the value and its unit index. */
    private fun scaled(bitsPerSecond: Double, table: List<String>): Pair<Double, Int> {
        var value = maxOf(0.0, bitsPerSecond) / 1000
        var unit = 0
        while (value >= 999.5 && unit < table.size - 1) {
            value /= 1000
            unit += 1
        }
        return value to unit
    }

    private fun number(value: Double): String =
        format(value, if (value > 0 && value < 9.95) 1 else 0)

    /** ("48,2", "Мбит/с") */
    fun speedParts(bitsPerSecond: Double): Pair<String, String> {
        val (value, unit) = scaled(bitsPerSecond, units)
        return number(value) to units[unit]
    }

    /** "48,2 Мбит/с" */
    fun speed(bitsPerSecond: Double): String {
        val (value, unit) = speedParts(bitsPerSecond)
        return "$value $unit"
    }

    /** "48М" — for the Dynamic Island's narrow corner. */
    fun speedCompact(bitsPerSecond: Double): String {
        val (value, unit) = scaled(bitsPerSecond, units)
        return number(value) + compactUnits[unit]
    }

    /** "1,2 ГБ", "86 МБ". Byte counts, so the ladder starts at the byte. */
    fun bytes(total: Long): String {
        var value = maxOf(0L, total).toDouble()
        var unit = 0
        while (value >= 999.5 && unit < bytesUnits.size - 1) {
            value /= 1000
            unit += 1
        }
        val decimals = if (unit > 0 && value < 9.95) 1 else 0
        return format(value, decimals) + " " + bytesUnits[unit]
    }

    /** "1 ч 12 мин", "4 мин", "35 с". */
    fun sessionLength(seconds: Double): String {
        val total = maxOf(0, seconds.toInt())
        if (total < 60) return "$total с"
        val hours = total / 3600
        val minutes = total % 3600 / 60
        if (hours == 0) return "$minutes мин"
        return if (minutes == 0) "$hours ч" else "$hours ч $minutes мин"
    }

    /** "1:12" — hours and minutes, the shape the island's corner can hold. */
    fun clock(seconds: Double): String {
        val minutes = maxOf(0, seconds.toInt()) / 60
        // Locale.ROOT: `"%d:%02d".format` follows the JVM's default locale, and
        // on an Arabic one that is «١:١٢» — Foundation's `String(format:)` and
        // Swift's `\(int)` never substitute digits, so the island would show a
        // different shape than iOS for the same session.
        return String.format(java.util.Locale.ROOT, "%d:%02d", minutes / 60, minutes % 60)
    }
}
