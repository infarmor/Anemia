import Foundation
import ServiceManagement

/// Registers the app as a login item via SMAppService (macOS 13+): no helper
/// process, no deprecated LSSharedFileList — the system launches the app's
/// bundle at login.
///
/// Caveats surfaced to the UI rather than swallowed: the registration is
/// path-based (moving the app breaks it), and an unbundled dev run
/// (`swift run`) can't register at all. `setEnabled` returns the error text
/// for the Settings sheet.
@MainActor
enum LoginItem {

    /// The system's actual state — read fresh, not cached, so an external
    /// change (user removing the item in System Settings) is reflected.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Register/unregister the app. Returns a user-facing error on failure.
    static func setEnabled(_ on: Bool) -> String? {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}