using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace AnemiaCore;

/// <summary>
/// The full persisted client state: manually-added servers, subscriptions, the
/// current selection, and anti-DPI options.
/// </summary>
public sealed class PersistedState
{
    public List<ProxyServer> Servers { get; set; } = new();
    public List<Subscription> Subscriptions { get; set; } = new();
    public Guid? SelectedServerId { get; set; }
    public AntiCensorshipOptions Anti { get; set; } = new();
    public bool KillSwitchEnabled { get; set; }
    public MaskingProfile MaskingProfile { get; set; } = MaskingProfile.Balanced;
    public bool AutoConnectOnLaunch { get; set; }
    /// <summary>Coexist mode: set the Windows system proxy to the engine while
    /// connected, so browsers route through Anemia alongside another VPN.
    /// Off by default, as on macOS: this changes a setting that outlives the app,
    /// so it is the user's explicit choice and not something a first launch or a
    /// restored file decides for them.</summary>
    public bool SystemProxyEnabled { get; set; }
    /// <summary>Refresh subscriptions automatically: once shortly after launch,
    /// then every 6 hours. Keeps expiring/rotating server lists current.</summary>
    public bool SubscriptionAutoRefresh { get; set; } = true;
    /// <summary>
    /// Masking profile (by ProxyServer.IdentityKey) that was learned to keep a
    /// given server's traffic flowing, from adaptive escalation during
    /// recovery. Reused on the next connect to that server so it starts from
    /// the obfuscation it actually needs, not the global default.
    /// </summary>
    public Dictionary<string, string> LearnedMasking { get; set; } = new();

    /// <summary>Local-bypass rules as the user typed them (see
    /// <see cref="SplitTunnelRules"/>): the raw lines are what persists, and the
    /// helper re-parses them on every connect, so opening a Mac's state.json
    /// here carries the rules and <see cref="SplitTunnelPlan"/> decides what
    /// routes they mean on Windows.</summary>
    public SplitTunnelRules SplitTunnel { get; set; } = new();

    /// <summary>Whether the learned model ranks servers. Nothing on Windows
    /// ranks with a model (no CoreML equivalent), but the flag belongs to the
    /// user's file, so it survives a round trip through this app.</summary>
    public bool MlRankingEnabled { get; set; } = true;

    public PersistedState() { }

    /// <summary>Lenient decoding: missing or malformed fields fall back to
    /// defaults so a schema change never discards a user's saved servers.
    /// Collections decode element-by-element: a single poisoned entry drops
    /// only itself, not the whole list. Returns null when the store is so
    /// corrupt that defaults should replace it (the persistence layer then
    /// backs the raw bytes up first).</summary>
    public static PersistedState? FromJson(JsonNode? root)
    {
        if (root is not JsonObject obj) return null;
        var state = new PersistedState();

        state.Servers = LenientArray(obj, "servers", ProxyServerFromJson);
        // Same all-or-nothing rule as a server: a saved subscription whose
        // stamp is a *string* is refused entirely (the `dates` fixture: Swift
        // keeps three of four, this port kept all four), and inventing a fresh
        // id for a row the others threw away would resurrect it on the next
        // sync.
        state.Subscriptions = LenientArray(obj, "subscriptions", SubscriptionFromJson);
        // Every fallback below is Swift's, taken off `PersistedState.init(from:)`:
        // the value is decoded strictly, and a wrong type takes the *default* —
        // not a coerced one. `"4"` for muxConcurrency is 8 there, and a
        // `systemProxyEnabled` of "yes" is false, because that is what the Mac
        // and the phone write back from the same bytes.
        if (Strict.Text(obj["selectedServerID"]) is { } selected && IsUuid(selected))
            state.SelectedServerId = Guid.ParseExact(selected, "D");
        // An `anti` key that is *absent* is not an empty one: Swift's
        // `(try? c.decode(AntiCensorshipOptions.self, forKey: .anti)) ?? .recommended`
        // hands back the recommended profile — fragmentation plus one junk
        // generator — while `anti: {}` decodes leniently to no fragment and no
        // noises. Writing the wrong one of these silently disables a user's
        // anti-DPI shape on the next save.
        // Absent, null or a wrongly-typed container all take the recommended
        // profile; only a real object goes through the lenient decode, where
        // `anti: {}` means "no fragment, no noises" — the difference between the
        // two is a user's anti-DPI shape on the next save.
        state.Anti = obj["anti"] is JsonObject antiObject
            ? AntiCensorshipOptions.FromJson(antiObject)
            : AntiCensorshipOptions.Recommended;
        state.KillSwitchEnabled = Strict.Bool(obj["killSwitchEnabled"]) ?? false;
        // Swift decodes an enum by its raw value exactly: "MAXIMUM" or "Balanced"
        // is not a profile and falls back to .balanced.
        foreach (var candidate in Enum.GetValues<MaskingProfile>())
            if (Strict.Text(obj["maskingProfile"]) is { } profile && MatchesRawValue(candidate, profile))
            { state.MaskingProfile = candidate; break; }
        state.AutoConnectOnLaunch = Strict.Bool(obj["autoConnectOnLaunch"]) ?? false;
        state.SystemProxyEnabled = Strict.Bool(obj["systemProxyEnabled"]) ?? false;
        state.SubscriptionAutoRefresh = Strict.Bool(obj["subscriptionAutoRefresh"]) ?? true;
        state.MlRankingEnabled = Strict.Bool(obj["mlRankingEnabled"]) ?? true;
        state.LearnedMasking = Strict.TextMap(obj["learnedMasking"]) ?? new Dictionary<string, string>();
        state.SplitTunnel = SplitTunnelRules.FromJson(obj["splitTunnel"]);
        return state;
    }

    /// <summary>
    /// Decode one saved server. Swift's <c>ProxyServer</c> has no custom
    /// <c>init(from:)</c>, so the synthesized decoder is all-or-nothing: one
    /// wrong type anywhere — including inside <c>awg</c> and
    /// <c>wgProfile</c> — throws, and the caller's element-wise leniency drops
    /// that server alone. Being gentler here would leave this port holding
    /// entries the Mac and the phone threw away, and writing them back would
    /// resurrect them on the next sync, which is how a corrupt record becomes
    /// permanent.
    /// </summary>
    public static ProxyServer? ProxyServerFromJson(JsonNode? node)
    {
        if (node is not JsonObject o) return null;
        try
        {
            // Required, exactly as Swift declares them.
            if (Strict.Text(o["id"]) is not { } idText || !IsUuid(idText)) return null;
            if (Strict.Text(o["name"]) is not { } name) return null;
            if (Strict.Text(o["proto"]) is not { } proto || Wire.ParseProtocol(proto) is not { } protocol
                || !string.Equals(Wire.Name(protocol), proto, StringComparison.Ordinal)) return null;
            if (Strict.Text(o["address"]) is not { } address) return null;
            if (Strict.Int(o["port"]) is not { } port) return null;
            if (Strict.Text(o["credential"]) is not { } credential) return null;
            if (Strict.Int(o["alterId"]) is not { } alterId) return null;
            if (Strict.Text(o["network"]) is not { } network || Wire.ParseNetwork(network) is not { } net
                || !string.Equals(Wire.Name(net), network, StringComparison.Ordinal)) return null;
            if (Strict.Text(o["security"]) is not { } security || Wire.ParseSecurity(security) is not { } sec
                || !string.Equals(Wire.Name(sec), security, StringComparison.Ordinal)) return null;
            if (Strict.TextArray(o["alpn"]) is not { } alpn) return null;
            if (Strict.Bool(o["allowInsecure"]) is not { } allowInsecure) return null;

            var server = new ProxyServer
            {
                Id = Guid.ParseExact(idText, "D"),
                Name = name,
                Proto = protocol,
                Address = address,
                Port = port,
                Credential = credential,
                AlterId = alterId,
                Network = net,
                Security = sec,
                Alpn = alpn,
                AllowInsecure = allowInsecure,
            };

            // Optionals: absent or null means nil; a value of the wrong type
            // means the whole entry is refused.
            bool Bad(JsonNode? value, out string? text)
            {
                text = null;
                if (value is null || value.GetValueKind() == System.Text.Json.JsonValueKind.Null) return false;
                if (Strict.Text(value) is not { } found) return true;
                text = found;
                return false;
            }
            foreach (var (key, assign) in new (string, System.Action<string?>)[]
            {
                ("method", v => server.Method = v), ("vmessCipher", v => server.VmessCipher = v),
                ("sni", v => server.Sni = v), ("fingerprint", v => server.Fingerprint = v),
                ("realityPublicKey", v => server.RealityPublicKey = v),
                ("realityShortId", v => server.RealityShortId = v),
                ("realitySpiderX", v => server.RealitySpiderX = v),
                ("flow", v => server.Flow = v), ("path", v => server.Path = v),
                ("host", v => server.Host = v), ("headerType", v => server.HeaderType = v),
                ("xhttpMode", v => server.XhttpMode = v), ("xhttpExtra", v => server.XhttpExtra = v),
                ("vlessEncryption", v => server.VlessEncryption = v),
            })
            {
                if (!o.TryGetPropertyValue(key, out var value)) continue;
                if (Bad(value, out var text)) return null;
                assign(text);
            }
            if (o.TryGetPropertyValue("grpcMultiMode", out var grpc) && grpc is not null &&
                grpc.GetValueKind() != System.Text.Json.JsonValueKind.Null)
            {
                if (Strict.Bool(grpc) is not { } multi) return null;
                server.GrpcMultiMode = multi;
            }
            if (o.TryGetPropertyValue("userData", out var userData) && userData is not null)
            {
                if (userData.GetValueKind() == System.Text.Json.JsonValueKind.Null)
                    server.UserData = null;
                else if (Strict.TextMap(userData) is not { } map) return null;
                else server.UserData = map;
            }
            if (o.TryGetPropertyValue("awg", out var awg) && awg is not null &&
                awg.GetValueKind() != System.Text.Json.JsonValueKind.Null)
            {
                try { server.Awg = AwgObfuscation.FromJson(awg); }
                catch (AwgShapeException) { return null; }
                if (server.Awg is null) return null;
            }
            if (o.TryGetPropertyValue("wgProfile", out var profile) && profile is not null &&
                profile.GetValueKind() != System.Text.Json.JsonValueKind.Null)
            {
                server.WgProfile = WireGuardProfile.FromJson(profile);
                if (server.WgProfile is null) return null;
            }
            return server;
        }
        catch (FormatException) { return null; }      // a UUID that only looked like one
        catch (System.Text.Json.JsonException) { return null; }
        catch (InvalidOperationException) { return null; }
    }

    /// <summary>Foundation's <c>UUID(uuidString:)</c> wants the 8-4-4-4-12
    /// dashed form and nothing else; <c>Guid.TryParse</c> also eats a bare
    /// 32-hex, a leading space and braces, so a port using it keeps four
    /// servers per file where the other three keep one.</summary>
    /// <summary>A saved subscription, decoded the way Swift's synthesized
    /// <c>Decodable</c> does it: every declared field must be present and of the
    /// declared type, and one that is not costs the whole entry. The
    /// <c>dates</c> fixture is exactly this test — a subscription whose
    /// <c>lastUpdated</c> is the string "791692800" is refused there and was kept
    /// here, and a kept row that the other three dropped grows the list on every
    /// device that reads the file.</summary>
    public static Subscription? SubscriptionFromJson(JsonNode? node)
    {
        if (node is not JsonObject s) return null;
        if (Strict.Text(s["id"]) is not { } idText || !IsUuid(idText)) return null;
        if (Strict.Text(s["name"]) is not { } name) return null;
        if (Strict.Text(s["url"]) is not { } url) return null;
        DateTimeOffset? last = null;
        if (s["lastUpdated"] is { } stamp && stamp.GetValueKind() != System.Text.Json.JsonValueKind.Null)
        {
            if (Strict.Double(stamp) is not { } seconds) return null;
            last = FromReferenceSeconds(seconds);
        }
        return new Subscription
        {
            Id = Guid.ParseExact(idText, "D"),
            Name = name,
            Url = url,
            LastUpdated = last,
            Servers = LenientArray(s, "servers", ProxyServerFromJson),
        };
    }

    public static bool IsUuid(string text)
    {
        if (text.Length != 36) return false;
        var groups = new[] { 8, 4, 4, 4, 12 };
        var at = 0;
        foreach (var width in groups)
        {
            for (var i = 0; i < width; i++, at++)
                if (!Uri.IsHexDigit(text[at])) return false;
            if (width != 12 && (at >= text.Length || text[at++] != '-')) return false;
        }
        return true;
    }

    private static List<T> LenientArray<T>(JsonObject obj, string key, Func<JsonNode?, T?> map) where T : class
    {
        var result = new List<T>();
        if (obj[key] is JsonArray arr)
        {
            foreach (var entry in arr)
                if (map(entry) is { } mapped) result.Add(mapped);
        }
        return result;
    }

    /// <summary>The document Swift's encoder writes for the same state: keys in
    /// the order the properties are declared (the compare sorts them, so order
    /// is only about readability), UUIDs the way Foundation prints them, dates as
    /// reference-date seconds, and — the part that actually differs between two
    /// encoders — <c>encodeIfPresent</c> semantics: a nil optional leaves the key
    /// out rather than writing null. The one <c>:null</c> in a golden decode row
    /// is a server literally named "alpn:null".</summary>
    public JsonObject ToJson()
    {
        var obj = new JsonObject
        {
            ["servers"] = ToJsonArray(Servers),
        };
        var subscriptions = new JsonArray();
        foreach (var sub in Subscriptions)
        {
            var entry = new JsonObject
            {
                ["id"] = TrafficLedger.Uuid(sub.Id),
                ["name"] = sub.Name,
                ["url"] = sub.Url,
            };
            if (sub.LastUpdated is { } stamp)
                entry["lastUpdated"] = JsonValue.Create(ToReferenceSeconds(stamp));
            entry["servers"] = ToJsonArray(sub.Servers);
            subscriptions.Add(entry);
        }
        obj["subscriptions"] = subscriptions;
        Put(obj, "selectedServerID",
            SelectedServerId is { } selected ? JsonValue.Create(TrafficLedger.Uuid(selected)) : null);
        obj["anti"] = Anti.ToJson();
        obj["killSwitchEnabled"] = KillSwitchEnabled;
        obj["maskingProfile"] = RawValue(MaskingProfile);
        obj["autoConnectOnLaunch"] = AutoConnectOnLaunch;
        obj["mlRankingEnabled"] = MlRankingEnabled;
        obj["systemProxyEnabled"] = SystemProxyEnabled;
        obj["subscriptionAutoRefresh"] = SubscriptionAutoRefresh;
        obj["splitTunnel"] = SplitTunnel.ToJson();
        var learned = new JsonObject();
        foreach (var (k, v) in LearnedMasking) learned[k] = v;
        obj["learnedMasking"] = learned;
        return obj;
    }

    /// <summary>Foundation prints a UUID in upper case, and every file the other
    /// three ports read carries that spelling.</summary>
    internal static void Put(JsonObject obj, string key, JsonNode? value)
    {
        if (value is not null) obj[key] = value;
    }

    private static JsonNode? Text(string? value) => value is null ? null : JsonValue.Create(value);

    /// <summary>Swift's `MaskingProfile` raw values are the lower-camel case
    /// names (`balanced`, `ruYandex`); the enum's `ToString()` is PascalCase, and
    /// writing that into the shared file is how a port quietly renames every
    /// profile on the first save.</summary>
    /// <summary>The wire form of a profile — the enum's raw value in
    /// Swift, which is lower-camel and not the C# name.</summary>
    public static string RawValue(MaskingProfile profile) => profile switch
    {
        MaskingProfile.Off => "off",
        MaskingProfile.Balanced => "balanced",
        MaskingProfile.Maximum => "maximum",
        MaskingProfile.RuYandex => "ruYandex",
        MaskingProfile.RuVK => "ruVK",
        _ => profile.ToString(),
    };

    internal static bool MatchesRawValue(MaskingProfile profile, string text) =>
        string.Equals(RawValue(profile), text, StringComparison.Ordinal);

    /// <summary>Seconds since Foundation's reference date, as a number — what
    /// `JSONEncoder` writes for a `Date` by default.</summary>
    internal static double ToReferenceSeconds(DateTimeOffset moment) =>
        (moment - UnixEpoch).TotalSeconds - ReferenceSeconds;

    internal static DateTimeOffset FromReferenceSeconds(double seconds) =>
        UnixEpoch.AddSeconds(seconds + ReferenceSeconds);

    private static readonly DateTimeOffset UnixEpoch = new(1970, 1, 1, 0, 0, 0, TimeSpan.Zero);
    private const double ReferenceSeconds = 978307200;

    private static JsonArray ToJsonArray(IEnumerable<JsonObject> entries)
    {
        var arr = new JsonArray();
        foreach (var s in entries) arr.Add(s);
        return arr;
    }

    private static JsonArray ToJsonArray(IEnumerable<ProxyServer> servers)
    {
        var arr = new JsonArray();
        foreach (var s in servers) arr.Add(ServerNode(s));
        return arr;
    }

    /// <summary>One server in the shape the shared file uses — the same node the
    /// state writer and the sync bundle must produce, or a bundle would carry a
    /// server the other devices read as a different one.</summary>
    internal static JsonObject ServerNode(ProxyServer s)
    {
        var entry = new JsonObject
        {
            ["id"] = TrafficLedger.Uuid(s.Id),
            ["name"] = s.Name,
            ["proto"] = Wire.Name(s.Proto),
            ["address"] = s.Address,
            ["port"] = s.Port,
            ["credential"] = s.Credential,
            ["alterId"] = s.AlterId,
            ["network"] = Wire.Name(s.Network),
            ["security"] = Wire.Name(s.Security),
            ["alpn"] = new JsonArray(s.Alpn.Select(a => (JsonNode?)JsonValue.Create(a)).ToArray()),
            ["allowInsecure"] = s.AllowInsecure,
        };
        // Optionals are omitted, not nulled: that is what
        // `encodeIfPresent` in the synthesized encoder does, and the diff
        // between the two is a key the other ports never learned to ignore.
        Put(entry, "method", Text(s.Method));
        Put(entry, "vmessCipher", Text(s.VmessCipher));
        Put(entry, "sni", Text(s.Sni));
        Put(entry, "fingerprint", Text(s.Fingerprint));
        Put(entry, "realityPublicKey", Text(s.RealityPublicKey));
        Put(entry, "realityShortId", Text(s.RealityShortId));
        Put(entry, "realitySpiderX", Text(s.RealitySpiderX));
        Put(entry, "flow", Text(s.Flow));
        Put(entry, "path", Text(s.Path));
        Put(entry, "host", Text(s.Host));
        Put(entry, "headerType", Text(s.HeaderType));
        Put(entry, "xhttpMode", Text(s.XhttpMode));
        Put(entry, "xhttpExtra", Text(s.XhttpExtra));
        Put(entry, "vlessEncryption", Text(s.VlessEncryption));
        Put(entry, "grpcMultiMode", s.GrpcMultiMode is { } grpc ? JsonValue.Create(grpc) : null);
        if (s.Awg is { } awg) entry["awg"] = awg.ToJson();
        if (s.WgProfile is { } profile) entry["wgProfile"] = profile.ToJson();
        if (s.UserData is { } userData)
        {
            var map = new JsonObject();
            foreach (var (k, v) in userData.OrderBy(e => e.Key, StringComparer.Ordinal)) map[k] = v;
            entry["userData"] = map;
        }
        return entry;
    }

    /// <summary>A copy a merge can be tested against. This exists because
    /// `Preview` used to serialize the whole state to JSON and parse it back on
    /// every call — a sheet that previews as you type did that per keystroke.
    ///
    /// Only what a merge can touch is rebuilt: the two lists, each
    /// subscription's server list, and the learned-masking table. The servers
    /// themselves are shared — a merge appends them or rewrites an id on a
    /// private copy, it never edits one in place — and `anti` / `splitTunnel`
    /// are replaced whole, not modified, so sharing those objects keeps the
    /// preview from pretending to need a deep copy it would have to keep in sync
    /// with every new field.</summary>
    public PersistedState Clone()
    {
        var copy = new PersistedState
        {
            Servers = new List<ProxyServer>(Servers),
            Subscriptions = Subscriptions.Select(sub => new Subscription
            {
                Id = sub.Id,
                Name = sub.Name,
                Url = sub.Url,
                LastUpdated = sub.LastUpdated,
                Servers = new List<ProxyServer>(sub.Servers),
            }).ToList(),
            SelectedServerId = SelectedServerId,
            Anti = Anti,
            KillSwitchEnabled = KillSwitchEnabled,
            MaskingProfile = MaskingProfile,
            AutoConnectOnLaunch = AutoConnectOnLaunch,
            SystemProxyEnabled = SystemProxyEnabled,
            SubscriptionAutoRefresh = SubscriptionAutoRefresh,
            LearnedMasking = new Dictionary<string, string>(LearnedMasking, StringComparer.Ordinal),
            SplitTunnel = SplitTunnel,
            MlRankingEnabled = MlRankingEnabled,
        };
        return copy;
    }

    /// <summary>Every selectable server: manual entries first, then
    /// subscription servers.</summary>
    [JsonIgnore]
    public IEnumerable<ProxyServer> AllServers => Servers.Concat(Subscriptions.SelectMany(s => s.Servers));

    public ProxyServer? ServerWithId(Guid id) => AllServers.FirstOrDefault(s => s.Id == id);
}

/// <summary>
/// Reads/writes <see cref="PersistedState"/> as JSON on disk. Writes atomically
/// so a crash mid-save can't corrupt the store.
/// </summary>
public sealed class StatePersistence
{
    private static readonly JsonSerializerOptions WriteOptions = new() { WriteIndented = true };

    public string FilePath { get; }

    public StatePersistence(string filePath) => FilePath = filePath;

    /// <summary>Default location: %APPDATA%\Anemia\state.json.</summary>
    public static string DefaultPath()
    {
        var baseDir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        if (string.IsNullOrEmpty(baseDir)) baseDir = Environment.CurrentDirectory;
        return Path.Combine(baseDir, "Anemia", "state.json");
    }

    /// <summary>
    /// Load state, returning an empty default if the file is absent/unreadable.
    /// A malformed or schema-drifted file is backed up first — the lenient
    /// decoder never throws on field mismatches (it falls back per-field), so a
    /// silent data loss must be detected by comparing the raw JSON with what
    /// the decode recovered.
    /// </summary>
    public PersistedState Load()
    {
        byte[] data;
        try
        {
            data = File.ReadAllBytes(FilePath);
        }
        catch (IOException)
        {
            return new PersistedState();
        }
        catch (UnauthorizedAccessException)
        {
            return new PersistedState();
        }

        PersistedState? decoded = null;
        JsonObject? raw = null;
        try
        {
            raw = JsonNode.Parse(data) as JsonObject;
            decoded = PersistedState.FromJson(raw);
        }
        catch (JsonException)
        {
            decoded = null;
        }

        // Schema drift detector: the raw store still carries entries in some
        // collection, but the decode recovered fewer of them (or none — or
        // failed outright) → previous contents are about to be lost. Counts
        // are compared, not just emptiness. Every persisted collection is
        // checked, not just `servers`.
        var droppedEntries = false;
        if (raw is not null)
        {
            static int? RawCount(JsonNode? v)
            {
                if (v is null) return null;
                if (v is JsonArray a) return a.Count;
                if (v is JsonObject o) return o.Count;
                return 1;
            }
            int? DecodedCount(int actual) => decoded is null ? 0 : actual;

            if (RawCount(raw["servers"]) is { } n1)
                droppedEntries = droppedEntries || (decoded?.Servers.Count ?? 0) < n1;
            if (RawCount(raw["subscriptions"]) is { } n2)
                droppedEntries = droppedEntries || (decoded?.Subscriptions.Count ?? 0) < n2;
            if (RawCount(raw["learnedMasking"]) is { } n3)
                droppedEntries = droppedEntries || (decoded?.LearnedMasking.Count ?? 0) < n3;
            _ = DecodedCount(0);
        }
        if (decoded is null || droppedEntries)
        {
            // Millisecond timestamp: a same-second collision would silently
            // overwrite an earlier backup.
            var backup = Path.Combine(
                Path.GetDirectoryName(FilePath)!,
                $"{Path.GetFileNameWithoutExtension(FilePath)}.json.corrupt-{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}.bak");
            try
            {
                File.WriteAllBytes(backup, data);
            }
            catch (IOException)
            {
                // recovery must never crash the app
            }
            catch (UnauthorizedAccessException)
            {
            }
            PruneCorruptBackups();
        }
        return decoded ?? new PersistedState();
    }

    public void Save(PersistedState state)
    {
        var dir = Path.GetDirectoryName(FilePath);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        // Write-then-rename: the closest portable equivalent of an atomic
        // file write, so a crash mid-save can't corrupt the store.
        var tmp = FilePath + ".tmp";
        File.WriteAllText(tmp, state.ToJson().ToJsonString(WriteOptions));
        if (File.Exists(FilePath)) File.Replace(tmp, FilePath, null);
        else File.Move(tmp, FilePath);
    }

    /// <summary>A persistently poisoned store re-enters the backup path on
    /// every app launch, each run dropping a fresh timestamped .corrupt-*.bak
    /// next to the state file — unbounded clutter. Keep only the newest few
    /// and delete the rest (best effort; failure to prune must never fail the
    /// load).</summary>
    private void PruneCorruptBackups(int kept = 3)
    {
        try
        {
            var dir = Path.GetDirectoryName(FilePath);
            if (dir is null) return;
            var baseName = Path.GetFileNameWithoutExtension(FilePath);
            var backups = Directory.GetFiles(dir, $"{baseName}.json.corrupt-*.bak")
                .OrderByDescending(static f => f, StringComparer.Ordinal) // newest (largest ms stamp) first
                .ToList();
            for (var i = kept; i < backups.Count; i++)
            {
                try { File.Delete(backups[i]); } catch (IOException) { }
            }
        }
        catch (IOException)
        {
        }
    }
}