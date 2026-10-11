package app.anemia.core

/**
 * The portable half of `Sources/LoaderCore/LatencyProbe.swift`: what one probe
 * attempt dials, and how a round of attempts accumulates. Timing a real
 * handshake is the app's job (a `SSLSocket` on Android, `NWConnection` on
 * Apple) — these two rules are the part that must read the same on both
 * platforms, because they decide whether a server counts as alive at all.
 */
object Probing {

    /**
     * A TLS handshake carries the server name — but SNI is defined as a DNS
     * name, and several servers fail a handshake that presents an IP literal, so
     * a literal (or a `sni` that is one) sends no name at all. A colon means
     * IPv6, which is never a valid SNI either.
     */
    data class Target(val usable: Boolean, val port: Int, val serverName: String?, val tls: Boolean)

    fun target(host: String, port: Int, sni: String?, tls: Boolean): Target {
        if (host.isEmpty() || port <= 0 || port > 65_535) return Target(false, port, null, tls)
        val name = sni ?: host
        val send = name.isNotEmpty() && !Addresses.isIPv4(name) && !name.contains(':')
        return Target(true, port, if (send) name else null, tls)
    }

    /**
     * One round of `count` attempts over results the caller measured. A dead
     * server costs `count × timeout` otherwise, so `earlyAbortAfterFails` stops
     * the round after that many failures in a row — and a single success resets
     * the streak, so a slow-but-alive server is never given up on.
     */
    fun collect(
        count: Int,
        earlyAbortAfterFails: Int?,
        cancelled: () -> Boolean = { false },
        attempt: (Int) -> Int?,
    ): List<Int?> {
        val results = ArrayList<Int?>()
        var consecutiveFails = 0
        for (index in 0 until maxOf(1, count)) {
            if (cancelled()) break
            val r = attempt(index)
            results.add(r)
            if (r == null) {
                consecutiveFails += 1
                val limit = earlyAbortAfterFails
                if (limit != null && consecutiveFails >= limit) break
            } else {
                consecutiveFails = 0
            }
        }
        return results
    }

    /** How many attempts this round will actually make. */
    fun attempts(count: Int): Int = maxOf(1, count)
}
