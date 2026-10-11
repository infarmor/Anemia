namespace AnemiaCore;

/// <summary>
/// Reading the engine's own output. Port of
/// <c>Sources/LoaderCore/EngineLog.swift</c>; <c>engine/cases.golden.txt</c>
/// holds the fixture, and its texts are real xray 26.x output captured from the
/// bundled binary — the shape of a Go error chain is not something a port
/// should invent.
/// </summary>
public static class EngineLog
{
    /// <summary>The one line worth showing when xray dies during startup.</summary>
    public static string FailureReason(IReadOnlyList<string> lines)
    {
        // Only the innermost link of the chain says what to fix; a request that
        // died at the outermost wrapper reads like a config-file path.
        for (var i = lines.Count - 1; i >= 0; i--)
            if (lines[i].Contains("Failed to start", StringComparison.Ordinal))
                return Cause(lines[i]);
        for (var i = lines.Count - 1; i >= 0; i--)
            if (LooksLikeFailure(lines[i])) return lines[i];
        return lines.Count == 0 ? "engine exited during startup" : lines[lines.Count - 1];
    }

    /// <summary>The innermost cause of one engine error text, chain or not. A
    /// text without a chain comes back trimmed and otherwise untouched: dropping
    /// the wrapper would leave the user a word and no context.</summary>
    public static string Cause(string text)
    {
        var chain = text.Split(" > ", StringSplitOptions.RemoveEmptyEntries)
            .Select(Foundation.TrimFoundationSpaces)
            .Where(part => part.Length > 0)
            .ToArray();
        return chain.Length > 1 ? StripPackagePrefix(chain[^1]) : Foundation.TrimFoundationSpaces(text);
    }

    /// <summary>"infra/conf: Failed to build TLS config." → "Failed to build TLS
    /// config." Only a slash-separated, space-free token counts as a Go package
    /// path, so "listen tcp 127.0.0.1:1080: bind: …" stays intact.</summary>
    public static string StripPackagePrefix(string text)
    {
        var colon = text.IndexOf(": ", StringComparison.Ordinal);
        if (colon < 0) return text;
        var head = text[..colon];
        if (!head.Contains('/') || head.Contains(' ')) return text;
        return text[(colon + 2)..];
    }

    /// <summary>Whether a log line reads as a failure. ASCII-only folding,
    /// deliberately: a locale-sensitive comparison makes "FAILED" stop matching
    /// "failed" in a Turkish locale (dotted capital I), which would tie the
    /// message a user sees to the language setting of their machine.</summary>
    public static bool LooksLikeFailure(string line)
    {
        var buffer = new System.Text.StringBuilder(line.Length);
        foreach (var c in line)
            buffer.Append(c >= 'A' && c <= 'Z' ? (char)(c + 32) : c);
        var text = buffer.ToString();
        return text.Contains("failed", StringComparison.Ordinal) ||
               text.Contains("invalid", StringComparison.Ordinal);
    }
}

/// <summary>Byte counters of a running engine, as the tunnel reports them.</summary>
public readonly record struct TrafficCounters(long Up, long Down);

/// <summary>What one health check said. <c>Measured</c> carries the number the
/// report should show — which is not always -1 on failure: a request answered in
/// five seconds was answered, so the report says five seconds and still counts as
/// a failure.</summary>
public readonly record struct HealthOutcome(bool IsSilence, int Ms, bool Failed)
{
    public static readonly HealthOutcome Silence = new(true, 0, false);

    public static HealthOutcome Measured(int ms, bool failed) => new(false, ms, failed);
}

/// <summary>The state the tunnel keeps about its own health.</summary>
public readonly record struct HealthState(int? Health, int Failures);

/// <summary>
/// "Does this tunnel carry traffic right now?" — port of
/// <c>Sources/LoaderCore/TunnelHealth.swift</c>, the rules that live inside the
/// iOS tunnel extension where no test host can reach them. Two engines, two ways
/// to ask: Xray has a dialer, so send one real request and time it; AmneziaWG has
/// none, so the only reading is whether the phone sent and nothing came back.
/// </summary>
public sealed class TunnelHealth
{
    /// <summary>A tiny request that takes longer than this is a tunnel that
    /// carries nothing, however politely it answers.</summary>
    public int RequestLimitMs { get; set; } = 3_000;

    /// <summary>AmneziaWG needs evidence the phone actually tried: with an idle
    /// screen nothing is sent, and silence is not a failure.</summary>
    public long SendFloorBytes { get; set; } = 2_000;

    /// <summary>Xray. Null means the request never completed — including "the
    /// engine is not running", which is also a tunnel that carries nothing.</summary>
    public HealthOutcome Request(int? ms) => ms is not { } value
        ? HealthOutcome.Measured(-1, true)
        : HealthOutcome.Measured(value, value > RequestLimitMs);

    /// <summary>AmneziaWG, from two readings of the same engine run. Null
    /// counters mean the engine did not answer: nothing is claimed and the caller
    /// keeps `previous` for the next round, because a dropped reading widens the
    /// next interval rather than inventing a stall.</summary>
    public HealthOutcome Counters(TrafficCounters? counters, TrafficCounters? previous, int? latency)
    {
        if (counters is not { } current || previous is not { } before) return HealthOutcome.Silence;
        var sent = current.Up - before.Up;
        var received = current.Down - before.Down;
        if (received > 0) return HealthOutcome.Measured(latency ?? 1, false);
        // A negative delta is an engine restart, not a silent server.
        if (sent > SendFloorBytes) return HealthOutcome.Measured(-1, true);
        return HealthOutcome.Silence;
    }

    /// <summary>How the report and the failure counter change after one outcome.
    /// The counter is what <see cref="AutoSwitchPolicy"/> eventually reads, so the
    /// meaning of "two in a row" lives here rather than in whoever calls the
    /// check — and silence must not touch anything.</summary>
    public HealthState Apply(HealthOutcome outcome, HealthState state) => outcome.IsSilence
        ? state
        : new HealthState(outcome.Ms, outcome.Failed ? state.Failures + 1 : 0);
}
