using System.IO;
using System.Windows;
using System.Windows.Controls;
using AnemiaCore;
using Microsoft.Win32;

namespace AnemiaApp;

/// <summary>
/// The transfer sheet: write the file another device imports, or read one it
/// sent. Every decision in it — is this ours, is it too new, what would a merge
/// add, does the settings checkbox mean anything — lives in
/// <see cref="TransferModel"/> and is tested there; this class only moves text
/// between the screen and that model.
///
/// What is deliberately absent: a drawn QR code. The link is offered as text
/// (copyable, and short enough for a phone camera only after an encoder exists
/// here to render it), because a grey placeholder box would look like a feature
/// the port does not have.
/// </summary>
public partial class TransferWindow : Window
{
    private readonly AppState _app;
    private SyncBundle? _incoming;
    private bool _suppressPreview;

    public TransferWindow(AppState app)
    {
        InitializeComponent();
        _app = app;
        var bundle = _app.ExportBundle();
        ExportSummary.Text = $"{bundle.Servers.Count} servers · " +
            $"{bundle.Subscriptions.Count} subscriptions · settings";
    }

    // MARK: - Export

    private void OnSaveFile(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            Title = "Export to a file",
            Filter = $"Anemia bundle (*.{SyncBundle.FileExtension})|*.{SyncBundle.FileExtension}|Any file|*.*",
            FileName = $"anemia-{DateTime.Now:yyyyMMdd-HHmm}.{SyncBundle.FileExtension}",
        };
        if (dialog.ShowDialog(this) != true) return;
        Try(() =>
        {
            File.WriteAllText(dialog.FileName, _app.ExportBundle().FileText());
            LinkText.Text = "Written: " + Path.GetFileName(dialog.FileName);
        });
    }

    private void OnCopyLink(object sender, RoutedEventArgs e)
    {
        Try(() =>
        {
            var link = _app.ExportBundle().Link();
            System.Windows.Clipboard.SetText(link);
            LinkText.Text = $"Link copied ({link.Length} characters). On the iPhone: " +
                            "Servers → + → paste.";
        });
    }

    // MARK: - Import

    private void OnOpenFile(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            Title = "Open an exported bundle",
            Filter = $"Anemia bundle (*.{SyncBundle.FileExtension})|*.{SyncBundle.FileExtension}|Any file|*.*",
        };
        if (dialog.ShowDialog(this) != true) return;
        try
        {
            ReadText(File.ReadAllText(dialog.FileName));
        }
        catch (IOException io)
        {
            IncomingSummary.Text = "Could not read that file: " + io.Message;
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
                    ? "Looks like an Anemia bundle, but this build cannot read it."
                    : "This is not an Anemia bundle.";
                return;
            case { Kind: TransferModel.LoadKind.NewerVersion } loaded:
                PreviewLine.Text =
                    $"Written by a newer Anemia (format version {loaded.Version}) — update this app to open it.";
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
            $"From {bundle.Device}. New servers {TransferModel.CountText(preview.AddedServers, preview.KnownServers)}" +
            $" · new subscriptions {TransferModel.CountText(preview.NewSubscriptions.Count, preview.KnownSubscriptions)}" +
            (bundle.Settings is null ? " · no settings in this file" : "");
        // Adding nothing is not a reason to refuse the file — it is a reason to
        // gray the button out, which is what the macOS sheet does.
        ImportButton.IsEnabled = !preview.AddsNothing || preview.SettingsApplied;
    }

    private void OnImport(object sender, RoutedEventArgs e)
    {
        if (_incoming is not { } bundle) return;
        Try(() =>
        {
            var summary = _app.ImportBundle(bundle, ApplySettingsBox.IsChecked == true);
            PreviewLine.Text = $"Imported: +{summary.AddedServers} servers, " +
                $"+{summary.NewSubscriptions.Count} subscriptions" +
                (summary.SettingsApplied ? ", settings" : "");
            ImportButton.IsEnabled = false;
            _suppressPreview = true;
            IncomingText.Clear();
            _suppressPreview = false;
        });
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
