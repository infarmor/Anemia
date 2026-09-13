import SwiftUI

/// Instant press feedback — fluid-interfaces rule #1: respond on pointer-DOWN,
/// never only on release. The label dips (scale, plus a whisper of opacity)
/// the instant the press registers, and settles on a critically damped
/// spring so release never bounces a control the finger didn't flick.
/// Reduced motion keeps the feedback as a plain opacity dip — gentler, not
/// absent.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .opacity(configuration.isPressed ? (reduceMotion ? 0.72 : 0.92) : 1)
            .animation(reduceMotion ? .linear(duration: 0.08) : Theme.springQuick,
                       value: configuration.isPressed)
    }
}

/// The app's filled pill — primary in-row and footer actions (settings
/// Enable/Update, sheet Import/Import confirm). Replaces the system
/// `.borderedProminent` chrome whose default corners and tint never matched
/// the warm tiles.
struct PillButton: View {
    let title: String
    var icon: String?
    var tint: Color = Theme.accentDim
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(Theme.ui(10, .semibold)) }
                Text(title).font(Theme.ui(12, .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(tint, in: Capsule())
        }
        .buttonStyle(PressableStyle())
        .pointerCursor()
    }
}

/// Quiet capsule chip for secondary actions (Ping all, Fastest, Cancel) —
/// the same idle fill the masking menu and action chips use.
struct GhostButton: View {
    let title: String
    var icon: String?
    var busy = false
    var tint: Color = Theme.textHi
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if busy {
                    ProgressView().controlSize(.mini)
                } else if let icon {
                    Image(systemName: icon).font(Theme.ui(11, .semibold))
                }
                Text(title).font(Theme.ui(12, .medium))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.idle, in: Capsule())
        }
        .buttonStyle(PressableStyle())
        .pointerCursor()
    }
}

/// "Best server" pill shown on kxc's top-ranked row. Reads `kxc` (with a
/// sparkle) when the neural model is driving the ranking, else `Best`.
struct BestBadge: View {
    var neural: Bool
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: neural ? "sparkles" : "bolt.fill").font(Theme.ui(9, .semibold))
            Text(neural ? "kxc" : "Best").font(Theme.ui(9, .semibold))
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Theme.accent.opacity(0.14), in: Capsule())
        .help("kxc's recommended server")
    }
}

/// Compact three-bar "steadiness" meter from the stability score in [0, 1].
/// Shows how *dependable* a link is (loss / jitter / upward trend), which is
/// distinct from raw latency — a fast server that occasionally stalls reads
/// lower here than a slightly slower but rock-steady one. Bars fill 1 → 3.
struct StabilityBars: View {
    let score: Double

    // 0 only for a fully dead server (score 0 — all probes failed): an
    // all-empty meter must not read as "at least somewhat stable".
    private var level: Int {
        score <= 0.01 ? 0 : (score >= 0.75 ? 3 : (score >= 0.5 ? 2 : 1))
    }
    private var tint: Color {
        score >= 0.75 ? Theme.tierGood : (score >= 0.5 ? Theme.tierFair : Theme.tierPoor)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(i < level ? tint : Theme.textLo.opacity(0.25))
                    .frame(width: 3, height: 5 + CGFloat(i) * 2.5)
            }
        }
        .help("Stability \(Int((score * 100).rounded()))% — steadiness of latency (loss, jitter, trend)")
    }
}

/// Compact quality tier from the kxc score (jitter/loss/trend aware).
struct QualityTag: View {
    let tier: AppState.Quality
    var body: some View {
        Text(tier.rawValue.uppercased())
            .font(Theme.ui(9, .semibold))
            .foregroundStyle(color)
    }
    private var color: Color {
        switch tier {
        case .excellent: return Theme.tierExcellent
        case .good:      return Theme.tierGood
        case .fair:      return Theme.tierFair
        case .poor:      return Theme.tierPoor
        }
    }
}

/// Color-coded latency badge shared by the menu and the servers sheet.
struct PingBadge: View {
    let result: PingResult?

    var body: some View {
        switch result {
        case .measuring:
            ProgressView().controlSize(.mini)
        case .ms(let v):
            Text(Format.ping(v))
                .font(Theme.metric(11))
                .foregroundStyle(color(v))
        case .failed:
            Text("—").font(Theme.ui(11, .semibold)).foregroundStyle(Theme.tierPoor)
        case nil:
            EmptyView()
        }
    }

    // Thresholds suit a TLS-handshake RTT (a full round-trip, higher than a raw
    // ICMP/TCP ping): good ≤120 ms, fair ≤300 ms, poor above — on the shared
    // tier scale so ping, quality and stability read as one system.
    private func color(_ v: Int) -> Color {
        v < 120 ? Theme.tierGood : (v < 300 ? Theme.tierFair : Theme.tierPoor)
    }
}
