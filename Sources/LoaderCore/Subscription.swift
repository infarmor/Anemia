import Foundation

/// A saved subscription: a URL that returns a list of share links, plus the
/// servers most recently fetched from it.
public struct Subscription: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var url: String
    public var lastUpdated: Date?
    public var servers: [ProxyServer]

    /// Can this list be fetched at all without the user asking? A panel
    /// reachable over plain http answers as whoever controls the path decides:
    /// a café router returns its own server list and the nightly auto-refresh
    /// quietly installs it in place of the real one. Automatic rounds skip
    /// these subscriptions; pressing Refresh still loads them — the row shows
    /// the mark next to the name.
    public var tlsProtected: Bool {
        url.lowercased().hasPrefix("https://")
    }

    public init(
        id: UUID = UUID(),
        name: String,
        url: String,
        lastUpdated: Date? = nil,
        servers: [ProxyServer] = []
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.lastUpdated = lastUpdated
        self.servers = servers
    }
}
