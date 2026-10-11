import Foundation
import LoaderCore
import Observation
import UIKit

/// Servers, subscriptions, the selection and the masking profile — the same
/// `PersistedState` the macOS app keeps, stored in this app's container.
@MainActor
@Observable
final class ServerStore {
    private(set) var state: PersistedState
    var importError: String?
    private(set) var refreshing: Set<UUID> = []
    /// Why a subscription's last refresh failed; a successful one clears it.
    private(set) var refreshErrors: [UUID: String] = [:]

    /// What each subscription's panel says about it (traffic, expiry…).
    private(set) var subscriptionInfo: [UUID: SubscriptionInfo] = [:] {
        didSet {
            saveInfo()
            onInfoChange?()
        }
    }
    /// Reminders follow what the panels say.
    @ObservationIgnored var onInfoChange: (() -> Void)?
    /// Servers that just disappeared. The tunnel keeps carrying traffic
    /// through a deleted exit until the app stops it, and the interface has
    /// moved on to another server by then.
    @ObservationIgnored var onRemoved: (([UUID]) -> Void)?

    // iOS-only settings live outside the state shared with the Mac app.

    /// "Автопереподключение": iOS brings the tunnel back after drops and
    /// network changes (on-demand).
    var autoReconnect: Bool {
        didSet { UserDefaults.standard.set(autoReconnect, forKey: Keys.autoReconnect) }
    }

    /// "Умное переключение": leave a server that stopped carrying traffic.
    var autoSwitch: Bool {
        didSet { UserDefaults.standard.set(autoSwitch, forKey: Keys.autoSwitch) }
    }

    /// "Без рекламы": AdGuard DNS.
    var adBlock: Bool {
        didSet { UserDefaults.standard.set(adBlock, forKey: Keys.adBlock) }
    }

    /// "Раздача через VPN": traffic forwarded from devices attached to the
    /// Personal Hotspot follows the tunnel's routes too.
    var hotspotThroughVPN: Bool {
        didSet { UserDefaults.standard.set(hotspotThroughVPN, forKey: Keys.hotspotThroughVPN) }
    }

    /// "Подбирать маскировку": a server that answers but carries nothing is
    /// retried with stronger masking, and what worked is kept for it — in
    /// `learnedMasking`, the same map the Mac app keeps.
    var adaptiveMasking: Bool {
        didSet { UserDefaults.standard.set(adaptiveMasking, forKey: Keys.adaptiveMasking) }
    }

    /// Starred servers, by identity: a star survives subscription refreshes
    /// and even removing and adding the server again.
    private(set) var favorites: Set<String> {
        didSet { UserDefaults.standard.set(Array(favorites), forKey: Keys.favorites) }
    }

    /// Servers connected lately, newest first.
    private(set) var recents: [UUID] {
        didSet { UserDefaults.standard.set(recents.map(\.uuidString), forKey: Keys.recents) }
    }

    /// Wi‑Fi or mobile data right now: masking is learned per network.
    @ObservationIgnored var network: () -> NetworkKind? = { nil }

    @ObservationIgnored private let persistence = StatePersistence(fileURL: StatePersistence.defaultURL())
    /// A stale-subscription pass in flight; see `refreshStaleSubscriptions`.
    @ObservationIgnored private var refreshingStale = false
    /// Когда подписку последний раз трогали — успешно или нет. `lastUpdated`
    /// ставится только на успехе, и без этой отметки панель, которая отвечает
    /// ошибкой, остаётся «просроченной» навсегда.
    @ObservationIgnored private var refreshAttempts: [UUID: Date] = [:]
    /// Как часто повторять заведомо неудачную автозагрузку: тот же час, что
    /// `refreshIsDue` отводит на самый настойчивый запрос панели.
    private static let failedRetryAge: TimeInterval = 3600

    private enum Keys {
        static let autoReconnect = "autoReconnect"
        static let autoSwitch = "autoSwitch"
        static let adBlock = "adBlock"
        static let hotspotThroughVPN = "hotspotThroughVPN"
        static let adaptiveMasking = "adaptiveMasking"
        static let subscriptionInfo = "subscriptionInfo"
        static let favorites = "favoriteServers"
        static let recents = "recentServers"
    }

    init() {
        state = persistence.load()
        let defaults = UserDefaults.standard
        autoReconnect = defaults.object(forKey: Keys.autoReconnect) as? Bool ?? true
        autoSwitch = defaults.object(forKey: Keys.autoSwitch) as? Bool ?? true
        adBlock = defaults.bool(forKey: Keys.adBlock)
        hotspotThroughVPN = defaults.object(forKey: Keys.hotspotThroughVPN) as? Bool ?? true
        adaptiveMasking = defaults.object(forKey: Keys.adaptiveMasking) as? Bool ?? true
        favorites = Set(defaults.stringArray(forKey: Keys.favorites) ?? [])
        recents = (defaults.stringArray(forKey: Keys.recents) ?? []).compactMap(UUID.init(uuidString:))
        if let data = defaults.data(forKey: Keys.subscriptionInfo),
           let saved = try? JSONDecoder().decode([UUID: SubscriptionInfo].self, from: data) {
            subscriptionInfo = saved
        }
    }

    /// What worked for this server before on this kind of network (else on
    /// any), when it differs from the chosen profile.
    func learnedMasking(for server: ProxyServer) -> MaskingProfile? {
        guard let learned = state.learnedMasking(for: server, on: network()), learned != masking else { return nil }
        return learned
    }

    /// The masking to connect `server` with.
    func masking(for server: ProxyServer) -> MaskingProfile {
        (adaptiveMasking ? learnedMasking(for: server) : nil) ?? masking
    }

    /// Keeps what worked for the network the device is on now; nil forgets.
    func learn(_ profile: MaskingProfile?, for server: ProxyServer) {
        var updated = state
        updated.learnMasking(profile, for: server, on: network())
        guard updated.learnedMasking != state.learnedMasking else { return }
        state = updated
        save()
    }

    /// Servers with masking of their own on this network.
    var learnedCount: Int {
        allServers.filter { learnedMasking(for: $0) != nil }.count
    }

    func isFavorite(_ server: ProxyServer) -> Bool {
        favorites.contains(server.identityKey)
    }

    func toggleFavorite(_ server: ProxyServer) {
        if favorites.remove(server.identityKey) == nil {
            favorites.insert(server.identityKey)
        }
    }

    var favoriteServers: [ProxyServer] {
        allServers.filter(isFavorite)
    }

    /// The last few servers connected, that still exist.
    var recentServers: [ProxyServer] {
        recents.compactMap(state.server(withID:))
    }

    func noteConnected(_ server: ProxyServer) {
        recents = Array(([server.id] + recents.filter { $0 != server.id }).prefix(6))
    }

    /// Everything worth moving to another device (see Transfer.swift).
    func syncBundle() -> SyncBundle {
        var bundle = SyncBundle(state: state, device: UIDevice.current.name)
        bundle.settings?.adBlock = adBlock
        bundle.settings?.autoReconnect = autoReconnect
        bundle.settings?.autoSwitch = autoSwitch
        bundle.settings?.adaptiveMasking = adaptiveMasking
        return bundle
    }

    /// Adds what a bundle from another device brings. The new subscriptions
    /// are fetched after it returns rather than inside it: a stalled panel
    /// would otherwise leave the sheet on a spinner long after the import was
    /// safely saved, and nothing tells the user the data is already in.
    func importSync(_ bundle: SyncBundle, applySettings: Bool) async {
        var updated = state
        let summary = bundle.merge(into: &updated, applySettings: applySettings)
        // Отменено, пока сливались поля: ничего не записываем и не стартуем
        // загрузку подписок — пользователь ушёл из шторки.
        guard !Task.isCancelled else { return }
        state = updated
        if applySettings, let settings = bundle.settings {
            if let value = settings.adBlock { adBlock = value }
            if let value = settings.autoReconnect { autoReconnect = value }
            if let value = settings.autoSwitch { autoSwitch = value }
            if let value = settings.adaptiveMasking { adaptiveMasking = value }
        }
        save()
        let fresh = Set(summary.newSubscriptions.map(\.url))
        let ids = state.subscriptions.filter { fresh.contains($0.url) }.map(\.id)
        guard !ids.isEmpty else { return }
        Task { [weak self] in
            for id in ids { await self?.refresh(id) }
        }
    }

    /// The panel's own name for a subscription, else the one it was added with.
    func displayName(of subscription: Subscription) -> String {
        subscriptionInfo[subscription.id]?.title ?? subscription.name
    }

    /// The subscription a server came from; nil for manually added ones.
    func subscription(containing serverID: UUID) -> Subscription? {
        state.subscriptions.first { $0.servers.contains { $0.id == serverID } }
    }

    var allServers: [ProxyServer] { state.allServers }

    var selected: ProxyServer? {
        // With nothing selected yet, fall back to a server the phone can
        // actually run: handing back a Hysteria 1 entry as "selected" makes
        // every screen that trusts this property name an exit that cannot
        // connect.
        state.selectedServerID.flatMap(state.server(withID:))
            ?? state.allServers.first(where: \.runsOnIOS)
            ?? state.allServers.first
    }

    var masking: MaskingProfile {
        get { state.maskingProfile }
        set {
            state.maskingProfile = newValue
            save()
        }
    }

    /// "Kill switch": nothing leaves outside the tunnel.
    var killSwitch: Bool {
        get { state.killSwitchEnabled }
        set {
            state.killSwitchEnabled = newValue
            save()
        }
    }

    var splitTunnel: SplitTunnelRules {
        get { state.splitTunnel }
        set {
            state.splitTunnel = newValue
            save()
        }
    }

    var autoRefreshSubscriptions: Bool {
        get { state.subscriptionAutoRefresh }
        set {
            state.subscriptionAutoRefresh = newValue
            save()
        }
    }

    func select(_ id: UUID) {
        // A selection that names a server which doesn't exist survives in
        // state.json and travels to the Mac app in a sync bundle.
        guard state.server(withID: id) != nil else { return }
        state.selectedServerID = id
        save()
    }

    /// Share links (one per line, or a base64 blob) or a subscription URL.
    /// Returns whether anything was added.
    func importText(_ text: String) async -> Bool {
        importError = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return await addSubscription(url: trimmed)
        }
        let result = SubscriptionParser.parse(trimmed)
        guard let first = result.servers.first else {
            importError = result.failures.first.map { "Не удалось разобрать ссылку: \($0.error)" }
                ?? "Здесь нет ссылок на серверы"
            return false
        }
        // Re-importing a list the user already has used to double every row:
        // same server, new id, and each copy probed separately.
        let known = Set(state.allServers.map(\.identityKey))
        let fresh = result.servers.filter { !known.contains($0.identityKey) }
        guard !fresh.isEmpty else {
            importError = "Все эти серверы уже в списке"
            return false
        }
        state.servers.append(contentsOf: fresh)
        if state.selectedServerID == nil { state.selectedServerID = first.id }
        save()
        return true
    }

    func refresh(_ id: UUID) async {
        guard var subscription = state.subscriptions.first(where: { $0.id == id }),
              !refreshing.contains(id) else { return }
        refreshing.insert(id)
        defer { refreshing.remove(id) }
        refreshAttempts[id] = Date()
        // Shown under the subscription, not in the import sheet: the refresh
        // may run in the background while the user adds something else.
        let result = await fetch(&subscription)
        if let info = result.info {
            subscriptionInfo[id] = info
        }
        if let problem = result.problem {
            refreshErrors[id] = problem
            return
        }
        refreshErrors[id] = nil
        guard let index = state.subscriptions.firstIndex(where: { $0.id == id }) else { return }
        state.subscriptions[index] = subscription
        fixSelection()
        // Панель, которая крутит ключи на каждой выдаче, оставляет после себя
        // записи маскировки у уже несуществующих серверов: на удалениях подписки
        // они вычищаются, на обновлении — нет, и `state.json` растёт с каждым
        // раундом.
        pruneLearned()
        save()
    }

    /// Refreshes subscriptions not updated for 6 hours, or as often as their
    /// panel asks — at launch, on return to the app and periodically while
    /// it runs.
    func refreshStaleSubscriptions(defaultAge: TimeInterval = 6 * 3600) async {
        // One pass at a time. Returning to the foreground starts another, and
        // so does the half-hour timer: over a dozen panels that are slow or
        // unreachable the passes stacked, each holding 20 s timeouts, and the
        // spinners in the list stopped meaning "the app is working".
        guard state.subscriptionAutoRefresh, !refreshingStale else { return }
        refreshingStale = true
        defer { refreshingStale = false }
        for subscription in state.subscriptions {
            // Проход запускается сам — при старте, возврате в foreground и по
            // таймеру, значит никто не увидит подмену списка. Решение целиком
            // в `refreshIsDue`: панели без TLS пропускаются, а интервал
            // берётся тот, что попросила панель, но не чаще раза в час и не
            // реже раза в сутки.
            //
            // Кроме одного случая: `lastUpdated` ставится только на успехе, и
            // панель, которая стабильно отвечает ошибкой (истёкший токен, 403,
            // мёртвый хост), остаётся «просроченной» навсегда. Без этой
            // паузы каждый возврат на экран — новый запрос с 20-секундным
            // таймаутом: трафик, батарея и бан со стороны панели.
            if refreshErrors[subscription.id] != nil,
               let at = refreshAttempts[subscription.id],
               Date().timeIntervalSince(at) < Self.failedRetryAge { continue }
            if subscription.refreshIsDue(
                now: Date(),
                panelInterval: subscriptionInfo[subscription.id]?.updateInterval,
                defaultAge: defaultAge
            ) {
                await refresh(subscription.id)
            }
        }
    }

    func refreshAll() async {
        for subscription in state.subscriptions {
            await refresh(subscription.id)
        }
    }

    func removeServers(at offsets: IndexSet) {
        removeServers(ids: offsets.map { state.servers[$0].id })
    }

    /// For lists that show a filtered slice: the offsets there don't match
    /// the stored order.
    func removeServers(ids: [UUID]) {
        state.servers.removeAll { ids.contains($0.id) }
        fixSelection()
        pruneLearned()
        save()
        onRemoved?(ids)
    }

    func removeSubscription(_ id: UUID) {
        let removed = state.subscriptions.first { $0.id == id }?.servers.map(\.id) ?? []
        state.subscriptions.removeAll { $0.id == id }
        refreshErrors[id] = nil
        subscriptionInfo[id] = nil
        refreshAttempts[id] = nil
        fixSelection()
        pruneLearned()
        save()
        onRemoved?(removed)
    }

    /// Learned-masking entries for servers that no longer exist. The map is
    /// keyed by the server's identity rather than its id, panels re-issue
    /// servers under new names on every refresh, and the whole state is
    /// re-encoded on each save — without this it only ever grows.
    private func pruneLearned() {
        let live = Set(state.allServers.map(\.identityKey))
        // Избранное и выбранный сервер не вычёркиваются: у панели, которая
        // крутит ключи на каждой выдаче, идентичность сервера меняется, и
        // вместе со «старой» записью стиралась бы и маскировка, которая единственная
        // пропускала трафик через DPI. Звезда переживает смену ключа намеренно —
        // и подобранная маскировка должна переживать её так же.
        let chosen = state.allServers.filter { $0.id == state.selectedServerID }.map(\.identityKey)
        let keep = favorites.union(chosen)
        let kept = state.learnedMasking.filter {
            let key = PersistedState.serverKey(ofLearnedMaskingKey: $0.key)
            return live.contains(key) || keep.contains(key)
        }
        if kept.count != state.learnedMasking.count { state.learnedMasking = kept }
    }

    // MARK: - Private

    private func addSubscription(url: String) async -> Bool {
        // Та же ссылка дважды — два комплекта строк: у подписок разные UUID,
        // поэтому каждый сервер прощупывается дважды за раунд, обе подписки
        // обновляются отдельно, а дубликаты уезжают дальше в sync-бандле.
        // Правило — то же, по которому подписки сводит `SyncBundle.merge`.
        let address = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if state.subscriptions.contains(where: { Self.samePanel($0.url, address) }) {
            importError = "Такая подписка уже добавлена"
            return false
        }
        var subscription = Subscription(name: URL(string: url)?.host ?? url, url: url)
        let result = await fetch(&subscription)
        if let problem = result.problem {
            importError = problem
            return false
        }
        if let info = result.info {
            subscriptionInfo[subscription.id] = info
        }
        state.subscriptions.append(subscription)
        if state.selectedServerID == nil { state.selectedServerID = subscription.servers.first?.id }
        save()
        return true
    }

    /// Как `SyncBundle.normalized`: регистр хоста не значим, висящий слэш — тоже.
    private static func samePanel(_ left: String, _ right: String) -> Bool {
        func plain(_ url: String) -> String {
            url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return plain(left) == plain(right)
    }

    /// Fetches and parses a subscription. On failure returns why, and its
    /// servers stay as they were.
    private func fetch(_ subscription: inout Subscription) async -> (problem: String?, info: SubscriptionInfo?) {
        guard let url = URL(string: subscription.url),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            // Адрес подписки может прийти и из чужого переноса, и из QR: без
            // проверки схемы телефон дёргал бы `file://` или что похуже, а
            // панель получает право выбрать схему целиком.
            return ("Подписка — должен быть адрес http:// или https://", nil)
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        // Panels (3x-ui, Marzban, …) answer unknown clients with an HTML page;
        // v2rayN is the most widely allowed client name.
        request.setValue("v2rayN/6.26", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            if let http, !(200...299).contains(http.statusCode) {
                return ("Подписка ответила ошибкой HTTP \(http.statusCode)", nil)
            }
            // A panel is not supposed to answer with 40 MB: the body is copied
            // into a String and every line parsed before anything reaches the
            // list. Bound it before that.
            if data.count > 4_000_000 {
                return ("Ответ подписки слишком большой (\(Bytes.text(Int64(data.count))))", nil)
            }
            // Само парсение — уже не на главном актёре: панель на несколько
            // мегабайт — это тысячи ссылок, а `fetch` стартует из `.task` и из
            // возврата на экран, где каждый блок интерфейса ждёт главного
            // актёра.
            let body = data
            let result = await Task.detached(priority: .userInitiated) {
                SubscriptionParser.parse(String(decoding: body, as: UTF8.self))
            }.value
            // An error page or a captive portal is a failed fetch, not an
            // empty server list — keep what was there.
            let info = http.flatMap { SubscriptionInfo.parse($0) }
            guard !result.servers.isEmpty else {
                // An expired subscription often answers with an empty list:
                // its headers still say why.
                if let info, let expiry = info.expiryText, (info.expires ?? .distantFuture) < .now {
                    return (expiry, info)
                }
                return ("В подписке нет подходящих серверов", info)
            }
            // Тот же потолок, что у переноса, но на пути, который выбирает сама
            // панель: без него несколько тысяч ссылок оседают в хранилище, и
            // каждое сохранение `state.json` перекодировывает его целиком на
            // главном потоке.
            guard result.servers.count <= 2000 else {
                return ("Подписка выдала \(result.servers.count) серверов — это слишком много, "
                        + "список не заменён", info)
            }
            subscription.servers = SubscriptionParser.carryingIDs(from: subscription.servers, into: result.servers)
            subscription.lastUpdated = Date()
            return (nil, info)
        } catch {
            return ("Не удалось загрузить подписку: \(error.localizedDescription)", nil)
        }
    }

    private func fixSelection() {
        if let id = state.selectedServerID, state.server(withID: id) == nil {
            state.selectedServerID = state.allServers.first?.id
        }
    }

    private func saveInfo() {
        if let data = try? JSONEncoder().encode(subscriptionInfo) {
            UserDefaults.standard.set(data, forKey: Keys.subscriptionInfo)
        }
    }

    private func save() {
        do {
            try persistence.save(state)
        } catch {
            importError = "Не удалось сохранить серверы: \(error.localizedDescription)"
        }
    }
}
