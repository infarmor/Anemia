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

    public init(
        servers: [ProxyServer] = [],
        subscriptions: [Subscription] = [],
        selectedServerID: UUID? = nil,
        anti: AntiCensorshipOptions = .recommended,
        killSwitchEnabled: Bool = false,
        maskingProfile: MaskingProfile = .balanced,
        autoConnectOnLaunch: Bool = false,
        mlRankingEnabled: Bool = true
    ) {
        self.servers = servers
        self.subscriptions = subscriptions
        self.selectedServerID = selectedServerID
        self.anti = anti
        self.killSwitchEnabled = killSwitchEnabled
        self.maskingProfile = maskingProfile
        self.autoConnectOnLaunch = autoConnectOnLaunch
        self.mlRankingEnabled = mlRankingEnabled
    }

    /// Lenient decoding: missing or malformed fields fall back to defaults so a
    /// schema change never discards a user's saved servers.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        servers = (try? c.decode([ProxyServer].self, forKey: .servers)) ?? []
        subscriptions = (try? c.decode([Subscription].self, forKey: .subscriptions)) ?? []
        selectedServerID = (try? c.decodeIfPresent(UUID.self, forKey: .selectedServerID)) ?? nil
        anti = (try? c.decode(AntiCensorshipOptions.self, forKey: .anti)) ?? .recommended
        killSwitchEnabled = (try? c.decode(Bool.self, forKey: .killSwitchEnabled)) ?? false
        maskingProfile = (try? c.decode(MaskingProfile.self, forKey: .maskingProfile)) ?? .balanced
        autoConnectOnLaunch = (try? c.decode(Bool.self, forKey: .autoConnectOnLaunch)) ?? false
        mlRankingEnabled = (try? c.decode(Bool.self, forKey: .mlRankingEnabled)) ?? true
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
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Loader", isDirectory: true)
                   .appendingPathComponent("state.json", isDirectory: false)
    }

    /// Load state, returning an empty default if the file is absent/unreadable.
    public func load() -> PersistedState {
        guard let data = try? Data(contentsOf: fileURL) else { return PersistedState() }
        return (try? JSONDecoder().decode(PersistedState.self, from: data)) ?? PersistedState()
    }

    public func save(_ state: PersistedState) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: [.atomic])
    }
}
