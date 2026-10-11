import Observation
import UIKit

/// Where the main screen should go next, when something outside it asks:
/// the app icon's menu, for now.
@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()

    /// Open "Проверка утечек".
    var leakCheckRequested = false
}

/// The app icon's menu (press and hold on the Home Screen): switch the VPN,
/// move to the fastest server, check for leaks. The items follow the
/// tunnel's state.
@MainActor
enum HomeScreenActions {
    private enum Action: String {
        case connect = "anemia.connect"
        case disconnect = "anemia.disconnect"
        case fastest = "anemia.fastest"
        case leakCheck = "anemia.leakCheck"
    }

    private static var last: (isOn: Bool, server: String?)?

    static func update(isOn: Bool, server: String?) {
        guard last.map({ $0.isOn != isOn || $0.server != server }) ?? true else { return }
        last = (isOn, server)
        UIApplication.shared.shortcutItems = [
            isOn
                ? item(.disconnect, "Отключить VPN", subtitle: server, symbol: "shield.slash")
                : item(.connect, "Включить VPN", subtitle: server, symbol: "checkmark.shield"),
            item(.fastest, "Самый быстрый сервер", subtitle: nil, symbol: "bolt.fill"),
            item(.leakCheck, "Проверка утечек", subtitle: nil, symbol: "eye.slash"),
        ]
    }

    /// Runs an item's action. False for an unknown item.
    static func perform(_ type: String) -> Bool {
        guard let action = Action(rawValue: type) else { return false }
        let model = AppModel.shared
        switch action {
        case .connect:
            Task { await model.actions.connectSelected(waitUntilConnected: false) }
        case .disconnect:
            Task { await model.actions.disconnect() }
        case .fastest:
            // Итог раунда Live Activity пишет только когда туннель был включён;
            // с выключенным «Ни один сервер не ответил» возвращался и
            // выбрасывался — пункт иконки крутил минуты молча.
            Task {
                let outcome = await model.actions.switchToFastest(reason: .manual)
                if let outcome, !model.tunnel.isOn { model.tunnel.showError(outcome) }
            }
        case .leakCheck:
            AppRouter.shared.leakCheckRequested = true
        }
        return true
    }

    private static func item(_ action: Action, _ title: String, subtitle: String?, symbol: String) -> UIApplicationShortcutItem {
        UIApplicationShortcutItem(type: action.rawValue, localizedTitle: title, localizedSubtitle: subtitle,
                                  icon: UIApplicationShortcutIcon(systemImageName: symbol))
    }
}

/// Hands the icon's menu to `HomeScreenActions`: at a cold start the item
/// comes with the scene, later through the scene delegate.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let item = options.shortcutItem {
            _ = HomeScreenActions.perform(item.type)
        }
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(HomeScreenActions.perform(shortcutItem.type))
    }
}
