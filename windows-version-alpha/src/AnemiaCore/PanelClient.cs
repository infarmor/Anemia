using System.Globalization;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AnemiaCore;

/// <summary>
/// The shared rules of a subscription fetch, so the Windows client asks the same
/// questions macOS and iOS do. Port of the body of
/// <c>Sources/LoaderApp/App/AppState.swift</c>'s <c>refresh(_:)</c>.
/// </summary>
public static class PanelClient
{
    /// <summary>Most subscription panels (3x-ui, Marzban, RealityEZPZ) gate on
    /// User-Agent and answer an HTML error page to unknown clients; v2rayN is the
    /// most widely allow-listed header across providers.</summary>
    public const string UserAgent = "v2rayN/6.26";

    /// <summary>A panel that means it sends tens of kilobytes. Four megabytes is
    /// the cap the iOS/macOS layer settled on: a captive portal or a hostile
    /// redirect can otherwise stream forever while the client waits to parse.</summary>
    public const int MaxBodyBytes = 4 * 1024 * 1024;

    /// <summary>Headers as <see cref="SubscriptionInfo.Parse"/> wants them: wire
    /// case preserved, first value of a repeated name.</summary>
    public static Dictionary<string, string> Headers(HttpResponseMessage response)
    {
        var headers = new Dictionary<string, string>(StringComparer.Ordinal);
        void Add(IEnumerable<KeyValuePair<string, IEnumerable<string>>> source)
        {
            foreach (var (name, values) in source)
                if (!headers.ContainsKey(name) && values.FirstOrDefault() is { } value)
                    headers[name] = value;
        }
        Add(response.Headers);
        Add(response.Content?.Headers ?? Enumerable.Empty<KeyValuePair<string, IEnumerable<string>>>());
        return headers;
    }

    /// <summary>Read the body with a hard ceiling. Returning null means "too
    /// big", which the caller must treat as a failed fetch rather than as a
    /// truncated list — half a subscription is not a smaller subscription.</summary>
    public static async Task<string?> ReadBodyCappedAsync(HttpResponseMessage response, CancellationToken ct)
    {
        await using var stream = await response.Content.ReadAsStreamAsync(ct);
        var buffer = new byte[64 * 1024];
        var collected = new MemoryStream();
        while (true)
        {
            var read = await stream.ReadAsync(buffer, ct);
            if (read == 0) break;
            if (collected.Length + read > MaxBodyBytes) return null;
            collected.Write(buffer, 0, read);
        }
        return Encoding.UTF8.GetString(collected.ToArray());
    }
}

/// <summary>
/// What each panel said about the account last time it was fetched. Kept in its
/// own file rather than in <c>state.json</c>: that file is Swift's format, read
/// back by the Mac and the phone, and the headers are transient metadata —
/// macOS and iOS hold them in UserDefaults, Android in its prefs, and neither
/// mixes them into the server list.
/// </summary>
public sealed class SubscriptionInfoStore
{
    public string FilePath { get; }

    private readonly Dictionary<Guid, SubscriptionInfo> _infos = new();

    public SubscriptionInfoStore(string? filePath = null)
    {
        FilePath = filePath ?? DefaultPath();
        Load();
    }

    public static string DefaultPath()
    {
        var baseDir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        if (string.IsNullOrEmpty(baseDir)) baseDir = Environment.CurrentDirectory;
        return Path.Combine(baseDir, "Anemia", "panels.json");
    }

    public SubscriptionInfo? this[Guid id] => _infos.TryGetValue(id, out var info) ? info : null;

    public void Remember(Guid id, SubscriptionInfo? info)
    {
        if (info is null) return;
        _infos[id] = info;
        Save();
    }

    public void Forget(Guid id)
    {
        _attempts.Remove(id);
        if (_infos.Remove(id)) Save();
    }

    /// <summary>When a round last tried this panel, whether or not it worked.
    /// Kept in memory: it only ever has to outlive the next few ticks, and a
    /// restart deserves one fresh attempt at a panel that kept failing.</summary>
    private readonly Dictionary<Guid, long> _attempts = new();

    public void RecordAttempt(Guid id) =>
        _attempts[id] = DateTimeOffset.UtcNow.ToUnixTimeSeconds();

    public long? LastAttempt(Guid id) => _attempts.TryGetValue(id, out var at) ? at : null;

    /// <summary>The interval the panel asked for, in seconds — the number the
    /// unattended round clamps against.</summary>
    public double? UpdateInterval(Guid id) => this[id]?.UpdateIntervalSeconds;

    private void Load()
    {
        _infos.Clear();
        JsonNode? root;
        try
        {
            root = JsonNode.Parse(File.ReadAllText(FilePath));
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            return; // absent or unreadable is "nothing remembered", never a crash
        }
        if (root is not JsonObject obj) return;
        foreach (var (key, value) in obj)
        {
            if (!Guid.TryParse(key, out var id) || value is not JsonObject entry) continue;
            var info = FromJson(entry);
            if (info is not null) _infos[id] = info;
        }
    }

    private void Save()
    {
        var obj = new JsonObject();
        foreach (var (id, info) in _infos)
        {
            var entry = new JsonObject
            {
                ["title"] = info.Title,
                ["uploaded"] = info.Uploaded,
                ["downloaded"] = info.Downloaded,
                ["total"] = info.Total,
                ["expires"] = info.ExpiresEpochSeconds,
                // A non-finite interval would serialize as `null` and come back
                // as "the panel never asked" — drop it here instead, the same way
                // the Android cache does.
                ["updateInterval"] = info.UpdateIntervalSeconds is { } age && double.IsFinite(age)
                    ? age
                    : null,
                ["supportUrl"] = info.SupportUrl,
                ["webPageUrl"] = info.WebPageUrl,
                ["announcement"] = info.Announcement,
            };
            obj[id.ToString("D", CultureInfo.InvariantCulture)] = entry;
        }
        var directory = Path.GetDirectoryName(FilePath);
        if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
        // Same write-then-rename discipline as state.json.
        var tmp = FilePath + ".tmp";
        File.WriteAllText(tmp, obj.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        if (File.Exists(FilePath)) File.Replace(tmp, FilePath, null);
        else File.Move(tmp, FilePath);
    }

    private static SubscriptionInfo? FromJson(JsonObject entry)
    {
        var info = new SubscriptionInfo();
        string? Text(string key) => entry[key] is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;
        long? Whole(string key) => entry[key] is JsonValue v && v.TryGetValue<long>(out var n) ? n : null;
        double? Real(string key) => entry[key] is JsonValue v && v.TryGetValue<double>(out var d) && double.IsFinite(d) ? d : null;

        info.Title = Text("title");
        info.Uploaded = Whole("uploaded");
        info.Downloaded = Whole("downloaded");
        info.Total = Whole("total");
        info.ExpiresEpochSeconds = Whole("expires");
        info.UpdateIntervalSeconds = Real("updateInterval") ?? Whole("updateInterval");
        info.SupportUrl = Text("supportUrl");
        info.WebPageUrl = Text("webPageUrl");
        info.Announcement = Text("announcement");
        return info.Equals(new SubscriptionInfo()) ? null : info;
    }
}
