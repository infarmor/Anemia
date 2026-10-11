using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Media;
using AnemiaCore;
using Brush = System.Windows.Media.Brush;

namespace AnemiaApp;

public partial class ServersWindow : Window
{
    private readonly AppState _app;
    private readonly Dictionary<Guid, int?> _pingResults;
    private readonly ObservableCollection<ServerRow> _rows = new();

    /// <summary>Raised after a fresh probe lands, with the server's id — the
    /// main window keeps the selected-server card's badge in sync with it.</summary>
    public event Action<Guid?>? PingSeeded;
    /// <summary>Status lines (import results, subscription fetches) for the
    /// main window's log tile.</summary>
    public event Action<string>? StatusLog;

    public ServersWindow(AppState app, Dictionary<Guid, int?> pingResults)
    {
        InitializeComponent();
        _app = app;
        _pingResults = pingResults;
        DataContext = this;
        ServerList.ItemsSource = _rows;

        _app.ServersChanged += OnServersChanged;

        RebuildRows();
        // Badges seed from persisted history so the sheet is informative
        // before the first fresh probe of the session.
        SeedFromHistory();
        var selectedId = _app.State.SelectedServerId;
        foreach (var row in _rows)
            row.DotBrush = row.Id == selectedId ? (Brush)FindResource("Good") : Dim();
    }

    public ObservableCollection<ServerRow> Rows => _rows;

    internal IReadOnlyList<ServerRow> CurrentRows() => _rows.ToList();

    protected override void OnClosed(EventArgs e)
    {
        _app.ServersChanged -= OnServersChanged;
        base.OnClosed(e);
    }

    private Brush Dim() => (Brush)FindResource("TextDim");

    private void OnServersChanged()
    {
        var selectedId = _app.State.SelectedServerId;
        Dispatcher.BeginInvoke(() =>
        {
            // Keep probe results that still refer to living servers.
            RebuildRows();
            foreach (var row in _rows)
            {
                var dotBrush = row.Id == selectedId ? (Brush)FindResource("Good") : Dim();
                row.DotBrush = dotBrush;
                if (_pingResults.TryGetValue(row.Id, out var rtt)) SetBadge(row, rtt);
            }
        });
    }

    private void RebuildRows()
    {
        var selectedId = _app.State.SelectedServerId;
        var known = _app.AllServers.Select(s => s.Id).ToHashSet();
        for (var i = _rows.Count - 1; i >= 0; i--)
            if (!known.Contains(_rows[i].Id)) _rows.RemoveAt(i);
        var present = _rows.Select(r => r.Id).ToHashSet();
        foreach (var server in _app.AllServers)
            if (present.Add(server.Id)) _rows.Add(new ServerRow(server, Dim()));
    }

    /// <summary>Seed the ping badges from persisted history (median of the
    /// last five samples), preserving any fresher in-session results.</summary>
    private void SeedFromHistory()
    {
        Dictionary<string, List<float>> history;
        try { history = new AnemiaCore.HistoryStore().Load(); }
        catch (System.IO.IOException) { return; }
        foreach (var row in _rows)
        {
            if (_pingResults.ContainsKey(row.Id)) continue;
            if (!history.TryGetValue(row.Server.IdentityKey, out var past) || past.Count == 0) continue;
            var recent = past.TakeLast(5).OrderBy(v => v).ToList();
            SetBadge(row, (int)Math.Round(recent[recent.Count / 2]));
        }
    }

    private void SetBadge(ServerRow row, int? rtt)
    {
        row.Ping = rtt is null ? "—" : $"{rtt} ms";
        row.PingBrush = (Brush)FindResource(rtt switch
        {
            null => "TextDim",
            < 200 => "Good",
            < 600 => "Warn",
            _ => "Danger",
        });
        row.DotBrush = row.Id == _app.State.SelectedServerId
            ? (Brush)FindResource("Good") : Dim();
    }

    // ── Handlers ──────────────────────────────────────────────────────────

    private void OnRowClick(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not ServerRow row) return;
        _app.SelectServer(row.Id);
        // macOS sheet behaviour: picking a server while disconnected just
        // selects; while connected the app re-dials on its own.
    }

    private void OnRemove(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not ServerRow row) return;
        _app.RemoveServer(row.Id);
        _pingResults.Remove(row.Id);
    }

    private void OnImport(object sender, RoutedEventArgs e)
    {
        var text = ImportBox.Text.Trim();
        if (text.Length == 0) return;
        // A single non-link string is treated as a subscription URL by the
        // add-subscription button; Import only consumes share links.
        var (added, failed) = _app.AddFromText(text);
        ImportBox.Clear();
        Log($"import: {added} added, {failed} skipped");
    }

    private void OnImportKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == System.Windows.Input.Key.Enter) OnImport(sender, e);
    }

    private async void OnAddSubscription(object sender, RoutedEventArgs e)
    {
        var url = ImportBox.Text.Trim();
        if (url.Length == 0 || !Uri.TryCreate(url, UriKind.Absolute, out var uri)
            || uri.Scheme is not ("http" or "https"))
        {
            Log("add-subscription: paste a subscription URL in the field first");
            return;
        }
        var (sub, status) = await _app.AddAndFetchAsync(uri.ToString(), CancellationToken.None);
        Log(sub is null ? status : $"subscription {sub.Name}: {status}");
    }

    private async void OnRefreshSubs(object sender, RoutedEventArgs e)
    {
        // Pressing the button IS the request: an unencrypted panel is fetched for
        // a person, never for a timer.
        foreach (var status in await _app.RefreshAllSubscriptionsAsync(CancellationToken.None, allowInsecure: true))
            Log(status);
    }

    private async void OnPickBest(object sender, RoutedEventArgs e)
    {
        BestBtn.IsEnabled = false;
        try
        {
            var best = await _app.PickBestAsync(CancellationToken.None);
            Log(best is not null ? $"selected best: {best.Name}" : "no reachable server found");
            PingSeeded?.Invoke(best?.Id);
        }
        finally { BestBtn.IsEnabled = true; }
    }

    private async void OnPingAll(object sender, RoutedEventArgs e)
    {
        PingAllBtn.IsEnabled = false;
        try
        {
            var progress = new Progress<(ServerRow Row, int? Rtt)>(t =>
            {
                SetBadge(t.Row, t.Rtt);
                PingSeeded?.Invoke(t.Row.Id);
            });
            // The main window owns the probe loop so both windows share the
            // sequential ordering (concurrent handshakes skew timings).
            if (Owner is MainWindow mw) await mw.PingAllAsync(progress);
            else await PingSequential();
        }
        finally { PingAllBtn.IsEnabled = true; }
    }

    private async Task PingSequential()
    {
        foreach (var row in _rows)
        {
            var rtt = await LatencyProbe.HandshakePing(row.Server.Address, row.Server.Port);
            _pingResults[row.Server.Id] = rtt;
            if (rtt is { } ok) _app.RecordPing(row.Server, ok);
            SetBadge(row, rtt);
        }
    }

    private void Log(string line) => StatusLog?.Invoke(line);
}