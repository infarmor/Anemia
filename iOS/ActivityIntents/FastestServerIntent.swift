import AppIntents
import os

/// The Live Activity's "Быстрее" button: pings the servers and moves the
/// tunnel to the fastest one. Runs in the app's process (see AppActions).
struct FastestServerIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Самый быстрый сервер"
    static let description = IntentDescription("Пингует серверы Anemia и переключает VPN на самый быстрый.")
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        Logger(subsystem: "Anemia", category: "intent").info("fastest server requested from the Live Activity")
        await AppActions.switchToFastest?()
        return .result()
    }
}
