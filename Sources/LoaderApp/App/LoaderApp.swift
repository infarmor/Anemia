import SwiftUI

@main
struct LoaderApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        // Main AmneziaVPN-style window.
        WindowGroup("Anemia", id: "main") {
            RootView()
                .environmentObject(state)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 400, height: 640)

        // Menu-bar quick control.
        MenuBarExtra {
            MenuContentView()
                .environmentObject(state)
                .frame(width: 340)
        } label: {
            if let logo = AppAssets.logo {
                Image(nsImage: logo).resizable().scaledToFit()
                    .frame(width: 18, height: 18)
                    .opacity(state.isConnected ? 1 : 0.55)
            } else {
                Image(systemName: state.isConnected ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
