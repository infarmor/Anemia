import SwiftUI
import LoaderCore

/// Fast menu-bar control: connect, pick fastest, and one-tap server switching.
struct MenuContentView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            connectRow
            actionRow
            Divider()
            serverList
            Divider()
            footer
        }
        .padding(12)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            if let logo = AppAssets.logo {
                Image(nsImage: logo).resizable().scaledToFit().frame(height: 16)
            }
            Text("Anemia").font(.system(size: 14, weight: .bold))
            Spacer()
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(statusText).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Connect

    private var connectRow: some View {
        Button(action: state.toggleConnection) {
            HStack {
                Image(systemName: state.isConnected ? "stop.circle.fill" : "play.circle.fill")
                Text(buttonTitle)
                Spacer()
                if state.connection.isBusy { ProgressView().controlSize(.small) }
                else if let ms = state.proxyLatency, state.isConnected { Text("\(ms) ms").font(.caption).monospacedDigit() }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(state.selectedServer == nil && !state.isConnected)
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button { Task { await state.connectFastest() } } label: {
                Label("Fastest", systemImage: "bolt.fill").frame(maxWidth: .infinity)
            }
            .disabled(state.allServers.isEmpty || state.isPinging)
            Button { Task { await state.pingAll() } } label: {
                HStack { if state.isPinging { ProgressView().controlSize(.mini) } else { Image(systemName: "gauge.with.dots.needle.bottom.50percent") }; Text("Ping") }
                    .frame(maxWidth: .infinity)
            }
            .disabled(state.allServers.isEmpty || state.isPinging)
        }
        .font(.caption)
    }

    // MARK: - Servers

    private var serverList: some View {
        Group {
            if state.allServers.isEmpty {
                Text("No servers — import in the main window.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(state.allServers) { server in
                            Button { state.quickConnect(server.id) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: server.id == state.selectedServerID ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(server.id == state.selectedServerID ? Color.accentColor : .secondary)
                                        .font(.caption)
                                    Text(server.name).lineLimit(1)
                                    Spacer()
                                    PingBadge(result: state.pings[server.id])
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 3).padding(.horizontal, 4)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button { openWindow(id: "main") } label: { Label("Open Anemia", systemImage: "macwindow") }
            Spacer()
            Button(role: .destructive) { NSApplication.shared.terminate(nil) } label: {
                Label("Quit", systemImage: "power")
            }
        }
        .font(.caption)
    }

    // MARK: - Derived

    private var statusColor: Color {
        switch state.connection {
        case .connected: return state.tunnelActive ? .green : .orange
        case .connecting: return .yellow
        case .error: return .red
        case .disconnected: return .secondary
        }
    }
    private var statusText: String {
        switch state.connection {
        case .connected: return state.tunnelActive ? "Connected" : "SOCKS"
        case .connecting: return "Connecting…"
        case .error: return "Error"
        case .disconnected: return "Off"
        }
    }
    private var buttonTitle: String {
        switch state.connection {
        case .connected, .error: return "Disconnect"
        case .connecting: return "Connecting…"
        case .disconnected: return "Connect"
        }
    }
}
