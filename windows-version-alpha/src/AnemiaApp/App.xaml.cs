using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using AnemiaCore;

namespace AnemiaApp;

public partial class App : System.Windows.Application
{
    private AppState? _app;
    private System.Windows.Forms.NotifyIcon? _tray;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        ApplyTheme(IsSystemDark());

        _app = new AppState();
        _app.LoadOrInit();

        // Single-instance guard: two engines would fight over the SOCKS port
        // (the second one's free-port pick would silently shift ports the
        // system proxy already points at).
        var mutex = new System.Threading.Mutex(initiallyOwned: true, "Local\\AnemiaApp", out var isFirst);
        if (!isFirst)
        {
            System.Windows.MessageBox.Show("Anemia is already running (check the tray).", "Anemia",
                MessageBoxButton.OK, MessageBoxImage.Information);
            Shutdown();
            return;
        }
        GC.KeepAlive(mutex);

        // Follow the system light/dark setting live, like the macOS theme's
        // dynamic NSColors do.
        Microsoft.Win32.SystemEvents.UserPreferenceChanged += (_, args) =>
        {
            if (args.Category == Microsoft.Win32.UserPreferenceCategory.General)
                Dispatcher.Invoke(() => ApplyTheme(IsSystemDark()));
        };

        BuildTray();
        // The tray's Connect/Disconnect label must track the switch in the
        // window too, not just tray-initiated toggles.
        _app.StateChanged += () =>
        {
            if (_toggleItem is { } item)
                Dispatcher.Invoke(() => item.Text =
                    _app.TunnelState == TunnelState.Disconnected ? "Connect" : "Disconnect");
        };
        var window = new MainWindow(_app);
        window.Show();
        Current.MainWindow = window;
        Current.Exit += OnAppExit;

        await _app.OnLaunchAsync();
    }

    /// <summary>Windows apps are expected to follow the system appearance;
    /// HKCU SOFTWARE\...\Themes\Personalize AppsUseLightTheme is the switch
    /// the Settings app flips. A missing key (server SKUs) reads as light.</summary>
    private static bool IsSystemDark()
    {
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("AppsUseLightTheme") is int v && v == 0;
        }
        catch { return false; }
    }

    /// <summary>Swap the palette brushes in place: the warm-charcoal dark
    /// palette mirrors Theme.swift's dark values (never pure black), the
    /// light palette is Claude's ivory. The card shadow deepens on dark
    /// where fills are fainter.</summary>
    private void ApplyTheme(bool dark)
    {
        var r = Resources;
        r["BgGradient"] = new LinearGradientBrush(
            Color(dark ? 0x262624u : 0xFAF9F5u), Color(dark ? 0x1F1E1Du : 0xF0EEE6u), 90);
        r["Card"] = Brush(dark, 0x0EFFFFFF, 0xE0FFFFFF);
        r["CardHi"] = Brush(dark, 0x16FFFFFF, 0xF7FFFFFF);
        r["Stroke"] = Brush(dark, 0x12FFFFFF, 0x1A141413);
        r["EdgeHi"] = Brush(dark, 0x12FFFFFF, 0xD9FFFFFF);
        r["EdgeLo"] = Brush(dark, 0x03FFFFFF, 0x1AFFFFFF);
        r["Text"] = Brush(dark, 0xEBFFFFFF, 0xFF141413);
        r["TextDim"] = Brush(dark, 0x80FFFFFF, 0xFF6E6D68);
        r["Accent"] = Solid(dark ? 0xDF8A67u : 0xD97757u);
        r["AccentDim"] = Solid(dark ? 0xD97757u : 0xC96442u);
        r["Good"] = Solid(dark ? 0xDF8A67u : 0xD97757u);
        r["Idle"] = Brush(dark, 0x1AFFFFFF, 0x0F141413);
        r["Danger"] = Solid(dark ? 0xF0705Eu : 0xB8442Fu);
        r["Warn"] = Solid(dark ? 0xE0A82Eu : 0xB7791Fu);
        if (r["CardShadow"] is System.Windows.Media.Effects.DropShadowEffect sh)
            sh.Opacity = dark ? 0.28 : 0.10;
    }

    private static System.Windows.Media.Color Color(uint hex) =>
        System.Windows.Media.Color.FromRgb((byte)(hex >> 16), (byte)(hex >> 8), (byte)hex);

    private static SolidColorBrush Solid(uint hex)
    {
        var b = new SolidColorBrush(Color(hex)); b.Freeze(); return b;
    }

    private static SolidColorBrush Brush(bool dark, uint darkHex, uint lightHex)
    {
        var b = new SolidColorBrush(Color(dark ? darkHex : lightHex)); b.Freeze(); return b;
    }

    private void BuildTray()
    {
        _tray = new System.Windows.Forms.NotifyIcon
        {
            Text = "Anemia",
            Icon = MakeIcon(),
            Visible = true,
        };
        var menu = new System.Windows.Forms.ContextMenuStrip();
        menu.Items.Add("Open", null, (_, _) => ShowWindow());
        menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
        _toggleItem = new System.Windows.Forms.ToolStripMenuItem("Connect", null,
            (_, _) => _ = ToggleFromTray());
        menu.Items.Add(_toggleItem);
        // Fast-switch, like the macOS menu: server list rebuilt every time
        // the menu opens, so it never goes stale. Picking a server connects
        // through it directly.
        _serversItem = new System.Windows.Forms.ToolStripMenuItem("Servers");
        _serversItem.DropDownOpening += (_, _) => RebuildServerMenu();
        menu.Items.Add(_serversItem);
        menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
        menu.Items.Add("Quit", null, (_, _) => Quit());
        _tray.ContextMenuStrip = menu;
        _tray.DoubleClick += (_, _) => ShowWindow();
    }

    private System.Windows.Forms.ToolStripMenuItem? _toggleItem;
    private System.Windows.Forms.ToolStripMenuItem? _serversItem;

    private void RebuildServerMenu()
    {
        if (_app is null || _serversItem is null) return;
        var drop = _serversItem.DropDown;
        drop.Items.Clear();
        var selectedId = _app.SelectedServer?.Id;
        foreach (var server in _app.AllServers.Take(20)) // tray menus get unusable past that
        {
            var name = server.Name.Length > 0 ? server.Name : $"{server.Address}:{server.Port}";
            if (name.Length > 48) name = name[..48] + "…";
            var item = new System.Windows.Forms.ToolStripMenuItem(
                (server.Id == selectedId ? "● " : "　 ") + name);
            item.Click += (_, _) =>
            {
                _app.SelectServer(server.Id);
                _ = _app.ConnectAsync();
            };
            drop.Items.Add(item);
        }
        if (_app.AllServers.Count == 0)
        {
            var empty = new System.Windows.Forms.ToolStripMenuItem("(no servers — open Anemia to add)");
            empty.Enabled = false;
            drop.Items.Add(empty);
        }
    }

    private async Task ToggleFromTray()
    {
        if (_app is null) return;
        await _app.ToggleAsync();
        if (_toggleItem is { } item)
            item.Text = _app.TunnelState == TunnelState.Disconnected ? "Connect" : "Disconnect";
    }

    private void ShowWindow()
    {
        if (Current.MainWindow is { } w)
        {
            w.Show();
            w.WindowState = WindowState.Normal;
            w.Activate();
        }
    }

    /// <summary>Draws a 32×32 fallback icon in-process: no bundled .ico asset
    /// is required for a dev build (the csproj's ApplicationIcon is optional).
    /// Terracotta mark on warm ink — same identity as the macOS menu icon.</summary>
    private static System.Drawing.Icon MakeIcon()
    {
        using var bmp = new System.Drawing.Bitmap(32, 32);
        using (var g = System.Drawing.Graphics.FromImage(bmp))
        {
            g.Clear(System.Drawing.Color.Transparent);
            using var fill = new System.Drawing.SolidBrush(System.Drawing.Color.FromArgb(0xD9, 0x77, 0x57));
            using var dark = new System.Drawing.SolidBrush(System.Drawing.Color.FromArgb(0x1F, 0x1E, 0x1D));
            g.FillEllipse(dark, 1, 1, 30, 30);
            g.FillEllipse(fill, 8, 8, 16, 16);
        }
        return System.Drawing.Icon.FromHandle(bmp.GetHicon());
    }

    internal static bool ForceClose;

    private void Quit()
    {
        ForceClose = true;
        if (Current.MainWindow is { } w) w.Close();
        Shutdown();
    }

    private void OnAppExit(object sender, ExitEventArgs e)
    {
        if (_tray is { } tray)
        {
            tray.Visible = false;
            tray.Dispose();
            _tray = null;
        }
        // Persisted state saves on every mutation; teardown only reverts
        // machine-wide state (proxy, engine, tunnel).
        _app?.Dispose();
    }
}