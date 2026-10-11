#if targetEnvironment(simulator)
import SwiftUI

/// `-liveActivityGallery`: every Live Activity state drawn by the app itself,
/// at the sizes iOS uses — for checking the design in the simulator, where
/// the system's own rendering waits on a permission prompt. The island
/// layouts are approximations of what iOS does with the regions: the system
/// measures the centre first and drops a leading or trailing view that
/// doesn't fit next to the camera, so anything here that only just fits is
/// what the device will hide.
struct LiveActivityGallery: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("Экран блокировки")
                ForEach(Array(ActivitySamples.all.enumerated()), id: \.offset) { _, sample in
                    caption(sample.name)
                    ActivityLockScreenView(state: sample.state, isStale: sample.stale)
                        .frame(width: 340)
                        .background(ActivityPalette.charcoal)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }

                section("Dynamic Island, развёрнутый")
                ForEach(Array(ActivitySamples.all.prefix(5).enumerated()), id: \.offset) { _, sample in
                    caption(sample.name)
                    ExpandedIsland(state: sample.state, isStale: sample.stale)
                }

                section("Dynamic Island, компактный")
                ForEach(Array(ActivitySamples.all.enumerated()), id: \.offset) { _, sample in
                    caption(sample.name)
                    CompactIsland(state: sample.state, isStale: sample.stale)
                }

                section("Apple Watch, Smart Stack")
                ForEach(Array(ActivitySamples.all.enumerated()), id: \.offset) { _, sample in
                    caption(sample.name)
                    WatchCard(state: sample.state, isStale: sample.stale)
                }
            }
            .padding(16)
        }
        .background(Color(white: 0.55))
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.top, 8)
    }

    private func caption(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.85))
    }
}

/// The expanded island: leading and trailing beside the camera, the centre
/// below it, the bottom across.
private struct ExpandedIsland: View {
    let state: ActivityState
    let isStale: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 0) {
                ActivityIslandLeading(state: state)
                    .frame(width: 62, alignment: .leading)
                ActivityIslandCenter(state: state)
                    .frame(maxWidth: .infinity)
                ActivityIslandTrailing(state: state, isStale: isStale)
                    .frame(width: 84, alignment: .trailing)
            }
            .frame(height: 44)
            ActivityIslandBottom(state: state, isStale: isStale)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .frame(width: 371)
        .background(.black, in: RoundedRectangle(cornerRadius: 44, style: .continuous))
    }
}

/// A Smart Stack card on a 45 mm watch: about 184 × 88 pt, the app's
/// icon above the activity.
private struct WatchCard: View {
    let state: ActivityState
    let isStale: Bool

    var body: some View {
        ActivitySmallView(state: state, isStale: isStale)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(width: 184, alignment: .leading)
            .background(ActivityPalette.charcoal, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(8)
            .background(.black, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

/// The compact island: a pill around the camera. The two corners are the
/// real limit — about 40 pt of leading and 40 pt of trailing next to the
/// cutout — so this is where an oversized view shows up as missing, or as a
/// pill stretched across the whole display.
private struct CompactIsland: View {
    let state: ActivityState
    let isStale: Bool

    var body: some View {
        HStack(spacing: 0) {
            ActivityCompactMark(state: state, size: 17)
                .frame(width: 40, alignment: .leading)
            Spacer(minLength: 126)
            ActivityCompactStatus(state: state, isStale: isStale)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(width: 250, height: 37)
        .background(.black, in: Capsule())
    }
}
#endif
