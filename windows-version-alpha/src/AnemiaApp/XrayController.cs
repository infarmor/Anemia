using System.Diagnostics;
using System.IO;
using AnemiaCore;

namespace AnemiaApp;

public enum XrayErrorKind
{
    BinaryNotFound,
    AlreadyRunning,
    FailedToStart,
    Cancelled,
}

public sealed class XrayException : Exception
{
    public XrayErrorKind Kind { get; }
    public XrayException(XrayErrorKind kind, string message = "") : base(message) { Kind = kind; }
}

/// <summary>
/// Supervises a local `xray` process that runs the generated config and
/// exposes the SOCKS/HTTP inbounds. It does not touch the system route table —
/// that is the privileged helper's job. This class only owns the proxy engine.
/// Port of the macOS LoaderApp XrayController, including the free-port picks,
/// the pre-launch `xray run -test` validation (cached per config shape), the
/// readiness gate and the stale-teardown guards.
/// </summary>
public sealed class XrayController
{
    private Process? _process;
    private string? _configPath;
    /// <summary>The instant the current engine run began — the zero point of its
    /// cumulative traffic counters, and what the usage ledger keys a run by.
    /// Written once per run and never recomputed: a stamp that moves makes every
    /// reading look like a new engine, and the day is then billed the whole
    /// cumulative counter again.</summary>
    private DateTimeOffset? _runStartedAt;
    /// <summary>True while a start is between its guards and the readiness
    /// gate: a concurrent start sees it and refuses.</summary>
    private bool _starting;
    /// <summary>Set when Stop() is called while a start is still in flight:
    /// the start checks it after each await and cleans up after itself.</summary>
    private bool _stopRequested;
    private XrayConfigBuilder _builder;
    private readonly List<string> _logTail = new();
    private readonly object _logLock = new();
    /// <summary>Last-known IPv4 per server domain. Mid-session reconnects
    /// happen while the system resolver is pointed at the (dying) tunnel,
    /// where a fresh lookup of the server's own domain can loop; the cache
    /// pins the hosts entry anyway.</summary>
    /// <summary>Server+profile shapes that already passed `xray run -test`
    /// this session — reconnecting to a validated shape skips the validator
    /// spawn. Session-scoped on purpose.</summary>
    private readonly HashSet<string> _validatedKeys = new();

    /// <summary>Everything about a (server, anti) pair that decides whether the
    /// engine accepts its config: protocol identity, transport, TLS layer, and
    /// the emitted anti-DPI shape. Ports and the resolved server IP are
    /// deliberately excluded — they change per run but never flip a validation
    /// verdict.</summary>
    private static string ValidationKey(ProxyServer server, AntiCensorshipOptions anti)
    {
        var frag = anti.Fragment is { } f ? $"{f.Packets}|{f.Length}|{f.Interval}" : "-";
        var noises = string.Join(";", anti.Noises.Select(n => $"{n.Type}/{n.Packet}/{n.Delay}"));
        return string.Join("|",
            server.IdentityKey,
            Wire.Name(server.Network),
            Wire.Name(server.Security),
            // alterId/vmessCipher shape the emitted vmess user object; leaving
            // them out reused a verdict cached for a different user config.
            server.AlterId.ToString(),
            server.VmessCipher ?? "-",
            server.Sni ?? "-",
            string.Join(",", server.Alpn),
            server.HeaderType ?? "-",
            server.Host ?? "-",
            server.Path ?? "-",
            server.GrpcMultiMode?.ToString() ?? "-",
            server.RealityPublicKey ?? "-", server.RealityShortId ?? "-",
            server.Fingerprint ?? anti.Fingerprint,
            server.AllowInsecure ? "insecure" : "-",
            string.Join(",", anti.Mimicry),
            anti.MuxEnabled ? $"mux{anti.MuxConcurrency}" : "-",
            frag,
            noises);
    }

    /// <summary>Streamed log lines from the xray process (already trimmed).</summary>
    public event Action<string>? OnLog;
    /// <summary>Called when the process exits, with its termination status.</summary>
    public event Action<int>? OnExit;

    public XrayController(XrayConfigBuilder? builder = null)
    {
        _builder = builder ?? new XrayConfigBuilder();
    }

    public bool IsRunning => _process is { } p && !p.HasExited;
    /// <summary>The current engine run's zero point for its traffic counters, or
    /// null while no engine is ours. Stable for the whole run — the usage ledger
    /// decides "same engine" by comparing exactly this.</summary>
    public DateTimeOffset? RunStartedAt => _runStartedAt;
    public int SocksPort => _builder.SocksPort;
    public int HttpPort => _builder.HttpPort;
    public int? ApiPort => _builder.ApiPort;

    /// <summary>Physical interface the engine's server dial is pinned to.
    /// Must be set before StartAsync; null disables the pin.</summary>
    public string? DialerInterface
    {
        get => _builder.DialerInterface;
        set => _builder.DialerInterface = value;
    }

    /// <summary>Locate the xray binary. Search order:
    /// 1. ANEMIA_XRAY_PATH env override (dev convenience)
    /// 2. app-dir Resources\xray.exe (production, bundled)
    /// 3. common install paths.</summary>
    public string? ResolveBinary()
    {
        var env = Environment.GetEnvironmentVariable("ANEMIA_XRAY_PATH");
        if (!string.IsNullOrEmpty(env) && File.Exists(env)) return env;

        var candidates = new List<string>();
        var appDir = AppContext.BaseDirectory;
        candidates.Add(Path.Combine(appDir, "Resources", "xray.exe"));
        candidates.Add(Path.Combine(appDir, "xray.exe"));
        // For a dev checkout, fall back to the sibling macOS-fetch script layout.
        candidates.Add(Path.Combine(appDir, "..", "..", "..", "..", "Resources", "xray.exe"));
        foreach (var c in candidates)
        {
            try
            {
                if (File.Exists(c)) return Path.GetFullPath(c);
            }
            catch (IOException) { }
        }
        return null;
    }

    /// <summary>Write the config for `server` and launch xray. Throws if
    /// already running or the binary is missing.</summary>
    public async Task StartAsync(ProxyServer server, AntiCensorshipOptions anti, string endpointAddress, bool adBlock)
    {
        if (IsRunning || _starting) throw new XrayException(XrayErrorKind.AlreadyRunning);
        _starting = true;
        _stopRequested = false;
        try
        {
            var binary = ResolveBinary() ?? throw new XrayException(XrayErrorKind.BinaryNotFound,
                "В папке Anemia отсутствует xray.exe");

            // Pick free ports so a lingering process or another app can't
            // block the bind and crash the engine on start.
            var socks = PortFinder.Pick(_builder.SocksPort);
            var http = PortFinder.Pick(_builder.HttpPort, new HashSet<int> { socks });
            _builder.SocksPort = socks;
            _builder.HttpPort = http;
            if (_builder.ApiPort is { } ap)
                _builder.ApiPort = PortFinder.Pick(ap, new HashSet<int> { socks, http });

            var serverHost = server.Address;
            var hosts = new Dictionary<string, string>();
            if (!DirectResolver.IsIPAddress(serverHost)) hosts[serverHost] = endpointAddress;
            _builder.DnsHosts = hosts;
            _builder.RemoteDns = adBlock
                ? new List<string> { "https://dns.adguard-dns.com/dns-query" }
                : new XrayConfigBuilder().RemoteDns;

            var data = _builder.MakeConfigData(server, anti);
            var configPath = Path.Combine(Path.GetTempPath(), $"anemia-xray-{Guid.NewGuid():N}.json");
            await File.WriteAllBytesAsync(configPath, data);
            _configPath = configPath;

            // Validate the config with the real engine before launching, so a
            // bad profile fails with a clear message instead of a crash loop.
            // The verdict is fully determined by the server+profile shape, so
            // a shape that already passed this session skips the re-spawn.
            var key = ValidationKey(server, anti) + "|" + endpointAddress + "|" + adBlock;
            if (!_validatedKeys.Contains(key))
            {
                var check = await Task.Run(() => ValidateConfig(binary, configPath));
                if (_stopRequested) { CleanupConfig(); throw new XrayException(XrayErrorKind.Cancelled); }
                if (!check.Ok)
                {
                    CleanupConfig();
                    throw new XrayException(XrayErrorKind.FailedToStart, check.Message);
                }
                _validatedKeys.Add(key);
            }

            var proc = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = binary,
                    Arguments = $"run -c \"{configPath}\"",
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    CreateNoWindow = true,
                },
                EnableRaisingEvents = true,
            };

            // Buffer per run: xray writes in arbitrary chunks, so a naive
            // split-on-newline would emit partial lines whenever a read
            // boundary lands mid-line.
            var lineBuffer = new LogLineBuffer();
            proc.OutputDataReceived += (_, e) =>
            {
                foreach (var line in lineBuffer.Append(e.Data))
                    OnLogLine(line);
            };
            proc.ErrorDataReceived += (_, e) =>
            {
                foreach (var line in lineBuffer.Append(e.Data))
                    OnLogLine(line);
            };
            proc.Exited += (_, _) =>
            {
                var status = proc.ExitCode;
                // Only tear down state if THIS run is still current. A stale
                // handler (fired after a quick stop/start cycle) must not wipe
                // the new process or delete the new run's config file.
                if (_process != proc) return;
                _process = null;
                _runStartedAt = null;
                CleanupConfig();
                OnExit?.Invoke(status);
            };

            if (!proc.Start())
            {
                CleanupConfig();
                throw new XrayException(XrayErrorKind.FailedToStart, "process spawn refused");
            }
            proc.BeginOutputReadLine();
            proc.BeginErrorReadLine();
            _process = proc;
            // Spawner's clock first, the kernel's if it will answer: either way
            // the value is written once here, so every reading of this run sees
            // the same stamp.
            _runStartedAt = DateTimeOffset.UtcNow;
            try { _runStartedAt = new DateTimeOffset(proc.StartTime.ToUniversalTime()); }
            catch (Exception e) when (e is InvalidOperationException
                                      or ArgumentException
                                      or NotSupportedException) { }
            // Stop() may have landed while the spawn was still in flight:
            // honor it now instead of leaving the engine this start just
            // spawned running orphaned.
            if (_stopRequested)
            {
                Stop();
                throw new XrayException(XrayErrorKind.Cancelled);
            }

            // Readiness gate: a successful spawn only means exec worked. Wait
            // until the SOCKS inbound actually accepts connections — otherwise
            // connect() would report "connected" on top of a crashed engine,
            // and the helper would tunnel into a dead upstream. Polls off the
            // UI thread, max 5 s.
            var ready = await Task.Run(() => WaitForPort(socks, TimeSpan.FromSeconds(5)));
            // Both conditions must hold: CanConnect alone could be answered by
            // a squatter that grabbed the port between Pick and launch
            // (TOCTOU) while our engine was already dead.
            if (!ready || !IsRunning)
            {
                var alive = IsRunning;
                var reason = alive
                    ? $"engine did not open SOCKS port {socks} in time"
                    : EngineFailureReason();
                Stop();  // nils process first, so the exit handler stays inert
                throw new XrayException(XrayErrorKind.FailedToStart, reason);
            }
        }
        finally
        {
            _starting = false;
        }
    }

    public void Stop()
    {
        if (_process is null)
        {
            // A start is still in flight: it checks this flag after each await
            // and cleans up after itself — a plain no-op here would let it
            // spawn an orphaned engine.
            if (_starting) _stopRequested = true;
            return;
        }
        var proc = _process;
        _process = null;
        if (!proc.HasExited)
        {
            try
            {
                proc.Kill(entireProcessTree: true);
            }
            catch (InvalidOperationException) { }
            catch (SystemException) { }
        }
        proc.Dispose();
        CleanupConfig();
    }

    private void OnLogLine(string line)
    {
        if (line.Length == 0) return;
        lock (_logLock)
        {
            _logTail.Add(line);
            if (_logTail.Count > 20) _logTail.RemoveRange(0, _logTail.Count - 20);
        }
        OnLog?.Invoke(line);
    }

    /// <summary>The one line worth showing when the engine dies during startup.
    /// xray reports it as a single `Failed to start:` line whose cause is a
    /// ` > `-separated Go chain, from the outermost wrapper (which names a temp
    /// config path the user cannot open) down to the reason. Showing the last
    /// line raw was showing the path, not the problem.</summary>
    private string EngineFailureReason()
    {
        string[] tail;
        lock (_logLock) { tail = _logTail.ToArray(); }
        return EngineLog.FailureReason(tail);
    }

    private void CleanupConfig()
    {
        if (_configPath is { } path)
        {
            try { File.Delete(path); } catch (IOException) { }
        }
        _configPath = null;
    }

    /// <summary>Poll until 127.0.0.1:port accepts TCP connections or the
    /// deadline passes. Blocking sync function — call via Task.Run.</summary>
    private static bool WaitForPort(int port, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            if (PortFinder.CanConnect(port)) return true;
            Thread.Sleep(50);
        }
        return false;
    }

    /// <summary>Run `xray run -test` on a config file. Returns success and, on
    /// failure, the most relevant error line. Bounded by a timeout: a hung
    /// validator used to block the worker forever. Non-null output is the
    /// merged stdout/stderr.</summary>
    private static (bool Ok, string Message) ValidateConfig(string binaryPath, string configPath)
    {
        var result = RunCapturing(binaryPath, $"run -c \"{configPath}\" -test", TimeSpan.FromSeconds(15));
        if (result is null) return (false, "config validation timed out or failed to spawn");
        if (result.Value.Status == 0) return (true, "");
        var lines = result.Value.Output.Split('\n');
        var msg = lines.LastOrDefault(l => l.Contains("failed") || l.Contains("invalid")) ?? lines.LastOrDefault() ?? "config invalid";
        return (false, msg.Trim());
    }

    /// <summary>Spawn a short-lived xray subprocess, capture its merged
    /// stdout/stderr and bound the whole run by `timeout`. On timeout the
    /// child is killed and null is returned, so hung children never stack up —
    /// the stats poller spawns one every 2 s. Blocking by design: call from a
    /// worker thread.</summary>
    public static (int Status, string Output)? RunCapturing(string binaryPath, string arguments, TimeSpan timeout)
    {
        using var proc = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = binaryPath,
                Arguments = arguments,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            },
        };
        var box = new OutputBox();
        if (!proc.Start()) return null;
        proc.OutputDataReceived += (_, e) => { if (e.Data is not null) box.Append(e.Data + "\n"); };
        proc.ErrorDataReceived += (_, e) => { if (e.Data is not null) box.Append(e.Data + "\n"); };
        proc.BeginOutputReadLine();
        proc.BeginErrorReadLine();

        if (proc.WaitForExit((int)timeout.TotalMilliseconds))
        {
            return (proc.ExitCode, box.Snapshot());
        }
        // Timeout: bounded kill ladder — a child that ignores a graceful
        // request must not wedge the poll cycle forever.
        try { proc.Kill(entireProcessTree: true); } catch (SystemException) { }
        return null;
    }

    /// <summary>Cumulative proxy traffic counters (bytes) from Xray's Stats
    /// API. Native-first: a single gRPC-over-h2c connection to the API port.
    /// Falls back to the `xray api statsquery` CLI, bounded by a timeout, when
    /// the native RPC doesn't complete. Blocking: call from a worker.</summary>
    public static (long Up, long Down)? QueryXrayTraffic(string? binaryPath, int apiPort)
    {
        // Narrow pattern keeps the response tiny and the RPC fast.
        var stats = XrayStatsApi.Query(port: (ushort)apiPort, pattern: "outbound>>>proxy>>>");
        if (stats is not null)
        {
            long up = 0, down = 0;
            foreach (var s in stats)
            {
                if (s.Name == "outbound>>>proxy>>>traffic>>>uplink") up = s.Value;
                else if (s.Name == "outbound>>>proxy>>>traffic>>>downlink") down = s.Value;
            }
            return (up, down);
        }

        if (binaryPath is null) return null;
        var result = RunCapturing(binaryPath, $"api statsquery --server=127.0.0.1:{apiPort}", TimeSpan.FromSeconds(6));
        if (result is null || result.Value.Status != 0) return null;
        try
        {
            var node = System.Text.Json.Nodes.JsonNode.Parse(result.Value.Output);
            var arr = node?["stat"] as System.Text.Json.Nodes.JsonArray;
            if (arr is null) return null;
            long up = 0, down = 0;
            foreach (var entry in arr.OfType<System.Text.Json.Nodes.JsonObject>())
            {
                var name = entry["name"]?.GetValue<string>();
                var value = long.TryParse(entry["value"]?.GetValue<string>(), out var v) ? v : 0;
                if (name == "outbound>>>proxy>>>traffic>>>uplink") up = value;
                else if (name == "outbound>>>proxy>>>traffic>>>downlink") down = value;
            }
            return (up, down);
        }
        catch (System.Text.Json.JsonException)
        {
            return null;
        }
    }
}

/// <summary>Thread-safe accumulator for subprocess output.</summary>
file sealed class OutputBox
{
    private readonly System.Text.StringBuilder _sb = new();
    private readonly object _lock = new();
    public void Append(string chunk)
    {
        lock (_lock) { _sb.Append(chunk); }
    }
    public string Snapshot()
    {
        lock (_lock) { return _sb.ToString(); }
    }
}

/// <summary>Reassembles newline-terminated log lines from arbitrarily-chunked
/// process events. DataReceived events are serialized per process, and each
/// engine run owns its own buffer, so no locking is needed.</summary>
file sealed class LogLineBuffer
{
    private string _pending = "";
    public IEnumerable<string> Append(string? chunk)
    {
        if (string.IsNullOrEmpty(chunk)) yield break;
        _pending += chunk;
        while (true)
        {
            var nl = _pending.IndexOf('\n');
            if (nl < 0) break;
            var line = _pending[..nl].Trim('\r', ' ');
            _pending = _pending[(nl + 1)..];
            if (line.Length > 0) yield return line;
        }
    }
}
