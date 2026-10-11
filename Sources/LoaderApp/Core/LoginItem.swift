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

    /// Registered, but the system will not run it until the user ticks Anemia
    /// in System Settings → General → Login Items. A separate state on
    /// purpose: `register()` succeeded here, yet `isEnabled` is still false,
    /// and a caller that only re-reads `isEnabled` shows the toggle snapping
    /// back with nothing said about why.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
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