using System.IO;
using System.Runtime.InteropServices;
using System.Security;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using AnemiaCore;
using Microsoft.Win32;
using Button = System.Windows.Controls.Button;
using Clipboard = System.Windows.Clipboard;
using ComboBox = System.Windows.Controls.ComboBox;
using HorizontalAlignment = System.Windows.HorizontalAlignment;
using Path = System.IO.Path;
using Rectangle = System.Windows.Shapes.Rectangle;
using TextBox = System.Windows.Controls.TextBox;

namespace AnemiaApp;

public partial class SettingsWindow : AnemiaToolWindow
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string RunValue = "Anemia";

    private readonly AppState _app;
    private readonly Func<string> _journal;
    private readonly DispatcherTimer _journalTimer = new() { Interval = TimeSpan.FromMilliseconds(400) };
    private readonly CancellationTokenSource _lifetime = new();
    private readonly TextBlock _generalInfo = new() { Visibility = Visibility.Collapsed };
    private readonly TextBlock _killInfo = Caption();
    private readonly TextBlock _helperInfo = Caption();
    private readonly TextBlock _rulesInfo = Caption();
    private readonly TextBlock _diagnosticsInfo = Caption();
    private readonly TextBox _rules = Editor("Правила исключений", false, 108);
    private readonly TextBox _log = Editor("Журнал подключения", true, 148);
    private readonly ComboBox _masking = new();
    private TransferWindow? _transfer;
    private ToggleButton _startup = null!;
    private ToggleButton _autoConnect = null!;
    private ToggleButton _subscriptionRefresh = null!;
    private ToggleButton _killSwitch = null!;
    private ToggleButton _adBlock = null!;
    private ToggleButton _bypass = null!;
    private Button _saveRules = null!;
    private string _savedRules = "";
    private bool _syncing;
    private bool _startupEnabled;
    private bool? _helperAvailable;
    private bool _refreshing;

    public SettingsWindow(AppState app, Func<string> journal)
    {
        _app = app;
        _journal = journal;
        InitializeComponent();

        BuildGeneral();
        BuildProtection();
        BuildNetwork();
        BuildDiagnostics();
        BuildAbout();
        _generalInfo.SetResourceReference(StyleProperty, "Dim");
        _generalInfo.TextWrapping = TextWrapping.Wrap;
        Activated += (_, _) => LoadStartup();
        SyncState();

        _app.StateChanged += SyncState;
        Tabs.SelectionChanged += OnTabChanged;
        _rules.TextChanged += (_, _) => UpdateRulesPreview();
        _journalTimer.Tick += (_, _) => UpdateJournal();
        Loaded += (_, _) => UpdateJournal();
        Closed += (_, _) =>
        {
            _app.StateChanged -= SyncState;
            _journalTimer.Stop();
            _lifetime.Cancel();
            _lifetime.Dispose();
        };
    }

    private void BuildGeneral()
    {
        _startup = Switch("Запускать при входе в Windows", OnStartup);
        _autoConnect = Switch("Подключаться при запуске", (_, _) => _app.SetAutoConnect(_autoConnect.IsChecked == true));
        _subscriptionRefresh = Switch("Автообновление подписок",
            (_, _) => _app.SetSubscriptionAutoRefresh(_subscriptionRefresh.IsChecked == true));
        Group(GeneralPane, "Запуск",
            Row("startup", "Запускать при входе в Windows", "Открывает Anemia после входа в учётную запись", _startup),
            Row("power", "Подключаться при запуске", "Использовать выбранный сервер или лучший из списка", _autoConnect),
            Row("refresh", "Автообновление подписок", "Проверять обновления по расписанию подписок", _subscriptionRefresh));
        GeneralPane.Children.Add(_generalInfo);
        Group(GeneralPane, "Данные",
            Row("transfer", "Перенос серверов", "Импорт и экспорт списка и настроек VPN",
                Action("Открыть…", (_, _) => OpenTransfer())));
    }

    private void OpenTransfer()
    {
        if (_transfer is { IsLoaded: true } existing)
        {
            if (existing.WindowState == WindowState.Minimized) SystemCommands.RestoreWindow(existing);
            existing.Activate();
            return;
        }
        var transfer = new TransferWindow(_app) { Owner = this };
        _transfer = transfer;
        transfer.Closed += (_, _) => _transfer = null;
        transfer.Show();
    }

    private void BuildProtection()
    {
        _killSwitch = Switch("Kill switch", (_, _) => _app.SetKillSwitch(_killSwitch.IsChecked == true));
        _adBlock = Switch("Блокировать рекламу", (_, _) => _app.SetAdBlock(_adBlock.IsChecked == true));
        _masking.ItemsSource = Enum.GetValues<MaskingProfile>()
            .Select(profile => new MaskingChoice(profile, MaskingName(profile))).ToArray();
        _masking.DisplayMemberPath = nameof(MaskingChoice.Label);
        _masking.SelectedValuePath = nameof(MaskingChoice.Profile);
        _masking.MinWidth = 140;
        _masking.SetResourceReference(StyleProperty, "MiniCombo");
        AutomationProperties.SetName(_masking, "Профиль маскирования");
        _masking.SelectionChanged += (_, _) =>
        {
            if (!_syncing && _masking.SelectedValue is MaskingProfile profile && profile != _app.State.MaskingProfile)
                _app.SetMaskingProfile(profile);
        };
        Group(ProtectionPane, "Защита трафика",
            Row("guard", "Kill switch", "Блокирует трафик при обрыве туннеля", _killSwitch, _killInfo),
            Row("block", "Блокировать рекламу", "AdGuard DNS со следующего подключения", _adBlock),
            Row("masking", "Маскирование", "Профиль подключения Xray", _masking));
    }

    private void BuildNetwork()
    {
        _bypass = Switch("Исключения VPN", OnBypass);
        _saveRules = Action("Сохранить", OnSaveRules);
        var help = Caption("По одному адресу на строку. Например, example.com или 192.168.0.0/16.");
        var editor = new StackPanel { Margin = new Thickness(12, 6, 12, 10) };
        help.Margin = new Thickness(0, 0, 0, 8);
        _rulesInfo.Margin = new Thickness(0, 7, 0, 8);
        _saveRules.HorizontalAlignment = HorizontalAlignment.Right;
        editor.Children.Add(help);
        editor.Children.Add(_rules);
        editor.Children.Add(_rulesInfo);
        editor.Children.Add(_saveRules);
        Group(NetworkPane, "Маршрутизация",
            Row("route", "Исключения VPN", "Перечисленные адреса идут через обычное подключение", _bypass),
            editor);
    }

    private void BuildDiagnostics()
    {
        _helperInfo.Text = HelperLabel();
        Group(DiagnosticsPane, "Системный VPN",
            Row("guard", "Служба туннеля", "", Action("Обновить", async (_, _) => await UpdateHelper()), _helperInfo),
            Row("copy", "Отчёт о состоянии", "Версия, компоненты и состояние VPN",
                Action("Скопировать", (_, _) => Copy(BuildReport()))));
        var block = new StackPanel { Margin = new Thickness(12, 4, 12, 12) };
        block.Children.Add(_log);
        Group(DiagnosticsPane, "Журнал",
            Row("log", "Журнал подключения", "Обновляется во время работы VPN",
                Action("Скопировать", (_, _) => Copy(_journal()))), block);
        DiagnosticsPane.Children.Add(_diagnosticsInfo);
    }

    private void BuildAbout()
    {
        Group(AboutPane, "Приложение",
            Row("info", "Anemia для Windows", VersionLabel()),
            Row("info", "Система", $"Windows {Environment.OSVersion.Version} · {RuntimeInformation.OSArchitecture}"));
        Group(AboutPane, "Компоненты",
            Row("engine", "Xray", ComponentState(_app.InstalledXrayPath)),
            Row("engine", "AmneziaWG", ComponentState(FindComponent("anemia-engine.exe"))),
            Row("guard", "Служба системного VPN", ComponentState(FindComponent("AnemiaHelper.exe"))),
            Row("engine", "Адаптер Wintun", ComponentState(FindComponent("wintun.dll"))));
    }

    private void SyncState()
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.BeginInvoke(SyncState);
            return;
        }
        _syncing = true;
        try
        {
            var state = _app.State;
            _autoConnect.IsChecked = state.AutoConnectOnLaunch;
            _subscriptionRefresh.IsChecked = state.SubscriptionAutoRefresh;
            _killSwitch.IsChecked = state.KillSwitchEnabled;
            _adBlock.IsChecked = _app.AdBlockEnabled;
            _masking.SelectedValue = state.MaskingProfile;
            _bypass.IsChecked = state.SplitTunnel.Enabled;
            _killInfo.Text = _app.KillSwitchActive ? "Блокировка активна"
                : state.KillSwitchEnabled ? "Включится при следующем подключении"
                : "Блокирует трафик при обрыве туннеля";
            var clean = _rules.Text == _savedRules;
            _savedRules = string.Join(Environment.NewLine, state.SplitTunnel.Entries);
            if (clean) _rules.Text = _savedRules;
            UpdateRulesPreview();
        }
        finally { _syncing = false; }
    }

    private void OnBypass(object sender, RoutedEventArgs args)
    {
        var active = _bypass.IsChecked == true;
        var stored = _app.State.SplitTunnel;
        if (active && SplitTunnelParser.Parse(stored.Entries).Rejected.Count > 0)
        {
            _bypass.IsChecked = stored.Enabled;
            _rulesInfo.Text = "Исправьте сохранённые правила перед включением исключений.";
            return;
        }
        _app.SetSplitTunnel(active, stored.Entries);
    }

    private void OnSaveRules(object sender, RoutedEventArgs args)
    {
        var lines = ReadLines(_rules.Text);
        if (SplitTunnelParser.Parse(lines).Rejected.Count > 0) return;
        _savedRules = _rules.Text;
        _app.SetSplitTunnel(_bypass.IsChecked == true, lines);
        UpdateRulesPreview();
    }

    private void UpdateRulesPreview()
    {
        var parsed = SplitTunnelParser.Parse(ReadLines(_rules.Text));
        _saveRules.IsEnabled = _rules.Text != _savedRules && parsed.Rejected.Count == 0;
        _rulesInfo.SetResourceReference(TextBlock.ForegroundProperty, parsed.Rejected.Count > 0 ? "Danger" : "TextDim");
        _rulesInfo.Text = parsed.Rejected.Count > 0
            ? $"«{parsed.Rejected[0].Line}» · {RuleError(parsed.Rejected[0].Reason)}"
            : parsed.Entries.Count == 0 ? "Правил пока нет." : $"Допустимых правил · {parsed.Entries.Count}";
    }

    private static List<string> ReadLines(string text)
    {
        using var reader = new StringReader(text);
        var lines = new List<string>();
        while (reader.ReadLine() is { } line) lines.Add(line);
        return lines;
    }

    private static string RuleError(string reason) => reason switch
    {
        var text when text.StartsWith("too broad", StringComparison.Ordinal) =>
            "слишком широкая сеть (IPv4 от /8, IPv6 от /16)",
        var text when text.StartsWith("prefix length", StringComparison.Ordinal) => "неверная длина префикса",
        "loopback never goes through the VPN" => "локальный адрес не проходит через VPN",
        "that range is the VPN tunnel itself" => "адрес входит в диапазон самого туннеля",
        "domain is too long" => "доменное имя слишком длинное",
        _ => "неверный IP-адрес или доменное имя",
    };

    private void OnTabChanged(object sender, SelectionChangedEventArgs args)
    {
        if (!ReferenceEquals(args.Source, Tabs)) return;
        if (Tabs.SelectedItem == DiagnosticsTab)
        {
            UpdateJournal();
            _journalTimer.Start();
            _ = UpdateHelper();
        }
        else _journalTimer.Stop();
    }

    private void UpdateJournal()
    {
        var latest = _journal();
        if (latest.Length == 0) latest = "Записей пока нет.";
        if (_log.Text == latest) return;
        var scrollToBottom = _log.VerticalOffset >= _log.ExtentHeight - _log.ViewportHeight - 1;
        var priorOffset = _log.VerticalOffset;
        _log.Text = latest;
        if (scrollToBottom) _log.ScrollToEnd();
        else _log.ScrollToVerticalOffset(priorOffset);
    }

    private async Task UpdateHelper()
    {
        if (_refreshing) return;
        _refreshing = true;
        _helperInfo.Text = "Проверка связи…";
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
            timeout.CancelAfter(TimeSpan.FromSeconds(2));
            _helperAvailable = await _app.IsVpnHelperAvailableAsync(timeout.Token);
            _helperInfo.Text = HelperLabel();
        }
        finally { _refreshing = false; }
    }

    private string HelperLabel() => _helperAvailable switch
    {
        true => "Служба отвечает",
        false when FindComponent("AnemiaHelper.exe") is null => "Компонент не найден",
        false => "Служба не запущена или не отвечает",
        _ => "Связь ещё не проверялась",
    };

    private string BuildReport() => string.Join(Environment.NewLine,
        "Anemia для Windows",
        VersionLabel(),
        $"Windows {Environment.OSVersion.Version} · {RuntimeInformation.OSArchitecture}",
        $"VPN · {VpnLabel()}",
        $"Служба · {HelperLabel()}",
        $"Xray · {ComponentState(_app.InstalledXrayPath)}",
        $"AmneziaWG · {ComponentState(FindComponent("anemia-engine.exe"))}",
        $"Kill switch · {(_app.State.KillSwitchEnabled ? "включён" : "выключен")}",
        $"Маскирование · {MaskingName(_app.State.MaskingProfile)}");

    private string VpnLabel() => _app.TunnelState switch
    {
        TunnelState.Connected when _app.TunnelActive => "Подключён, трафик проходит",
        TunnelState.Connected => "Туннель запущен",
        TunnelState.Connecting => "Подключение",
        TunnelState.Reconnecting => "Переподключение",
        _ => "Отключён",
    };

    private void Copy(string text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            _diagnosticsInfo.Text = "В журнале пока нет записей.";
            return;
        }
        try
        {
            Clipboard.SetText(text);
            _diagnosticsInfo.Text = "Скопировано в буфер обмена.";
        }
        catch (ExternalException)
        {
            _diagnosticsInfo.Text = "Буфер обмена занят. Повторите копирование.";
        }
    }

    private static string VersionLabel() =>
        $"Версия {typeof(SettingsWindow).Assembly.GetName().Version?.ToString(3)} · {RuntimeInformation.ProcessArchitecture}";

    private static string? FindComponent(string name)
    {
        var root = AppContext.BaseDirectory;
        return new[] { Path.Combine(root, "Resources", name), Path.Combine(root, name), Path.Combine(root, "..", name) }
            .FirstOrDefault(File.Exists);
    }

    private static string ComponentState(string? path)
    {
        if (path is null) return "Компонент не найден";
        try
        {
            var version = System.Diagnostics.FileVersionInfo.GetVersionInfo(path).FileVersion;
            return string.IsNullOrWhiteSpace(version) ? "Компонент найден" : $"Версия {version}";
        }
        catch (IOException) { return "Компонент не найден"; }
    }

    private static string? StartupCommand()
    {
        var path = Environment.ProcessPath;
        return string.Equals(Path.GetFileName(path), "Anemia.exe", StringComparison.OrdinalIgnoreCase)
            ? $"\"{path}\""
            : null;
    }

    private void LoadStartup()
    {
        var command = StartupCommand();
        _startup.IsEnabled = command is not null;
        if (command is null)
        {
            StartupNotice("Автозапуск доступен при запуске через Anemia.exe.");
            return;
        }
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            _startupEnabled = string.Equals(key?.GetValue(RunValue) as string, command,
                StringComparison.OrdinalIgnoreCase);
            _startup.IsChecked = _startupEnabled;
            StartupNotice("");
        }
        catch (Exception error) when (error is SecurityException or UnauthorizedAccessException or IOException)
        {
            _startup.IsEnabled = false;
            StartupNotice("Не удалось прочитать настройки автозапуска Windows.");
        }
    }

    private void OnStartup(object sender, RoutedEventArgs args)
    {
        var command = StartupCommand();
        if (command is null) return;
        try
        {
            var enabled = _startup.IsChecked == true;
            if (enabled)
            {
                using var key = Registry.CurrentUser.CreateSubKey(RunKey);
                key.SetValue(RunValue, command, RegistryValueKind.String);
            }
            else
            {
                using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
                if (string.Equals(key?.GetValue(RunValue) as string, command, StringComparison.OrdinalIgnoreCase))
                    key!.DeleteValue(RunValue, throwOnMissingValue: false);
            }
            _startupEnabled = enabled;
            StartupNotice("");
        }
        catch (Exception error) when (error is SecurityException or UnauthorizedAccessException or IOException)
        {
            _startup.IsChecked = _startupEnabled;
            StartupNotice("Windows не сохранила настройку автозапуска.");
        }
    }

    private void StartupNotice(string text)
    {
        _generalInfo.Text = text;
        _generalInfo.Visibility = text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private static string MaskingName(MaskingProfile profile) => profile switch
    {
        MaskingProfile.Off => "Выключено",
        MaskingProfile.Balanced => "Сбалансированная",
        MaskingProfile.Maximum => "Максимальная",
        MaskingProfile.RuYandex => "Россия · Яндекс",
        MaskingProfile.RuVK => "Россия · VK",
        _ => profile.Title(),
    };

    private sealed record MaskingChoice(MaskingProfile Profile, string Label)
    {
        public override string ToString() => Label;
    }

    private static void Group(StackPanel pane, string title, params FrameworkElement[] rows)
    {
        var heading = Caption(title);
        heading.Margin = new Thickness(2, 0, 0, 5);
        pane.Children.Add(heading);
        var card = new Border { Padding = new Thickness(0, 2, 0, 2), Margin = new Thickness(0, 0, 0, 14) };
        card.SetResourceReference(StyleProperty, "CardTile");
        card.BorderThickness = new Thickness(0);
        var content = new StackPanel();
        card.Child = content;
        for (var index = 0; index < rows.Length; index++)
        {
            if (index > 0)
            {
                var divider = new Rectangle { Margin = new Thickness(50, 0, 0, 0) };
                divider.SetResourceReference(StyleProperty, "Hairline");
                content.Children.Add(divider);
            }
            content.Children.Add(rows[index]);
        }
        pane.Children.Add(card);
    }

    private static FrameworkElement Row(string icon, string title, string detail,
        FrameworkElement? accessory = null, TextBlock? caption = null)
    {
        var row = new DockPanel { Margin = new Thickness(12, 8, 12, 8) };
        if (accessory is not null)
        {
            accessory.VerticalAlignment = VerticalAlignment.Center;
            accessory.Margin = new Thickness(10, 0, 0, 0);
            DockPanel.SetDock(accessory, Dock.Right);
            row.Children.Add(accessory);
        }

        var tile = new Border { Width = 24, Height = 24, CornerRadius = new CornerRadius(6) };
        tile.SetResourceReference(StyleProperty, "ProtectionIcon");
        if (accessory is ToggleButton toggle)
            tile.SetBinding(TagProperty, new System.Windows.Data.Binding("IsChecked") { Source = toggle });
        else if (accessory is ComboBox masking)
        {
            void UpdateTile() => tile.Tag = masking.SelectedValue is MaskingProfile profile && profile != MaskingProfile.Off;
            masking.SelectionChanged += (_, _) => UpdateTile();
            UpdateTile();
        }
        var glyph = new System.Windows.Shapes.Path
        {
            Data = Geometry.Parse(Glyph(icon)), Width = 12, Height = 12,
            Stretch = Stretch.Uniform, StrokeThickness = 1.5, StrokeLineJoin = PenLineJoin.Round,
            StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round,
        };
        glyph.SetBinding(Shape.StrokeProperty, new System.Windows.Data.Binding
        {
            Source = tile, Path = new PropertyPath("(0)", TextElement.ForegroundProperty),
        });
        tile.Child = glyph;
        DockPanel.SetDock(tile, Dock.Left);
        row.Children.Add(tile);

        var description = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        var label = new TextBlock { Text = title, FontSize = 13, FontWeight = FontWeights.Medium };
        label.SetResourceReference(TextBlock.ForegroundProperty, "Text");
        description.Children.Add(label);
        caption ??= Caption(detail);
        caption.Margin = new Thickness(0, 2, 0, 0);
        description.Children.Add(caption);
        row.Children.Add(description);
        return row;
    }

    private static string Glyph(string icon) => icon switch
    {
        "startup" => "M1,1 H15 V11 H1 Z M5,15 H11 M8,11 V15",
        "power" => "M8,0 V7 M4,3 A6,6 0 1 0 12,3",
        "refresh" => "M14,4 A6,6 0 1 0 14,12 M14,0 V4 H10",
        "transfer" => "M1,5 H15 M11,1 L15,5 L11,9 M15,12 H1 M5,8 L1,12 L5,16",
        "guard" => "M8,1 L14,3 V8 Q14,12 8,15 Q2,12 2,8 V3 Z M6,7 H10 V11 H6 Z M7,7 V6 A1,1 0 0 1 9,6 V7",
        "block" => "M8,1 A7,7 0 1 1 8,15 A7,7 0 1 1 8,1 Z M3,3 L13,13",
        "masking" => "M0,4 L7,2 L9,8 Q8,12 5,12 Q2,11 1,8 Z M8,7 L15,9 L14,12 Q11,16 8,15 Q6,14 6,12 M3,6 H4 M6,5 H7 M10,9 H11 M13,10 H14",
        "route" => "M8,15 V8 L2,2 M8,8 L14,2 M2,2 H6 M14,2 H10",
        "copy" => "M5,5 H14 V15 H5 Z M2,11 V1 H10",
        "log" => "M2,1 H14 V15 H2 Z M5,5 H11 M5,8 H11 M5,11 H9",
        "engine" => "M3,3 H13 V13 H3 Z M6,6 H10 V10 H6 Z M0,6 H3 M13,6 H16 M0,10 H3 M13,10 H16 M6,0 V3 M10,0 V3 M6,13 V16 M10,13 V16",
        _ => "M8,1 A7,7 0 1 1 8,15 A7,7 0 1 1 8,1 Z M8,7 V12 M8,4 V4.5",
    };

    private static TextBlock Caption(string text = "")
    {
        var caption = new TextBlock { Text = text, FontSize = 11, TextWrapping = TextWrapping.Wrap };
        caption.SetResourceReference(TextBlock.ForegroundProperty, "TextDim");
        return caption;
    }

    private static Button Action(string label, RoutedEventHandler clicked)
    {
        var button = new Button { Content = label, Padding = new Thickness(10, 5, 10, 5) };
        button.SetResourceReference(StyleProperty, "Btn");
        button.Click += clicked;
        return button;
    }

    private static ToggleButton Switch(string label, RoutedEventHandler clicked)
    {
        var toggle = new ToggleButton();
        toggle.SetResourceReference(StyleProperty, "Switch");
        AutomationProperties.SetName(toggle, label);
        toggle.Click += clicked;
        return toggle;
    }

    private static TextBox Editor(string label, bool readOnly, double height)
    {
        var editor = new TextBox
        {
            Height = height, TextWrapping = TextWrapping.Wrap, IsReadOnly = readOnly, AcceptsReturn = true,
            Padding = new Thickness(9), VerticalContentAlignment = VerticalAlignment.Top,
            VerticalScrollBarVisibility = ScrollBarVisibility.Hidden,
        };
        AutomationProperties.SetName(editor, label);
        editor.SetResourceReference(StyleProperty, "Field");
        editor.SetResourceReference(FontFamilyProperty, "MetricFont");
        return editor;
    }
}
