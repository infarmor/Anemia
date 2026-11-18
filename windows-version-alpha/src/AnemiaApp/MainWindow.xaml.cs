using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using AnemiaCore;
// WPF + WinForms global usings collide on Brush; WPF wins everywhere here.
using Brush = System.Windows.Media.Brush;

namespace AnemiaApp;

/// <summary>Per-server view model for the picker sheet: labels for the row
/// plus the ping badge, updated in place through INPC (the row count is
/// small; a full MVVM stack isn't worth it for a menu-bar-class client).</summary>
public sealed class ServerRow : INotifyPropertyChanged
{
    public ProxyServer Server { get; }
    public Guid Id => Server.Id;
    public string Name => Server.Name.Length > 0 ? Server.Name : $"{Server.Address}:{Server.Port}";
    public string Subtitle => $"{ProtoLabel} · {Server.Address}:{Server.Port} · {TransportLabel}";
    private string ProtoLabel => Server.Proto switch
    {
        ProxyProtocol.Vless => "vless",
        ProxyProtocol.Vmess => "vmess",
        ProxyProtocol.Ss => "ss",
        ProxyProtocol.Trojan => "trojan",
        _ => "?",
    };
    private string TransportLabel => Wire.Name(Server.Network) +
        (Server.Security == StreamSecurity.None ? "" : $"/{Wire.Name(Server.Security)}");

    private string _ping = "—";
    public string Ping
    {
        get => _ping;
        set { _ping = value; Raised(nameof(Ping)); }
    }

    private Brush _dotBrush = null!;
    /// <summary>Selection dot: accent when this row is the chosen server.</summary>
    public Brush DotBrush
    {
        get => _dotBrush;
        set { _dotBrush = value; Raised(nameof(DotBrush)); }
    }

    private Brush _pingBrush = null!;
    public Brush PingBrush
    {
        get => _pingBrush;
        set { _pingBrush = value; Raised(nameof(PingBrush)); }
    }

    public ServerRow(ProxyServer server, Brush dimBrush)
    {
        Server = server;
        _pingBrush = dimBrush;
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    private void Raised(string name) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

public partial class MainWindow : Window
{
    private readonly AppState _app;
    private readonly DispatcherTimer _clock = new() { Interval = TimeSpan.FromSeconds(1) };
    /// <summary>Last probe results keyed by server id — survives list rebuilds
    /// so a subscription refresh doesn't blank the badges.</summary>
    private readonly Dictionary<Guid, int?> _pingResults = new();
    private ServersWindow? _servers;
    private SettingsWindow? _settings;
    private StatsWindow? _stats;
    private LeakTestWindow? _leaks;
    private LeakTestModel.Report? _lastLeakReport;
    private DateTimeOffset? _leakSessionStarted;
    private readonly Queue<string> _journal = new();
    private bool _quickActionRunning;
    private string? _quickActionNotice;
    private bool _disconnectRequested;

    public MainWindow(AppState app)
    {
        InitializeComponent();
        _app = app;

        MaskingBox.ItemsSource = Enum.GetValues<MaskingProfile>()
            .Select(p => new ComboItem(p, MaskingLabel(p))).ToList();
        MaskingBox.DisplayMemberPath = nameof(ComboItem.Label);
        MaskingBox.SelectedValuePath = nameof(ComboItem.Profile);

        _app.StateChanged += OnStateChanged;
        _app.ServersChanged += OnStateChanged; // picker-driven selection updates the card
        _app.StatsUpdated += stats => Dispatcher.BeginInvoke(() => OnStats(stats));
        _app.Log += line => Dispatcher.BeginInvoke(() => AppendLog(line));
        WorldMap.CountryPicked += SelectMapCountry;
        WorldMap.CountryDetails = CountryDetails;

        // Tray-style close: the X hides the window; the tray icon's Quit is
        // the real exit (the app holds the engine + system proxy, so a stray
        // close must not strand them).
        Closing += (_, e) =>
        {
            if (!App.ForceClose)
            {
                e.Cancel = true;
                Hide();
            }
        };

        // Session timer ticks while connected ("· 12:34" beside the status).
        _clock.Tick += (_, _) => { UpdateSession(); UpdateLeakTile(); };
        _clock.Start();

        OnStateChanged();
        AppendLog("Anemia готова к подключению");
    }

    private static string MaskingLabel(MaskingProfile profile) => profile.Title() switch
    {
        "Off" => "Выключено",
        "Balanced" => "Сбалансированная",
        "Maximum" => "Максимальная",
        var label => label,
    };

    private sealed record ComboItem(MaskingProfile Profile, string Label)
    {
        public override string ToString() => Label;
    }

    // ── State binding ─────────────────────────────────────────────────────

    private void OnStateChanged()
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.BeginInvoke(OnStateChanged);
            return;
        }
        var state = _app.TunnelState;
        var (title, brush) = state switch
        {
            TunnelState.Connected when _app.TunnelActive => ("Защищено", "Accent"),
            TunnelState.Connected when !_app.HasHealthReading => ("VPN подключён", "TextDim"),
            TunnelState.Connected => ("Нет связи с сервером", "Danger"),
            TunnelState.Connecting => ("Подключение…", "TextDim"),
            TunnelState.Reconnecting => ("Переподключение…", "TextDim"),
            _ when _app.LastError is not null => ("Ошибка подключения", "Danger"),
            _ => ("Не подключено", "TextDim"),
        };
        StatusText.Text = _disconnectRequested
            ? state is TunnelState.Connecting or TunnelState.Reconnecting ? "Отменяем подключение…" : "Отключение…"
            : title;
        StatusGlyph.Stroke = (Brush)FindResource(brush);
        const string shield = "M12,1 L22,5 L22,12 Q22,19 12,24 Q2,19 2,12 L2,5 Z ";
        StatusGlyph.Data = Geometry.Parse(shield + (_app.TunnelActive ? "M7,12 L10,15 L17,8" : state switch
        {
            TunnelState.Connecting or TunnelState.Reconnecting => "M12,7 V12 L16,15",
            _ when _app.LastError is not null => "M12,7 V13 M12,16 V17",
            _ => "M7,8 L17,17",
        }));
        StatusText.Foreground = (Brush)FindResource(brush == "TextDim" ? "Text" : brush);
        StatusDetail.Text = _disconnectRequested ? "Завершаем работу системного VPN" :
            _app.LastError ?? _quickActionNotice ?? (state == TunnelState.Disconnected
            ? _app.SelectedServer is null ? "Добавьте сервер, чтобы подключиться" : "Включите VPN переключателем вверху"
            : "");
        StatusDetail.Visibility = StatusDetail.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        ConnectSwitch.IsChecked = ConnectionRequested;
        ConnectSwitch.IsEnabled = !_disconnectRequested;
        ConnectSwitch.ToolTip = _disconnectRequested ? "Дождитесь завершения отключения" : ConnectionRequested
            ? state is TunnelState.Connecting or TunnelState.Reconnecting ? "Отменить подключение VPN" : "Отключить VPN"
            : CanConnectToSelection ? "Подключить VPN" : "Выбрать сервер для VPN";
        System.Windows.Automation.AutomationProperties.SetHelpText(ConnectSwitch, (string)ConnectSwitch.ToolTip);
        UpdateSession();

        var displayed = _app.ActiveServer ?? _app.SelectedServer;
        var knownServers = _app.AllServers;
        var countries = knownServers.Select(server => Country.Code(server.Name))
            .OfType<string>().Distinct(StringComparer.OrdinalIgnoreCase).Order().ToArray();
        WorldMap.CanPick = state == TunnelState.Disconnected;
        WorldMap.SetExit(displayed is null ? null : Country.Code(displayed.Name),
            _app.TunnelActive, displayed?.Name, _app.ProxyLatency, _app.MapHomeCountry, countries);
        MapLegendGroup.Visibility = knownServers.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        MapLegend.Text =
            $"{Counted(countries.Length, "страна", "страны", "стран")} · {Counted(knownServers.Count, "сервер", "сервера", "серверов")}";
        var hasCandidate = knownServers.Any(server => !server.IsHysteriaFamily);
        FastestBtn.IsEnabled = !_quickActionRunning && !_disconnectRequested && hasCandidate &&
            state is TunnelState.Connected or TunnelState.Disconnected;
        PingBtn.IsEnabled = !_quickActionRunning && knownServers.Count > 0;
        FastestBtn.ToolTip = _quickActionRunning ? "Идёт замер задержки" :
            !hasCandidate ? "Добавьте сервер, поддерживаемый Windows" :
            FastestBtn.IsEnabled ? "Подключить лучший сервер" : "Дождитесь завершения подключения";
        PingBtn.ToolTip = _quickActionRunning ? "Идёт замер задержки" :
            PingBtn.IsEnabled ? "Замерить задержку" : "Добавьте сервер для замера";
        RouteMode.Text = state == TunnelState.Connected ? "Системный VPN" : "Отключён";
        RouteMode.Foreground = (Brush)FindResource(_app.TunnelActive ? "Accent" : "TextDim");
        RouteTile.Tag = _app.TunnelActive;
        UsageButton.Opacity = _app.TunnelActive ? 1 : 0.52;
        UpdateLeakTile();
        ServerName.Text = displayed is { } server ? server.Name : "Выбрать сервер";
        ServerSubtitle.Text = displayed is { } chosen
            ? $"{chosen.Proto} · {chosen.Address}:{chosen.Port}" : "Добавьте ссылку или подписку";
        SetPingLabel(ServerPing, displayed is not null && _pingResults.TryGetValue(displayed.Id, out var ping)
            ? ping : null);

        KillSwitchSwitch.IsChecked = _app.State.KillSwitchEnabled;
        AdBlockSwitch.IsChecked = _app.AdBlockEnabled;
        KillSwitchCaption.Text = _app.KillSwitchActive ? "Блокировка активна"
            : _app.State.KillSwitchEnabled ? "Включится при следующем подключении"
            : "Блокировать трафик при обрыве туннеля";
        if (!Equals(MaskingBox.SelectedValue, _app.State.MaskingProfile))
            MaskingBox.SelectedValue = _app.State.MaskingProfile;
    }

    private static string Counted(int count, string one, string few, string many)
    {
        var ending = count % 100 is >= 11 and <= 14 ? many : (count % 10) switch
        {
            1 => one,
            2 or 3 or 4 => few,
            _ => many,
        };
        return $"{count} {ending}";
    }

    private void UpdateSession()
    {
        if (_app.ConnectedSince is { } since && _app.TunnelState == TunnelState.Connected)
        {
            var d = DateTimeOffset.UtcNow - since;
            SessionText.Text = $"· {(int)d.TotalHours:d2}:{d.Minutes:d2}:{d.Seconds:d2}";
            SessionText.Visibility = Visibility.Visible;
            if (_app.ProxyLatency is { } rtt)
            {
                PingText.Text = $"· {rtt} мс";
                PingText.Foreground = rtt < 200 ? (Brush)FindResource("Good")
                    : rtt < 600 ? (Brush)FindResource("Warn")
                    : (Brush)FindResource("Danger");
                PingText.Visibility = Visibility.Visible;
            }
        }
        else
        {
            SessionText.Visibility = Visibility.Collapsed;
            PingText.Visibility = Visibility.Collapsed;
            RateText.Visibility = Visibility.Collapsed;
            DownRate.Text = UpRate.Text = FormatRate(0);
            DownTotal.Text = UpTotal.Text = FormatBytes(0);
            TrafficPlot.Clear();
        }
    }

    private void OnStats(StatsSnapshot stats)
    {
        if (_app.TunnelState != TunnelState.Connected) return;
        TrafficPlot.Add(stats.DownRate, stats.UpRate);
        DownRate.Text = FormatRate(stats.DownRate);
        UpRate.Text = FormatRate(stats.UpRate);
        DownTotal.Text = FormatBytes(stats.TotalDown);
        UpTotal.Text = FormatBytes(stats.TotalUp);

        // Live rate in the status cluster too, like the macOS one-liner.
        if (_app.TunnelState == TunnelState.Connected
            && stats.UpRate + stats.DownRate > 0)
        {
            RateText.Text = $"· ↓ {FormatRate(stats.DownRate)} ↑ {FormatRate(stats.UpRate)}";
            RateText.Visibility = Visibility.Visible;
        }
        else
            RateText.Visibility = Visibility.Collapsed;
    }

    private static string FormatRate(long bytesPerSec) =>
        bytesPerSec >= 1 << 20 ? $"{bytesPerSec / (double)(1 << 20):f1} МБ/с"
        : bytesPerSec >= 1 << 10 ? $"{bytesPerSec / (1 << 10)} КБ/с"
        : $"{bytesPerSec} Б/с";

    private static string FormatBytes(long bytes) =>
        bytes >= 1L << 30 ? $"{bytes / (double)(1L << 30):f2} ГБ"
        : bytes >= 1L << 20 ? $"{bytes / (double)(1L << 20):f1} МБ"
        : bytes >= 1L << 10 ? $"{bytes / (double)(1L << 10):f0} КБ"
        : $"{bytes} Б";

    private static void SetPingLabel(TextBlock tb, int? rtt)
    {
        var view = tb;
        view.Text = rtt is null ? "—" : $"{rtt} мс";
        view.SetResourceReference(TextBlock.ForegroundProperty, rtt switch
        {
            null => "TextDim",
            < 200 => "Good",
            < 600 => "Warn",
            _ => "Danger",
        });
    }

    // ── Handlers ──────────────────────────────────────────────────────────

    private bool ConnectionRequested => _app.TunnelState != TunnelState.Disconnected || _app.KillSwitchActive;

    private bool CanConnectToSelection => _app.SelectedServer is { IsHysteriaFamily: false };

    private async void OnConnectToggle(object sender, RoutedEventArgs e)
    {
        // ToggleButton flips before Click; the engine owns the displayed state.
        ConnectSwitch.IsChecked = ConnectionRequested;
        _quickActionNotice = null;
        var stopping = ConnectionRequested;
        if (!stopping && !CanConnectToSelection)
        {
            OnStateChanged();
            OpenServers();
            return;
        }
        if (_disconnectRequested) return;
        if (stopping)
        {
            _disconnectRequested = true;
            OnStateChanged();
        }
        try { await _app.ToggleAsync(); }
        finally
        {
            if (stopping) _disconnectRequested = false;
            OnStateChanged();
        }
    }

    private void OnOpenServers(object sender, RoutedEventArgs e) => OpenServers();
    private void OnOpenSettings(object sender, RoutedEventArgs e) => OpenSettings();

    internal void OpenSettings() => PresentTool(_settings,
        () => new SettingsWindow(_app, () => string.Join(Environment.NewLine, _journal)),
        window => _settings = window);

    private void OnCloseWindow(object sender, RoutedEventArgs e) => SystemCommands.CloseWindow(this);

    private void OnMinimizeWindow(object sender, RoutedEventArgs e) => SystemCommands.MinimizeWindow(this);

    private void OnMaximizeWindow(object sender, RoutedEventArgs e)
    {
        if (WindowState == WindowState.Maximized)
            SystemCommands.RestoreWindow(this);
        else
            SystemCommands.MaximizeWindow(this);
    }

    private void OnOpenLeakTest(object sender, RoutedEventArgs e) => PresentTool(_leaks,
        () => new LeakTestWindow(_app, CurrentLeakReport(), (report, started) =>
        {
            _lastLeakReport = report;
            _leakSessionStarted = started;
            UpdateLeakTile();
        }),
        window => _leaks = window);

    private LeakTestModel.Report? CurrentLeakReport() =>
        _lastLeakReport is { } report && _leakSessionStarted == _app.ConnectedSince &&
        report.IsCurrent(_app.ActiveServer?.Id, DateTimeOffset.UtcNow) ? report : null;

    private void UpdateLeakTile()
    {
        var report = CurrentLeakReport();
        var clean = report is not null && LeakTestWindow.VerifiedClean(report);
        LeakTile.Tag = clean;
        LeakCaption.Text = clean ? $"Внешний IP {report!.Exit!.Ip} · утечки не обнаружены" :
            report?.Verdict == LeakTestModel.VerdictKind.Leaks ? "Последняя проверка выявила возможную утечку" :
            "Какой IP видят сайты, не утекают ли DNS и IPv6";
    }

    private void OnOpenStats(object sender, RoutedEventArgs e) => PresentTool(_stats,
        () => new StatsWindow(_app), window => _stats = window);

    private void SelectMapCountry(string code)
    {
        if (_app.TunnelState != TunnelState.Disconnected) return;
        var best = _app.AllServers
            .Where(server => !server.IsHysteriaFamily && Country.Code(server.Name) == code)
            .OrderBy(server => _pingResults.GetValueOrDefault(server.Id) ?? int.MaxValue)
            .FirstOrDefault();
        if (best is not null) _app.SelectServer(best.Id);
    }

    private string CountryDetails(string code)
    {
        var servers = _app.AllServers.Where(server => Country.Code(server.Name) == code).ToArray();
        var ping = servers.Select(server => _pingResults.GetValueOrDefault(server.Id)).Min();
        var count = Counted(servers.Length, "сервер", "сервера", "серверов");
        return $"{Country.Name(code)} · {count}" + (ping is { } ms ? $" · {ms} мс" : "");
    }

    private void OnAdBlockToggle(object sender, RoutedEventArgs e) =>
        _app.SetAdBlock(AdBlockSwitch.IsChecked == true);

    private void OpenServers() => PresentTool(_servers, () =>
    {
        var window = new ServersWindow(_app, _pingResults);
        window.PingSeeded += seed => { if (seed is { } id) RefreshCardPing(id); };
        window.StatusLog += line => Dispatcher.BeginInvoke(() => AppendLog(line));
        return window;
    }, window => _servers = window);

    private void PresentTool<T>(T? existing, Func<T> create, Action<T?> remember) where T : Window
    {
        if (existing is not null)
        {
            RestoreAndActivate(existing);
            return;
        }

        var tool = create();
        tool.ShowInTaskbar = false;
        tool.Owner = this;
        var closingFromForeground = false;
        tool.Closing += (_, _) => closingFromForeground = tool.IsActive;
        tool.Closed += (_, _) =>
        {
            remember(null);
            if (!closingFromForeground || App.ForceClose) return;
            Dispatcher.BeginInvoke(DispatcherPriority.ContextIdle, new Action(() =>
            {
                if (IsVisible && WindowState == WindowState.Minimized && !App.ForceClose)
                    RestoreAndActivate(this);
            }));
        };
        tool.Show();
        remember(tool);
    }

    internal static void RestoreAndActivate(Window window)
    {
        if (window.WindowState != WindowState.Minimized)
        {
            window.Activate();
            return;
        }
        SystemCommands.RestoreWindow(window);
        window.Dispatcher.BeginInvoke(DispatcherPriority.ContextIdle, new Action(() =>
        {
            if (window.IsVisible) window.Activate();
        }));
    }

    private void RefreshCardPing(Guid id)
    {
        if (_app.SelectedServer?.Id == id && _pingResults.TryGetValue(id, out var rtt))
        {
            SetPingLabel(ServerPing, rtt);
        }
    }

    private async void OnPickBest(object sender, RoutedEventArgs e)
    {
        if (_quickActionRunning) return;
        _quickActionRunning = true;
        _quickActionNotice = "Ищем лучший сервер…";
        OnStateChanged();
        try
        {
            var best = await _app.ConnectBestAsync(CancellationToken.None);
            _quickActionNotice = best is null ? "Не удалось замерить ни один сервер" : null;
            if (best is not null) AppendLog($"Выбран сервер {best.Name}");
            else AppendLog("У серверов пока нет успешных замеров");
        }
        finally
        {
            _quickActionRunning = false;
            OnStateChanged();
        }
    }

    private async void OnPingAll(object sender, RoutedEventArgs e)
    {
        if (_quickActionRunning) return;
        _quickActionRunning = true;
        _quickActionNotice = "Замеряем задержку…";
        OnStateChanged();
        try
        {
            await PingAllAsync();
        }
        finally
        {
            _quickActionRunning = false;
            _quickActionNotice = null;
            OnStateChanged();
        }
    }

    // Not async: SetKillSwitch is a synchronous state write, and an `async void`
    // without an await only makes the handler look like it can still be running
    // after it returned.
    private void OnKillSwitchToggle(object sender, RoutedEventArgs e) =>
        _app.SetKillSwitch(KillSwitchSwitch.IsChecked == true);

    private void OnMaskingChanged(object sender, SelectionChangedEventArgs e)
    {
        if (MaskingBox.SelectedValue is MaskingProfile p && p != _app.State.MaskingProfile)
            _app.SetMaskingProfile(p);
    }

    /// <summary>Sequential handshake probes (concurrency skews the timings),
    /// off the UI thread. Shared with the picker window.</summary>
    internal async Task PingAllAsync(IProgress<(ServerRow Row, int? Rtt)>? report = null)
    {
        var rows = _servers?.CurrentRows()
                   ?? _app.AllServers.Select(s => new ServerRow(s, (Brush)FindResource("TextDim"))).ToList();
        foreach (var row in rows)
        {
            var rtt = await LatencyProbe.HandshakePing(row.Server.Address, row.Server.Port);
            _pingResults[row.Server.Id] = rtt;
            if (rtt is { } ok) _app.RecordPing(row.Server, ok);
            report?.Report((row, rtt));
        }
        if (_app.SelectedServer is { } sel && _pingResults.TryGetValue(sel.Id, out var r))
            SetPingLabel(ServerPing, r);
    }

    private void AppendLog(string line)
    {
        if (_journal.Count == 400) _journal.Dequeue();
        _journal.Enqueue(line);
    }
}
