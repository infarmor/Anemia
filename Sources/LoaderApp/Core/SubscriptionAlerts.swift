import Foundation
import LoaderCore
@preconcurrency import UserNotifications

/// "Remind before a subscription ends": a notification three days and one
/// day before a subscription runs out, and once when 90 % of its traffic is
/// used (LoaderCore/SubscriptionReminders).
///
/// No prompt out of nowhere: notifications start out quiet (provisional —
/// straight to Notification Center); Settings offers to show them as banners.
@MainActor
final class SubscriptionAlerts: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            scheduleSoon()
        }
    }

    @Published private(set) var permission: UNAuthorizationStatus = .notDetermined

    /// What the reminders are planned from: (subscription, its name, what
    /// the panel says). Set by AppState.
    var source: () -> [(id: UUID, name: String, info: SubscriptionInfo)] = { [] }

    /// Subscriptions that got the low-traffic note for their current allowance.
    private var warned: Set<UUID>
    /// Expiry reminders handed to the system, by reminder and expiry, with
    /// when they fire: one already due goes out once, not with every refresh.
    private var handed: [String: Date]
    private var pending: Task<Void, Never>?
    private static let prefix = "anemia.sub."
    /// The notification center exists for an app bundle only: a test
    /// process asking for it crashes.
    private static let available = Bundle.main.bundleURL.pathExtension == "app"

    private enum Keys {
        static let enabled = "subscriptionReminders"
        static let warned = "subscriptionTrafficWarned"
        static let handed = "subscriptionRemindersHanded"
    }

    init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        warned = Set((defaults.stringArray(forKey: Keys.warned) ?? []).compactMap(UUID.init(uuidString:)))
        handed = (defaults.dictionary(forKey: Keys.handed) as? [String: Date]) ?? [:]
    }

    /// After subscriptions changed: waits a moment, so a refresh of all of
    /// them reschedules once.
    func scheduleSoon() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.reschedule()
        }
    }

    func reschedule() async {
        guard Self.available else { return }
        let center = UNUserNotificationCenter.current()
        let ours = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
        center.removePendingNotificationRequests(withIdentifiers: ours)
        await refreshPermission()
        guard isEnabled else { return }

        let subscriptions = source()
        // A renewed allowance may be warned about again.
        let fractions = Dictionary(subscriptions.map { ($0.id, $0.info.usedFraction ?? 0) }) { first, _ in first }
        warned = warned.filter { (fractions[$0] ?? 0) >= 0.9 }
        let plan = SubscriptionReminders.plan(subscriptions, alreadyWarned: warned)
        guard !plan.isEmpty, await authorize() else { return }
        let now = Date()
        for reminder in plan {
            var trigger: UNNotificationTrigger?
            if let date = reminder.date {
                let key = "\(reminder.id)@\(Int(date.timeIntervalSince1970))"
                let fire = Self.morning(of: date)
                if fire.timeIntervalSince(now) > 5 {
                    let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                    trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
                } else if handed[key] != nil {
                    continue
                }
                handed[key] = fire
            } else {
                warned.insert(reminder.subscriptionID)
            }
            try? await center.add(Self.request(for: reminder, trigger: trigger))
        }
        handed = handed.filter { now.timeIntervalSince($0.value) < 8 * 86_400 }
        UserDefaults.standard.set(handed, forKey: Keys.handed)
        UserDefaults.standard.set(warned.map(\.uuidString), forKey: Keys.warned)
    }

    /// Banners and sound: the one system prompt, asked for from Settings.
    func askForBanners() async {
        guard Self.available else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await reschedule()
    }

    func refreshPermission() async {
        guard Self.available else { return }
        permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: - Private

    private func authorize() async -> Bool {
        switch permission {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge, .provisional])) ?? false
            await refreshPermission()
            return granted
        default:
            return false
        }
    }

    private static func request(for reminder: SubscriptionReminders.Reminder,
                                trigger: UNNotificationTrigger?) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        switch reminder.kind {
        case .expiresSoon(let days):
            content.title = "“\(reminder.name)” ends \(days == 1 ? "tomorrow" : "in \(days) days")"
            content.body = "Renew the subscription to keep the VPN running."
        case .lowTraffic(let remaining, let fraction):
            content.title = "“\(reminder.name)” is running out of traffic"
            content.body = "\(Int((fraction * 100).rounded()))% used — \(Format.bytes(remaining)) left."
        }
        content.sound = .default
        content.threadIdentifier = "subscriptions"
        return UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger)
    }

    /// Reminders go out in the morning of the day they're due (right away,
    /// nil trigger, when that has passed).
    private static func morning(of date: Date) -> Date {
        Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: date) ?? date
    }
}

// The panel's word about a subscription, for the Mac's English UI.
extension SubscriptionInfo {
    /// "42.1 GB of 100 GB left", "Unlimited · 3.2 GB used".
    var trafficText: String? {
        if let remaining, let total {
            return "\(Format.bytes(remaining)) of \(Format.bytes(total)) left"
        }
        if let used {
            return "Unlimited · \(Format.bytes(used)) used"
        }
        return nil
    }

    /// "Valid until Oct 12, 2026", "Ends tomorrow", "Expired".
    var expiryText: String? {
        guard let expires else { return nil }
        let interval = expires.timeIntervalSinceNow
        if interval <= 0 { return "Expired" }
        if interval < 3 * 86_400 {
            return "Ends \(expires.formatted(.relative(presentation: .named)))"
        }
        return "Valid until \(expires.formatted(date: .abbreviated, time: .omitted))"
    }
}
