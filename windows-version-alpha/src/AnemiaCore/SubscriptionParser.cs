namespace AnemiaCore;

/// <summary>
/// Parses subscription payloads into a list of <see cref="ProxyServer"/>.
/// The common v2ray/xray subscription format is a base64 blob whose decoded
/// text is one share link per line. Some panels serve the links as plain text
/// (already decoded). This handles both, and skips lines it can't parse rather
/// than failing the whole import.
/// </summary>
public static class SubscriptionParser
{
    public sealed record SubscriptionResult(List<ProxyServer> Servers, List<(string Line, ParseErrorException Error)> Failures);

    /// <summary>Parse a raw subscription body (as fetched from a subscription
    /// URL, or pasted by the user).</summary>
    public static SubscriptionResult Parse(string body)
    {
        var trimmed = Foundation.TrimSpaceLike(body);
        var servers = new List<ProxyServer>();
        var failures = new List<(string, ParseErrorException)>();
        if (trimmed.Length == 0) return new SubscriptionResult(servers, failures);

        // A body with no scheme marker is a base64 blob; a blob that decodes to
        // nothing is garbage, not "an empty subscription" — returning all-empty
        // used to wipe the saved list on a panel outage.
        var undecodable = false;
        string text;
        if (trimmed.Contains("://")) text = trimmed;
        else if (Base64.DecodeToString(trimmed) is { } decoded) text = decoded;
        else { text = trimmed; undecodable = true; }

        // One entry per distinct server: panels hand the same link out on
        // several lines, which showed up as duplicate rows, doubled every probe
        // and grew the state file on each refresh. `identityKey` is the same
        // "is this the same server" test carryingIDs already uses.
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var rawLine in SplitOnSwiftNewlines(text))
        {
            var line = Foundation.TrimFoundationSpaces(rawLine);
            if (line.Length == 0 || !line.Contains("://")) continue;
            try
            {
                var server = ShareLinkParser.Parse(line);
                if (seen.Add(server.IdentityKey)) servers.Add(server);
            }
            catch (ParseErrorException e)
            {
                failures.Add((line, e));
            }
            catch (Exception e)
            {
                failures.Add((line, new ParseErrorException(ParseErrorKind.MalformedUri, e.Message)));
            }
        }

        if (undecodable && servers.Count == 0 && failures.Count == 0)
        {
            failures.Add((trimmed[..Math.Min(80, trimmed.Length)], new ParseErrorException(
                ParseErrorKind.MalformedUri,
                "subscription body is not decodable base64 and contains no share links")));
        }
        return new SubscriptionResult(servers, failures);
    }

    /// <summary>Swift cuts the body with <c>Character.isNewline</c>, which is not
    /// 'LF' and 'CR': a body whose lines end in VT or FF would otherwise arrive
    /// as one giant "link" — one server with the rest of the subscription glued
    /// onto its name.</summary>
    private static List<string> SplitOnSwiftNewlines(string text)
    {
        var lines = new List<string>();
        var start = 0;
        for (var i = 0; i < text.Length; i++)
        {
            if (!Foundation.IsSwiftNewline(text[i])) continue;
            lines.Add(text[start..i]);
            start = i + 1;
        }
        if (start < text.Length) lines.Add(text[start..]);
        return lines;
    }

    /// <summary>
    /// Carry server IDs across a refresh: an entry whose identity (protocol,
    /// endpoint, credential) was already listed keeps that entry's id, so the
    /// selection and the ping history survive an update. Each old id is handed
    /// out at most once — duplicate ids break every id-keyed list — and the rest
    /// keep their own. Port of Swift's `SubscriptionParser.carryingIDs`.
    /// </summary>
    public static List<ProxyServer> CarryingIDs(IReadOnlyList<ProxyServer> old, IReadOnlyList<ProxyServer> fresh)
    {
        var pool = new Dictionary<string, Queue<Guid>>();
        foreach (var server in old)
        {
            if (!pool.TryGetValue(server.IdentityKey, out var ids)) pool[server.IdentityKey] = ids = new Queue<Guid>();
            ids.Enqueue(server.Id);
        }
        var used = new HashSet<Guid>();
        var result = new List<ProxyServer>(fresh.Count);
        foreach (var server in fresh)
        {
            if (pool.TryGetValue(server.IdentityKey, out var ids))
            {
                while (ids.Count > 0)
                {
                    var candidate = ids.Dequeue();
                    if (used.Add(candidate))
                    {
                        server.Id = candidate;
                        break;
                    }
                }
            }
            result.Add(server);
        }
        return result;
    }
}
/// <summary>What to do with a body a panel just answered with.</summary>
public enum RefreshVerdict
{
    /// <summary>Replace the stored list with this one (ids carried across).</summary>
    Applied,
    /// <summary>Nothing parsed and the headers say the term is past: the panel
    /// is expired, which the row should say out loud.</summary>
    Expired,
    /// <summary>Nothing parsed and no proof of why — an error page, a captive
    /// portal, a dead provider. The saved list stays.</summary>
    NoUsableServers,
}

public static class SubscriptionRules
{
    /// <summary>The one rule a refresh must never break: an empty result is a
    /// FAILED fetch, not "this provider lists no servers now". Storing the empty
    /// list wiped a good one — and the vanished-server check that follows then
    /// dropped the live session — on every provider outage. Port of the guard in
    /// macOS <c>AppState.refresh(_:)</c>.</summary>
    public static (RefreshVerdict Verdict, List<ProxyServer> Servers) DecideRefresh(
        IReadOnlyList<ProxyServer> stored, SubscriptionParser.SubscriptionResult parsed, SubscriptionInfo? info,
        long nowEpochSeconds)
    {
        if (parsed.Servers.Count == 0)
        {
            var verdict = info?.ExpiresEpochSeconds is { } expires && expires < nowEpochSeconds
                ? RefreshVerdict.Expired
                : RefreshVerdict.NoUsableServers;
            return (verdict, stored.ToList());
        }
        return (RefreshVerdict.Applied, SubscriptionParser.CarryingIDs(stored, parsed.Servers));
    }
}
