import Foundation

/// The full persisted client state: manually-added servers, subscriptions,
/// the current selection, and anti-DPI options.
public struct PersistedState: Codable, Sendable, Equatable {
    public var servers: [ProxyServer]
    public var subscriptions: [Subscription]
    public var selectedServerID: UUID?
    public var anti: AntiCensorshipOptions
    public var killSwitchEnabled: Bool
    public var maskingProfile: MaskingProfile
    public var autoConnectOnLaunch: Bool
    /// Use the kxc CoreML ranker (vs. plain lowest-ping) to choose the fastest.
    public var mlRankingEnabled: Bool
    /// Coexist mode: set the macOS system SOCKS proxy to the engine while
    /// connected, so browsers route through Anemia alongside another VPN.
    /// Off by default: it changes a persistent system setting, so it is the
    /// user's explicit choice (the app offers it when another VPN blocks the
    /// full tunnel).
    public var systemProxyEnabled: Bool
    /// Refresh subscriptions automatically: once shortly after launch, then
    /// every 6 hours. Keeps expiring/rotating server lists current without the
    /// user remembering the manual button.
    public var subscriptionAutoRefresh: Bool
    /// Masking profile (by ``ProxyServer/identityKey``) that was learned to keep
    /// a given server's traffic flowing, from adaptive escalation during
    /// recovery. Reused on the next connect to that server so it starts from the
    /// obfuscation it actually needs, not the global default.
    public var learnedMasking: [String: String]
    /// Split tunneling: destinations that bypass the VPN.
    public var splitTunnel: SplitTunnelRules

    public init(
        servers: [ProxyServer] = [],
        subscriptions: [Subscription] = [],
        selectedServerID: UUID? = nil,
        anti: AntiCensorshipOptions = .recommended,
        killSwitchEnabled: Bool = false,
        maskingProfile: MaskingProfile = .balanced,
        autoConnectOnLaunch: Bool = false,
        mlRankingEnabled: Bool = true,
        systemProxyEnabled: Bool = false,
        subscriptionAutoRefresh: Bool = true,
        learnedMasking: [String: String] = [:],
        splitTunnel: SplitTunnelRules = SplitTunnelRules()
    ) {
        self.servers = servers
        self.subscriptions = subscriptions
        self.selectedServerID = selectedServerID
        self.anti = anti
        self.killSwitchEnabled = killSwitchEnabled
        self.maskingProfile = maskingProfile
        self.autoConnectOnLaunch = autoConnectOnLaunch
        self.mlRankingEnabled = mlRankingEnabled
        self.systemProxyEnabled = systemProxyEnabled
        self.subscriptionAutoRefresh = subscriptionAutoRefresh
        self.learnedMasking = learnedMasking
        self.splitTunnel = splitTunnel
    }

    /// Lenient decoding: missing or malformed fields fall back to defaults so a
    /// schema change never discards a user's saved servers. Collections decode
    /// element-by-element: a single poisoned entry (an unknown enum raw value
    /// from an older/newer schema, say) drops only itself, not the whole list —
    /// all-or-nothing array decoding used to null every server the user had.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        servers = (try? c.decode([ProxyServer].self, forKey: .servers))
            ?? c.decodeLenientArray(ProxyServer.self, forKey: .servers)
        subscriptions = (try? c.decode([Subscription].self, forKey: .subscriptions))
            ?? c.decodeLenientArray(Subscription.self, forKey: .subscriptions)
        selectedServerID = (try? c.decodeIfPresent(UUID.self, forKey: .selectedServerID)) ?? nil
        anti = (try? c.decode(AntiCensorshipOptions.self, forKey: .anti)) ?? .recommended
        killSwitchEnabled = (try? c.decode(Bool.self, forKey: .killSwitchEnabled)) ?? false
        maskingProfile = (try? c.decode(MaskingProfile.self, forKey: .maskingProfile)) ?? .balanced
        autoConnectOnLaunch = (try? c.decode(Bool.self, forKey: .autoConnectOnLaunch)) ?? false
        mlRankingEnabled = (try? c.decode(Bool.self, forKey: .mlRankingEnabled)) ?? true
        systemProxyEnabled = (try? c.decode(Bool.self, forKey: .systemProxyEnabled)) ?? false
        subscriptionAutoRefresh = (try? c.decode(Bool.self, forKey: .subscriptionAutoRefresh)) ?? true
        learnedMasking = (try? c.decode([String: String].self, forKey: .learnedMasking)) ?? [:]
        splitTunnel = (try? c.decode(SplitTunnelRules.self, forKey: .splitTunnel)) ?? SplitTunnelRules()
    }

    /// Every selectable server: manual entries first, then subscription servers.
    public var allServers: [ProxyServer] {
        servers + subscriptions.flatMap { $0.servers }
    }

    public func server(withID id: UUID) -> ProxyServer? {
        allServers.first { $0.id == id }
    }
}

/// Reads/writes ``PersistedState`` as JSON on disk. Writes atomically so a crash
/// mid-save can't corrupt the store.
public struct StatePersistence: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Default location: `~/Library/Application Support/Loader/state.json`.
    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.homeDirectory.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Loader", isDirectory: true)
                   .appendingPathComponent("state.json", isDirectory: false)
    }

    /// Load state, returning an empty default if the file is absent/unreadable.
    /// A malformed or schema-drifted file is backed up first — the lenient
    /// decoder never throws on field mismatches (it falls back per-field), so
    /// a silent data loss must be detected by comparing the raw JSON with what
    /// the decode recovered.
    public func load() -> PersistedState {
        guard let data = try? Data(contentsOf: fileURL) else { return PersistedState() }
        let decoded = try? JSONDecoder().decode(PersistedState.self, from: data)

        // Schema drift detector: the raw store still carries entries in some
        // collection, but the decode recovered fewer of them (or none — or
        // failed outright) → previous contents are about to be lost. Counts
        // are compared, not just emptiness, so a lenient per-element decode
        // that drops even one poisoned entry still triggers the safety
        // backup. Every persisted collection is checked, not just `servers`.
        var droppedEntries = false
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // A non-collection value (e.g. drift to a scalar) counts as one entry.
            func rawCount(_ key: String) -> Int? {
                guard let v = obj[key] else { return nil }
                if let a = v as? [Any] { return a.count }
                if let d = v as? [String: Any] { return d.count }
                return 1
            }
            if let n = rawCount("servers") {
                droppedEntries = droppedEntries || ((decoded?.servers.count ?? 0) < n)
            }
            if let n = rawCount("subscriptions") {
                droppedEntries = droppedEntries || ((decoded?.subscriptions.count ?? 0) < n)
            }
            if let n = rawCount("learnedMasking") {
                droppedEntries = droppedEntries || ((decoded?.learnedMasking.count ?? 0) < n)
            }
            // `splitTunnel` is an object, so `rawCount` on it would compare the
            // two keys `enabled`/`entries` against a rule count — meaningless.
            // Its own decoder is the lenient one that cannot fail: an
            // unreadable `entries` array comes back empty, the file still
            // "loads", and the next save() replaces the only copy of the user's
            // bypass rules with nothing. Check the nested array by name.
            if let rules = obj["splitTunnel"] as? [String: Any],
               let entries = rules["entries"] as? [Any] {
                droppedEntries = droppedEntries || ((decoded?.splitTunnel.entries.count ?? 0) < entries.count)
            }
            // `anti` is the other lenient struct, and two of its shapes cost
            // more than the field that broke:
            //  * `noises` is read element by element, so one poisoned entry costs
            //    that entry — but a `noises` that is not an array at all, or an
            //    element shape nothing decodes, still falls back per *field* and
            //    can empty the list;
            //  * `fragment` is a single all-or-nothing struct: a panel writing
            //    `length: 200` instead of "100-200" loses the whole ClientHello
            //    fragmentation, silently.
            // Both are invisible in the worst way — the UI keeps naming the
            // anti-DPI profile while the engine gets less of it, and the
            // connection fails somewhere else — so the raw document is compared
            // with what the decode recovered before the next save overwrites it.
            if let anti = obj["anti"] as? [String: Any] {
                if let noises = anti["noises"] as? [Any] {
                    droppedEntries = droppedEntries || ((decoded?.anti.noises.count ?? 0) < noises.count)
                }
                // A present-but-unreadable fragment object, not `"fragment":null`
                // (which is the user turning fragmentation off, and decodes fine).
                if anti["fragment"] is [String: Any] {
                    droppedEntries = droppedEntries || (decoded?.anti.fragment == nil)
                }
            }
        }
        if decoded == nil || droppedEntries {
            // Millisecond timestamp: a same-second collision would silently
            // overwrite an earlier backup.
            let backup = fileURL.deletingPathExtension()
                .appendingPathExtension("json.corrupt-\(Int(Date().timeIntervalSince1970 * 1000)).bak")
            // This write is the one thing standing between the user and losing
            // their server list, so a transient FS failure (disk pressure,
            // atomic-rename hiccup under load) falls back to a plain write.
            // `try?` stays — recovery must never crash the app — but never
            // silently skip the backup while one write mode can still work.
            if (try? data.write(to: backup, options: [.atomic])) == nil {
                try? data.write(to: backup)
            }
            pruneCorruptBackups()
        }
        return decoded ?? PersistedState()
    }

    public func save(_ state: PersistedState) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: [.atomic])
    }

    /// A persistently poisoned store re-enters this backup path on every app
    /// launch, each run dropping a fresh timestamped `.corrupt-*.bak` next to
    /// the state file — unbounded clutter for an unattended Mac. Keep only the
    /// newest few and delete the rest (best effort; failure to prune must
    /// never fail the load).
    private func pruneCorruptBackups(kept: Int = 3) {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        let base = fileURL.deletingPathExtension().lastPathComponent
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let backups = entries
            .filter { $0.lastPathComponent.hasPrefix("\(base).json.corrupt-") && $0.pathExtension == "bak" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } // newest (largest ms stamp) first
        for stale in backups.dropFirst(max(0, kept)) {
            try? fm.removeItem(at: stale)
        }
    }
}

/// Absorbs a poisoned element: `init` never throws, so decoding an array of
/// these can't fail wholesale — a bad entry becomes `nil` and is dropped
/// individually instead of nulling the collection it lives in.
private struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

private extension KeyedDecodingContainer {
    /// Decode an array element-by-element, keeping the healthy entries when
    /// individual elements are corrupt (unknown enum raw value, type drift).
    /// Falls back to an empty array only if the key isn't a collection at all.
    func decodeLenientArray<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T] {
        guard let boxed = try? decode([FailableDecodable<T>].self, forKey: key) else { return [] }
        return boxed.compactMap(\.value)
    }
}
