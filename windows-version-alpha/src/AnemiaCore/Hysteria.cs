using System.Globalization;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace AnemiaCore;

/// <summary>
/// Builds the client YAML for the standalone <c>hysteria</c> engine. Port of
/// <c>Sources/LoaderCore/HysteriaConfigBuilder.swift</c>.
///
/// Xray-core cannot dial the hysteria protocol (QUIC, its own framing), so a
/// hysteria server runs as its own process next to xray: the hysteria client
/// connects upstream and serves a local SOCKS5 bridge, and the xray config
/// routes everything into that bridge. This is the pure half — config text and
/// validation; the app-side controller owns the process.
/// </summary>
public static class HysteriaConfigBuilder
{
    private static readonly JsonSerializerOptions YamlScalarOptions = new()
    {
        // Swift's JSONEncoder keeps printable non-ASCII (a Cyrillic password
        // stays readable) and escapes the rest; UnsafeRelaxedJsonEscaping is the
        // .NET setting with the same behaviour.
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    /// <summary>Problems that would otherwise fail silently on the wire.</summary>
    public static List<string> Validate(ProxyServer server)
    {
        var problems = new List<string>();
        if (server.Credential.Length == 0) problems.Add("auth/password is empty");
        if (server.Port is < 1 or > 65535)
            problems.Add($"port {server.Port.ToString(CultureInfo.InvariantCulture)} is out of range");
        if (server.Address.Length == 0) problems.Add("server address is empty");
        if (server.UserData?.TryGetValue("portHopping", out var hop) == true &&
            hop.Length > 0 && !IsValidPortSpec(hop))
        {
            problems.Add($"port hopping spec '{hop}' is not a port list like 443,20000-50000");
        }
        if (server.Proto == ProxyProtocol.Hysteria)
        {
            // The v1 YAML below is generated for completeness, but the bundled
            // binary is the v2 engine: it would reject the config, or worse parse
            // it wrongly. Say it at import/connect.
            problems.Add("hysteria protocol v1 requires the legacy hysteria v1 client binary");
        }
        return problems;
    }

    /// <summary>The client YAML. <paramref name="socksPort"/> is the local bridge
    /// port the controller picked — the same port the xray socks outbound must
    /// target.</summary>
    public static string MakeClientConfig(ProxyServer server, int socksPort)
    {
        if (server.Credential.Length == 0)
            throw new ConfigBuilderException(ConfigBuilderErrorKind.HysteriaMissingAuth,
                "Hysteria server carries no auth/password — re-import the link.");

        var host = server.Address.Contains(':') && !server.Address.StartsWith("[", StringComparison.Ordinal)
            ? "[" + server.Address + "]"
            : server.Address;
        var endpoint = host + ":" + PortSpecFor(server);

        var lines = new List<string>();
        switch (server.Proto)
        {
            case ProxyProtocol.Hysteria2:
                lines.Add("server: " + YamlString(endpoint));
                lines.Add("auth: " + YamlString(server.Credential));
                lines.Add("tls:");
                if (!string.IsNullOrEmpty(server.Sni)) lines.Add("  sni: " + YamlString(server.Sni));
                if (server.AllowInsecure) lines.Add("  insecure: true");
                if (server.Alpn.Count > 0) lines.Add("  alpn: " + YamlString(string.Join(",", server.Alpn)));
                // The client's field is `pinSHA256` (checked against the hysteria
                // 2.12 binary). The old `pinnedSHA256` spelling was silently
                // ignored — a link's certificate pin never took effect.
                if (server.UserData?.GetValueOrDefault("pinSHA256") is { Length: > 0 } pin)
                    lines.Add("  pinSHA256: " + YamlString(pin));
                if (server.UserData?.GetValueOrDefault("obfs") is { Length: > 0 } obfs2 &&
                    server.UserData.GetValueOrDefault("obfsPassword") is { Length: > 0 } obfsPass)
                {
                    lines.Add("obfs:");
                    lines.Add("  type: " + YamlString(obfs2));
                    lines.Add("  salamander:");
                    lines.Add("    password: " + YamlString(obfsPass));
                }
                break;
            case ProxyProtocol.Hysteria:
                // v1 shape, kept for tooling and tests; validate refuses to run
                // it against a v2 binary.
                lines.Add("server: " + YamlString(endpoint));
                lines.Add("protocol: " + YamlString(server.UserData?.GetValueOrDefault("protocol") ?? "udp"));
                if (server.UserData?.TryGetValue("upmbps", out var up) == true)
                    lines.Add("up: " + YamlString(up + " Mbps"));
                if (server.UserData?.TryGetValue("downmbps", out var down) == true)
                    lines.Add("down: " + YamlString(down + " Mbps"));
                lines.Add("auth_str: " + YamlString(server.Credential));
                lines.Add("tls:");
                if (!string.IsNullOrEmpty(server.Sni)) lines.Add("  sni: " + YamlString(server.Sni));
                if (server.AllowInsecure) lines.Add("  insecure: true");
                if (server.Alpn.Count > 0) lines.Add("  alpn: " + YamlString(string.Join(",", server.Alpn)));
                if (server.UserData?.GetValueOrDefault("obfs") is { Length: > 0 } obfs1)
                {
                    lines.Add("obfs: " + YamlString(obfs1));
                    if (server.UserData.GetValueOrDefault("obfsPassword") is { Length: > 0 } v1Pass)
                        lines.Add("obfs_param: " + YamlString(v1Pass));
                }
                break;
            default:
                throw new ConfigBuilderException(ConfigBuilderErrorKind.UnsupportedProtocol,
                    $"Hysteria protocol v1 is not supported by the bundled engine path — " +
                    $"use a hysteria2 (hy2://) link. ({Wire.Name(server.Proto)})");
        }
        // The bridge xray routes through. No bandwidth section: without one
        // hysteria2 uses BBR, which outperforms guessed rate limits.
        lines.Add("socks5:");
        lines.Add("  listen: " + YamlString("127.0.0.1:" + socksPort.ToString(CultureInfo.InvariantCulture)));
        return string.Join("\n", lines) + "\n";
    }

    /// <summary>`443`, `20000-50000`, `443,20000-50000` — every port 1…65535,
    /// ranges ascending.</summary>
    public static bool IsValidPortSpec(string spec)
    {
        var items = spec.Split(',');
        if (items.Length == 0) return false;
        return items.All(ValidItem);

        static bool ValidItem(string item)
        {
            var bounds = item.Split('-');
            if (bounds.Length is < 1 or > 2) return false;
            var ports = new List<int>();
            foreach (var bound in bounds)
            {
                if (bound.Length == 0 || bound.Length > 5 || !bound.All(char.IsDigit)) return false;
                if (SwiftInt.Parse(bound) is not { } value || value < 1 || value > 65535) return false;
                ports.Add((int)value);
            }
            return ports.Count == bounds.Length && (ports.Count == 1 || ports[0] <= ports[1]);
        }
    }

    /// <summary>The client's server port field: the link's port, widened by its
    /// port hopping spec — the hysteria client hops across every listed port.</summary>
    public static string PortSpecFor(ProxyServer server)
    {
        if (server.Proto != ProxyProtocol.Hysteria2 ||
            server.UserData?.GetValueOrDefault("portHopping") is not { Length: > 0 } hop ||
            !IsValidPortSpec(hop))
            return server.Port.ToString(CultureInfo.InvariantCulture);
        var covers = hop.Split(',').Any(item =>
        {
            var bounds = item.Split('-')
                .Select(SwiftInt.Parse)
                .Where(value => value is not null)
                .Select(value => (int)value!)
                .ToList();
            return bounds.Count == 1 ? bounds[0] == server.Port
                : bounds.Count == 2 && bounds[0] <= server.Port && server.Port <= bounds[1];
        });
        return covers ? hop : server.Port.ToString(CultureInfo.InvariantCulture) + "," + hop;
    }

    /// <summary>Emit a YAML scalar as a double-quoted string: YAML accepts the
    /// JSON string grammar, so JSON-escaping guarantees a hostile auth password
    /// (quotes, colons, newlines, <c>#</c>) cannot break the document.</summary>
    public static string YamlString(string value) => JsonSerializer.Serialize(value, YamlScalarOptions);
}
