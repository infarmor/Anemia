import SwiftUI

@main
struct AnemiaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        model = AppModel.shared
    }

    var body: some Scene {
        WindowGroup {
            #if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("-liveActivityGallery") {
                LiveActivityGallery()
            } else {
                main
            }
            #else
            main
            #endif
        }
    }

    private var main: some View {
        ContentView()
            .environment(model.tunnel)
            .environment(model.store)
            .environment(model.liveActivity)
            .environment(model.pings)
            .environment(model.actions)
            .environment(model.stats)
            .environment(model.speedTest)
            .environment(model.network)
            .environment(model.leaks)
            .environment(model.alerts)
            .environment(AppRouter.shared)
            .tint(Theme.accent)
            .task {
                #if targetEnvironment(simulator)
                if let phase = Self.demoPhase() {
                    model.liveActivity.startDemo(phase: phase)
                    return
                }
                #endif
                await model.tunnel.loadIfNeeded()
                await model.alerts.reschedule()
            }
            .task {
                // Subscriptions: at launch, then every half hour checks
                // for ones the panel considers stale — also while the app
                // keeps running in the background for the Live Activity.
                while !Task.isCancelled {
                    await model.store.refreshStaleSubscriptions()
                    try? await Task.sleep(for: .seconds(30 * 60))
                }
            }
            .onChange(of: scenePhase) {
                guard scenePhase == .active else { return }
                // Back in front: iOS allows starting the activity again.
                model.liveActivity.backInFront()
                Task { await model.store.refreshStaleSubscriptions() }
            }
    }

    #if targetEnvironment(simulator)
    /// `-demoLiveActivity [-demoPhase connected|reconnecting|searching|ended]`
    private static func demoPhase() -> TunnelActivityAttributes.ContentState.Phase? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-demoLiveActivity") else { return nil }
        if let index = arguments.firstIndex(of: "-demoPhase"), index + 1 < arguments.count {
            return TunnelActivityAttributes.ContentState.Phase(rawValue: arguments[index + 1]) ?? .connected
        }
        return .connected
    }
    #endif
}
