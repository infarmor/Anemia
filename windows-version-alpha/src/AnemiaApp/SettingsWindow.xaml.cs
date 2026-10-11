using System.Windows;
using AnemiaCore;

namespace AnemiaApp;

public partial class SettingsWindow : Window
{
    private readonly AppState _app;

    public SettingsWindow(AppState app)
    {
        InitializeComponent();
        _app = app;
        SystemProxyBox.IsChecked = _app.State.SystemProxyEnabled;
        AutoConnectBox.IsChecked = _app.State.AutoConnectOnLaunch;
        SubRefreshBox.IsChecked = _app.State.SubscriptionAutoRefresh;
    }

    private void OnSystemProxyToggle(object sender, RoutedEventArgs e) =>
        _app.SetSystemProxyEnabled(SystemProxyBox.IsChecked == true);

    private void OnAutoConnectToggle(object sender, RoutedEventArgs e) =>
        _app.SetAutoConnect(AutoConnectBox.IsChecked == true);

    private void OnSubRefreshToggle(object sender, RoutedEventArgs e)
    {
        _app.State.SubscriptionAutoRefresh = SubRefreshBox.IsChecked == true;
        _app.Save();
    }
}