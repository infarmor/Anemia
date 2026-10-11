using System.Globalization;

namespace AnemiaCore;

/// <summary>
/// When the tunnel is allowed to ask about its health again — and whether what
/// it last answered is still evidence. Port of
/// <c>Sources/LoaderCore/HealthSchedule.swift</c>.
///
/// A check is a real request out through the exit; on a phone in a pocket that
/// costs battery and traffic and is useful only while someone is watching the
/// tunnel. Whether the mode is on at all is deliberately not a flag here: the
/// app raises "health wanted" only when it is, so a disabled mode arrives as an
/// expired request.
/// </summary>
public sealed class HealthSchedule
{
    /// <summary>How long the app is still considered to be watching the tunnel.</summary>
    public double WatchedWindow { get; set; } = 60;

    /// <summary>How long its request to measure health still counts.</summary>
    public double WantedWindow { get; set; } = 60;

    /// <summary>How often the check may be repeated.</summary>
    public double Interval { get; set; } = 30;

    /// <summary>After this the failure counter is stale.</summary>
    public double StaleAfter { get; set; } = 90;

    /// <summary>Ages are seconds at the moment of the decision; null means
    /// "that has not happened yet" — null <paramref name="checkedAge"/> means
    /// "never measured", so it is time.</summary>
    public bool HealthDue(double? watchedAge, double? wantedAge, double? checkedAge)
    {
        if (watchedAge is not { } watched || watched >= WatchedWindow) return false;
        if (wantedAge is not { } wanted || wanted >= WantedWindow) return false;
        if (checkedAge is not { } checkedValue) return true;
        // A negative age (the clock stepped back, so the gap cannot be measured)
        // is "not yet", not "now": the monitor loops every few seconds, and
        // "unknown = measure" would turn one clock jump into a request per tick.
        return checkedValue >= Interval;
    }

    /// <summary>Is the reading taken <paramref name="checkedAge"/> seconds ago
    /// still alive? This is the guard against a silent freeze: the failure count
    /// is a report field, and when the checks stop — clock back, screen away,
    /// engine mute — the last value would stay "two failures in a row" forever.
    /// That is exactly the threshold the switch decision reads.
    ///
    /// A negative age is not fresh either: an unmeasurable gap deserves silence
    /// more than a switch based on data nothing can confirm.</summary>
    public bool SignalFresh(double? checkedAge) =>
        checkedAge is { } age && age >= 0 && age <= StaleAfter;
}

/// <summary>What the app should do about a tunnel that stopped carrying traffic.</summary>
public enum SwitchVerdict
{
    /// <summary>Turned off by the user, or there is nothing to move to.</summary>
    Off,
    /// <summary>Not connected, so there is no session whose health could fail.</summary>
    NotConnected,
    /// <summary>Something else already owns the tunnel.</summary>
    Busy,
    /// <summary>Not enough evidence: one miss, no signal yet, or the session is too young.</summary>
    Unproven,
    /// <summary>The budget for the window is spent, or the last move is too recent.</summary>
    Throttled,
    /// <summary>Move now.</summary>
    Go,
}

public static class SwitchVerdictExtensions
{
    /// <summary>The wire name the goldens print.</summary>
    public static string Raw(this SwitchVerdict verdict) => verdict switch
    {
        SwitchVerdict.Off => "off",
        SwitchVerdict.NotConnected => "notConnected",
        SwitchVerdict.Busy => "busy",
        SwitchVerdict.Unproven => "unproven",
        SwitchVerdict.Throttled => "throttled",
        SwitchVerdict.Go => "go",
        _ => verdict.ToString(),
    };
}

/// <summary>
/// The auto-switching decision in one place, so the apps cannot drift on
/// thresholds. Port of <c>AutoSwitchPolicy.swift</c>.
/// </summary>
public sealed class AutoSwitchPolicy
{
    /// <summary>Consecutive failed health checks before anything moves. One miss
    /// is a lost packet.</summary>
    public int FailuresToAct { get; set; } = 2;

    /// <summary>A session younger than this gets to finish setting up.</summary>
    public double MinSessionAge { get; set; } = 60;

    /// <summary>How far back the budget looks.</summary>
    public double Window { get; set; } = 15 * 60;

    /// <summary>How many moves the window allows in total.</summary>
    public int MaxSwitches { get; set; } = 3;

    /// <summary>Smallest gap between two moves.</summary>
    public double MinGap { get; set; } = 3 * 60;

    /// <summary><paramref name="recentSwitches"/> are ages in seconds of the
    /// moves already made, in any order — the gap is measured against the
    /// nearest one, so an unsorted list cannot be read as a long pause. Negative
    /// ages count as "just happened" and hold the switch off rather than opening
    /// a bypass. <paramref name="healthFailures"/> is null until the tunnel has
    /// answered once: "no signal" is neither "fine" nor "dead".</summary>
    public SwitchVerdict Decide(bool enabled, bool connected, bool busy, int serverCount,
                                int? healthFailures, double sessionAge, IReadOnlyList<double> recentSwitches)
    {
        if (!enabled || serverCount <= 1) return SwitchVerdict.Off;
        if (!connected) return SwitchVerdict.NotConnected;
        if (busy) return SwitchVerdict.Busy;
        if (healthFailures is not { } failures || failures < FailuresToAct) return SwitchVerdict.Unproven;
        // A comparison with NaN is false always, so an unknown session age means
        // "do not switch", not "the session is eternal".
        if (!(sessionAge > MinSessionAge)) return SwitchVerdict.Unproven;
        var kept = Retained(recentSwitches);
        if (kept.Count >= MaxSwitches) return SwitchVerdict.Throttled;
        if (kept.Any(age => !(age > MinGap))) return SwitchVerdict.Throttled;
        return SwitchVerdict.Go;
    }

    /// <summary>The switches that still count toward the budget.</summary>
    public List<double> Retained(IReadOnlyList<double> recentSwitches) =>
        recentSwitches.Where(age => age <= Window).ToList();
}

/// <summary>
/// Counts tunnel moves so <see cref="AutoSwitchPolicy"/> can say "enough". Port
/// of <c>SwitchBudget.swift</c>: the window cut and the refund of a move that
/// went nowhere live here, because keeping the list by hand at each call site is
/// what made idle attempts eat budget slots on iOS.
/// </summary>
public sealed class SwitchBudget
{
    public double Window { get; }

    private readonly List<double> _marks;

    public SwitchBudget(double window = 15 * 60, IEnumerable<double>? marks = null)
    {
        Window = window;
        _marks = marks?.ToList() ?? new List<double>();
    }

    public IReadOnlyList<double> Marks => _marks;

    /// <summary>Drop what is outside the window and record a new move.</summary>
    public void Note(double now)
    {
        Prune(now);
        _marks.Add(now);
    }

    /// <summary>Undo a move that started nothing. Exactly one mark is removed —
    /// not "all matching ones": two decisions in the same millisecond differ by
    /// one of them having happened.</summary>
    public void Refund(double now)
    {
        for (var i = _marks.Count - 1; i >= 0; i--)
        {
            if (_marks[i] != now) continue;
            _marks.RemoveAt(i);
            return;
        }
    }

    /// <summary>Ages for the predicate, cut by the window. Order is not
    /// required: the policy measures the gap against the nearest one.</summary>
    public List<double> AgesAt(double now) =>
        _marks.Where(mark => now - mark <= Window).Select(mark => now - mark).ToList();

    /// <summary>Only the marks still inside the window — deliberately the same
    /// condition as <see cref="AgesAt"/>, so the list and the ages cannot drift
    /// apart and be caught in only one of the two columns of the golden.</summary>
    public void Prune(double now) => _marks.RemoveAll(mark => now - mark > Window);
}
