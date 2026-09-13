import SwiftUI
import AppKit

/// Bridges AppKit's terminate callback to AppState, so the privileged tunnel is
/// torn down synchronously on quit. Set by AppState.init.
@MainActor enum AppTermination {
    static var handler: (() -> Void)?
}

/// Bridges the GURL Apple Event (clicking a `vpn://` / `hysteria://` /
/// `amnezia://` … link) to AppState.importLink. Set by AppState.init.
@MainActor enum AppURLOpen {
    static var handler: ((String) -> Void)?
}

/// Minimal delegate: run the tunnel teardown when the app is quitting so the
/// machine is never left offline behind a still-armed tunnel/kill switch, and
/// route opened share links into the import pipeline.
final class AppDelegate: NSObject, NSApplicationDelegate {
    override init() {
        super.init()
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppTermination.handler?() }
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let raw = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return }
        Task { @MainActor in AppURLOpen.handler?(raw) }
    }
}

@main
struct LoaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        // Main AmneziaVPN-style window.
        WindowGroup("Anemia", id: "main") {
            RootView()
                .environmentObject(state)
        }
        .windowResizability(.contentSize)
        // Compact column: the default frame hugs the content's own minimum
        // (RootView .frame(minWidth: 560, minHeight: 470)) — an oversized
        // default height leaves a tall blank band under the last tile.
        .defaultSize(width: 580, height: 500)

        // Menu-bar quick control.
        MenuBarExtra {
            MenuContentView()
                .environmentObject(state)
                .frame(width: 340)
        } label: {
            if let icon = AppAssets.menuBarIcon {
                Image(nsImage: icon).resizable().scaledToFit()
                    .frame(width: 18, height: 18)
                    .opacity(state.isConnected ? 1 : 0.55)
            } else {
                Image(systemName: state.isConnected ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
