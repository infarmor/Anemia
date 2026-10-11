import Foundation
import LoaderCore
import Observation
import UIKit
import UserNotifications

/// "Напоминать о подписке": a notification three days and one day before a
/// subscription runs out, and once when 90 % of its traffic is used.
///
/// Without a prompt out of nowhere: notifications start out quiet (iOS's
/// provisional permission, straight to Notification Center); the switch in
/// Settings asks for banners.
@MainActor
@Observable
final class SubscriptionAlerts {
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            scheduleSoon()
        }
    }

    private(set) var permission: UNAuthorizationStatus = .notDetermined

    @ObservationIgnored private let store: ServerStore
    /// Subscriptions that got the low-traffic note for their current allowance.
    @ObservationIgnored private var warned: Set<UUID>
    /// Expiry reminders handed to iOS, by reminder and expiry, with when
    /// they fire: one already due goes out once, not with every refresh.
    @ObservationIgnored private var handed: [String: Date]
    @ObservationIgnored private var pending: Task<Void, Never>?
    /// Номер текущего `reschedule()`. Его зовут из трёх мест одновременно
    /// (старт приложения, `askForBanners()`, отложенный `scheduleSoon()`), и
    /// два перекрывшихся прохода успевали оба прочитать `warned`, оба
    /// просчитать план и оба добавить немедленное напоминание — у него
    /// идентификатор `reminder.id`, а iOS снимает дубликаты только среди
    /// *ожидающих* запросов; уже доставленный можно добавить снова.
    @ObservationIgnored private var runID = 0
    private static let prefix = "anemia.sub."

    private enum Keys {
        static let enabled = "subscriptionReminders"
        static let warned = "subscriptionTrafficWarned"
        static let handed = "subscriptionRemindersHanded"
    }

    init(store: ServerStore) {
        self.store = store
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
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.reschedule()
        }
    }

    /// Последний ли это запланированный проход.
    private func isCurrent(_ run: Int) -> Bool { run == runID }

    func reschedule() async {
        runID += 1
        let mine = runID
        let center = UNUserNotificationCenter.current()
        let ours = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
        // После каждого `await` — проверка, что этот проход ещё последний:
        // иначе два перекрывающихся `reschedule()` оба снимают «свои» ожидающие
        // запросы по устаревшему списку и оба добавляют срочное напоминание, а
        // доставленное не-pending уведомление по тому же `identifier` iOS не
        // схлопывает — баннер показывается дважды.
        guard isCurrent(mine) else { return }
        center.removePendingNotificationRequests(withIdentifiers: ours)
        await refreshPermission()
        guard isCurrent(mine), isEnabled else { return }

        // A renewed allowance may be warned about again. The pruning has to
        // reach the disk here: with nothing left to schedule, the run ends
        // below without writing, and the next launch reads the old id back —
        // the traffic warning would never fire again.
        warned = warned.filter { (store.subscriptionInfo[$0]?.usedFraction ?? 0) >= 0.9 }
        UserDefaults.standard.set(warned.map(\.uuidString), forKey: Keys.warned)
        let now = Date()
        // Pruned and persisted BEFORE the plan is looked at: with nothing left
        // to schedule the run used to end at the guard below without writing,
        // so keys of long-gone expiries stayed in defaults forever — one per
        // (subscription, date) the app ever reminded about.
        handed = handed.filter { now.timeIntervalSince($0.value) < 8 * 86_400 }
        UserDefaults.standard.set(handed, forKey: Keys.handed)
        let subscriptions = store.state.subscriptions.compactMap { subscription in
            store.subscriptionInfo[subscription.id].map {
                (id: subscription.id, name: store.displayName(of: subscription), info: $0)
            }
        }
        let plan = SubscriptionReminders.plan(subscriptions, alreadyWarned: warned)
        guard !plan.isEmpty, await authorize() else { return }
        guard isCurrent(mine) else { return }
        for reminder in plan {
            // Не `return`: проход, снятый новым на середине списка, всё равно
            // обязан записать уже принятые отметки, иначе напоминание, которое
            // он успел поставить, снова встанет в очередь.
            guard isCurrent(mine) else { break }
            var trigger: UNNotificationTrigger?
            var key: String?
            var fire = Date.distantPast
            var traffic: UUID?
            if let date = reminder.date {
                let candidate = "\(reminder.id)@\(Int(date.timeIntervalSince1970))"
                let morning = Self.morning(of: date)
                if morning.timeIntervalSince(now) > 5 {
                    let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: morning)
                    trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
                } else if handed[candidate] != nil {
                    continue
                }
                key = candidate
                fire = morning
            } else {
                traffic = reminder.subscriptionID
            }
            // «Отдано» — только после принятого запроса. Отметка ставилась
            // заранее, и сорванный `add` (`try?` проглатывал ошибку, а iOS
            // ограничивает число ожидающих уведомлений) терял напоминание
            // навсегда: дата уже в прошлом, ключ в `handed` — и ветка выше
            // больше никогда его не планировала.
            guard (try? await center.add(request(for: reminder, trigger: trigger))) != nil else { continue }
            if let key { handed[key] = fire }
            // То же с предупреждением о трафике: внесённое в `warned` до
            // принятого запроса больше никогда не повторялось.
            if let traffic { warned.insert(traffic) }
        }
        UserDefaults.standard.set(handed, forKey: Keys.handed)
        UserDefaults.standard.set(warned.map(\.uuidString), forKey: Keys.warned)
    }

    /// Banners and sound: the one system prompt, asked for from Settings.
    func askForBanners() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await refreshPermission()
        await reschedule()
    }

    func refreshPermission() async {
        permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: - Private

    private func authorize() async -> Bool {
        switch permission {
        case .authorized, .provisional, .ephemeral:
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

    private func request(for reminder: SubscriptionReminders.Reminder,
                         trigger: UNNotificationTrigger?) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        switch reminder.kind {
        case .expiresSoon(let days):
            content.title = "Подписка «\(reminder.name)» заканчивается"
            content.body = days == 1
                ? "Остался один день — продлите её, чтобы VPN не отключился."
                : "Осталось \(days) \(WorldMap.plural(days, "день", "дня", "дней")) — продлите её заранее."
        case .lowTraffic(let remaining, let fraction):
            content.title = "Подписка «\(reminder.name)»: трафик на исходе"
            content.body = "Использовано \(Int((fraction * 100).rounded(.down)))% — осталось \(Bytes.text(remaining))."
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
