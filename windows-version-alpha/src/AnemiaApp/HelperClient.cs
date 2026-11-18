using System.ComponentModel;
using System.Diagnostics;
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
        _pipeName = pipeName ?? "anemia-vpn-helper";
    }

    /// <summary>True when the helper service answers a ping. Cheap: the pipe
    /// connect itself fails fast when nothing is listening.</summary>
    public async Task<bool> IsAvailableAsync(CancellationToken ct)
    {
        var reply = await SendAsync(new JsonObject { ["cmd"] = "ping" }, ct);
        return reply is not null && reply["ok"]?.GetValue<bool>() == true;
    }

    /// <summary>Spawn the helper elevated if it isn't answering yet. The UAC
    /// prompt is part of the deal (route/firewall work needs admin).</summary>
    public async Task EnsureAvailableAsync(CancellationToken ct)
    {
        if (await IsAvailableAsync(ct)) return;
        ct.ThrowIfCancellationRequested();
        var helperPath = Path.Combine(AppContext.BaseDirectory, "AnemiaHelper.exe");
        if (!File.Exists(helperPath)) throw new IOException("В папке Anemia отсутствует AnemiaHelper.exe");
        try
        {
            using var process = await Task.Run(() => Process.Start(new ProcessStartInfo
            {
                FileName = helperPath,
                UseShellExecute = true,
                Verb = "runas", // triggers UAC
            }), ct);
            if (process is null) throw new IOException("Windows не запустила помощник Anemia");
        }
        catch (Win32Exception error) when (error.NativeErrorCode == 1223)
        {
            throw new IOException("Запрос прав администратора отменён. Включите VPN ещё раз.", error);
        }
        catch (Win32Exception error)
        {
            throw new IOException("Windows не запустила помощник Anemia. " + error.Message, error);
        }

        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(TimeSpan.FromSeconds(10));
        while (!deadline.IsCancellationRequested)
        {
            try { await Task.Delay(250, deadline.Token); }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested) { break; }
            if (await IsAvailableAsync(deadline.Token)) return;
        }
        ct.ThrowIfCancellationRequested();
        throw new IOException("Помощник Anemia запустился, но не ответил. Повторите подключение.");
    }

    /// <summary>Bring the tunnel up: create the wintun adapter, spawn tun2socks
    /// pointed at the app's SOCKS inbound, install the default route via the
    /// tunnel gateway plus a /32 bypass route for the server's own IP, arm the
    /// kill switch if requested, and keep <paramref name="bypass"/> — the local
    /// destinations as the parser normalized them — off it. The helper parses
    /// those lines again itself: this process is not the authority on what may
    /// be routed around the VPN.</summary>
    public Task<JsonObject?> StartTunnelAsync(
        int socksPort, string serverIp, int serverPort, bool killSwitch, IReadOnlyList<string> bypass,
        CancellationToken ct) =>
        SendAsync(new JsonObject
        {
            ["cmd"] = "start-tunnel",
            ["socksPort"] = socksPort,
            ["serverIp"] = serverIp,
            ["serverPort"] = serverPort,
            ["killSwitch"] = killSwitch,
            ["bypass"] = Lines(bypass),
        }, ct);

    public Task<JsonObject?> StartAwgAsync(
        AnemiaCore.ProxyServer server, string serverIp, bool killSwitch, bool adBlock, IReadOnlyList<string> bypass,
        CancellationToken ct)
    {
        var profile = server.WgProfile ?? throw new IOException("В профиле AmneziaWG нет настроек пира");
        var problems = AnemiaCore.AmneziaWgConfigBuilder.Validate(server, profile.Mtu ?? 1280);
        if (problems.Count != 0) throw new IOException($"Профиль AmneziaWG: {problems[0]}");
        return SendAsync(new JsonObject
        {
            ["cmd"] = "start-tunnel",
            ["serverIp"] = serverIp,
            ["serverPort"] = server.Port,
            ["killSwitch"] = killSwitch,
            ["bypass"] = Lines(bypass),
            ["uapi"] = AnemiaCore.AmneziaWgConfigBuilder.MakeUapiSetScript(server, serverIp),
            ["addresses"] = Lines(AnemiaCore.AmneziaWgConfigBuilder.TunnelAddresses(server)),
            ["dns"] = Lines(adBlock ? new[] { "94.140.14.14", "94.140.15.15" } :
                profile.ResolverAddresses.Count > 0 ? profile.ResolverAddresses : new[] { "1.1.1.1" }),
            ["mtu"] = profile.Mtu ?? 1280,
        }, ct);
    }

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

    public Task<JsonObject?> StopTunnelAsync(CancellationToken ct, bool keepFirewall = false) =>
        SendAsync(new JsonObject { ["cmd"] = "stop-tunnel", ["keepFirewall"] = keepFirewall }, ct);

    public Task<JsonObject?> StatusAsync(CancellationToken ct) =>
        SendAsync(new JsonObject { ["cmd"] = "status" }, ct);

    /// <summary>Send one JSON command and read one JSON-line reply, with a
    /// bounded wait: a hung elevated process must not freeze the connect flow.
    /// Any transport failure folds into a null reply for the caller to handle.</summary>
    public async Task<JsonObject?> SendAsync(JsonObject command, CancellationToken ct)
    {
        command["v"] = 1;
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(TimeSpan.FromSeconds(command["cmd"]?.GetValue<string>() == "start-tunnel" ? 55 : 10));
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
        catch (TimeoutException)
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
