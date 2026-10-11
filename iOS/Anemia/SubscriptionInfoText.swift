import Foundation
import LoaderCore

// The panel's word about a subscription (LoaderCore/SubscriptionInfo), in
// Russian for the iPhone app.
extension SubscriptionInfo {
    /// "Осталось 42,1 ГБ из 100 ГБ", "Безлимит · использовано 3,2 ГБ".
    var trafficText: String? {
        if let remaining, let total {
            return "Осталось \(Bytes.text(remaining)) из \(Bytes.text(total))"
        }
        if let used {
            return "Безлимит · использовано \(Bytes.text(used))"
        }
        return nil
    }

    /// "Действует до 12 октября 2026 г.", "Истекает завтра", "Подписка истекла".
    var expiryText: String? {
        guard let expires else { return nil }
        let interval = expires.timeIntervalSinceNow
        if interval <= 0 { return "Подписка истекла" }
        if interval < 3 * 86_400 {
            return "Истекает \(expires.formatted(.relative(presentation: .named).locale(Self.russian)))"
        }
        return "Действует до \(expires.formatted(.dateTime.day().month(.wide).year().locale(Self.russian)))"
    }

    private static let russian = Locale(identifier: "ru_RU")
}
