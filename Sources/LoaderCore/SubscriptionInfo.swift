import Foundation

/// What a panel (3x-ui, Marzban, Remnawave…) says about a subscription in the
/// response headers: traffic, expiry, its own name, where to get help. Both
/// apps read it; each words it in its own language.
public struct SubscriptionInfo: Codable, Equatable, Sendable {
    public var title: String?
    public var uploaded: Int64?
    public var downloaded: Int64?
    /// Traffic allowance, bytes; nil or 0 means unlimited.
    public var total: Int64?
    public var expires: Date?
    /// How often the panel wants the list refreshed.
    public var updateInterval: TimeInterval?
    public var supportURL: URL?
    public var webPageURL: URL?
    public var announcement: String?

    public init(title: String? = nil, uploaded: Int64? = nil, downloaded: Int64? = nil, total: Int64? = nil,
                expires: Date? = nil, updateInterval: TimeInterval? = nil, supportURL: URL? = nil,
                webPageURL: URL? = nil, announcement: String? = nil) {
        self.title = title
        self.uploaded = uploaded
        self.downloaded = downloaded
        self.total = total
        self.expires = expires
        self.updateInterval = updateInterval
        self.supportURL = supportURL
        self.webPageURL = webPageURL
        self.announcement = announcement
    }

    public var used: Int64? {
        guard uploaded != nil || downloaded != nil else { return nil }
        // A panel may answer with sizes near Int64.max; `+` trapping on
        // overflow crashed the app while it rendered the traffic row.
        let (value, overflow) = (uploaded ?? 0).addingReportingOverflow(downloaded ?? 0)
        return overflow ? .max : value
    }

    public var isUnlimited: Bool { (total ?? 0) <= 0 }

    public var remaining: Int64? {
        guard let total, total > 0 else { return nil }
        // Negative counters are a lie, not a credit: clamping them first keeps
        // the subtraction in range instead of overflowing upward.
        let usedValue = max(used ?? 0, 0)
        let (value, overflow) = total.subtractingReportingOverflow(usedValue)
        return overflow ? 0 : max(value, 0)
    }

    /// 0…1 of the allowance used; nil when unlimited.
    ///
    /// Clamped at both ends, not just the top. `used` refuses to overflow and
    /// `remaining` treats negative counters as a lie — this is the value the UI
    /// multiplies by 100 and hands to `Int(...)`, and a panel answering
    /// `upload=-99999999999999999999` (which the parser bounds to `Int64.min`)
    /// made the fraction about −9.2e18, so the traffic row trapped instead of
    /// reading 0 %.
    public var usedFraction: Double? {
        guard let total, total > 0 else { return nil }
        return max(0, min(Double(used ?? 0) / Double(total), 1))
    }

    /// Worth a word: nearly out of time (3 days) or traffic (90 %).
    ///
    /// `>=`, the same comparison the reminder planner uses
    /// (`SubscriptionReminders.plan`) and the same one `SubscriptionAlerts`
    /// uses to decide whether a "already warned" mark still applies. With `>`
    /// here, a subscription sitting at exactly 90 % was marked as warned by the
    /// filter and then never planned a reminder — so when it climbed past 90 %
    /// there was nothing left to fire, and the badge stayed grey for a plan
    /// nobody could see.
    public func needsAttention(now: Date = Date()) -> Bool {
        if let expires, expires.timeIntervalSince(now) < 3 * 86_400 { return true }
        if let fraction = usedFraction, fraction >= 0.9 { return true }
        return false
    }

    // MARK: - Parsing

    /// From a subscription response; nil when the panel said nothing.
    public static func parse(_ response: HTTPURLResponse) -> SubscriptionInfo? {
        parse { response.value(forHTTPHeaderField: $0) }
    }

    /// From raw headers, any capitalization.
    public static func parse(headers: [String: String]) -> SubscriptionInfo? {
        let lowered = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        return parse { lowered[$0.lowercased()] }
    }

    private static func parse(_ header: (String) -> String?) -> SubscriptionInfo? {
        func value(_ name: String) -> String? {
            guard let raw = header(name)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            return raw
        }
        var info = SubscriptionInfo()
        if let userinfo = value("subscription-userinfo") {
            for pair in userinfo.split(separator: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, let number = Double(parts[1]), number.isFinite else { continue }
                // `Int(Double)` traps before any clamping when the value is
                // past Int64.max — a panel answering `total=99999999999999999999`
                // crashed the app mid-refresh. Bound the Double first.
                let rounded = number.rounded()
                let amount: Int64
                if rounded >= Double(Int64.max) { amount = .max }
                else if rounded < Double(Int64.min) { amount = .min }
                else { amount = Int64(rounded) }
                switch parts[0].lowercased() {
                case "upload": info.uploaded = amount
                case "download": info.downloaded = amount
                case "total": info.total = amount
                case "expire": info.expires = amount > 0 ? Date(timeIntervalSince1970: TimeInterval(amount)) : nil
                default: break
                }
            }
        }
        info.title = value("profile-title").map(text)
        // `hours > 0` alone lets `inf` through (`Double("1e400")` is infinity),
        // and one infinity in this dictionary is enough to break persistence:
        // the `try? JSONEncoder().encode([UUID: SubscriptionInfo])` that macOS
        // and iOS use throws on a non-finite Double and silently drops *every*
        // panel's headers — quota, expiry and the requested interval included.
        if let hours = value("profile-update-interval").flatMap(Double.init), hours > 0,
            (hours * 3600).isFinite {
            info.updateInterval = hours * 3600
        }
        info.supportURL = value("support-url").flatMap(link)
        info.webPageURL = value("profile-web-page-url").flatMap(link)
        info.announcement = value("announce").map(text)
        return info == SubscriptionInfo() ? nil : info
    }

    /// "base64:…" or plain text, sometimes percent-encoded; header values
    /// arrive decoded as Latin-1 while panels send UTF-8.
    public static func text(_ raw: String) -> String {
        let value = repairedUTF8(raw)
        if value.lowercased().hasPrefix("base64:") {
            var payload = String(value.dropFirst(7))
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
            if let data = Data(base64Encoded: payload), let decoded = String(data: data, encoding: .utf8) {
                return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return value.removingPercentEncoding ?? value
    }

    private static func link(_ raw: String) -> URL? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              ["https", "http", "tg"].contains(scheme) else { return nil }
        return url
    }

    private static func repairedUTF8(_ value: String) -> String {
        guard value.unicodeScalars.contains(where: { $0.value > 0x7F }),
              value.unicodeScalars.allSatisfy({ $0.value <= 0xFF }),
              let bytes = value.data(using: .isoLatin1),
              let repaired = String(data: bytes, encoding: .utf8)
        else { return value }
        return repaired
    }
}

/// When to remind about a subscription running out. The apps turn these
/// into local notifications in their own words.
public enum SubscriptionReminders {
    public struct Reminder: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// Days left when it fires.
            case expiresSoon(days: Int)
            /// Allowance left, bytes, and the share of it used.
            case lowTraffic(remaining: Int64, usedFraction: Double)
        }

        /// Stable per subscription and kind, so rescheduling replaces.
        public var id: String
        public var subscriptionID: UUID
        public var name: String
        public var kind: Kind
        /// nil: now.
        public var date: Date?
    }

    /// Three days and one day before expiry (those still ahead), and a
    /// low-traffic note once 90 % is used — `alreadyWarned` holds the
    /// subscriptions that got that note, so it comes once per allowance.
    public static func plan(_ subscriptions: [(id: UUID, name: String, info: SubscriptionInfo)],
                            alreadyWarned: Set<UUID>, now: Date = Date()) -> [Reminder] {
        var reminders: [Reminder] = []
        for subscription in subscriptions {
            let info = subscription.info
            if let expires = info.expires, expires > now {
                for days in [3, 1] {
                    let date = expires.addingTimeInterval(-Double(days) * 86_400)
                    guard date > now else { continue }
                    reminders.append(Reminder(id: "anemia.sub.\(subscription.id.uuidString).expiry.\(days)",
                                              subscriptionID: subscription.id, name: subscription.name,
                                              kind: .expiresSoon(days: days), date: date))
                }
            }
            if let fraction = info.usedFraction, fraction >= 0.9, let remaining = info.remaining,
               !alreadyWarned.contains(subscription.id) {
                reminders.append(Reminder(id: "anemia.sub.\(subscription.id.uuidString).traffic",
                                          subscriptionID: subscription.id, name: subscription.name,
                                          kind: .lowTraffic(remaining: remaining, usedFraction: fraction), date: nil))
            }
        }
        return reminders
    }
}
