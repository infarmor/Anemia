using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using AnemiaCore;
using Xunit;

namespace AnemiaCoreTests;

/// <summary>
/// The traffic ledger, replayed from the same scripts the Kotlin port runs: each
/// scenario is a list of readings and questions, so what is compared is the state
/// machine — same run versus new run, the capped step, the prune, the forget —
/// not one call in isolation. Output lines follow `LoaderTool ledger` exactly;
/// documents are compared after canonicalisation, because a JSON dictionary's
/// pair order is not content.
/// </summary>
public class ParityTrafficLedgerTests
{
    private const string Folder = "score";

    [Fact]
    public void LedgerScenariosMatchSwift()
    {
        var directory = Path.Combine(Parity.Fixtures, Folder, "ledger");
        var scripts = Directory.GetFiles(directory, "*.txt").OrderBy(name => name, StringComparer.Ordinal).ToList();
        Assert.NotEmpty(scripts);

        var produced = new StringBuilder();
        var commands = 0;
        var documents = 0;
        foreach (var script in scripts)
        {
            // Каждый сценарий — новый журнал, как в эмитенте: иначе «top» и
            // документ следующего сценария несут серверы предыдущего.
            var ledger = new TrafficLedger();
            produced.Append("=== ").Append(Path.GetFileNameWithoutExtension(script)).Append(Parity.LineFeed);
            foreach (var raw in Parity.Split(File.ReadAllText(script, Encoding.UTF8)))
            {
                commands++;
                var parts = raw.Split(Parity.Tab).Select(part => part.Trim(' ', (char)0x09)).ToArray();
                var verb = parts.Length > 0 ? parts[0] : "";
                switch (verb)
                {
                    case "rec":
                        ReplayRecord(ledger, parts);
                        break;
                    case "stopped":
                        ledger.Stopped();
                        break;
                    case "reset":
                        ledger.Reset();
                        break;
                    case "forget":
                        ledger.Forget(parts.Skip(1).Select( ParseUuid).Where(id => id is not null).Select(id => id!.Value));
                        break;
                    case "days":
                        {
                            if (parts.Length < 3 || SwiftInt.Parse(parts[1]) is not { } count ||
                                SwiftDouble.Parse(parts[2]) is not { } now) break;
                            var zone = parts.Length > 3 ? parts[3] : "";
                            foreach (var day in ledger.RecentDays((int)count, Epoch(now), zone))
                                produced.Append("day").Append(Parity.Tab).Append(DayDump(day)).Append(Parity.LineFeed);
                            break;
                        }
                    case "today":
                    case "month":
                        {
                            if (parts.Length < 2 || SwiftDouble.Parse(parts[1]) is not { } now) break;
                            var zone = parts.Length > 2 ? parts[2] : "";
                            var day = verb == "today" ? ledger.Today(Epoch(now), zone) : ledger.Month(Epoch(now), zone);
                            produced.Append(verb).Append(Parity.Tab).Append(DayDump(day)).Append(Parity.LineFeed);
                            break;
                        }
                    case "top":
                        foreach (var total in ledger.TopServers)
                        {
                            produced.Append("srv").Append(Parity.Tab)
                                .Append("id=").Append(TrafficLedger.Uuid(total.Id))
                                .Append(" name=").Append(total.Name)
                                .Append(" recv=").Append(total.Received.ToString(CultureInfo.InvariantCulture))
                                .Append(" sent=").Append(total.Sent.ToString(CultureInfo.InvariantCulture))
                                .Append(" total=").Append(total.Total.ToString(CultureInfo.InvariantCulture))
                                .Append(" lastUsed=").Append(Bits(Seconds(total.LastUsed)))
                                .Append(Parity.LineFeed);
                        }
                        break;
                    case "key":
                        {
                            if (parts.Length < 3 || SwiftDouble.Parse(parts[2]) is not { } now) break;
                            produced.Append("key").Append(Parity.Tab)
                                .Append(TrafficLedger.DayKey(Epoch(now), Zone(parts[1]))).Append(Parity.LineFeed);
                            break;
                        }
                    case "dayof":
                        {
                            if (parts.Length < 3) break;
                            var date = TrafficLedger.DateOfDay(parts[2], Zone(parts[1]));
                            produced.Append("dayof").Append(Parity.Tab)
                                .Append(date is { } value ? Bits(Seconds(value)) : "nil").Append(Parity.LineFeed);
                            break;
                        }
                    case "json":
                        produced.Append("json").Append(Parity.Tab).Append(Parity.Canonical(ledger.ToJson())).Append(Parity.LineFeed);
                        documents++;
                        break;
                    default:
                        produced.Append("error").Append(Parity.Tab).Append("unknown verb ").Append(verb).Append(Parity.LineFeed);
                        break;
                }
            }
        }

        // Строки `json` нормализуются с обеих сторон: эмитент печатает плоский
        // массив серверов в порядке словаря Foundation, а порядок пар — не
        // содержательная часть документа. Всё остальное сравнивается текстом.
        var golden = string.Join("\n", Parity.Split(Parity.Read(Folder, "ledger.golden.txt"))
            .Select(line => line.StartsWith("json\t", StringComparison.Ordinal)
                ? "json" + Parity.Tab + Parity.Canonical(line[(4 + 1)..])
                : line)) + "\n";
        Parity.Compare(produced.ToString(), golden, "учёт трафика", floor: 100);
        // Ровно столько строк в сценариях сегодня (387 непустых строк в
        // `score/ledger/*.txt`), и семь документов — цифры стоят и в README.
        // Расхождение значит «фикстуры изменились»: сверь с Kotlin и Swift и
        // обнови число, а не подгоняй журнал под него.
        Assert.Equal(387, commands);
        Assert.Equal(7, documents);
    }


    private static void ReplayRecord(TrafficLedger ledger, string[] parts)
    {
        // rec  run  recv  sent  id  name  now  tz
        if (parts.Length < 8) return;
        if (SwiftDouble.Parse(parts[1]) is not { } run || SwiftDouble.Parse(parts[6]) is not { } now) return;
        var id = parts[4] == "-" ? null : ParseUuid(parts[4]);
        ledger.Record(
            Epoch(run),
            SwiftInt.Parse(parts[2]) ?? 0,
            SwiftInt.Parse(parts[3]) ?? 0,
            id is { } serverId ? (serverId, parts[5]) : null,
            Epoch(now),
            parts[7]);
    }

    private static Guid? ParseUuid(string text) =>
        Guid.TryParseExact(text, "D", out var parsed) ? parsed : null;

    private static string DayDump(TrafficLedger.Day day) =>
        $"id={day.Id} recv={day.Received.ToString(CultureInfo.InvariantCulture)}" +
        $" sent={day.Sent.ToString(CultureInfo.InvariantCulture)}" +
        $" time={Bits(day.Time)} total={day.Total.ToString(CultureInfo.InvariantCulture)}";

    private static double Seconds(DateTimeOffset moment) => moment.ToUnixTimeSeconds();

    /// <summary>The emitter prints these numbers as IEEE-754 bit patterns: the
    /// ledger's seconds are doubles, and a step cap off by one ULP is exactly the
    /// kind of drift a decimal print would hide.</summary>
    private static string Bits(double value) =>
        BitConverter.DoubleToInt64Bits(value).ToString("x16", CultureInfo.InvariantCulture);

    private static DateTimeOffset Epoch(double seconds) =>
        DateTimeOffset.FromUnixTimeSeconds((long)Math.Round(seconds, MidpointRounding.AwayFromZero));

    private static TimeZoneInfo? Zone(string id)
    {
        if (string.IsNullOrEmpty(id)) return null;
        try { return TimeZoneInfo.FindSystemTimeZoneById(id); }
        catch (Exception e) when (e is TimeZoneNotFoundException or InvalidTimeZoneException) { return null; }
    }

    /// <summary>`stopped()` closes the connected stretch and nothing else: the
    /// run's counters keep running, so the next reading is still a delta. Clearing
    /// the run stamp here would add the engine's whole cumulative byte count to a
    /// day a second time.</summary>
    [Fact]
    public void StoppingEndsTheStretchNotTheRun()
    {
        var ledger = new TrafficLedger();
        var run = DateTimeOffset.FromUnixTimeSeconds(1_000_000);
        // First reading of a run: no previous stamp, so the counters are taken
        // whole. Second: only the delta counts.
        ledger.Record(run, 100, 10, null, run.AddSeconds(10));
        ledger.Record(run, 160, 16, null, run.AddSeconds(20));
        // The engine stopped. A reading 80 s later must not charge those 80 s to
        // the tunnel — but the run's counters keep running, so the bytes are
        // still a delta. Clearing the run stamp here would add the whole
        // cumulative count to the day a second time.
        ledger.Stopped();
        ledger.Record(run, 200, 20, null, run.AddSeconds(100));

        var day = ledger.Today(run.AddSeconds(100), "UTC");
        // 100 + 60 + 40, and 10 + 6 + 4: the last stretch counts as a delta, not
        // as the engine's whole cumulative counter.
        Assert.Equal(200, day.Received);
        Assert.Equal(20, day.Sent);
        Assert.Equal(10, day.Time);
    }

    [Fact]
    public void TotalsSaturateInsteadOfWrapping()
    {
        // A restored document carries whatever the previous run wrote, and
        // `received + sent` at long.MaxValue wrapped negative — the stats sheet
        // then printed a debt. Both sides clamp; Kotlin wraps and prints 0 Б, so
        // the clamp is the difference between a readable day and a nonsense one.
        var day = new TrafficLedger.Day("2026-09-27", long.MaxValue, 5);
        Assert.Equal(long.MaxValue, day.Total);
        var server = new TrafficLedger.ServerTotal
        {
            Received = long.MinValue,
            Sent = -5,
        };
        Assert.Equal(long.MinValue, server.Total);
    }

    /// <summary>The other half of the contract: what Swift wrote, this port has
    /// to read and rewrite without loss. The reference-date shift (seconds from
    /// 2001-01-01, not from the unix epoch) is visible only here — read those
    /// stamps as unix and every server looks 31 years older than it is, which
    /// the recency prune then keeps. Foundation writes a UUID dictionary as a
    /// flat «key, value» array with UPPER-CASE keys, so a pair-step that parses
    /// only lower case silently empties the whole board.</summary>
    [Fact]
    public void SwiftDocumentsReadBackWithoutLoss()
    {
        var documents = 0;
        foreach (var line in Parity.Split(Parity.Read(Folder, "ledger.golden.txt")))
        {
            if (!line.StartsWith("json" + Parity.Tab, StringComparison.Ordinal)) continue;
            var swift = line[("json" + Parity.Tab).Length..];
            var ledger = TrafficLedger.FromJson(swift);
            Assert.NotNull(ledger);
            Assert.Equal(Parity.Canonical(swift), Parity.Canonical(ledger!.ToJson()));
            documents++;
        }
        // 7 — how many `json` lines the emitter actually prints today
        // (`grep -c '^json\t' score/ledger.golden.txt`); an empty sweep of the
        // fixtures would otherwise read as "nothing lost".
        Assert.Equal(7, documents);
    }

    /// <summary>A ledger read back mid-run keeps the run's baseline: the next
    /// reading is a delta, not the engine's whole cumulative counter. Without
    /// this, every app restart that happens while the tunnel is up bills the
    /// engine's bytes-so-far to today a second time.</summary>
    [Fact]
    public void ARestoredLedgerContinuesTheRunItWasSavedIn()
    {
        var ledger = new TrafficLedger();
        var run = DateTimeOffset.FromUnixTimeSeconds(1_760_000_000);
        ledger.Record(run, 500, 50, null, run.AddSeconds(10), "UTC");
        var restored = TrafficLedger.FromJson(ledger.ToJson());
        Assert.NotNull(restored);

        // Same engine run, 60 more bytes down and 6 up.
        restored!.Record(run, 560, 56, null, run.AddSeconds(20), "UTC");
        var day = restored.Today(run.AddSeconds(20), "UTC");
        Assert.Equal(560, day.Received);
        Assert.Equal(56, day.Sent);
        // The gap across the restart is not charged to the tunnel: the restored
        // `lastReading` is what makes the next step a step.
        Assert.Equal(10, day.Time);

        // A different run stamp means a different engine: its counters start
        // from zero, so they are added whole rather than subtracted against the
        // saved baseline — which for a smaller new counter would clamp to nothing
        // and lose the bytes the new engine already carried.
        restored.Record(run.AddSeconds(1000), 7, 1, null, run.AddSeconds(1010), "UTC");
        var afterNewRun = restored.Today(run.AddSeconds(1010), "UTC");
        Assert.Equal(567, afterNewRun.Received);
        Assert.Equal(57, afterNewRun.Sent);
        // The 990 s the app was not counting stay outside the tunnel time.
        Assert.Equal(20, afterNewRun.Time);
    }

    /// <summary>Everything the app might find in `traffic.json` that is not a
    /// ledger: absent, half-written, wrongly typed, or holding a stamp
    /// `DateTimeOffset` cannot represent. None of it may throw — this runs while
    /// the app starts, and a crash here is an app that will not open, not a
    /// missing day of statistics.</summary>
    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("not json at all")]
    [InlineData("[]")]
    [InlineData("null")]
    [InlineData("{\"days\":")]
    [InlineData("{\"days\":[],\"servers\":{}}")]
    public void AnUnreadableDocumentIsAnEmptyLedger(string text)
    {
        var ledger = TrafficLedger.FromJson(text);
        // A document that is not an object at all is "no ledger" (null), which
        // callers turn into a fresh one; anything that parses as an object is
        // decoded field by field.
        if (ledger is null) return;
        Assert.Empty(ledger.Days);
        Assert.Empty(ledger.Servers);
    }

    [Fact]
    public void WronglyTypedEntriesDecodeAsZeroNotAsFailure()
    {
        // A day whose counters are strings, a server pair whose value is a
        // number, a `lastUsed` that is not a number: the rest of the board must
        // survive. Dropping the whole document here would throw away a user's
        // history because of one bad row.
        var ledger = TrafficLedger.FromJson(
            "{\"days\":{\"2026-09-27\":{\"id\":\"2026-09-27\",\"received\":\"many\",\"sent\":3,\"time\":\"soon\"}}," +
            "\"servers\":[\"11111111-1111-1111-1111-111111111111\",7," +
            "\"22222222-2222-2222-2222-222222222222\",{\"id\":\"22222222-2222-2222-2222-222222222222\"," +
            "\"name\":\"ночь\",\"received\":9,\"sent\":9,\"lastUsed\":\"yesterday\"}]," +
            "\"lastReading\":\"soon\",\"lastRun\":{\"startedAt\":\"soon\"}}");
        Assert.NotNull(ledger);
        Assert.Equal(0, ledger!.Days["2026-09-27"].Received);
        Assert.Equal(0, ledger.Days["2026-09-27"].Time);
        Assert.Equal(3, ledger.Days["2026-09-27"].Sent);
        // The malformed pair is skipped, the good one is kept.
        Assert.Single(ledger.Servers);
        Assert.Equal("ночь", ledger.Servers.Values.Single().Name);
        // An unparseable stamp keeps the sentinel role, not a guessed year.
        Assert.Equal(TrafficLedger.DistantPast, ledger.Servers.Values.Single().LastUsed);
        // The run and reading stamps that did not parse are absent, not faked:
        // the next reading then starts a fresh baseline instead of deltaing
        // against a number that never existed.
        Assert.DoesNotContain("\"lastRun\"", ledger.ToJson());
        Assert.DoesNotContain("lastReading", ledger.ToJson());
    }

    [Fact]
    public void AStampOutsideDateTimeOffsetClampsInsteadOfThrowing()
    {
        // Foundation's `Date.distantPast` is a second count this type cannot
        // hold. The clamp keeps the ordering the sentinel exists for (oldest),
        // and the app still starts.
        var ledger = TrafficLedger.FromJson(
            "{\"days\":{},\"servers\":[\"33333333-3333-3333-3333-333333333333\"," +
            "{\"id\":\"33333333-3333-3333-3333-333333333333\",\"name\":\"ancient\",\"received\":1,\"sent\":1," +
            "\"lastUsed\":-64116672000}],\"lastReading\":-64116672000}");
        Assert.NotNull(ledger);
        Assert.Equal(DateTimeOffset.MinValue, ledger!.Servers.Values.Single().LastUsed);
        Assert.Single(ledger.TopServers);
        // Clamping is bounded, not a wrap: a future stamp lands on the newest
        // instant the type has, and still writes a number the other ports can
        // read back — not the crash or the `null` an out-of-range value would
        // have produced.
        var far = TrafficLedger.FromJson("{\"days\":{},\"servers\":[],\"lastReading\":1e30}");
        Assert.NotNull(far);
        var written = JsonNode.Parse(far!.ToJson())!;
        Assert.Equal(DateTimeOffset.MaxValue.ToUnixTimeSeconds() - TrafficLedger.ReferenceEpoch,
                     written["lastReading"]!.GetValue<double>());
    }
}
