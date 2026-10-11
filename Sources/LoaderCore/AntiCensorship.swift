import Foundation

/// Options that harden the outbound connection against DPI / traffic analysis.
///
/// These map onto native Xray-core features — no home-grown crypto. The goal is
/// exactly what the user asked for: make the traffic unreadable, pad it with
/// junk so a censor's DPI can't classify it, while keeping it fast.
public struct AntiCensorshipOptions: Codable, Sendable, Equatable {

    /// TLS ClientHello fragmentation. Splits the first packet so SNI-based DPI
    /// can't match the handshake. Implemented via a `freedom` dialer outbound.
    public struct Fragment: Codable, Sendable, Equatable {
        /// What to fragment: "tlshello" (just the ClientHello) or "1-3" (packet range).
        public var packets: String
        /// Byte length range of each fragment, e.g. "100-200".
        public var length: String
        /// Delay range between fragments in ms, e.g. "10-20".
        public var interval: String

        public init(packets: String = "tlshello", length: String = "100-200", interval: String = "10-20") {
            self.packets = packets
            self.length = length
            self.interval = interval
        }
    }

    /// Junk / noise packets sent before real data to poison DPI classifiers.
    /// Maps to the masking `freedom` outbound's `settings.noises` — not a
    /// socket option; see ``AntiCensorshipOptions/emittableNoises`` for what
    /// the engine will actually load.
    public struct Noise: Codable, Sendable, Equatable {
        /// "rand" (random bytes), "str" (literal), "hex" or "base64" — matched
        /// case-sensitively by the engine.
        public var type: String
        /// Byte length range (rand) or the literal/hex/base64 payload.
        public var packet: String
        /// Delay range in ms before sending, e.g. "10-16".
        public var delay: String

        public init(type: String = "rand", packet: String = "50-100", delay: String = "10-16") {
            self.type = type
            self.packet = packet
            self.delay = delay
        }
    }

    /// Enable TLS ClientHello fragmentation.
    public var fragment: Fragment?
    /// One or more junk-noise generators.
    public var noises: [Noise]
    /// Enable connection multiplexing with padding (mux.cool).
    public var muxEnabled: Bool
    public var muxConcurrency: Int
    /// TCP Fast Open — shaves a round trip on connect. Retained for
    /// persisted-state compatibility; ignored on Darwin, where xray's TFO
    /// setsockopt fails with EINVAL and kills the whole dial ("failed to
    /// apply socket options > invalid argument", Xray-core#989).
    public var tcpFastOpen: Bool
    /// uTLS fingerprint to mimic (e.g. "chrome", "firefox", "safari",
    /// "randomized", or the Russian-service aliases "yandex"/"vk" — those map
    /// onto the closest real uTLS ID, see ``AntiCensorshipOptions/utlsFingerprint``).
    /// Applied to Reality/TLS unless the server link overrides it.
    public var fingerprint: String
    /// Stealth-SNI pool: when the server link carries no explicit SNI, the
    /// handshake is presented with a random host from this list. Pointing the
    /// ClientHello at a TSPU-whitelisted Russian domain (yandex.ru, vk.com, …)
    /// makes the session look like ordinary RU-service traffic — the classic
    /// whitelist evasion. The server must actually serve/camouflage that name
    /// (Reality dest), so the presets only bundle well-known mirror domains.
    public var mimicry: [String]

    public init(
        fragment: Fragment? = nil,
        noises: [Noise] = [],
        muxEnabled: Bool = false,
        muxConcurrency: Int = 8,
        tcpFastOpen: Bool = true,
        fingerprint: String = "chrome",
        mimicry: [String] = []
    ) {
        self.fragment = fragment
        self.noises = noises
        self.muxEnabled = muxEnabled
        self.muxConcurrency = muxConcurrency
        self.tcpFastOpen = tcpFastOpen
        self.fingerprint = fingerprint
        self.mimicry = mimicry
    }

    /// Custom decoder: older persisted state has no `mimicry` key, and any
    /// single field may have drifted (e.g. a noise `packet` that used to be a
    /// number). Each field falls back independently, so one bad entry costs
    /// that field's default — not the whole options struct (which the
    /// synthesized decoder would have failed, making Persistence treat a
    /// perfectly good store as corrupt).
    ///
    /// The two arrays get the same rule one level down: read element by
    /// element, so one poisoned noise costs *that entry*. Decoded through
    /// `try?` as a whole array, a single bad element emptied `noises` — every
    /// generator and the ClientHello fragmentation gone while the UI kept
    /// naming the same masking profile, which is a handshake that dies
    /// somewhere else entirely. `Persistence.decodeLenientArray` does this
    /// already but is private to that file; duplicating the wrapper here beats
    /// editing a file another pass is working in.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fragment = (try? c.decodeIfPresent(Fragment.self, forKey: .fragment)) ?? nil
        noises = (try? c.decodeIfPresent([Loose<Noise>].self, forKey: .noises))?.compactMap(\.value) ?? []
        muxEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .muxEnabled)) ?? false
        muxConcurrency = (try? c.decodeIfPresent(Int.self, forKey: .muxConcurrency)) ?? 8
        tcpFastOpen = (try? c.decodeIfPresent(Bool.self, forKey: .tcpFastOpen)) ?? true
        fingerprint = (try? c.decodeIfPresent(String.self, forKey: .fingerprint)) ?? "chrome"
        mimicry = (try? c.decodeIfPresent([Loose<String>].self, forKey: .mimicry))?.compactMap(\.value) ?? []
    }

    /// Russian-service fingerprint aliases → the closest real uTLS ClientHello.
    /// YaBrowser is Chromium-based (→ chrome); the VK client TLS stack matches
    /// OkHttp-on-Android (→ android). Unknown names pass through to uTLS
    /// lowercased — uTLS only knows the canonical lowercase IDs ("chrome",
    /// "randomized"…), so a link carrying "Chrome" or "iOS" would otherwise be
    /// rejected as an unknown fingerprint and kill the handshake.
    public static func utlsFingerprint(_ name: String) -> String {
        switch name.lowercased() {
        case "yandex": return "chrome"
        case "vk":     return "android"
        default:       return name.lowercased()
        }
    }

    /// Balanced default tuned for "unreadable + junk + fast": fragment the
    /// ClientHello, one random junk generator, TFO on, Chrome fingerprint.
    /// Mux stays off because XTLS-Vision is faster without it.
    public static var recommended: AntiCensorshipOptions { balanced }

    public static var balanced: AntiCensorshipOptions {
        AntiCensorshipOptions(
            fragment: Fragment(),
            noises: [Noise()],
            tcpFastOpen: true,
            fingerprint: "chrome"
        )
    }

    /// Aggressive masking: smaller/faster ClientHello fragments and several
    /// varied junk generators, with a randomized fingerprint. Costs a little
    /// latency for maximum DPI resistance.
    public static var maximum: AntiCensorshipOptions {
        AntiCensorshipOptions(
            fragment: Fragment(packets: "tlshello", length: "40-80", interval: "5-10"),
            noises: [
                Noise(type: "rand", packet: "100-200", delay: "4-8"),
                Noise(type: "rand", packet: "40-80", delay: "8-14")
            ],
            tcpFastOpen: true,
            fingerprint: "randomized"
        )
    }

    /// No obfuscation — plain fast path (useful when Reality already hides you).
    public static var off: AntiCensorshipOptions {
        AntiCensorshipOptions(fragment: nil, noises: [], muxEnabled: false,
                              tcpFastOpen: true, fingerprint: "chrome")
    }

    /// Russia-tuned evasion masquerading as Yandex traffic. Fragment sizes and
    /// jitter follow the community (zapret-style) values that survive TSPU
    /// parsing; a literal HTTP junk packet toward www.yandex.ru precedes the
    /// real data, and handshakes without their own SNI borrow a whitelisted
    /// Yandex host.
    public static var russiaYandex: AntiCensorshipOptions {
        AntiCensorshipOptions(
            fragment: Fragment(packets: "tlshello", length: "10-25", interval: "5-12"),
            noises: [
                Noise(type: "rand", packet: "30-90", delay: "5-10"),
                Noise(type: "str", packet: "GET / HTTP/1.1\r\nHost: www.yandex.ru\r\n\r\n", delay: "10-16")
            ],
            tcpFastOpen: true,
            fingerprint: "yandex",
            mimicry: ["www.yandex.ru", "yandex.ru", "ya.ru", "dzen.ru", "sso.yandex.ru"]
        )
    }

    /// Russia-tuned evasion masquerading as VK traffic — same mechanics as
    /// ``russiaYandex`` with VK's domain pool and fingerprint.
    public static var russiaVK: AntiCensorshipOptions {
        AntiCensorshipOptions(
            fragment: Fragment(packets: "tlshello", length: "15-35", interval: "6-14"),
            noises: [
                Noise(type: "rand", packet: "40-120", delay: "5-11"),
                Noise(type: "str", packet: "GET / HTTP/1.1\r\nHost: www.vk.com\r\n\r\n", delay: "9-15")
            ],
            tcpFastOpen: true,
            fingerprint: "vk",
            mimicry: ["www.vk.com", "vk.com", "m.vk.com", "vkvideo.ru", "vkuser.net"]
        )
    }
}

/// User-facing masking presets that map onto ``AntiCensorshipOptions``.
public enum MaskingProfile: String, Codable, Sendable, CaseIterable {
    case off
    case balanced
    case maximum
    case ruYandex
    case ruVK

    public var options: AntiCensorshipOptions {
        switch self {
        case .off:      return .off
        case .balanced: return .balanced
        case .maximum:  return .maximum
        case .ruYandex: return .russiaYandex
        case .ruVK:     return .russiaVK
        }
    }

    public var title: String {
        switch self {
        case .off:      return "Off"
        case .balanced: return "Balanced"
        case .maximum:  return "Max"
        case .ruYandex: return "RU·Ya"
        case .ruVK:     return "RU·VK"
        }
    }

    public var subtitle: String {
        switch self {
        case .off:      return "No obfuscation — fastest"
        case .balanced: return "Fragment + junk — recommended"
        case .maximum:  return "Aggressive fragment + more junk"
        case .ruYandex: return "Russia: masquerade as Yandex (stealth SNI + junk)"
        case .ruVK:     return "Russia: masquerade as VK (stealth SNI + junk)"
        }
    }

    /// The next stronger profile to try when a server connects but its traffic
    /// is being throttled or reset (likely DPI). Walks lightest → heaviest and
    /// ends at the Russia-tuned whitelist-mimicry profiles; `nil` at the top.
    public var escalated: MaskingProfile? {
        switch self {
        case .off:      return .balanced
        case .balanced: return .maximum
        case .maximum:  return .ruYandex
        case .ruYandex: return .ruVK
        case .ruVK:     return nil
        }
    }
}

/// One array element, or nothing when it can't be read — so a single corrupt
/// entry cannot take its whole array down with it.
private struct Loose<Element: Decodable>: Decodable {
    let value: Element?

    init(from decoder: Decoder) throws {
        value = try? Element(from: decoder)
    }
}
