import Foundation

/// Everything one Anemia hands another — Mac to iPhone and back, as a file
/// (AirDrop, Files) or a QR code: the servers added by hand, the
/// subscriptions (their addresses; each device fetches the lists itself) and
/// the settings both apps share. The selection stays behind: each device
/// picks its own exit.
public struct SyncBundle: Codable, Equatable, Sendable {
    public static let formatVersion = 1
    public static let fileExtension = "anemia"
    /// The QR / link form: `anemia://sync/` + base64url(zlib(JSON)).
    public static let linkPrefix = "anemia://sync/"

    public struct SubscriptionEntry: Codable, Equatable, Sendable {
        public var name: String
        public var url: String

        public init(name: String, url: String) {
            self.name = name
            self.url = url
        }
    }

    /// Settings travel as optionals: a field one app doesn't have (the Mac
    /// has no ad blocking switch, say) stays nil and leaves the other side's
    /// value alone.
    public struct Settings: Codable, Equatable, Sendable {
        public var maskingProfile: MaskingProfile?
        public var killSwitchEnabled: Bool?
        public var splitTunnel: SplitTunnelRules?
        public var learnedMasking: [String: String]?
        public var subscriptionAutoRefresh: Bool?
        /// Block ads (AdGuard DNS), in both apps. Kept by each app itself,
        /// outside `PersistedState`, so the bundle carries it on its own.
        public var adBlock: Bool?
        // iPhone-only; the Mac ignores them.
        public var autoReconnect: Bool?
        public var autoSwitch: Bool?
        public var adaptiveMasking: Bool?

        public init(maskingProfile: MaskingProfile? = nil, killSwitchEnabled: Bool? = nil,
                    splitTunnel: SplitTunnelRules? = nil, learnedMasking: [String: String]? = nil,
                    subscriptionAutoRefresh: Bool? = nil, adBlock: Bool? = nil, autoReconnect: Bool? = nil,
                    autoSwitch: Bool? = nil, adaptiveMasking: Bool? = nil) {
            self.maskingProfile = maskingProfile
            self.killSwitchEnabled = killSwitchEnabled
            self.splitTunnel = splitTunnel
            self.learnedMasking = learnedMasking
            self.subscriptionAutoRefresh = subscriptionAutoRefresh
            self.adBlock = adBlock
            self.autoReconnect = autoReconnect
            self.autoSwitch = autoSwitch
            self.adaptiveMasking = adaptiveMasking
        }
    }

    public var version: Int
    public var exportedAt: Date
    /// The sending device's name, shown before importing.
    public var device: String
    public var servers: [ProxyServer]
    public var subscriptions: [SubscriptionEntry]
    public var settings: Settings?

    public init(version: Int = SyncBundle.formatVersion, exportedAt: Date = Date(), device: String,
                servers: [ProxyServer], subscriptions: [SubscriptionEntry], settings: Settings?) {
        self.version = version
        self.exportedAt = exportedAt
        self.device = device
        self.servers = servers
        self.subscriptions = subscriptions
        self.settings = settings
    }

    /// A bundle of `state`, with its shared settings.
    public init(state: PersistedState, device: String, exportedAt: Date = Date()) {
        self.init(
            exportedAt: exportedAt,
            device: device,
            servers: state.servers,
            subscriptions: state.subscriptions.map { SubscriptionEntry(name: $0.name, url: $0.url) },
            settings: Settings(
                maskingProfile: state.maskingProfile,
                killSwitchEnabled: state.killSwitchEnabled,
                splitTunnel: state.splitTunnel,
                learnedMasking: state.learnedMasking.isEmpty ? nil : state.learnedMasking,
                subscriptionAutoRefresh: state.subscriptionAutoRefresh
            )
        )
    }

    // MARK: - Merging

    public struct Summary: Equatable, Sendable {
        public var addedServers: Int
        /// Servers the other side already had (same endpoint and credentials).
        public var knownServers: Int
        public var newSubscriptions: [SubscriptionEntry]
        public var knownSubscriptions: Int
        public var settingsApplied: Bool

        public var addsNothing: Bool { addedServers == 0 && newSubscriptions.isEmpty && !settingsApplied }
    }

    /// What `merge` would do to `state`, without doing it.
    public func preview(against state: PersistedState, applySettings: Bool) -> Summary {
        var copy = state
        return merge(into: &copy, applySettings: applySettings)
    }

    /// Adds what `state` lacks — servers by identity (endpoint and
    /// credentials), subscriptions by address — and, with `applySettings`,
    /// takes over the settings the bundle carries. New subscriptions arrive
    /// empty (never fetched), for the caller to refresh.
    @discardableResult
    public func merge(into state: inout PersistedState, applySettings: Bool) -> Summary {
        var summary = Summary(addedServers: 0, knownServers: 0, newSubscriptions: [],
                              knownSubscriptions: 0, settingsApplied: false)
        var known = Set(state.allServers.map(\.identityKey))
        var knownIDs = Set(state.allServers.map(\.id))
        for var server in servers {
            guard known.insert(server.identityKey).inserted else {
                summary.knownServers += 1
                continue
            }
            // The same server edited on both sides keeps both copies apart.
            if !knownIDs.insert(server.id).inserted {
                server.id = UUID()
                knownIDs.insert(server.id)
            }
            state.servers.append(server)
            summary.addedServers += 1
        }

        var knownURLs = Set(state.subscriptions.map { Self.normalized($0.url) })
        for entry in subscriptions {
            guard knownURLs.insert(Self.normalized(entry.url)).inserted else {
                summary.knownSubscriptions += 1
                continue
            }
            state.subscriptions.append(Subscription(name: entry.name, url: entry.url))
            summary.newSubscriptions.append(entry)
        }

        if applySettings, let settings {
            if let masking = settings.maskingProfile { state.maskingProfile = masking }
            if let killSwitch = settings.killSwitchEnabled { state.killSwitchEnabled = killSwitch }
            if let rules = settings.splitTunnel { state.splitTunnel = rules }
            if let learned = settings.learnedMasking {
                state.learnedMasking.merge(learned) { _, incoming in incoming }
            }
            if let refresh = settings.subscriptionAutoRefresh { state.subscriptionAutoRefresh = refresh }
            summary.settingsApplied = true
        }

        if state.selectedServerID == nil {
            state.selectedServerID = state.allServers.first?.id
        }
        return summary
    }

    private static func normalized(_ url: String) -> String {
        url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: - Encoding

    public enum DecodeError: Error, Equatable {
        case notABundle
        /// Written by a newer Anemia than this one understands.
        case newerVersion(Int)
    }

    /// The file form: readable JSON.
    public func fileData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Reads the file form or the link form.
    public static func decode(_ data: Data) throws -> SyncBundle {
        if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           text.hasPrefix(linkPrefix) {
            return try fromLink(text)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let bundle = try? decoder.decode(SyncBundle.self, from: data) else {
            // Tell "too new" apart from "not ours".
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let version = object["version"] as? Int, version > formatVersion, object["device"] != nil {
                throw DecodeError.newerVersion(version)
            }
            throw DecodeError.notABundle
        }
        guard bundle.version <= formatVersion else { throw DecodeError.newerVersion(bundle.version) }
        return bundle
    }

    /// The link form, small enough for a QR code with a handful of servers.
    public func link() throws -> String {
        let encoder = JSONEncoder()
        // Sorted keys: without them `learnedMasking` and `userData` go out in a
        // dictionary's random order, so the same bundle produced a different — and
        // sometimes longer, QR-not-fitting — payload on every export.
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(self)
        let packed = try (json as NSData).compressed(using: .zlib) as Data
        return Self.linkPrefix + Self.base64URL(packed)
    }

    public static func fromLink(_ text: String) throws -> SyncBundle {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(linkPrefix) else { throw DecodeError.notABundle }
        let payload = String(trimmed.dropFirst(linkPrefix.count))
        guard let packed = base64URLDecode(payload),
              let json = try? (packed as NSData).decompressed(using: .zlib) as Data
        else { throw DecodeError.notABundle }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let bundle = try? decoder.decode(SyncBundle.self, from: json) else { throw DecodeError.notABundle }
        guard bundle.version <= formatVersion else { throw DecodeError.newerVersion(bundle.version) }
        return bundle
    }

    /// Whether `text` looks like a bundle at all — a link or the file's JSON.
    public static func looksLikeBundle(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix(linkPrefix) { return true }
        return trimmed.hasPrefix("{") && trimmed.contains("\"exportedAt\"") && trimmed.contains("\"device\"")
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}
