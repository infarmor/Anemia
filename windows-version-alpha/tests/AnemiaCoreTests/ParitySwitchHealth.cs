using System.Globalization;
using System.Text;
using AnemiaCore;
using Xunit;

namespace AnemiaCoreTests;

/// <summary>
/// The three reliability predicates that decide when a tunnel is looked at, when
/// it is acted on, and how often: the health schedule, the auto-switch verdict
/// and the switch budget. Each is a golden of its own in the shared fixture set,
/// so Windows cannot pace differently from the phone.
/// </summary>
public class ParitySwitchHealthTests
{
    /// <summary>`health/run.txt`: `label watchedAge wantedAge checkedAge
    /// watchedWindow wantedWindow interval staleAfter`. An empty window column
    /// leaves the policy's own default in place — otherwise editing the constant
    /// would colour nothing.</summary>
    [Fact]
    public void HealthScheduleMatchesSwift()
    {
        var produced = new StringBuilder();
        var verdicts = 0;
        foreach (var line in Parity.Lines(Parity.Read("health", "run.txt")))
        {
            var parts = Parity.Columns(line);
            var label = parts.Length > 0 ? parts[0] : "";
            if (label.Length == 0)
            {
                produced.Append("error").Append(Parity.Tab).Append("no label").Append(Parity.Tab).Append(line).Append(Parity.LineFeed);
                continue;
            }
            if (line.Contains((char)0x0D)) { produced.Append(label).Refuse("cr"); continue; }
            if (parts.Length != 8) { produced.Append(label).Refuse("columns " + parts.Length); continue; }

            string? problem = null;
            double? Age(int index, string name)
            {
                var raw = parts[index];
                if (raw.Length == 0) return null;
                var value = SwiftDouble.Parse(raw);
                if (value is null || !double.IsFinite(value.Value))
                {
                    if (problem is null) problem = name;
                    return null;
                }
                return value;
            }
            var watched = Age(1, "watchedAge");
            var wanted = Age(2, "wantedAge");
            var checkedAge = Age(3, "checkedAge");
            var watchWindow = Age(4, "watchedWindow");
            var wantWindow = Age(5, "wantedWindow");
            var every = Age(6, "interval");
            var stale = Age(7, "staleAfter");
            if (problem is not null) { produced.Append(label).Refuse(problem); continue; }

            var schedule = new HealthSchedule();
            if (watchWindow is { } w) schedule.WatchedWindow = w;
            if (wantWindow is { } wa) schedule.WantedWindow = wa;
            if (every is { } e) schedule.Interval = e;
            if (stale is { } st) schedule.StaleAfter = st;
            var due = schedule.HealthDue(watched, wanted, checkedAge);
            // Freshness is printed always: without it "the check is not running"
            // and "there is no data" would be the same line, and the switch
            // decision is exactly what tells them apart.
            var fresh = schedule.SignalFresh(checkedAge);
            produced.Append(label).Append(Parity.Tab).Append("due=").Append(due ? "1" : "0")
                .Append(Parity.Tab).Append("fresh=").Append(fresh ? "1" : "0").Append(Parity.LineFeed);
            verdicts++;
        }

        Parity.Compare(produced.ToString(), Parity.Read("health", "run.golden.txt"), "расписание проверок", floor: 25);
        Assert.True(verdicts >= 25, "вердиктов: " + verdicts);
    }

    /// <summary>`switch/due.txt`: `label enabled connected busy serverCount
    /// healthFailures sessionAge recentSwitches`. Flags are 0/1 only — an empty
    /// column would mean "not filled in", not "off".</summary>
    [Fact]
    public void SwitchVerdictMatchesSwift()
    {
        var produced = new StringBuilder();
        var policy = new AutoSwitchPolicy();
        var verdicts = 0;
        var goes = 0;
        foreach (var line in Parity.Lines(Parity.Read("switch", "due.txt")))
        {
            var parts = Parity.Columns(line);
            var label = parts.Length > 0 ? parts[0] : "";
            if (label.Length == 0)
            {
                produced.Append("error").Append(Parity.Tab).Append("no label").Append(Parity.Tab).Append(line).Append(Parity.LineFeed);
                continue;
            }
            if (line.Contains((char)0x0D)) { produced.Append(label).Refuse("cr"); continue; }
            if (parts.Length != 8) { produced.Append(label).Refuse("columns " + parts.Length); continue; }

            string? problem = null;
            bool Flag(int index, string name)
            {
                switch (parts[index])
                {
                    case "0": return false;
                    case "1": return true;
                    default:
                        if (problem is null) problem = name;
                        return false;
                }
            }
            double? Real(int index, string name)
            {
                var value = SwiftDouble.Parse(parts[index]);
                if (value is null || !double.IsFinite(value.Value))
                {
                    if (problem is null) problem = name;
                    return null;
                }
                return value;
            }
            int? Narrow(int index, string name)
            {
                if (SwiftInt.Parse(parts[index]) is not { } value ||
                    value < int.MinValue || value > int.MaxValue)
                {
                    if (problem is null) problem = name;
                    return null;
                }
                return (int)value;
            }

            var enabled = Flag(1, "enabled");
            var connected = Flag(2, "connected");
            var busy = Flag(3, "busy");
            var serverCount = Narrow(4, "serverCount");
            var failures = parts[5].Length == 0 ? null : Narrow(5, "healthFailures");
            var sessionAge = Real(6, "sessionAge");
            var ages = new List<double>();
            if (parts[7].Length > 0)
            {
                foreach (var raw in parts[7].Split(','))
                {
                    var value = SwiftDouble.Parse(raw);
                    if (value is null || !double.IsFinite(value.Value))
                    {
                        if (problem is null) problem = "recentSwitches";
                        break;
                    }
                    ages.Add(value.Value);
                }
            }
            if (problem is not null) { produced.Append(label).Refuse(problem); continue; }

            var verdict = policy.Decide(enabled, connected, busy, serverCount ?? 0, failures,
                sessionAge ?? 0, ages);
            if (verdict == SwitchVerdict.Go) goes++;
            produced.Append(label).Append(Parity.Tab)
                .Append("kept=").Append(policy.Retained(ages).Count.ToString(CultureInfo.InvariantCulture))
                .Append(Parity.Tab).Append("verdict=").Append(verdict.Raw()).Append(Parity.LineFeed);
            verdicts++;
        }

        Parity.Compare(produced.ToString(), Parity.Read("switch", "due.golden.txt"), "решение о переключении", floor: 25);
        Assert.True(verdicts >= 25, "вердиктов: " + verdicts);
        Assert.True(goes >= 3, "решений «переключить»: " + goes);
    }

    /// <summary>`switch/budget.txt`: `label op now window marks`. Both the marks
    /// and the ages are printed, because one window rule feeds two functions — a
    /// mutant in it has to be visible in both columns, not only where somebody
    /// thought to look.</summary>
    [Fact]
    public void SwitchBudgetMatchesSwift()
    {
        var produced = new StringBuilder();
        var ops = 0;
        var refusals = 0;
        foreach (var line in Parity.Lines(Parity.Read("switch", "budget.txt")))
        {
            var parts = Parity.Columns(line);
            var label = parts.Length > 0 ? parts[0] : "";
            if (label.Length == 0)
            {
                refusals++;
                produced.Append("error").Append(Parity.Tab).Append("no label").Append(Parity.Tab).Append(line).Append(Parity.LineFeed);
                continue;
            }
            if (line.Contains((char)0x0D)) { refusals++; produced.Append(label).Refuse("cr"); continue; }
            if (parts.Length != 5)
            {
                refusals++;
                produced.Append(label).Refuse("columns " + parts.Length);
                continue;
            }

            string? problem = null;
            double? Real(int index, string name)
            {
                var value = SwiftDouble.Parse(parts[index]);
                if (value is null || !double.IsFinite(value.Value))
                {
                    if (problem is null) problem = name;
                    return null;
                }
                return value;
            }
            var op = parts[1];
            if (op is not ("note" or "refund" or "prune" or "ages") && problem is null) problem = "op";
            var now = Real(2, "now");
            var window = Real(3, "window");
            var marks = new List<double>();
            if (parts[4].Length > 0)
            {
                foreach (var raw in parts[4].Split(','))
                {
                    var value = SwiftDouble.Parse(raw);
                    if (value is null || !double.IsFinite(value.Value))
                    {
                        if (problem is null) problem = "marks";
                        continue;
                    }
                    marks.Add(value.Value);
                }
            }
            if (problem is not null) { produced.Append(label).Refuse(problem); refusals++; continue; }

            var budget = new SwitchBudget(window ?? 15 * 60, marks);
            var at = now ?? 0;
            switch (op)
            {
                case "note": budget.Note(at); break;
                case "refund": budget.Refund(at); break;
                case "prune": budget.Prune(at); break;
            }
            // Пустой список печатается как «-»: иначе «список пуст» и «списка не
            // было» сливаются в одну строку, а refund на пустом — это другой случай.
            string Column(IEnumerable<string> values)
            {
                var joined = string.Join(",", values);
                return joined.Length == 0 ? "-" : joined;
            }
            produced.Append(label).Append(Parity.Tab).Append("op=").Append(op).Append(Parity.Tab)
                .Append("marks=").Append(Column(budget.Marks.Select(SwiftNumber.Of))).Append(Parity.Tab)
                .Append("ages=").Append(Column(budget.AgesAt(at).Select(SwiftNumber.Of))).Append(Parity.LineFeed);
            ops++;
        }

        // `-0.0` and `0.0` are the same number and different text; the golden
        // keeps Swift's, and so does the formatter above.
        Parity.Compare(produced.ToString(), Parity.Read("switch", "budget.golden.txt"), "бюджет переключений", floor: 22);
        Assert.True(ops >= 18, "операций: " + ops);
        Assert.True(refusals >= 5, "громко отказанных кейсов: " + refusals);
    }
/// <summary>How Swift prints a Double, because the golden compares text: a whole
/// number carries its decimal point ("999.0"), and -0 is not 0.</summary>
internal static class SwiftNumber
{
    public static string Of(double value)
    {
        if (double.IsNaN(value)) return "nan";
        if (double.IsPositiveInfinity(value)) return "inf";
        if (double.IsNegativeInfinity(value)) return "-inf";
        var text = value.ToString("R", CultureInfo.InvariantCulture);
        if (text.Contains('E') || text.Contains('e')) return text.ToLowerInvariant();
        return text.Contains('.') ? text : text + ".0";
    }
}
}
