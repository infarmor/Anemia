using AnemiaCore;
using Xunit;

namespace AnemiaCoreTests;

/// <summary>
/// Every row below is the answer of the real iOS formatters: `ActivityText.swift`
/// compiled with swiftc on this Mac and run over these inputs (the probe is a
/// throwaway; the table is the record). Two of them exist only to pin a rounding
/// rule that no other input touches: 1050 bytes is «1,0 КБ» because Foundation
/// rounds the decimal 1.05 half to even, and 1051 is «1,1 КБ» — the pair is what
/// a naive `ToString("F1")` of the binary double gets wrong.
/// </summary>
public class FormattingTests
{

    [Theory]
    [InlineData(0.0d, "0 Кбит/с", "0К")]
    [InlineData(1.0d, "0,0 Кбит/с", "0,0К")]
    [InlineData(999.0d, "1,0 Кбит/с", "1,0К")]
    [InlineData(4200.0d, "4,2 Кбит/с", "4,2К")]
    [InlineData(48200.0d, "48 Кбит/с", "48К")]
    [InlineData(99400.0d, "99 Кбит/с", "99К")]
    [InlineData(99490.0d, "99 Кбит/с", "99К")]
    [InlineData(9950000.0d, "10 Мбит/с", "10М")]
    [InlineData(12340000.0d, "12 Мбит/с", "12М")]
    [InlineData(999499999.0d, "999 Мбит/с", "999М")]
    [InlineData(999500000.0d, "1,0 Гбит/с", "1,0Г")]
    [InlineData(1000000000.0d, "1,0 Гбит/с", "1,0Г")]
    [InlineData(5000000000000.0d, "5\u00A0000 Гбит/с", "5\u00A0000Г")]
    [InlineData(-42.0d, "0 Кбит/с", "0К")]
    public void SpeedMatchesIos(double bits, string expected, string compact)
    {
        Assert.Equal(expected, Formatting.Speed(bits));
        Assert.Equal(compact, Formatting.SpeedCompact(bits));
    }

    [Theory]
    [InlineData(0L, "0 Б")]
    [InlineData(1L, "1 Б")]
    [InlineData(999L, "999 Б")]
    [InlineData(1000L, "1,0 КБ")]
    [InlineData(1049L, "1,0 КБ")]
    [InlineData(1050L, "1,0 КБ")]
    [InlineData(1051L, "1,1 КБ")]
    [InlineData(86000000L, "86 МБ")]
    [InlineData(1200000000L, "1,2 ГБ")]
    [InlineData(999499999999L, "999 ГБ")]
    [InlineData(999500000000000L, "1\u00A0000 ТБ")]
    [InlineData(1500000000000000L, "1\u00A0500 ТБ")]
    [InlineData(-7L, "0 Б")]
    public void BytesMatchIos(long total, string expected)
        => Assert.Equal(expected, Formatting.Bytes(total));

    [Theory]
    [InlineData(0.0d, "0 с")]
    [InlineData(35.0d, "35 с")]
    [InlineData(59.7d, "59 с")]
    [InlineData(60.0d, "1 мин")]
    [InlineData(119.0d, "1 мин")]
    [InlineData(120.0d, "2 мин")]
    [InlineData(3599.0d, "59 мин")]
    [InlineData(3600.0d, "1 ч")]
    [InlineData(3661.0d, "1 ч 1 мин")]
    [InlineData(7325.0d, "2 ч 2 мин")]
    [InlineData(-20.0d, "0 с")]
    public void SessionLengthMatchesIos(double seconds, string expected)
        => Assert.Equal(expected, Formatting.SessionLength(seconds));

    /// <summary>The grouping is U+00A0 — measured, and the reason the constant
    /// exists: a panel that breaks the line inside «1 000 ТБ» is a layout bug
    /// this port would otherwise ship.</summary>
    [Fact]
    public void ThousandsUseTheNonBreakingSpace()
    {
        Assert.Equal("5\u00A0000 Гбит/с", Formatting.Speed(5_000_000_000_000));
        Assert.Contains(Formatting.Nb, Formatting.Bytes(999_500_000_000_000));
    }

    /// <summary>Numbers must not follow the machine. Android needed the same
    /// guard for a different runtime (`Locale.ROOT`): under ar-EG .NET writes
    /// 1٬000 with Arabic-Indic digits and an Arabic comma, and a Windows user on
    /// such a locale would see the traffic figure in digits the iOS app does not
    /// produce. The separators here are the ones Foundation's ru_RU uses, chosen
    /// by the port, never inherited.</summary>
    [Fact]
    public void OutputDoesNotFollowTheCurrentCulture()
    {
        var before = System.Globalization.CultureInfo.CurrentCulture;
        try
        {
            System.Globalization.CultureInfo.CurrentCulture = new System.Globalization.CultureInfo("ar-EG");
            Assert.Equal("1\u00A0000 ТБ", Formatting.Bytes(999_500_000_000_000));
            Assert.Equal("5\u00A0000 Гбит/с", Formatting.Speed(5_000_000_000_000));
            Assert.Equal("1:15", Formatting.Clock(4529));
        }
        finally { System.Globalization.CultureInfo.CurrentCulture = before; }
    }

    /// <summary>The macOS session timer: `mm:ss` until an hour, then `h:mm:ss`.
    /// Digits are ASCII whatever the machine's locale is.</summary>
    [Theory]
    [InlineData(0d, "00:00")]
    [InlineData(59d, "00:59")]
    [InlineData(60d, "01:00")]
    [InlineData(4529d, "1:15:29")]
    [InlineData(3600d, "1:00:00")]
    [InlineData(4529d + 3600, "2:15:29")]
    [InlineData(-20d, "00:00")]
    public void DurationIsTheEngineTimerShape(double seconds, string expected)
        => Assert.Equal(expected, Formatting.Duration(seconds));

    [Theory]
    [InlineData(0d, "0:00")]
    [InlineData(59d, "0:00")]
    [InlineData(60d, "0:01")]
    [InlineData(3600d, "1:00")]
    [InlineData(4529d, "1:15")]
    [InlineData(86400d, "24:00")]
    public void ClockIsMinutesAndNeverLocalizedDigits(double seconds, string expected)
        => Assert.Equal(expected, Formatting.Clock(seconds));
}
