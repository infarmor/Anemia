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
    /// Maps to Xray `sockopt.noises`.
    public struct Noise: Codable, Sendable, Equatable {
        /// "rand" (random bytes), "str" (literal), or "base64".
        public var type: String
        /// Packet size range (rand) or the literal/base64 payload.
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
    /// TCP Fast Open — shaves a round trip on connect.
    public var tcpFastOpen: Bool
    /// uTLS fingerprint to mimic (e.g. "chrome", "firefox", "safari",
    /// "randomized"). Applied to Reality/TLS unless the server link overrides it.
    public var fingerprint: String

    public init(
        fragment: Fragment? = nil,
        noises: [Noise] = [],
        muxEnabled: Bool = false,
        muxConcurrency: Int = 8,
        tcpFastOpen: Bool = true,
        fingerprint: String = "chrome"
    ) {
        self.fragment = fragment
        self.noises = noises
        self.muxEnabled = muxEnabled
        self.muxConcurrency = muxConcurrency
        self.tcpFastOpen = tcpFastOpen
        self.fingerprint = fingerprint
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
}

/// User-facing masking presets that map onto ``AntiCensorshipOptions``.
public enum MaskingProfile: String, Codable, Sendable, CaseIterable {
    case off
    case balanced
    case maximum

    public var options: AntiCensorshipOptions {
        switch self {
        case .off:      return .off
        case .balanced: return .balanced
        case .maximum:  return .maximum
        }
    }

    public var title: String {
        switch self {
        case .off:      return "Off"
        case .balanced: return "Balanced"
        case .maximum:  return "Max"
        }
    }

    public var subtitle: String {
        switch self {
        case .off:      return "No obfuscation — fastest"
        case .balanced: return "Fragment + junk — recommended"
        case .maximum:  return "Aggressive fragment + more junk"
        }
    }
}
