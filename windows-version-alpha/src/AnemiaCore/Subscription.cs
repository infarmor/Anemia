namespace AnemiaCore;

/// <summary>
/// A saved subscription: a URL that returns a list of share links, plus the
/// servers most recently fetched from it. Port of
/// <c>Sources/LoaderCore/Subscription.swift</c> — the members below are the same
/// decision macOS, iOS and Android make, and
/// <c>Android/core/src/test/resources/sub/due.golden.txt</c> pins all three
/// against Swift's own answers.
///
/// Ages are epoch <em>seconds</em> as <c>double</c>, exactly like Swift's
/// <c>TimeInterval</c>, and that is not laziness: the fixture set answers
/// <c>now = nan</c> and <c>lastUpdated = inf</c>, and the verdict has to come out
/// the way Foundation's does — every comparison against NaN is false, so such a
/// panel is never due. A <see cref="DateTimeOffset"/> carries neither value.
/// </summary>
public sealed class Subscription
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public string Url { get; set; } = "";
    public DateTimeOffset? LastUpdated { get; set; }
    public List<ProxyServer> Servers { get; set; } = new();

    /// <summary>What an unattended round waits between two fetches when the panel
    /// says nothing — Swift's 6 h default argument.</summary>
    public const double DefaultMaxAgeSeconds = 6 * 3600;

    public const double MinMaxAgeSeconds = 3600;

    public const double MaxMaxAgeSeconds = 24 * 3600;

    /// <summary>Swift's `Date.distantPast`, used for a panel never fetched.</summary>
    public const double DistantPastSeconds = -63138364800;

    public Subscription() { }

    public Subscription(string name, string url, DateTimeOffset? lastUpdated = null,
                        List<ProxyServer>? servers = null)
    {
        Name = name;
        Url = url;
        LastUpdated = lastUpdated;
        Servers = servers ?? new List<ProxyServer>();
    }

    /// <summary>Can this list be fetched at all without the user asking? A panel
    /// reachable over plain http answers as whoever controls the path decides: a
    /// café router returns its own server list and the nightly auto-refresh
    /// quietly installs it in place of the real one. Automatic rounds skip these;
    /// pressing Refresh still loads them, and the row shows the mark.</summary>
    public bool TlsProtected => Url.StartsWith("https://", StringComparison.OrdinalIgnoreCase);

    /// <summary>How long an unattended round waits between two fetches of this
    /// panel.</summary>
    public double RefreshMaxAgeSeconds(double? panelIntervalSeconds = null,
                                       double? defaultAgeSeconds = null) =>
        MaxAgeSeconds(panelIntervalSeconds, defaultAgeSeconds);

    /// <summary>Whether an unattended round may re-fetch this panel — the whole
    /// decision (TLS gate + how often) in one place, so no platform can drift on
    /// when a list is allowed to change by itself.</summary>
    public bool RefreshIsDue(DateTimeOffset now, double? panelIntervalSeconds = null,
                             double? defaultAgeSeconds = null, bool allowInsecure = false) =>
        RefreshIsDue(LastUpdated?.ToUnixTimeSeconds(), (double)now.ToUnixTimeSeconds(), TlsProtected,
                     panelIntervalSeconds, defaultAgeSeconds, allowInsecure);

    /// <summary>The same decision on raw epoch seconds: the whole predicate, kept
    /// free of date types so the NaN and infinity cases a panel can hand in answer
    /// exactly as they do on Swift.</summary>
    public static bool RefreshIsDue(double? lastFetchedSeconds, double nowSeconds, bool tlsProtected,
                                    double? panelIntervalSeconds = null, double? defaultAgeSeconds = null,
                                    bool allowInsecure = false)
    {
        if (!tlsProtected && !allowInsecure) return false;
        var fetched = lastFetchedSeconds ?? DistantPastSeconds;
        // A mark in the future means the clocks disagreed (a device that slept
        // through a DST change, a sync bundle from a machine with a wrong clock).
        // Waiting that out quietly would leave the list stale for the whole skew.
        if (fetched > nowSeconds) return true;
        return nowSeconds - fetched >= MaxAgeSeconds(panelIntervalSeconds, defaultAgeSeconds);
    }

    /// <summary><paramref name="panelIntervalSeconds"/> is what the panel asked
    /// for through <c>profile-update-interval</c>; a panel that says nothing gets
    /// <paramref name="defaultAgeSeconds"/>. Clamped to [1 h, 24 h]: hourly polling
    /// spams every panel, and a panel asking for monthly updates would otherwise
    /// sit stale for a month while its servers rot.</summary>
    private static double MaxAgeSeconds(double? panelIntervalSeconds, double? defaultAgeSeconds)
    {
        // NaN would sail through the clamp (`Min`/`Max` with NaN leave NaN) and
        // `age >= NaN` is false forever — the panel would silently stop updating.
        // Silence costs more than either default, so a non-number gives way both
        // as the panel's request and as the caller's default.
        var requested = panelIntervalSeconds is { } panel && double.IsFinite(panel)
            ? panel
            : defaultAgeSeconds is { } fallback && double.IsFinite(fallback)
                ? fallback
                : DefaultMaxAgeSeconds;
        return Math.Min(Math.Max(requested, MinMaxAgeSeconds), MaxMaxAgeSeconds);
    }
}
