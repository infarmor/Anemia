import ActivityKit
import SwiftUI
import WidgetKit

/// Lock Screen, Dynamic Island and Apple Watch. The views themselves are in
/// Activity/LiveActivityViews.swift, shared with the app's simulator gallery.
///
/// Expanded island: the session ring with the flag on the left, the speed
/// beside the camera, the country below it, the graph and the actions at the
/// bottom. Compact: the flag on the left and the session ring on the right,
/// the way the Clock app's timer sits there. The Lock Screen gets a single
/// strip — Apple requires the presentation, the app's detail lives in the
/// island.
struct TunnelLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TunnelActivityAttributes.self) { context in
            ActivityContentView(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(ActivityPalette.charcoal)
                .activitySystemActionForegroundColor(ActivityPalette.clay)
        } dynamicIsland: { context in
            let state = context.state
            let isStale = context.isStale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ActivityIslandLeading(state: state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ActivityIslandTrailing(state: state, isStale: isStale)
                }
                DynamicIslandExpandedRegion(.center) {
                    ActivityIslandCenter(state: state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ActivityIslandBottom(state: state, isStale: isStale)
                }
            } compactLeading: {
                ActivityCompactMark(state: state, size: 17)
            } compactTrailing: {
                ActivityCompactStatus(state: state, isStale: isStale)
            } minimal: {
                ActivityCompactMark(state: state, size: 15)
            }
            .keylineTint(ActivityPalette.clay)
        }
        // Apple Watch's Smart Stack and CarPlay get the short form.
        .supplementalActivityFamilies([.small])
    }
}

#Preview("Экран блокировки", as: .content, using: TunnelActivityAttributes()) {
    TunnelLiveActivity()
} contentStates: {
    ActivitySamples.connected
    ActivitySamples.connecting
    ActivitySamples.with(.reconnecting)
    ActivitySamples.with(.searching)
    ActivitySamples.with(.ended, note: "Соединение прервалось")
}

#Preview("Остров: компактно", as: .dynamicIsland(.compact), using: TunnelActivityAttributes()) {
    TunnelLiveActivity()
} contentStates: {
    ActivitySamples.connected
    ActivitySamples.with(.reconnecting)
}

#Preview("Остров: развёрнуто", as: .dynamicIsland(.expanded), using: TunnelActivityAttributes()) {
    TunnelLiveActivity()
} contentStates: {
    ActivitySamples.connected
    ActivitySamples.with(.ended)
}
