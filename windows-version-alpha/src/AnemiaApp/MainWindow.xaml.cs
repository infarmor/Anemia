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

    public MainWindow(AppState app)
    {
        InitializeComponent();
        _app = app;

        MaskingBox.ItemsSource = Enum.GetValues<MaskingProfile>()
            .Select(p => new ComboItem(p, p.Title())).ToList();
        MaskingBox.DisplayMemberPath = nameof(ComboItem.Label);
        MaskingBox.SelectedValuePath = nameof(ComboItem.Profile);

        _app.StateChanged += OnStateChanged;
        _app.ServersChanged += OnStateChanged; // picker-driven selection updates the card
        _app.StatsUpdated += OnStats;
        _app.Log += line => Dispatcher.BeginInvoke(() => AppendLog(line));

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
        _clock.Tick += (_, _) => UpdateSession();
        _clock.Start();

        OnStateChanged();
        AppendLog("Anemia ready");
    }

    private sealed record ComboItem(MaskingProfile Profile, string Label)
    {
        public override string ToString() => Label;
    }

    // ── State binding ─────────────────────────────────────────────────────

    private void OnStateChanged()
    {
        // Status truth table, ported from the macOS RootView: Connected is
        // only "good" once the tunnel demonstrably passes traffic.
        var s = _app.TunnelState;
        string title;
        Brush dot;
        if (s == TunnelState.Connected && !_app.ProxyReachable)
        {
            title = "No route to server";
            dot = (Brush)FindResource("Danger");
        }
        else if (s == TunnelState.Connected && _app.UsesTunnelPublic && !_app.TunnelActive)
        {
            title = "Tunnel failed — SOCKS only";
            dot = (Brush)FindResource("Warn");
        }
        else
        {
            (title, dot) = s switch
            {
                TunnelState.Connected => _app.UsesTunnelPublic
                    ? ("Protected", (Brush)FindResource("Good"))
                    : ("Connected", (Brush)FindResource("Good")),
                TunnelState.Connecting => ("Connecting…", (Brush)FindResource("Warn")),
                TunnelState.Reconnecting => ("Reconnecting…", (Brush)FindResource("Warn")),
                _ => ("Not connected", (Brush)FindResource("TextDim")),
            };
        }
        StatusText.Text = title;
        StatusDot.Fill = dot;
        StatusText.Foreground = s == TunnelState.Disconnected
            ? (Brush)FindResource("TextDim") : dot;

        // Session timer + latency + throughput ride beside the status while
        // connected, exactly like the macOS status cluster.
        UpdateSession();
        PingText.Visibility = _app.ProxyLatency is { } && s == TunnelState.Connected
            ? Visibility.Visible : Visibility.Collapsed;

        // Tooltip carries the full detail the one-line cluster can't fit.
        StatusTip.Content = _app.TunnelState switch
        {
            TunnelState.Connected when _app.SelectedServer is { } sv =>
                $"{sv.Name}\nSOCKS 127.0.0.1:{_app.SocksPort} · HTTP 127.0.0.1:{_app.HttpPort}",
            _ => _app.LastError ?? "Select a server and connect",
        };

        ConnectSwitch.IsChecked = s != TunnelState.Disconnected;

        // Selected-server card.
        if (_app.SelectedServer is { } sel)
        {
            ServerName.Text = sel.Name.Length > 0 ? sel.Name : $"{sel.Address}:{sel.Port}";
            ServerSubtitle.Text = _app.TunnelState == TunnelState.Connected
                ? $"connected · SOCKS 127.0.0.1:{_app.SocksPort}"
                : "tap to change or re-ping";
            if (_pingResults.TryGetValue(sel.Id, out var rtt) && rtt is { } ok)
                SetPingLabel(ServerPing, ok);
            else
            {
                ServerPing.Text = "—";
                ServerPing.Foreground = (Brush)FindResource("TextDim");
            }
        }
        else
        {
            ServerName.Text = "No server selected";
            ServerSubtitle.Text = "Tap to import or choose a server";
            ServerPing.Text = "";
        }

        // Traffic-mode dot mirrors what actually routes the traffic.
        (ModeText.Text, ModeDot.Fill, ModeText.Foreground) = _app.TunnelState switch
        {
            TunnelState.Connected when _app.UsesTunnelPublic =>
                ("Tunnel", (Brush)FindResource("Good"), (Brush)FindResource("Text")),
            TunnelState.Connected =>
                ("Proxy", (Brush)FindResource("Warn"), (Brush)FindResource("TextDim")),
            _ => ("Off", (Brush)FindResource("TextDim"), (Brush)FindResource("TextDim")),
        };

        KillSwitchSwitch.IsChecked = _app.State.KillSwitchEnabled;
        KillSwitchCaption.Text = _app.State.KillSwitchEnabled
            ? "Armed — re-arms itself on every reconnect"
            : "Fail-closed — block traffic if the tunnel drops";

        if (MaskingBox.SelectedValue is MaskingProfile p && p != _app.State.MaskingProfile)
            MaskingBox.SelectedValue = _app.State.MaskingProfile;
        MaskingCaption.Text = _app.State.MaskingProfile.Title();
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
                PingText.Text = $"· {rtt} ms";
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
        }
    }

    private void OnStats(StatsSnapshot stats)
    {
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
        bytesPerSec >= 1 << 20 ? $"{bytesPerSec / (double)(1 << 20):f1} MB/s"
        : bytesPerSec >= 1 << 10 ? $"{bytesPerSec / (1 << 10)} KB/s"
        : $"{bytesPerSec} B/s";

    private static string FormatBytes(long bytes) =>
        bytes >= 1L << 30 ? $"{bytes / (double)(1L << 30):f2} GB"
        : bytes >= 1L << 20 ? $"{bytes / (double)(1L << 20):f1} MB"
        : bytes >= 1L << 10 ? $"{bytes / (double)(1L << 10):f0} KB"
        : $"{bytes} B";

    private static void SetPingLabel(TextBlock tb, int? rtt)
    {
        var view = tb;
        view.Text = rtt is null ? "—" : $"{rtt} ms";
        view.SetResourceReference(TextBlock.ForegroundProperty, rtt switch
        {
            null => "TextDim",
            < 200 => "Good",
            < 600 => "Warn",
            _ => "Danger",
        });
    }

    // ── Handlers ──────────────────────────────────────────────────────────

    private async void OnConnectToggle(object sender, RoutedEventArgs e) => await _app.ToggleAsync();

    private void OnOpenServers(object sender, RoutedEventArgs e) => OpenServers();
    private void OnOpenTransfer(object sender, RoutedEventArgs e)
    {
        var w = new TransferWindow(_app) { Owner = this };
        w.Show();
    }

    private void OnOpenSettings(object sender, RoutedEventArgs e)
    {
        var w = new SettingsWindow(_app) { Owner = this };
        w.Show();
    }

    private void OpenServers()
    {
        if (_servers is { } open && open.IsLoaded) { open.Activate(); return; }
        _servers = new ServersWindow(_app, _pingResults) { Owner = this };
        _servers.PingSeeded += seed => { if (seed is { } id) RefreshCardPing(id); };
        _servers.StatusLog += line => Dispatcher.BeginInvoke(() => AppendLog(line));
        _servers.Show();
    }

    private void RefreshCardPing(Guid id)
    {
        if (_app.SelectedServer?.Id == id && _pingResults.TryGetValue(id, out var rtt))
        {
            SetPingLabel(ServerPing, rtt);
            ServerSubtitle.Text = "tap to change or re-ping";
        }
    }

    private async void OnPickBest(object sender, RoutedEventArgs e)
    {
        FastestBtn.IsEnabled = false;
        try
        {
            var best = await _app.PickBestAsync(CancellationToken.None);
            if (best is not null) AppendLog($"selected best: {best.Name}");
            else AppendLog("no reachable server found");
        }
        finally { FastestBtn.IsEnabled = true; }
    }

    private async void OnPingAll(object sender, RoutedEventArgs e)
    {
        PingBtn.IsEnabled = false;
        try
        {
            await PingAllAsync();
        }
        finally { PingBtn.IsEnabled = true; }
    }

    // Not async: SetKillSwitch is a synchronous state write, and an `async void`
    // without an await only makes the handler look like it can still be running
    // after it returned.
    private void OnKillSwitchToggle(object sender, RoutedEventArgs) =>
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
        LogBox.AppendText(line + Environment.NewLine);
        LogBox.ScrollToEnd();
        if (LogBox.Text.Length > 64_000)
            LogBox.Text = LogBox.Text[16_000..]; // keep the tail, drop the bulk
    }
}