using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AnemiaApp;

/// <summary>
/// Client for the privileged <c>AnemiaHelper</c> named-pipe JSON service.
/// The helper owns everything the unprivileged app must not touch: the
/// wintun adapter, route table, and the fail-closed firewall kill switch.
/// One short-lived pipe connection per command — helpers restart, and a
/// per-command connection can't wedge the app on a half-dead pipe.
/// </summary>
public sealed class HelperClient
{
    private readonly string _pipeName;

    public HelperClient(string? pipeName = null)
    {
        _pipeName = pipeName ?? "anemia-helper";
    }

    /// <summary>True when the helper service answers a ping. Cheap: the pipe
    /// connect itself fails fast when nothing is listening.</summary>
    public async Task<bool> IsAvailableAsync(CancellationToken ct)
    {
        var reply = await SendAsync(new JsonObject { ["cmd"] = "ping" }, ct);
        return reply is not null && reply["ok"]?.GetValue<bool>() == true;
    }

    /// <summary>Spawn the helper elevated if it isn't answering yet. The UAC
    /// prompt is part of the deal (route/firewall work needs admin); the
    /// helper repairs any crash-orphaned tunnel state on boot, so a duplicate
    /// launch is harmless. Returns false when the user declines elevation or
    /// the binary is missing.</summary>
    public async Task<bool> LaunchIfMissingAsync(CancellationToken ct)
    {
        if (await IsAvailableAsync(ct)) return true;
        var helperPath = Path.Combine(AppContext.BaseDirectory, "AnemiaHelper.exe");
        if (!File.Exists(helperPath)) return false;
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = helperPath,
                UseShellExecute = true,
                Verb = "runas", // triggers UAC
            });
        }
        catch (System.ComponentModel.Win32Exception)
        {
            return false; // user declined the prompt
        }
        // Wait for the pipe to come up; the helper also spends its first
        // moments repairing any orphaned tunnel state.
        for (var attempt = 0; attempt < 20; attempt++)
        {
            await Task.Delay(250, ct);
            if (await IsAvailableAsync(ct)) return true;
        }
        return false;
    }

    /// <summary>Bring the tunnel up: create the wintun adapter, spawn tun2socks
    /// pointed at the app's SOCKS inbound, install the default route via the
    /// tunnel gateway plus a /32 bypass route for the server's own IP, arm the
    /// kill switch if requested, and keep <paramref name="bypass"/> — the local
    /// destinations as the parser normalized them — off it. The helper parses
    /// those lines again itself: this process is not the authority on what may
    /// be routed around the VPN.</summary>
    public Task<JsonObject?> StartTunnelAsync(
        int socksPort, string? serverIp, bool killSwitch, IReadOnlyList<string> bypass,
        CancellationToken ct) =>
        SendAsync(new JsonObject
        {
            ["cmd"] = "start-tunnel",
            ["socksPort"] = socksPort,
            ["serverIp"] = serverIp,
            ["killSwitch"] = killSwitch,
            ["bypass"] = Lines(bypass),
        }, ct);

    /// <summary>Replace the bypass routes of a running tunnel.</summary>
    public Task<JsonObject?> ApplyBypassAsync(IReadOnlyList<string> bypass, CancellationToken ct) =>
        SendAsync(new JsonObject
        {
            ["cmd"] = "apply-bypass",
            ["bypass"] = Lines(bypass),
        }, ct);

    /// <summary>Re-pin the bypass routes after a gateway change or on the
    /// heartbeat: names are resolved again, nothing that is up comes down.</summary>
    public Task<JsonObject?> ReassertBypassAsync(CancellationToken ct) =>
        SendAsync(new JsonObject { ["cmd"] = "reassert-bypass" }, ct);

    private static JsonArray Lines(IReadOnlyList<string> lines)
    {
        var array = new JsonArray();
        foreach (var line in lines) array.Add(JsonValue.Create(line));
        return array;
    }

    public Task<JsonObject?> StopTunnelAsync(CancellationToken ct) =>
        SendAsync(new JsonObject { ["cmd"] = "stop-tunnel" }, ct);

    public Task<JsonObject?> StatusAsync(CancellationToken ct) =>
        SendAsync(new JsonObject { ["cmd"] = "status" }, ct);

    /// <summary>Send one JSON command and read one JSON-line reply, with a
    /// bounded wait: a hung elevated process must not freeze the connect flow.
    /// Any transport failure folds into a null reply — callers treat that as
    /// "helper unavailable" and fall back to proxy-only mode.</summary>
    public async Task<JsonObject?> SendAsync(JsonObject command, CancellationToken ct)
    {
        command["v"] = 1;
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(TimeSpan.FromSeconds(10));
            await using var pipe = new NamedPipeClientStream(
                ".", _pipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
            await pipe.ConnectAsync(3000, timeout.Token);
            using var writeCts = CancellationTokenSource.CreateLinkedTokenSource(timeout.Token);
            writeCts.CancelAfter(TimeSpan.FromSeconds(10));
            var payload = Encoding.UTF8.GetBytes(command.ToJsonString() + "\n");
            await pipe.WriteAsync(payload, writeCts.Token);
            await pipe.FlushAsync(writeCts.Token);

            // Read one newline-terminated reply with a hard cap so a hostile
            // or wedged helper can't pin the app in an unbounded read.
            var buf = new byte[64 * 1024];
            var total = 0;
            while (total < buf.Length)
            {
                var n = await pipe.ReadAsync(buf.AsMemory(total, buf.Length - total), timeout.Token);
                if (n == 0) break;
                total += n;
                if (buf.AsSpan(0, total).Contains((byte)'\n')) break;
            }
            var text = Encoding.UTF8.GetString(buf, 0, total).Trim();
            if (text.Length == 0) return null;
            return JsonNode.Parse(text) as JsonObject;
        }
        catch (OperationCanceledException)
        {
            return null;
        }
        catch (IOException)
        {
            return null;
        }
        catch (ObjectDisposedException)
        {
            return null;
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

/// <summary>
/// User-level system proxy (WinINet), mirroring what the macOS app did with
/// SCNetworkConfiguration. Setting <c>ProxyEnable/ProxyServer</c> under
/// HKCU\...\Internet Settings needs no elevation. A full kill of the
/// proxy state is mandatory on every disconnect: a stale proxy pointing at
/// a dead local port blackholes the user's browsing.
/// </summary>
public static class SystemProxyManager
{
    private const string KeyPath = @"Software\Microsoft\Windows\CurrentVersion\Internet Settings";

    public static bool Set(int socksPort)
    {
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(KeyPath, writable: true);
            if (key is null) return false;
            key.SetValue("ProxyEnable", 1, Microsoft.Win32.RegistryValueKind.DWord);
            key.SetValue("ProxyServer", $"socks=127.0.0.1:{socksPort}", Microsoft.Win32.RegistryValueKind.String);
            // Override list: loopback is where the proxy itself lives; leave
            // every other host to the proxy.
            key.SetValue("ProxyOverride", "localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*;<local>",
                Microsoft.Win32.RegistryValueKind.String);
            Refresh();
            return true;
        }
        catch (System.Security.SecurityException) { return false; }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
    }

    public static bool Clear()
    {
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(KeyPath, writable: true);
            if (key is null) return false;
            key.SetValue("ProxyEnable", 0, Microsoft.Win32.RegistryValueKind.DWord);
            Refresh();
            return true;
        }
        catch (System.Security.SecurityException) { return false; }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
    }

    [System.Runtime.InteropServices.DllImport("wininet.dll", SetLastError = true)]
    private static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);

    /// <summary>Broadcast the change so running processes pick it up without a
    /// re-login (WinINet caches the settings until told otherwise).</summary>
    private static void Refresh()
    {
        const int internetOptionSettingsChanged = 39;
        const int internetOptionRefresh = 37;
        _ = InternetSetOption(IntPtr.Zero, internetOptionSettingsChanged, IntPtr.Zero, 0);
        _ = InternetSetOption(IntPtr.Zero, internetOptionRefresh, IntPtr.Zero, 0);
    }
}