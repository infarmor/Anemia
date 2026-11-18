using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Windows;
using System.Windows.Controls;
using AnemiaCore;
using Button = System.Windows.Controls.Button;

namespace AnemiaApp;

internal sealed class LeakTestWindow : AnemiaToolWindow
{
    private readonly AppState _app;
    private readonly TextBlock _title;
    private readonly TextBlock _detail;
    private readonly StackPanel _results = new();
    private readonly Button _check = new() { Content = "Проверить", HorizontalAlignment = System.Windows.HorizontalAlignment.Right };
    private readonly CancellationTokenSource _lifetime = new();

    public LeakTestWindow(AppState app, LeakTestModel.Report? previous,
        Action<LeakTestModel.Report, DateTimeOffset?> onResult)
    {
        _app = app;
        Title = "Проверка утечек";
        Width = 470;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        SetResourceReference(BackgroundProperty, "Ground");
        var content = new StackPanel { Margin = new Thickness(20) };
        Content = new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden };
        _title = Label("Проверка утечек", "Text", 24);
        _title.SetResourceReference(TextBlock.FontFamilyProperty, "DisplayFont");
        _detail = Label("Внешний IP, IPv6 и DNS", "TextDim", 12);
        _detail.Margin = new Thickness(0, 3, 0, 14);
        content.Children.Add(_title);
        content.Children.Add(_detail);
        content.Children.Add(_results);
        _check.SetResourceReference(StyleProperty, "BtnPrimary");
        _check.Margin = new Thickness(0, 14, 0, 0);
        content.Children.Add(_check);
        if (previous is not null) Display(previous);
        Closed += (_, _) => { _lifetime.Cancel(); _lifetime.Dispose(); };
        _check.Click += async (_, _) =>
        {
            var token = _lifetime.Token;
            _check.IsEnabled = false;
            _title.Text = "Проверяем подключение…";
            _title.SetResourceReference(TextBlock.ForegroundProperty, "Text");
            _detail.Text = "Определяем видимые адреса и DNS-серверы.";
            _results.Children.Clear();
            var session = _app.ActiveServer?.Id;
            var since = _app.ConnectedSince;
            var physical = session is null || _app.KillSwitchActive ? null : PhysicalInterface.Detect();
            try
            {
                var report = await LeakTestModel.RunAsync(session, url => Fetch(url, null, token),
                    aroundTunnel: physical is null ? null : url => Fetch(url, physical, token),
                    resolve: async host =>
                    {
                        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
                        timeout.CancelAfter(TimeSpan.FromSeconds(6));
                        try { await Dns.GetHostAddressesAsync(host, timeout.Token); }
                        catch (Exception error) when (error is SocketException or OperationCanceledException) { }
                    });
                if (token.IsCancellationRequested) return;
                if (since != _app.ConnectedSince || session != _app.ActiveServer?.Id)
                {
                    _title.Text = "Подключение изменилось";
                    _detail.Text = "Повторите проверку для текущего подключения.";
                    return;
                }
                onResult(report, since);
                _app.UpdateMapOrigin(report.Direct?.CountryCode);
                Display(report);
            }
            catch (Exception error)
            {
                if (token.IsCancellationRequested) return;
                _title.Text = "Проверка прервалась";
                _detail.Text = error.Message;
            }
            finally { if (!token.IsCancellationRequested) _check.IsEnabled = true; }
        };
    }

    internal static bool VerifiedClean(LeakTestModel.Report report) =>
        report.Verdict == LeakTestModel.VerdictKind.Clean &&
        report.Dns is { Count: > 0 } && report.Direct?.CountryCode is { } home &&
        report.Exit?.CountryCode is { } exit && !home.Equals(exit, StringComparison.OrdinalIgnoreCase);

    private void Display(LeakTestModel.Report report)
    {
        var clean = VerifiedClean(report);
        _title.Text = report.Verdict switch
        {
            LeakTestModel.VerdictKind.Unprotected => "VPN отключён",
            LeakTestModel.VerdictKind.Failed => "Внешний IP недоступен",
            LeakTestModel.VerdictKind.Leaks => "Возможная утечка",
            _ => clean ? "Утечек не обнаружено" : "Проверка неполная",
        };
        _title.SetResourceReference(TextBlock.ForegroundProperty,
            clean || report.Verdict == LeakTestModel.VerdictKind.Leaks ? "Accent" : "Text");
        _detail.Text = report.Direct is null && report.ServerId is not null
            ? "Для сравнения нужен адрес провайдера."
            : !clean && report.Verdict == LeakTestModel.VerdictKind.Clean
                ? "Для полной проверки нужны данные DNS и различимые страны провайдера и выхода."
                : $"Замер в {report.Date.ToLocalTime():HH:mm}";
        _results.Children.Clear();
        AddRow("Внешний IP", Describe(report.Exit), report.Bypassed ? "Совпадает с адресом провайдера" : null);
        AddRow("IP провайдера", Describe(report.Direct));
        AddRow("IPv6", Describe(report.Ipv6), report.Ipv6Leak is null ? null : "Видна сеть провайдера");
        var dns = report.Dns is { Count: > 0 } resolvers
            ? string.Join("\n", resolvers.Select(server => Join(server.Ip, server.Country, server.Org)))
            : "Данные не получены";
        AddRow("DNS", dns, report.DnsLeak.Count == 0 ? null : "Найдены резолверы в стране провайдера");
    }

    private void AddRow(string title, string value, string? finding = null)
    {
        var row = new Border { Margin = new Thickness(0, 0, 0, 5), Padding = new Thickness(11, 7, 11, 7) };
        row.SetResourceReference(StyleProperty, "CardTile");
        var labels = new StackPanel();
        labels.Children.Add(Label(title, "TextDim", 11));
        labels.Children.Add(Label(value, "Text", 13));
        if (finding is not null) labels.Children.Add(Label(finding, "Accent", 11));
        row.Child = labels;
        _results.Children.Add(row);
    }

    private static TextBlock Label(string text, string brush, double size)
    {
        var label = new TextBlock { Text = text, FontSize = size, TextWrapping = TextWrapping.Wrap };
        label.SetResourceReference(TextBlock.ForegroundProperty, brush);
        return label;
    }

    private static string Describe(LeakCheck.IpInfo? info) =>
        info is null ? "Данные не получены" : Join(info.Ip, info.City, info.Country, info.Isp);

    private static string Join(params string?[] parts) => string.Join(" · ", parts.Where(value => !string.IsNullOrWhiteSpace(value)));

    private static async Task<string?> Fetch(string url, string? interfaceName, CancellationToken cancellationToken)
    {
        using var handler = new SocketsHttpHandler { UseProxy = false, AllowAutoRedirect = false };
        if (interfaceName is not null)
        {
            var nic = NetworkInterface.GetAllNetworkInterfaces().FirstOrDefault(adapter => adapter.Name == interfaceName);
            var properties = nic?.GetIPProperties();
            var source = properties?.UnicastAddresses.FirstOrDefault(value =>
                value.Address.AddressFamily == AddressFamily.InterNetwork)?.Address;
            if (source is null || properties?.GetIPv4Properties()?.Index is not { } index) return null;
            handler.ConnectCallback = async (context, ct) =>
            {
                var targets = await Dns.GetHostAddressesAsync(context.DnsEndPoint.Host, AddressFamily.InterNetwork, ct);
                var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
                try
                {
                    socket.SetSocketOption(SocketOptionLevel.IP, (SocketOptionName)31, IPAddress.HostToNetworkOrder(index));
                    socket.Bind(new IPEndPoint(source, 0));
                    await socket.ConnectAsync(targets, context.DnsEndPoint.Port, ct);
                    return new NetworkStream(socket, ownsSocket: true);
                }
                catch
                {
                    socket.Dispose();
                    throw;
                }
            };
        }
        using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(7), MaxResponseContentBufferSize = 65536 };
        try { return await client.GetStringAsync(url, cancellationToken); }
        catch (Exception error) when (error is HttpRequestException or IOException or SocketException or OperationCanceledException)
        {
            return null;
        }
    }
}
