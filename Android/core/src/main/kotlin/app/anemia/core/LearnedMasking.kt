package app.anemia.core

/**
 * Port of `Sources/LoaderCore/LearnedMasking.swift`: which masking profile
 * actually got a server through, remembered per server — and per kind of
 * network, because a mobile operator filters harder than home Wi‑Fi.
 *
 * The server's plain identity key is the general entry; a network's own entry
 * wins on that network. Forgetting a server drops both, so it goes back to the
 * profile the user chose.
 */
enum class NetworkKind(val raw: String) {
    WIFI("wifi"), CELLULAR("cellular");

    companion object {
        fun of(raw: String?): NetworkKind? = entries.firstOrNull { it.raw == raw }
    }
}

object LearnedMasking {

    fun key(server: ProxyServer, network: NetworkKind?): String =
        if (network == null) server.identityKey else server.identityKey + "#" + network.raw

    /** The server part of a learned-masking key. */
    fun serverKeyOf(key: String): String {
        for (network in NetworkKind.entries) {
            if (key.endsWith("#" + network.raw)) {
                return key.dropLast(network.raw.length + 1)
            }
        }
        return key
    }

    /** What worked for `server` on this kind of network, else anywhere. */
    fun profileFor(
        state: PersistedState,
        server: ProxyServer,
        network: NetworkKind?,
    ): MaskingProfile? {
        val raw = network?.let { state.learnedMasking[key(server, it)] }
            ?: state.learnedMasking[server.identityKey]
        return raw?.let { MaskingProfile.of(it) }
    }

    /** The same state with what was learned (or with the entries forgotten). */
    fun learned(
        state: PersistedState,
        profile: MaskingProfile?,
        server: ProxyServer,
        network: NetworkKind?,
    ): PersistedState {
        val learned = LinkedHashMap(state.learnedMasking)
        val key = key(server, network)
        if (profile != null) {
            learned[key] = profile.name
        } else {
            learned.remove(key)
            learned.remove(server.identityKey)
        }
        return state.copy(learnedMasking = learned)
    }
}

/** How hard the profile hides the handshake — the order adaptive masking walks. */
val MaskingProfile.strength: Int
    get() = when (this) {
        MaskingProfile.off -> 0
        MaskingProfile.balanced -> 1
        MaskingProfile.maximum -> 2
        MaskingProfile.ruYandex, MaskingProfile.ruVK -> 3
    }
