import SwiftUI
import LoaderCore

/// Menu-bar popover in the Claude design language. Radical departure from the
/// old utility layout (AppKit bordered buttons stacked under a wide header):
///
///  * centered serif wordmark + a small status line under it — the popover
///    opens as a calm "identity card", not a control panel;
///  * ONE large terracotta pill as the primary action (Connect/Disconnect),
///    label and icon only — no stock macOS button chrome anywhere;
///  * the current server as a soft card that expands *inline* into the full
///    picker, so switching servers never opens another surface;
///  * Fastest/Ping as quiet capsule chips;
///  * a hairline and two tiny text actions as the footer.
struct MenuContentView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var listExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 16)
                .padding(.bottom, 13)

            connectPill
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            trafficRow
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            // The server card morphs into the picker in place — the popover
            // never grows a second window for its most common action.
            if listExpanded {
                serverList
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            } else {
                serverCard
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }

            actionChips
                .padding(.horizontal, 14)
                .padding(.bottom, 14)

            divider
            footer
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
        }
        .background(VibrancyBackground())
        .animation(Theme.spring, value: listExpanded)
        .animation(Theme.spring, value: state.isConnected)
        // Live traffic while the popover is open: registering as a stats
        // viewer raises the poll cadence to 2 s (5 s headless), so the
        // numbers move instead of lying still.
        .onAppear { state.statsViewOpened() }
        .onDisappear { state.statsViewClosed() }
    }

    // MARK: - Live traffic

    /// ↓/↑ speeds on the left, session totals on the right — one quiet row,
    /// visible only while the tunnel is up. The values come straight from the
    /// native stats poll, so opening the popover is watching the wire.
    @ViewBuilder private var trafficRow: some View {
        if state.isConnected {
            HStack(spacing: 10) {
                trafficMetric(icon: "arrow.down", speed: state.downlinkSpeed, tint: Theme.accent)
                trafficMetric(icon: "arrow.up", speed: state.uplinkSpeed, tint: Theme.warn)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down").font(Theme.metric(9))
                        Text(Format.bytes(state.downlinkTotal))
                    }
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up").font(Theme.metric(9))
                        Text(Format.bytes(state.uplinkTotal))
                    }
                }
                .font(Theme.metric(10))
                .foregroundStyle(Theme.textLo)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .softCard(Theme.subRadius, fill: Theme.card, shadow: false)
            .transition(.opacity)
        }
    }

    private func trafficMetric(icon: String, speed: Int64, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(Theme.metric(10, .semibold)).foregroundStyle(tint)
            Text(Format.speed(speed)).font(Theme.metric(11)).foregroundStyle(Theme.textHi)
        }
    }

    // MARK: - Header (quiet identity, serif status headline)

    /// Claude's headline grammar: the most important message — the
    /// connection state — IS the headline, set in the display serif. The
    /// wordmark steps back into a small quiet line above it, instead of
    /// competing with the status the way the old two-line header did.
    private var header: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                if let logo = AppAssets.logo {
                    Image(nsImage: logo).resizable().scaledToFit().frame(height: 14)
                        // White-on-transparent logo: multiplied to warm ink on
                        // the ivory light theme so the mark stays visible.
                        .colorMultiply(colorScheme == .dark ? .white : Theme.textHi)
                }
                Text("Anemia").font(Theme.display(13, .semibold)).foregroundStyle(Theme.textLo)
            }
            HStack(spacing: 7) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                Text(statusHeadline).font(Theme.display(19)).tracking(Theme.tracking(for: 19))
                    .foregroundStyle(statusColor)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Primary action pill

    private var connectPill: some View {
        let blocked = state.selectedServer == nil && !state.isConnected
        return Button(action: state.toggleConnection) {
            HStack(spacing: 8) {
                if state.connection.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: state.isConnected ? "stop.fill" : "play.fill")
                        .font(Theme.ui(11, .semibold))
                }
                Text(buttonTitle).font(Theme.ui(14, .semibold))
                Spacer()
                if let ms = state.proxyLatency, state.isConnected {
                    Text(Format.ping(ms))
                        .font(Theme.metric(12))
                        .opacity(0.85)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(Theme.accentDim, in: Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.985))
        .pointerCursor()
        .disabled(blocked)
        .opacity(blocked ? 0.45 : 1)
    }

    // MARK: - Server card / inline picker

    private var serverCard: some View {
        Button { listExpanded = true } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.selectedServer?.name ?? "Choose a server")
                        .font(Theme.ui(13, .semibold))
                        .foregroundStyle(Theme.textHi).lineLimit(1)
                    Text(serverSubtitle)
                        .font(Theme.ui(11)).foregroundStyle(Theme.textLo).lineLimit(1)
                }
                Spacer()
                if let id = state.selectedServerID {
                    PingBadge(result: state.pings[id])
                }
                Image(systemName: "chevron.down")
                    .font(Theme.ui(10, .semibold))
                    .foregroundStyle(Theme.textLo)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .softCard(Theme.subRadius, fill: Theme.card, shadow: false)
        }
        .buttonStyle(PressableStyle(scale: 0.99))
        .pointerCursor()
    }

    private var serverList: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Servers").font(Theme.display(13)).foregroundStyle(Theme.textHi)
                Spacer()
                Button { listExpanded = false } label: {
                    Image(systemName: "chevron.up")
                        .font(Theme.ui(10, .semibold))
                        .foregroundStyle(Theme.textLo)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Back")
            }
            if state.allServers.isEmpty {
                Text("No servers — import in the main window.")
                    .font(Theme.ui(11)).foregroundStyle(Theme.textLo)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity)
                    .softCard(Theme.subRadius, fill: Theme.card, shadow: false)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(state.allServers) { server in
                            MenuServerRow(server: server) { listExpanded = false }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 240)
            }
        }
    }

    private var serverSubtitle: String {
        guard let s = state.selectedServer else { return "Tap to open the list" }
        var parts = [s.proto.rawValue.uppercased()]
        if s.security != .none { parts.append(s.security.rawValue) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Quiet action chips

    private var actionChips: some View {
        HStack(spacing: 8) {
            actionChip(title: "Fastest", icon: "bolt.fill",
                       busy: state.isPinging,
                       disabled: state.allServers.isEmpty || state.isPinging) {
                state.requestConnectFastest()
            }
            actionChip(title: "Ping", icon: "gauge.with.dots.needle.bottom.50percent",
                       busy: state.isPinging,
                       disabled: state.allServers.isEmpty || state.isPinging) {
                Task { await state.pingAll() }
            }
        }
    }

    private func actionChip(title: String, icon: String, busy: Bool,
                           disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: icon).font(Theme.ui(11, .semibold))
                }
                Text(title).font(Theme.ui(12, .medium))
            }
            .foregroundStyle(disabled ? Theme.textLo.opacity(0.55) : Theme.textHi)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(Theme.idle, in: Capsule())
        }
        .buttonStyle(PressableStyle())
        .pointerCursor(disabled ? .arrow : .pointingHand)
        .disabled(disabled)
    }

    // MARK: - Footer

    /// Hairline in the theme's stroke color — the default Divider's cool gray
    /// reads off-brand against the warm ivory/charcoal ground.
    private var divider: some View { Divider().overlay(Theme.stroke) }

    private var footer: some View {
        HStack {
            Button { openWindow(id: "main") } label: { Label("Open Anemia", systemImage: "macwindow") }
                .buttonStyle(PressableStyle(scale: 0.95))
                .foregroundStyle(Theme.textLo)
                .pointerCursor()
            Spacer()
            Button { NSApplication.shared.terminate(nil) } label: {
                Label("Quit", systemImage: "power")
            }
            .buttonStyle(PressableStyle(scale: 0.95))
            .foregroundStyle(Theme.textLo)
            .pointerCursor()
        }
        .font(.caption)
    }

    // MARK: - Derived

    private var statusColor: Color {
        switch state.connection {
        case .connected:
            // Health monitor lost the upstream: show it, don't keep pretending
            // everything is fine while pages silently stop loading.
            guard state.proxyReachable else { return Theme.danger }
            return state.tunnelActive ? Theme.accent : Theme.warn
        case .connecting: return Theme.accent
        case .error: return Theme.danger
        case .disconnected: return Theme.textLo
        }
    }
    /// The headline carries the real state, not a euphemism: "Protected" only
    /// when the full system tunnel is up and the upstream answers.
    private var statusHeadline: String {
        switch state.connection {
        case .connected:
            guard state.proxyReachable else { return "No route" }
            if state.tunnelActive { return "Protected" }
            // A failed system tunnel reads as a failure, not as SOCKS mode.
            return state.systemTunnelError != nil ? "Tunnel failed" : "SOCKS only"
        case .connecting: return "Connecting…"
        case .error: return "Error"
        case .disconnected: return "Off"
        }
    }
    private var buttonTitle: String {
        switch state.connection {
        case .connected, .error: return "Disconnect"
        case .connecting: return "Working…"
        case .disconnected: return "Connect"
        }
    }
}

/// One server row in the inline picker: hover-highlighted quiet row in the
/// shared tile language — same hover cue as the main servers sheet, so both
/// pickers feel like the same app. Tapping picks AND collapses back to the
/// card via `onPick`, one gesture for the whole round trip.
private struct MenuServerRow: View {
    @EnvironmentObject var state: AppState
    let server: ProxyServer
    let onPick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            state.quickConnect(server.id)
            onPick()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: server.id == state.selectedServerID ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(server.id == state.selectedServerID ? Theme.accent : Theme.textLo)
                    .font(.caption)
                Text(server.name).font(Theme.ui(13, .medium)).lineLimit(1).foregroundStyle(Theme.textHi)
                Spacer()
                if server.id == state.recommendedServerID {
                    BestBadge(neural: state.mlRankingEnabled && state.kxcLoaded)
                }
                PingBadge(result: state.pings[server.id])
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Theme.idle : Color.clear,
                        in: RoundedRectangle(cornerRadius: Theme.subRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .pointerCursor()
        .onHover { hovering = $0 }
        .animation(Theme.springQuick, value: hovering)
    }
}