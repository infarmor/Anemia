package app.anemia.core

/**
 * Port of `Sources/LoaderCore/LeakCheck.swift`: what the leak screens read back
 * from the three services they ask, and the verdict about it. The network calls
 * themselves are app business — this is the parsing and the judging, which have
 * to agree with the Mac and the iPhone answer for the same bytes.
 */
object LeakCheck {

    class LeakException(message: String) : Exception(message)

    data class IPInfo(
        val ip: String,
        val countryCode: String? = null,
        val country: String? = null,
        val city: String? = null,
        val isp: String? = null,
    )

    data class DNSServer(
        val ip: String,
        val countryCode: String? = null,
        val country: String? = null,
        val org: String? = null,
    )

    sealed class Finding {
        /** The internet sees the provider's address: traffic isn't in the tunnel. */
        data object TunnelBypassed : Finding()

        /** IPv6 goes out from the home country. */
        data class Ipv6Leak(val info: IPInfo) : Finding()

        /** These resolvers sit in the home country. */
        data class DnsLeak(val servers: List<DNSServer>) : Finding()
    }

    // MARK: - Parsing

    /** ip.sb's geoip answer; `asn_organization` stands in for a missing `isp`. */
    fun parseIPSB(json: String): IPInfo = try {
        val raw = objectOf(json, "ip.sb: unexpected answer")
        val ip = stringField(raw, "ip") ?: throw LeakException("пустой адрес")
        if (ip.isEmpty()) throw LeakException("пустой адрес")
        IPInfo(
            ip = ip,
            countryCode = stringField(raw, "country_code")?.uppercase(),
            country = stringField(raw, "country"),
            city = stringField(raw, "city"),
            isp = stringField(raw, "isp") ?: stringField(raw, "asn_organization"),
        )
    } catch (error: Exception) {
        // Whatever went wrong, the user reads one thing — and so does Swift,
        // whose `try?` swallows the field-level failure the same way.
        throw LeakException("ip.sb: unexpected answer")
    }

    /** Cloudflare's `cdn-cgi/trace`: `key=value` lines, no JSON. */
    fun parseTrace(text: String): IPInfo {
        val fields = LinkedHashMap<String, String>()
        for (line in splitOnNewlines(text)) {
            val cut = line.indexOf('=')
            if (cut <= 0) continue
            val key = line.substring(0, cut)
            val value = line.substring(cut + 1)
            // Swift's `split(separator: "=", maxSplits: 1)` drops the empty half,
            // so a bare `loc=` never becomes an empty country code.
            if (key.isNotEmpty() && value.isNotEmpty()) fields[key] = value
        }
        val ip = fields["ip"]
        if (ip.isNullOrEmpty()) throw LeakException("Cloudflare: unexpected answer")
        return IPInfo(ip = ip, countryCode = fields["loc"]?.uppercase())
    }

    /** bash.ws's dnsleak report: only `type: dns`, one entry per address. */
    fun parseBashWS(json: String): List<DNSServer> {
        val items = runCatching { Json.parse(json) as? List<*> }.getOrNull()
            ?: throw LeakException("bash.ws: unexpected answer")
        val seen = HashSet<String>()
        return items.mapNotNull { item ->
            val entry = item as? Map<*, *> ?: throw LeakException("bash.ws: unexpected answer")
            // `ip` and `type` are required, so one entry without them fails the
            // whole array — the same verdict Swift's decoder gives.
            val ip = entry["ip"] as? String ?: throw LeakException("bash.ws: unexpected answer")
            val type = entry["type"] as? String ?: throw LeakException("bash.ws: unexpected answer")
            if (type != "dns" || !seen.add(ip)) return@mapNotNull null
            DNSServer(
                ip = ip,
                countryCode = (entry["country"] as? String)?.uppercase(),
                country = entry["country_name"] as? String,
                org = entry["org"] as? String ?: entry["asn"] as? String,
            )
        }
    }

    // MARK: - Judging

    /**
     * What's wrong, comparing the exit the tunnel shows with the provider's own
     * address. Empty: nothing leaks — or there is no direct address to compare
     * with, which is the same answer as far as the user is concerned.
     */
    fun findings(exit: IPInfo?, direct: IPInfo?, ipv6: IPInfo?, dns: List<DNSServer>): List<Finding> {
        direct ?: return emptyList()
        val findings = ArrayList<Finding>()
        if (exit != null && exit.ip == direct.ip) findings.add(Finding.TunnelBypassed)
        val home = direct.countryCode?.uppercase()
        val away = exit?.countryCode?.uppercase()
        // A home-country exit hides nothing by country: say only what's certain.
        if (home == null || home == away) return findings
        ipv6?.let { if (it.countryCode?.uppercase() == home) findings.add(Finding.Ipv6Leak(it)) }
        val local = dns.filter { it.countryCode?.uppercase() == home }
        if (local.isNotEmpty()) findings.add(Finding.DnsLeak(local))
        return findings
    }

    private fun objectOf(json: String, message: String): Map<*, *> =
        runCatching { Json.parse(json) as? Map<*, *> }.getOrNull() ?: throw LeakException(message)

    private fun stringField(map: Map<*, *>, key: String): String? {
        val value = map[key] ?: return null
        // Swift's `String` field rejects a JSON number rather than reading "42".
        return value as? String ?: throw LeakException("не строковое поле «$key»")
    }
}

/**
 * Swift splits on `Character.isNewline`, where a CRLF is one grapheme cluster:
 * the pair is one separator here too, so a report with Windows line endings
 * yields the same lines on both platforms.
 */
fun splitOnNewlines(text: String): List<String> {
    val out = ArrayList<String>()
    var start = 0
    var index = 0
    while (index < text.length) {
        val char = text[index]
        val width = when {
            char == '\r' && index + 1 < text.length && text[index + 1] == '\n' -> 2
            char == '\n' || char == '\r' || char == '\u000B' || char == '\u000C' ||
                char == '\u0085' || char == '\u2028' || char == '\u2029' -> 1
            else -> 0
        }
        if (width == 0) {
            index += 1
            continue
        }
        if (index > start) out.add(text.substring(start, index))
        index += width
        start = index
    }
    if (start < text.length) out.add(text.substring(start))
    return out
}
