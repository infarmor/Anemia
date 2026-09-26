import Foundation

/// The kind of network a device is on. Mobile operators often filter harder
/// than home Wi‑Fi, so the masking a server needed on one may be too little —
/// or more than needed — on the other.
public enum NetworkKind: String, Codable, Sendable, CaseIterable {
    /// Wi‑Fi or a cable.
    case wifi
    /// Mobile data: the phone's own, or a Mac on the phone's hotspot.
    case cellular
}

/// The masking that got a server through, kept in
/// `PersistedState.learnedMasking` per server and per kind of network. The
/// server's plain identity key is the general entry (the only one the Mac
/// app kept before networks mattered); a network's own entry comes first
/// on that network.
extension PersistedState {
    public static func learnedMaskingKey(for server: ProxyServer, on network: NetworkKind?) -> String {
        guard let network else { return server.identityKey }
        return server.identityKey + "#" + network.rawValue
    }

    /// The server part of a learned-masking key.
    public static func serverKey(ofLearnedMaskingKey key: String) -> String {
        for network in NetworkKind.allCases where key.hasSuffix("#" + network.rawValue) {
            return String(key.dropLast(network.rawValue.count + 1))
        }
        return key
    }

    /// What worked for `server` on this kind of network, else anywhere.
    public func learnedMasking(for server: ProxyServer, on network: NetworkKind?) -> MaskingProfile? {
        let raw = network.flatMap { learnedMasking[Self.learnedMaskingKey(for: server, on: $0)] }
            ?? learnedMasking[server.identityKey]
        return raw.flatMap(MaskingProfile.init(rawValue:))
    }

    /// Keeps what worked on this kind of network (anywhere, without one).
    /// Forgetting drops the network's entry and the general one, so the
    /// server goes back to the chosen profile on this network.
    public mutating func learnMasking(_ profile: MaskingProfile?, for server: ProxyServer, on network: NetworkKind?) {
        let key = Self.learnedMaskingKey(for: server, on: network)
        if let profile {
            learnedMasking[key] = profile.rawValue
        } else {
            learnedMasking[key] = nil
            learnedMasking[server.identityKey] = nil
        }
    }
}

extension MaskingProfile {
    /// How hard the profile hides the handshake — the order adaptive masking
    /// tries them in.
    public var strength: Int {
        switch self {
        case .off: 0
        case .balanced: 1
        case .maximum: 2
        case .ruYandex, .ruVK: 3
        }
    }
}
