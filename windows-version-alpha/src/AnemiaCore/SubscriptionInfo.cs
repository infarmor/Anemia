using System.Globalization;

namespace AnemiaCore;

/// <summary>
/// What a panel (3x-ui, Marzban, Remnawave…) says about a subscription in the
/// response headers: traffic, expiry, its own name, where to get help. Port of
/// <c>Sources/LoaderCore/SubscriptionInfo.swift</c>.
///
/// The arithmetic is written with overflow in mind because the Swift side
/// trapped twice on it — a header <c>total</c> beyond <c>long.MaxValue</c>, and
/// <c>remaining</c> subtracting a negative counter — and
/// <c>sub/headers.golden.txt</c> pins both, plus every edge of the number
/// grammar a hostile panel can reach.
/// </summary>
public sealed class SubscriptionInfo : IEquatable<SubscriptionInfo>
{
    public string? Title { get; set; }

    public long? Uploaded { get; set; }

    public long? Downloaded { get; set; }

    /// <summary>Traffic allowance, bytes; null or 0 means unlimited.</summary>
    public long? Total { get; set; }

    /// <summary>Expiry, epoch seconds.</summary>
    public long? ExpiresEpochSeconds { get; set; }

    /// <summary>How often the panel wants the list refreshed, seconds.</summary>
    public double? UpdateIntervalSeconds { get; set; }

    public string? SupportUrl { get; set; }

    public string? WebPageUrl { get; set; }

    public string? Announcement { get; set; }

    /// <summary>Bytes spent. A panel may answer with sizes near
    /// <c>long.MaxValue</c>, so the sum saturates instead of wrapping.</summary>
    public long? Used
    {
        get
        {
            if (Uploaded is null && Downloaded is null) return null;
            var a = Uploaded ?? 0;
            var b = Downloaded ?? 0;
            return Sat.Add(a, b);
        }
    }

    public bool IsUnlimited => (Total ?? 0) <= 0;

    public long? Remaining
    {
        get
        {
            if (Total is not { } allowed || allowed <= 0) return null;
            // Negative counters are a lie, not a credit: clamping them first
            // keeps the subtraction in range instead of overflowing upward.
            var spent = Math.Max(Used ?? 0, 0);
            return Math.Max(Sat.Sub(allowed, spent), 0);
        }
    }

    /// <summary>0…1 of the allowance used; null when unlimited. Clamped at both
    /// ends, not just the top: <see cref="Used"/> refuses to overflow and
    /// <see cref="Remaining"/> treats negative counters as a lie, and this is the
    /// value the UI multiplies by 100 and turns into an integer — a panel
    /// answering `upload=-99999999999999999999` (which the parser bounds to
    /// <c>long.MinValue</c>) made the fraction about −9.2e18, and the traffic row
    /// trapped instead of reading 0 %.</summary>
    public double? UsedFraction
    {
        get
        {
            if (Total is not { } allowed || allowed <= 0) return null;
            return Math.Max(0, Math.Min((Used ?? 0) / (double)allowed, 1));
        }
    }

    /// <summary>Worth a word: out of time within three days, or past 90 % of
    /// the allowance.</summary>
    public bool NeedsAttention(long nowEpochSeconds)
    {
        if (ExpiresEpochSeconds is { } expires && expires - nowEpochSeconds < 3 * 86_400) return true;
        // `>=`, not `>`: the same comparison the reminder planner and the
        // "already warned" filter use, and with `>` a plan sitting at exactly 90 %
        // was counted as warned and then never planned a reminder at all.
        if (UsedFraction is { } fraction && fraction >= 0.9) return true;
        return false;
    }

    /// <summary>From raw response headers, any capitalization; null when the
    /// panel said nothing at all.</summary>
    public static SubscriptionInfo? Parse(IReadOnlyDictionary<string, string> headers)
    {
        // First occurrence wins, matching Foundation's
        // `Dictionary(…, uniquingKeysWith: { first, _ in first })`.
        var lowered = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var (key, value) in headers)
            if (!lowered.ContainsKey(key.ToLowerInvariant())) lowered[key.ToLowerInvariant()] = value;

        string? Value(string name) =>
            lowered.TryGetValue(name, out var raw)
            && Foundation.TrimSpaceLike(raw).Length > 0
                ? Foundation.TrimSpaceLike(raw)
                : null;

        long? uploaded = null, downloaded = null, total = null, expires = null;
        if (Value("subscription-userinfo") is { } userinfo)
        {
            foreach (var pair in userinfo.Split(';'))
            {
                var parts = pair.Split(new[] { '=' }, 2);
                if (parts.Length != 2) continue;
                if (SwiftDouble.Parse(Foundation.TrimFoundationSpaces(parts[1])) is not { } number) continue;
                if (!double.IsFinite(number)) continue;                var amount = RoundToLong(number);
                switch (Foundation.TrimFoundationSpaces(parts[0]).ToLowerInvariant())
                {
                    case "upload": uploaded = amount; break;
                    case "download": downloaded = amount; break;
                    case "total": total = amount; break;
                    // Assigned unconditionally, as Swift does: a second
                    // `expire=0` RESETS the deadline rather than leaving the
                    // earlier one in place.
                    case "expire": expires = amount > 0 ? amount : null; break;
                }
            }
        }

        // `> 0` alone lets `inf` through (`profile-update-interval: 1e400`), and
        // one infinity in these headers is enough to break persistence on
        // macOS/iOS, where the JSON encoder throws on a non-finite Double and
        // silently drops EVERY panel's headers.
        double? interval = null;
        if (Value("profile-update-interval") is { } hoursText &&
            SwiftDouble.Parse(hoursText) is { } hours && hours > 0)
        {
            var stretched = hours * 3600;
            if (double.IsFinite(stretched)) interval = stretched;
        }

        var info = new SubscriptionInfo
        {
            Title = Value("profile-title") is { } title ? Text(title) : null,
            Uploaded = uploaded,
            Downloaded = downloaded,
            Total = total,
            ExpiresEpochSeconds = expires,
            UpdateIntervalSeconds = interval,
            SupportUrl = Value("support-url") is { } support ? Link(support) : null,
            WebPageUrl = Value("profile-web-page-url") is { } web ? Link(web) : null,
            Announcement = Value("announce") is { } announce ? Text(announce) : null,
        };
        return info.Equals(new SubscriptionInfo()) ? null : info;
    }

    /// <summary>`base64:…` or plain text, sometimes percent-encoded; header
    /// values arrive decoded as Latin-1 while panels send UTF-8.</summary>
    public static string Text(string raw)
    {
        var value = RepairedUtf8(raw);
        if (value.StartsWith("base64:", StringComparison.OrdinalIgnoreCase))
        {
            var payload = value[7..].Replace('-', '+').Replace('_', '/');
            payload = payload.PadRight(payload.Length + (4 - payload.Length % 4) % 4, '=');
            if (TryDecodeBase64(payload, out var bytes) && Foundation.Utf8(bytes) is { } decoded)
                return Foundation.TrimSpaceLike(decoded);
        }
        return Foundation.PercentDecode(value) ?? value;
    }

    /// <summary>Swift's `number.rounded()` (half away from zero) then a clamped
    /// `Int64` — no trap either way.</summary>
    internal static long RoundToLong(double number)
    {
        var rounded = number >= 0 ? Math.Floor(number + 0.5) : Math.Ceiling(number - 0.5);
        if (rounded >= long.MaxValue) return long.MaxValue;
        if (rounded <= (double)long.MinValue) return long.MinValue;
        return (long)rounded;
    }

    /// <summary>Latin-1-looking text that is really UTF-8 read one byte at a
    /// time — how a header arrives when the panel sends Cyrillic and the
    /// transport decodes it as ISO-8859-1.</summary>
    private static string RepairedUtf8(string value)
    {
        var anyHigh = false;
        foreach (var c in value)
            if (c > 0x7F) { anyHigh = true; break; }
        if (!anyHigh) return value;
        foreach (var c in value)
            if (c > 0xFF) return value;
        var bytes = new byte[value.Length];
        for (var i = 0; i < value.Length; i++) bytes[i] = (byte)value[i];
        return Foundation.Utf8(bytes) ?? value;
    }

    private static readonly string[] LinkSchemes = { "https", "http", "tg" };

    /// <summary>`URL(string:)` plus the scheme allowlist the Swift side applies.
    /// A scheme the transport would run (javascript, file) is dropped here
    /// rather than handed to a browser.</summary>
    private static string? Link(string raw)
    {
        foreach (var c in raw)
            if (c <= ' ' || c == (char)0x7F) return null;
        var colon = raw.IndexOf(':');
        if (colon <= 0) return null;
        var scheme = raw[..colon];
        if (!(scheme[0] >= 'A' && scheme[0] <= 'Z' || scheme[0] >= 'a' && scheme[0] <= 'z')) return null;
        for (var i = 1; i < scheme.Length; i++)
        {
            var c = scheme[i];
            if (!(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' ||
                  c == '+' || c == '.' || c == '-'))
                return null;
        }
        return Array.IndexOf(LinkSchemes, scheme.ToLowerInvariant()) >= 0 ? raw : null;
    }

    private static bool TryDecodeBase64(string payload, out byte[] bytes)
    {
        try
        {
            bytes = Convert.FromBase64String(payload);
            return true;
        }
        catch (FormatException)
        {
            bytes = Array.Empty<byte>();
            return false;
        }
    }

    public bool Equals(SubscriptionInfo? other) =>
        other is not null &&
        Title == other.Title && Uploaded == other.Uploaded && Downloaded == other.Downloaded &&
        Total == other.Total && ExpiresEpochSeconds == other.ExpiresEpochSeconds &&
        UpdateIntervalSeconds == other.UpdateIntervalSeconds && SupportUrl == other.SupportUrl &&
        WebPageUrl == other.WebPageUrl && Announcement == other.Announcement;

    public override bool Equals(object? obj) => Equals(obj as SubscriptionInfo);

    public override int GetHashCode() =>
        HashCode.Combine(
            HashCode.Combine(Title, Uploaded, Downloaded, Total, ExpiresEpochSeconds),
            HashCode.Combine(UpdateIntervalSeconds, SupportUrl, WebPageUrl, Announcement));
}

/// <summary>Saturating 64-bit addition/subtraction — Swift's
/// `addingReportingOverflow`/`subtractingReportingOverflow` pair, whose callers
/// clamp rather than trap.</summary>
internal static class Sat
{
    public static long Add(long a, long b)
    {
        var sum = a + b;
        // Overflow shows up as the sum disagreeing in sign with both addends.
        if (((a ^ sum) & (b ^ sum)) < 0) return a > 0 ? long.MaxValue : long.MinValue;
        return sum;
    }

    public static long Sub(long a, long b)
    {
        var difference = a - b;
        if (((a ^ b) & (a ^ difference)) < 0) return a > 0 ? long.MaxValue : long.MinValue;
        return difference;
    }
}
