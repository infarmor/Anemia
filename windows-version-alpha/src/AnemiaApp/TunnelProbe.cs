using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace AnemiaApp;

internal static class TunnelProbe
{
    private static NetworkInterface? Adapter() => NetworkInterface.GetAllNetworkInterfaces()
        .FirstOrDefault(adapter => adapter.Name.Equals("anemia", StringComparison.OrdinalIgnoreCase)
            && adapter.OperationalStatus == OperationalStatus.Up);

    public static (long Up, long Down)? Traffic()
    {
        var stats = Adapter()?.GetIPStatistics();
        return stats is null ? null : (stats.BytesSent, stats.BytesReceived);
    }

    public static async Task<int?> CheckAsync(CancellationToken ct)
    {
        var properties = Adapter()?.GetIPProperties();
        if (properties is null) return null;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(5));
        var targets = new[] { IPAddress.Parse("1.1.1.1"), IPAddress.Parse("2606:4700:4700::1111") };
        var tasks = new List<Task<int?>>();
        foreach (var target in targets)
        {
            var family = target.AddressFamily;
            var source = properties.UnicastAddresses.FirstOrDefault(entry =>
                entry.Address.AddressFamily == family && !entry.Address.IsIPv6LinkLocal);
            var index = family == AddressFamily.InterNetwork
                ? properties.GetIPv4Properties()?.Index : properties.GetIPv6Properties()?.Index;
            if (source is not null && index is { } actual)
                tasks.Add(CheckPathAsync(target, source.Address, actual, timeout.Token));
        }

        while (tasks.Count > 0)
        {
            var result = await Task.WhenAny(tasks);
            if (await result is { } rtt)
            {
                timeout.Cancel();
                return rtt;
            }
            tasks.Remove(result);
        }
        return null;
    }

    private static async Task<int?> CheckPathAsync(IPAddress target, IPAddress source, int index, CancellationToken ct)
    {
        var ipv4 = target.AddressFamily == AddressFamily.InterNetwork;
        using var handler = new SocketsHttpHandler
        {
            UseProxy = false,
            AllowAutoRedirect = false,
            ConnectCallback = async (_, token) =>
            {
                var socket = new Socket(source.AddressFamily, SocketType.Stream, ProtocolType.Tcp);
                try
                {
                    // Windows IP_UNICAST_IF is 31. IPv4 takes the index in network byte order.
                    var level = ipv4 ? SocketOptionLevel.IP : SocketOptionLevel.IPv6;
                    socket.SetSocketOption(level, (SocketOptionName)31, ipv4 ? IPAddress.HostToNetworkOrder(index) : index);
                    socket.Bind(new IPEndPoint(source, 0));
                    await socket.ConnectAsync(new IPEndPoint(target, 443), token);
                    return new NetworkStream(socket, ownsSocket: true);
                }
                catch
                {
                    socket.Dispose();
                    throw;
                }
            },
        };
        using var client = new HttpClient(handler);
        try
        {
            var host = ipv4 ? target.ToString() : $"[{target}]";
            var start = Stopwatch.GetTimestamp();
            using var reply = await client.GetAsync($"https://{host}/cdn-cgi/trace",
                HttpCompletionOption.ResponseHeadersRead, ct);
            return reply.IsSuccessStatusCode ? (int)Stopwatch.GetElapsedTime(start).TotalMilliseconds : null;
        }
        catch (Exception error) when (error is HttpRequestException or IOException or SocketException or OperationCanceledException)
        {
            return null;
        }
    }
}
