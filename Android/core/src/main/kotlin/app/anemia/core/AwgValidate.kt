package app.anemia.core

/**
 * The checks that catch an AmneziaWG config which *looks* fine and drops
 * packets silently. Port of `validate`/`warnings` in
 * `Sources/LoaderCore/AmneziaWG.swift`; the message text is part of the
 * contract — `Scripts/golden-awg-problems.sh` compares it with what the Swift
 * code prints for the same conf, so a reworded message fails the check rather
 * than drifting away from the other platforms.
 */
object AwgValidate {
    /** A WireGuard key: 44 base64 characters decoding to 32 bytes. */
    fun isValidKey(text: String): Boolean = AmneziaWg.hexKey(text) != null

    /**
     * `"12345"` → that value, `"12345-12399"` → the inclusive range; `0x`
     * prefixes allowed. Values above [max] are rejected — H* ride the wire as
     * 32 bits, the 3.x timers as 16.
     */
    fun parseRange(raw: String, max: Long): LongRange? {
        fun value(text: String): Long? {
            val t = trimFoundationSpaces(text)
            // Грамматика Swift'а: `UInt32(t)` для десятичной формы и
            // `UInt32(t.dropFirst(2), radix: 16)` для hex. Обе принимают
            // ведущий «+» и отвергают «−», цифры только ASCII — «١٢٣» для
            // Foundation не число, а `toLongOrNull` на JVM его прочитал бы.
            // В hex-форме буквы — обычные `a`…`f`: `0x1f` это 31, а не ошибка.
            val hex = t.startsWith("0x")
            val body = if (hex) t.substring(2) else t
            val digits = if (body.startsWith("+")) body.substring(1) else body
            if (digits.isEmpty()) return null
            val wellFormed = if (hex) {
                digits.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }
            } else {
                digits.all { it in '0'..'9' }
            }
            if (!wellFormed) return null
            return digits.toLongOrNull(if (hex) 16 else 10)?.takeIf { it <= max }
        }
        val dash = raw.indexOf('-')
        if (dash >= 0) {
            val low = value(raw.substring(0, dash)) ?: return null
            val high = value(raw.substring(dash + 1)) ?: return null
            return if (low <= high) low..high else null
        }
        val single = value(raw) ?: return null
        return single..single
    }

    fun parseHeaderRange(raw: String): LongRange? = parseRange(raw, UInt32_MAX)

    /**
     * Проверка сервера целиком, как в Swift: профиля нет — это не «нечего
     * проверять», а первая же проблема, и текст её должен дойти до интерфейса
     * тем же, что на iOS.
     */
    fun validate(server: ProxyServer, mtu: Int = 1420): List<String> {
        val wg = WgServer.of(server) ?: return listOf("missing peer profile (server public key)")
        return validate(wg, mtu)
    }

    /** Problems that would make the config fail without a single error line. */
    fun validate(server: WgServer, mtu: Int = 1420): List<String> {
        val profile = server.profile
        val problems = mutableListOf<String>()
        if (!isValidKey(profile.peerPublicKey)) {
            problems.add("peer public key is not a 32-byte base64 key")
        }
        if (!isValidKey(server.privateKey)) {
            problems.add("private key is not a 32-byte base64 key")
        }
        profile.presharedKey?.let {
            if (!isValidKey(it)) problems.add("preshared key is not a 32-byte base64 key")
        }
        if (profile.allowedIPs.isEmpty()) {
            problems.add("AllowedIPs is empty — nothing would route into the tunnel")
        }
        profile.mtu?.let {
            if (it <= 0 || it > 65535) {
                // The tunnel settings take this as the interface MTU: 0 is not
                // "auto", it is an interface that carries nothing.
                problems.add("MTU ($it) is not usable — leave it unset or pick 576…1500")
            }
        }
        profile.keepAlive?.let {
            if (it < 0 || it > 65535) {
                problems.add("PersistentKeepalive ($it) is outside the 0…65535 the daemon parses")
            }
        }
        problems.addAll(validateObfuscation(server.obfuscation, profile.mtu ?: mtu))
        return problems
    }

    private fun validateObfuscation(o: AwgObfuscation?, mtu: Int): List<String> {
        if (o == null) return emptyList()
        val problems = mutableListOf<String>()
        // What the daemon accepts: jc/jmin/jmax parse with ParseUint(…, 32) and
        // S1…S4 with ParseUint(…, 16) (device/uapi.go of the pinned
        // amneziawg-go). Negative or oversized values fail the whole IpcSet —
        // the import looked fine and the tunnel died with an opaque UAPI error.
        for ((name, value) in listOf("Jc" to o.junkPackets, "Jmin" to o.junkMin, "Jmax" to o.junkMax)) {
            if (value != null && (value < 0 || value > 4_294_967_295)) {
                problems.add("$name ($value) is outside the 0…4294967295 the daemon parses")
            }
        }
        for ((name, value) in listOf("S1" to o.initPadding, "S2" to o.responsePadding,
                                     "S3" to o.cookiePadding, "S4" to o.transportPadding)) {
            if (value != null && (value < 0 || value > 65_535)) {
                problems.add("$name ($value) is outside the 0…65535 the daemon parses")
            }
        }
        // A junk packet at or above the MTU gets IP-fragmented — a DPI
        // signature no legit flow produces.
        o.junkMax?.let {
            if (it >= mtu) {
                problems.add("Jmax ($it) ≥ MTU ($mtu) — junk packets will be fragmented; set Jmax below $mtu")
            }
        }
        val jmin = o.junkMin
        val jmax = o.junkMax
        if (jmin != null && jmax != null && jmin > jmax) {
            problems.add("Jmin ($jmin) > Jmax ($jmax)")
        }
        // Documented AmneziaWG trap: this coincidence makes the 148-byte
        // initiation and the 92-byte response the same wire size again.
        val s1 = o.initPadding
        val s2 = o.responsePadding
        if (s1 != null && s2 != null && s1 + 56 == s2) {
            problems.add("S1 + 56 = S2 ($s1 + 56 = $s2) — initiation and response packets become indistinguishable by size; change one")
        }
        // S4 rides the wire as a u8 padding length; above 255 the daemon
        // rejects the whole config with an obscure UAPI error.
        o.transportPadding?.let {
            if (it > 255) problems.add("S4 ($it) is above the 255-byte transport-padding limit")
        }
        o.headerProtectionKey?.let { key ->
            if (AmneziaWg.hexKey(key) == null) {
                problems.add("HeaderProtectionKey is not a 32-byte key (base64 or hex)")
            }
            // amneziawg-go: header protection needs every padding S1–S4 ≥ 12.
            val paddings = listOf("S1" to o.initPadding, "S2" to o.responsePadding,
                                  "S3" to o.cookiePadding, "S4" to o.transportPadding)
            val short = paddings.filter { (_, value) -> (value ?: 0) < 12 }
                .joinToString(", ") { (name, value) -> "$name = ${value ?: "unset"}" }
            if (short.isNotEmpty()) {
                problems.add("header protection needs S1–S4 ≥ 12 ($short)")
            }
        }
        // 3.x ranges ride the wire as 16-bit values.
        val shortRanges = listOf(
            "ContentPaddingAddition" to o.contentPaddingAddition,
            "RekeyAfterTime" to o.rekeyAfterTime,
            "RekeyTimeout" to o.rekeyTimeout,
            "RejectAfterTime" to o.rejectAfterTime,
            "KeepaliveTimeout" to o.keepaliveTimeout,
            "MaxHandshakeAttempts" to o.maxHandshakeAttempts,
        )
        for ((name, raw) in shortRanges) {
            if (raw != null && parseRange(raw, UInt16_MAX) == null) {
                problems.add("$name = $raw is not a number or range up to 65535")
            }
        }
        // Overlapping header ranges make packets unclassifiable — the engine
        // drops them silently, with no log line.
        val headers = listOf("H1" to o.header1, "H2" to o.header2,
                             "H3" to o.header3, "H4" to o.header4)
        val seen = mutableListOf<Pair<String, LongRange>>()
        for ((name, raw) in headers) {
            // An unset header keeps WireGuard's default type value — legal.
            if (raw == null) continue
            val range = parseHeaderRange(raw)
            if (range == null) {
                problems.add("$name = $raw is not a number or range")
                continue
            }
            for ((otherName, other) in seen) {
                if (other.first <= range.last && range.first <= other.last) {
                    problems.add("$name range $raw overlaps $otherName range — packets would be dropped as unclassifiable")
                }
            }
            seen.add(name to range)
        }
        return problems
    }

    /**
     * Legal configs that misbehave — reported rather than refused, since the
     * server side isn't the user's to change.
     */
    fun warnings(server: WgServer): List<String> {
        val o = server.obfuscation ?: return emptyList()
        if (o.randomTrailers != true) return emptyList()
        // amneziawg-go#186: with RandomTrailers on, a transport packet whose
        // random prefix lands inside an H1–H3 range is classified as a
        // handshake and dropped — loss ≈ 1 − ∏(1 − width/2³²).
        var keep = 1.0
        for (raw in listOf(o.header1, o.header2, o.header3)) {
            val range = raw?.let { parseHeaderRange(it) } ?: continue
            keep *= 1 - (range.last - range.first + 1).toDouble() / 4_294_967_296.0
        }
        val loss = 1 - keep
        if (loss <= 0.001) return emptyList()
        // Locale.ROOT: the percentage has to read "0.5" on a Russian JVM too,
        // the same way the Swift side formats it.
        return listOf(String.format(
            java.util.Locale.ROOT,
            "RandomTrailers with wide H1–H3 ranges drops ~%.1f%% of packets " +
                "(amneziawg-go #186) — the server should narrow those ranges",
            loss * 100,
        ))
    }

    private const val UInt16_MAX = 65535L
    private const val UInt32_MAX = 4294967295L
}
