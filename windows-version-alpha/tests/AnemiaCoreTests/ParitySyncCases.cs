using System.Text;
using System.Text.Json.Nodes;
using AnemiaCore;
using Xunit;

namespace AnemiaCoreTests;

/// <summary>
/// The whole `sync/cases.golden.txt` — 35 cases run through the same four
/// operations Swift runs: read a bundle the other side wrote, produce the file
/// form, produce the QR form, and merge a bundle into a state.
///
/// The file form is compared by its <b>base64 bytes</b>: a bundle carries no
/// floating point, so there is no "close enough" — either Windows writes the
/// same file a Mac reads as its own, or it does not. The link row is compared as
/// text, which only holds if the compact JSON *and* the DEFLATE agree with
/// Apple's byte for byte; the read rows prove the refusals (a stamp in the wrong
/// shape, a bundle from a newer app) refuse the same way for the same reason.
/// </summary>
public class ParitySyncCases
{
    private const string Folder = "sync";

    [Fact]
    public void EveryBundleCaseMatchesSwift()
    {
        var directory = Path.Combine(Parity.Fixtures, Folder, "cases");
        var files = Directory.GetFiles(directory, "*.json").OrderBy(name => name, StringComparer.Ordinal).ToList();
        Assert.NotEmpty(files);

        var golden = Parity.Split(Parity.Read(Folder, "cases.golden.txt"));
        var goldenRows = Blocks(golden);
        // The `file` row is Foundation's *collation*-sorted echo of the document
        // (`adaptiveMasking` before `adBlock`), while `file-bytes` — the row that
        // actually matters — is JSONEncoder's ordinal one. Both sides therefore go
        // through this port's canonical form before being compared, and the order
        // rule cancels out instead of becoming a fake divergence.
        var goldenCanonical = string.Join(Parity.LineFeed.ToString(), golden
            .Select(line => line.StartsWith("file" + Parity.Tab, StringComparison.Ordinal)
                ? "file" + Parity.Tab + Parity.Canonical(line[(4 + 1)..])
                : line)) + Parity.LineFeed;
        var produced = new StringBuilder();
        var counts = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var file in files)
        {
            var name = Path.GetFileNameWithoutExtension(file);
            var root = JsonNode.Parse(File.ReadAllText(file, Encoding.UTF8));
            var kind = root?["kind"]?.GetValue<string>() ?? "";
            counts[kind] = counts.GetValueOrDefault(kind) + 1;
            produced.Append("=== ").Append(name).Append(Parity.LineFeed);
            RunCase(produced, name, kind, root!, goldenRows);
        }

        Parity.Compare(produced.ToString(), goldenCanonical, "перенос бандла", floor: 60);
        // The four kinds are the four operations. A case whose kind nobody
        // dispatches would leave its rows un-compared and the run still green.
        Assert.Equal(new Dictionary<string, int> { ["read"] = 22, ["file"] = 2, ["link"] = 3, ["merge"] = 8 }, counts);
        Assert.Equal(35, files.Count);
    }

    /// <summary>The golden cut into «case → row → value», so a check reads the row
    /// that belongs to the case it is running instead of the first match.</summary>
    private static Dictionary<string, Dictionary<string, string>> Blocks(string[] lines)
    {
        var blocks = new Dictionary<string, Dictionary<string, string>>(StringComparer.Ordinal);
        string? current = null;
        foreach (var line in lines)
        {
            if (line.StartsWith("=== ", StringComparison.Ordinal))
            {
                current = line[4..];
                blocks[current] = new Dictionary<string, string>(StringComparer.Ordinal);
            }
            else if (current is not null && line.Contains(Parity.Tab))
            {
                var at = line.IndexOf(Parity.Tab);
                blocks[current][line[..at]] = line[(at + 1)..];
            }
        }
        return blocks;
    }

    private static void RunCase(StringBuilder into, string name, string kind, JsonNode root,
        Dictionary<string, Dictionary<string, string>> goldenRows)
    {
        switch (kind)
        {
            case "read":
            {
                var body = root["body"]!.GetValue<string>();
                // Decided before anything is written: `Append(a).Append(b(x))`
                // evaluates b() only after a has already gone into the buffer, so
                // a throw in the middle of the row would print `bundle` and then
                // `error` for the same case.
                string row;
                try
                {
                    row = "bundle" + Parity.Tab + Dump(SyncBundle.Decode(body));
                }
                catch (SyncBundle.DecodeException e)
                {
                    row = "error" + Parity.Tab + e;
                }
                catch (Exception)
                {
                    row = "error" + Parity.Tab + "deserialize";
                }
                into.Append(row).Append(Parity.LineFeed);
                break;
            }
            case "file":
            {
                var bundle = CaseBundle(root);
                var text = bundle.FileText();
                // The golden's `file` row is JSONSerialization's collation-sorted
                // echo of the same document; both sides go through one canonical
                // form, so the order rule cancels and only the content is compared.
                into.Append("file").Append(Parity.Tab).Append(Parity.Canonical(text)).Append(Parity.LineFeed);
                into.Append("file-bytes").Append(Parity.Tab)
                    .Append(Convert.ToBase64String(Encoding.UTF8.GetBytes(text))).Append(Parity.LineFeed);
                into.Append("file-read").Append(Parity.Tab)
                    .Append(Dump(SyncBundle.Decode(text))).Append(Parity.LineFeed);
                break;
            }
            case "link":
            {
                var bundle = CaseBundle(root);
                into.Append("link").Append(Parity.Tab).Append(bundle.Link()).Append(Parity.LineFeed);
                // The link *Swift* wrote, read by this port: a decoder that only
                // understands its own deflater would pass the row above and lose
                // every QR code an iPhone generated.
                into.Append("link-read").Append(Parity.Tab)
                    .Append(Dump(SyncBundle.FromLink(goldenRows[name]["link"]))).Append(Parity.LineFeed);
                break;
            }
            case "merge":
            {
                var bundle = CaseBundle(root);
                var state = PersistedState.FromJson(root["state"]) ?? new PersistedState();
                var apply = root["apply"]?.GetValue<bool>() ?? true;
                var summary = bundle.Merge(state, apply);
                into.Append("summary").Append(Parity.Tab)
                    .Append($"added={summary.AddedServers} known={summary.KnownServers}")
                    .Append($" new={summary.NewSubscriptions.Count} knownSubs={summary.KnownSubscriptions}")
                    .Append($" settings={(summary.SettingsApplied ? 1 : 0)} nothing={(summary.AddsNothing ? 1 : 0)}")
                    .Append(Parity.LineFeed);
                var ids = state.Servers.Select(s => s.Id).ToList();
                into.Append("after").Append(Parity.Tab)
                    .Append($"count={state.Servers.Count}")
                    .Append($" unique={(ids.Distinct().Count() == ids.Count ? 1 : 0)}")
                    .Append(" names=" + string.Join(";", state.Servers.Select(s => s.Name)))
                    .Append(" selected=" + (state.SelectedServerId is { } selected
                        ? (state.Servers.FirstOrDefault()?.Id == selected ? "first" : "other")
                        : "-"))
                    .Append(" subs=" + string.Join(";", state.Subscriptions.Select(s => $"{s.Name}@{s.Url}")))
                    .Append($" masking={PersistedState.RawValue(state.MaskingProfile)}")
                    .Append($" kill={(state.KillSwitchEnabled ? 1 : 0)}")
                    .Append($" subref={(state.SubscriptionAutoRefresh ? 1 : 0)}")
                    .Append(" learned=" + string.Join(";", state.LearnedMasking
                        .OrderBy(pair => pair.Key, StringComparer.Ordinal)
                        .Select(pair => $"{pair.Key}={pair.Value}")))
                    .Append(" split=" + (state.SplitTunnel.Enabled ? "on" : "off") + ":" +
                            string.Join(",", state.SplitTunnel.Entries))
                    .Append(Parity.LineFeed);
                break;
            }
            default:
                into.Append("error").Append(Parity.Tab).Append($"unknown kind {kind}").Append(Parity.LineFeed);
                break;
        }
    }

    private static SyncBundle CaseBundle(JsonNode root)
    {
        var bundle = SyncBundle.FromJson(root["bundle"]);
        Assert.NotNull(bundle);
        Assert.True(bundle!.Version <= SyncBundle.FormatVersion, "a case bundle newer than this build can merge");
        return bundle;
    }

    /// <summary>`LoaderTool sync`'s `bundleDump`, field for field. The stamp is
    /// printed truncated toward zero, as `Int64(seconds)` does.</summary>
    private static string Dump(SyncBundle bundle)
    {
        var seconds = (long)Math.Truncate(bundle.ExportedAt);
        return $"version={bundle.Version} device={bundle.Device} at={seconds}" +
               " servers=" + string.Join(";", bundle.Servers.Select(s => s.IdentityKey)) +
               " subs=" + string.Join(";", bundle.Subscriptions.Select(s => $"{s.Name}@{s.Url}")) +
               " settings=" + (bundle.Settings is { } settings ? SettingsDump(settings) : "nil");
    }

    private static string SettingsDump(BundleSettings settings)
    {
        string Flag(bool? value) => value is null ? "-" : value.Value ? "1" : "0";
        return "masking=" + (settings.MaskingProfile is { } profile ? PersistedState.RawValue(profile) : "-") +
            " kill=" + Flag(settings.KillSwitchEnabled) +
            " split=" + (settings.SplitTunnel is { } rules
                ? (rules.Enabled ? "on" : "off") + ":" + string.Join(",", rules.Entries) : "-") +
            " learned=" + (settings.LearnedMasking is { } learned
                ? string.Join(";", learned.OrderBy(pair => pair.Key, StringComparer.Ordinal)
                    .Select(pair => $"{pair.Key}={pair.Value}")) : "-") +
            " subref=" + Flag(settings.SubscriptionAutoRefresh) +
            " adblock=" + Flag(settings.AdBlock) +
            " reconnect=" + Flag(settings.AutoReconnect) +
            " autoswitch=" + Flag(settings.AutoSwitch) +
            " adaptive=" + Flag(settings.AdaptiveMasking);
    }
}
