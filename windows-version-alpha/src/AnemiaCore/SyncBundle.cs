using System.Globalization;
using System.IO.Compression;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AnemiaCore;

/// <summary>
/// What one Anemia hands another — Mac to iPhone and back — as a file (AirDrop,
/// Files) or a QR code: the servers added by hand, the subscriptions (their
/// addresses; each device fetches the lists itself) and the settings both apps
/// share. The selection stays behind: each device picks its own exit.
///
/// Port of `Sources/LoaderCore/SyncBundle.swift`. Two things make it more than a
/// struct with a serializer: the file form is compared **byte for byte** with
/// what `JSONEncoder` writes (see <see cref="SwiftJson"/>), and the link form is
/// a raw DEFLATE stream whose bytes Apple's `.zlib` and .NET's `DeflateStream`
/// produce identically at `CompressionLevel.Optimal` — measured on this Mac
/// against the three link rows of `sync/cases.golden.txt`, where a different
/// level gave 894 bytes against Apple's 869.
/// </summary>
public sealed class SyncBundle
{
    /// <summary>The only version this build reads.</summary>
    public const int FormatVersion = 1;

    /// <summary>File name extension of the JSON form.</summary>
    public const string FileExtension = "anemia";

    /// <summary>The QR / link form: `anemia://sync/` + base64url(deflate(JSON)).</summary>
    public const string LinkPrefix = "anemia://sync/";

    public int Version { get; set; } = FormatVersion;

    /// <summary>Seconds since 1970, kept as Foundation's `Date` holds them — a
    /// file may carry a fraction, and the writer drops it the way `JSONEncoder`
    /// does rather than rounding.</summary>
    public double ExportedAt { get; set; }

    /// <summary>The sending device's name, shown before importing.</summary>
    public string Device { get; set; } = "";

    public List<ProxyServer> Servers { get; set; } = new();
    public List<SubscriptionEntry> Subscriptions { get; set; } = new();

    /// <summary>Settings travel as optionals: a field one app doesn't have stays
    /// nil and leaves the other side's value alone.</summary>
    public BundleSettings? Settings { get; set; }

    public sealed record SubscriptionEntry(string Name, string Url);

    /// <summary>A bundle of `state`, with its shared settings.</summary>
    public static SyncBundle FromState(PersistedState state, string device, double exportedAt) => new()
    {
        Device = device,
        ExportedAt = exportedAt,
        Servers = state.Servers.ToList(),
        Subscriptions = state.Subscriptions
            .Select(sub => new SubscriptionEntry(sub.Name, sub.Url))
            .ToList(),
        Settings = new BundleSettings
        {
            MaskingProfile = state.MaskingProfile,
            KillSwitchEnabled = state.KillSwitchEnabled,
            SplitTunnel = state.SplitTunnel,
            // An empty learning table is not a decision to clear the other side's.
            LearnedMasking = state.LearnedMasking.Count == 0 ? null : state.LearnedMasking,
            SubscriptionAutoRefresh = state.SubscriptionAutoRefresh,
        },
    };

    /// <summary>
    /// Whether the text is ours at all — a link, or JSON that carries the two
    /// fields a bundle must have. The link form is matched case-insensitively
    /// here (a panel pasted from a web page that upper-cased it still looks like
    /// ours), while the JSON test is a plain substring check on the quoted keys —
    /// so a bundle pretty-printed with spaces around its colons still counts, and
    /// a share link does not.
    /// </summary>
    public static bool LooksLikeBundle(string text)
    {
        var trimmed = Foundation.TrimFoundationSpacesAndNewlines(text);
        if (trimmed.StartsWith(LinkPrefix, StringComparison.OrdinalIgnoreCase)) return true;
        return trimmed.StartsWith("{", StringComparison.Ordinal)
            && trimmed.Contains("\"exportedAt\"", StringComparison.Ordinal)
            && trimmed.Contains("\"device\"", StringComparison.Ordinal);
    }

    // MARK: - Reading

    /// <summary>`SyncBundle.DecodeError`.</summary>
    public sealed class DecodeException(string reason, int version = 0) : Exception(reason)
    {
        public string Reason { get; } = reason;
        public int NewerVersion { get; } = version;
        public override string ToString() => Reason == "newerVersion" ? $"newerVersion({NewerVersion})" : Reason;
    }

    /// <summary>Reads the file form or the link form, and tells "too new" apart
    /// from "not ours" — the two need different words in front of the user.</summary>
    public static SyncBundle Decode(string text)
    {
        var trimmed = Foundation.TrimFoundationSpacesAndNewlines(text);
        // Swift tests the prefix case-sensitively here and lower-cased inside
        // `FromLink`, so an upper-cased link reaches this port only by being
        // handed to `FromLink` directly — a difference the `read-link-uppercase`
        // case pins from both sides.
        if (trimmed.StartsWith(LinkPrefix, StringComparison.Ordinal)) return FromLink(trimmed);
        return DecodeJson(ParseOrNull(trimmed) ?? throw new DecodeException("notABundle"));
    }

    private static SyncBundle DecodeJson(JsonNode? root)
    {
        SyncBundle? bundle;
        try
        {
            bundle = FromJson(root);
        }
        catch (DecodeException)
        {
            throw;
        }
        catch (Exception)
        {
            bundle = null;
        }
        if (bundle is null)
        {
            // `decode` falls back to this check only to name the failure.
            if (root is JsonObject obj &&
                Strict.Int(obj["version"]) is { } version && version > FormatVersion &&
                Strict.Text(obj["device"]) is not null)
                throw new DecodeException("newerVersion", version);
            throw new DecodeException("notABundle");
        }
        if (bundle.Version > FormatVersion) throw new DecodeException("newerVersion", bundle.Version);
        return bundle;
    }

    /// <summary>Swift's synthesized `Decodable` for this struct: every declared
    /// field must be present and of the right type, and one bad server element
    /// costs the whole bundle — the state file drops bad servers instead, because
    /// its own reader is hand-written and lenient there.</summary>
    public static SyncBundle? FromJson(JsonNode? node)
    {
        if (node is not JsonObject obj) return null;
        if (Strict.Int(obj["version"]) is not { } version) return null;
        if (Strict.Text(obj["exportedAt"]) is not { } stampText) return null;
        if (SwiftDate.Parse(stampText) is not { } stamp) return null;
        if (Strict.Text(obj["device"]) is not { } device) return null;

        var servers = new List<ProxyServer>();
        if (obj["servers"] is not JsonArray serverArray) return null;
        foreach (var entry in serverArray)
        {
            if (PersistedState.ProxyServerFromJson(entry) is not { } server) return null;
            servers.Add(server);
        }

        var subscriptions = new List<SubscriptionEntry>();
        if (obj["subscriptions"] is not JsonArray subArray) return null;
        foreach (var item in subArray)
        {
            if (item is not JsonObject sub) return null;
            if (Strict.Text(sub["name"]) is not { } name) return null;
            if (Strict.Text(sub["url"]) is not { } url) return null;
            subscriptions.Add(new SubscriptionEntry(name, url));
        }

        BundleSettings? settings = null;
        if (obj.TryGetPropertyValue("settings", out var settingsNode) && settingsNode is not null &&
            settingsNode.GetValueKind() != JsonValueKind.Null)
        {
            settings = BundleSettings.FromJson(settingsNode);
            if (settings is null) return null;
        }

        return new SyncBundle
        {
            Version = version,
            ExportedAt = stamp,
            Device = device,
            Servers = servers,
            Subscriptions = subscriptions,
            Settings = settings,
        };
    }

    /// <summary>The link form, small enough for a QR code with a handful of
    /// servers. Compact, key-sorted JSON first — without the sort a dictionary's
    /// random order makes the same bundle a different, sometimes longer payload
    /// on every export.</summary>
    public string Link()
    {
        var json = Encoding.UTF8.GetBytes(SwiftJson.Compact(Node()));
        using var buffer = new MemoryStream();
        using (var deflate = new DeflateStream(buffer, CompressionLevel.Optimal, leaveOpen: true))
            deflate.Write(json);
        return LinkPrefix + Base64Url(buffer.ToArray());
    }

    public static SyncBundle FromLink(string text)
    {
        var trimmed = Foundation.TrimFoundationSpacesAndNewlines(text);
        if (!trimmed.StartsWith(LinkPrefix, StringComparison.OrdinalIgnoreCase))
            throw new DecodeException("notABundle");
        var payload = trimmed[LinkPrefix.Length..];
        if (!TryBase64Url(payload, out var packed)) throw new DecodeException("notABundle");
        JsonNode? root;
        try
        {
            using var input = new MemoryStream(packed);
            using var deflate = new DeflateStream(input, CompressionMode.Decompress);
            using var json = new MemoryStream();
            deflate.CopyTo(json);
            root = ParseOrNull(Encoding.UTF8.GetString(json.ToArray()));
        }
        catch (Exception)
        {
            throw new DecodeException("notABundle");
        }
        if (root is null) throw new DecodeException("notABundle");
        return DecodeJson(root);
    }

    // MARK: - Writing

    /// <summary>`JSONEncoder` with `[.prettyPrinted, .sortedKeys]` — the readable
    /// file form, byte for byte what the other three ports write.</summary>
    public string FileText() => SwiftJson.Pretty(Node());

    /// <summary>The bundle as the document the encoder writes: `version`,
    /// `exportedAt`, `device`, `servers`, `subscriptions`, and `settings` only
    /// when there are settings to carry.</summary>
    public JsonObject Node()
    {
        var obj = new JsonObject
        {
            ["version"] = Version,
            ["exportedAt"] = SwiftDate.Format(ExportedAt),
            ["device"] = Device,
            ["servers"] = new JsonArray(Servers.Select(s => (JsonNode?)PersistedState.ServerNode(s)).ToArray()),
            ["subscriptions"] = new JsonArray(Subscriptions
                .Select(entry => (JsonNode?)new JsonObject
                {
                    ["name"] = entry.Name,
                    ["url"] = entry.Url,
                })
                .ToArray()),
        };
        if (Settings is { } settings) obj["settings"] = settings.Node();
        return obj;
    }

    // MARK: - Merging

    public sealed class MergeSummary
    {
        public int AddedServers { get; init; }
        /// <summary>Servers the other side already had (same endpoint and credentials).</summary>
        public int KnownServers { get; init; }
        public List<SubscriptionEntry> NewSubscriptions { get; init; } = new();
        public int KnownSubscriptions { get; init; }
        public bool SettingsApplied { get; init; }
        public bool AddsNothing => AddedServers == 0 && NewSubscriptions.Count == 0 && !SettingsApplied;
    }

    /// <summary>What <see cref="Merge"/> would do to `state`, without doing it.</summary>
    public MergeSummary Preview(PersistedState state, bool applySettings)
    {
        var copy = state.Clone();   // not ToJson/FromJson: this runs as the sheet types
        return Merge(copy, applySettings);
    }

    /// <summary>Adds what `state` lacks — servers by identity (endpoint and
    /// credentials), subscriptions by address — and, with `applySettings`, takes
    /// over the settings the bundle carries. New subscriptions arrive empty (never
    /// fetched), for the caller to refresh.</summary>
    public MergeSummary Merge(PersistedState state, bool applySettings)
    {
        var addedServers = 0;
        var knownServers = 0;
        var knownSubscriptions = 0;
        var seen = state.AllServers.Select(s => s.IdentityKey).ToHashSet(StringComparer.Ordinal);
        var seenIds = state.AllServers.Select(s => s.Id).ToHashSet();
        foreach (var server in Servers)
        {
            var copy = server;
            if (!seen.Add(copy.IdentityKey))
            {
                knownServers++;
                continue;
            }
            // The same server edited on both sides keeps both copies apart.
            if (!seenIds.Add(copy.Id))
            {
                copy = CloneWithNewId(copy);
                seenIds.Add(copy.Id);
            }
            state.Servers.Add(copy);
            addedServers++;
        }

        var knownUrls = state.Subscriptions.Select(s => Normalized(s.Url)).ToHashSet(StringComparer.Ordinal);
        var newSubscriptions = new List<SubscriptionEntry>();
        foreach (var entry in Subscriptions)
        {
            if (!knownUrls.Add(Normalized(entry.Url)))
            {
                knownSubscriptions++;
                continue;
            }
            state.Subscriptions.Add(new Subscription { Name = entry.Name, Url = entry.Url });
            newSubscriptions.Add(entry);
        }

        var applied = false;
        if (applySettings && Settings is { } settings)
        {
            if (settings.MaskingProfile is { } profile) state.MaskingProfile = profile;
            if (settings.KillSwitchEnabled is { } kill) state.KillSwitchEnabled = kill;
            if (settings.SplitTunnel is { } rules) state.SplitTunnel = rules;
            if (settings.LearnedMasking is { } learned)
                foreach (var pair in learned) state.LearnedMasking[pair.Key] = pair.Value;
            if (settings.SubscriptionAutoRefresh is { } refresh) state.SubscriptionAutoRefresh = refresh;
            applied = true;
        }

        state.SelectedServerId ??= state.AllServers.FirstOrDefault()?.Id;

        return new MergeSummary
        {
            AddedServers = addedServers,
            KnownServers = knownServers,
            NewSubscriptions = newSubscriptions,
            KnownSubscriptions = knownSubscriptions,
            SettingsApplied = applied,
        };
    }

    /// <summary>Foundation's `normalized`: the panel address without its
    /// decoration, folded — so `https://a/` and `https://a ` are one panel.</summary>
    private static string Normalized(string url) =>
        Foundation.TrimFoundationSpacesAndNewlines(url)
            .ToLowerInvariant()
            .Trim('/');

    private static ProxyServer CloneWithNewId(ProxyServer server)
    {
        var node = PersistedState.ProxyServerFromJson(PersistedState.ServerNode(server));
        if (node is null) return server;
        node.Id = Guid.NewGuid();
        return node;
    }

    private static JsonNode? ParseOrNull(string text)
    {
        try { return JsonNode.Parse(text); }
        catch (JsonException) { return null; }
    }

    private static string Base64Url(byte[] data) =>
        Convert.ToBase64String(data).Replace('+', '-').Replace('/', '_').TrimEnd('=');

    private static bool TryBase64Url(string text, out byte[] data)
    {
        var base64 = text.Replace('-', '+').Replace('_', '/');
        base64 += new string('=', (4 - base64.Length % 4) % 4);
        try
        {
            data = Convert.FromBase64String(base64);
            return true;
        }
        catch (FormatException)
        {
            data = Array.Empty<byte>();
            return false;
        }
    }
}

/// <summary>The settings half of a bundle. Every field is optional on purpose:
/// a field one app has and another doesn't stays nil and leaves the receiving
/// side's own value alone rather than resetting it to a default.</summary>
public sealed class BundleSettings
{
    public MaskingProfile? MaskingProfile { get; set; }
    public bool? KillSwitchEnabled { get; set; }
    public SplitTunnelRules? SplitTunnel { get; set; }
    public Dictionary<string, string>? LearnedMasking { get; set; }
    public bool? SubscriptionAutoRefresh { get; set; }
    /// <summary>Block ads (AdGuard DNS), in both apps. Kept by each app itself,
    /// outside the state file, so the bundle carries it on its own.</summary>
    public bool? AdBlock { get; set; }
    // iPhone-only; the other ports ignore them.
    public bool? AutoReconnect { get; set; }
    public bool? AutoSwitch { get; set; }
    public bool? AdaptiveMasking { get; set; }

    /// <summary>Swift's synthesized decoder for these optionals: a field of the
    /// wrong type is a failed decode, and a failed decode costs the whole bundle
    /// — unlike the state file, whose hand-written reader keeps going. A profile
    /// name that is not one of the raw values is therefore refused here while
    /// `state.json` falls back to `balanced`.</summary>
    public static BundleSettings? FromJson(JsonNode? node)
    {
        if (node is not JsonObject obj) return null;
        var settings = new BundleSettings();
        foreach (var (key, value) in obj)
        {
            switch (key)
            {
                case "maskingProfile":
                    if (Strict.Text(value) is not { } profile) return null;
                    if (!TryProfile(profile, out var parsed)) return null;
                    settings.MaskingProfile = parsed;
                    break;
                case "killSwitchEnabled":
                    if (Strict.Bool(value) is not { } kill) return null;
                    settings.KillSwitchEnabled = kill;
                    break;
                case "splitTunnel":
                    if (SplitTunnelRules.FromJson(value) is not { } rules) return null;
                    settings.SplitTunnel = rules;
                    break;
                case "learnedMasking":
                    if (Strict.TextMap(value) is not { } learned) return null;
                    settings.LearnedMasking = learned;
                    break;
                case "subscriptionAutoRefresh":
                    if (Strict.Bool(value) is not { } refresh) return null;
                    settings.SubscriptionAutoRefresh = refresh;
                    break;
                case "adBlock":
                    if (Strict.Bool(value) is not { } adBlock) return null;
                    settings.AdBlock = adBlock;
                    break;
                case "autoReconnect":
                    if (Strict.Bool(value) is not { } reconnect) return null;
                    settings.AutoReconnect = reconnect;
                    break;
                case "autoSwitch":
                    if (Strict.Bool(value) is not { } autoSwitch) return null;
                    settings.AutoSwitch = autoSwitch;
                    break;
                case "adaptiveMasking":
                    if (Strict.Bool(value) is not { } adaptive) return null;
                    settings.AdaptiveMasking = adaptive;
                    break;
                default:
                    break;      // an unknown key is not a failure — that is how a newer app's bundle stays readable
            }
        }
        return settings;
    }

    public JsonObject Node()
    {
        var obj = new JsonObject();
        PersistedState.Put(obj, "maskingProfile",
            MaskingProfile is { } profile ? JsonValue.Create(PersistedState.RawValue(profile)) : null);
        PersistedState.Put(obj, "killSwitchEnabled",
            KillSwitchEnabled is { } kill ? JsonValue.Create(kill) : null);
        PersistedState.Put(obj, "splitTunnel", SplitTunnel?.ToJson());
        if (LearnedMasking is { } learned)
        {
            var map = new JsonObject();
            foreach (var pair in learned.OrderBy(e => e.Key, StringComparer.Ordinal)) map[pair.Key] = pair.Value;
            obj["learnedMasking"] = map;
        }
        PersistedState.Put(obj, "subscriptionAutoRefresh",
            SubscriptionAutoRefresh is { } refresh ? JsonValue.Create(refresh) : null);
        PersistedState.Put(obj, "adBlock", AdBlock is { } adBlock ? JsonValue.Create(adBlock) : null);
        PersistedState.Put(obj, "autoReconnect",
            AutoReconnect is { } reconnect ? JsonValue.Create(reconnect) : null);
        PersistedState.Put(obj, "autoSwitch", AutoSwitch is { } autoSwitch ? JsonValue.Create(autoSwitch) : null);
        PersistedState.Put(obj, "adaptiveMasking",
            AdaptiveMasking is { } adaptive ? JsonValue.Create(adaptive) : null);
        return obj;
    }

    private static bool TryProfile(string text, out MaskingProfile profile)
    {
        // Qualified: inside this class the property of the same name shadows the
        // enum type.
        profile = AnemiaCore.MaskingProfile.Balanced;
        foreach (var candidate in Enum.GetValues<AnemiaCore.MaskingProfile>())
        {
            if (!string.Equals(PersistedState.RawValue(candidate), text, StringComparison.Ordinal)) continue;
            profile = candidate;
            return true;
        }
        return false;
    }
}
