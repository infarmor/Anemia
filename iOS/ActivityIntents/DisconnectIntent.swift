import ActivityKit
import AppIntents
import NetworkExtension
import os

/// The Live Activity's power button. The intent is part of the app as well
/// as the widget extension, so iOS runs it in the app's process — the only
/// one that can reach the VPN configuration and the activity.
struct DisconnectIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Отключить VPN"
    static let description = IntentDescription("Отключает туннель Anemia.")
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        Logger(subsystem: "Anemia", category: "intent").info("disconnect requested from the Live Activity")
        if let disconnect = AppActions.disconnect {
            // The app ends the activity with the session's summary.
            await disconnect()
            return .result()
        }
        // Not wired (shouldn't happen in the app): stop the tunnel directly.
        for manager in try await NETunnelProviderManager.loadAllFromPreferences() {
            // With auto-reconnect on, iOS would bring the tunnel straight back.
            if manager.isOnDemandEnabled {
                manager.isOnDemandEnabled = false
                try await manager.saveToPreferences()
            }
            manager.connection.stopVPNTunnel()
        }
        for activity in Activity<TunnelActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        return .result()
    }
}
