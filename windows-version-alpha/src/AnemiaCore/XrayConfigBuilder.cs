using System.Text;
using System.Text.Json.Nodes;

namespace AnemiaCore;

/// <summary>A profile the bundled engine (Xray-core 26.x) cannot run.</summary>
public enum ConfigBuilderErrorKind
{
    /// <summary>HTTP/2 (h2) and QUIC stream transports were removed from
    /// Xray-core in the 26.x line; the config would be rejected (or worse,
    /// silently dial plain TCP) at engine start.</summary>
    TransportRemovedByEngine,
    /// <summary>`mode=` on an xhttp link must be one of the four the engine
    /// knows; anything else is a config the engine rejects at start.</summary>
    InvalidXhttpMode,
    /// <summary>`extra=` must be a JSON object — Xray reads it as one, and a
    /// scalar there is not a transport option but a broken link.</summary>
    InvalidXhttpExtra,
    /// <summary>A Reality link without pbk= can never handshake: the engine
    /// has no server public key to authenticate against, so the dial fails
    /// after a confusing delay. Caught at build time with an actionable
    /// message.</summary>
    RealityMissingPublicKey,
    /// <summary>A Shadowsocks server whose cipher is missing or was removed from
    /// the engine. The method is the one field such a server cannot fall back
    /// from: the engine answers `unknown cipher method: …` and dies at start.</summary>
    ShadowsocksMethodMissing,
    ShadowsocksMethodUnsupported,
    /// <summary>A hysteria server with no password: the client would dial and
    /// be refused after a handshake timeout that names nothing.</summary>
    HysteriaMissingAuth,
    /// <summary>The server is neither hysteria generation this builder knows.</summary>
    UnsupportedProtocol,
    /// <summary>Hysteria owns its own process and a local SOCKS bridge; xray
    /// dials that bridge. Building the config without the bridge port means the
    /// engine was started out of order.</summary>
    HysteriaBridgeMissing,
    /// <summary>The server belongs to the WireGuard family: it must be
    /// supervised by the amneziawg-go engine, and reaching this builder means the
    /// caller misrouted it.</summary>
    WireGuardNotOnXray,
    /// <summary>Xray 26.x removed both the `header` and the `seed` of
    /// kcpSettings. Dialing plain mKCP at a server that expects obfuscation
    /// means no answer and no error, so the link is refused by name.</summary>
    MkcpObfuscationUnsupported,
}

public sealed class ConfigBuilderException : Exception
{
    public ConfigBuilderErrorKind Kind { get; }
    public ConfigBuilderException(ConfigBuilderErrorKind kind, string message) : base(message) { Kind = kind; }

    public static ConfigBuilderException InvalidXhttpMode(string mode) =>
        new(ConfigBuilderErrorKind.InvalidXhttpMode,
            $"xhttp mode '{mode}' is not one of auto, packet-up, stream-up, stream-one.");

    public static ConfigBuilderException InvalidXhttpExtra() =>
        new(ConfigBuilderErrorKind.InvalidXhttpExtra,
            "xhttp extra must be a JSON object.");

    public static ConfigBuilderException TransportRemovedByEngine(string name) =>
        new(ConfigBuilderErrorKind.TransportRemovedByEngine,
            $"Transport '{name}' is no longer supported by the bundled Xray-core (removed in 26.x). " +
            "Ask the provider for a ws/grpc/tcp variant of this server.");

    /// <summary>Xray-core's wireguard outbound speaks the plain WireGuard
    /// handshake only — it cannot carry the AmneziaWG junk/padding/header
    /// parameters, so emitting one would silently strip every obfuscation
    /// setting and drop all traffic on an AWG server.</summary>
    /// <summary>Hysteria owns its own process and a local SOCKS bridge; xray
    /// dials that bridge. Building the config without the bridge port means the
    /// engine was started out of order.</summary>
    public static ConfigBuilderException HysteriaBridgeMissing() =>
        new(ConfigBuilderErrorKind.HysteriaBridgeMissing,
            "Hysteria engine is not running — no local bridge port to route through.");

    public static ConfigBuilderException WireGuardNotOnXray(string proto) =>
        new(ConfigBuilderErrorKind.WireGuardNotOnXray,
            $"{proto} servers run on the AmneziaWG engine, not Xray.");

    public static ConfigBuilderException RealityMissingPublicKey() =>
        new(ConfigBuilderErrorKind.RealityMissingPublicKey,
            "This Reality server carries no public key (pbk=) — the handshake cannot authenticate. " +
            "Re-import the share link from the panel so it includes the key.");

    public static ConfigBuilderException ShadowsocksMethodMissing() =>
        new(ConfigBuilderErrorKind.ShadowsocksMethodMissing,
            "This Shadowsocks server has no cipher. Re-import the link; older SIP003 links " +
            "carry it as method:password@host.");

    public static ConfigBuilderException ShadowsocksMethodUnsupported(string method) =>
        new(ConfigBuilderErrorKind.ShadowsocksMethodUnsupported,
            $"The bundled Xray-core does not implement the cipher '{method}'. " +
            "Stream ciphers (aes-256-cfb and friends) were removed; ask the provider for " +
            "an AEAD cipher (aes-256-gcm, chacha20-ietf-poly1305, 2022-blake3-*).");

    public static ConfigBuilderException MkcpObfuscationUnsupported(string detail) =>
        new(ConfigBuilderErrorKind.MkcpObfuscationUnsupported,
            $"mKCP obfuscation ({detail}) was removed from Xray-core 26.x, and dialing plain " +
            "mKCP at a server that expects it fails without an error. Use a ws, grpc or tcp " +
            "variant of this server.");
}

/// <summary>
/// Builds an Xray-core JSON configuration from a <see cref="ProxyServer"/> plus
/// <see cref="AntiCensorshipOptions"/>.
/// The generated config exposes local SOCKS + HTTP inbounds (which the tun
/// tun2socks bridge and system-proxy paths dial into) and a single "proxy"
/// outbound to the selected server. Anti-DPI features are layered on natively:
/// fragment → a freedom outbound used as dialerProxy that shreds the TLS
/// ClientHello so SNI-based DPI can't classify the handshake; noises → junk
/// packets emitted before real data (sockopt.noises); mux → connection
/// multiplexing with padding (skipped under XTLS-Vision, which is faster
/// unmuxed).
/// </summary>
public sealed class XrayConfigBuilder
{
    /// <summary>The ciphers the bundled Xray-core accepts, measured against the
    /// shipped binary with `xray run -c … -test`: everything else fails to start
    /// with `unknown cipher method`, and the engine matches case-insensitively.
    /// Same list as Swift's <c>XrayConfigBuilder.supportedCiphers</c> and the
    /// Kotlin port's.</summary>
    public static readonly IReadOnlySet<string> SupportedCiphers = new HashSet<string>(StringComparer.Ordinal)
    {
        "aes-128-gcm", "aes-256-gcm", "chacha20-poly1305", "chacha20-ietf-poly1305",
        "xchacha20-ietf-poly1305", "none",
        "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305",
    };

    public int SocksPort { get; set; }
    public int HttpPort { get; set; }
    public string Listen { get; set; }
    public string LogLevel { get; set; }
    public bool EnableSniffing { get; set; }
    /// <summary>Local Xray Stats API port (dokodemo-door). Null disables traffic stats.</summary>
    public int? ApiPort { get; set; }
    /// <summary>Remote DNS resolvers, queried through the proxy to avoid DNS leaks.</summary>
    public List<string> RemoteDns { get; set; }
    /// <summary>
    /// Static dns.hosts entries (domain → IP), pinned into the engine's DNS
    /// config. The essential one is the VPN server's own domain: after the app
    /// points the system resolver at the tunnel, any lookup of the server's
    /// domain would travel into the tunnel → engine → DoH through the proxy →
    /// and to reach the proxy the engine must resolve that same domain — a
    /// loop that stalls until every TTL expires. A hosts entry answers it
    /// locally and instantly, engine dials included.
    /// </summary>
    public Dictionary<string, string> DnsHosts { get; set; } = new();
    /// <summary>
    /// Drop QUIC (UDP/443) so browsers fall back to HTTP/2 over TCP — the path
    /// Reality/XTLS-Vision actually secure. QUIC over a proxy is frequently
    /// throttled or reset by DPI and, being UDP, benefits from none of the TCP
    /// obfuscation; forcing TCP is a standard reliability win.
    /// </summary>
    public bool BlockQuic { get; set; }
    /// <summary>
    /// Answer tunneled DNS (any :53, UDP or TCP) inside the engine via the
    /// built-in `dns` outbound, resolving with RemoteDns (DoH through the
    /// proxy). The helper points the system resolver at the tunnel's gateway
    /// address, so system lookups enter the tun → tun2socks → SOCKS UDP →
    /// engine: poisoned answers from the ISP resolver become impossible while
    /// the tunnel is up.
    /// </summary>
    public bool HijackDns { get; set; }
    /// <summary>Per-connection copy-buffer (KB) in the engine's connection
    /// policy. 0 lets the core auto-size it.</summary>
    public int BufferSizeKb { get; set; }
    /// <summary>
    /// Physical interface the engine's server connection is pinned to via
    /// sockopt.interface. On Windows this is the interface's alias/luid-derived
    /// name; null disables the pin. Without this pin, whenever a TUN holds the
    /// default route (our own tunnel during a reconnect race, or a third-party
    /// VPN), the engine's dial is swallowed by that TUN.
    /// </summary>
    public string? DialerInterface { get; set; }

    public XrayConfigBuilder(
        int socksPort = 10808,
        int httpPort = 10809,
        string listen = "127.0.0.1",
        string logLevel = "warning",
        bool enableSniffing = true,
        int? apiPort = 10812,
        List<string>? remoteDns = null,
        string? dialerInterface = null,
        bool blockQuic = true,
        bool hijackDns = true,
        int bufferSizeKb = 512)
    {
        SocksPort = socksPort;
        HttpPort = httpPort;
        Listen = listen;
        LogLevel = logLevel;
        EnableSniffing = enableSniffing;
        ApiPort = apiPort;
        RemoteDns = remoteDns ?? new List<string>
            { "https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query", "1.1.1.1" };
        DialerInterface = dialerInterface;
        BlockQuic = blockQuic;
        HijackDns = hijackDns;
        BufferSizeKb = bufferSizeKb;
    }

    /// <summary>Build the full config as a JSON node (insertion-ordered).</summary>
    public JsonObject MakeConfig(ProxyServer server, AntiCensorshipOptions? anti = null)
    {
        anti ??= AntiCensorshipOptions.Recommended;
        var outbounds = new JsonArray();

        // --- Fragment dialer (optional) ---------------------------------
        // When fragmentation is on, the physical socket is opened by this
        // freedom outbound, so junk-noise + TFO sockopts live here.
        bool useFragment = anti.Fragment is not null;
        if (anti.Fragment is { } frag)
        {
            var fragmentOutbound = new JsonObject
            {
                ["tag"] = "fragment",
                ["protocol"] = "freedom",
                ["settings"] = new JsonObject
                {
                    ["domainStrategy"] = "AsIs",
                    ["fragment"] = new JsonObject
                    {
                        ["packets"] = frag.Packets,
                        ["length"] = frag.Length,
                        ["interval"] = frag.Interval,
                    },
                },
            };
            var sockopt = MakeSockopt(anti, dialerProxy: null);
            if (sockopt is not null)
                fragmentOutbound["streamSettings"] = new JsonObject { ["sockopt"] = sockopt };
            outbounds.Add(fragmentOutbound);
        }

        // --- Main proxy outbound ---------------------------------------
        outbounds.Insert(0, MakeProxyOutbound(server, anti, useFragment));

        // --- Direct + block --------------------------------------------
        outbounds.Add(new JsonObject
        {
            ["tag"] = "direct", ["protocol"] = "freedom",
            ["settings"] = new JsonObject { ["domainStrategy"] = "UseIP" },
        });
        outbounds.Add(new JsonObject
        {
            ["tag"] = "block", ["protocol"] = "blackhole", ["settings"] = new JsonObject(),
        });
        // Built-in DNS outbound: answers hijacked :53 traffic with the
        // configured (proxied DoH) resolvers.
        if (HijackDns)
            outbounds.Add(new JsonObject { ["tag"] = "dns-out", ["protocol"] = "dns", ["settings"] = new JsonObject() });

        // --- Inbounds ---------------------------------------------------
        var socksIn = new JsonObject
        {
            ["tag"] = "socks-in",
            ["protocol"] = "socks",
            ["listen"] = Listen,
            ["port"] = SocksPort,
            ["settings"] = new JsonObject { ["udp"] = true, ["auth"] = "noauth" },
        };
        var httpIn = new JsonObject
        {
            ["tag"] = "http-in",
            ["protocol"] = "http",
            ["listen"] = Listen,
            ["port"] = HttpPort,
        };
        if (EnableSniffing)
        {
            var sniff = new JsonObject
            {
                ["enabled"] = true, ["destOverride"] = new JsonArray("http", "tls", "quic"),
                ["routeOnly"] = false,
            };
            socksIn["sniffing"] = (JsonObject)sniff.DeepClone();
            httpIn["sniffing"] = sniff;
        }

        var inbounds = new JsonArray { socksIn, httpIn };
        // Local Stats API inbound (dokodemo-door), used to poll live traffic.
        if (ApiPort is { } apiPort)
        {
            inbounds.Add(new JsonObject
            {
                ["tag"] = "api-in",
                ["protocol"] = "dokodemo-door",
                ["listen"] = "127.0.0.1",
                ["port"] = apiPort,
                ["settings"] = new JsonObject { ["address"] = "127.0.0.1" },
            });
        }

        // --- Routing ----------------------------------------------------
        // Keep LAN / loopback traffic off the proxy using explicit private
        // CIDRs, so no external geoip.dat/geosite.dat assets are required.
        string[] privateCidrs =
        {
            "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
            "172.16.0.0/12", "192.168.0.0/16",
            "::1/128", "fc00::/7", "fe80::/10",
        };
        var rules = new JsonArray();
        if (ApiPort is not null)
        {
            // Dispatch the API inbound to the built-in API handler.
            rules.Add(new JsonObject
            {
                ["type"] = "field", ["inboundTag"] = new JsonArray("api-in"), ["outboundTag"] = "api",
            });
        }
        // Hijack tunneled DNS FIRST: the system resolver (and any app that
        // hardcodes :53) must be answered by the engine through proxied DoH —
        // before the LAN-direct rule can hand those queries to the physical
        // network, where ISP DPI poisons them. Restricted to the tunnel
        // inbounds: an unrestricted `port: 53` would also catch the DNS
        // module's OWN queries to the plain fallback resolver ("1.1.1.1") and
        // route them back into the dns outbound — a query answering itself
        // with a query, forever.
        if (HijackDns)
        {
            rules.Add(new JsonObject
            {
                ["type"] = "field",
                ["inboundTag"] = new JsonArray("socks-in", "http-in"),
                ["port"] = 53,
                ["outboundTag"] = "dns-out",
            });
        }
        // Link-local / LAN-name lookups (mDNS ".local", router ".lan",
        // ".home.arpa", ".internal") must be answered on the physical network:
        // a proxied lookup reaches a resolver that has never heard of those
        // names and the LAN host stays unreachable until the tunnel drops.
        rules.Add(new JsonObject
        {
            ["type"] = "field",
            ["outboundTag"] = "direct",
            ["domain"] = new JsonArray("domain:local", "domain:lan", "domain:home.arpa", "domain:internal"),
        });
        // LAN / loopback next, so local UDP/443 (and everything private) still
        // goes direct even with the QUIC block below.
        rules.Add(new JsonObject
        {
            ["type"] = "field", ["outboundTag"] = "direct",
            ["ip"] = new JsonArray(privateCidrs.Select(s => (JsonNode)s).ToArray()),
        });
        // Multicast + subnet broadcast can't traverse a SOCKS-backed tunnel:
        // handing them to the engine just burns its worker on a dial that can
        // never connect. Block them outright.
        rules.Add(new JsonObject
        {
            ["type"] = "field",
            ["outboundTag"] = "block",
            ["ip"] = new JsonArray("224.0.0.0/4", "255.255.255.255/32", "ff00::/8"),
        });
        // Drop QUIC (UDP/443) → browsers retry over HTTP/2/TCP through the proxy.
        if (BlockQuic)
        {
            rules.Add(new JsonObject
            {
                ["type"] = "field", ["outboundTag"] = "block", ["network"] = "udp", ["port"] = 443,
            });
        }
        var routing = new JsonObject { ["domainStrategy"] = "AsIs", ["rules"] = rules };

        // --- DNS (anti-leak): resolve names remotely through the proxy ---
        // Caching is explicit (default-on) so repeated lookups don't pay a
        // fresh DoH round-trip on every new connection.
        var dns = new JsonObject
        {
            ["servers"] = new JsonArray(RemoteDns.Select(s => (JsonNode)s).ToArray()),
            ["queryStrategy"] = "UseIP",
            ["disableCache"] = false,
        };
        if (DnsHosts.Count > 0)
        {
            var hosts = new JsonObject();
            foreach (var (k, v) in DnsHosts) hosts[k] = v;
            dns["hosts"] = hosts;
        }

        var config = new JsonObject
        {
            ["log"] = new JsonObject { ["loglevel"] = LogLevel },
            ["dns"] = dns,
            ["inbounds"] = inbounds,
            ["outbounds"] = outbounds,
            ["routing"] = routing,
        };

        // --- Connection policy (throughput + resource tuning) -----------
        // level 0 governs every proxied connection: bufferSize for fewer
        // syscalls per byte on bulk transfers, connIdle to reclaim idle
        // connections, handshake to fail a dead upstream fast.
        var policy = new JsonObject
        {
            ["levels"] = new JsonObject
            {
                ["0"] = new JsonObject
                {
                    ["handshake"] = 4, ["connIdle"] = 300, ["bufferSize"] = BufferSizeKb,
                },
            },
        };

        // --- Stats API wiring -------------------------------------------
        if (ApiPort is not null)
        {
            config["api"] = new JsonObject
            {
                ["tag"] = "api", ["services"] = new JsonArray("StatsService"),
            };
            config["stats"] = new JsonObject();
            policy["system"] = new JsonObject
            {
                ["statsInboundUplink"] = true, ["statsInboundDownlink"] = true,
                ["statsOutboundUplink"] = true, ["statsOutboundDownlink"] = true,
            };
        }
        config["policy"] = policy;

        return config;
    }

    /// <summary>Serialize the config to pretty-printed JSON. Validated like every
    /// other entry point: a second, unchecked path is how a config that the
    /// engine refuses ends up being what a tool prints and a test asserts.</summary>
    public string MakeConfigString(ProxyServer server, AntiCensorshipOptions? anti = null)
    {
        Validate(server);
        var config = MakeConfig(server, anti);
        return config.ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = true });
    }

    /// <summary>Validate + serialize. Throws <see cref="ConfigBuilderException"/>
    /// for anything the engine can't run.</summary>
    public byte[] MakeConfigData(ProxyServer server, AntiCensorshipOptions? anti = null)
    {
        Validate(server);
        var config = MakeConfig(server, anti);
        return Encoding.UTF8.GetBytes(config.ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = true }));
    }

    /// <summary>Everything the bundled engine cannot run, refused here with a
    /// message a user can act on instead of a Go line about a server they cannot
    /// inspect.</summary>
    /// <summary>Swift's rule: `extra` counts when it parses as a JSON
    /// <em>object</em> — a scalar or a broken fragment is not an option bag.</summary>
    internal static bool LooksLikeJsonObject(string text)
    {
        try
        {
            return JsonNode.Parse(text) is JsonObject;
        }
        catch (System.Text.Json.JsonException)
        {
            return false;
        }
    }

    private void Validate(ProxyServer server)
    {
        // Fail before serializing anything the engine can't run: 26.x removed
        // the HTTP/2 and QUIC stream transports, and a config carrying them
        // dies at engine start with a cryptic core-side message.
        if (server.Network is NetworkType.Http or NetworkType.Quic)
            throw ConfigBuilderException.TransportRemovedByEngine(Wire.Name(server.Network));
        // A Reality link without the server's public key authenticates against
        // nothing — fail here, with the fix.
        if (server.Security == StreamSecurity.Reality && server.RealityPublicKey is null)
            throw ConfigBuilderException.RealityMissingPublicKey();
        // The xhttp parameters are checked before anything is written, like
        // Reality's key: an unknown mode or a non-object extra is an engine-side
        // rejection the user would only see as a connection that never starts.
        if (server.Network == NetworkType.Xhttp)
        {
            if (server.XhttpMode is { } mode &&
                !new[] { "auto", "packet-up", "stream-up", "stream-one" }.Contains(mode, StringComparer.Ordinal))
                throw ConfigBuilderException.InvalidXhttpMode(mode);
            if (server.XhttpExtra is { } extra && !LooksLikeJsonObject(extra))
                throw ConfigBuilderException.InvalidXhttpExtra();
        }
        if (server.Proto == ProxyProtocol.Ss)
        {
            var method = Foundation.TrimFoundationSpaces(server.Method ?? "");
            if (method.Length == 0) throw ConfigBuilderException.ShadowsocksMethodMissing();
            if (!SupportedCiphers.Contains(method.ToLowerInvariant()))
                throw ConfigBuilderException.ShadowsocksMethodUnsupported(method);
        }
        // The WireGuard family never has an xray outbound: the handshake is the
        // daemon's, and a stripped-down WG outbound would look connected while
        // every packet from an obfuscated server is dropped.
        if (server.IsWireGuardFamily)
            throw ConfigBuilderException.WireGuardNotOnXray(Wire.Name(server.Proto));
        if (server.Network == NetworkType.Kcp)
        {
            var header = Foundation.TrimFoundationSpaces(server.HeaderType ?? "");
            if (header.Length > 0 && !header.Equals("none", StringComparison.OrdinalIgnoreCase))
                throw ConfigBuilderException.MkcpObfuscationUnsupported("header=" + header);
            if (server.UserData?.TryGetValue("kcpSeed", out var seed) == true && seed.Length > 0)
                throw ConfigBuilderException.MkcpObfuscationUnsupported("seed is set");
        }
    }

    // MARK: - Outbound assembly

    /// <summary>
    /// FNV-1a over the UTF-8 bytes — a hash that is stable across launches and
    /// machines (unlike a runtime hash seed). Masked into the positive half so
    /// the modulo pick is always in-bounds.
    /// </summary>
    public static long StableHash(string s)
    {
        ulong h = 0xcbf29ce484222325UL;
        foreach (var b in Encoding.UTF8.GetBytes(s))
        {
            h ^= b;
            h *= 0x100000001b3UL;
        }
        return unchecked((long)(h & 0x7FFFFFFFFFFFFFFFUL));
    }

    private JsonObject MakeProxyOutbound(ProxyServer server, AntiCensorshipOptions anti, bool useFragment)
    {
        // Hysteria speaks QUIC with its own framing — nothing xray can dial. The
        // hysteria engine owns the wire and serves a local SOCKS5 bridge, so this
        // outbound is a plain socks dial into that bridge: no streamSettings
        // (there is no network layer left to configure) and no mux (the bridge is
        // loopback, so multiplexing buys nothing).
        if (server.IsHysteriaFamily)
        {
            if (server.UserData?.GetValueOrDefault("hySocksPort") is not { } bridgeText ||
                SwiftInt.Parse(bridgeText) is not { } bridge || bridge is < 1 or > 65535)
                throw ConfigBuilderException.HysteriaBridgeMissing();
            return new JsonObject
            {
                ["tag"] = "proxy",
                ["protocol"] = "socks",
                ["settings"] = new JsonObject
                {
                    ["servers"] = new JsonArray(new JsonObject
                    {
                        ["address"] = "127.0.0.1", ["port"] = (int)bridge,
                    }),
                },
            };
        }
        var outbound = new JsonObject
        {
            ["tag"] = "proxy",
            ["protocol"] = server.XrayProtocolName,
            ["settings"] = MakeProxySettings(server),
        };

        outbound["streamSettings"] = MakeStreamSettings(server, anti, useFragment);

        // Mux with padding — but not with XTLS-Vision (incompatible + slower).
        bool isVision = (server.Flow ?? "").Contains("vision");
        // … and not on xhttp either: the transport already multiplexes its own
        // requests, and Xray-core refuses the combination.
        if (anti.MuxEnabled && !isVision && server.Network != NetworkType.Xhttp)
        {
            outbound["mux"] = new JsonObject
            {
                ["enabled"] = true,
                ["concurrency"] = anti.MuxConcurrency,
                ["xudpConcurrency"] = 8,
                ["xudpProxyUDP443"] = "reject",
            };
        }
        return outbound;
    }

    private static JsonObject MakeProxySettings(ProxyServer server)
    {
        switch (server.Proto)
        {
            case ProxyProtocol.Vless:
            {
                var user = new JsonObject
                {
                    ["id"] = server.Credential, ["encryption"] = "none", ["level"] = 0,
                };
                if (!string.IsNullOrEmpty(server.Flow)) user["flow"] = server.Flow;
                return new JsonObject
                {
                    ["vnext"] = new JsonArray(new JsonObject
                    {
                        ["address"] = server.Address, ["port"] = server.Port, ["users"] = new JsonArray(user),
                    }),
                };
            }
            case ProxyProtocol.Vmess:
            {
                var user = new JsonObject
                {
                    ["id"] = server.Credential,
                    ["alterId"] = server.AlterId,
                    // Honor the link's scy (v2rayN "security"): a panel set to
                    // `zero` or a fixed AEAD cipher rejects the client's
                    // `auto` pick during negotiation. Null → engine default.
                    ["security"] = server.VmessCipher ?? "auto",
                    ["level"] = 0,
                };
                return new JsonObject
                {
                    ["vnext"] = new JsonArray(new JsonObject
                    {
                        ["address"] = server.Address, ["port"] = server.Port, ["users"] = new JsonArray(user),
                    }),
                };
            }
            case ProxyProtocol.Trojan:
            {
                var srv = new JsonObject
                {
                    ["address"] = server.Address, ["port"] = server.Port,
                    ["password"] = server.Credential, ["level"] = 0,
                };
                if (!string.IsNullOrEmpty(server.Flow)) srv["flow"] = server.Flow;
                return new JsonObject { ["servers"] = new JsonArray(srv) };
            }
            case ProxyProtocol.Ss:
            {
                var srv = new JsonObject
                {
                    ["address"] = server.Address,
                    ["port"] = server.Port,
                    ["method"] = server.Method ?? "aes-256-gcm",
                    ["password"] = server.Credential,
                    ["uot"] = true,
                    ["level"] = 0,
                };
                return new JsonObject { ["servers"] = new JsonArray(srv) };
            }
            default:
                throw new InvalidOperationException($"unhandled protocol {server.Proto}");
        }
    }

    private JsonObject MakeStreamSettings(ProxyServer server, AntiCensorshipOptions anti, bool useFragment)
    {
        var stream = new JsonObject { ["network"] = Wire.Name(server.Network) };

        // Stealth SNI: an explicit link SNI always wins. Otherwise borrow a
        // host from the anti-DPI mimicry pool (TSPU whitelist evasion) — but
        // only where a mismatched serverName is safe, i.e. Reality (camouflage
        // SNI is the whole point). For a TLS server the cert is always
        // name-validated now — Xray-core 26.x removed allowInsecure, so a
        // borrowed SNI would fail validation and break the handshake; leave
        // the name unset and let xray default it to the server address.
        // The pick is stable per server (hashed off its identity, not random)
        // so a reconnect keeps the same camouflage host — a flapping SNI
        // across reconnects is itself a DPI correlation signal.
        string? mimicrySni = anti.Mimicry.Count == 0
            ? null
            : anti.Mimicry[(int)(StableHash(server.IdentityKey) % anti.Mimicry.Count)];
        // RU-service fingerprint aliases collapse onto real uTLS IDs here, so
        // xray never sees a name it doesn't know.
        var effectiveFingerprint = AntiCensorshipOptions.UtlsFingerprint(server.Fingerprint ?? anti.Fingerprint);

        // Security layer.
        switch (server.Security)
        {
            case StreamSecurity.Reality:
            {
                stream["security"] = "reality";
                var reality = new JsonObject { ["show"] = false };
                var sni = server.Sni ?? mimicrySni;
                if (sni is not null) reality["serverName"] = sni;
                reality["fingerprint"] = effectiveFingerprint;
                if (server.RealityPublicKey is { } pbk) reality["publicKey"] = pbk;
                if (server.RealityShortId is { } sid) reality["shortId"] = sid;
                // The link may pin the camouflage ALPN (e.g. h2-only Reality);
                // without it the engine defaults to [h2, http/1.1] and the TLS
                // handshake fails on ALPN mismatch.
                if (server.Alpn.Count > 0) reality["alpn"] = new JsonArray(server.Alpn.Select(a => (JsonNode)a).ToArray());
                // spiderX is the path the Reality client "crawls" on the
                // camouflage site; default to root so a link that omits it
                // still handshakes.
                reality["spiderX"] = server.RealitySpiderX ?? "/";
                stream["realitySettings"] = reality;
                break;
            }
            case StreamSecurity.Tls:
            case StreamSecurity.Xtls:
            {
                stream["security"] = "tls";
                // NOTE: allowInsecure is deliberately NOT emitted — Xray-core
                // 26.x removed the option entirely; `true` is a fatal config
                // error. The flag lives on in ProxyServer purely so links and
                // old saved state still parse.
                var tls = new JsonObject();
                // CDN links routinely carry no sni, only host — the domain
                // fronting the origin. Falling back to the address (an IP) as
                // SNI gets the handshake cut by the CDN; `host` is the
                // serverName the panel meant (same fallback v2rayN applies).
                var sni = server.Sni ?? server.Host;
                if (sni is not null) tls["serverName"] = sni;
                if (server.Alpn.Count > 0) tls["alpn"] = new JsonArray(server.Alpn.Select(a => (JsonNode)a).ToArray());
                tls["fingerprint"] = effectiveFingerprint;
                stream["tlsSettings"] = tls;
                break;
            }
            case StreamSecurity.None:
                stream["security"] = "none";
                break;
        }

        // Transport-specific settings.
        switch (server.Network)
        {
            case NetworkType.Ws:
            {
                var ws = new JsonObject();
                if (server.Path is { } path) ws["path"] = path;
                if (server.Host is { } host) ws["headers"] = new JsonObject { ["Host"] = host };
                stream["wsSettings"] = ws;
                break;
            }
            case NetworkType.HttpUpgrade:
            {
                var hu = new JsonObject();
                if (server.Path is { } path) hu["path"] = path;
                if (server.Host is { } host) hu["host"] = host;
                stream["httpupgradeSettings"] = hu;
                break;
            }
            case NetworkType.Grpc:
            {
                var grpc = new JsonObject();
                if (server.Path is { } name) grpc["serviceName"] = name;
                // :authority from the link (its host param) and the
                // multiplexing mode — dropping either silently broke gRPC
                // servers that actually rely on them.
                if (!string.IsNullOrEmpty(server.Host)) grpc["authority"] = server.Host;
                if (server.GrpcMultiMode == true) grpc["multiMode"] = true;
                stream["grpcSettings"] = grpc;
                break;
            }
            case NetworkType.Http:
            {
                // Unreachable from MakeConfigData (rejected there); kept so
                // MakeConfig stays total for direct dictionary inspection.
                var h2 = new JsonObject();
                if (server.Path is { } path) h2["path"] = path;
                if (server.Host is { } host) h2["host"] = new JsonArray(host);
                stream["httpSettings"] = h2;
                break;
            }
            case NetworkType.Tcp:
            {
                if (server.HeaderType == "http")
                {
                    // Full http-obfuscation request: with `request` absent,
                    // Xray substitutes a bare default and the link's path/Host
                    // are lost — emit them explicitly.
                    stream["tcpSettings"] = new JsonObject
                    {
                        ["header"] = new JsonObject
                        {
                            ["type"] = "http",
                            ["request"] = new JsonObject
                            {
                                ["version"] = "1.1",
                                ["method"] = "GET",
                                ["path"] = new JsonArray(server.Path ?? "/"),
                                ["headers"] = new JsonObject
                                {
                                    ["Host"] = new JsonArray(server.Host ?? server.Address),
                                },
                            },
                        },
                    };
                }
                break;
            }
            case NetworkType.Kcp:
            {
                // mKCP still exists, but 26.x removed both `seed` and `header`
                // obfuscation from kcpSettings — emitting either is a config
                // error. Plain tunable settings only; the defaults are fine.
                stream["kcpSettings"] = new JsonObject();
                break;
            }
            case NetworkType.Xhttp:
            {
                var xhttp = new JsonObject();
                if (server.Path is { } path) xhttp["path"] = path;
                if (server.Host is { } host) xhttp["host"] = host;
                if (server.XhttpMode is { } mode) xhttp["mode"] = mode;
                if (server.XhttpExtra is { } extra && LooksLikeJsonObject(extra))
                    xhttp["extra"] = JsonNode.Parse(extra);
                stream["xhttpSettings"] = xhttp;
                break;
            }
            case NetworkType.Quic:
                break;
        }

        // Socket options: when fragmenting, the fragment outbound owns the
        // physical socket (TFO/noises), and we only chain to it here.
        if (useFragment)
        {
            stream["sockopt"] = new JsonObject { ["dialerProxy"] = "fragment" };
        }
        else
        {
            var sockopt = MakeSockopt(anti, dialerProxy: null);
            if (sockopt is not null) stream["sockopt"] = sockopt;
        }

        return stream;
    }

    private JsonObject? MakeSockopt(AntiCensorshipOptions anti, string? dialerProxy)
    {
        var sockopt = new JsonObject
        {
            // Interactive latency: don't let Nagle coalesce the small,
            // fragmented ClientHello writes we rely on for DPI evasion.
            ["tcpNoDelay"] = true,
            // Keep the NAT mapping warm and notice a silently-dropped tunnel
            // faster (pairs with the app-side health check + auto-reconnect).
            // BOTH are emitted — some platform socket layers swap Idle and
            // Interval, and a lone Idle leaves a zero write on the idle option.
            ["tcpKeepAliveIdle"] = 30,
            ["tcpKeepAliveInterval"] = 10,
        };
        // tcpFastOpen is deliberately NOT emitted: xray's TFO setsockopt fails
        // with EINVAL ("failed to apply socket options > invalid argument",
        // Xray-core#989) — fatal to the dial, repeated every connection
        // attempt. The flag stays in the options struct for persisted-state
        // compatibility only.
        if (!string.IsNullOrEmpty(DialerInterface))
            sockopt["interface"] = DialerInterface;
        if (anti.Noises.Count > 0)
        {
            var noises = new JsonArray();
            foreach (var noise in anti.Noises)
            {
                noises.Add(new JsonObject
                {
                    ["type"] = noise.Type, ["packet"] = noise.Packet, ["delay"] = noise.Delay,
                });
            }
            sockopt["noises"] = noises;
        }
        if (dialerProxy is not null) sockopt["dialerProxy"] = dialerProxy;
        return sockopt;
    }
}