import Foundation

/// A network service's SOCKS proxy as `networksetup -getsocksfirewallproxy`
/// reports it.
public struct ProxySetting: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var host: String
    public var port: Int

    public init(enabled: Bool, host: String, port: Int) {
        self.enabled = enabled
        self.host = host
        self.port = port
    }

    public static let off = ProxySetting(enabled: false, host: "", port: 0)
}

/// Crash-safe ledger of every system change the helper makes that would
/// SURVIVE a helper crash or a reboot on its own: per-service DNS resolvers
/// and SOCKS proxies (persistent SystemConfiguration preferences written by
/// `networksetup`) and the pf enable reference held by the kill switch.
///
/// This ledger is what keeps a Mac from being left offline. The earlier
/// backup files broke that promise in three ways, each enough to strand a
/// machine with dead DNS or a dead proxy across reboots:
///  * the backup was deleted even when the restore command failed;
///  * the next session then captured the *leftover pin* as the user's own
///    setting, so every later "restore" faithfully re-applied it;
///  * services whose state couldn't be read were overridden anyway, with no
///    record to undo them after a crash.
///
/// The contract now:
///  1. The prior value is written — fsync'd — BEFORE a setting changes. No
///     durable record, no change.
///  2. A prior value is never one of our own (a resolver on a tunnel gateway,
///     a proxy on an engine port): see ``NetworkSettingsPolicy``.
///  3. An entry leaves the ledger only once its restore landed, or once the
///     setting no longer holds our value (the user changed it since).
///  4. Every helper launch — boot (RunAtLoad), crash respawn, reinstall —
///     replays the ledger before serving a single request.
public struct NetworkJournal: Codable, Equatable, Sendable {
    public struct DNSEntry: Codable, Equatable, Sendable {
        public var service: String
        /// Resolvers before the override; empty = automatic (DHCP).
        public var prior: [String]
        /// Resolvers we set; empty = unknown (migrated from a legacy backup).
        public var applied: [String]

        public init(service: String, prior: [String], applied: [String]) {
            self.service = service
            self.prior = prior
            self.applied = applied
        }
    }

    public struct ProxyEntry: Codable, Equatable, Sendable {
        public var service: String
        public var prior: ProxySetting
        /// The loopback endpoint we pointed the service at; port 0 = unknown
        /// (migrated from a legacy backup).
        public var applied: ProxySetting

        public init(service: String, prior: ProxySetting, applied: ProxySetting) {
            self.service = service
            self.prior = prior
            self.applied = applied
        }
    }

    public static let currentVersion = 1

    public var version = NetworkJournal.currentVersion
    public var dns: [DNSEntry] = []
    public var proxy: [ProxyEntry] = []
    /// pf enable reference taken by the kill switch (`pfctl -E`).
    public var pfToken: String?
    /// A pre-0.8 helper armed its kill switch by replacing pf's MAIN ruleset.
    /// Recovery must then reload /etc/pf.conf — only in that case, since a
    /// reload flushes anchors other system services insert at runtime.
    public var legacyMainRuleset = false

    public var isEmpty: Bool { dns.isEmpty && proxy.isEmpty && pfToken == nil && !legacyMainRuleset }

    public init() {}

    /// Lenient decode: a field that fails to decode costs that field, never
    /// the whole ledger (a ledger that reads as "empty" restores nothing) — and
    /// the same rule one level down, where it matters most: an entry that can't
    /// be read costs **that entry**, not the array. Before that, one drifted
    /// field in one service's record discarded every DNS entry: the helper
    /// booted, saw an empty ledger, restored nothing at all, and the first
    /// `persist()` wrote the emptiness over the only copy that could have put
    /// the machine's DNS back.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? Self.currentVersion
        dns = (try? c.decode([Loose<DNSEntry>].self, forKey: .dns))?.compactMap(\.value) ?? []
        proxy = (try? c.decode([Loose<ProxyEntry>].self, forKey: .proxy))?.compactMap(\.value) ?? []
        pfToken = (try? c.decodeIfPresent(String.self, forKey: .pfToken)) ?? nil
        legacyMainRuleset = (try? c.decode(Bool.self, forKey: .legacyMainRuleset)) ?? false
    }
}

/// One ledger entry, or nothing when the entry can't be read — so a single
/// unreadable record cannot take its whole array with it.
private struct Loose<Element: Decodable>: Decodable {
    let value: Element?

    init(from decoder: Decoder) throws {
        value = try? Element(from: decoder)
    }
}
