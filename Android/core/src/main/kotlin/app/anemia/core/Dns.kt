package app.anemia.core

/**
 * AdGuard DNS — the "Без рекламы" resolver of both apps. Port of
 * `AdBlockDNS` in `Sources/LoaderCore/AdBlockDNS.swift`.
 */
object AdBlockDns {
    val servers = listOf("94.140.14.14", "94.140.15.15")
    val dohHost = "dns.adguard-dns.com"

    /** For the engine's DNS, through the proxy like the default resolvers. */
    val remoteDNS = listOf("https://$dohHost/dns-query", servers[0])
}
