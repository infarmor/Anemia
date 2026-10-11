using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AnemiaCore;

/// <summary>
/// How much went through the VPN, per day and per server, from a running
/// engine's cumulative counters. Port of
/// <c>Sources/LoaderCore/TrafficLedger.swift</c>.
///
/// The counters restart with every engine run, so a reading is compared with the
/// previous reading <em>of the same run</em> — which is why the run's start stamp
/// is part of the state and why the Android port snapping it once per run is not
/// a detail: recomputing `now − uptime` per tick invents a new run every time and
/// records cumulative counters as deltas.
/// </summary>
public sealed class TrafficLedger
{
    public sealed class Day
    {
        /// <summary>"2026-09-17", a local calendar day.</summary>
        public string Id { get; set; } = "";
        public long Received { get; set; }
        public long Sent { get; set; }

        /// <summary>Seconds connected.</summary>
        public double Time { get; set; }

        public long Total => Sat(Received, Sent);

        public Day() { }

        public Day(string id, long received = 0, long sent = 0, double time = 0)
        {
            Id = id;
            Received = received;
            Sent = sent;
            Time = time;
        }
    }

    public sealed class ServerTotal
    {
        public Guid Id { get; set; }
        public string Name { get; set; } = "";
        public long Received { get; set; }
        public long Sent { get; set; }
        public DateTimeOffset LastUsed { get; set; } = DistantPast;

        public long Total => Sat(Received, Sent);
    }

    /// <summary>"Never used". Foundation's `Date.distantPast` is a second count
    /// that DateTimeOffset cannot hold (it is before year 1 in the unix frame),
    /// so this is the earliest stamp the type allows: the same sentinel role, and
    /// the golden shows any case where the exact number is ever printed.</summary>
    public static readonly DateTimeOffset DistantPast = DateTimeOffset.MinValue;

    /// <summary>Days kept; older ones go.</summary>
    public const int KeepDays = 120;

    /// <summary>How many server totals to keep: the list is a "top" board, and
    /// entries for deleted servers are worth nothing but disk.</summary>
    public const int KeepServers = 200;

    /// <summary>A gap between readings longer than this means nobody was
    /// counting, so the connected time does not include it.</summary>
    public const double MaxStep = 10;

    /// <summary>Foundation's `Date` reference date, which is what the document
    /// stores server timestamps against.</summary>
    public const double ReferenceEpoch = 978307200;

    private readonly Dictionary<string, Day> _days = new(StringComparer.Ordinal);
    private readonly Dictionary<Guid, ServerTotal> _servers = new();
    private (DateTimeOffset StartedAt, long Received, long Sent)? _lastRun;
    private DateTimeOffset? _lastReading;

    public IReadOnlyDictionary<string, Day> Days => _days;

    public IReadOnlyDictionary<Guid, ServerTotal> Servers => _servers;

    /// <summary>Saturating add: a restored document carries whatever the
    /// previous run wrote, and `received + sent` near `long.MaxValue` trapped the
    /// stats sheet. A clamped ledger at least keeps the day the user can read.</summary>
    internal static long Sat(long a, long b)
    {
        var sum = a + b;
        if (((a ^ sum) & (b ^ sum)) < 0) return a < 0 ? long.MinValue : long.MaxValue;
        return sum;
    }

    /// <summary>One reading of a run's counters (bytes since
    /// <paramref name="runStartedAt"/>).</summary>
    public void Record(DateTimeOffset runStartedAt, long received, long sent,
                       (Guid Id, string Name)? server, DateTimeOffset now, string timeZoneId = "")
    {
        var zone = Zone(timeZoneId);
        long newReceived = received, newSent = sent;
        if (_lastRun is { } last && last.StartedAt == runStartedAt)
        {
            newReceived = Math.Max(received - last.Received, 0);
            newSent = Math.Max(sent - last.Sent, 0);
        }
        _lastRun = (runStartedAt, received, sent);
        var step = _lastReading is { } previous
            ? Math.Min(Math.Max((now - previous).TotalSeconds, 0), MaxStep)
            : 0.0;
        _lastReading = now;

        var key = DayKey(now, zone);
        var day = _days.TryGetValue(key, out var existing) ? existing : new Day(key);
        day.Received += newReceived;
        day.Sent += newSent;
        day.Time += step;
        _days[key] = day;

        if (server is { } which && newReceived + newSent > 0)
        {
            if (!_servers.TryGetValue(which.Id, out var total))
                total = new ServerTotal { Id = which.Id };
            total.Name = which.Name;
            total.Received += newReceived;
            total.Sent += newSent;
            total.LastUsed = now;
            _servers[which.Id] = total;
        }
        Prune();
    }

    /// <summary>The engine stopped: the next reading starts a new connected
    /// stretch, so the time the tunnel was down is not charged to it.</summary>
    public void Stopped() => _lastReading = null;

    public void Reset()
    {
        _days.Clear();
        _servers.Clear();
        _lastRun = null;
        _lastReading = null;
    }

    /// <summary>Drops the per-server totals of servers that no longer exist —
    /// a re-imported subscription regenerates ids, and without this the "top"
    /// list keeps deleted exits forever.</summary>
    public void Forget(IEnumerable<Guid> ids)
    {
        foreach (var id in ids) _servers.Remove(id);
    }

    private void Prune()
    {
        if (_days.Count > KeepDays)
        {
            var keep = _days.Keys.Ordering().TakeLast(KeepDays).ToHashSet(StringComparer.Ordinal);
            foreach (var key in _days.Keys.Where(key => !keep.Contains(key)).ToList())
                _days.Remove(key);
        }
        if (_servers.Count > KeepServers)
        {
            var keep = _servers.Values
                .OrderBy(total => total, RecencyDescending)
                .Take(KeepServers)
                .Select(total => total.Id)
                .ToHashSet();
            foreach (var id in _servers.Keys.Where(id => !keep.Contains(id)).ToList())
                _servers.Remove(id);
        }
    }

    /// <summary>The last <paramref name="count"/> days, oldest first, empty days
    /// filled in.</summary>
    public List<Day> RecentDays(int count, DateTimeOffset now, string timeZoneId = "")
    {
        var zone = Zone(timeZoneId);
        var today = StartOfDay(now, zone);
        var result = new List<Day>(count);
        for (var offset = count - 1; offset >= 0; offset--)
        {
            var date = today.AddDays(-offset);
            var key = DayKey(date, zone);
            result.Add(_days.TryGetValue(key, out var day) ? day : new Day(key));
        }
        return result;
    }

    public Day Today(DateTimeOffset now, string timeZoneId = "")
    {
        var zone = Zone(timeZoneId);
        var key = DayKey(now, zone);
        return _days.TryGetValue(key, out var day) ? day : new Day(key);
    }

    /// <summary>The calendar month of <paramref name="now"/>, summed.</summary>
    public Day Month(DateTimeOffset now, string timeZoneId = "")
    {
        var zone = Zone(timeZoneId);
        var prefix = DayKey(now, zone)[..7];
        var sum = new Day(prefix);
        foreach (var day in _days.Values.Where(day => day.Id.StartsWith(prefix, StringComparison.Ordinal)))
        {
            sum.Received += day.Received;
            sum.Sent += day.Sent;
            sum.Time += day.Time;
        }
        return sum;
    }

    /// <summary>Biggest total first; ties go to the name, because a dictionary's
    /// order is arbitrary per launch and a board whose entries share a total used
    /// to shuffle every time the app opened.</summary>
    public List<ServerTotal> TopServers =>
        _servers.Values
            .OrderByDescending(total => total.Total)
            .ThenBy(total => total.Name, StringComparer.Ordinal)
            .ToList();

    /// <summary>Most recently used first, with the id as the tie-break.</summary>
    internal static readonly IComparer<ServerTotal> RecencyDescending =
        Comparer<ServerTotal>.Create(NewestFirst);

    /// <summary>Ties in the recency order need a tie-break too, for the same
    /// reason.</summary>
    internal static int NewestFirst(ServerTotal a, ServerTotal b)
    {
        if (a.LastUsed == b.LastUsed)
            return string.CompareOrdinal(Uuid(a.Id), Uuid(b.Id));
        return a.LastUsed > b.LastUsed ? -1 : 1;
    }

    // MARK: - Reading a document back

    /// <summary>Read what a previous run wrote. Anything unreadable is "empty
    /// ledger", never a crash: the counters restart on the next reading anyway,
    /// and losing a day of history beats losing the app's start. Dates in the
    /// document are seconds since the 2001 reference date, because that is what
    /// `JSONEncoder` writes for a `Date` — reading them as unix seconds would
    /// date every server to 1970 and the "top" prune would drop the live ones
    /// first.</summary>
    public static TrafficLedger? FromJson(string json)
    {
        JsonNode? root;
        try { root = JsonNode.Parse(json); }
        catch (JsonException) { return null; }
        if (root is not JsonObject obj) return null;

        var ledger = new TrafficLedger();
        if (obj["days"] is JsonObject days)
        {
            foreach (var (key, value) in days)
            {
                if (value is not JsonObject day) continue;
                ledger._days[key] = new Day(key, Integer(day["received"]), Integer(day["sent"]),
                                            Real(day["time"]) ?? 0);
            }
        }
        if (obj["servers"] is JsonArray servers)
        {
            // Foundation writes a dictionary with non-string keys as a flat
            // «key, value» array. Step by pairs, and skip a malformed one rather
            // than dropping the whole board.
            for (var i = 0; i + 1 < servers.Count; i += 2)
            {
                if (servers[i] is not JsonValue keyNode ||
                    !keyNode.TryGetValue<string>(out var text) ||
                    !Guid.TryParseExact(text, "D", out var id) ||
                    servers[i + 1] is not JsonObject value) continue;
                var total = new ServerTotal
                {
                    Id = id,
                    Name = value["name"] is JsonValue name && name.TryGetValue<string>(out var nameText)
                        ? nameText : "",
                    Received = Integer(value["received"]),
                    Sent = Integer(value["sent"]),
                };
                if (Real(value["lastUsed"]) is { } used) total.LastUsed = FromReferenceSeconds(used);
                ledger._servers[id] = total;
            }
        }
        if (Real(obj["lastReading"]) is { } reading) ledger._lastReading = FromReferenceSeconds(reading);
        if (obj["lastRun"] is JsonObject run && Real(run["startedAt"]) is { } stamp)
            ledger._lastRun = (FromReferenceSeconds(stamp), Integer(run["received"]), Integer(run["sent"]));
        return ledger;
    }

    private static long Integer(JsonNode? node) => node switch
    {
        JsonValue value when value.TryGetValue<long>(out var whole) => whole,
        JsonValue value when value.TryGetValue<double>(out var real) => (long)real,
        _ => 0,
    };

    private static double? Real(JsonNode? node) => node switch
    {
        JsonValue value when value.TryGetValue<double>(out var real) => real,
        JsonValue value when value.TryGetValue<long>(out var whole) => whole,
        _ => null,
    };

    /// <summary>A moment as the document stores it: seconds since 2001.</summary>
    public double ReferenceSeconds(DateTimeOffset moment) => moment.ToUnixTimeSeconds() - ReferenceEpoch;

    /// <summary>Reference seconds back to a moment. Foundation's `Date` spans
    /// ~±2.6e18 seconds; <c>DateTimeOffset</c> stops at year 10000, so a stamp
    /// outside that range is clamped to the nearest instant the type allows
    /// rather than thrown. This runs while the app loads its ledger from disk:
    /// an out-of-range day in a hand-edited or half-written file would
    /// otherwise take the launch down with it — and the clamped ends keep the
    /// role the sentinels have here (oldest/newest), which is all the prune and
    /// the "top" board read them for.</summary>
    private static DateTimeOffset FromReferenceSeconds(double seconds)
    {
        if (!double.IsFinite(seconds)) return DistantPast;
        var unix = seconds + ReferenceEpoch;
        if (unix < MinReferenceableSeconds) return DateTimeOffset.MinValue;
        if (unix > MaxReferenceableSeconds) return DateTimeOffset.MaxValue;
        return DateTimeOffset.UnixEpoch.AddSeconds(unix);
    }

    /// <summary>The unix-second bounds <c>DateTimeOffset</c> can hold.</summary>
    private static readonly double MinReferenceableSeconds = DateTimeOffset.MinValue.ToUnixTimeSeconds();
    private static readonly double MaxReferenceableSeconds = DateTimeOffset.MaxValue.ToUnixTimeSeconds();

    /// <summary>Foundation prints a UUID in upper case, and the ledger document
    /// carries that spelling.</summary>
    public static string Uuid(Guid id) => id.ToString("D").ToUpperInvariant();

    // MARK: - Days

    public static string DayKey(DateTimeOffset moment, TimeZoneInfo? zone = null)
    {
        var local = TimeZoneInfo.ConvertTime(moment, Zone(zone));
        return local.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
    }

    /// <summary>The instant a day key names in that zone — midnight, which is not
    /// the same UTC moment in a zone with a DST change.</summary>
    public static DateTimeOffset? DateOfDay(string key, TimeZoneInfo? zone = null)
    {
        if (!DateTime.TryParseExact(key, "yyyy-MM-dd", CultureInfo.InvariantCulture,
                DateTimeStyles.None, out var parsed))
            return null;
        return StartOfLocalDay(parsed, zone);
    }

    /// <summary>Midnight of a local date in a named zone, as UTC. A zone with a
    /// shift at midnight has no such instant, and the day then has no start to
    /// charge time to — null, not a guessed one.</summary>
    private static DateTimeOffset? StartOfLocalDay(DateTime local, TimeZoneInfo? zone)
    {
        var target = zone ?? TimeZoneInfo.Local;
        var midnight = DateTime.SpecifyKind(
            new DateTime(local.Year, local.Month, local.Day), DateTimeKind.Unspecified);
        if (target is null)
            return new DateTimeOffset(midnight, TimeZoneInfo.Local.GetUtcOffset(midnight));
        try
        {
            return new DateTimeOffset(TimeZoneInfo.ConvertTimeToUtc(midnight, target), TimeSpan.Zero);
        }
        catch (Exception e) when (e is ArgumentException or InvalidTimeZoneException)
        {
            return null;
        }
    }

    private static DateTimeOffset StartOfDay(DateTimeOffset moment, TimeZoneInfo? zone)
    {
        var local = TimeZoneInfo.ConvertTime(moment, Zone(zone));
        return StartOfLocalDay(local.DateTime, zone) ?? new DateTimeOffset(local.Date, local.Offset);
    }

    /// <summary>An empty or unknown zone means the machine's own, like
    /// <c>TimeZone.current</c>.</summary>
    private static TimeZoneInfo? Zone(string? timeZoneId)
    {
        if (string.IsNullOrEmpty(timeZoneId)) return null;
        try { return TimeZoneInfo.FindSystemTimeZoneById(timeZoneId); }
        catch (Exception e) when (e is TimeZoneNotFoundException or InvalidTimeZoneException) { return null; }
    }

    /// <summary>An unresolved zone means the machine's own — the equivalent of
    /// `TimeZone.current`. Returning null here would throw inside
    /// `ConvertTime` on every call that passes no zone, which is the app's own
    /// path, not the fixtures'.</summary>
    private static TimeZoneInfo Zone(TimeZoneInfo? zone) => zone ?? TimeZoneInfo.Local;

    // MARK: - Document

    /// <summary>The document Swift's <c>JSONEncoder</c> writes: days by key,
    /// servers as a flat «key, value» array, dates as seconds since the 2001
    /// reference date, and an absent optional as no key at all.</summary>
    public string ToJson()
    {
        var root = new JsonObject();
        var days = new JsonObject();
        foreach (var (key, day) in _days.Ordering().ToList())
        {
            days[key] = new JsonObject
            {
                ["id"] = day.Id,
                ["received"] = day.Received,
                ["sent"] = day.Sent,
                ["time"] = day.Time,
            };
        }
        root["days"] = days;
        var servers = new JsonArray();
        foreach (var (id, total) in _servers.OrderBy(pair => Uuid(pair.Key), StringComparer.Ordinal))
        {
            var key = Uuid(id);
            servers.Add(key);
            servers.Add(new JsonObject
            {
                ["id"] = key,
                ["name"] = total.Name,
                ["received"] = total.Received,
                ["sent"] = total.Sent,
                ["lastUsed"] = total.LastUsed.ToUnixTimeSeconds() - ReferenceEpoch,
            });
        }
        root["servers"] = servers;
        if (_lastReading is { } reading) root["lastReading"] = reading.ToUnixTimeSeconds() - ReferenceEpoch;
        if (_lastRun is { } run)
        {
            root["lastRun"] = new JsonObject
            {
                ["startedAt"] = run.StartedAt.ToUnixTimeSeconds() - ReferenceEpoch,
                ["received"] = run.Received,
                ["sent"] = run.Sent,
            };
        }
        // UnsafeRelaxedJsonEscaping keeps «ночь» as UTF-8 the way
        // JSONEncoder writes it; the resolver has to be named for this runtime to
        // serialise a JsonNode built from plain values at all.
        return root.ToJsonString(new JsonSerializerOptions
        {
            Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
            TypeInfoResolver = new System.Text.Json.Serialization.Metadata.DefaultJsonTypeInfoResolver(),
        });
    }
}

internal static class LedgerOrdering
{
    /// <summary>Ordinal ordering of day keys — the ISO form sorts as a
    /// chronology.</summary>
    public static IEnumerable<string> Ordering(this IEnumerable<string> keys) =>
        keys.OrderBy(key => key, StringComparer.Ordinal);

    public static List<KeyValuePair<string, TrafficLedger.Day>> Ordering(
        this IReadOnlyDictionary<string, TrafficLedger.Day> days) =>
        days.OrderBy(pair => pair.Key, StringComparer.Ordinal).ToList();

    public static List<KeyValuePair<Guid, TrafficLedger.ServerTotal>> Ordering(
        this IReadOnlyDictionary<Guid, TrafficLedger.ServerTotal> servers) =>
        servers.OrderBy(pair => pair.Key.ToString("D").ToUpperInvariant(), StringComparer.Ordinal).ToList();
}
