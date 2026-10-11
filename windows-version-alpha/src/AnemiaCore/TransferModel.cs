namespace AnemiaCore;

/// <summary>
/// The decisions the transfer sheet makes, kept out of the WPF project so they
/// can be run on any machine: what a dropped file or pasted text is, whether its
/// settings may be taken, and what a merge would do before the user commits to
/// it. The sheet itself is then only layout and buttons.
///
/// Port of the flow in `Sources/LoaderApp/Views/TransferViews.swift` and
/// `AppState.importSync`.
/// </summary>
public static class TransferModel
{
    public enum LoadKind
    {
        /// <summary>A bundle this build can show and merge.</summary>
        Bundle,
        /// <summary>Written by a newer Anemia — say so, rather than «bad file».</summary>
        NewerVersion,
        /// <summary>Not ours at all, or unreadable.</summary>
        Unreadable,
    }

    public readonly record struct Loaded(LoadKind Kind, SyncBundle? Bundle, int Version = 0)
    {
        public bool IsBundle => Kind == LoadKind.Bundle && Bundle is not null;
    }

    /// <summary>Reads a bundle from the text of a `.anemia` file or from a
    /// `anemia://sync/` link. Swift distinguishes «too new» from «not ours»
    /// because the two need different words in front of the user, so this does
    /// too — and a file that cannot be read at all is the third answer.</summary>
    public static Loaded Load(string text)
    {
        try
        {
            return new Loaded(LoadKind.Bundle, SyncBundle.Decode(text));
        }
        catch (SyncBundle.DecodeException e)
        {
            return e.Reason == "newerVersion"
                ? new Loaded(LoadKind.NewerVersion, null, e.NewerVersion)
                : new Loaded(LoadKind.Unreadable, null);
        }
        catch (Exception)
        {
            // A file on a remote disk, a truncated QR paste, a bundle whose
            // servers do not decode: all three are «unreadable», never a crash —
            // this runs on the thread that draws the sheet.
            return new Loaded(LoadKind.Unreadable, null);
        }
    }

    /// <summary>Whether the bundle's settings should actually be taken. The
    /// checkbox means nothing when the sender carried no settings, and showing
    /// it as applied would promise a change that did not happen.</summary>
    public static bool WillApplySettings(SyncBundle bundle, bool checkbox) =>
        checkbox && bundle.Settings is not null;

    /// <summary>What <see cref="Apply"/> would do, without doing it.</summary>
    public static SyncBundle.MergeSummary Preview(SyncBundle bundle, PersistedState state, bool checkbox) =>
        bundle.Preview(state, WillApplySettings(bundle, checkbox));

    /// <summary>Merges into <paramref name="state"/> — servers by identity,
    /// subscriptions by address — and returns what it added. The caller persists
    /// and refreshes its lists afterwards, as the other ports do.</summary>
    public static SyncBundle.MergeSummary Apply(SyncBundle bundle, PersistedState state, bool checkbox) =>
        bundle.Merge(state, WillApplySettings(bundle, checkbox));

    /// <summary>"3 (2 already here)" — the count the sheet shows next to
    /// «New servers». Known-only rows still read «0», never empty.</summary>
    public static string CountText(int added, int known) =>
        known > 0 ? $"{added} ({known} already here)" : added.ToString(System.Globalization.CultureInfo.InvariantCulture);

    /// <summary>The log line macOS leaves behind, so a Windows import can be
    /// recognised in the same shape by whoever reads the file later.</summary>
    public static string ImportLog(SyncBundle bundle, SyncBundle.MergeSummary summary) =>
        "imported from " + bundle.Device + ": +" + summary.AddedServers + " servers, +" +
        summary.NewSubscriptions.Count + " subscriptions" +
        (summary.SettingsApplied ? ", settings" : "");
}
