using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json.Nodes;
using AnemiaCore;

namespace AnemiaHelper;

/// <summary>Owns the VPN adapter, routing and Windows Filtering Platform session.</summary>
internal static class Program
{
    private const string TunnelDevice = "anemia";
    private const string PipeName = "anemia-vpn-helper";
    private const string XrayV4 = "198.18.0.1";
    private const string SinkV6 = "fd41:6e65:6d69:6100::1";
    private static readonly string[] TunnelOwnedRanges = { "198.18.0.0/15", SinkV6 + "/128" };

    private sealed record Session(string Address, int Port, string Program);

    private static readonly object Gate = new();
    private static Process? _pump;
    private static Process? _firewall;
    private static Session? _session;
    private static bool _wantsFirewall;
    private static readonly List<string> _tunnelAddresses = new();
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
        using var mutex = new Mutex(true, @"Local\AnemiaVpnHelper", out var ownsHelper);
        if (!ownsHelper) return;
        using var identity = WindowsIdentity.GetCurrent();
        var security = new PipeSecurity();
        security.AddAccessRule(new PipeAccessRule(identity.User!, PipeAccessRights.ReadWrite,
            AccessControlType.Allow));

        while (true)
        {
            NamedPipeServerStream server;
            try
            {
                server = NamedPipeServerStreamAcl.Create(
                    PipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous,
                    0, 0, security);
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
                try
                {
                    server.WaitForConnection();
                    using var reader = new StreamReader(server, Encoding.UTF8);
                    using var writer = new StreamWriter(server, new UTF8Encoding(false)) { AutoFlush = true };
                    var line = reader.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(5))
                        .GetAwaiter().GetResult();
                    if (line is not null) writer.WriteLine(Handle(line));
                }
                catch (IOException) { }
                catch (TimeoutException) { }
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
                    lock (Gate) return TunnelReply();
                case "start-tunnel":
                    return StartTunnel(cmd);
                case "stop-tunnel":
                    lock (Gate)
                    {
                        TearDownTunnel(keepFirewall: cmd["keepFirewall"]?.GetValue<bool>() == true);
                        return TunnelReply();
                    }
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

    private static string TunnelReply(string? detail = null)
    {
        var adapter = TunnelAdapter();
        var up = _session is not null && _pump is { HasExited: false }
            && adapter is { OperationalStatus: OperationalStatus.Up };
        var armed = _firewall is { HasExited: false };
        var addresses = new JsonArray();
        if (up)
        {
            var actual = adapter!.GetIPProperties().UnicastAddresses;
            foreach (var address in _tunnelAddresses)
                if (actual.Any(entry => entry.Address.ToString() == address)) addresses.Add(address);
            up = addresses.Count > 0 && (!_wantsFirewall || armed);
        }

        return new JsonObject
        {
            ["ok"] = true,
            ["up"] = up,
            ["armed"] = armed,
            ["addresses"] = addresses,
            ["detail"] = detail,
        }.ToJsonString();
    }

    private static string StartTunnel(JsonObject cmd)
    {
        var socksPort = cmd["socksPort"]?.GetValue<int>() ?? 0;
        var serverPort = cmd["serverPort"]?.GetValue<int>() ?? 0;
        var rawIp = cmd["serverIp"]?.GetValue<string>();
        var killSwitch = cmd["killSwitch"]?.GetValue<bool>() == true;
        var bypass = Strict.TextArray(cmd["bypass"]) ?? new List<string>();
        var uapi = cmd["uapi"]?.GetValue<string>();
        var awg = uapi is not null;
        if (!IPAddress.TryParse(rawIp, out var ip) || serverPort is < 1 or > 65535 ||
            (!awg && socksPort is < 1 or > 65535))
            return Reply(ok: false, "Некорректный адрес подключения");
        if (uapi?.Length > 65536) return Reply(ok: false, "Слишком большой профиль AmneziaWG");

        lock (Gate)
        {
            var retainSeal = killSwitch && _firewall is { HasExited: false };
            TearDownTunnel(keepFirewall: retainSeal);
            try
            {
                var binaryName = awg ? "anemia-engine.exe" : "xray.exe";
                var binary = ResolveTool(binaryName) ?? throw MissingTool(binaryName);
                var addresses = awg ? ReadAddresses(Strict.TextArray(cmd["addresses"]) ?? new())
                    : new List<(IPAddress Address, int Bits)> { (IPAddress.Parse(XrayV4), 24) };
                var dns = awg ? (Strict.TextArray(cmd["dns"]) ?? new()).Select(IPAddress.Parse).ToList()
                    : new List<IPAddress> { IPAddress.Parse("198.18.0.2") };
                var (gateway, physical) = DefaultGateway();
                if (!IPAddress.IsLoopback(ip)) PinServer(ip.ToString(), gateway, physical);

                if (awg)
                {
                    var mtu = cmd["mtu"]?.GetValue<int>() ?? 1280;
                    if (mtu is < 576 or > 65535) throw new IOException("Некорректный MTU AmneziaWG");
                    _pump = EngineChild.Start(binary, "awg", new { Adapter = TunnelDevice, UAPI = uapi, MTU = mtu });
                }
                else
                {
                    var tun2socks = ResolveTool("tun2socks.exe") ?? throw MissingTool("tun2socks.exe");
                    _pump = StartXrayPump(tun2socks, socksPort);
                }

                for (var attempt = 0; attempt < 40 && TunnelAdapter() is null && !_pump.HasExited; attempt++)
                    Thread.Sleep(125);
                if (_pump.HasExited || TunnelAdapter() is null)
                    throw new IOException("Windows не создала адаптер VPN");

                _session = new Session(ip.ToString(), serverPort, binary);
                _wantsFirewall = killSwitch;
                // Use more-specific routes than the physical default, independent of its metric.
                // IPv6 without a peer address is still captured instead of leaving via the uplink.
                ConfigureAdapter(addresses, dns);
                var problems = bypass.Count > 0 ? InstallBypass(bypass) : new List<string>();
                if (killSwitch) RefreshFirewall(BypassEnvironment());
                foreach (var route in new[] { "0.0.0.0/1", "128.0.0.0/1", "::/1", "8000::/1" })
                {
                    var family = route.Contains(':') ? "ipv6" : "ipv4";
                    Exec($"interface {family} add route prefix={route} interface=\"{TunnelDevice}\" metric=1 store=active");
                }

                for (var attempt = 0; attempt < 20 && TunnelAdapter()?.OperationalStatus != OperationalStatus.Up; attempt++)
                    Thread.Sleep(125);
                if (_pump.HasExited || TunnelAdapter()?.OperationalStatus != OperationalStatus.Up)
                    throw new IOException("Системный туннель не активен");

                return TunnelReply(problems.Count == 0 ? null : ProblemsText(problems));
            }
            catch (Exception error)
            {
                TearDownTunnel(keepFirewall: retainSeal);
                return Reply(ok: false, error.Message);
            }
        }
    }

    private static NetworkInterface? TunnelAdapter() => NetworkInterface.GetAllNetworkInterfaces()
        .FirstOrDefault(adapter => adapter.Name.Equals(TunnelDevice, StringComparison.OrdinalIgnoreCase));

    private static IOException MissingTool(string name) => new($"В комплекте Anemia отсутствует {name}");

    private static Process StartXrayPump(string executable, int socksPort)
    {
        var process = new Process
        {
            StartInfo = new ProcessStartInfo(executable)
            {
                ArgumentList = { "--device", TunnelDevice, "--proxy", $"socks5://127.0.0.1:{socksPort}", "--loglevel", "warn" },
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            },
        };
        try
        {
            if (!process.Start()) throw new IOException("Не удалось запустить tun2socks");
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
            return process;
        }
        catch
        {
            EngineChild.Stop(process);
            throw;
        }
    }

    private static List<(IPAddress Address, int Bits)> ReadAddresses(List<string> entries)
    {
        var result = new List<(IPAddress Address, int Bits)>();
        foreach (var value in entries)
        {
            var parts = value.Split('/', 2);
            if (!IPAddress.TryParse(parts[0], out var address) || IPAddress.IsLoopback(address))
                throw new IOException("Некорректный адрес интерфейса AmneziaWG");
            var maximum = address.AddressFamily == AddressFamily.InterNetwork ? 32 : 128;
            var bits = parts.Length == 1 ? maximum : int.Parse(parts[1], System.Globalization.CultureInfo.InvariantCulture);
            if (bits < 1 || bits > maximum || address.Equals(IPAddress.Any) || address.Equals(IPAddress.IPv6Any))
                throw new IOException("Некорректный префикс интерфейса AmneziaWG");
            result.Add((address, bits));
        }
        if (!result.Any(entry => entry.Address.AddressFamily == AddressFamily.InterNetwork))
            result.Add((IPAddress.Parse("172.29.0.1"), 32));
        return result;
    }

    private static void ConfigureAdapter(List<(IPAddress Address, int Bits)> addresses, List<IPAddress> dns)
    {
        if (!addresses.Any(entry => entry.Address.AddressFamily == AddressFamily.InterNetworkV6))
            addresses.Add((IPAddress.Parse(SinkV6), 128));

        foreach (var (address, bits) in addresses)
        {
            var family = address.AddressFamily == AddressFamily.InterNetwork ? "ipv4" : "ipv6";
            var adapter = family == "ipv4" ? "name" : "interface";
            Exec($"interface {family} add address {adapter}=\"{TunnelDevice}\" address={address}/{bits} store=active");
            _tunnelAddresses.Add(address.ToString());
        }
        foreach (var family in new[] { AddressFamily.InterNetwork, AddressFamily.InterNetworkV6 })
        {
            var label = family == AddressFamily.InterNetwork ? "ipv4" : "ipv6";
            var servers = dns.Where(address => address.AddressFamily == family).ToList();
            if (servers.Count == 0) continue;
            Exec($"interface {label} set dnsservers name=\"{TunnelDevice}\" source=static address={servers[0]} validate=no");
            for (var index = 1; index < servers.Count; index++)
                Exec($"interface {label} add dnsservers name=\"{TunnelDevice}\" address={servers[index]} index={index + 1} validate=no");
        }
    }

    private static void TearDownTunnel(bool keepFirewall = false)
    {
        EngineChild.Stop(_pump);
        _pump = null;
        foreach (var delete in _addedRoutes.AsEnumerable().Reverse()) RunRoute(delete);
        _addedRoutes.Clear();
        foreach (var op in SplitTunnelPlan.TearDown(Bypass)) RunRoute(op.Arguments);
        ServerPinsV4.Clear();
        ServerPinsV6.Clear();
        _tunnelAddresses.Clear();
        _session = null;
        _wantsFirewall = keepFirewall;
        if (keepFirewall) return;
        EngineChild.Stop(_firewall);
        _firewall = null;
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
        if (error is null) _addedRoutes.Add($"{Family(inet6)}delete {dest} mask {mask} {gateway}{ifPart}");
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
    private static void PinServer(string serverIp, string? gatewayV4, string? interfaceV4)
    {
        if (DirectResolver.IsIPv4(serverIp))
        {
            if (gatewayV4 is null) throw new IOException("Нет IPv4-шлюза для сервера VPN");
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
            if (_session is null) return Reply(ok: false, "no tunnel is up");
            var problems = InstallBypass(lines);
            return Reply(ok: problems.Count == 0, detail: ProblemsText(problems));
        }
    }

    private static string ReassertBypassCommand()
    {
        lock (Gate)
        {
            if (_session is null) return Reply(ok: false, "no tunnel is up");
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
        if (_firewall is not null) TryRefreshFirewall(env, problems);
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
        if (_firewall is not null && result.Grew) TryRefreshFirewall(env, problems);
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

    private static void TryRefreshFirewall(SplitTunnelPlan.Env env, List<string> problems)
    {
        try { RefreshFirewall(env); }
        catch (Exception error) { problems.Add(error.Message); }
    }

    private static void RefreshFirewall(SplitTunnelPlan.Env env)
    {
        if (!_wantsFirewall || _session is not { } session) return;
        var binary = ResolveTool("anemia-engine.exe") ?? throw MissingTool("anemia-engine.exe");
        var (ipv4, ipv6) = SplitTunnelPlan.AllowList(Bypass, env);
        var previous = _firewall;
        _firewall = EngineChild.Start(binary, "firewall", new
        {
            Adapter = TunnelDevice,
            session.Program,
            session.Address,
            session.Port,
            Bypass = ipv4.Concat(ipv6).ToArray(),
        });
        EngineChild.Stop(previous);
    }

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
                FileName = Path.Combine(Environment.SystemDirectory, "route.exe"),
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

    // ── Subprocess + tooling helpers ──────────────────────────────────────

    /// <summary>Run route.exe, return null on success or the output text.</summary>
    private static string? RunRoute(string routeArgs)
    {
        using var proc = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.SystemDirectory, "route.exe"),
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
                FileName = Path.Combine(Environment.SystemDirectory, "netsh.exe"),
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
