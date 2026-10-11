using System.Text.Json.Nodes;

namespace AnemiaCore;

/// <summary>
/// Options that harden the outbound connection against DPI / traffic analysis.
/// These map onto native Xray-core features — no home-grown crypto. The goal:
/// make the traffic unreadable, pad it with junk so a censor's DPI can't
/// classify it, while keeping it fast.
/// </summary>
public sealed class AntiCensorshipOptions
{
    /// <summary>
    /// TLS ClientHello fragmentation. Splits the first packet so SNI-based DPI
    /// can't match the handshake. Implemented via a `freedom` dialer outbound.
    /// </summary>
    public sealed class FragmentOptions
    {
        /// <summary>What to fragment: "tlshello" (just the ClientHello) or "1-3" (packet range).</summary>
        public string Packets { get; set; } = "tlshello";
        /// <summary>Byte length range of each fragment, e.g. "100-200".</summary>
        public string Length { get; set; } = "100-200";
        /// <summary>Delay range between fragments in ms, e.g. "10-20".</summary>
        public string Interval { get; set; } = "10-20";

        public FragmentOptions() { }
        public FragmentOptions(string packets, string length, string interval)
        { Packets = packets; Length = length; Interval = interval; }
    }

    /// <summary>
    /// Junk / noise packets sent before real data to poison DPI classifiers.
    /// Maps to Xray sockopt.noises.
    /// </summary>
    public sealed class NoiseOptions
    {
        /// <summary>"rand" (random bytes), "str" (literal), or "base64".</summary>
        public string Type { get; set; } = "rand";
        /// <summary>Packet size range (rand) or the literal/base64 payload.</summary>
        public string Packet { get; set; } = "50-100";
        /// <summary>Delay range in ms before sending, e.g. "10-16".</summary>
        public string Delay { get; set; } = "10-16";

        public NoiseOptions() { }
        public NoiseOptions(string type, string packet, string delay)
        { Type = type; Packet = packet; Delay = delay; }
    }

    /// <summary>Enable TLS ClientHello fragmentation.</summary>
    public FragmentOptions? Fragment { get; set; }
    /// <summary>One or more junk-noise generators.</summary>
    public List<NoiseOptions> Noises { get; set; } = new();
    /// <summary>Enable connection multiplexing with padding (mux.cool).</summary>
    public bool MuxEnabled { get; set; }
    /// <summary>Multiplexed connections per dial. Swift's `Int` (64-bit) is the
    /// stored width, so a file from another device can hold a number the engine
    /// will refuse — measured 2026-09-30: xray 26.3.27 decodes this field as
    /// int16 and fails the whole config above it. Both ports hand it the same
    /// bytes and the same loud refusal; storing it narrower instead (an earlier
    /// draft of this port did) quietly substituted 8 and connected with nobody's
    /// settings.</summary>
    public long MuxConcurrency { get; set; } = 8;
    /// <summary>
    /// TCP Fast Open — shaves a round trip on connect. Retained for
    /// persisted-state compatibility; never emitted into the config (xray's
    /// TFO setsockopt fails with EINVAL and kills the whole dial,
    /// Xray-core#989 — observed on Darwin; left out everywhere for parity).
    /// </summary>
    public bool TcpFastOpen { get; set; } = true;
    /// <summary>
    /// uTLS fingerprint to mimic (e.g. "chrome", "firefox", "safari",
    /// "randomized", or the Russian-service aliases "yandex"/"vk"). Applied to
    /// Reality/TLS unless the server link overrides it.
    /// </summary>
    public string Fingerprint { get; set; } = "chrome";
    /// <summary>
    /// Stealth-SNI pool: when the server link carries no explicit SNI, the
    /// handshake is presented with a host from this list. Pointing the
    /// ClientHello at a TSPU-whitelisted Russian domain (yandex.ru, vk.com…)
    /// makes the session look like ordinary RU-service traffic.
    /// </summary>
    public List<string> Mimicry { get; set; } = new();

    /// <summary>
    /// Lenient decoding: missing or malformed fields fall back to defaults so
    /// one bad entry costs that field's default — not the whole options struct.
    /// </summary>
    public AntiCensorshipOptions() { }

    public static AntiCensorshipOptions FromJson(JsonNode? node)
    {
        var options = new AntiCensorshipOptions();
        if (node is not JsonObject obj) return options;

        // Swift's own rules, read off `AntiCensorshipOptions.init(from:)`:
        //   fragment = (try? c.decodeIfPresent(Fragment.self, …)) ?? nil
        // so a fragment with one wrong field costs the *whole* fragment — a
        // half-read {"packets":"tlshello","length":200} would otherwise describe
        // a ClientHello split the user never asked for.
        if (obj["fragment"] is JsonObject frag)
        {
            var packets = Strict.Text(frag["packets"]);
            var length = Strict.Text(frag["length"]);
            var interval = Strict.Text(frag["interval"]);
            if (packets is not null && length is not null && interval is not null)
                options.Fragment = new FragmentOptions(packets, length, interval);
        }
        // `noises = (try? [Loose<Noise>])?.compactMap(\.value) ?? []` — each
        // element is decoded on its own, and an element that fails
        // ({"type":5}) is dropped rather than filled with defaults.
        if (obj["noises"] is JsonArray noises)
        {
            foreach (var entry in noises.OfType<JsonObject>())
            {
                var type = Strict.Text(entry["type"]);
                var packet = Strict.Text(entry["packet"]);
                var delay = Strict.Text(entry["delay"]);
                if (type is not null && packet is not null && delay is not null)
                    options.Noises.Add(new NoiseOptions(type, packet, delay));
            }
        }
        options.MuxEnabled = Strict.Bool(obj["muxEnabled"]) ?? false;
        options.MuxConcurrency = Strict.Long(obj["muxConcurrency"]) ?? 8;
        options.TcpFastOpen = Strict.Bool(obj["tcpFastOpen"]) ?? true;
        options.Fingerprint = Strict.Text(obj["fingerprint"]) ?? "chrome";
        // `[Loose<String>]`: a non-string element is dropped, but the field must
        // be an array at all — Swift's `"mimicry": "telegram"` decodes to [].
        if (obj["mimicry"] is JsonArray mimicry)
            foreach (var s in mimicry)
                if (Strict.Text(s) is { } str) options.Mimicry.Add(str);
        return options;
    }

    internal static bool TryBool(JsonValue v, bool fallback)
    {
        if (v.TryGetValue<bool>(out var b)) return b;
        if (v.TryGetValue<string>(out var s) && bool.TryParse(s, out var p)) return p;
        return fallback;
    }

    internal static int TryInt(JsonValue v, int fallback)
    {
        if (v.TryGetValue<int>(out var i)) return i;
        if (v.TryGetValue<string>(out var s) && int.TryParse(s, out var p)) return p;
        return fallback;
    }

    public JsonObject ToJson()
    {
        var obj = new JsonObject();
        if (Fragment is { } frag)
        {
            obj["fragment"] = new JsonObject
            {
                ["packets"] = frag.Packets, ["length"] = frag.Length, ["interval"] = frag.Interval,
            };
        }
        var noises = new JsonArray();
        foreach (var n in Noises)
        {
            noises.Add(new JsonObject { ["type"] = n.Type, ["packet"] = n.Packet, ["delay"] = n.Delay });
        }
        obj["noises"] = noises;
        obj["muxEnabled"] = MuxEnabled;
        obj["muxConcurrency"] = MuxConcurrency;
        obj["tcpFastOpen"] = TcpFastOpen;
        obj["fingerprint"] = Fingerprint;
        var mimicry = new JsonArray();
        foreach (var s in Mimicry) mimicry.Add(s);
        obj["mimicry"] = mimicry;
        return obj;
    }

    /// <summary>RU-service fingerprint aliases → the closest real uTLS
    /// ClientHello. YaBrowser is Chromium-based (→ chrome); the VK client TLS
    /// stack matches OkHttp-on-Android (→ android). Unknown names pass through
    /// lowercased — uTLS only knows the canonical lowercase IDs, so a link
    /// carrying "Chrome" or "iOS" would otherwise be rejected as an unknown
    /// fingerprint and kill the handshake.</summary>
    public static string UtlsFingerprint(string name) => name.ToLowerInvariant() switch
    {
        "yandex" => "chrome",
        "vk" => "android",
        var n => n,
    };

    /// <summary>Balanced default tuned for "unreadable + junk + fast":
    /// fragment the ClientHello, one random junk generator, TFO on, Chrome
    /// fingerprint. Mux stays off because XTLS-Vision is faster without it.</summary>
    public static AntiCensorshipOptions Recommended => Balanced();

    public static AntiCensorshipOptions Balanced() => new()
    {
        Fragment = new FragmentOptions(),
        Noises = { new NoiseOptions() },
        TcpFastOpen = true,
        Fingerprint = "chrome",
    };

    /// <summary>Aggressive masking: smaller/faster ClientHello fragments and
    /// several varied junk generators, with a randomized fingerprint. Costs a
    /// little latency for maximum DPI resistance.</summary>
    public static AntiCensorshipOptions Maximum() => new()
    {
        Fragment = new FragmentOptions("tlshello", "40-80", "5-10"),
        Noises =
        {
            new NoiseOptions("rand", "100-200", "4-8"),
            new NoiseOptions("rand", "40-80", "8-14"),
        },
        TcpFastOpen = true,
        Fingerprint = "randomized",
    };

    /// <summary>No obfuscation — plain fast path (useful when Reality already
    /// hides you).</summary>
    public static AntiCensorshipOptions Off() => new()
    {
        Fragment = null,
        Noises = { },
        MuxEnabled = false,
        TcpFastOpen = true,
        Fingerprint = "chrome",
    };

    /// <summary>Russia-tuned evasion masquerading as Yandex traffic. Fragment
    /// sizes and jitter follow the community (zapret-style) values that survive
    /// TSPU parsing; a literal HTTP junk packet toward www.yandex.ru precedes
    /// the real data, and handshakes without their own SNI borrow a whitelisted
    /// Yandex host.</summary>
    public static AntiCensorshipOptions RussiaYandex() => new()
    {
        Fragment = new FragmentOptions("tlshello", "10-25", "5-12"),
        Noises =
        {
            new NoiseOptions("rand", "30-90", "5-10"),
            new NoiseOptions("str", "GET / HTTP/1.1\r\nHost: www.yandex.ru\r\n\r\n", "10-16"),
        },
        TcpFastOpen = true,
        Fingerprint = "yandex",
        Mimicry = { "www.yandex.ru", "yandex.ru", "ya.ru", "dzen.ru", "sso.yandex.ru" },
    };

    /// <summary>Russia-tuned evasion masquerading as VK traffic — same
    /// mechanics as <see cref="RussiaYandex"/> with VK's domain pool and
    /// fingerprint.</summary>
    public static AntiCensorshipOptions RussiaVK() => new()
    {
        Fragment = new FragmentOptions("tlshello", "15-35", "6-14"),
        Noises =
        {
            new NoiseOptions("rand", "40-120", "5-11"),
            new NoiseOptions("str", "GET / HTTP/1.1\r\nHost: www.vk.com\r\n\r\n", "9-15"),
        },
        TcpFastOpen = true,
        Fingerprint = "vk",
        Mimicry = { "www.vk.com", "vk.com", "m.vk.com", "vkvideo.ru", "vkuser.net" },
    };
}

/// <summary>User-facing masking presets that map onto <see cref="AntiCensorshipOptions"/>.</summary>
public enum MaskingProfile
{
    Off,
    Balanced,
    Maximum,
    RuYandex,
    RuVK,
}

public static class MaskingProfileExtensions
{
    public static AntiCensorshipOptions Options(this MaskingProfile profile) => profile switch
    {
        MaskingProfile.Off => AntiCensorshipOptions.Off(),
        MaskingProfile.Balanced => AntiCensorshipOptions.Balanced(),
        MaskingProfile.Maximum => AntiCensorshipOptions.Maximum(),
        MaskingProfile.RuYandex => AntiCensorshipOptions.RussiaYandex(),
        MaskingProfile.RuVK => AntiCensorshipOptions.RussiaVK(),
        _ => AntiCensorshipOptions.Balanced(),
    };

    public static string Title(this MaskingProfile profile) => profile switch
    {
        MaskingProfile.Off => "Off",
        MaskingProfile.Balanced => "Balanced",
        MaskingProfile.Maximum => "Max",
        MaskingProfile.RuYandex => "RU·Ya",
        MaskingProfile.RuVK => "RU·VK",
        _ => profile.ToString(),
    };

    public static string Subtitle(this MaskingProfile profile) => profile switch
    {
        MaskingProfile.Off => "No obfuscation — fastest",
        MaskingProfile.Balanced => "Fragment + junk — recommended",
        MaskingProfile.Maximum => "Aggressive fragment + more junk",
        MaskingProfile.RuYandex => "Russia: masquerade as Yandex (stealth SNI + junk)",
        MaskingProfile.RuVK => "Russia: masquerade as VK (stealth SNI + junk)",
        _ => "",
    };

    /// <summary>The next stronger profile to try when a server connects but its
    /// traffic is being throttled or reset (likely DPI). Walks lightest →
    /// heaviest and ends at the Russia-tuned whitelist-mimicry profiles; null
    /// at the top.</summary>
    public static MaskingProfile? Escalated(this MaskingProfile profile) => profile switch
    {
        MaskingProfile.Off => MaskingProfile.Balanced,
        MaskingProfile.Balanced => MaskingProfile.Maximum,
        MaskingProfile.Maximum => MaskingProfile.RuYandex,
        MaskingProfile.RuYandex => MaskingProfile.RuVK,
        MaskingProfile.RuVK => null,
        _ => null,
    };
}