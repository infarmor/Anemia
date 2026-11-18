using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Imaging;
using AnemiaCore;
using Microsoft.Win32;
using QRCoder;

namespace AnemiaApp;

/// <summary>
/// The transfer sheet: write the file another device imports, or read one it
/// sent. Every decision in it — is this ours, is it too new, what would a merge
/// add, does the settings checkbox mean anything — lives in
/// <see cref="TransferModel"/> and is tested there; this class only moves text
/// between the screen and that model.
///
/// </summary>
public partial class TransferWindow : AnemiaToolWindow
{
    private readonly AppState _app;
    private SyncBundle? _incoming;
    private bool _suppressPreview;

    public TransferWindow(AppState app)
    {
        InitializeComponent();
        _app = app;
        var bundle = _app.ExportBundle();
        ExportSummary.Text = $"Серверов: {bundle.Servers.Count} · подписок: {bundle.Subscriptions.Count} · настройки";
    }

    // MARK: - Export

    private void OnSaveFile(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            Title = "Экспорт настроек",
            Filter = $"Файл Anemia (*.{SyncBundle.FileExtension})|*.{SyncBundle.FileExtension}|Все файлы|*.*",
            FileName = $"anemia-{DateTime.Now:yyyyMMdd-HHmm}.{SyncBundle.FileExtension}",
        };
        if (dialog.ShowDialog(this) != true) return;
        Try(() =>
        {
            File.WriteAllText(dialog.FileName, _app.ExportBundle().FileText());
            LinkText.Text = "Сохранено в " + Path.GetFileName(dialog.FileName);
        });
    }

    private void OnCopyLink(object sender, RoutedEventArgs e)
    {
        Try(() =>
        {
            var link = _app.ExportBundle().Link();
            System.Windows.Clipboard.SetText(link);
            LinkText.Text = "Ссылка скопирована. Вставьте её в Anemia на другом устройстве.";
        });
    }

    private void OnShowQr(object sender, RoutedEventArgs e)
    {
        if (TransferQr.Visibility == Visibility.Visible)
        {
            TransferQr.Visibility = Visibility.Collapsed;
            return;
        }

        Try(() =>
        {
            try
            {
                using var generator = new QRCodeGenerator();
                using var data = generator.CreateQrCode(_app.ExportBundle().Link(), QRCodeGenerator.ECCLevel.M);
                using var qr = new PngByteQRCode(data);
                using var stream = new MemoryStream(qr.GetGraphic(4));
                var image = new BitmapImage();
                image.BeginInit();
                image.CacheOption = BitmapCacheOption.OnLoad;
                image.StreamSource = stream;
                image.EndInit();
                TransferQr.Source = image;
                TransferQr.Visibility = Visibility.Visible;
                LinkText.Text = "Отсканируйте код на другом устройстве.";
            }
            catch (QRCoder.Exceptions.DataTooLongException)
            {
                LinkText.Text = "Данные не помещаются в QR-код. Сохраните файл или скопируйте ссылку.";
            }
        });
    }

    // MARK: - Import

    private void OnOpenFile(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            Title = "Открыть файл переноса",
            Filter = $"Файл Anemia (*.{SyncBundle.FileExtension})|*.{SyncBundle.FileExtension}|Все файлы|*.*",
        };
        if (dialog.ShowDialog(this) != true) return;
        try
        {
            ReadText(File.ReadAllText(dialog.FileName));
        }
        catch (IOException io)
        {
            IncomingSummary.Text = "Не удалось прочитать файл. " + io.Message;
        }
    }

    private void OnPaste(object sender, RoutedEventArgs e)
    {
        if (System.Windows.Clipboard.ContainsText()) IncomingText.Text = System.Windows.Clipboard.GetText();
    }

    private void OnTextChanged(object sender, TextChangedEventArgs e) => ReadText(IncomingText.Text);

    /// <summary>One entry point for file and clipboard, because the two forms
    /// differ only in how they arrive: `anemia://sync/…` or pretty JSON.</summary>
    private string _loadedText = "";

    private void ReadText(string text)
    {
        // Pasting a 40 KB bundle fires this per keystroke; the same text
        // produces the same answer, so the decode runs once per change of text
        // rather than once per character.
        if (_suppressPreview || text == _loadedText) return;
        _loadedText = text;
        _incoming = null;
        ImportButton.IsEnabled = false;
        ApplySettingsBox.Visibility = Visibility.Collapsed;
        switch (TransferModel.Load(text))
        {
            case { Kind: TransferModel.LoadKind.Unreadable } when text.Trim().Length == 0:
                PreviewLine.Text = "";
                return;
            case { Kind: TransferModel.LoadKind.Unreadable }:
                PreviewLine.Text = SyncBundle.LooksLikeBundle(text)
                    ? "Эта версия Anemia не может прочитать файл."
                    : "Данные не распознаны как файл переноса Anemia.";
                return;
            case { Kind: TransferModel.LoadKind.NewerVersion } loaded:
                PreviewLine.Text =
                    $"Формат {loaded.Version} требует более новой версии Anemia.";
                return;
            case { IsBundle: true, Bundle: { } bundle }:
                _incoming = bundle;
                ApplySettingsBox.Visibility = bundle.Settings is null ? Visibility.Collapsed : Visibility.Visible;
                ImportButton.IsEnabled = true;
                ShowPreview();
                return;
        }
    }

    private void OnPreviewAgain(object sender, RoutedEventArgs e) => ShowPreview();

    private void ShowPreview()
    {
        if (_incoming is not { } bundle) return;
        var preview = TransferModel.Preview(bundle, _app.State, ApplySettingsBox.IsChecked == true);
        PreviewLine.Text =
            $"Устройство {bundle.Device}. Новых серверов: {preview.AddedServers}" +
            $" · новых подписок: {preview.NewSubscriptions.Count}" +
            (bundle.Settings is null ? " · без настроек" : "");
        // Adding nothing is not a reason to refuse the file — it is a reason to
        // gray the button out, which is what the macOS sheet does.
        ImportButton.IsEnabled = !preview.AddsNothing || preview.SettingsApplied;
    }

    private async void OnImport(object sender, RoutedEventArgs e)
    {
        if (_incoming is not { } bundle) return;
        ImportButton.IsEnabled = false;
        try
        {
            var summary = _app.ImportBundle(bundle, ApplySettingsBox.IsChecked == true);
            var status = $"Добавлено серверов: {summary.AddedServers} · подписок: {summary.NewSubscriptions.Count}" +
                (summary.SettingsApplied ? " · настройки применены" : "");
            PreviewLine.Text = status;
            _suppressPreview = true;
            IncomingText.Clear();
            _suppressPreview = false;
            _incoming = null;
            _loadedText = "";
            ApplySettingsBox.Visibility = Visibility.Collapsed;
            TransferQr.Visibility = Visibility.Collapsed;
            IncomingText.IsEnabled = false;
            foreach (var entry in summary.NewSubscriptions)
            {
                var subscription = _app.State.Subscriptions.FirstOrDefault(sub => sub.Url == entry.Url);
                if (subscription is not null)
                    await _app.RefreshSubscriptionAsync(subscription, CancellationToken.None);
            }
        }
        catch (Exception error) { IncomingSummary.Text = error.Message; }
        finally
        {
            IncomingText.IsEnabled = true;
            ShowPreview();
        }
    }

    /// <summary>A file on a disconnected network share or a denied clipboard is
    /// a message, not a stack trace: this window is opened to move data between
    /// machines, and half of it will be tried on machines that are not plugged
    /// in well.</summary>
    private void Try(Action action)
    {
        try
        {
            action();
        }
        catch (Exception e)
        {
            IncomingSummary.Text = e.Message;
        }
    }
}
