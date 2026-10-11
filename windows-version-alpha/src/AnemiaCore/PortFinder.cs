using System.Net;
using System.Net.Sockets;

namespace AnemiaCore;

/// <summary>
/// Finds free local TCP ports so the engine's inbounds never fail to bind when
/// the default ports are already taken (another instance, another app, a
/// lingering process). Improves connection reliability.
/// </summary>
public static class PortFinder
{
    /// <summary>Ask the OS for a free ephemeral port by binding 127.0.0.1:0.</summary>
    public static int? FreePort()
    {
        try
        {
            using var sock = new TcpListener(IPAddress.Loopback, 0);
            sock.Start();
            var port = ((IPEndPoint)sock.LocalEndpoint).Port;
            sock.Stop();
            return port;
        }
        catch (SocketException)
        {
            return null;
        }
    }

    /// <summary>Whether a specific TCP port on 127.0.0.1 is currently bindable.</summary>
    public static bool IsFree(int port)
    {
        if (port <= 0 || port >= 65536) return false;
        TcpListener? sock = null;
        try
        {
            sock = new TcpListener(IPAddress.Loopback, port);
            sock.Start();
            return true;
        }
        catch (SocketException)
        {
            return false;
        }
        finally
        {
            try { sock?.Stop(); } catch { /* best effort */ }
        }
    }

    /// <summary>
    /// Whether something on 127.0.0.1:port currently accepts TCP connections.
    /// Complements IsFree (bind probe) — this is the engine-liveness probe used
    /// after spawning xray to confirm its inbound actually opened.
    /// </summary>
    public static bool CanConnect(int port, int timeoutMs = 200)
    {
        if (port <= 0 || port >= 65536) return false;
        try
        {
            using var client = new TcpClient();
            var ar = client.BeginConnect(IPAddress.Loopback, port, null, null);
            // Non-blocking-equivalent wait so a firewalled/half-open port
            // can't stall the caller.
            if (!ar.AsyncWaitHandle.WaitOne(timeoutMs))
            {
                try { client.Close(); } catch { }
                return false;
            }
            client.EndConnect(ar);
            return true;
        }
        catch (SocketException)
        {
            return false;
        }
        catch (ObjectDisposedException)
        {
            return false;
        }
        catch (InvalidOperationException)
        {
            return false;
        }
    }

    /// <summary>
    /// The preferred port if it's free, otherwise an OS-assigned free port,
    /// avoiding any in <paramref name="exclude"/>.
    /// The last-resort fallback returns the busy preferred anyway: callers pin
    /// it into the config and probe it (WaitForPort), so a colliding start
    /// still fails with a clear "did not open SOCKS port" reason — whereas a
    /// made-up port number here would silently disagree with the one the
    /// config actually carries.
    /// </summary>
    public static int Pick(int preferred, HashSet<int>? exclude = null)
    {
        if (exclude is null || !exclude.Contains(preferred))
        {
            if (IsFree(preferred)) return preferred;
        }
        for (var i = 0; i < 20; i++)
        {
            if (FreePort() is { } p && (exclude is null || !exclude.Contains(p))) return p;
        }
        return preferred;
    }
}