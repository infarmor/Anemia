using System.IO;
using AnemiaCore;
using Xunit;

namespace AnemiaCoreTests;

/// <summary>
/// The disk half of the traffic ledger: what gets written, how often, and what
/// a restart finds. The arithmetic itself is pinned against Swift's own output
/// in <see cref="ParityTrafficLedgerTests"/> and by
/// <c>Scripts/verify-traffic.sh</c>; these tests are about the store around it —
/// the throttle that decides whether a day survives a kill, and the rule that a
/// broken file costs rows rather than the app.
/// </summary>
public sealed class UsageStoreTests : IDisposable
{
    private readonly string _dir;
    private readonly string _file;

    /// <summary>Monotonic seconds, driven by the test.</summary>
    private double _tick;

    /// <summary>Wall time, also driven: a day boundary and an NTP step both
    /// have to be reproducible. Local midday, so a test that steps the clock by
    /// hours stays inside one calendar day — this machine runs in a zone where
    /// a round unix number is 01:53 local, and the first version of these tests
    /// "lost" a day's bytes across a midnight it had not meant to cross.</summary>
    private DateTimeOffset _now = LocalNoon(0);

    /// <summary>Noon local time, `shift` days from today, as UTC.</summary>
    private static DateTimeOffset LocalNoon(int shift) =>
        new(DateTime.Now.Date.AddDays(shift).AddHours(12).ToUniversalTime(), TimeSpan.Zero);

    public UsageStoreTests()
    {
        _dir = Path.Combine(Path.GetTempPath(), "anemia-usage-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_dir);
        _file = Path.Combine(_dir, "traffic.json");
    }

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch (IOException) { }
    }

    private UsageStore Open() => new(_file, () => _now, () => _tick);

    private long Saved(string json) =>
        TrafficLedger.FromJson(json)!.Today(_now).Received;

    private long SavedTotal() => Saved(File.ReadAllText(_file));

    /// <summary>A restart finds the same day it left, and the engine run it was
    /// saved in: the next reading of that run is a delta, not the whole
    /// cumulative counter again.</summary>
    [Fact]
    public void AReopenedStoreContinuesTheDayAndTheRun()
    {
        var run = _now;
        var store = Open();
        var id = Guid.NewGuid();
        store.Record(run, 500, 50, (id, "Frankfurt"));
        _tick += 2;
        store.Record(run, 900, 90, (id, "Frankfurt"));
        Assert.Equal(900, store.Today.Received);

        // Same file, new process. Stopped() is the flush: a reopened store can
        // only know what actually reached the disk, and the window has not
        // closed yet.
        store.Stopped();
        var reopened = Open();
        Assert.Equal(900, reopened.Today.Received);
        Assert.Equal(90, reopened.Today.Sent);
        Assert.Equal("Frankfurt", reopened.TopServers.Single().Name);

        // The tunnel is still up: xray's counters keep counting from the same
        // instant. Reading them as new totals would bill the day 900 again.
        _tick += 2;
        reopened.Record(run, 1000, 100, (id, "Frankfurt"));
        Assert.Equal(1000, reopened.Today.Received);
    }

    /// <summary>The throttle, measured through the file: a sample every 2 s is
    /// not a write every 2 s, and crossing the window does write.</summary>
    [Fact]
    public void WritesHappenOncePerWindowNotPerSample()
    {
        var run = _now;
        var store = Open();
        store.Record(run, 100, 10, null);          // first sample: saves at once
        for (var i = 0; i < 15; i++)
        {
            _tick += 2;                            // 2 … 30 s of polling
            store.Record(run, 100 + (i + 1) * 10, 10, null);
        }
        // On disk there is still the first save — 100 bytes, not 250. Exactly
        // 30 s is not yet the window ("older than", as on Android/Kotlin); the
        // iOS port uses `>=`, so the boundary is stated here rather than left to
        // whichever library a later reader copies.
        Assert.Equal(100, SavedTotal());
        Assert.Equal(250, store.Today.Received);

        _tick += 1;                                // 31 s: the window closes
        store.Record(run, 260, 10, null);
        Assert.Equal(260, SavedTotal());
        Assert.Equal(260, store.Today.Received);
    }

    /// <summary>The reason the throttle is not wall-clock based: a step
    /// backwards (NTP sync, a DST change) used to switch persisting off for the
    /// size of the step, and the bytes in between were lost on the next kill.</summary>
    [Fact]
    public void AWallClockStepBackwardsDoesNotStopPersisting()
    {
        var run = _now;
        var store = Open();
        store.Record(run, 100, 10, null);

        _now = _now.AddHours(-3);                  // the clock jumps
        _tick += 31;                               // monotonic time did not
        store.Record(run, 200, 20, null);
        Assert.Equal(200, SavedTotal());

        _now = _now.AddHours(3);
        _tick += 31;
        store.Record(run, 300, 30, null);
        Assert.Equal(300, SavedTotal());
    }

    /// <summary>Stopped() writes immediately: "the tunnel went down at 22:14"
    /// must not wait for the next 30 s window, because nothing is counting any
    /// more and the next window may never come.</summary>
    [Fact]
    public void StoppingSavesWithoutWaitingForTheWindow()
    {
        var run = _now;
        var store = Open();
        store.Record(run, 100, 10, null);
        Assert.Contains("lastReading", File.ReadAllText(_file));    // a stretch is being counted

        _tick += 2;
        store.Record(run, 120, 12, null);
        Assert.Equal(100, SavedTotal());                            // still throttled on disk
        Assert.Equal(120, store.Today.Received);

        store.Stopped();
        Assert.DoesNotContain("lastReading", File.ReadAllText(_file));
        Assert.Equal(120, SavedTotal());                            // flushed now
    }

    /// <summary>A file this build cannot make sense of costs the rows that are
    /// broken, never the start of the app: the app reads this at launch, and an
    /// exception here is a VPN client that will not open.</summary>
    [Fact]
    public void ACorruptFileIsNoHistoryNotAFailedStart()
    {
        File.WriteAllText(_file, "{\"days\":{\"2025-06-01\":{\"id\":\"2025-06-01\",\"received\":7777,\"sent\":1");
        var store = Open();
        Assert.Equal(0, store.Today.Received);

        // It records anyway, and the next save is a document again.
        store.Record(_now, 10, 1, null);
        Assert.Equal(10, SavedTotal());
        Assert.NotNull(TrafficLedger.FromJson(File.ReadAllText(_file)));
    }

    /// <summary>Deleted exits leave the board — but an empty server list means
    /// "not loaded yet", and treating it as "the user deleted everything" would
    /// wipe the whole "top" board on a race with the first load.</summary>
    [Fact]
    public void DeletedServersLeaveTheBoardAndAnEmptyListChangesNothing()
    {
        var (a, b) = (Guid.NewGuid(), Guid.NewGuid());
        var run = _now;
        var store = Open();
        store.Record(run, 100, 0, (a, "Berlin"));
        _tick += 2;
        // 80 more bytes since the previous reading, now through the other exit:
        // the counters are the engine's, and the ledger attributes the delta to
        // whichever server the session is dialing.
        store.Record(run, 180, 0, (b, "Riga"));
        Assert.Equal(2, store.TopServers.Count);

        store.ForgetExcept(new[] { b });
        Assert.Equal("Riga", store.TopServers.Single().Name);
        Assert.Equal(180, SavedTotal());

        _tick += 2;
        store.ForgetExcept(Array.Empty<Guid>());
        Assert.Single(store.TopServers);

        _tick += 2;
        store.ForgetExcept(new[] { a, b });
        Assert.Single(store.TopServers);
    }

    /// <summary>The day rolls over on the local calendar, in the machine's own
    /// zone — the same rule the other ports apply, checked here at a boundary.</summary>
    [Fact]
    public void SamplesLandingAfterMidnightBelongToTheNextDay()
    {
        // Two seconds before local midnight, then two seconds later. Built from
        // this machine's own next midnight rather than a unix round number,
        // which is mid-afternoon or pre-dawn depending on the zone; a plain
        // "noon + 12 h" would miss the boundary on a 25-hour DST day.
        _now = new DateTimeOffset(
            DateTime.Now.Date.AddDays(1).AddSeconds(-2).ToUniversalTime(), TimeSpan.Zero);
        var run = _now.AddMinutes(-10);
        var store = Open();
        var id = Guid.NewGuid();
        store.Record(run, 100, 0, (id, "Berlin"));
        _tick += 2;
        _now = _now.AddSeconds(2);
        store.Record(run, 100, 0, (id, "Berlin"));

        var days = store.RecentDays(2);
        Assert.Equal(2, days.Count);
        Assert.Equal(100, days[0].Received);
        Assert.Equal(0, days[1].Received);
        Assert.NotEqual(days[0].Id, days[1].Id);
    }

    /// <summary>A failing disk has to say so. Counting bytes in memory and never
    /// writing them is invisible from the outside — the statistics screen would
    /// read "no traffic" where the truth is "no file" — and the app must keep
    /// counting anyway rather than throw on the UI's behalf.</summary>
    [Fact]
    public void DiskTroubleIsAnnouncedAndCountingContinues()
    {
        var blocker = Path.Combine(_dir, "blocked");
        File.WriteAllText(blocker, "not a directory");
        var logs = new List<string>();
        var store = new UsageStore(Path.Combine(blocker, "traffic.json"), () => _now, () => _tick);
        store.Log += line => logs.Add(line);

        store.Record(_now, 10, 1, null);
        Assert.Contains("traffic.json", Assert.Single(logs));
        Assert.Equal(10, store.Today.Received);

        // It does not spam either: the next attempt waits for the window.
        _tick += 2;
        store.Record(_now, 20, 2, null);
        Assert.Single(logs);
        Assert.Equal(20, store.Today.Received);
    }
}
