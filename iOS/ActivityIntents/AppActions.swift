import Foundation

/// What the Live Activity's buttons and the Control Center switch do.
///
/// The intents are compiled into the widget extension as well, but iOS runs
/// them in the app's process (they are LiveActivityIntents): the app fills
/// these in at launch — a launch in the background included. In the
/// extension they stay nil and are never called.
@MainActor
enum AppActions {
    /// Connects the selected server, unless the VPN is already on. nil when
    /// the tunnel came up, otherwise why it didn't — an intent that answers
    /// "done" to a refusal leaves the Control Center switch flipped over a
    /// tunnel that never started.
    static var connect: (() async -> String?)?
    /// Turns the VPN off for good: auto-reconnect doesn't bring it back.
    static var disconnect: (() async -> Void)?
    /// Pings the servers and moves the tunnel to the fastest one.
    static var switchToFastest: (() async -> Void)?

    /// Thrown instead of reporting a success the tunnel didn't have: iOS
    /// reverts a `SetValueIntent` switch when `perform()` throws.
    enum Failure: LocalizedError {
        case notWired
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .notWired: "Anemia не готова: приложение не ответило"
            case .refused(let why): why
            }
        }
    }
}
