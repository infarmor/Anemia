using System.Net;
using System.Net.Http;
using System.Diagnostics;

namespace AnemiaCore;

/// <summary>
/// Confirms the tunnel actually carries traffic by fetching a tiny 204 endpoint
/// through the local SOCKS proxy, and reports the real round-trip latency.
/// </summary>
public static class ProxyHealth
{
    private static SocketsHttpHandler SocksHandler(int socksPort, TimeSpan timeout)
    {
        var handler = new SocketsHttpHandler
        {
            ConnectTimeout = timeout,
            UseProxy = true,
            Proxy = new WebProxy($"socks5://127.0.0.1:{socksPort}"),
            AllowAutoRedirect = false,
        };
        return handler;
    }

    /// <summary>Health check through the SOCKS tunnel; returns the RTT in ms or
    /// null when the endpoint is unreachable.</summary>
    public static async Task<int?> CheckAsync(int socksPort, TimeSpan? timeout = null, CancellationToken ct = default)
    {
        timeout ??= TimeSpan.FromSeconds(6);
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(timeout.Value);
        using var handler = SocksHandler(socksPort, timeout.Value);
        using var client = new HttpClient(handler, disposeHandler: false);
        client.Timeout = timeout.Value;
        try
        {
            var start = Stopwatch.GetTimestamp();
            using var resp = await client.GetAsync(
                "https://cp.cloudflare.com/generate_204",
                HttpCompletionOption.ResponseHeadersRead, cts.Token);
            if (resp.StatusCode != HttpStatusCode.NoContent) return null;
            return (int)Stopwatch.GetElapsedTime(start).TotalMilliseconds;
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>
    /// One-shot capacity probe: download `bytes` through the live SOCKS proxy
    /// and return the achieved throughput in bytes/sec, or null on failure.
    /// Latency says how responsive a server is; this says how fast it is — a
    /// server can ping well yet be throttled to a trickle. Kept small (256 KB)
    /// and bounded so it barely costs the user any traffic.
    /// </summary>
    public static async Task<long?> ThroughputAsync(int socksPort, int bytes = 262_144, TimeSpan? timeout = null, CancellationToken ct = default)
    {
        timeout ??= TimeSpan.FromSeconds(8);
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(timeout.Value);
        using var handler = SocksHandler(socksPort, timeout.Value);
        using var client = new HttpClient(handler, disposeHandler: false);
        client.Timeout = timeout.Value;
        try
        {
            var start = Stopwatch.GetTimestamp();
            using var resp = await client.GetAsync(
                $"https://speed.cloudflare.com/__down?bytes={bytes}",
                HttpCompletionOption.ResponseContentRead, cts.Token);
            if ((int)resp.StatusCode is < 200 or > 299) return null;
            var data = await resp.Content.ReadAsByteArrayAsync(cts.Token);
            if (data.Length == 0) return null;
            var secs = Stopwatch.GetElapsedTime(start).TotalSeconds;
            if (secs <= 0) return null;
            return (long)(data.Length / secs);
        }
        catch (Exception)
        {
            return null;
        }
    }
}
