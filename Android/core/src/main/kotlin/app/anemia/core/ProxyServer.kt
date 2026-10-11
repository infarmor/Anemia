package app.anemia.core

/**
 * The canonical server model, port of `ProxyServer` and its enums in
 * `Sources/LoaderCore/Models.swift`. Field names follow the Swift ones so a
 * golden dump of one platform can be read against the other.
 */

enum class ProxyProtocol(val raw: String) {
    VLESS("vless"), VMESS("vmess"), SHADOWSOCKS("ss"), TROJAN("trojan"),
    AMNEZIA("awg"), WIREGUARD("wg"), HYSTERIA("hysteria"), HYSTERIA2("hysteria2");

    val isWireGuardFamily: Boolean get() = this == AMNEZIA || this == WIREGUARD
    val isHysteriaFamily: Boolean get() = this == HYSTERIA || this == HYSTERIA2

    /** The protocol name the engine's outbound wants; hysteria dials its own engine. */
    val xrayProtocolName: String get() = when (this) {
        SHADOWSOCKS -> "shadowsocks"
        HYSTERIA, HYSTERIA2 -> "socks"
        else -> raw
    }
}

enum class NetworkType(val raw: String) {
    TCP("tcp"), WS("ws"), GRPC("grpc"), HTTP("http"), HTTPUPGRADE("httpupgrade"),
    QUIC("quic"),
    // The engine name, not the link alias: Swift stores "mkcp" here, and this
    // is the value that reaches streamSettings.network.
    KCP("mkcp"), XHTTP("xhttp");
}

enum class StreamSecurity(val raw: String) {
    NONE("none"), TLS("tls"), REALITY("reality"), XTLS("xtls");
}

/** Mirrors `ParseError`; `describe()` matches how Swift prints the case. */
class ProxyParseException(val kind: String, val detail: String? = null) : Exception(
    if (detail == null) kind else "$kind(\"$detail\")"
) {
    fun describe(): String = message ?: kind
}

/**
 * Как ошибка разбора читается в интерфейсе: ровно так, как Swift печатает
 * `("\(error)")` — `kind("detail")` для случая `ParseError` и, поскольку
 * `ParseError.awgConfig` — это `.malformedURI("AmneziaWG config: …")`,
 * обёртка и для исключения конфига.
 */
fun parseErrorText(error: Throwable): String = when (error) {
    is ProxyParseException -> error.describe()
    is AwgConfigException -> "malformedURI(\"${error.message}\")"
    else -> error.message ?: error.toString()
}

data class ProxyServer(
    /** Its own across refreshes: `carryingIDs` hands the old one to a new copy. */
    val id: java.util.UUID = java.util.UUID.randomUUID(),
    val name: String,
    val proto: ProxyProtocol,
    val address: String,
    val port: Int,
    val credential: String,
    val method: String? = null,
    val alterId: Int = 0,
    val vmessCipher: String? = null,
    val network: NetworkType = NetworkType.TCP,
    val security: StreamSecurity = StreamSecurity.NONE,
    val sni: String? = null,
    val alpn: List<String> = emptyList(),
    val fingerprint: String? = null,
    val allowInsecure: Boolean = false,
    val realityPublicKey: String? = null,
    val realityShortId: String? = null,
    val realitySpiderX: String? = null,
    val flow: String? = null,
    val path: String? = null,
    val host: String? = null,
    val headerType: String? = null,
    val grpcMultiMode: Boolean? = null,
    val xhttpMode: String? = null,
    val xhttpExtra: String? = null,
    val vlessEncryption: String? = null,
    /** AmneziaWG obfuscation set; nil for every other protocol. */
    val awg: AwgObfuscation? = null,
    /** Peer key, routes and DNS of a WireGuard-family server. */
    val wgProfile: WireGuardProfile? = null,
    /** Nil and «no extras» are different JSON: Swift writes the key only when it has a value. */
    val userData: Map<String, String>? = null,
) {
    /**
     * What makes two entries "the same server" — the same six fields Swift
     * joins with `|`. It keys learned masking, the stealth-SNI pick (which must
     * not move between reconnects) and duplicate detection.
     */
    val identityKey: String
        get() = listOf(
            proto.raw, address, port.toString(), credential, method ?: "", flow ?: "",
        ).joinToString("|")
}

