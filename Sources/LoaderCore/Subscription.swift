import Foundation

/// A saved subscription: a URL that returns a list of share links, plus the
/// servers most recently fetched from it.
public struct Subscription: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var url: String
    public var lastUpdated: Date?
    public var servers: [ProxyServer]

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
