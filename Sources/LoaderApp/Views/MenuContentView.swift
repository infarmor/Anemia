import SwiftUI
import LoaderCore

/// Menu-bar popover — the main window's grammar and two tones, condensed:
/// the state and the VPN switch on top, what's flowing, where you exit, the
/// two quick actions, and the way out. Everything a glance needs, nothing a
/// glance has to decode.
struct MenuContentView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var listExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !state.networkIssues.isEmpty {
                NoticeRow(symbol: "wifi.exclamationmark", tint: Theme.accent,
                          title: "Network settings need repair") {
                    if state.repairInProgress {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Repair") { Task { await state.repairNetwork() } }
                            .nativeButtonStyle(prominent: true)
                            .controlSize(.small)
                    }
                }
                .help(state.networkIssues.map(\.message).joined(separator: "\n"))
                .transition(slide)
            }
            if state.isConnected {
                trafficRow
                    .transition(slide)
            }
            Divider()
            if listExpanded {
                serverList
                    .transition(slide)
            } else {
                serverRow
                    .transition(.opacity)
            }
            quickActions
            Divider()
            footer
        }
        .padding(14)
        .background(GroundBackground())
        .animation(reduceMotion ? nil : Theme.spring, value: listExpanded)
        .animation(reduceMotion ? nil : Theme.spring, value: state.isConnected)
        .animation(reduceMotion ? nil : Theme.spring, value: state.networkIssues)
        // Live traffic while the popover is open: registering as a stats
        // viewer raises the poll cadence.
        .onAppear { state.statsViewOpened() }
        .onDisappear { state.statsViewClosed() }
    }

    /// Enter and exit along the same path (from the top edge), or a plain
    /// cross-fade under Reduce Motion.
    private var slide: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }

    private var isProtected: Bool {
        state.isConnected && state.tunnelActive && state.proxyReachable
    }

    // MARK: - Header: state + switch

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(isProtected ? AnyShapeStyle(Theme.accent.gradient) : AnyShapeStyle(Theme.idle))
                if state.connection == .connecting && !state.waitingForNetwork {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: statusSymbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isProtected ? Color.white : Theme.textLo)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 34, height: 34)
            .animation(reduceMotion ? nil : Theme.spring, value: isProtected)

            VStack(alignment: .leading, spacing: 1) {
                Text(statusHeadline)
                    .font(.system(size: 17, weight: .medium, design: .serif))
                    .foregroundStyle(isProtected || state.connection == .connecting ? Theme.accent : Theme.textHi)
                    .lineLimit(1)
                statusLine
            }
            Spacer(minLength: 8)
            Toggle(isOn: connectBinding) { Text("VPN") }
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .labelsHidden()
                .help(state.isConnected ? "Disconnect" : "Connect")
        }
    }

    @ViewBuilder private var statusLine: some View {
        if let since = state.connectedSince, state.isConnected {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                HStack(spacing: 4) {
                    Text(Format.duration(since: since, now: ctx.date))
                    if let ms = state.proxyLatency {
                        Text("·")
                        Text(Format.ping(ms))
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.textLo)
            }
        } else {
            Text(statusHint)
                .font(.caption)
                .foregroundStyle(Theme.textLo)
                .lineLimit(1)
        }
    }

    /// No server yet → turning the switch on opens the main window to pick
    /// one (the switch reads the real state, so it springs back off).
    private var connectBinding: Binding<Bool> {
        Binding(
            get: { state.isConnected || state.connection == .connecting },
            set: { on in
                if on, state.selectedServer == nil, !state.isConnected {
                    openWindow(id: "main")
                    return
                }
                state.setConnected(on)
            }
        )
    }

    // MARK: - Traffic

    private var trafficRow: some View {
        HStack(spacing: 14) {
            metric(symbol: "arrow.down", tint: Theme.accent, speed: state.downlinkSpeed, total: state.downlinkTotal)
            metric(symbol: "arrow.up", tint: Theme.textLo, speed: state.uplinkSpeed, total: state.uplinkTotal)
            TrafficSparkline()
                .frame(maxWidth: .infinity)
                .frame(height: 26)
        }
    }

    private func metric(symbol: String, tint: Color, speed: Int64, total: Int64) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(Format.speed(speed))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textHi)
                    .contentTransition(.numericText())
                Text(Format.bytes(total))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.textLo)
            }
            .lineLimit(1)
        }
        .fixedSize()
    }

    // MARK: - Server

    private var serverRow: some View {
        Button { listExpanded = true } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.selectedServer?.name ?? "Choose a Server")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textHi)
                        .lineLimit(1)
                    Text(serverSubtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textLo)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let id = state.selectedServerID {
                    PingBadge(result: state.pings[id])
                }
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textLo)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.985))
        .help("Choose a server")
    }

    private var serverList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Servers")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textLo)
                Spacer()
                Button { listExpanded = false } label: {
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textLo)
                .help("Collapse")
            }
            if state.allServers.isEmpty {
                Text("No servers yet — import one in the main window.")
                    .font(.caption)
                    .foregroundStyle(Theme.textLo)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(state.allServers) { server in
                            MenuServerRow(server: server) { listExpanded = false }
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
        }
    }

    private var serverSubtitle: String {
        guard let s = state.selectedServer else { return "Open the list to pick one" }
        var parts = [s.proto.rawValue.uppercased()]
        if s.security != .none { parts.append(s.security.rawValue) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Quick actions

    private var quickActions: some View {
        HStack(spacing: 8) {
            Button { state.requestConnectFastest() } label: {
                Label("Fastest", systemImage: "bolt.fill")
                    .frame(maxWidth: .infinity)
            }
            Button { Task { await state.pingAll() } } label: {
                HStack(spacing: 5) {
                    if state.isPinging {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    }
                    Text("Ping")
                }
                .frame(maxWidth: .infinity)
            }
        }
        .controlSize(.large)
        .nativeButtonStyle()
        .disabled(state.allServers.isEmpty || state.isPinging)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Open Anemia") { openWindow(id: "main") }
            Spacer()
            SettingsLink { Text("Settings…") }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.plain)
        .font(.callout)
        .foregroundStyle(Theme.textLo)
    }

    // MARK: - Derived

    private var statusSymbol: String {
        switch state.connection {
        case .connected:
            if !state.proxyReachable { return "exclamationmark.shield.fill" }
            return state.tunnelActive ? "checkmark.shield.fill" : "shield.lefthalf.filled"
        case .connecting: return state.waitingForNetwork ? "wifi.slash" : "shield"
        case .error: return "xmark.shield.fill"
        case .disconnected: return "shield.slash"
        }
    }

    /// The headline carries the real state: "Protected" only when the full
    /// system tunnel is up and the upstream answers.
    private var statusHeadline: String {
        switch state.connection {
        case .connected:
            guard state.proxyReachable else { return "No route" }
            if state.tunnelActive { return "Protected" }
            return state.systemTunnelError != nil ? "Tunnel failed" : "SOCKS only"
        case .connecting: return state.waitingForNetwork ? "Waiting for network" : "Connecting…"
        case .error: return "Connection error"
        case .disconnected: return "Not connected"
        }
    }

    private var statusHint: String {
        if case .error(let message) = state.connection { return message }
        if state.connection == .connecting { return state.selectedServer?.name ?? "" }
        return state.selectedServer?.name ?? "Choose a server"
    }
}

/// One server row in the inline picker: a menu-item-like row — hover fill,
/// accent checkmark on the selection. Picking connects and collapses.
private struct MenuServerRow: View {
    @EnvironmentObject var state: AppState
    let server: ProxyServer
    let onPick: () -> Void
    @State private var hovering = false

    private var selected: Bool { server.id == state.selectedServerID }

    var body: some View {
        Button {
            state.quickConnect(server.id)
            onPick()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.accent)
                    .opacity(selected ? 1 : 0)
                    .frame(width: 12)
                Text(server.name)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textHi)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if server.id == state.recommendedServerID {
                    BestBadge(neural: state.mlRankingEnabled && state.kxcLoaded)
                }
                PingBadge(result: state.pings[server.id])
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(hovering ? Theme.idle : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .onHover { hovering = $0 }
    }
}
