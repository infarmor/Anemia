using System.Text.Json;
using System.Text.Json.Serialization;

namespace AnemiaCore;

/// <summary>
/// Wire names for the enums that travel inside share links and the Xray
/// config. Swift's rawValues are the contract; C# keeps the same spellings
/// with explicit maps instead of relying on enum-name formatting.
/// </summary>
public static class Wire
{
    public static string Name(ProxyProtocol p) => p switch
    {
        ProxyProtocol.Ss => "ss",
        ProxyProtocol.Vless => "vless",
        ProxyProtocol.Vmess => "vmess",
        ProxyProtocol.Trojan => "trojan",
        ProxyProtocol.Amnezia => "awg",
        ProxyProtocol.WireGuard => "wg",
        ProxyProtocol.Hysteria => "hysteria",
        ProxyProtocol.Hysteria2 => "hysteria2",
        _ => p.ToString().ToLowerInvariant(),
    };

    public static string Name(NetworkType n) => n switch
    {
        NetworkType.Tcp => "tcp",
        NetworkType.Ws => "ws",
        NetworkType.Grpc => "grpc",
        NetworkType.Http => "http",
        NetworkType.HttpUpgrade => "httpupgrade",
        NetworkType.Quic => "quic",
        NetworkType.Kcp => "mkcp",
        NetworkType.Xhttp => "xhttp",
        _ => n.ToString().ToLowerInvariant(),
    };

    public static string Name(StreamSecurity s) => s switch
    {
        StreamSecurity.None => "none",
        StreamSecurity.Tls => "tls",
        StreamSecurity.Reality => "reality",
        StreamSecurity.Xtls => "xtls",
        _ => s.ToString().ToLowerInvariant(),
    };

    public static ProxyProtocol? ParseProtocol(string s) => s.ToLowerInvariant() switch
    {
        "vless" => ProxyProtocol.Vless,
        "vmess" => ProxyProtocol.Vmess,
        "ss" => ProxyProtocol.Ss,
        "trojan" => ProxyProtocol.Trojan,
        "awg" => ProxyProtocol.Amnezia,
        "wg" => ProxyProtocol.WireGuard,
        "hysteria" => ProxyProtocol.Hysteria,
        "hysteria2" => ProxyProtocol.Hysteria2,
        _ => null,
    };

    public static NetworkType? ParseNetwork(string s) => s.ToLowerInvariant() switch
    {
        "tcp" => NetworkType.Tcp,
        "ws" => NetworkType.Ws,
        "grpc" => NetworkType.Grpc,
        "http" => NetworkType.Http,
        "httpupgrade" => NetworkType.HttpUpgrade,
        "quic" => NetworkType.Quic,
        "mkcp" => NetworkType.Kcp,
        "xhttp" or "splithttp" => NetworkType.Xhttp,
        _ => null,
    };

    public static StreamSecurity? ParseSecurity(string s) => s.ToLowerInvariant() switch
    {
        "none" => StreamSecurity.None,
        "tls" => StreamSecurity.Tls,
        "reality" => StreamSecurity.Reality,
        "xtls" => StreamSecurity.Xtls,
        _ => null,
    };
}

/// <summary>Serializes the wire enums as their lowercase share-link names.</summary>
public sealed class WireEnumConverterFactory : JsonConverterFactory
{
    public override bool CanConvert(Type typeToConvert) =>
        typeToConvert == typeof(NetworkType) || typeToConvert == typeof(StreamSecurity);

    public override JsonConverter? CreateConverter(Type typeToConvert, JsonSerializerOptions options)
    {
        var generic = typeof(WireEnumConverter<>).MakeGenericType(typeToConvert);
        return (JsonConverter?)Activator.CreateInstance(generic);
    }
}

public sealed class WireEnumConverter<T> : JsonConverter<T> where T : struct, Enum
{
    private static string NameOf(T value) =>
        value switch
        {
            NetworkType n => Wire.Name(n),
            StreamSecurity s => Wire.Name(s),
            _ => value.ToString()!,
        };

    private static T? ParseOf(string s)
    {
        if (typeof(T) == typeof(NetworkType)) return (T?)(object?)Wire.ParseNetwork(s);
        if (typeof(T) == typeof(StreamSecurity)) return (T?)(object?)Wire.ParseSecurity(s);
        return null;
    }

    public override T Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        var s = reader.GetString() ?? "";
        return ParseOf(s) ?? throw new JsonException($"unknown wire value '{s}' for {typeof(T).Name}");
    }

    public override void Write(Utf8JsonWriter writer, T value, JsonSerializerOptions options) =>
        writer.WriteStringValue(NameOf(value));
}