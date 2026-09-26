import SwiftUI

/// Instant press feedback for the few custom tiles (server rows, chips): a
/// small dip on pointer-down, settling on a critically damped spring. System
/// buttons bring their own feedback and don't use this.
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

extension View {
    /// The system button look for the running macOS: Liquid Glass on macOS 26
    /// and later, the classic bordered styles before. Prominent buttons fill
    /// with the clay accent (or `tint`); regular ones stay neutral glass.
    @ViewBuilder
    func nativeButtonStyle(prominent: Bool = false, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent).tint(tint ?? Theme.accent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            if prominent {
                buttonStyle(.borderedProminent).tint(tint ?? Theme.accent)
            } else {
                buttonStyle(.bordered)
            }
        }
    }
}

/// Primary in-row action (Enable, Save, Repair, Import): a prominent system
/// button in the clay accent unless `tint` says otherwise.
struct PillButton: View {
    let title: String
    var icon: String?
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let icon {
                Label(title, systemImage: icon)
            } else {
                Text(title)
            }
        }
        .nativeButtonStyle(prominent: true, tint: tint)
    }
}

/// Secondary action (Ping all, Cancel, Copy): a regular system button.
struct GhostButton: View {
    let title: String
    var icon: String?
    var busy = false
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if busy {
                    ProgressView().controlSize(.mini)
                } else if let icon {
                    Image(systemName: icon)
                }
                Text(title)
            }
        }
        .nativeButtonStyle()
        .tint(tint)
    }
}

/// "Best server" pill on kxc's top-ranked row.
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

/// Compact three-bar steadiness meter from the stability score in [0, 1].
struct StabilityBars: View {
    let score: Double

    private var level: Int {
        score <= 0.01 ? 0 : (score >= 0.75 ? 3 : (score >= 0.5 ? 2 : 1))
    }
    private var tint: Color {
        Theme.textHi
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(i < level ? tint : Theme.stroke)
                    .frame(width: 3, height: 5 + CGFloat(i) * 2.5)
            }
        }
        .help("Stability \(Int((score * 100).rounded()))% — steadiness of latency (loss, jitter, trend)")
    }
}

/// Compact quality tier from the kxc score.
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

/// Latency badge shared by the menu and the servers sheet.
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
            Text("—").font(Theme.ui(11, .semibold)).foregroundStyle(Theme.textLo)
        case nil:
            EmptyView()
        }
    }

    /// TLS-handshake RTT as ink density: good ≤120 ms reads strongest,
    /// poor (>300 ms) recedes — the number itself carries the detail.
    private func color(_ v: Int) -> Color {
        v < 120 ? Theme.textHi : (v < 300 ? Theme.textLo : Theme.tierFair)
    }
}
