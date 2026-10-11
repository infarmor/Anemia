using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json.Nodes;
using AnemiaCore;

namespace AnemiaApp;

public enum TunnelState
{
    Disconnected,
    Connecting,
    Connected,
    /// <summary>The engine died under us (or a reconnect loop is running):
    /// we are mid-way back to Connected. Distinct from Connecting so the UI
    /// can show that the user's tunnel went down unexpectedly.</summary>
    Reconnecting,
}

public sealed class StatsSnapshot
{
    public long TotalUp { get; init; }
    public long TotalDown { get; init; }
    /// <summary>Bytes/sec, computed from consecutive cumulative counters.</summary>
    public long UpRate { get; init; }
    public long DownRate { get; init; }
    /// <summary>Latest end-to-end RTT (ms) through the tunnel, null while unknown.</summary>
    public int? RttMs { get; init; }
}

/// <summary>
/// The connection state machine — Windows port of the macOS AppState. Owns
/// the server list, subscriptions, the selected profile, and one connection
/// attempt at a time. Layering:
///   unprivileged app: engine supervision, system proxy, helper IPC
///   privileged helper: wintun adapter, routes, firewall kill switch
/// </summary>
public sealed class AppState : IDisposable
{
    private readonly XrayController _xray = new();
    private readonly HelperClient _helper = new();
    private readonly StatePersistence _persistence;
    private readonly SubscriptionInfoStore _panels = new();
    /// <summary>The shared tunnel-health rules — the same numbers macOS, iOS and
    /// Android run, so this client does not act on a different amount of evidence
    /// than the phone on the same network.</summary>
    private readonly TunnelHealth _health = new();
    private readonly HealthSchedule _healthSchedule = new();
    private readonly AutoSwitchPolicy _switchPolicy = new();
    private readonly SwitchBudget _switchBudget = new();
    /// <summary>Per-day and per-server totals, kept in <c>traffic.json</c> in the
    /// same document the Mac and the phone read. Fed from the stats loop, which
    /// is the only thing that sees the engine's counters.</summary>
    private readonly UsageStore _usage = new();
    private HealthState _healthState;
    private DateTimeOffset? _lastHealthCheck;
    private readonly HistoryStore _history;
    private readonly object _gate = new();
    private readonly SynchronizationContext? _ui = SynchronizationContext.Current;

    private PersistedState _state;
    private TunnelState _tunnelState = TunnelState.Disconnected;
    private string? _lastError;
    private CancellationTokenSource? _connectCts;
    private CancellationTokenSource? _loopsCts;
    private long _connectGeneration;
    private bool _attemptInProgress;
    private int _reconnectAttempt;
    private (long Up, long Down)? _lastCounters;
    /// <summary>The engine run the traffic ledger was last fed from. Its only
    /// job is to notice that run changed (or went away) so the connected
    /// stretch is broken before the next reading — the ledger cannot tell a
    /// reconnect from a fast poll by itself.</summary>
    private DateTimeOffset? _usageRun;
    private DateTimeOffset _lastHistoryFlush = DateTimeOffset.UtcNow;
    private int? _lastRtt;
    private DateTimeOffset? _connectedSince;
    private DateTimeOffset? _tunnelUnreachableSince;
    private bool _proxyReachable;
    /// <summary>In-memory mirror of the on-disk history store. Every probe,
    /// health flush and ranking pass used to re-read the whole JSON file; now
    /// only the first touch of a session hits the disk. Guarded by _gate.</summary>
    private Dictionary<string, List<float>>? _historyCache;
    private bool _historyDirty;
    private readonly object _historyGate = new();

    public event Action? StateChanged;
    public event Action? ServersChanged;
    public event Action<StatsSnapshot>? StatsUpdated;
    public event Action<string>? Log;

    public AppState()
    {
        _persistence = new StatePersistence(StatePersistence.DefaultPath());
        _state = _persistence.Load();
        _history = new HistoryStore();
        _xray.OnLog += line => RaiseLog(line);
        _xray.OnExit += code => OnEngineExit(code);
        // Disk trouble has to be visible: without a line here "no statistics"
        // is indistinguishable from "no traffic".
        _usage.Log += RaiseLog;
    }

    public PersistedState State => _state;

    /// <summary>The traffic board's data: today, the month, the recent days and
    /// the per-server totals, all read from the ledger the stats loop feeds.</summary>
    public UsageStore Usage => _usage;
    public TunnelState TunnelState => _tunnelState;
    public string? LastError => _lastError;
    public ProxyServer? SelectedServer =>
        _state.SelectedServerId is { } id ? _state.ServerWithId(id) : null;
    public int SocksPort => _xray.SocksPort;
    public int HttpPort => _xray.HttpPort;

    /// <summary>When the current connected spell began (null otherwise) —
    /// drives the UI's session timer.</summary>
    public DateTimeOffset? ConnectedSince => _connectedSince;
    /// <summary>Latest health-probe latency through the tunnel, ms. Null while
    /// unknown (before the first successful probe of the spell).</summary>
    public int? ProxyLatency => _lastRtt;
    /// <summary>The SOCKS inbound answers and passes traffic. Optimistically
    /// true the moment the engine reports Connected; the health loop and the
    /// watchdog are what turn it off.</summary>
    public bool ProxyReachable => _proxyReachable && _tunnelState == TunnelState.Connected;
    /// <summary>True when the tunnel is up AND demonstrably carrying traffic.
    /// The UI's status truth table branches on this ("Protected" vs plain
    /// "Connected").</summary>
    public bool TunnelActive => _tunnelState == TunnelState.Connected && _proxyReachable;
    /// <summary>How long the tunnel has been failing its health checks —
    /// the watchdog force-restarts the engine past 25 s of this.</summary>
    public TimeSpan? UnreachableFor =>
        _tunnelUnreachableSince is { } since ? DateTimeOffset.UtcNow - since : null;

    /// <summary>True when the user asked for the full-TUN path (kill switch).
    /// Exposed for the status truth table ("Protected" vs "SOCKS only").</summary>
    public bool UsesTunnelPublic => UsesTunnel();

    // ── Persistence ────────────────────────────────────────────────────────

    public void Save() => _persistence.Save(_state);

    public void LoadOrInit()
    {
        // The lenient decoder in StatePersistence has already salvaged what it
        // could; nothing else to merge. Raise once so the UI binds fresh.
        RaiseStateChanged();
        RaiseServersChanged();
    }

    // ── Server management ─────────────────────────────────────────────────

    /// <summary>Add servers parsed from raw text (share links, one per line,
    /// or a whole base64 subscription body). Returns (added, failed) counts.</summary>
    public (int Added, int Failed) AddFromText(string text)
    {
        var (added, failed) = (0, 0);
        var existing = _state.AllServers.Select(s => s.IdentityKey).ToHashSet();
        foreach (var rawLine in text.Split('\n'))
        {
            var line = rawLine.Trim();
            if (line.Length == 0) continue;
            try
            {
                var server = ShareLinkParser.Parse(line);
                if (!existing.Add(server.IdentityKey))
                {
                    // Duplicate of something already configured — refresh its
                    // name but don't grow the list. Pick the newest entry with
                    // this identity and update it in place.
                    var twin = _state.AllServers.FirstOrDefault(s => s.IdentityKey == server.IdentityKey);
                    if (twin is not null && server.Name.Length > 0) twin.Name = server.Name;
                    continue;
                }
                _state.Servers.Add(server);
                added++;
            }
            catch (ParseErrorException)
            {
                failed++;
            }
        }
        if (added > 0) Save();
        RaiseServersChanged();
        return (added, failed);
    }

    public void RemoveServer(Guid id)
    {
        var wasSelected = _state.SelectedServerId == id;
        _state.Servers.RemoveAll(s => s.Id == id);
        foreach (var sub in _state.Subscriptions) sub.Servers.RemoveAll(s => s.Id == id);
        if (wasSelected)
        {
            _state.SelectedServerId = null;
            // Tearing down the server we're connected to is a user intent to
            // disconnect, not an invitation to reconnect to a random one.
            if (_tunnelState != TunnelState.Disconnected) _ = DisconnectAsync();
        }
        Save();
        RaiseServersChanged();
    }

    public void SelectServer(Guid id)
    {
        _state.SelectedServerId = id;
        Save();
        RaiseServersChanged();
        // Mirrors the macOS app: picking a server while connected re-dials.
        if (_tunnelState is TunnelState.Connected or TunnelState.Reconnecting)
            _ = ConnectAsync();
    }

    /// <summary>The bundle this machine would hand another: hand-added servers,
    /// the panels' addresses (each device fetches its own lists) and the shared
    /// settings. The selection stays home — every device picks its own exit.</summary>
    public SyncBundle ExportBundle() =>
        SyncBundle.FromState(_state, Environment.MachineName,
            DateTimeOffset.UtcNow.ToUnixTimeSeconds());

    /// <summary>Takes a bundle the user opened or pasted. The merge itself is
    /// <see cref="TransferModel.Apply"/>; what happens here is only what the
    /// other ports do afterwards — the settings that changed go through their
    /// setters, because a masking profile written straight into the state would
    /// not re-dial a live session the way the toggle in the sheet does.</summary>
    public SyncBundle.MergeSummary ImportBundle(SyncBundle bundle, bool applySettings)
    {
        MaskingProfile? before = bundle.Settings is not null && applySettings
            ? _state.MaskingProfile : null;
        var summary = TransferModel.Apply(bundle, _state, applySettings);
        if (summary.SettingsApplied)
        {
            if (before is not null && before != _state.MaskingProfile) SetMaskingProfile(_state.MaskingProfile);
            SetKillSwitch(_state.KillSwitchEnabled);
        }
        else
        {
            Save();
        }
        RaiseServersChanged();
        RaiseStateChanged();
        RaiseLog(TransferModel.ImportLog(bundle, summary));
        return summary;
    }

    public IReadOnlyList<ProxyServer> AllServers => _state.AllServers.ToList();

    // ── Subscriptions ─────────────────────────────────────────────────────

    /// <summary>Fetch and (re)import one subscription. Returns a user-facing
    /// status line. Failures never throw — the subscription list stays.
    ///
    /// <paramref name="allowInsecure"/> marks a round the user asked for. An
    /// unattended round must never swap the list of a panel reachable over plain
    /// http: whoever controls that path answers, and tomorrow's *encrypted*
    /// traffic would then run through an exit chosen by them.</summary>
    public async Task<string> RefreshSubscriptionAsync(Subscription sub, CancellationToken ct,
                                                       bool allowInsecure = false)
    {
        try
        {
            if (!Uri.TryCreate(sub.Url, UriKind.Absolute, out var uri) ||
                uri is not { Scheme: "http" or "https" })
                return $"{sub.Name}: bad subscription URL";

            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
            // Panels gate on User-Agent and answer an HTML error page to unknown
            // clients; v2rayN is the most widely allow-listed header.
            http.DefaultRequestHeaders.UserAgent.ParseAdd(PanelClient.UserAgent);
            using var request = new HttpRequestMessage(HttpMethod.Get, uri);
            var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
            if (!response.IsSuccessStatusCode)
                return $"{sub.Name}: fetch failed — HTTP {(int)response.StatusCode}";

            _panels.RecordAttempt(sub.Id);
            var body = await PanelClient.ReadBodyCappedAsync(response, ct);
            if (body is null)
                return $"{sub.Name}: fetch failed — body over {PanelClient.MaxBodyBytes / 1024 / 1024} MB";

            // Traffic, expiry, the panel's own name and interval: all in headers.
            var info = SubscriptionInfo.Parse(PanelClient.Headers(response));
            var result = SubscriptionParser.Parse(body);
            var (verdict, servers) = SubscriptionRules.DecideRefresh(
                sub.Servers, result, info, DateTimeOffset.UtcNow.ToUnixTimeSeconds());
            if (verdict != RefreshVerdict.Applied)
            {
                // An expired subscription usually answers with an empty list; its
                // headers are the only thing that says so.
                if (verdict == RefreshVerdict.Expired) _panels.Remember(sub.Id, info);
                return verdict == RefreshVerdict.Expired
                    ? $"{sub.Name}: subscription expired — the list is kept"
                    : $"{sub.Name}: no usable servers — the list is kept";
            }

            _panels.Remember(sub.Id, info);
            sub.Servers = servers;
            sub.LastUpdated = DateTimeOffset.UtcNow;
            Save();
            RaiseServersChanged();
            var skipped = result.Failures.Count;
            return skipped > 0
                ? $"{sub.Name}: {sub.Servers.Count} servers ({skipped} bad links skipped)"
                : $"{sub.Name}: {sub.Servers.Count} servers";
        }
        catch (OperationCanceledException)
        {
            return $"{sub.Name}: refresh cancelled";
        }
        catch (Exception ex) when (ex is HttpRequestException or IOException or TaskCanceledException
                                       or InvalidOperationException or UriFormatException)
        {
            return $"{sub.Name}: fetch failed — {ex.Message}";
        }
    }

    /// <summary>Add a panel and fetch it once, but only keep it if the fetch
    /// produced servers: macOS asks the panel BEFORE appending, so a typo in the
    /// URL costs one failed refresh instead of leaving a permanent empty row.
    /// The user typed this URL, which makes the round explicitly requested.</summary>
    public async Task<(Subscription? Subscription, string Status)> AddAndFetchAsync(string url,
                                                                                     CancellationToken ct,
                                                                                     string? name = null)
    {
        var candidate = new Subscription(name?.Length > 0 ? name : "Subscription", url);
        var status = await RefreshSubscriptionAsync(candidate, ct, allowInsecure: true);
        if (candidate.Servers.Count == 0) return (null, $"{url}: not added — {status}");
        _state.Subscriptions.Add(candidate);
        Save();
        RaiseServersChanged();
        return (candidate, status);
    }

    public Subscription AddSubscription(string url, string? name = null)
    {
        var sub = new Subscription(name?.Length > 0 ? name : "Subscription", url);
        _state.Subscriptions.Add(sub);
        Save();
        RaiseServersChanged();
        return sub;
    }

    // ── Masking profile ───────────────────────────────────────────────────

    public void SetMaskingProfile(MaskingProfile profile)
    {
        _state.MaskingProfile = profile;
        Save();
        RaiseStateChanged();
        if (_tunnelState is TunnelState.Connected or TunnelState.Reconnecting)
            _ = ConnectAsync(); // profile change mid-session re-dials
    }

    public void SetKillSwitch(bool enabled)
    {
        _state.KillSwitchEnabled = enabled;
        Save();
        RaiseStateChanged();
    }

    /// <summary>Store the local-bypass rules and put them in the route table.
    /// An empty list is sent too: clearing the rules is exactly the case where
    /// the routes already installed have to come down.</summary>
    public void SetSplitTunnel(bool enabled, List<string> entries)
    {
        _state.SplitTunnel.Enabled = enabled;
        _state.SplitTunnel.Entries = entries;
        Save();
        RaiseStateChanged();
        if (_tunnelState is TunnelState.Connected or TunnelState.Reconnecting)
            _ = ApplyBypassAsync();
    }

    /// <summary>The destinations for the helper, as the shared parser
    /// normalizes them: networks first, then names, the order macOS sends.</summary>
    private List<string> BypassLines()
    {
        var (networks, domains) = SplitTunnelParser.Partition(_state.SplitTunnel.ActiveEntries);
        return networks.Concat(domains).ToList();
    }

    private async Task ApplyBypassAsync()
    {
        var ct = _loopsCts?.Token ?? CancellationToken.None;
        try
        {
            var reply = await _helper.ApplyBypassAsync(BypassLines(), ct);
            if (reply is null) RaiseLog("helper did not answer — bypass routes unchanged");
            else if (reply["ok"]?.GetValue<bool>() == true) RaiseLog("bypass: " + ReplyText(reply));
            else RaiseLog("bypass refused: " + ReplyText(reply));
        }
        catch (Exception ex) when (ex is IOException or OperationCanceledException
                                      || ex is InvalidOperationException or TaskCanceledException)
        {
            RaiseLog("bypass could not be applied: " + ex.Message);
        }
    }

    private static string ReplyText(JsonNode? reply) =>
        reply?["detail"]?.GetValue<string>() ?? "no detail";

    public void SetSystemProxyEnabled(bool enabled)
    {
        _state.SystemProxyEnabled = enabled;
        Save();
        RaiseStateChanged();
        if (!enabled && _tunnelState == TunnelState.Disconnected)
            SystemProxyManager.Clear();
    }

    public void SetAutoConnect(bool enabled)
    {
        _state.AutoConnectOnLaunch = enabled;
        Save();
        RaiseStateChanged();
    }

    // ── Connect / disconnect ──────────────────────────────────────────────

    public Task ConnectAsync() => RunConnectAsync(userInitiated: true);

    public async Task ToggleAsync()
    {
        if (_tunnelState == TunnelState.Disconnected) await ConnectAsync();
        else await DisconnectAsync();
    }

    private async Task RunConnectAsync(bool userInitiated, bool inReconnect = false)
    {
        // Single-attempt guard, stronger than a state check: the reconnect
        // loop runs while the state reads Reconnecting, so a user clicking
        // Connect at that moment must not stack a second attempt on top —
        // the loser's failure handler would tear down the winner's engine.
        lock (_gate)
        {
            if (_attemptInProgress) return;
            _attemptInProgress = true;
        }
        try
        {
            await RunConnectInnerAsync(userInitiated, inReconnect);
        }
        finally
        {
            lock (_gate) _attemptInProgress = false;
        }
    }

    private async Task RunConnectInnerAsync(bool userInitiated, bool inReconnect)
    {
        var server = SelectedServer;
        if (server is null)
        {
            _lastError = "no server selected";
            RaiseLog("connect: no server selected");
            RaiseStateChanged();
            return;
        }

        // One generation per attempt: callbacks captured against this attempt
        // (loops, reconnect continuations) compare tokens before touching
        // global state, so a superseded attempt can't act on a newer one.
        var generation = ++_connectGeneration;
        _connectCts = new CancellationTokenSource();
        _loopsCts = new CancellationTokenSource();
        var ct = _connectCts.Token;

        if (!inReconnect)
        {
            _reconnectAttempt = 0;
            SetTunnelState(TunnelState.Connecting);
        }
        _lastError = null;
        RaiseLog($"connect: {server.Name} ({server.Address}:{server.Port})");
        RaiseStateChanged();

        // The masking profile is a starting point, not a promise: connect
        // failures walk up the escalation ladder (see Escalated()).
        var profile = _state.MaskingProfile;
        var anti = profile.Options();
        // LearnedMasking remembers per-identity profiles that had to be
        // escalated before — start there instead of re-failing on the same
        // wall every session.
        if (_state.LearnedMasking.TryGetValue(server.IdentityKey, out var learned)
            && Enum.TryParse<MaskingProfile>(learned, out var learnedProfile)
            && learnedProfile != profile)
        {
            anti = learnedProfile.Options();
            RaiseLog($"connect: using learned masking profile {learnedProfile.Title()}");
        }

        // Pin the engine's dial to the physical uplink when we can see one.
        _xray.DialerInterface = PhysicalInterface.Detect();

        // A re-dial (server switch mid-session, profile change, reconnect)
        // supersedes the current engine: stop it here so StartAsync sees a
        // clean slate. Without this the new attempt would fail with
        // AlreadyRunning and wrongly walk the masking-escalation ladder.
        if (_xray.IsRunning) _xray.Stop();

        Exception? failure = null;
        try
        {
            await _xray.StartAsync(server, anti);
            // Engine is up and its SOCKS port answers. If we're routing the
            // whole system through a TUN, hand off to the privileged helper.
            if (_state.KillSwitchEnabled || UsesTunnel())
            {
                // First TUN use this session pops UAC; a declined prompt just
                // degrades to proxy-only mode below.
                if (!await _helper.LaunchIfMissingAsync(ct))
                    RaiseLog("helper could not be launched (UAC declined or missing) — proxy-only mode");
                var serverIp = await ResolveServerIpAsync(server, ct);
                var reply = await _helper.StartTunnelAsync(
                    _xray.SocksPort, serverIp, _state.KillSwitchEnabled, BypassLines(), ct);
                if (reply is null || reply["ok"]?.GetValue<bool>() != true)
                {
                    // Without the helper there are no TUN routes — but the
                    // engine is fine, so degrade to proxy-only rather than
                    // fail the whole connect.
                    RaiseLog("helper unavailable or refused — falling back to proxy-only mode");
                }
                else if (reply["detail"]?.GetValue<string>() is { } detail &&
                         detail.Contains("bypass:"))
                {
                    // The tunnel came up and a destination the user asked to
                    // keep local did not: say so, or it looks configured.
                    RaiseLog(detail);
                }
            }
            if (_state.SystemProxyEnabled)
            {
                if (!SystemProxyManager.Set(_xray.SocksPort))
                    RaiseLog("system proxy could not be set (registry write refused)");
            }

            // The engine can die between StartAsync's readiness gate and this
            // line (its exit event was swallowed while the state read
            // Connecting). Never report Connected on top of a corpse.
            if (!_xray.IsRunning)
                throw new XrayException(XrayErrorKind.FailedToStart,
                    "engine exited right after start");

            SetTunnelState(TunnelState.Connected);
            // Backoff ladder is per-downspell, not per-session: after a
            // successful (re)connect the next outage starts at 1 s again.
            _reconnectAttempt = 0;
            RaiseLog($"connected via {server.Name} — SOCKS 127.0.0.1:{_xray.SocksPort}, HTTP 127.0.0.1:{_xray.HttpPort}");
            StartLoops(generation, server, _loopsCts.Token);
        }
        catch (OperationCanceledException)
        {
            // User-driven disconnect won the race; cleanup already ran.
            return;
        }
        catch (XrayException ex)
        {
            failure = ex;
        }
        catch (ConfigBuilderException ex)
        {
            failure = ex;
        }
        catch (IOException ex)
        {
            failure = ex;
        }
        catch (Exception ex)
        {
            // Never let an unexpected exception escape into the void: a
            // failed connect must always land in the Disconnected state.
            failure = ex;
        }

        if (failure is not null)
        {
            await CleanupAfterFailureAsync(ct);
            RaiseLog($"connect failed: {failure.Message}");

            // Escalate masking and retry — but only for engine-start failures
            // (config accepted, then the engine died or the validator refused
            // it): a missing binary or a config-shape error fails identically
            // on every rung of the ladder, so escalating there is churn.
            var escalated = profile.Escalated();
            if (failure is not OperationCanceledException
                && escalated is { } next
                && failure is XrayException { Kind: XrayErrorKind.FailedToStart })
            {
                RaiseLog($"masking escalation: {profile.Title()} → {next.Title()}");
                _state.MaskingProfile = next;
                _state.LearnedMasking[server.IdentityKey] = next.ToString();
                Save();
                RaiseStateChanged();
                // The failed attempt's tokens are dead weight now — the retry
                // allocates fresh ones; cancel these so nothing can linger.
                _loopsCts?.Cancel();
                _connectCts?.Cancel();
                // Recurse on the INNER method: we're still inside this
                // attempt, and RunConnectAsync's single-attempt guard would
                // bounce a nested call right back.
                await RunConnectInnerAsync(userInitiated: false, inReconnect: inReconnect);
                return;
            }

            _lastError = failure.Message;
            SetTunnelState(TunnelState.Disconnected);
        }
    }

    private async Task<string?> ResolveServerIpAsync(ProxyServer server, CancellationToken ct)
    {
        if (DirectResolver.IsIPv4(server.Address)) return server.Address;
        try
        {
            var resolve = Task.Run(() => DirectResolver.IPv4(server.Address), ct);
            var done = await Task.WhenAny(resolve, Task.Delay(TimeSpan.FromSeconds(3), ct));
            if (done == resolve)
            {
                var ips = await resolve;
                return ips.FirstOrDefault();
            }
        }
        catch (OperationCanceledException) { }
        return null;
    }

    public async Task DisconnectAsync()
    {
        _connectGeneration++;
        // Cancel whatever connect attempt is in flight first: its awaits
        // re-check the token and clean up their own half-built state.
        _connectCts?.Cancel();
        SetTunnelState(TunnelState.Disconnected);
        _lastError = null;
        RaiseLog("disconnecting");

        await CleanupConnectionAsync();
        // Kill the engine LAST: its exit callback ignores the exit event
        // once the state reads Disconnected, so no reconnect loop starts.
        try { _xray.Stop(); } catch { /* already gone */ }
        FlushHistory(force: true);
        RaiseStateChanged();
    }

    /// <summary>Tear down helper-side state (tunnel + routes + kill switch)
    /// and the system proxy. Errors are logged, never thrown: a disconnect
    /// must always finish as far as it can.</summary>
    private async Task CleanupConnectionAsync()
    {
        _loopsCts?.Cancel();
        _lastCounters = null;

        var helperStop = _helper.StopTunnelAsync(CancellationToken.None);
        try { await helperStop; } catch { /* helper already gone */ }

        // Unconditional: a stale proxy pointing at a dead local port
        // blackholes the user's browsing, so disconnect never leaves one.
        SystemProxyManager.Clear();
    }

    private async Task CleanupAfterFailureAsync(CancellationToken ct)
    {
        try { await CleanupConnectionAsync(); }
        catch { /* best effort during failure handling */ }
        try
        {
            _xray.Stop();
        }
        catch { /* engine already gone */ }
    }

    // ── Reconnect loop ────────────────────────────────────────────────────

    /// <summary>Engine process exit. If we believe we were connected (and this
    /// exit belongs to the current generation), start the reconnect ladder:
    /// 1 s, 2 s, 4 s … capped at 30 s, forever until it connects or the user
    /// disconnects. A crash-looping engine therefore self-heals instead of
    /// silently leaving the user offline.</summary>
    private void OnEngineExit(int exitCode)
    {
        RaiseLog($"xray exited (code {exitCode})");
        if (_tunnelState != TunnelState.Connected) return;
        var generation = _connectGeneration;
        SetTunnelState(TunnelState.Reconnecting);
        _ = Task.Run(async () =>
        {
            while (generation == _connectGeneration
                   && _tunnelState == TunnelState.Reconnecting)
            {
                var delay = TimeSpan.FromSeconds(Math.Min(30, Math.Pow(2, _reconnectAttempt)));
                _reconnectAttempt++;
                RaiseLog($"reconnect attempt {_reconnectAttempt} in {delay.TotalSeconds:0}s");
                try { await Task.Delay(delay); }
                catch (TaskCanceledException) { return; }
                if (generation != _connectGeneration) return;
                var wasConnecting = _tunnelState;
                // RunConnectAsync guards against concurrent Connecting, and
                // inReconnect keeps the attempt counter intact across retries.
                if (wasConnecting == TunnelState.Reconnecting)
                {
                    await RunConnectAsync(userInitiated: false, inReconnect: true);
                    if (_tunnelState == TunnelState.Connected) return;
                }
            }
        });
    }

    // ── Background loops (stats, health, history) ─────────────────────────

    private void StartLoops(long generation, ProxyServer server, CancellationToken ct)
    {
        _ = Task.Run(() => StatsLoopAsync(generation, server, ct));
        _ = Task.Run(() => HealthLoopAsync(generation, ct));
        _ = Task.Run(() => WatchdogLoopAsync(generation, ct));
    }

    /// <summary>Ask the shared policy whether a failover is allowed right now,
    /// and on "go" take the tunnel down so the crash ladder rebuilds it (masking
    /// escalation included). BOTH the health loop and the watchdog act through
    /// here: the budget is one ledger, and the loop that happens to run more
    /// often must not be able to bypass it — before this, a blocked server was
    /// torn down and rebuilt every 25 s for as long as it stayed blocked.</summary>
    private bool TryFailover(string reason)
    {
        var now = DateTimeOffset.UtcNow;
        // A frozen streak is not evidence; the schedule decides whether the last
        // reading still counts.
        double? checkedAge = _lastHealthCheck is { } last ? (now - last).TotalSeconds : null;
        int? failures = _healthSchedule.SignalFresh(checkedAge) ? _healthState.Failures : null;
        var sessionAge = _connectedSince is { } since ? (now - since).TotalSeconds : 0;
        var verdict = _switchPolicy.Decide(
            enabled: true,
            connected: _tunnelState == TunnelState.Connected,
            busy: _attemptInProgress,
            serverCount: _state.AllServers.Count(),
            healthFailures: failures,
            sessionAge: sessionAge,
            recentSwitches: _switchBudget.AgesAt(now.ToUnixTimeSeconds()));
        switch (verdict)
        {
            case SwitchVerdict.Go:
                _switchBudget.Note(now.ToUnixTimeSeconds());
                RaiseLog($"failover: {reason} — forcing reconnect");
                try { _xray.Stop(); } catch { /* already gone */ }
                return true;
            case SwitchVerdict.Throttled:
                RaiseLog("failover: held off — the budget for the last 15 minutes is spent");
                return false;
            case SwitchVerdict.Unproven:
                // Too young a session, or no signal at all: wait instead of
                // acting on evidence that does not exist yet.
                return false;
            default:
                return false;
        }
    }

    private async Task StatsLoopAsync(long generation, ProxyServer server, CancellationToken ct)
    {
        while (generation == _connectGeneration && !ct.IsCancellationRequested)
        {
            try
            {
                var binary = _xray.ResolveBinary();
                // The stamp is read around the query on purpose: if the engine
                // was replaced while the API call was in flight, the bytes
                // belong to the old run and the new stamp would book them as
                // that run's baseline — the whole cumulative counter landing on
                // today a second time. A torn reading is skipped, the next one
                // in 2 s is clean.
                var startedBefore = _xray.RunStartedAt;
                var counters = _xray.ApiPort is { } api
                    ? XrayController.QueryXrayTraffic(binary, api)
                    : null;
                var startedAfter = _xray.RunStartedAt;
                if (counters is { } c)
                {
                    var (upRate, downRate) = (0L, 0L);
                    if (_lastCounters is { } prev)
                    {
                        // Cumulative counters can restart if the engine was
                        // re-spawned underneath us — clamp negatives at zero.
                        upRate = Math.Max(0, c.Up - prev.Up);
                        downRate = Math.Max(0, c.Down - prev.Down);
                    }
                    _lastCounters = c;
                    StatsUpdated?.Invoke(new StatsSnapshot
                    {
                        TotalUp = c.Up,
                        TotalDown = c.Down,
                        // Loop cadence is 2 s; report per-second rate.
                        UpRate = upRate / 2,
                        DownRate = downRate / 2,
                    });

                    if (startedAfter is { } run && startedBefore == run)
                    {
                        if (_usageRun is { } seen && seen != run) _usage.Stopped();
                        _usageRun = run;
                        _usage.Record(run, c.Down, c.Up, (server.Id, server.Name));
                    }
                }
                else if (startedAfter is null && _usageRun is not null)
                {
                    // The engine is gone and nothing will report counters until
                    // the ladder brings one back: the downtime is not connected
                    // time, so the stretch ends here.
                    _usage.Stopped();
                    _usageRun = null;
                }
            }
            catch { /* stats are best-effort */ }
            try { await Task.Delay(TimeSpan.FromSeconds(2), ct); }
            catch (TaskCanceledException) { return; }
        }
    }

    private async Task HealthLoopAsync(long generation, CancellationToken ct)
    {
        while (generation == _connectGeneration && !ct.IsCancellationRequested)
        {
            int? rtt = null;
            try
            {
                rtt = await ProxyHealth.CheckAsync(_xray.SocksPort, ct: ct);
            }
            catch { /* health is best-effort */ }
            if (generation != _connectGeneration || ct.IsCancellationRequested) return;

            if (rtt is null)
            {
                // Quick re-probe before counting a miss: at the 10 s cadence a
                // single dropped probe would otherwise burn a whole check on
                // a transient hiccup.
                try { await Task.Delay(TimeSpan.FromSeconds(5), ct); }
                catch (TaskCanceledException) { return; }
                if (generation != _connectGeneration) return;
                try { rtt = await ProxyHealth.CheckAsync(_xray.SocksPort, ct: ct); }
                catch { }
                if (generation != _connectGeneration || ct.IsCancellationRequested) return;
            }

            var now = DateTimeOffset.UtcNow;
            // The streak is the shared rule's, not a local counter: a request that
            // answered in five seconds WAS answered, so the report shows five
            // seconds and the check still counts as a failure. A tunnel that
            // carries nothing slowly is not carrying.
            var outcome = _health.Request(rtt);
            var previousFailures = _healthState.Failures;
            _healthState = _health.Apply(outcome, _healthState);
            // This round has a reading, so the streak is fresh by construction;
            // whether an OLD reading still counts is what the schedule answers in
            // TryFailover, which the watchdog also calls.
            _lastHealthCheck = now;

            if (rtt is { } measured)
            {
                _lastRtt = measured;
                StatsUpdated?.Invoke(new StatsSnapshot { RttMs = measured });
            }

            if (outcome.Failed)
            {
                _proxyReachable = false;
                _tunnelUnreachableSince ??= now;
                RaiseLog($"health: tunnel is not passing traffic (check failed ×{_healthState.Failures})");
                if (_healthState.Failures > previousFailures) TryFailover("the tunnel is dead");
            }
            else
            {
                _proxyReachable = true;
                _tunnelUnreachableSince = null;
            }
            FlushHistory(force: false);
            try { await Task.Delay(TimeSpan.FromSeconds(10), ct); }
            catch (TaskCanceledException) { return; }
        }
    }

    /// <summary>Watchdog for the case the health loop can't see: the engine
    /// process stays alive and Connected is on the books, but nothing moves
    /// through the proxy. If no probe has passed for 25 s, force the engine
    /// down so the reconnect ladder rebuilds it — bounding the total silent
    /// outage instead of waiting for the failover's probe-failure count.</summary>
    private async Task WatchdogLoopAsync(long generation, CancellationToken ct)
    {
        while (generation == _connectGeneration && !ct.IsCancellationRequested)
        {
            try { await Task.Delay(TimeSpan.FromSeconds(5), ct); }
            catch (TaskCanceledException) { return; }
            if (generation != _connectGeneration) return;
            RePinBypassIfStale();
            if (_tunnelState != TunnelState.Connected || _proxyReachable) continue;
            if (_tunnelUnreachableSince is not { } since
                || DateTimeOffset.UtcNow - since < TimeSpan.FromSeconds(25)) continue;
            if (TryFailover("no traffic through the tunnel for 25s")) _proxyReachable = false;
        }
    }

    /// <summary>Re-pin the bypass routes once a minute while the tunnel is up.
    /// A router renewing its lease moves the gateway the routes were added
    /// through; from then on they point at an address that no longer answers
    /// and the destinations drift back into the tunnel without anyone
    /// noticing. The same round is how a name behind a CDN picks up the
    /// addresses it rotated to.</summary>
    private void RePinBypassIfStale()
    {
        if (_tunnelState != TunnelState.Connected || !UsesTunnel()) return;
        if (_state.SplitTunnel.ActiveEntries.Count == 0) return;
        var now = DateTimeOffset.UtcNow;
        if (now - _lastBypassRePin < BypassRePinEvery) return;
        _lastBypassRePin = now;
        var token = _loopsCts?.Token ?? CancellationToken.None;
        _ = Task.Run(async () =>
        {
            try
            {
                var reply = await _helper.ReassertBypassAsync(token);
                if (reply is not null && reply["ok"]?.GetValue<bool>() != true)
                    RaiseLog("bypass: " + ReplyText(reply));
            }
            catch (Exception ex) when (ex is IOException or InvalidOperationException
                                          || ex is OperationCanceledException or TaskCanceledException)
            {
                // The next minute tries again; a hiccup here is not worth a
                // log line every five seconds.
            }
        }, token);
    }

    private static readonly TimeSpan BypassRePinEvery = TimeSpan.FromMinutes(1);
    private DateTimeOffset _lastBypassRePin = DateTimeOffset.MinValue;

    /// <summary>Sample the latest health latency into the selected server's
    /// history (at most once a minute) and persist the cache when it changed.
    /// `force` bypasses the throttle (disconnect, shutdown).</summary>
    private void FlushHistory(bool force)
    {
        lock (_historyGate)
        {
            var cache = _historyCache ??= LoadHistorySafe();
            var server = SelectedServer;
            if (server is not null && _lastRtt is { } rtt
                && (force || DateTimeOffset.UtcNow - _lastHistoryFlush >= TimeSpan.FromMinutes(1)))
            {
                _lastHistoryFlush = DateTimeOffset.UtcNow;
                if (!cache.TryGetValue(server.IdentityKey, out var samples))
                    cache[server.IdentityKey] = samples = new List<float>();
                samples.Add(rtt);
                _historyDirty = true;
            }
            if (!_historyDirty) return;
            _historyDirty = false;
            try
            {
                // The store caps to its own rolling window on Save.
                _history.Save(new Dictionary<string, List<float>>(cache));
            }
            catch (IOException) { /* history is disposable */ }
        }
    }

    /// <summary>Persist pending history changes outside the throttle — probe
    /// results are user-visible in the picker and must not wait for the
    /// health loop's next flush.</summary>
    private void PersistHistory()
    {
        lock (_historyGate)
        {
            if (!_historyDirty || _historyCache is null) return;
            _historyDirty = false;
            try { _history.Save(new Dictionary<string, List<float>>(_historyCache)); }
            catch (IOException) { /* history is disposable */ }
        }
    }

    private Dictionary<string, List<float>> LoadHistorySafe()
    {
        try { return _history.Load(); }
        catch (IOException) { return new Dictionary<string, List<float>>(); }
    }

    /// <summary>A copy-on-read snapshot of the history cache for ranking and
    /// UI seeding — callers may hold it across awaits without seeing later
    /// mutations.</summary>
    private Dictionary<string, List<float>> HistorySnapshot()
    {
        lock (_historyGate)
        {
            var cache = _historyCache ??= LoadHistorySafe();
            return cache.ToDictionary(kv => kv.Key, kv => new List<float>(kv.Value));
        }
    }

    // ── Server ranking ────────────────────────────────────────────────────

    /// <summary>Rank all servers and select the best one. Replacement for the
    /// macOS client's CoreML ranker, simplified to what actually predicts a
    /// good server here: median of recent handshake history (2/3 weight) and
    /// one fresh probe (1/3). Servers with no data rank below any measured
    /// one; probes run sequentially so timings don't skew each other.
    /// Returns the chosen server (also selected), or null when no servers.</summary>
    public async Task<ProxyServer?> PickBestAsync(CancellationToken ct)
    {
        var servers = _state.AllServers.ToList();
        if (servers.Count == 0) return null;

        var history = HistorySnapshot();

        var ranked = new List<(ProxyServer Server, double Score)>();
        foreach (var server in servers)
        {
            ct.ThrowIfCancellationRequested();
            var fresh = await Task.Run(() => LatencyProbe.HandshakePing(server.Address, server.Port), ct);
            if (fresh is { } f)
            {
                RecordPing(server, f);
                double score = f;
                if (history.TryGetValue(server.IdentityKey, out var past) && past.Count > 0)
                {
                    var recent = past.TakeLast(5).OrderBy(v => v).ToList();
                    var median = recent[recent.Count / 2];
                    score = 0.67 * median + 0.33 * f;
                }
                ranked.Add((server, score));
            }
            else
            {
                ranked.Add((server, double.MaxValue));
            }
        }

        var best = ranked
            .OrderBy(r => r.Score)
            .ThenBy(r => r.Server.Name) // stable pick among equally-scored
            .FirstOrDefault();
        if (best.Server is null) return null;
        _state.SelectedServerId = best.Server.Id;
        Save();
        RaiseServersChanged();
        RaiseLog($"best server: {best.Server.Name} ({(best.Score == double.MaxValue ? "all unreachable" : $"{best.Score:0} ms")})");
        return best.Server;
    }

    /// <summary>Persist a handshake-probe result for a server (used by both
    /// the ranker and the UI's Ping all button). Updates the in-memory cache
    /// and writes through immediately.</summary>
    public void RecordPing(ProxyServer server, int rttMs)
    {
        lock (_historyGate)
        {
            var cache = _historyCache ??= LoadHistorySafe();
            if (!cache.TryGetValue(server.IdentityKey, out var samples))
                cache[server.IdentityKey] = samples = new List<float>();
            samples.Add(rttMs);
            _historyDirty = true;
        }
        PersistHistory();
    }

    // ── Subscriptions auto-refresh ────────────────────────────────────────

    /// <summary>How often the unattended round looks at the list. The decision
    /// itself is per panel — <see cref="Subscription.RefreshIsDue"/> — so a panel
    /// that asked for hourly updates gets them and a lazy one is not polled.</summary>
    private static readonly TimeSpan SubscriptionRoundTick = TimeSpan.FromMinutes(5);

    /// <summary>Refresh every subscription. <paramref name="allowInsecure"/> is
    /// the user pressing the button: without it the round skips unencrypted
    /// panels and panels that are not due yet.</summary>
    public async Task<IReadOnlyList<string>> RefreshAllSubscriptionsAsync(CancellationToken ct,
                                                                            bool allowInsecure = false)
    {
        var statuses = new List<string>();
        var now = DateTimeOffset.UtcNow;
        foreach (var sub in _state.Subscriptions.ToList())
        {
            if (!allowInsecure && !IsUnattendedDue(sub, now))
            {
                if (!sub.TlsProtected)
                    statuses.Add($"{sub.Name}: skipped by auto-refresh — no TLS, update it manually");
                continue;
            }
            statuses.Add(await RefreshSubscriptionAsync(sub, ct, allowInsecure));
        }
        return statuses;
    }

    /// <summary>Whether an unattended round may re-fetch this panel — plus the
    /// backoff the automatic round needs: a panel whose fetch always fails never
    /// moves <c>lastUpdated</c>, so without the attempt stamp every five-minute
    /// tick would retry it forever.</summary>
    private bool IsUnattendedDue(Subscription sub, DateTimeOffset now)
    {
        var interval = _panels.UpdateInterval(sub.Id);
        var lastAttempt = _panels.LastAttempt(sub.Id);
        double? fetched = sub.LastUpdated?.ToUnixTimeSeconds();
        if (lastAttempt is { } attempt && (fetched is null || attempt > fetched)) fetched = attempt;
        return Subscription.RefreshIsDue(fetched, now.ToUnixTimeSeconds(), sub.TlsProtected, interval);
    }

    /// <summary>Quota, expiry and the panel's own name — from the last fetch.</summary>
    public SubscriptionInfo? PanelInfo(Subscription sub) => _panels[sub.Id];

    /// <summary>Periodic subscription refresh while the app runs. Fails
    /// silently offline — the flag gates it, logs stay visible.</summary>
    private async Task SubscriptionLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try { await Task.Delay(SubscriptionRoundTick, ct); }
            catch (TaskCanceledException) { return; }
            if (!_state.SubscriptionAutoRefresh || _state.Subscriptions.Count == 0) continue;
            var statuses = await RefreshAllSubscriptionsAsync(ct);
            foreach (var status in statuses) RaiseLog(status);
        }
    }

    // ── Launch ────────────────────────────────────────────────────────────

    /// <summary>Called once after the UI is up: refresh subscriptions if
    /// auto-refresh is on, auto-connect if enabled. With auto-connect and no
    /// explicit selection, the best-ranked server is picked first.</summary>
    public async Task OnLaunchAsync()
    {
        _ = SubscriptionLoopAsync(new CancellationTokenSource().Token);
        if (_state.SubscriptionAutoRefresh && _state.Subscriptions.Count > 0)
        {
            foreach (var status in await RefreshAllSubscriptionsAsync(CancellationToken.None))
                RaiseLog(status);
        }
        if (_state.AutoConnectOnLaunch)
        {
            if (SelectedServer is null)
            {
                var best = await PickBestAsync(CancellationToken.None);
                if (best is null)
                {
                    RaiseLog("auto-connect: no servers configured yet");
                    return;
                }
            }
            await ConnectAsync();
        }
    }

    // ── Plumbing ──────────────────────────────────────────────────────────

    private bool UsesTunnel() =>
        _state.KillSwitchEnabled; // TUN mode ships with the kill switch; refine when helper exposes a mode flag

    private void SetTunnelState(TunnelState state)
    {
        _tunnelState = state;
        // Session bookkeeping lives here so every transition (user connect,
        // reconnect ladder, watchdog restart) updates it exactly once.
        if (state == TunnelState.Connected)
        {
            _connectedSince = DateTimeOffset.UtcNow;
            _proxyReachable = true; // optimistic; the health loop confirms
            _tunnelUnreachableSince = null;
        }
        else if (state is TunnelState.Disconnected or TunnelState.Reconnecting)
        {
            _connectedSince = null;
            _proxyReachable = false;
            _tunnelUnreachableSince = null;
        }
        RaiseStateChanged();
    }

    private void RaiseStateChanged()
    {
        if (_ui is { } ui) ui.Post(_ => StateChanged?.Invoke(), null);
        else StateChanged?.Invoke();
    }

    private void RaiseServersChanged()
    {
        // The traffic board's per-server rows follow the list: a re-imported
        // subscription regenerates ids, and without this the "top" board keeps
        // showing exits the user deleted (and the saved document only grows).
        // The snapshot is taken here rather than inside the store's lock so the
        // ledger cannot be handed a list that changes under it.
        var live = _state.AllServers.Select(s => s.Id).ToList();
        _usage.ForgetExcept(live);
        if (_ui is { } ui) ui.Post(_ => ServersChanged?.Invoke(), null);
        else ServersChanged?.Invoke();
    }

    private void RaiseLog(string message)
    {
        var line = $"{DateTimeOffset.Now:HH:mm:ss} {message}";
        if (_ui is { } ui) ui.Post(_ => Log?.Invoke(line), null);
        else Log?.Invoke(line);
    }

    public void Dispose()
    {
        _connectGeneration++;
        _loopsCts?.Cancel();
        _connectCts?.Cancel();
        FlushHistory(force: true); // last in-memory samples must not evaporate
        // The engine goes with us: end the connected stretch and flush, so the
        // bytes since the last 30 s window are on disk rather than in a process
        // that is about to end.
        try { _usage.Stopped(); } catch { /* disk trouble is already logged */ }
        try { _xray.Stop(); } catch { }
        SystemProxyManager.Clear();
        _ = _helper.StopTunnelAsync(CancellationToken.None);
    }
}