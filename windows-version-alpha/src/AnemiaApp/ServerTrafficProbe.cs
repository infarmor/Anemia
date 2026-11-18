using System.ComponentModel;
using System.IO;
using System.Net;
using System.Net.Sockets;
using AnemiaCore;

namespace AnemiaApp;

internal static class ServerTrafficProbe
{
    internal static bool Supports(ProxyServer server) =>
        server.Proto is ProxyProtocol.Vless or ProxyProtocol.Vmess or ProxyProtocol.Ss or ProxyProtocol.Trojan;

    internal static async Task<int?> CheckAsync(ProxyServer server, AntiCensorshipOptions options,
                                                 bool blockAds, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        var address = server.Address.Trim('[', ']');
        using var dnsDeadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        dnsDeadline.CancelAfter(TimeSpan.FromSeconds(3));
        IPAddress? endpoint;
        try
        {
            if (!IPAddress.TryParse(address, out endpoint))
            {
                var resolved = await Dns.GetHostAddressesAsync(address, dnsDeadline.Token);
                endpoint = resolved.FirstOrDefault(ip => ip.AddressFamily == AddressFamily.InterNetwork)
                    ?? resolved.FirstOrDefault();
            }
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested) { return null; }
        catch (SocketException) { return null; }

        if (endpoint is null) return null;
        ct.ThrowIfCancellationRequested();

        // The probe has its own controller, ports and config. The privileged
        // helper is never involved, so probing leaves tunnel routes untouched.
        var engine = new XrayController { DialerInterface = PhysicalInterface.Detect() };
        try
        {
            await engine.StartAsync(server, options, endpoint.ToString(), blockAds);
            ct.ThrowIfCancellationRequested();
            var result = await ProxyHealth.CheckAsync(engine.SocksPort, ct: ct);
            ct.ThrowIfCancellationRequested();
            return result;
        }
        catch (XrayException ex) when (ex.Kind != XrayErrorKind.BinaryNotFound) { return null; }
        catch (ConfigBuilderException) { return null; }
        catch (IOException) { return null; }
        catch (Win32Exception) { return null; }
        finally
        {
            engine.Stop();
        }
    }
}
