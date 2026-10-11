using System.Globalization;

namespace AnemiaCore;

/// <summary>
/// Speeds, byte totals and session lengths the way the app and the Live Activity
/// show them — port of `iOS/Activity/ActivityText.swift`.
///
/// The rules that matter, each one visible in the table of measured answers in
/// `FormattingTests`:
///   * the ladder steps at <b>999.5</b>, not at 1024 and not at 1000, so a link
///     reporting 999,6 Мбит/с reads «1,0 Гбит/с» rather than «1000 Мбит/с»;
///   * one decimal under 9.95 and none above — «4,2» and «48», never «48,0»;
///   * the decimal separator is a comma, the thousands separator is a
///     <b>non-breaking</b> space (U+00A0, measured) and the space before a unit
///     is an ordinary one — a UI that copies the wrong one wraps «1 000 ТБ»
///     across two lines on a narrow panel;
///   * rounding is **half to even** on the decimal form of the value: `1050` bytes
///     is «1,0 КБ» (1.05 → the even neighbour), where .NET's own
///     `ToString("F1")`-style away-from-zero rounding says «1,1 КБ». The
///     shortest-decimal step itself is not load-bearing in .NET 8 — the
///     double→decimal conversion already does it, which a mutation run showed —
///     so what the table really pins is the tie-breaking rule.
/// </summary>
public static class Formatting
{
    public const string Nb = " ";                       // Foundation's ru_RU grouping
    private static readonly string[] SpeedUnits = { "Кбит/с", "Мбит/с", "Гбит/с" };
    private static readonly string[] CompactUnits = { "К", "М", "Г" };
    private static readonly string[] BytesUnits = { "Б", "КБ", "МБ", "ГБ", "ТБ" };

    /// <summary>"48,2 Мбит/с" for 48.2 Мбит.</summary>
    public static string Speed(double bitsPerSecond)
    {
        var (value, unit) = Scale(bitsPerSecond, SpeedUnits.Length);
        return Number(value, OneDecimal: value > 0 && value < 9.95) + " " + SpeedUnits[unit];
    }

    /// <summary>"48М" — the Dynamic Island's narrow corner.</summary>
    public static string SpeedCompact(double bitsPerSecond)
    {
        var (value, unit) = Scale(bitsPerSecond, SpeedUnits.Length);
        return Number(value, OneDecimal: value > 0 && value < 9.95) + CompactUnits[unit];
    }

    /// <summary>The value and the unit apart, because the island paints them at
    /// two sizes.</summary>
    public static (string Value, string Unit) SpeedParts(double bitsPerSecond)
    {
        var (value, unit) = Scale(bitsPerSecond, SpeedUnits.Length);
        return (Number(value, OneDecimal: value > 0 && value < 9.95), SpeedUnits[unit]);
    }

    /// <summary>"1,2 ГБ", "86 МБ". Byte counts, so the ladder starts at the byte
    /// and a whole byte is never "0,9 Б".</summary>
    public static string Bytes(long total)
    {
        var value = Math.Max(0, (double)total);
        var unit = 0;
        while (value >= 999.5 && unit < BytesUnits.Length - 1)
        {
            value /= 1000;
            unit++;
        }
        return Number(value, OneDecimal: unit > 0 && value < 9.95) + " " + BytesUnits[unit];
    }

    /// <summary>"1 ч 12 мин", "4 мин", "35 с".</summary>
    public static string SessionLength(double seconds)
    {
        var total = Math.Max(0, (long)seconds);
        if (total < 60) return total + " с";
        var hours = total / 3600;
        var minutes = total % 3600 / 60;
        if (hours == 0) return minutes + " мин";
        return minutes == 0 ? hours + " ч" : $"{hours} ч {minutes} мин";
    }

    /// <summary>"1:12" — the island's corner clock; digits are always ASCII.</summary>
    public static string Clock(double seconds)
    {
        var minutes = Math.Max(0, (long)seconds) / 60;
        return FormattableString.Invariant($"{minutes / 60}:{minutes % 60:D2}");
    }

    /// <summary>"1:12:34" once an hour has passed, "12:34" before that — the
    /// macOS session timer.</summary>
    public static string Duration(double seconds)
    {
        var total = Math.Max(0, (long)seconds);
        var (h, m, s) = (total / 3600, total % 3600 / 60, total % 60);
        return h > 0 ? $"{h}:{m:D2}:{s:D2}" : $"{m:D2}:{s:D2}";
    }

    private static (double Value, int Unit) Scale(double bitsPerSecond, int unitCount)
    {
        var value = Math.Max(0, bitsPerSecond) / 1000;
        var unit = 0;
        while (value >= 999.5 && unit < unitCount - 1)
        {
            value /= 1000;
            unit++;
        }
        return (value, unit);
    }

    /// <summary>Foundation's `.number.precision(.fractionLength(n))` in ru_RU,
    /// including where it differs from a plain `ToString("F")`: round the
    /// shortest decimal form of the double, half to even, then group.</summary>
    internal static string Number(double value, bool OneDecimal)
    {
        var digits = OneDecimal ? 1 : 0;
        var shortest = value.ToString("R", CultureInfo.InvariantCulture);
        if (!decimal.TryParse(shortest, NumberStyles.Float, CultureInfo.InvariantCulture, out var exact))
            exact = (decimal)value;
        exact = Math.Round(exact, digits, MidpointRounding.ToEven);

        var format = (NumberFormatInfo)CultureInfo.InvariantCulture.NumberFormat.Clone();
        format.NumberDecimalSeparator = ",";
        format.NumberGroupSeparator = Nb;
        format.NumberGroupSizes = new[] { 3 };
        // "N", not "F": the fixed-point format never inserts group separators,
        // and Foundation's ru_RU grouping is exactly what the top of each ladder
        // needs («1 000 ТБ», «5 000 Гбит/с»).
        return exact.ToString("N" + digits, format);
    }
}
