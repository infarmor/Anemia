import Foundation

/// How much went through the VPN, per day and per server, from a running
/// engine's cumulative counters. The counters restart with every engine run,
/// so each reading is compared with the previous one of the same run.
public struct TrafficLedger: Codable, Equatable, Sendable {
    public struct Day: Codable, Equatable, Sendable, Identifiable {
        /// "2026-09-17", a local calendar day.
        public var id: String
        public var received: Int64 = 0
        public var sent: Int64 = 0
        /// Seconds connected.
        public var time: TimeInterval = 0

        public var total: Int64 { received + sent }

        public init(id: String, received: Int64 = 0, sent: Int64 = 0, time: TimeInterval = 0) {
            self.id = id
            self.received = received
            self.sent = sent
            self.time = time
        }
    }

    public struct ServerTotal: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        public var received: Int64 = 0
        public var sent: Int64 = 0
        public var lastUsed: Date = .distantPast

        public var total: Int64 { received + sent }
    }

    public private(set) var days: [String: Day] = [:]
    public private(set) var servers: [UUID: ServerTotal] = [:]
    private var lastRun: Run?
    private var lastReading: Date?

    private struct Run: Codable, Equatable, Sendable {
        var startedAt: Date
        var received: Int64
        var sent: Int64
    }

    /// Days kept; older ones go.
    public static let keepDays = 120
    /// How many server totals to keep: the list is a "top" board, and the
    /// entries of deleted servers are worth nothing but disk.
    public static let keepServers = 200
    /// A gap between readings longer than this means nobody was counting:
    /// the connected time doesn't include it.
    public static let maxStep: TimeInterval = 10

    public init() {}

    // MARK: - Recording

    /// One reading of a run's counters (bytes since `runStartedAt`).
    public mutating func record(runStartedAt: Date, received: Int64, sent: Int64,
                                server: (id: UUID, name: String)?, at now: Date = Date(),
                                timeZone: TimeZone = .current) {
        var newReceived = received
        var newSent = sent
        if let lastRun, lastRun.startedAt == runStartedAt {
            newReceived = max(received - lastRun.received, 0)
            newSent = max(sent - lastRun.sent, 0)
        }
        lastRun = Run(startedAt: runStartedAt, received: received, sent: sent)
        let step = lastReading.map { min(max(now.timeIntervalSince($0), 0), Self.maxStep) } ?? 0
        lastReading = now

        let key = Self.dayKey(now, timeZone: timeZone)
        var day = days[key] ?? Day(id: key)
        day.received += newReceived
        day.sent += newSent
        day.time += step
        days[key] = day

        if let server, newReceived + newSent > 0 {
            var total = servers[server.id] ?? ServerTotal(id: server.id, name: server.name)
            total.name = server.name
            total.received += newReceived
            total.sent += newSent
            total.lastUsed = now
            servers[server.id] = total
        }
        prune()
    }

    /// The engine stopped: the next reading starts a new connected stretch.
    public mutating func stopped() {
        lastReading = nil
    }

    public mutating func reset() {
        days = [:]
        servers = [:]
    }

    /// Drops the per-server totals of servers that no longer exist. `days` is
    /// pruned by age, but `servers` is keyed by `ProxyServer.id`, which a
    /// re-imported subscription regenerates — without this the "top servers"
    /// list keeps deleted exits forever and the encoded blob only grows.
    public mutating func forget(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids { servers[id] = nil }
    }

    /// Keeps only the most recently used server totals.
    private mutating func prune() {
        if days.count > Self.keepDays {
            let keep = Set(days.keys.sorted().suffix(Self.keepDays))
            days = days.filter { keep.contains($0.key) }
        }
        if servers.count > Self.keepServers {
            let keep = Set(servers.values.sorted { Self.newestFirst($0, $1) }
                .prefix(Self.keepServers).map { $0.id })
            servers = servers.filter { keep.contains($0.key) }
        }
    }

    // MARK: - Reading

    /// The last `count` days, oldest first, empty days filled in.
    public func recentDays(_ count: Int, now: Date = Date(), timeZone: TimeZone = .current) -> [Day] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        return (0..<count).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { date in
                let key = Self.dayKey(date, timeZone: timeZone)
                return days[key] ?? Day(id: key)
            }
        }
    }

    public func today(now: Date = Date(), timeZone: TimeZone = .current) -> Day {
        let key = Self.dayKey(now, timeZone: timeZone)
        return days[key] ?? Day(id: key)
    }

    /// The calendar month of `now`, summed.
    public func month(now: Date = Date(), timeZone: TimeZone = .current) -> Day {
        let prefix = String(Self.dayKey(now, timeZone: timeZone).prefix(7))
        return days.values.filter { $0.id.hasPrefix(prefix) }.reduce(into: Day(id: prefix)) { sum, day in
            sum.received += day.received
            sum.sent += day.sent
            sum.time += day.time
        }
    }

    public var topServers: [ServerTotal] {
        servers.values.sorted { a, b in
            a.total == b.total ? a.name < b.name : a.total > b.total
        }
    }

    /// Ties need a tie-break: `sorted` is not stable, and a dictionary's order is
    /// random per launch, so a "top" board whose entries share a total used to
    /// shuffle every time the app opened.
    static func newestFirst(_ a: ServerTotal, _ b: ServerTotal) -> Bool {
        a.lastUsed == b.lastUsed ? a.id.uuidString < b.id.uuidString : a.lastUsed > b.lastUsed
    }

    // MARK: - Days

    public static func dayKey(_ date: Date, timeZone: TimeZone = .current) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day())
    }

    public static func date(ofDay key: String, timeZone: TimeZone = .current) -> Date? {
        try? Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day().parse(key)
    }
}
