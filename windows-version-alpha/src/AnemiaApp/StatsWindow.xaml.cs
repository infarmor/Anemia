using System.Net.Http;
using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;
using AnemiaCore;

namespace AnemiaApp;

public partial class StatsWindow : AnemiaToolWindow
{
    private readonly AppState _app;
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(3) };
    private CancellationTokenSource? _measurement;
    private (bool Active, Guid? Server, DateTimeOffset? Since, TunnelState State) _measurementRoute;

    public StatsWindow(AppState app)
    {
        _app = app;
        InitializeComponent();
        _timer.Tick += (_, _) => UpdateUsage();
        _timer.Start();
        _app.StateChanged += RouteChanged;
        Closed += (_, _) =>
        {
            _timer.Stop();
            _app.StateChanged -= RouteChanged;
            _measurement?.Cancel();
        };
        UpdateUsage();
        RouteChanged();
    }

    private void UpdateUsage()
    {
        var usage = _app.Usage;
        var today = usage.Today;
        var month = usage.Month;
        TodayValue.Text = Formatting.Bytes(today.Total);
        TodayDetail.Text = Breakdown(today.Received, today.Sent);
        MonthValue.Text = Formatting.Bytes(month.Total);
        MonthDetail.Text = Breakdown(month.Received, month.Sent);
        var days = usage.RecentDays(14);
        var maximum = Math.Max(1L, days.Select(day => day.Total).DefaultIfEmpty().Max());
        Days.ItemsSource = days.Select(day => new DayBar(
            day.Total == 0 ? 1 : Math.Max(3, 62.0 * day.Total / maximum),
            $"{day.Id} · {Breakdown(day.Received, day.Sent)}")).ToArray();
        var servers = usage.TopServers;
        TopServers.ItemsSource = servers.Select(server => new ServerUsage(server.Name,
            Formatting.Bytes(server.Total), Breakdown(server.Received, server.Sent))).ToArray();
        NoTraffic.Visibility = servers.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void RouteChanged()
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.BeginInvoke(RouteChanged);
            return;
        }

        if (_measurement is not null && Route() != _measurementRoute) _measurement.Cancel();
        SpeedPath.Text = _app.TunnelActive && _app.ActiveServer is { } server
            ? $"Через VPN · {server.Name}"
            : _app.TunnelState == TunnelState.Disconnected ? "Напрямую, VPN выключен" : "Ожидание стабильного подключения";
        SpeedButton.IsEnabled = _measurement is not null || CanMeasure();
    }

    private (bool, Guid?, DateTimeOffset?, TunnelState) Route() =>
        (_app.TunnelActive, _app.ActiveServer?.Id, _app.ConnectedSince, _app.TunnelState);

    private bool CanMeasure() => _app.TunnelActive ||
        (_app.TunnelState == TunnelState.Disconnected && !_app.KillSwitchActive);

    private async void OnSpeed(object sender, RoutedEventArgs e)
    {
        if (_measurement is { } running)
        {
            running.Cancel();
            return;
        }
        if (!CanMeasure()) return;

        using var cancel = new CancellationTokenSource();
        _measurement = cancel;
        _measurementRoute = Route();
        SpeedButton.Content = "Остановить";
        SpeedValue.Text = "—";
        SetGauge(0);
        LatencyResult.Text = "Задержка —";
        DownloadResult.Text = "Приём —";
        UploadResult.Text = "Отдача —";
        var progress = new Progress<SpeedMeasurement.Reading>(reading =>
        {
            if (_measurement != cancel || cancel.IsCancellationRequested) return;
            var speed = Formatting.Speed(reading.Value);
            SpeedPhase.Text = reading.Phase switch
            {
                SpeedMeasurement.Phase.Latency => "Измеряем задержку",
                SpeedMeasurement.Phase.Download => "Приём",
                _ => "Отдача",
            };
            SpeedValue.Text = reading.Phase == SpeedMeasurement.Phase.Latency
                ? reading.Complete ? $"{reading.Value:0} мс" : "—"
                : speed;
            SetGauge(reading.Phase == SpeedMeasurement.Phase.Latency ? 0 : reading.Value);
            if (!reading.Complete) return;
            switch (reading.Phase)
            {
                case SpeedMeasurement.Phase.Latency: LatencyResult.Text = $"Задержка {reading.Value:0} мс"; break;
                case SpeedMeasurement.Phase.Download: DownloadResult.Text = $"Приём {speed}"; break;
                case SpeedMeasurement.Phase.Upload: UploadResult.Text = $"Отдача {speed}"; break;
            }
        });

        try
        {
            var result = await Task.Run(() => SpeedMeasurement.RunAsync(progress, cancel.Token), cancel.Token);
            cancel.Token.ThrowIfCancellationRequested();
            LatencyResult.Text = $"Задержка {result.Latency} мс";
            DownloadResult.Text = $"Приём {Formatting.Speed(result.Download)}";
            UploadResult.Text = result.Upload is { } upload ? $"Отдача {Formatting.Speed(upload)}" : "Отдача —";
            SpeedValue.Text = Formatting.Speed(result.Download);
            SetGauge(result.Download);
            SpeedPhase.Text = result.Upload is not null ? "Замер завершён" : "Скорость отдачи недоступна";
        }
        catch (OperationCanceledException) when (cancel.IsCancellationRequested)
        {
            SpeedPhase.Text = Route() == _measurementRoute ? "Замер остановлен" : "Подключение изменилось";
        }
        catch (Exception error) when (error is HttpRequestException or System.IO.IOException or OperationCanceledException)
        {
            SpeedPhase.Text = "Не удалось завершить тест скорости";
        }
        finally
        {
            _measurement = null;
            SpeedButton.Content = "Начать";
            RouteChanged();
        }
    }

    private void SetGauge(double rate)
    {
        if (rate <= 0)
        {
            SpeedArc.Data = Geometry.Empty;
            return;
        }
        var angle = Math.PI * Math.Clamp(Math.Log10(1 + rate / 1_000_000) / 3, 0, 1);
        var end = new System.Windows.Point(100 - 88 * Math.Cos(angle), 96 - 88 * Math.Sin(angle));
        var arc = new ArcSegment(end, new System.Windows.Size(88, 88), 0, false, SweepDirection.Clockwise, true);
        SpeedArc.Data = new PathGeometry(new[] { new PathFigure(new System.Windows.Point(12, 96), new[] { arc }, false) });
    }

    private void OnReset(object sender, RoutedEventArgs e)
    {
        if (System.Windows.MessageBox.Show(this, "Сбросить историю трафика на этом устройстве?", "Статистика",
                MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) != MessageBoxResult.Yes) return;
        _app.Usage.Reset();
        UpdateUsage();
    }

    private static string Breakdown(long received, long sent) =>
        $"↓ {Formatting.Bytes(received)}  ·  ↑ {Formatting.Bytes(sent)}";

    private sealed record DayBar(double Height, string Detail);
    private sealed record ServerUsage(string Name, string Total, string Detail);
}
