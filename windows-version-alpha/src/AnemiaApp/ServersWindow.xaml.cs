using System.Globalization;
using System.Windows;
using System.Windows.Input;
using AnemiaCore;
using Brush = System.Windows.Media.Brush;
using KeyEventArgs = System.Windows.Input.KeyEventArgs;
using MessageBox = System.Windows.MessageBox;

namespace AnemiaApp;

public partial class ServersWindow : AnemiaToolWindow
{
    private static readonly CultureInfo Russian = CultureInfo.GetCultureInfo("ru-RU");
    private readonly AppState _app;
    private readonly Dictionary<Guid, int?> _pingResults;
    private readonly Dictionary<Guid, ServerRow> _rows = new();
    private readonly Dictionary<Guid, int?> _trafficResults = new();
    private (MaskingProfile Profile, bool BlockAds)? _probeSettings;
    private CancellationTokenSource? _operation;
    private bool _showingTrafficStatus;
    private bool _closed;

    public event Action<Guid?>? PingSeeded;
    public event Action<string>? StatusLog;

    public ServersWindow(AppState app, Dictionary<Guid, int?> pingResults)
    {
        _app = app;
        _pingResults = pingResults;
        InitializeComponent();

        var history = new HistoryStore().Load();
        foreach (var server in _app.AllServers)
        {
            if (_pingResults.ContainsKey(server.Id) || !history.TryGetValue(server.IdentityKey, out var samples)) continue;
            var recent = samples.TakeLast(5).Order().ToArray();
            if (recent.Length > 0) _pingResults[server.Id] = (int)Math.Round(recent[recent.Length / 2]);
        }

        _app.ServersChanged += OnAppChanged;
        _app.StateChanged += OnAppChanged;
        RebuildList();
    }

    internal IReadOnlyList<ServerRow> CurrentRows() => _rows.Values.ToList();

    protected override void OnClosed(EventArgs e)
    {
        _closed = true;
        _operation?.Cancel();
        _app.ServersChanged -= OnAppChanged;
        _app.StateChanged -= OnAppChanged;
        base.OnClosed(e);
    }

    private void OnAppChanged() => Dispatcher.BeginInvoke(() =>
    {
        if (!_closed) RebuildList();
    });

    private void OnSearchChanged(object sender, System.Windows.Controls.TextChangedEventArgs e)
    {
        if (IsInitialized) RebuildList();
    }

    private void RebuildList()
    {
        if (_probeSettings is { } settings && settings != ProbeSettings)
        {
            _trafficResults.Clear();
            _probeSettings = null;
            if (_showingTrafficStatus) ShowStatus("Настройки изменились. Запустите проверку снова");
        }
        var servers = _app.AllServers;
        var liveIds = servers.Select(server => server.Id).ToHashSet();
        foreach (var id in _rows.Keys.Where(id => !liveIds.Contains(id)).ToArray())
        {
            _rows.Remove(id);
            _trafficResults.Remove(id);
            _pingResults.Remove(id);
        }

        foreach (var server in servers)
        {
            if (!_rows.TryGetValue(server.Id, out var row) || row.Server != server)
            {
                _trafficResults.Remove(server.Id);
                row = new ServerRow(server, ThemeBrush("TextDim"));
                _rows[server.Id] = row;
            }
            SetBadge(row);
        }

        var query = SearchBox.Text.Trim();
        var sections = new List<ServerSection>();
        var manual = Entries(_app.State.Servers, query, removable: true);
        if (manual.Count > 0) sections.Add(new ServerSection("Добавленные вручную", "", null, manual));
        foreach (var subscription in _app.State.Subscriptions)
        {
            var entries = Entries(subscription.Servers, query, removable: false);
            if (query.Length == 0 || entries.Count > 0)
                sections.Add(new ServerSection(SubscriptionName(subscription), SubscriptionDetails(subscription),
                                               subscription, entries, _app.PanelInfo(subscription)?.UsedFraction));
        }

        ServerList.ItemsSource = sections;
        var shown = sections.Sum(section => section.Servers.Count);
        CountText.Text = query.Length == 0 ? $"Серверов: {shown}" : $"Найдено: {shown} из {servers.Count}";
        EmptyText.Text = sections.Count == 0
            ? query.Length == 0 ? "Добавьте ссылку на сервер или подписку" : "Ничего не найдено"
            : "";
        UpdateActions();
    }

    private List<ServerEntry> Entries(IEnumerable<ProxyServer> servers, string query, bool removable)
    {
        var entries = new List<ServerEntry>();
        foreach (var server in servers)
        {
            if (!_rows.TryGetValue(server.Id, out var row) || !Matches(row, query)) continue;
            var canConnect = !server.IsHysteriaFamily;
            var state = server.IsHysteriaFamily ? "Недоступен на Windows" : ServerStatus(server);
            var subtitle = $"{Wire.Name(server.Proto).ToUpperInvariant()} · {server.Address}:{server.Port}";
            if (state.Length > 0) subtitle += " · " + state;
            entries.Add(new ServerEntry(row, subtitle, removable, canConnect));
        }
        return entries;
    }

    private string ServerStatus(ProxyServer server)
    {
        var connection = _app.ActiveServer?.Id == server.Id && _app.TunnelActive ? "Подключён"
            : _app.State.SelectedServerId == server.Id ? "Выбран" : "";
        if (!_trafficResults.TryGetValue(server.Id, out var rtt)) return connection;
        var traffic = rtt is { } ms ? $"Трафик проходит, {ms} мс" : "Проверка трафика не прошла";
        return connection.Length == 0 ? traffic : $"{connection} · {traffic}";
    }

    private static bool Matches(ServerRow row, string query)
    {
        if (query.Length == 0) return true;
        var code = Country.Code(row.Name);
        var fields = new[] { row.Name, row.Server.Address, Wire.Name(row.Server.Proto), code,
            code is null ? null : Country.Name(code), code is null ? null : EnglishCountryName(code) };
        return fields.Any(field => field is not null && Russian.CompareInfo.IndexOf(field, query,
            CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace) >= 0);
    }

    private static string? EnglishCountryName(string code)
    {
        try { return new RegionInfo(code).EnglishName; }
        catch (ArgumentException) { return null; }
    }

    private (MaskingProfile Profile, bool BlockAds) ProbeSettings => (_app.State.MaskingProfile, _app.AdBlockEnabled);

    private string SubscriptionName(Subscription subscription) =>
        _app.PanelInfo(subscription)?.Title ?? subscription.Name;

    private string SubscriptionDetails(Subscription subscription)
    {
        var info = _app.PanelInfo(subscription);
        var fields = new List<string> { $"Серверов: {subscription.Servers.Count}" };
        if (info?.Used is { } used)
            fields.Add(info.Total is > 0 ? $"{Formatting.Bytes(used)} из {Formatting.Bytes(info.Total.Value)}"
                                          : $"Использовано {Formatting.Bytes(used)}");
        if (info?.ExpiresEpochSeconds is { } expires && expires >= 0 && expires <= 253402300799)
        {
            var date = DateTimeOffset.FromUnixTimeSeconds(expires);
            fields.Add((date <= DateTimeOffset.Now ? "Истекла " : "До ") + date.ToLocalTime().ToString("d MMM yyyy", Russian));
        }
        if (subscription.LastUpdated is { } updated) fields.Add($"Обновлена {updated.ToLocalTime().ToString("d MMM, HH:mm", Russian)}");
        if (!subscription.TlsProtected) fields.Add("Без HTTPS, обновляется вручную");
        if (info?.Announcement is { Length: > 0 } announcement) fields.Add(announcement);
        return string.Join(" · ", fields);
    }

    private Brush ThemeBrush(string key) => (Brush)FindResource(key);

    private void SetBadge(ServerRow row)
    {
        var hasResult = _pingResults.TryGetValue(row.Id, out var rtt);
        row.Ping = rtt is { } ms ? $"{ms} мс" : hasResult ? "Нет ответа" : "—";
        row.PingBrush = ThemeBrush(rtt switch
        {
            null => "TextDim",
            < 200 => "Good",
            < 600 => "Warn",
            _ => "Danger",
        });
        row.DotBrush = ThemeBrush(_app.ActiveServer?.Id == row.Id && _app.TunnelActive ? "Good"
            : _app.State.SelectedServerId == row.Id ? "Accent" : "TextDim");
    }

    private void UpdateActions()
    {
        var idle = _operation is null;
        var available = _rows.Values.Any(row => !row.Server.IsHysteriaFamily);
        var canCheck = _rows.Values.Any(row => ServerTrafficProbe.Supports(row.Server));
        PingAllBtn.IsEnabled = idle && available;
        CheckBtn.IsEnabled = idle && canCheck && !_app.KillSwitchActive;
        CheckBtn.ToolTip = _app.KillSwitchActive
            ? "Активный Kill switch разрешает соединение только с текущим сервером"
            : "Проверяет запрос через каждый сервер Xray";
        RefreshBtn.IsEnabled = idle && _app.State.Subscriptions.Count > 0;
        BestBtn.IsEnabled = idle && available && _app.TunnelState is TunnelState.Connected or TunnelState.Disconnected;
        ImportBtn.IsEnabled = idle;
        CancelBtn.Visibility = idle ? Visibility.Collapsed : Visibility.Visible;
    }

    private void ShowStatus(string message, bool log = false, bool traffic = false)
    {
        if (_closed) return;
        StatusText.Text = message;
        _showingTrafficStatus = traffic;
        if (log) StatusLog?.Invoke(message);
    }

    private async Task RunOperation(Func<CancellationToken, Task> action)
    {
        if (_operation is not null) return;
        using var cancel = new CancellationTokenSource();
        _operation = cancel;
        UpdateActions();
        try
        {
            await action(cancel.Token);
        }
        catch (OperationCanceledException) when (cancel.IsCancellationRequested)
        {
            ShowStatus("Отменено");
        }
        finally
        {
            _operation = null;
            if (!_closed) RebuildList();
        }
    }

    private void OnCancelOperation(object sender, RoutedEventArgs e) => _operation?.Cancel();

    private void OnShowImport(object sender, RoutedEventArgs e)
    {
        ImportPanel.Visibility = Visibility.Visible;
        ImportBox.Focus();
    }

    private void OnHideImport(object sender, RoutedEventArgs e) => ImportPanel.Visibility = Visibility.Collapsed;

    private void OnImportKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter || (Keyboard.Modifiers & ModifierKeys.Control) == 0) return;
        e.Handled = true;
        OnImport(sender, e);
    }

    private async void OnImport(object sender, RoutedEventArgs e)
    {
        var value = ImportBox.Text.Trim();
        if (value.Length == 0)
        {
            ShowStatus("Вставьте ссылку или конфигурацию");
            return;
        }

        await RunOperation(async ct =>
        {
            if (!value.Contains('\n') && Uri.TryCreate(value, UriKind.Absolute, out var url)
                && url.Scheme is "http" or "https")
            {
                ShowStatus("Загружаем подписку…");
                var (subscription, status) = await _app.AddAndFetchAsync(url.ToString(), ct);
                ct.ThrowIfCancellationRequested();
                ShowStatus(status, log: true);
                if (subscription is null) return;
            }
            else
            {
                var (added, failed) = _app.AddFromText(value);
                if (added == 0)
                {
                    ShowStatus(failed > 0 ? "Не удалось импортировать. Проверьте ссылку или конфигурацию"
                                          : "Эти серверы уже добавлены", log: true);
                    return;
                }
                ShowStatus(failed > 0 ? $"Серверов добавлено: {added}, пропущено: {failed}"
                                      : $"Серверов добавлено: {added}", log: true);
            }
            ImportBox.Clear();
            ImportPanel.Visibility = Visibility.Collapsed;
        });
    }

    private void OnSelectServer(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { DataContext: ServerEntry { CanConnect: true } entry }) return;
        if (_app.State.SelectedServerId != entry.Row.Id) _app.SelectServer(entry.Row.Id);
        ShowStatus($"Выбран сервер {entry.Row.Name}");
    }

    private async void OnConnectServer(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { DataContext: ServerEntry { CanConnect: true } entry }) return;
        ShowStatus($"Подключаем {entry.Row.Name}…");
        await _app.ConnectServerAsync(entry.Row.Id);
        ShowStatus(_app.LastError ?? (_app.TunnelActive && _app.ActiveServer?.Id == entry.Row.Id
            ? $"Подключён сервер {entry.Row.Name}" : $"Выбран сервер {entry.Row.Name}"), log: true);
    }

    private void OnRemoveServer(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { DataContext: ServerEntry { CanRemove: true } entry }) return;
        _app.RemoveServer(entry.Row.Id);
        ShowStatus($"Сервер {entry.Row.Name} удалён", log: true);
    }

    private async void OnRefreshSubscription(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { DataContext: ServerSection { Subscription: { } subscription } }) return;
        await RunOperation(async ct =>
        {
            ShowStatus($"Обновляем {SubscriptionName(subscription)}…");
            var status = await _app.RefreshSubscriptionAsync(subscription, ct, allowInsecure: true);
            ct.ThrowIfCancellationRequested();
            ShowStatus(status, log: true);
        });
    }

    private void OnRemoveSubscription(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { DataContext: ServerSection { Subscription: { } subscription } }) return;
        var name = SubscriptionName(subscription);
        if (MessageBox.Show(this, $"Удалить «{name}» и все её серверы?", "Удаление подписки",
                            MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) != MessageBoxResult.Yes) return;
        _app.RemoveSubscription(subscription.Id);
        ShowStatus($"Подписка «{name}» удалена", log: true);
    }

    private async void OnRefreshSubs(object sender, RoutedEventArgs e) => await RunOperation(async ct =>
    {
        var subscriptions = _app.State.Subscriptions.ToList();
        var errors = new List<string>();
        for (var i = 0; i < subscriptions.Count; i++)
        {
            ct.ThrowIfCancellationRequested();
            var subscription = subscriptions[i];
            ShowStatus($"Обновляем подписки: {i + 1} из {subscriptions.Count}");
            var previous = subscription.LastUpdated;
            var status = await _app.RefreshSubscriptionAsync(subscription, ct, allowInsecure: true);
            StatusLog?.Invoke(status);
            if (subscription.LastUpdated == previous) errors.Add(status);
        }
        ct.ThrowIfCancellationRequested();
        var updated = subscriptions.Count - errors.Count;
        ShowStatus(errors.Count > 0 ? $"Подписок обновлено: {updated} из {subscriptions.Count}. {errors[0]}"
                                    : $"Подписок обновлено: {updated}");
    });

    private async void OnPickBest(object sender, RoutedEventArgs e) => await RunOperation(async ct =>
    {
        ShowStatus("Ищем лучший доступный сервер…");
        var best = await _app.ConnectBestAsync(ct);
        ShowStatus(best is null ? "У поддерживаемых серверов нет успешных замеров"
            : _app.LastError ?? (_app.TunnelActive && _app.ActiveServer?.Id == best.Id
                ? $"Подключён сервер {best.Name}" : $"Выбран сервер {best.Name}"), log: true);
        PingSeeded?.Invoke(best?.Id);
    });

    private async void OnPingAll(object sender, RoutedEventArgs e) => await RunOperation(async ct =>
    {
        var rows = CurrentRows().Where(row => !row.Server.IsHysteriaFamily).ToList();
        for (var i = 0; i < rows.Count; i++)
        {
            ct.ThrowIfCancellationRequested();
            var row = rows[i];
            ShowStatus($"Замеряем задержку: {i + 1} из {rows.Count}");
            var rtt = await LatencyProbe.HandshakePing(row.Server.Address, row.Server.Port);
            ct.ThrowIfCancellationRequested();
            if (!_rows.ContainsKey(row.Id)) continue;
            _pingResults[row.Id] = rtt;
            if (rtt is { } ms) _app.RecordPing(row.Server, ms);
            SetBadge(_rows[row.Id]);
            PingSeeded?.Invoke(row.Id);
        }
        ShowStatus($"Задержка измерена. Ответили: {rows.Count(row => _pingResults.GetValueOrDefault(row.Id) is not null)} из {rows.Count}");
    });

    private async void OnCheckAll(object sender, RoutedEventArgs e) => await RunOperation(async ct =>
    {
        var servers = _app.AllServers.Where(ServerTrafficProbe.Supports).ToList();
        var settings = ProbeSettings;
        _probeSettings = settings;
        _trafficResults.Clear();
        RebuildList();
        try
        {
            for (var i = 0; i < servers.Count; i++)
            {
                ct.ThrowIfCancellationRequested();
                if (_app.KillSwitchActive)
                {
                    ShowStatus("Проверка приостановлена. Активен Kill switch");
                    return;
                }
                ShowStatus($"Проверяем трафик: {i + 1} из {servers.Count}", traffic: true);
                var server = servers[i];
                var result = await ServerTrafficProbe.CheckAsync(server, settings.Profile.Options(), settings.BlockAds, ct);
                if (_probeSettings is null || settings != ProbeSettings)
                {
                    ShowStatus("Настройки изменились. Запустите проверку снова");
                    return;
                }
                if (_rows.TryGetValue(server.Id, out var row) && row.Server == server)
                    _trafficResults[server.Id] = result;
            }
        }
        catch (XrayException ex) when (ex.Kind == XrayErrorKind.BinaryNotFound)
        {
            ShowStatus("Для проверки трафика нужен Xray, файл не найден", log: true);
            return;
        }
        var passing = servers.Count(server => _trafficResults.GetValueOrDefault(server.Id) is not null);
        ShowStatus($"Трафик проходит через {passing} из {servers.Count} серверов Xray", log: true, traffic: true);
    });

    public sealed record ServerEntry(ServerRow Row, string Subtitle, bool CanRemove, bool CanConnect);

    public sealed record ServerSection(string Title, string Details, Subscription? Subscription,
                                       List<ServerEntry> Servers, double? Quota = null)
    {
        public bool IsSubscription => Subscription is not null;
        public bool HasDetails => Details.Length > 0;
        public bool HasQuota => Quota.HasValue;
        public double UsedFraction => Quota ?? 0;
    }
}
