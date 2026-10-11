using System.IO;

namespace AnemiaCore;

/// <summary>
/// How much went through the tunnel, per day and per server, kept on disk: the
/// Windows port of <c>iOS/Anemia/TrafficStats.swift</c> and
/// <c>Android/app/.../data/TrafficStore.kt</c> — a <see cref="TrafficLedger"/>
/// fed by the running engine's counters, written to <c>traffic.json</c>.
///
/// The document is the one the other ports read and write (seconds since
/// Foundation's 2001 reference date, UUID keys upper-cased in a flat
/// «key, value» array); <c>Scripts/verify-traffic.sh</c> proves a file written
/// here is read back by the real Swift decoder without loss, so copying the
/// folder between machines carries the history instead of resetting it.
///
/// Lives in AnemiaCore rather than the app so the throttle, the load and the
/// atomic write are testable on any machine — the WPF layer cannot even run
/// outside Windows.
/// </summary>
public sealed class UsageStore
{
    /// <summary>Seconds between saves. The counters are cheap to read and the
    /// file is not: at a 2 s poll a write per tick is ~40 k small rewrites a
    /// day.</summary>
    public const double SaveAfterSeconds = 30;

    private readonly object _gate = new();
    private readonly string _filePath;
    private readonly Func<DateTimeOffset> _clock;
    private readonly Func<double> _ticker;
    private readonly TrafficLedger _ledger;

    /// <summary>Monotonic seconds of the last save, or null when nothing has
    /// been written yet — the first sample must always persist. Monotonic on
    /// purpose: a wall-clock stamp was the bug this replaced, because NTP or a
    /// DST shift steps <c>Date</c> backwards and the "older than 30 s" test then
    /// fails for the length of the step, leaving a day's bytes in memory until
    /// the process is killed.</summary>
    private double? _lastSaved;

    /// <param name="clock">Wall time: what a day means. Injectable so a test can
    /// replay a day change.</param>
    /// <param name="ticker">Monotonic seconds: how often to write.</param>
    public UsageStore(string? filePath = null, Func<DateTimeOffset>? clock = null,
                      Func<double>? ticker = null)
    {
        _filePath = filePath ?? DefaultPath();
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
        _ticker = ticker ?? (() => Environment.TickCount64 / 1000.0);
        _ledger = Load();
    }

    /// <summary>The app's own folder, next to state.json and panels.json.</summary>
    public static string DefaultPath()
    {
        var baseDir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        if (string.IsNullOrEmpty(baseDir)) baseDir = Environment.CurrentDirectory;
        return Path.Combine(baseDir, "Anemia", "traffic.json");
    }

    /// <summary>One reading of the current engine run: its cumulative counters
    /// and the instant that run started. Turning them into deltas is the
    /// ledger's job — which is why <paramref name="runStartedAt"/> must be the
    /// same number for every reading of one run.</summary>
    public void Record(DateTimeOffset runStartedAt, long received, long sent,
                       (Guid Id, string Name)? server)
    {
        var now = _clock();
        lock (_gate)
        {
            _ledger.Record(runStartedAt, received, sent, server, now);
            if (SinceSave() > SaveAfterSeconds) SaveLocked();
        }
    }

    /// <summary>The engine stopped: the next reading opens a new connected
    /// stretch, so the minutes the tunnel was down are not charged to it.</summary>
    public void Stopped()
    {
        lock (_gate)
        {
            _ledger.Stopped();
            SaveLocked();
        }
    }

    public void Reset()
    {
        lock (_gate)
        {
            _ledger.Reset();
            SaveLocked();
        }
    }

    /// <summary>Totals of servers the user deleted go, so the "top" board does
    /// not list exits that no longer exist (a re-imported subscription
    /// regenerates ids). An empty <paramref name="live"/> means "the list is not
    /// loaded", not "delete everything" — hence the early return.</summary>
    public void ForgetExcept(IReadOnlyCollection<Guid> live)
    {
        if (live.Count == 0) return;
        List<Guid> stale;
        lock (_gate)
        {
            stale = _ledger.Servers.Keys.Where(id => !live.Contains(id)).ToList();
            if (stale.Count == 0) return;
            _ledger.Forget(stale);
            SaveLocked();
        }
    }

    // MARK: - Reading for the UI

    public TrafficLedger.Day Today
    {
        get { lock (_gate) return _ledger.Today(_clock()); }
    }

    public TrafficLedger.Day Month
    {
        get { lock (_gate) return _ledger.Month(_clock()); }
    }

    public List<TrafficLedger.ServerTotal> TopServers
    {
        get { lock (_gate) return _ledger.TopServers; }
    }

    public List<TrafficLedger.Day> RecentDays(int count)
    {
        lock (_gate) return _ledger.RecentDays(count, _clock());
    }

    /// <summary>What is on the disk right now, for the log line and the tests.
    /// A fresh parse rather than a shared reference: the caller keeps it after
    /// the lock is gone.</summary>
    public string Document
    {
        get { lock (_gate) return _ledger.ToJson(); }
    }

    // MARK: - Disk

    private TrafficLedger Load()
    {
        string text;
        try
        {
            text = File.ReadAllText(_filePath);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Absent or unreadable is "no history yet", never a failed start.
            return new TrafficLedger();
        }
        // A half-written file lands here too: FromJson decodes entry by entry
        // and returns null only when there is no object at all, so a truncated
        // tail costs those rows and not the whole history.
        return TrafficLedger.FromJson(text) ?? new TrafficLedger();
    }

    private void SaveLocked()
    {
        _lastSaved = _ticker();
        try
        {
            var directory = Path.GetDirectoryName(_filePath);
            if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
            // Write-then-rename, like state.json and panels.json: a crash during
            // the write must not leave a truncated ledger on disk, because the
            // next launch reads that file and "unreadable" costs the history.
            var tmp = _filePath + ".tmp";
            File.WriteAllText(tmp, _ledger.ToJson());
            if (File.Exists(_filePath)) File.Replace(tmp, _filePath, null);
            else File.Move(tmp, _filePath);
        }
        catch (Exception e)
        {
            // Silent is the one wrong outcome: without a line here "no
            // statistics" is indistinguishable from "no traffic".
            Log?.Invoke($"traffic.json не сохранился: {e.Message}");
        }
    }

    private double SinceSave() => _lastSaved is { } at ? Math.Max(0, _ticker() - at)
                                                      : double.PositiveInfinity;

    /// <summary>Disk trouble belongs in the app log, not in a swallowed
    /// exception.</summary>
    public event Action<string>? Log;
}
