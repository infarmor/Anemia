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

    /// How long an unattended round waits between two fetches of this panel.
    ///
    /// `panelInterval` is what the panel asked for through
    /// `profile-update-interval`, in seconds; a panel that says nothing gets
    /// `defaultAge`. The result is clamped to `[1 h, 24 h]`: hourly polling
    /// spams every panel in the list, and a panel asking for monthly updates
    /// would otherwise sit stale for a month while its servers rot.
    public func refreshMaxAge(
        panelInterval: TimeInterval?,
        defaultAge: TimeInterval = 6 * 3_600
    ) -> TimeInterval {
        // NaN прошёл бы зажатие нетронутым (`min`/`max` с NaN оставляют NaN), а
        // `age >= NaN` ложно навсегда — панель молча перестала бы обновляться.
        // Молчание дороже любого из дефолтов, поэтому не-число уступает и
        // просьба панели, и переданный дефолт.
        let requested = panelInterval.flatMap { $0.isFinite ? $0 : nil }
            ?? (defaultAge.isFinite ? defaultAge : 6 * 3_600)
        return min(max(requested, 3_600), 24 * 3_600)
    }

    /// Whether an unattended round may re-fetch this panel — the whole decision
    /// (TLS gate + how often) in one place, so macOS, iOS and the Kotlin port
    /// cannot drift apart on when a list is allowed to change by itself.
    ///
    /// `allowInsecure` marks a round the user asked for. Without it an
    /// unencrypted panel is never due, because its answer is written by
    /// whoever controls the path.
    public func refreshIsDue(
        now: Date,
        panelInterval: TimeInterval?,
        defaultAge: TimeInterval = 6 * 3_600,
        allowInsecure: Bool = false
    ) -> Bool {
        if !tlsProtected && !allowInsecure { return false }
        let fetched = lastUpdated ?? .distantPast
        // Отметка в будущем — часы разъехались (устройство спало через летнее
        // время, бандл приехал с Mac, у которого сбит час). Молча ждать, пока
        // перекос пройдёт, значит остаться без свежих серверов на недели.
        if fetched > now { return true }
        return now.timeIntervalSince(fetched)
            >= refreshMaxAge(panelInterval: panelInterval, defaultAge: defaultAge)
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
