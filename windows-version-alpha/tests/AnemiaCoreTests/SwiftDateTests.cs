using AnemiaCore;
using Xunit;

namespace AnemiaCoreTests;

/// <summary>
/// Foundation's ISO-8601 date, as the bundle files and QR payloads carry it.
///
/// Every row below is an answer the real decoder gave: each string was put into
/// a `read` case and run through `LoaderTool sync`, which prints `bundle at=…`
/// when `SyncBundle.decode` accepted it and `error notABundle` when it did not.
/// The format is not RFC 3339 and not .NET's `DateTimeOffset.TryParse` — it
/// rolls February 30 into March, takes an hour of 99, refuses a day of 32, and
/// stops reading at the end of the zone, so trailing junk is not an error while
/// a lowercase `t` or a missing zone is.
/// </summary>
public class SwiftDateTests
{
    /// <summary>The dump prints `Int64(seconds)`, so the observable part of a
    /// fraction is what it truncates to — that is what these rows pin.</summary>
    [Theory]
    [InlineData("2026-02-02T02:40:00Z", 1770000000)]
    [InlineData("2026-02-02T02:40:00.250Z", 1770000000)]
    [InlineData("2026-02-02T02:40:00.25Z", 1770000000)]
    [InlineData("2026-02-02T02:40:00.250000Z", 1770000000)]
    [InlineData("2026-02-02T05:40:00+0300", 1770000000)]
    [InlineData("2026-02-29T02:40:00Z", 1772332800)]          // February 29 rolls into March 1
    [InlineData("2026-02-30T00:00:00Z", 1772409600)]
    [InlineData("2026-02-31T00:00:00Z", 1772496000)]
    [InlineData("2028-02-29T00:00:00Z", 1835395200)]          // a real leap day
    [InlineData("2026-01-01T25:00:00Z", 1767315600)]          // an hour of 25 spills into the next day
    [InlineData("2026-01-01T24:61:00Z", 1767315660)]
    [InlineData("2026-01-01T99:00:00Z", 1767582000)]
    [InlineData("2026-01-01T00:00:61Z", 1767225661)]
    [InlineData("2026-01-01T00:00:99Z", 1767225699)]
    [InlineData("2026-01-01T00:0:00Z", 1767225600)]           // unpadded fields are fine
    [InlineData("2026-1-1T00:00:00Z", 1767225600)]
    [InlineData("2026-01-01T00:00:00z", 1767225600)]          // a lowercase zone marker is
    [InlineData("2026-01-01T00:00:00Zx", 1767225600)]         // … and so is junk after it
    [InlineData("2026-01-01T00:00:00ZZ", 1767225600)]
    [InlineData("2026-01-01T00:00:00+0000", 1767225600)]
    [InlineData("2026-01-01T00:00:00+03:00", 1767214800)]
    [InlineData("2026-01-01T00:00:00+03", 1767214800)]        // zone minutes are optional
    [InlineData("2026-01-01T00:00:00+3:00", 1767214800)]      // and one-digit parts
    [InlineData("2026-01-01T00:00:00+3", 1767214800)]
    [InlineData("2026-01-01T00:00:00+03:0", 1767214800)]
    [InlineData("2026-01-01T00:00:00+030000", 1767214800)]    // the extra pair is junk after the zone
    [InlineData("2026-01-01T00:00:00+00:60", 1767222000)]     // a zone minute of 60 rolls over
    [InlineData("2026-01-01T0:00:00Z", 1767225600)]
    [InlineData("2026-1-1T0:0:0Z", 1767225600)]
    [InlineData("2026-01-01T03:00:00-0300", 1767247200)]
    [InlineData("2026-01-01T00:00:00.5+0300", 1767214800)]
    [InlineData("2026-12-31T23:59:59Z", 1798761599)]
    public void AcceptedByFoundation(string text, long wholeSeconds)
    {
        var parsed = SwiftDate.Parse(text);
        Assert.NotNull(parsed);
        Assert.Equal(wholeSeconds, (long)System.Math.Floor(parsed!.Value));
    }

    /// <summary>Swift reads these; this port refuses them, and the difference is
    /// stated instead of hidden. Foundation runs a first-millennium year through
    /// its lenient era rules and lands on a day neither the Julian nor the
    /// proleptic-Gregorian calendar gives (measured above), and a `Date()` cannot
    /// be outside 0001…9999 in any file an Anemia writes. Refusing costs a bundle
    /// that no export produced; computing our own answer would have made the two
    /// devices disagree about the same file in silence.</summary>
    [Theory]
    [InlineData("0000-01-01T00:00:00Z")]      // Swift: −62167392000
    [InlineData("12026-01-01T00:00:00Z")]     // Swift: 317336745600
    public void YearsBeyondTheCalendarAreRefusedOnPurpose(string text)
        => Assert.Null(SwiftDate.Parse(text));

    /// <summary>A year below 1000 is read by both, two days apart: Foundation's
    /// lenient era rules put `1-01-01` at −62135769600 while the proleptic
    /// Gregorian calendar this port uses says −62135596800 (0001-01-01 is day
    /// −719162, not −719528 — that one is the *Julian* new year). Pinned so the
    /// gap is a recorded fact and not something a future change discovers.</summary>
    [Fact]
    public void FirstMillenniumIsTwoDaysOffFoundation()
    {
        Assert.Equal(-62135596800d, SwiftDate.Parse("1-01-01T00:00:00Z")!.Value);
    }

    [Theory]
    [InlineData("")]
    [InlineData("2026-02-02T02:40:00")]              // no zone
    [InlineData("2026-02-02 02:40:00Z")]             // a space is not the T
    [InlineData("2026-01-01t00:00:00Z")]             // and a lowercase t is not either
    [InlineData("2026-13-01T02:40:00Z")]             // month 13
    [InlineData("2026-00-10T00:00:00Z")]             // month 0
    [InlineData("2026-01-32T00:00:00Z")]             // day 32 — while day 30 in February rolls over
    [InlineData("2026-01-00T00:00:00Z")]             // day 0
    [InlineData("20260101T000000Z")]                 // the dashes are required
    [InlineData("2026-01-01")]                       // a date alone is not a moment
    [InlineData("2026-01-01Z")]
    [InlineData("2026-01-01T00:00Z")]                // seconds are required
    [InlineData("2026-01-01T00:00:00,500Z")]         // a comma fraction is a different format
    [InlineData("2026-01-01T00:00:00+25:00")]        // the zone hour is range-checked
    [InlineData("2026-01-01T00:00:00+24:00")]        // … at 23, not at 24
    [InlineData("2026-01-01T00:00:00 Z")]            // a space before the zone is junk before it
    [InlineData(" 2026-01-01T00:00:00Z")]            // and nothing is trimmed before the year
    [InlineData("вчера")]
    public void RefusedByFoundation(string text)
        => Assert.Null(SwiftDate.Parse(text));

    /// <summary>`JSONEncoder`'s `.iso8601` writes whole seconds with an uppercase
    /// `T` and a `Z`; a fraction the file carried does not survive the round trip,
    /// which is what the other ports do too.</summary>
    [Theory]
    [InlineData(1770000000.0, "2026-02-02T02:40:00Z")]
    [InlineData(1767225600.0, "2026-01-01T00:00:00Z")]
    [InlineData(1798761599.0, "2026-12-31T23:59:59Z")]
    [InlineData(951782400.0, "2000-02-29T00:00:00Z")]
    [InlineData(951782399.0, "2000-02-28T23:59:59Z")]
    [InlineData(1770000000.75, "2026-02-02T02:40:00Z")]
    [InlineData(-62135596800.0, "0001-01-01T00:00:00Z")]
    public void FormatsTheWayTheEncoderWrites(double seconds, string expected)
        => Assert.Equal(expected, SwiftDate.Format(seconds));

    /// <summary>Read then write, the way an imported bundle is re-exported: the
    /// stamp must come back as the same text Swift's own file form writes.</summary>
    [Theory]
    [InlineData("2026-02-02T02:40:00Z")]
    [InlineData("2026-01-01T00:00:00+03:00")]
    [InlineData("2026-02-30T00:00:00Z")]
    [InlineData("2026-02-02T02:40:00.250Z")]
    public void RoundTripsThroughItsOwnFormatting(string text)
    {
        var parsed = SwiftDate.Parse(text);
        Assert.NotNull(parsed);
        Assert.Equal(SwiftDate.Format(parsed!.Value), text switch
        {
            "2026-02-02T02:40:00.250Z" => "2026-02-02T02:40:00Z",
            "2026-02-02T02:40:00+03:00" or "2026-01-01T00:00:00+03:00" => "2025-12-31T21:00:00Z",
            "2026-02-30T00:00:00Z" => "2026-03-02T00:00:00Z",
            _ => text,
        });
    }
}
