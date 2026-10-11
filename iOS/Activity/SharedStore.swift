import Foundation

/// Widget kinds the app reloads.
enum WidgetKinds {
    static let status = "Anemia.Status"
    static let control = "Anemia.VPN"
}

/// Что приложение говорит виджетам: последнее известное состояние туннеля.
struct WidgetSnapshot: Codable, Equatable {
    var isOn: Bool
    var connected: Bool
    var countryCode: String?
    var title: String
    var subtitle: String
    var connectedSince: Date?
    var latency: Int?
    var received: Int64
    var sent: Int64
    var updatedAt: Date

    static let empty = WidgetSnapshot(isOn: false, connected: false, countryCode: nil, title: "Anemia",
                                      subtitle: "Сервер не выбран", connectedSince: nil, latency: nil,
                                      received: 0, sent: 0, updatedAt: .distantPast)
}

extension WidgetSnapshot {
    /// Толерантное декодирование — то же, что сделано для
    /// `TunnelActivityAttributes.ContentState`, и по той же причине: GBox
    /// подменяет бинарь приложения, а процесс виджета может остаться со старым
    /// кодом (и наоборот). Синтезированный декодер строгий: первое же добавленное
    /// поле — и снимок, записанный другой сборкой, не читается,
    /// `SharedStore.read()` отвечает nil, а виджет молча переезжает на `.empty`:
    /// «Сервер не выбран» при работающем туннеле и без единой подсказки о причине.
    /// Поля в расширении — чтобы не потерялся обычный инициализатор, которым
    /// снимок пишет приложение.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isOn = try c.decodeIfPresent(Bool.self, forKey: .isOn) ?? false
        connected = try c.decodeIfPresent(Bool.self, forKey: .connected) ?? false
        countryCode = try c.decodeIfPresent(String.self, forKey: .countryCode)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Anemia"
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? "Сервер не выбран"
        connectedSince = try c.decodeIfPresent(Date.self, forKey: .connectedSince)
        latency = try c.decodeIfPresent(Int.self, forKey: .latency)
        received = try c.decodeIfPresent(Int64.self, forKey: .received) ?? 0
        sent = try c.decodeIfPresent(Int64.self, forKey: .sent) ?? 0
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }
}

/// A file both the app and the widget extension can reach.
///
/// GBox signs with its certificate's own App Group IDs, which the build
/// can't know, so the group is found at run time: the provisioning profile
/// lists the groups, and the first one this process can open wins — the same
/// one in the app and in the extension, since both carry the same profile.
/// Without any usable group the store stays empty and the widgets fall back
/// to what they can see themselves.
enum SharedStore {
    static let container: URL? = {
        #if targetEnvironment(simulator)
        // The simulator doesn't enforce App Group entitlements.
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.anemia.simulator")
        #else
        for group in appGroups() {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
                return url
            }
        }
        return nil
        #endif
    }()

    static var isAvailable: Bool { container != nil }

    static func read() -> WidgetSnapshot? {
        guard let url = container?.appendingPathComponent(fileName),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    static func write(_ snapshot: WidgetSnapshot) {
        guard let url = container?.appendingPathComponent(fileName),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static let fileName = "widget-snapshot.json"

    /// The groups in this bundle's profile, or the containing app's for an
    /// extension, sorted so every process tries them in the same order.
    ///
    /// Порядок здесь — не косметика: приложение и виджет-расширение переподписаны
    /// разными App ID, и каждый процесс раньше брал СВОЙ профиль, если в нём
    /// нашлась хоть одна группа. Два профиля с разными наборами — два разных
    /// контейнера, и снимок между ними не переездает вовсе: виджет навечно
    /// остаётся с «Сервер не выбран», хотя приложение пишет рядом. Поэтому
    /// сначала профиль контейнера, а свой — как запасной.
    private static func appGroups() -> [String] {
        let bundle = Bundle.main.bundleURL
        let candidates = [
            // PlugIns/X.appex → the app bundle
            bundle.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("embedded.mobileprovision"),
            bundle.appendingPathComponent("embedded.mobileprovision"),
        ]
        var seen = Set<String>()
        var groups: [String] = []
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let found = profileGroups(data), !found.isEmpty else { continue }
            groups += found.sorted().filter { seen.insert($0).inserted }
        }
        return groups
    }

    /// The profile is a signed CMS blob with the XML plist inside.
    private static func profileGroups(_ data: Data) -> [String]? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return nil }
        let plist = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let profile = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let entitlements = profile["Entitlements"] as? [String: Any]
        else { return nil }
        return (entitlements["com.apple.security.application-groups"] as? [String])?
            .filter { !$0.contains("*") }
    }
}
