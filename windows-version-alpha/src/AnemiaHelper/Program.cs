using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;
using AnemiaCore;

namespace AnemiaHelper;

/// <summary>
/// Privileged tunnel supervisor. Protocol: one JSON line in → one JSON line
/// out per connection, commands: ping / start-tunnel / stop-tunnel / status.
///
/// Design notes (mirroring the macOS LoaderHelper):
///  • The wintun adapter is created and owned by tun2socks (--device anemia),
///    so this process never links wintun.dll itself — one less native
///    dependency to pin and update.
///  • The kill switch is fail-closed: the firewall's default outbound policy
///    is flipped to block BEFORE the allow rules exist, so a crash between
///    steps leaves the machine sealed. Every mutation is idempotent and
///    reversible by <see cref="TearDownTunnel"/>, which runs both on clean
///    stop and on process start (repairing after a crash mid-tunnel).
///  • A /32 route for the server's real IP via the ORIGINAL default gateway
///    is installed first, before the tunnel claims the default route — the
///    engine's own dial to the server must survive 0.0.0.0/0 being captured.
/// </summary>
internal static class Program
{
    private const string TunnelDevice = "anemia";
    private const string PipeName = "anemia-helper";
    private const string FirewallRulePrefix = "Anemia KS";
    /// <summary>The adapter's own range and the fake-IP pool it sits in: a
    /// bypass overlapping either would send the tunnel's traffic to the
    /// physical gateway and cut the link it is trying to bypass.</summary>
    private static readonly string[] TunnelOwnedRanges = { "198.18.0.0/15" };

    private static readonly object Gate = new();
    private static Process? _tun2socks;
    private static bool _firewallArmed;
    private static (string RuleSuffix, string? ServerIp)? _tunnelState;
    private static readonly List<string> _addedRoutes = new();

    /// <summary>What the bypass owns: the planner keeps the routes it installed
    /// so a rule edit can come down before it goes up, and teardown can remove
    /// exactly this session's entries.</summary>
    private static readonly SplitTunnelPlan.State Bypass = new();

    /// <summary>Host routes pinned for the engine's own dial to the server. The
    /// bypass must not re-add over them (see SplitTunnelPlan.Env.ServerPinsV4).</summary>
    private static readonly List<string> ServerPinsV4 = new();
    private static readonly List<string> ServerPinsV6 = new();

    private static void Main()
    {
        // Repair pass: if a previous helper died mid-tunnel (crash, power
        // loss), its routes/firewall state is still armed — and _firewallArmed
        // is always false on a fresh boot, so TearDownTunnel alone would NOT
        // unseal the firewall. Disarm unconditionally: it's idempotent and
        // restores the Windows-default policy.
        TearDownTunnel();
        DisarmFirewall();

        while (true)
        {
            NamedPipeServerStream server;
            try
            {
                server = new NamedPipeServerStream(
                    PipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
            }
            catch (IOException)
            {
                // maxNumberOfServerInstances=1: a pipe already answers under
                // this name — a second helper instance would just sit here
                // forever serving nobody. Exit quietly instead.
                return;
            }
            using (server)
            {
                server.WaitForConnection();
                using var reader = new StreamReader(server, Encoding.UTF8);
                using var writer = new StreamWriter(server, new UTF8Encoding(false)) { AutoFlush = true };
                var line = reader.ReadLine();
                if (line is null) continue;
                var reply = Handle(line);
                writer.Write(reply + "\n");
            }
        }
    }

    private static string Handle(string line)
    {
        JsonObject? cmd;
        try
        {
            cmd = JsonNode.Parse(line) as JsonObject;
        }
        catch (System.Text.Json.JsonException)
        {
            return Reply(ok: false, "malformed command");
        }
        if (cmd is null) return Reply(ok: false, "malformed command");

        try
        {
            switch (cmd["cmd"]?.GetValue<string>())
            {
                case "ping":
                    return Reply(ok: true);
                case "status":
                    lock (Gate)
                        return Reply(ok: true, detail: _tunnelState is null
                            ? "idle"
                            : $"tunnel up (server {_tunnelState.Value.ServerIp ?? "?"}), " +
                              $"{Bypass.Installed.Count} bypass routes");
                case "start-tunnel":
                    return StartTunnel(cmd);
                case "stop-tunnel":
                    lock (Gate) TearDownTunnel();
                    return Reply(ok: true, detail: "tunnel down");
                case "apply-bypass":
                    return ApplyBypass(cmd);
                case "reassert-bypass":
                    return ReassertBypassCommand();
                default:
                    return Reply(ok: false, "unknown command");
            }
        }
        catch (Exception ex)
        {
            return Reply(ok: false, ex.Message);
        }
    }

    private static string Reply(bool ok, string? detail = null)
    {
        var node = new JsonObject { ["ok"] = ok };
        if (detail is not null) node["detail"] = detail;
        return node.ToJsonString();
    }

    private static string StartTunnel(JsonObject cmd)
    {
        var socksPort = cmd["socksPort"]?.GetValue<int>() ?? 0;
        var serverIp = cmd["serverIp"] is { } ip && ip.GetValue<string>().Length > 0
            ? ip.GetValue<string>() : null;
        var killSwitch = cmd["killSwitch"]?.GetValue<bool>() == true;
        var bypassLines = Strict.TextArray(cmd["bypass"]) ?? new List<string>();
        if (socksPort is < 1 or > 65535) return Reply(ok: false, "bad socks port");

        lock (Gate)
        {
            if (_tunnelState is not null) TearDownTunnel();

            try
            {
                return StartTunnelInner(socksPort, serverIp, killSwitch, bypassLines);
            }
            catch (Exception ex)
            {
                // Any failure mid-sequence (firewall exec, adapter never
                // appeared, route add) must leave NOTHING armed: a machine
                // sealed by a half-built tunnel is worse than no tunnel.
                TearDownTunnel();
                return Reply(ok: false, ex.Message);
            }
        }
    }

    private static string StartTunnelInner(int socksPort, string? serverIp, bool killSwitch,
                                           List<string> bypassLines)
    {
        var tun2socks = ResolveTool("tun2socks.exe");
        if (tun2socks is null) return MissingToolReply("tun2socks.exe");

        // 0. Snapshot the ORIGINAL default gateway and interface BEFORE
        // any route changes; the server bypass hangs off it.
        var (originalGateway, originalIf) = DefaultGateway();
        if (originalGateway is null && serverIp is not null)
            return Reply(ok: false, "no default gateway — cannot install server bypass route");

        // 1. Fail-closed first: seal egress, then open exactly the holes
        // the tunnel needs. (Only when kill switch is requested.)
        if (killSwitch)
        {
            ArmFirewall(serverIp);
            _firewallArmed = true;
        }

        // 2. Spawn tun2socks on a free device name. It creates the wintun
        // adapter and pumps packets between it and our SOCKS inbound.
        _tun2socks = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = tun2socks,
                Arguments = $"--device {TunnelDevice} --proxy socks5://127.0.0.1:{socksPort} " +
                            "--loglevel warn",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            },
        };
        if (!_tun2socks.Start())
        {
            return Reply(ok: false, "tun2socks failed to start");
        }
        // Drain both pipes: redirected output nobody reads fills the 4 KB
        // pipe buffer, and then tun2socks blocks forever on its next log
        // line — a tunnel that dies the first time it has something to say.
        _tun2socks.BeginOutputReadLine();
        _tun2socks.BeginErrorReadLine();

        // 3. Address the adapter. tun2socks needs a moment to create it.
        var addressed = false;
        for (var attempt = 0; attempt < 20 && !addressed; attempt++)
        {
            Thread.Sleep(250);
            addressed = Run($"interface ip set address name=\"{TunnelDevice}\" source=static addr=198.18.0.1 mask=255.255.255.0") is null;
        }
        if (!addressed)
        {
            return Reply(ok: false, $"adapter '{TunnelDevice}' never appeared");
        }

        // 4. Routes, most-critical first: the server's own host route via the
        // original gateway, then the default route via the tunnel. The pin is
        // load-bearing — without it the engine's dial to the server follows the
        // default route straight back into the tunnel.
        if (serverIp is not null && originalGateway is { } gw)
        {
            PinServer(serverIp, gw, originalIf);
        }
        AddRoute("0.0.0.0", "0.0.0.0", "198.18.0.2", TunnelDevice, metric: 1);

        // 5. Point system DNS at the tunnel: the engine hijacks :53
        // (hijackDns) and resolves via DoH through the proxy, so ISP
        // poisoning is out of the loop entirely. Best-effort: if it fails,
        // lookups fall to the physical adapter's resolver — degraded, not
        // broken.
        Run($"interface ip set dns name=\"{TunnelDevice}\" source=static addr=198.18.0.2");

        _tunnelState = (TunnelDevice, serverIp);

        // Bypass routes come last: a destination that refuses to be routed must
        // not take the tunnel down with it, so its problems are reported beside
        // a successful start rather than thrown.
        var problems = bypassLines.Count > 0 ? InstallBypass(bypassLines) : new List<string>();
        return Reply(ok: true, detail: problems.Count == 0
            ? "tunnel up"
            : "tunnel up; bypass: " + string.Join("; ", problems.Take(5)));
    }

    private static string MissingToolReply(string tool) =>
        Reply(ok: false, $"{tool} not found next to the app (see Scripts/fetch-cores.ps1)");

    /// <summary>Full teardown, idempotent. Order matters: kill the pump first
    /// (its exit removes the wintun adapter and its routes), then the static
    /// routes we added, then restore the firewall LAST — restoring it first
    /// would briefly expose traffic on a still-routed tunnel.</summary>
    private static void TearDownTunnel()
    {
        lock (Gate)
        {
            if (_tun2socks is { } proc)
            {
                try
                {
                    if (!proc.HasExited) proc.Kill(entireProcessTree: true);
                }
                catch (InvalidOperationException) { }
                catch (SystemException) { }
                proc.Dispose();
                _tun2socks = null;
            }
            foreach (var deleteArgs in _addedRoutes)
            {
                RunRoute(deleteArgs); // best-effort
            }
            _addedRoutes.Clear();
            // The bypass routes come down with the session's own ones: they were
            // added through the physical gateway, so they survive the adapter
            // going away and would keep sending the user's destinations around a
            // tunnel that no longer exists.
            foreach (var op in SplitTunnelPlan.TearDown(Bypass))
            {
                RunRoute(op.Arguments);   // best-effort
            }
            ServerPinsV4.Clear();
            ServerPinsV6.Clear();
            if (_firewallArmed)
            {
                DisarmFirewall();
                _firewallArmed = false;
            }
            _tunnelState = null;
        }
    }

    // ── Route plumbing ────────────────────────────────────────────────────

    private static void AddRoute(string dest, string mask, string gateway, string? interfaceName,
                                 int metric = 1, bool inet6 = false)
    {
        // route.exe, not netsh: the v4 route table is read back via
        // `route print -4` in DefaultGateway, so one tool owns both
        // directions. Interface is addressed by index; resolve it from the
        // interface name when we have one.
        var ifPart = InterfaceIndex(interfaceName, inet6) is { } idx ? $" if {idx}" : null;
        // NOT persistent (-p omitted): a crash must not leave a default
        // route pointing at a dead tunnel across reboots. Crash-orphaned
        // non-persistent routes die with the adapter; the firewall seal is
        // disarmed by the boot-repair pass instead.
        var args = $"{Family(inet6)}add {dest} mask {mask} {gateway} metric {metric}{ifPart}";
        var error = RunRoute(args);
        if (error is null) _addedRoutes.Add($"{Family(inet6)}delete {dest} mask {mask}");
        // A route that already exists from a crashed previous run is fine.
        else if (!IsAlreadyThere(error)) throw new IOException($"route add failed: {error}");
    }

    private static string Family(bool inet6) => inet6 ? "-6 " : "";

    /// <summary>route.exe's own words for "this entry is already in the table".
    /// The strings come from the tool's output rather than an exit code because
    /// the code is 1 for this and for every other failure.</summary>
    private static bool IsAlreadyThere(string routeOutput) =>
        routeOutput.Contains("already exists", StringComparison.OrdinalIgnoreCase)
        || routeOutput.Contains("object already", StringComparison.OrdinalIgnoreCase);

    /// <summary>Index of the interface <c>route.exe</c> has to be told about.
    /// A link-local IPv6 next hop means nothing without it, and a multi-homed
    /// machine can otherwise resolve the same gateway onto the wrong adapter.</summary>
    private static int? InterfaceIndex(string? name, bool inet6)
    {
        if (name is null) return null;
        try
        {
            var properties = NetworkInterface.GetAllNetworkInterfaces()
                .FirstOrDefault(n => n.Name == name)?.GetIPProperties();
            if (properties is null) return null;
            return inet6 ? properties.GetIPv6Properties()?.Index : properties.GetIPv4Properties()?.Index;
        }
        catch (NetworkInformationException) { return null; }
        catch (InvalidOperationException) { return null; }
    }

    /// <summary>Pin the server's own address to the physical gateway before the
    /// tunnel takes the default route. The address arrives resolved, so its
    /// family chooses the gateway: a v6 server with no v6 gateway cannot be
    /// reached at all, and saying so beats adding a route the table rejects.</summary>
    private static void PinServer(string serverIp, string gatewayV4, string? interfaceV4)
    {
        if (DirectResolver.IsIPv4(serverIp))
        {
            AddRoute(serverIp, "255.255.255.255", gatewayV4, interfaceV4);
            ServerPinsV4.Add(serverIp);
            return;
        }
        if (!DirectResolver.IsIPv6(serverIp))
            throw new IOException($"server address \"{serverIp}\" is not an address");
        var gatewayV6 = DefaultGatewayIPv6(out var interfaceName);
        if (gatewayV6 is null)
            throw new IOException(
                $"the server is at {serverIp} and this machine has no IPv6 gateway to reach it through");
        AddRoute(serverIp, "128", gatewayV6, interfaceName, inet6: true);
        ServerPinsV6.Add(serverIp);
    }

    /// <summary>The IPv6 default gateway, read from the managed adapter table
    /// instead of parsing <c>route print -6</c>: that table is column-aligned
    /// for humans and localized, so its layout is not something this machine
    /// can verify. Which shape Windows reports there — a global address or a
    /// link-local one — is likewise a reading to take on a Windows box; the
    /// interface index travels with it so a link-local next hop still names its
    /// adapter.</summary>
    private static string? DefaultGatewayIPv6(out string? interfaceName)
    {
        interfaceName = null;
        try
        {
            foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.Name == TunnelDevice || nic.OperationalStatus != OperationalStatus.Up) continue;
                foreach (var gateway in nic.GetIPProperties().GatewayAddresses)
                {
                    if (gateway.Address.AddressFamily != AddressFamily.InterNetworkV6) continue;
                    var text = gateway.Address.ToString();
                    var zone = text.IndexOf('%');
                    if (zone >= 0) text = text[..zone];
                    interfaceName = nic.Name;
                    return text;
                }
            }
        }
        catch (NetworkInformationException) { }
        return null;
    }

    // ── Split tunnel ──────────────────────────────────────────────────────

    private static string ApplyBypass(JsonObject cmd)
    {
        var lines = Strict.TextArray(cmd["bypass"]) ?? new List<string>();
        lock (Gate)
        {
            // The bypass is a property of a running tunnel: without one the
            // routes would sit on the physical gateway pointing at nothing.
            if (_tunnelState is null) return Reply(ok: false, "no tunnel is up");
            var problems = InstallBypass(lines);
            return Reply(ok: problems.Count == 0, detail: ProblemsText(problems));
        }
    }

    private static string ReassertBypassCommand()
    {
        lock (Gate)
        {
            if (_tunnelState is null) return Reply(ok: false, "no tunnel is up");
            var problems = ReassertBypass();
            return Reply(ok: problems.Count == 0, detail: ProblemsText(problems));
        }
    }

    /// <summary>Replace the session's bypass routes with these lines. The lines
    /// are parsed again here: the app is unprivileged and gets no say over the
    /// default route, however it described its request.</summary>
    private static List<string> InstallBypass(List<string> lines)
    {
        var env = BypassEnvironment();
        var result = SplitTunnelPlan.Apply(Bypass, env, lines,
                                          DirectResolver.IPv4, DirectResolver.IPv6);
        var problems = result.Problems.Concat(RunOperations(result.Operations)).ToList();
        if (_firewallArmed) problems.AddRange(RestateBypassRules(env));
        return problems;
    }

    /// <summary>Re-pin after a gateway change or on the app's heartbeat: new
    /// addresses for a name are added, nothing that is up comes down.</summary>
    private static List<string> ReassertBypass()
    {
        var env = BypassEnvironment();
        var result = SplitTunnelPlan.Reassert(Bypass, env,
                                              DirectResolver.IPv4, DirectResolver.IPv6);
        var problems = RunOperations(result.Operations).ToList();
        // Only a list that grew is worth rewriting firewall rules for; the
        // heartbeat would otherwise restate the whole seal every minute.
        if (_firewallArmed && result.Grew) problems.AddRange(RestateBypassRules(env));
        return problems;
    }

    private static IEnumerable<string> RunOperations(IEnumerable<SplitTunnelPlan.Operation> operations)
    {
        foreach (var op in operations)
        {
            var error = RunRoute(op.Arguments);
            if (error is null) continue;
            // An entry the table already holds does what was asked, whoever put
            // it there. Anything else is a destination the user believes is
            // bypassed and is not, so it has to come back as a problem.
            if (op.What == SplitTunnelPlan.Action.Add && IsAlreadyThere(error)) continue;
            yield return $"{op.Route.Destination}: {error}";
        }
    }

    private static SplitTunnelPlan.Env BypassEnvironment()
    {
        var (gatewayV4, nameV4) = DefaultGateway();
        var gatewayV6 = DefaultGatewayIPv6(out var nameV6);
        var onLink = AdapterPrefixes(TunnelDevice);
        var owned = AdapterPrefixes(null).Except(onLink).ToList();
        foreach (var range in TunnelOwnedRanges)
            if (SplitTunnelPlan.TryPrefix(range, out var rangePrefix)) owned.Add(rangePrefix);
        return new SplitTunnelPlan.Env
        {
            GatewayV4 = gatewayV4,
            GatewayV6 = gatewayV6,
            InterfaceV4 = InterfaceIndex(nameV4, inet6: false),
            InterfaceV6 = InterfaceIndex(nameV6, inet6: true),
            OnLink = onLink,
            TunnelOwned = owned,
            ServerPinsV4 = new List<string>(ServerPinsV4),
            ServerPinsV6 = new List<string>(ServerPinsV6),
        };
    }

    /// <summary>Every adapter's on-link prefix, taken from the address it
    /// carries and the prefix length that came with it. Skipping a device is how
    /// the tunnel's own range stays out of the physical list: a destination
    /// inside the tunnel must never read as "reachable without us".</summary>
    private static List<SplitTunnelPlan.Prefix> AdapterPrefixes(string? deviceToSkip)
    {
        var prefixes = new List<SplitTunnelPlan.Prefix>();
        try
        {
            foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.Name == deviceToSkip || nic.OperationalStatus != OperationalStatus.Up) continue;
                foreach (var unicast in nic.GetIPProperties().UnicastAddresses)
                {
                    if (unicast.Address.AddressFamily
                        is not (AddressFamily.InterNetwork or AddressFamily.InterNetworkV6)) continue;
                    if (IPAddress.IsLoopback(unicast.Address)) continue;
                    var bits = unicast.PrefixLength;
                    // 0 is what an adapter reports when it has no prefix — a
                    // /0 would cover every destination and swallow the tunnel.
                    if (bits is < 1 or > 128) continue;
                    var text = unicast.Address.ToString();
                    var zone = text.IndexOf('%');
                    if (zone >= 0) text = text[..zone];
                    if (SplitTunnelPlan.TryPrefix($"{text}/{bits}", out var prefix)) prefixes.Add(prefix);
                }
            }
        }
        catch (NetworkInformationException) { }
        return prefixes;
    }

    /// <summary>The destinations a sealed machine must still be allowed to
    /// reach. Without this the bypass is a route to a firewall that drops the
    /// packet, which is worse than no rule at all: it looks configured.</summary>
    private static List<string> RestateBypassRules(SplitTunnelPlan.Env env)
    {
        var problems = new List<string>();
        var name = $"{FirewallRulePrefix} bypass";
        // Whole set, one name, deleted then rewritten: a stale address must not
        // survive the rule that removed it.
        if (Run($"advfirewall firewall delete rule name=\"{name}\"") is { } removeError)
            problems.Add("bypass rules: " + removeError);
        var (v4, v6) = SplitTunnelPlan.AllowList(Bypass, env);
        var all = v4.Concat(v6).ToList();
        for (var i = 0; i < all.Count; i += AllowRuleChunk)
        {
            var chunk = string.Join(',', all.GetRange(i, Math.Min(AllowRuleChunk, all.Count - i)));
            // A CDN-backed name can add dozens of addresses a minute; one rule
            // per chunk keeps a single refused list from losing the rest, and
            // how long a `remoteip=` list netsh accepts is not something this
            // machine can read.
            if (Run($"advfirewall firewall add rule name=\"{name}\" dir=out action=allow remoteip={chunk}")
                is { } addError)
                problems.Add($"bypass allow list: {addError}");
        }
        return problems;
    }

    private const int AllowRuleChunk = 20;

    private static string ProblemsText(List<string> problems) =>
        problems.Count == 0 ? "bypass applied" : string.Join("; ", problems.Take(5));


    /// <summary>(gateway IP, interface name) of the current default route —
    /// the physical one, before the tunnel exists. Parsed from `route print`
    /// because .NET has no managed route-table API.</summary>
    private static (string? Gateway, string? Interface) DefaultGateway()
    {
        string output;
        using (var proc = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = "route",
                Arguments = "print -4",
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            },
        })
        {
            proc.Start();
            output = proc.StandardOutput.ReadToEnd();
            proc.WaitForExit(10000);
        }
        string? gateway = null, interfaceIp = null;
        foreach (var raw in output.Split('\n'))
        {
            var tokens = raw.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries);
            // route print columns: Destination Netmask Gateway Interface Metric
            if (tokens.Length >= 4 && tokens[0] == "0.0.0.0" && tokens[1] == "0.0.0.0")
            {
                gateway = tokens[2];
                interfaceIp = tokens[3];
                break;
            }
        }
        if (gateway is null || interfaceIp is null) return (null, null);
        var name = NetworkInterface.GetAllNetworkInterfaces()
            .FirstOrDefault(n => n.GetIPProperties()
                .UnicastAddresses.Any(a => a.Address.ToString() == interfaceIp))?.Name;
        return (gateway, name);
    }

    // ── Firewall kill switch ──────────────────────────────────────────────

    private static void ArmFirewall(string? serverIp)
    {
        // Default-deny outbound in ALL profiles, always, even on public ones.
        Exec("advfirewall set allprofiles firewallpolicy blockinboundalways,blockoutbound");
        Exec($"advfirewall firewall add rule name=\"{FirewallRulePrefix} loopback\" dir=out action=allow remoteip=127.0.0.0/8");
        foreach (var exe in new[] { "xray.exe", "tun2socks.exe", "Anemia.exe" })
        {
            var path = ResolveTool(exe);
            if (path is not null)
                Exec($"advfirewall firewall add rule name=\"{FirewallRulePrefix} {exe}\" dir=out action=allow program=\"{path}\"");
        }
        // The server's own IP must stay dialable even before the TUN is up —
        // that IS the escape hatch that makes fail-closed survivable.
        if (serverIp is not null)
            Exec($"advfirewall firewall add rule name=\"{FirewallRulePrefix} server\" dir=out action=allow remoteip={serverIp}");
        // Loopback DNS hijack target + DHCP renewals need UDP/53 & 67/68 out
        // the physical net only when they come from Windows itself; keep it
        // strict: DHCP only.
        Exec("advfirewall firewall add rule name=\"Anemia KS dhcp\" dir=out action=allow protocol=udp remoteport=67,68");
    }

    private static void DisarmFirewall()
    {
        // Windows defaults: outbound allowed. Delete our rules, then restore
        // policy — deleting first avoids a window where allow rules are gone
        // but policy still blocks.
        foreach (var name in new[]
                 {
                     $"{FirewallRulePrefix} loopback", $"{FirewallRulePrefix} server",
                     $"{FirewallRulePrefix} bypass",
                     $"{FirewallRulePrefix} dhcp", $"{FirewallRulePrefix} xray.exe",
                     $"{FirewallRulePrefix} tun2socks.exe", $"{FirewallRulePrefix} Anemia.exe",
                 })
        {
            Exec($"advfirewall firewall delete rule name=\"{name}\"");
        }
        Exec("advfirewall set allprofiles firewallpolicy blockinbound,allowoutbound");
    }

    // ── Subprocess + tooling helpers ──────────────────────────────────────

    /// <summary>Run route.exe, return null on success or the output text.</summary>
    private static string? RunRoute(string routeArgs)
    {
        using var proc = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = "route",
                Arguments = routeArgs,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            },
        };
        proc.Start();
        var output = proc.StandardOutput.ReadToEnd() + proc.StandardError.ReadToEnd();
        proc.WaitForExit(15000);
        return proc.ExitCode == 0 ? null : output.Trim();
    }

    /// <summary>Run netsh, return null on success or the stderr text.</summary>
    private static string? Run(string netshArgs)
    {
        using var proc = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = "netsh",
                Arguments = netshArgs,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            },
        };
        proc.Start();
        var output = proc.StandardOutput.ReadToEnd() + proc.StandardError.ReadToEnd();
        proc.WaitForExit(15000);
        return proc.ExitCode == 0 ? null : output.Trim();
    }

    private static void Exec(string netshArgs)
    {
        var err = Run(netshArgs);
        if (err is not null) throw new IOException($"netsh {netshArgs.Split(' ')[0]}: {err}");
    }

    /// <summary>Locate a bundled tool: sibling Resources\ dir of the app that
    /// launched us, then our own directory.</summary>
    private static string? ResolveTool(string fileName)
    {
        foreach (var dir in new[]
                 {
                     Path.Combine(AppContext.BaseDirectory, "Resources"),
                     AppContext.BaseDirectory,
                     Path.Combine(AppContext.BaseDirectory, ".."),
                 })
        {
            try
            {
                var candidate = Path.GetFullPath(Path.Combine(dir, fileName));
                if (File.Exists(candidate)) return candidate;
            }
            catch (IOException) { }
        }
        return null;
    }
}