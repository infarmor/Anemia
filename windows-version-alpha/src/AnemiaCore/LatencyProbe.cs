using System.Diagnostics;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;

namespace AnemiaCore;

/// <summary>
/// Measures real round-trip latency to a server by timing a full TLS handshake.
/// A plain TCP-connect "ping" is unreliable whenever a system-wide TUN proxy in
/// fake-IP mode is active (sing-box / clash / Mihomo and friends): the local
/// tunnel answers every TCP SYN itself, so connect() returns in well under a
/// millisecond and every server reads "0 ms". A TLS handshake cannot be faked
/// locally — the tunnel has to relay ClientHello/ServerHello to the real
/// endpoint — so its timing reflects the true network path. It also mirrors
/// what the proxy actually does when you browse: these are TLS/Reality servers
/// on 443.
/// </summary>
public static class LatencyProbe
{
    /// <summary>
    /// Ping `count` times, returning each attempt's RTT in ms (null = failed /
    /// timed-out attempt) for jitter/loss statistics.
    /// `tls` picks the probe: a full TLS handshake (the default, for
    /// TLS/Reality servers on 443) or a plain TCP connect (for `security:
    /// none` servers, which don't speak TLS — a handshake probe would always
    /// "fail" them and hide them from ranking/auto-pick).
    /// `earlyAbortAfterFails`: stop probing after this many consecutive failed
    /// attempts — with many down servers in a subscription the round would
    /// otherwise spend most of its wall clock waiting on servers that were
    /// never going to answer.
    /// </summary>
    public static async Task<List<int?>> Sample(
        string host, int port, string? sni = null, int count = 5,
        TimeSpan? timeout = null, bool tls = true, int? earlyAbortAfterFails = null,
        CancellationToken ct = default)
    {
        timeout ??= TimeSpan.FromSeconds(4);
        var results = new List<int?>();
        var consecutiveFails = 0;
        for (var i = 0; i < Math.Max(1, count); i++)
        {
            ct.ThrowIfCancellationRequested();
            var r = await HandshakePing(host, port, sni, timeout.Value, tls, ct);
            results.Add(r);
            if (r is null)
            {
                consecutiveFails++;
                if (earlyAbortAfterFails is { } limit && consecutiveFails >= limit) break;
            }
            else
            {
                consecutiveFails = 0;
            }
        }
        return results;
    }

    /// <summary>One handshake/connect RTT in milliseconds, or null on
    /// failure/timeout. tls == true times a full TLS handshake; false times a
    /// TCP connect.</summary>
    public static async Task<int?> HandshakePing(
        string host, int port, string? sni = null,
        TimeSpan timeout = default, bool tls = true, CancellationToken ct = default)
    {
        if (timeout == default) timeout = TimeSpan.FromSeconds(4);
        if (string.IsNullOrEmpty(host) || port <= 0 || port > 65535) return null;

        // SNI so Reality/TLS servers steer the handshake to the right site —
        // but only for hostnames: SNI is defined as a DNS name, and several
        // servers hard-fail handshakes that present an IP literal. An IP host
        // just omits the extension.
        var sniName = sni ?? host;
        var useSni = !string.IsNullOrEmpty(sniName) && !DirectResolver.IsIPv4(sniName) && !sniName.Contains(':');

        try
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(timeout);
            var start = Stopwatch.GetTimestamp();
            using var client = new TcpClient();
            using (var reg = cts.Token.Register(() => client.Close()))
            {
                await client.ConnectAsync(host, port, cts.Token);
                if (tls)
                {
                    using var ssl = new SslStream(client.GetStream(), leaveInnerStreamOpen: false,
                        userCertificateValidationCallback: (_, _, _, _) => true);
                    // We only time the handshake — accept any certificate.
                    // These endpoints present camouflage/self-signed certs;
                    // validation isn't the point, and a rejection would just
                    // cost us the measurement.
                    await ssl.AuthenticateAsClientAsync(new SslClientAuthenticationOptions
                    {
                        TargetHost = useSni ? sniName : string.Empty,
                        EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13,
                        // No session resumption: every probe is a full
                        // handshake, so repeated samples measure the same
                        // thing (comparable jitter, no 0-RTT skew).
                        AllowTlsResume = false,
                    }, cts.Token);
                }
            }
            var ms = (long)Stopwatch.GetElapsedTime(start).TotalMilliseconds;
            return (int)ms;
        }
        catch (Exception)
        {
            return null;
        }
    }
}