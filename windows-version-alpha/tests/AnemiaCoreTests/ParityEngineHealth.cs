using System.Globalization;
using System.Text;
using AnemiaCore;
using Xunit;

namespace AnemiaCoreTests;

/// <summary>
/// The rules the Windows client should share with the phone: what the engine's
/// last words mean, and what counts as a tunnel that carries nothing.
/// `engine/cases.golden.txt` and `health/cases.golden.txt` are Swift's own
/// answers, so this compares against the implementation the other three
/// platforms are pinned to, not against a reading of it.
/// </summary>
public class ParityEngineHealthTests
{
    /// <summary>Reason = the line chosen from the log tail (macOS), Cause = the
    /// same chain arriving as a returned error (Android). Both roads are printed
    /// by the emitter, so both are checked.</summary>
    [Fact]
    public void EngineLogMatchesSwift()
    {
        var produced = new StringBuilder();
        var reasons = 0;
        foreach (var line in Parity.Lines(Parity.Read("engine", "cases.txt")))
        {
            var parts = Parity.Columns(line);
            var label = parts.Length > 0 ? parts[0] : "";
            if (label.Length == 0)
            {
                produced.Append("error").Append(Parity.Tab).Append("no label").Append(Parity.Tab).Append(line)
                    .Append(Parity.LineFeed);
                continue;
            }
            if (line.Contains((char)0x0D)) { produced.Append(label).Refuse("cr"); continue; }
            if (parts.Length != 2) { produced.Append(label).Refuse("columns " + parts.Length); continue; }

            var body = Parity.Unescape(parts[1]);
            if (body.Length == 0) { produced.Append(label).Refuse("empty"); continue; }

            // `components(separatedBy: "\n")`, not the newline set: the emitter
            // splits on LF only, so a VT inside a case stays part of the line.
            var lines = body == "<empty>"
                ? Array.Empty<string>()
                : body.Split((char)0x0A);
            produced.Append(label).Append(Parity.Tab)
                .Append("reason=").Append(EngineLog.FailureReason(lines)).Append(Parity.Tab)
                .Append("cause=").Append(EngineLog.Cause(lines.Length == 0 ? "" : lines[^1]))
                .Append(Parity.LineFeed);
            reasons++;
        }

        Parity.Compare(produced.ToString(), Parity.Read("engine", "cases.golden.txt"),
                       "последние слова движка", floor: 25);
        Assert.True(reasons >= 20, "разобранных кейсов: " + reasons);
    }

    /// <summary>Thresholds come from the fixture where the column is empty only
    /// by leaving the policy's own default in place — the harness must not
    /// substitute a constant, or editing that constant would colour nothing.</summary>
    [Fact]
    public void HealthRulesMatchSwift()
    {
        var produced = new StringBuilder();
        var verdicts = 0;
        foreach (var line in Parity.Lines(Parity.Read("health", "cases.txt")))
        {
            var parts = Parity.Columns(line);
            var label = parts.Length > 0 ? parts[0] : "";
            if (label.Length == 0)
            {
                produced.Append("error").Append(Parity.Tab).Append("no label").Append(Parity.Tab).Append(line)
                    .Append(Parity.LineFeed);
                continue;
            }
            if (line.Contains((char)0x0D)) { produced.Append(label).Refuse("cr"); continue; }
            if (parts.Length != 12) { produced.Append(label).Refuse("columns " + parts.Length); continue; }

            string? problem = null;
            // Narrow integers on purpose: Swift reads Int32 here, and a fixture
            // value that does not fit is the case's error, not a silent clamp.
            int? Number(int index, string name, bool required = true)
            {
                var raw = parts[index];
                if (raw.Length == 0)
                {
                    if (required && problem is null) problem = name;
                    return null;
                }
                if (SwiftInt.Parse(raw) is not { } value ||
                    value < int.MinValue || value > int.MaxValue)
                {
                    if (problem is null) problem = name;
                    return null;
                }
                return (int)value;
            }

            var mode = parts[1];
            if (mode != "xray" && mode != "awg" && problem is null) problem = "mode";
            var ms = Number(2, "ms", required: false);
            var prevUp = Number(3, "prevUp", required: false);
            var prevDown = Number(4, "prevDown", required: false);
            if ((prevUp is null) != (prevDown is null) && problem is null) problem = "prev pair";
            var curUp = Number(5, "curUp", required: false);
            var curDown = Number(6, "curDown", required: false);
            if ((curUp is null) != (curDown is null) && problem is null) problem = "counters pair";
            var latency = Number(7, "latency", required: false);
            var limit = Number(8, "limit", required: false);
            var floor = Number(9, "sendFloor", required: false);
            var start = Number(10, "startFailures");
            var startHealth = Number(11, "startHealth", required: false);
            if (problem is not null) { produced.Append(label).Refuse(problem); continue; }

            var rules = new TunnelHealth();
            if (limit is { } limitValue) rules.RequestLimitMs = limitValue;
            if (floor is { } floorValue) rules.SendFloorBytes = floorValue;
            var outcome = mode == "xray"
                ? rules.Request(ms)
                : rules.Counters(
                    curUp is { } up && curDown is { } down ? new TrafficCounters(up, down) : null,
                    prevUp is { } pup && prevDown is { } pdown ? new TrafficCounters(pup, pdown) : null,
                    latency);
            var state = rules.Apply(outcome, new HealthState(startHealth, start ?? 0));

            produced.Append(label).Append(Parity.Tab).Append("start=").Append(start ?? 0)
                .Append(Parity.Tab).Append("from=").Append(Text(startHealth))
                .Append(Parity.Tab);
            if (outcome.IsSilence) produced.Append("outcome=silence");
            else
            {
                produced.Append("outcome=measured").Append(Parity.Tab)
                    .Append("ms=").Append(outcome.Ms).Append(Parity.Tab)
                    .Append("failed=").Append(outcome.Failed ? "1" : "0");
            }
            produced.Append(Parity.Tab).Append("health=").Append(Text(state.Health))
                .Append(Parity.Tab).Append("failures=").Append(state.Failures)
                .Append(Parity.LineFeed);
            verdicts++;
        }

        Parity.Compare(produced.ToString(), Parity.Read("health", "cases.golden.txt"),
                       "правило здоровья", floor: 25);
        Assert.True(verdicts >= 25, "вердиктов: " + verdicts);
    }

    private static string Text(int? value) => value?.ToString(CultureInfo.InvariantCulture) ?? "nil";

    /// <summary>The engine writes these words in ASCII English; the rest of the
    /// line may carry anything. Folding through the *current culture* makes the
    /// message a user sees depend on the language setting of their machine —
    /// measured on this runtime under tr-TR, where "FAILED".ToLower() is
    /// "faıled" and stops matching. The golden case
    /// `dotted-capital-I` covers the other half: "İnvalid" must NOT read as a
    /// failure either.</summary>
    [Fact]
    public void FailureFoldingDoesNotDependOnTheCurrentCulture()
    {
        var saved = CultureInfo.CurrentCulture;
        try
        {
            CultureInfo.CurrentCulture = new CultureInfo("tr-TR");
            Assert.True(EngineLog.LooksLikeFailure("FAILED to start: boom"));
            Assert.False(EngineLog.LooksLikeFailure("İnvalid token here"));
        }
        finally
        {
            CultureInfo.CurrentCulture = saved;
        }
    }
}
