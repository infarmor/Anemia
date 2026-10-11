import AppIntents
import os

/// The widget's "Включить" button. Runs in the app's process (see
/// AppActions), which may also start the Live Activity from there.
struct ConnectIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Включить VPN"
    static let description = IntentDescription("Подключает выбранный сервер Anemia.")
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        Logger(subsystem: "Anemia", category: "intent").info("connect requested from a widget")
        guard let connect = AppActions.connect else { throw AppActions.Failure.notWired }
        if let why = await connect() {
            Logger(subsystem: "Anemia", category: "intent").error("connect refused: \(why, privacy: .public)")
            throw AppActions.Failure.refused(why)
        }
        return .result()
    }
}
