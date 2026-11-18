using System.IO;
using System.Net;
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
}

/// <summary>
/// The connection state machine — Windows port of the macOS AppState. Owns
/// the server list, subscriptions, the selected profile, and one connection
/// attempt at a time. Layering:
///   unprivileged app: Xray supervision, tunnel health and helper IPC
///   privileged helper: wintun adapter, routes, firewall kill switch
/// </summary>
public sealed class AppState : IDisposable
{
    private readonly XrayController _xray = new();
    private readonly HelperClient _helper = new();
    private readonly StatePersistence _persistence;
    private readonly SubscriptionInfoStore _panels = new();
    private readonly HashSet<Guid> _refreshingSubscriptions = new();
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
    private readonly SemaphoreSlim _connectionGate = new(1);
    private readonly Dictionary<string, string> _serverAddresses = new(StringComparer.OrdinalIgnoreCase);
    private readonly SynchronizationContext? _ui = SynchronizationContext.Current;

    private PersistedState _state;
    private TunnelState _tunnelState = TunnelState.Disconnected;
    private string? _lastError;
    private CancellationTokenSource? _connectCts;
    private CancellationTokenSource? _loopsCts;
    private CancellationTokenSource? _recoveryCts;
    private ProxyServer? _activeServer;
    private bool _adapterReady;
    private bool _killSwitchActive;
    private bool _helperStarted;
    private bool _disconnecting;
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
    public ProxyServer? ActiveServer => _activeServer;
    public bool KillSwitchActive => _killSwitchActive;
    public bool HasHealthReading => _lastHealthCheck is not null;
    private const string Preferences = @"HKEY_CURRENT_USER\Software\Anemia";
    public bool AdBlockEnabled { get; private set; } =
        Microsoft.Win32.Registry.GetValue(Preferences, "AdBlock", 0) is 1;
    public string? MapHomeCountry { get; private set; }

    public void UpdateMapOrigin(string? country)
    {
        if (country is null || country == MapHomeCountry) return;
        MapHomeCountry = country;
        RaiseStateChanged();
    }

    public void SetAdBlock(bool enabled)
    {
        Microsoft.Win32.Registry.SetValue(Preferences, "AdBlock", enabled ? 1 : 0);
        AdBlockEnabled = enabled;
        RaiseStateChanged();
    }

    /// <summary>When the current connected spell began (null otherwise) —
    /// drives the UI's session timer.</summary>
    public DateTimeOffset? ConnectedSince => _connectedSince;
    /// <summary>Latest health-probe latency through the tunnel, ms. Null while
    /// unknown (before the first successful probe of the spell).</summary>
    public int? ProxyLatency => _lastRtt;
    public bool TunnelActive => _tunnelState == TunnelState.Connected && _adapterReady && _proxyReachable;

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
        List<ProxyServer> servers;
        int failed;
        if (text.Split('\n').Any(line => line.Trim().Equals("[Interface]", StringComparison.OrdinalIgnoreCase)))
        {
            try
            {
                servers = [WireGuardLink.ParseConfigText(text)];
                failed = 0;
            }
            catch (ParseErrorException) { return (0, 1); }
        }
        else
        {
            var parsed = SubscriptionParser.Parse(text);
            servers = parsed.Servers;
            failed = parsed.Failures.Count;
            if (servers.Count == 0) return (0, Math.Max(1, failed));
        }

        var existing = _state.AllServers.GroupBy(server => server.IdentityKey)
            .ToDictionary(group => group.Key, group => group.First());
        var added = 0;
        foreach (var server in servers)
        {
            if (!existing.TryAdd(server.IdentityKey, server))
            {
                if (server.Name.Length > 0) existing[server.IdentityKey].Name = server.Name;
                continue;
            }
            _state.Servers.Add(server);
            if (!server.IsHysteriaFamily) _state.SelectedServerId ??= server.Id;
            added++;
        }
        Save();
        RaiseServersChanged();
        return (added, failed);
    }

    public void RemoveServer(Guid id)
    {
        _state.Servers.RemoveAll(s => s.Id == id);
        foreach (var sub in _state.Subscriptions) sub.Servers.RemoveAll(s => s.Id == id);
        SaveServerChanges();
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

    public async Task ConnectServerAsync(Guid id)
    {
        if (_state.ServerWithId(id) is not { IsHysteriaFamily: false }) return;
        _state.SelectedServerId = id;
        Save();
        RaiseServersChanged();
        if (ActiveServer?.Id != id || _tunnelState != TunnelState.Connected) await ConnectAsync();
    }

    /// <summary>The bundle this machine would hand another: hand-added servers,
    /// the panels' addresses (each device fetches its own lists) and the shared
    /// settings. The selection stays home — every device picks its own exit.</summary>
    public SyncBundle ExportBundle()
    {
        var bundle = SyncBundle.FromState(_state, Environment.MachineName,
            DateTimeOffset.UtcNow.ToUnixTimeSeconds());
        if (bundle.Settings is { } settings) settings.AdBlock = AdBlockEnabled;
        return bundle;
    }

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
            if (bundle.Settings?.AdBlock is { } adBlock) SetAdBlock(adBlock);
            if (_tunnelState == TunnelState.Connected) _ = ApplyBypassAsync();
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
                                                       bool allowInsecure = false) =>
        await FetchSubscriptionAsync(sub, ct, allowInsecure);

    private async Task<string> FetchSubscriptionAsync(Subscription sub, CancellationToken ct,
                                                       bool allowInsecure, bool isNew = false)
    {
        if (!isNew && !_state.Subscriptions.Contains(sub)) return "Подписка удалена";
        if (!allowInsecure && !sub.TlsProtected) return $"{sub.Name}: обновите вручную, ссылка без HTTPS";
        lock (_gate)
        {
            if (!_refreshingSubscriptions.Add(sub.Id)) return $"{sub.Name}: обновление уже идёт";
        }
        try
        {
            if (!Uri.TryCreate(sub.Url, UriKind.Absolute, out var uri) ||
                uri is not { Scheme: "http" or "https" })
                return $"{sub.Name}: неверный адрес подписки";

            if (!isNew) _panels.RecordAttempt(sub.Id);
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
            // Panels gate on User-Agent and answer an HTML error page to unknown
            // clients; v2rayN is the most widely allow-listed header.
            http.DefaultRequestHeaders.UserAgent.ParseAdd(PanelClient.UserAgent);
            using var request = new HttpRequestMessage(HttpMethod.Get, uri);
            var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
            if (!response.IsSuccessStatusCode)
                return $"{sub.Name}: ошибка загрузки HTTP {(int)response.StatusCode}";

            var body = await PanelClient.ReadBodyCappedAsync(response, ct);
            if (body is null)
                return $"{sub.Name}: размер подписки превышает {PanelClient.MaxBodyBytes / 1024 / 1024} МБ";

            ct.ThrowIfCancellationRequested();
            if (!isNew && !_state.Subscriptions.Contains(sub)) return "Подписка удалена";

            // Traffic, expiry, the panel's own name and interval: all in headers.
            var info = SubscriptionInfo.Parse(PanelClient.Headers(response));
            var result = SubscriptionParser.Parse(body);
            var (verdict, servers) = SubscriptionRules.DecideRefresh(
                sub.Servers, result, info, DateTimeOffset.UtcNow.ToUnixTimeSeconds());
            if (verdict != RefreshVerdict.Applied)
            {
                // An expired subscription usually answers with an empty list; its
                // headers are the only thing that says so.
                if (verdict == RefreshVerdict.Expired && !isNew)
                {
                    _panels.Remember(sub.Id, info);
                    RaiseServersChanged();
                }
                return verdict == RefreshVerdict.Expired
                    ? $"{sub.Name}: срок истёк, список сохранён"
                    : $"{sub.Name}: нет подходящих серверов, список сохранён";
            }

            _panels.Remember(sub.Id, info);
            sub.Servers = servers;
            sub.LastUpdated = DateTimeOffset.UtcNow;
            if (!isNew) SaveServerChanges();
            var skipped = result.Failures.Count;
            return skipped > 0
                ? $"{sub.Name}: серверов {sub.Servers.Count}, ошибок в ссылках {skipped}"
                : $"{sub.Name}: серверов {sub.Servers.Count}";
        }
        catch (OperationCanceledException)
        {
            return $"{sub.Name}: загрузка отменена";
        }
        catch (Exception ex) when (ex is HttpRequestException or IOException or TaskCanceledException
                                       or InvalidOperationException or UriFormatException)
        {
            return $"{sub.Name}: не удалось загрузить подписку. {ex.Message}";
        }
        finally
        {
            lock (_gate) _refreshingSubscriptions.Remove(sub.Id);
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
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri is not { Scheme: "http" or "https" })
            return (null, "Вставьте ссылку на подписку HTTP или HTTPS");
        if (_state.Subscriptions.Any(existing => SameSubscriptionUrl(existing.Url, url)))
            return (null, "Эта подписка уже добавлена");
        var candidate = new Subscription(name?.Length > 0 ? name : uri.Host, url);
        var status = await FetchSubscriptionAsync(candidate, ct, allowInsecure: true, isNew: true);
        if (candidate.Servers.Count == 0) return (null, status);
        if (_state.Subscriptions.Any(existing => SameSubscriptionUrl(existing.Url, url)))
        {
            _panels.Forget(candidate.Id);
            return (null, "Эта подписка уже добавлена");
        }
        _state.Subscriptions.Add(candidate);
        _state.SelectedServerId ??= candidate.Servers.FirstOrDefault(server => !server.IsHysteriaFamily)?.Id;
        Save();
        RaiseServersChanged();
        return (candidate, status);
    }

    private static bool SameSubscriptionUrl(string left, string right) =>
        string.Equals(left.Trim().TrimEnd('/'), right.Trim().TrimEnd('/'), StringComparison.Ordinal);

    public void RemoveSubscription(Guid id)
    {
        if (_state.Subscriptions.RemoveAll(sub => sub.Id == id) == 0) return;
        _panels.Forget(id);
        SaveServerChanges();
    }

    private void SaveServerChanges()
    {
        // Capture the selected server while an initial connection is still
        // establishing and has not assigned ActiveServer yet.
        var connectedId = ActiveServer?.Id ??
            (_tunnelState == TunnelState.Connecting ? _state.SelectedServerId : null);
        if (_state.SelectedServerId is { } selected && _state.ServerWithId(selected) is null)
            _state.SelectedServerId = _state.AllServers.FirstOrDefault(server => !server.IsHysteriaFamily)?.Id;
        Save();
        RaiseServersChanged();
        if (connectedId is { } active && _state.ServerWithId(active) is null) _ = DisconnectAsync();
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

    public void SetAutoConnect(bool enabled)
    {
        _state.AutoConnectOnLaunch = enabled;
        Save();
        RaiseStateChanged();
    }

    public void SetSubscriptionAutoRefresh(bool enabled)
    {
        _state.SubscriptionAutoRefresh = enabled;
        Save();
        RaiseStateChanged();
    }

    internal string? InstalledXrayPath => _xray.ResolveBinary();

    internal Task<bool> IsVpnHelperAvailableAsync(CancellationToken token) =>
        _helper.IsAvailableAsync(token);

    // ── Connect / disconnect ──────────────────────────────────────────────

    public Task ConnectAsync()
    {
        _recoveryCts?.Cancel();
        return RunConnectAsync(userInitiated: true);
    }

    public async Task ToggleAsync()
    {
        if (_tunnelState == TunnelState.Disconnected && !_killSwitchActive) await ConnectAsync();
        else await DisconnectAsync();
    }

    private async Task RunConnectAsync(bool userInitiated, bool inReconnect = false)
    {
        if (_disconnecting || !await _connectionGate.WaitAsync(0)) return;
        _attemptInProgress = true;
        try
        {
            if (!_disconnecting) await RunConnectInnerAsync(userInitiated, inReconnect);
        }
        finally
        {
            _attemptInProgress = false;
            _connectionGate.Release();
        }
    }

    private async Task RunConnectInnerAsync(bool userInitiated, bool inReconnect)
    {
        var server = SelectedServer;
        if (server is null)
        {
            _lastError = "Сначала выберите сервер";
            RaiseLog("connect: no server selected");
            RaiseStateChanged();
            return;
        }

        // One generation per attempt: callbacks captured against this attempt
        // (loops, reconnect continuations) compare tokens before touching
        // global state, so a superseded attempt can't act on a newer one.
        var generation = ++_connectGeneration;
        _connectCts?.Cancel();
        _loopsCts?.Cancel();
        _connectCts = new CancellationTokenSource();
        _lastCounters = null;
        _lastRtt = null;
        _lastHealthCheck = null;
        _healthState = default;
        _proxyReachable = false;
        _adapterReady = false;
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

        Exception? failure = null;
        try
        {
            if (server.IsHysteriaFamily) throw new IOException("Подключение Hysteria пока недоступно на Windows");
            var serverIp = await ResolveServerIpAsync(server, ct);
            await _helper.EnsureAvailableAsync(ct);
            _helperStarted = true;
            ct.ThrowIfCancellationRequested();

            _xray.Stop();
            var killSwitch = _state.KillSwitchEnabled;
            JsonObject? reply;
            if (server.IsWireGuardFamily)
            {
                reply = await _helper.StartAwgAsync(server, serverIp, killSwitch, AdBlockEnabled,
                    BypassLines(), CancellationToken.None);
            }
            else
            {
                _xray.DialerInterface = PhysicalInterface.Detect();
                await _xray.StartAsync(server, anti, serverIp, AdBlockEnabled);
                ct.ThrowIfCancellationRequested();
                reply = await _helper.StartTunnelAsync(
                    _xray.SocksPort, serverIp, server.Port, killSwitch, BypassLines(), CancellationToken.None);
            }
            ct.ThrowIfCancellationRequested();
            if (!IsTunnelUp(reply))
                throw new IOException(reply?["detail"]?.GetValue<string>() ?? "Помощник Windows не подтвердил запуск VPN");

            if (!server.IsWireGuardFamily && !_xray.IsRunning)
                throw new XrayException(XrayErrorKind.FailedToStart, "Движок Xray остановился");
            if (reply?["detail"]?.GetValue<string>() is { Length: > 0 } detail) RaiseLog(detail);

            _activeServer = server;
            _adapterReady = true;
            _killSwitchActive = reply?["armed"]?.GetValue<bool>() == true;
            _reconnectAttempt = 0;
            SetTunnelState(TunnelState.Connected);
            RaiseLog($"Системный VPN запущен через {server.Name}");
            StartLoops(generation, server, _loopsCts.Token);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            // Disconnect waits for this attempt before stopping the helper.
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
            if (ct.IsCancellationRequested) return;
            await CleanupConnectionAsync(keepFirewall: _killSwitchActive);
            _xray.Stop();
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
            SetTunnelState(inReconnect ? TunnelState.Reconnecting : TunnelState.Disconnected);
        }
    }

    private async Task<string> ResolveServerIpAsync(ProxyServer server, CancellationToken ct)
    {
        if (IPAddress.TryParse(server.Address.Trim('[', ']'), out var literal)) return literal.ToString();
        try
        {
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
            deadline.CancelAfter(TimeSpan.FromSeconds(3));
            var ips = await Dns.GetHostAddressesAsync(server.Address, deadline.Token);
            var endpoint = ips.FirstOrDefault(ip => ip.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork)
                ?? ips.FirstOrDefault();
            if (endpoint is not null) return _serverAddresses[server.Address] = endpoint.ToString();
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested) { }
        catch (System.Net.Sockets.SocketException) { }

        ct.ThrowIfCancellationRequested();
        if (_serverAddresses.TryGetValue(server.Address, out var saved)) return saved;
        throw new IOException("Не удалось определить адрес сервера");
    }

    private static bool IsTunnelUp(JsonObject? reply) =>
        reply?["ok"]?.GetValue<bool>() == true && reply["up"]?.GetValue<bool>() == true;

    public async Task DisconnectAsync()
    {
        _disconnecting = true;
        _recoveryCts?.Cancel();
        _connectCts?.Cancel();
        _loopsCts?.Cancel();
        await _connectionGate.WaitAsync();
        try
        {
            _connectGeneration++;
            _lastError = null;
            SetTunnelState(TunnelState.Disconnected);
            _xray.Stop();
            await CleanupConnectionAsync();
            FlushHistory(force: true);
            RaiseStateChanged();
        }
        finally
        {
            _disconnecting = false;
            _connectionGate.Release();
        }
    }

    private async Task CleanupConnectionAsync(bool keepFirewall = false)
    {
        _loopsCts?.Cancel();
        _lastCounters = null;
        _adapterReady = false;
        _activeServer = null;
        if (!_helperStarted) return;
        var reply = await _helper.StopTunnelAsync(CancellationToken.None, keepFirewall);
        if (reply?["ok"]?.GetValue<bool>() == true)
        {
            _killSwitchActive = reply["armed"]?.GetValue<bool>() == true;
        }
        else
        {
            _lastError ??= "Помощник Windows не подтвердил остановку VPN";
            RaiseLog(_lastError);
        }
    }

    private void OnEngineExit(int exitCode)
    {
        RaiseLog($"Xray остановился (код {exitCode})");
        BeginRecovery();
    }

    private void BeginRecovery()
    {
        CancellationToken ct;
        lock (_gate)
        {
            if (_disconnecting || _tunnelState != TunnelState.Connected) return;
            _recoveryCts?.Cancel();
            _recoveryCts = new CancellationTokenSource();
            ct = _recoveryCts.Token;
            _loopsCts?.Cancel();
            SetTunnelState(TunnelState.Reconnecting);
        }

        _ = Task.Run(async () =>
        {
            while (!ct.IsCancellationRequested && _tunnelState == TunnelState.Reconnecting)
            {
                var delay = TimeSpan.FromSeconds(Math.Min(30, Math.Pow(2, _reconnectAttempt)));
                _reconnectAttempt++;
                try { await Task.Delay(delay, ct); }
                catch (OperationCanceledException) { return; }
                await RunConnectAsync(userInitiated: false, inReconnect: true);
            }
        }, ct);
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
                BeginRecovery();
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
                var run = _connectedSince;
                var counters = TunnelProbe.Traffic();
                if (generation != _connectGeneration || ct.IsCancellationRequested) return;
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

                    if (run is { } started && run == _connectedSince)
                    {
                        if (_usageRun is { } seen && seen != started) _usage.Stopped();
                        _usageRun = started;
                        _usage.Record(started, c.Down, c.Up, (server.Id, server.Name));
                    }
                }
                else if (run is null && _usageRun is not null)
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
            var reply = await _helper.StatusAsync(ct);
            if (generation != _connectGeneration || ct.IsCancellationRequested) return;
            if (reply?["ok"]?.GetValue<bool>() == true)
                _killSwitchActive = reply["armed"]?.GetValue<bool>() == true;
            _adapterReady = IsTunnelUp(reply);
            if (!_adapterReady)
            {
                _lastError = "Системный туннель остановился";
                BeginRecovery();
                return;
            }

            int? rtt = null;
            try
            {
                rtt = await TunnelProbe.CheckAsync(ct);
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
                try { rtt = await TunnelProbe.CheckAsync(ct); }
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
            RaiseStateChanged();
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
        if (_tunnelState != TunnelState.Connected || !_adapterReady) return;
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
    /// Returns the chosen server (also selected), or null when none responds.</summary>
    public async Task<ProxyServer?> PickBestAsync(CancellationToken ct)
    {
        var servers = _state.AllServers.Where(server => !server.IsHysteriaFamily).ToList();
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
        }

        ct.ThrowIfCancellationRequested();
        var best = ranked
            .Where(result => _state.ServerWithId(result.Server.Id) is not null)
            .OrderBy(r => r.Score)
            .ThenBy(r => r.Server.Name) // stable pick among equally-scored
            .FirstOrDefault();
        if (best.Server is null) return null;
        _state.SelectedServerId = best.Server.Id;
        Save();
        RaiseServersChanged();
        RaiseLog($"Лучший сервер: {best.Server.Name} ({best.Score:0} мс)");
        return best.Server;
    }

    public async Task<ProxyServer?> ConnectBestAsync(CancellationToken ct)
    {
        var best = await PickBestAsync(ct);
        if (best is not null && ActiveServer?.Id != best.Id) await ConnectAsync();
        return best;
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
            if (SelectedServer is null or { IsHysteriaFamily: true })
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

    private void SetTunnelState(TunnelState state)
    {
        _tunnelState = state;
        // Session bookkeeping lives here so every transition (user connect,
        // reconnect ladder, watchdog restart) updates it exactly once.
        if (state == TunnelState.Connected)
        {
            _connectedSince = DateTimeOffset.UtcNow;
            _proxyReachable = false;
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
        _recoveryCts?.Cancel();
        _loopsCts?.Cancel();
        _connectCts?.Cancel();
        FlushHistory(force: true); // last in-memory samples must not evaporate
        // The engine goes with us: end the connected stretch and flush, so the
        // bytes since the last 30 s window are on disk rather than in a process
        // that is about to end.
        try { _usage.Stopped(); } catch { /* disk trouble is already logged */ }
        try { _xray.Stop(); } catch { }
        if (_helperStarted)
            Task.Run(() => _helper.StopTunnelAsync(CancellationToken.None)).GetAwaiter().GetResult();
    }
}
