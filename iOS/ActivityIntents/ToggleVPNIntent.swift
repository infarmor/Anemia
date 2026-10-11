import AppIntents
import os

/// The Control Center / Lock Screen switch. A LiveActivityIntent as well, so
/// iOS runs it in the app's process — which can start the VPN and, from
/// inside the intent, the Live Activity too.
@available(iOS 18.0, *)
struct ToggleVPNIntent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Anemia VPN"
    static let description = IntentDescription("Включает и выключает VPN Anemia.")
    static let isDiscoverable = false

    @Parameter(title: "Включён")
    var value: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        Logger(subsystem: "Anemia", category: "intent").info("control switch: \(value ? "on" : "off", privacy: .public)")
        if value {
            guard let connect = AppActions.connect else { throw AppActions.Failure.notWired }
            // Без этого тумблер оставался включённым над туннелем, который не
            // начался: отказ iOS не видит, а `perform()` вернулся с успехом.
            if let why = await connect() {
                Logger(subsystem: "Anemia", category: "intent").error("connect refused: \(why, privacy: .public)")
                throw AppActions.Failure.refused(why)
            }
        } else {
            guard let disconnect = AppActions.disconnect else { throw AppActions.Failure.notWired }
            await disconnect()
        }
        return .result()
    }
}
