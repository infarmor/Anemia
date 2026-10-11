using AnemiaCore;
using Xunit;

namespace AnemiaCoreTests;

/// <summary>
/// The transfer sheet's decisions, tested where they are made — in the core, not
/// in WPF, because the WPF project compiles on this Mac but cannot run, and a
/// sheet nobody can open must still be provably right about the one thing that
/// matters: what it does to the user's server list.
/// </summary>
public class TransferModelTests
{
    private static SyncBundle Bundle(int version = 1, bool withSettings = true, int servers = 2) => new()
    {
        Version = version,
        ExportedAt = 1_770_000_000,
        Device = "iPhone Маши",
        Servers = Enumerable.Range(0, servers).Select(i => new ProxyServer
        {
            Id = Guid.Parse($"1B564D2F-5117-4C8C-9B0D-9E2F8A3F1C2{i}"),
            Name = "s" + i,
            Proto = ProxyProtocol.Trojan,
            Address = "h" + i + ".example.com",
            Port = 443,
            Credential = "p",
            Network = NetworkType.Ws,
            Security = StreamSecurity.Tls,
        }).ToList(),
        Subscriptions = new List<SyncBundle.SubscriptionEntry>
        {
            new("Панель", "https://panel.example.com/sub"),
        },
        Settings = withSettings
            ? new BundleSettings { KillSwitchEnabled = true, SubscriptionAutoRefresh = true }
            : null,
    };

    [Fact]
    public void AFileTheOtherPortsWriteIsReadAsItself()
    {
        var text = Bundle().FileText();
        var loaded = TransferModel.Load(text);
        Assert.Equal(TransferModel.LoadKind.Bundle, loaded.Kind);
        Assert.Equal("iPhone Маши", loaded.Bundle!.Device);
        Assert.Equal(2, loaded.Bundle.Servers.Count);
    }

    [Fact]
    public void ALinkIsReadToo()
    {
        var loaded = TransferModel.Load(Bundle().Link());
        Assert.Equal(TransferModel.LoadKind.Bundle, loaded.Kind);
        Assert.Equal(2, loaded.Bundle!.Servers.Count);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   \n  ")]
    [InlineData("не бандл")]
    [InlineData("{\"version\": 1}")]
    [InlineData("[]")]
    public void JunkIsAnAnswerAndNotAnException(string text)
        => Assert.Equal(TransferModel.LoadKind.Unreadable, TransferModel.Load(text).Kind);

    /// <summary>«Too new» and «not ours» are different sentences to a user: one
    /// says update the app, the other says this file is not from Anemia. Swift's
    /// `DecodeError` carries the version, so the sheet can name it.</summary>
    [Fact]
    public void ANewerBundleSaysSoAndKeepsItsVersion()
    {
        var loaded = TransferModel.Load(
            """{"version":2,"exportedAt":"2026-02-02T02:40:00Z","device":"Mac","servers":[],"subscriptions":[]}""");
        Assert.Equal(TransferModel.LoadKind.NewerVersion, loaded.Kind);
        Assert.Equal(2, loaded.Version);
        Assert.Null(loaded.Bundle);
    }

    /// <summary>The checkbox is meaningless without settings to take, and
    /// reporting them as applied when the sender carried none would show a
    /// change in the log that never happened.</summary>
    [Theory]
    [InlineData(true, true, true)]
    [InlineData(true, false, false)]
    [InlineData(false, true, false)]
    [InlineData(false, false, false)]
    public void SettingsAreTakenOnlyWhenBothSidesSaySo(bool checkbox, bool bundleHasSettings, bool expected)
        => Assert.Equal(expected, TransferModel.WillApplySettings(Bundle(withSettings: bundleHasSettings), checkbox));

    [Fact]
    public void PreviewPromisesExactlyWhatApplyDelivers()
    {
        var bundle = Bundle();
        var state = new PersistedState
        {
            Servers = new List<ProxyServer> { bundle.Servers[0] },
        };
        var preview = TransferModel.Preview(bundle, state, checkbox: true);

        var after = new PersistedState { Servers = new List<ProxyServer> { bundle.Servers[0] } };
        var applied = TransferModel.Apply(bundle, after, checkbox: true);

        Assert.Equal(preview.AddedServers, applied.AddedServers);
        Assert.Equal(preview.KnownServers, applied.KnownServers);
        Assert.Equal(1, preview.AddedServers);          // the second server is new
        Assert.Equal(1, preview.KnownServers);          // the first is the same endpoint and key
        Assert.Equal(2, after.Servers.Count);
        Assert.Single(state.Servers);                   // preview changed nothing
    }

    /// <summary>A merge that adds nothing must be visible as nothing: the sheet
    /// disables its own Import button on this, and a «settings» word in the log
    /// line for a bundle that carried none would be a lie about the user's
    /// machine.</summary>
    [Fact]
    public void AnEmptyBundleAddsNothingAndSaysNothing()
    {
        var bundle = Bundle(servers: 0, withSettings: false);
        bundle.Subscriptions.Clear();
        var summary = TransferModel.Apply(bundle, new PersistedState(), checkbox: true);
        Assert.True(summary.AddsNothing);
        Assert.False(summary.SettingsApplied);
        Assert.Equal("imported from iPhone Маши: +0 servers, +0 subscriptions",
            TransferModel.ImportLog(bundle, summary));
    }

    /// <summary>What a preview must not do is reach back into the live store.
    /// Checked by instance identity rather than by timing: the merge appends to
    /// the lists and writes into the learned table, so those three must be new
    /// objects; everything else it replaces whole.</summary>
    [Fact]
    public void CloneCopiesExactlyWhatAMergeCanTouch()
    {
        var state = new PersistedState
        {
            Servers = new List<ProxyServer> { Bundle().Servers[0] },
            Subscriptions = new List<Subscription> { new("Панель", "https://a") },
            LearnedMasking = new Dictionary<string, string> { ["k"] = "balanced" },
        };
        state.Subscriptions[0].Servers.Add(Bundle().Servers[1]);
        var copy = state.Clone();
        Assert.NotSame(state.Servers, copy.Servers);
        Assert.NotSame(state.Subscriptions, copy.Subscriptions);
        Assert.NotSame(state.Subscriptions[0].Servers, copy.Subscriptions[0].Servers);
        Assert.NotSame(state.LearnedMasking, copy.LearnedMasking);
        copy.Servers.Clear();
        copy.Subscriptions[0].Servers.Clear();
        copy.LearnedMasking["second"] = "maximum";
        Assert.Single(state.Servers);
        Assert.Single(state.Subscriptions[0].Servers);
        Assert.Single(state.LearnedMasking);
    }

    /// <summary>A sheet that previews as the user types needs the copy to be
    /// cheap. The first version of this path serialized the whole state to JSON
    /// and parsed it back through the strict decoder: measured on this machine,
    /// 200 previews of a 300-server store cost 11,4 seconds that way and 9 ms
    /// with <see cref="PersistedState.Clone"/>. The bound here is loose on
    /// purpose (it would pass even on a ten-times slower machine) — it exists to
    /// catch a regression back to a serialize-per-keystroke, not to benchmark.</summary>
    [Fact]
    public void PreviewIsCheapEnoughToDoPerKeystroke()
    {
        var state = new PersistedState();
        for (var i = 0; i < 300; i++)
            state.Servers.Add(new ProxyServer
            {
                Name = "s" + i, Proto = ProxyProtocol.Vless, Address = $"h{i}.example.com",
                Port = 443, Credential = "c" + i,
            });
        var bundle = Bundle(servers: 10);
        var watch = System.Diagnostics.Stopwatch.StartNew();
        for (var round = 0; round < 50; round++) TransferModel.Preview(bundle, state, checkbox: true);
        watch.Stop();
        Assert.True(watch.ElapsedMilliseconds < 2000, $"50 превью заняли {watch.ElapsedMilliseconds} мс");
        Assert.Equal(300, state.Servers.Count);       // and none of them got in
    }

    [Theory]
    [InlineData(0, 0, "0")]
    [InlineData(3, 0, "3")]
    [InlineData(3, 2, "3 (2 already here)")]
    [InlineData(0, 5, "0 (5 already here)")]
    public void CountsSayHowManyAreNew(int added, int known, string expected) =>
        Assert.Equal(expected, TransferModel.CountText(added, known));
}
