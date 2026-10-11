package app.anemia.core

/**
 * Port of `Sources/LoaderCore/AntiCensorship.swift`: the DPI-hardening knobs
 * that map onto native Xray-core features (ClientHello fragmentation and junk
 * packets on a `freedom` dialer outbound — `settings.fragment` and
 * `settings.noises`, see `MaskingEmission.kt` — plus mux, uTLS fingerprints and
 * the stealth-SNI pool).
 *
 * The presets carry values that were tuned against real DPI behaviour, not
 * placeholders — `Scripts/golden-xray.sh` compares the config each one produces
 * with the config the Swift code produces from the same server.
 */
data class AntiCensorshipOptions(
    val fragment: Fragment? = null,
    val noises: List<Noise> = emptyList(),
    val muxEnabled: Boolean = false,
    val muxConcurrency: Int = 8,
    /** Kept for state compatibility; never emitted (see `makeSockopt`). */
    val tcpFastOpen: Boolean = true,
    val fingerprint: String = "chrome",
    val mimicry: List<String> = emptyList(),
) {
    data class Fragment(
        val packets: String = "tlshello",
        val length: String = "100-200",
        val interval: String = "10-20",
    )

    data class Noise(val type: String = "rand", val packet: String = "50-100", val delay: String = "10-16")

    companion object {
        /**
         * Russian-service aliases onto real uTLS IDs: YaBrowser is Chromium, the
         * VK client's stack looks like OkHttp. Anything else passes through
         * lowercased, because uTLS only knows canonical lowercase IDs and would
         * reject a link carrying "Chrome".
         */
        fun utlsFingerprint(name: String): String = when (name.lowercase()) {
            "yandex" -> "chrome"
            "vk" -> "android"
            else -> name.lowercase()
        }

        /** Balanced "unreadable + junk + fast"; mux stays off for XTLS-Vision. */
        val recommended = AntiCensorshipOptions(fragment = Fragment(), noises = listOf(Noise()))

        val balanced = recommended

        val maximum = AntiCensorshipOptions(
            fragment = Fragment(length = "40-80", interval = "5-10"),
            noises = listOf(
                Noise(packet = "100-200", delay = "4-8"),
                Noise(packet = "40-80", delay = "8-14"),
            ),
            fingerprint = "randomized",
        )

        val off = AntiCensorshipOptions()

        /** Zapret-style values that survive TSPU parsing, masquerading as Yandex. */
        val russiaYandex = AntiCensorshipOptions(
            fragment = Fragment(length = "10-25", interval = "5-12"),
            noises = listOf(
                Noise(packet = "30-90", delay = "5-10"),
                Noise(type = "str", packet = "GET / HTTP/1.1\r\nHost: www.yandex.ru\r\n\r\n", delay = "10-16"),
            ),
            fingerprint = "yandex",
            mimicry = listOf("www.yandex.ru", "yandex.ru", "ya.ru", "dzen.ru", "sso.yandex.ru"),
        )

        val russiaVK = AntiCensorshipOptions(
            fragment = Fragment(length = "15-35", interval = "6-14"),
            noises = listOf(
                Noise(packet = "40-120", delay = "5-11"),
                Noise(type = "str", packet = "GET / HTTP/1.1\r\nHost: www.vk.com\r\n\r\n", delay = "9-15"),
            ),
            fingerprint = "vk",
            mimicry = listOf("www.vk.com", "vk.com", "m.vk.com", "vkvideo.ru", "vkuser.net"),
        )
    }
}

/** The user-facing presets, same raw values as Swift's `MaskingProfile`. */
enum class MaskingProfile(val options: AntiCensorshipOptions) {
    off(AntiCensorshipOptions.off),
    balanced(AntiCensorshipOptions.balanced),
    maximum(AntiCensorshipOptions.maximum),
    ruYandex(AntiCensorshipOptions.russiaYandex),
    ruVK(AntiCensorshipOptions.russiaVK);

    /** Короткая подпись для списка — те же строки, что у Swift `MaskingProfile.title`. */
    val title: String get() = when (this) {
        off -> "Off"
        balanced -> "Balanced"
        maximum -> "Max"
        ruYandex -> "RU·Ya"
        ruVK -> "RU·VK"
    }

    /** Lightest → heaviest; the recovery ladder walks this and stops at the top. */
    val escalated: MaskingProfile? get() = when (this) {
        off -> balanced
        balanced -> maximum
        maximum -> ruYandex
        ruYandex -> ruVK
        ruVK -> null
    }

    companion object {
        fun of(name: String?): MaskingProfile? = entries.firstOrNull { it.name == name }
    }
}
