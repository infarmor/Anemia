import SwiftUI
import LoaderCore

/// Main window: a clean black interface. Connection is controlled only from the
/// top bar (a switch). The center shows the brand mark as a live status element
/// — no oversized button.
struct RootView: View {
    @EnvironmentObject var state: AppState
    @State private var showServers = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                Divider().overlay(Theme.stroke)
                Spacer(minLength: 0)
                statusHero
                Spacer(minLength: 0)
                VStack(spacing: 12) {
                    protectionRow
                    statsRow
                    serverCard
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
        }
        .frame(minWidth: 400, minHeight: 620)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showServers) { ServersSheet().environmentObject(state) }
        .sheet(isPresented: $showSettings) { SettingsSheet().environmentObject(state) }
    }

    // MARK: - Top bar (the only place to connect)

    private var topBar: some View {
        HStack(spacing: 10) {
            if let logo = AppAssets.logo {
                Image(nsImage: logo).resizable().scaledToFit().frame(height: 24)
            }
            Text("Anemia").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.textHi)

            Spacer()

            HStack(spacing: 10) {
                Text(statusWord)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(statusColor)
                if state.connection.isBusy {
                    ProgressView().controlSize(.small)
                }
                Toggle("", isOn: connectBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Theme.accent)
                    .disabled(state.selectedServer == nil && !state.isConnected)
                    .help("Connect / disconnect")

                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill").font(.system(size: 15))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.textLo)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var connectBinding: Binding<Bool> {
        Binding(
            get: { state.isConnected || state.connection == .connecting },
            set: { _ in state.toggleConnection() }
        )
    }

    // MARK: - Status hero (brand mark as status, not a button)

    private var statusHero: some View {
        VStack(spacing: 20) {
            ZStack {
                if state.isConnected {
                    Circle()
                        .fill(Theme.accent.opacity(0.18))
                        .frame(width: 170, height: 170)
                        .blur(radius: 45)
                }
                if let logo = AppAssets.logo {
                    Image(nsImage: logo)
                        .resizable().scaledToFit()
                        .frame(height: 132)
                        .saturation(state.isConnected ? 1 : 0)
                        .opacity(state.isConnected ? 1 : 0.45)
                        .animation(.easeInOut(duration: 0.35), value: state.isConnected)
                }
            }

            VStack(spacing: 6) {
                Text(statusTitle)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(statusColor)
                if let since = state.connectedSince, state.isConnected {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(Format.duration(since: since, now: ctx.date))
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.textLo)
                    }
                } else if case .error(let msg) = state.connection {
                    Text(msg).font(.caption).foregroundStyle(Theme.danger)
                        .multilineTextAlignment(.center).lineLimit(2).padding(.horizontal, 30)
                } else {
                    Text(state.selectedServer == nil ? "Choose a server to begin" : "Toggle the switch to connect")
                        .font(.caption).foregroundStyle(Theme.textLo)
                }
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Protection chips

    private var protectionRow: some View {
        HStack(spacing: 10) {
            ProtectionChip(title: "Kill switch", on: state.killSwitchEnabled, icon: "lock.shield")
            ProtectionChip(title: "Anti-DPI", on: antiDPIOn, icon: "waveform.path.ecg")
            ProtectionChip(title: state.tunnelActive ? "System" : "SOCKS",
                           on: state.tunnelActive, icon: "network")
        }
    }

    private var antiDPIOn: Bool { state.anti.fragment != nil || !state.anti.noises.isEmpty }

    // MARK: - Stats

    private var statsRow: some View {
        HStack(spacing: 12) {
            StatPill(icon: "arrow.down", tint: Theme.accent,
                     value: Format.speed(state.downlinkSpeed),
                     caption: Format.bytes(state.downlinkTotal))
            StatPill(icon: "arrow.up", tint: Theme.brand,
                     value: Format.speed(state.uplinkSpeed),
                     caption: Format.bytes(state.uplinkTotal))
        }
        .opacity(state.isConnected ? 1 : 0.4)
    }

    // MARK: - Server card

    private var serverCard: some View {
        Button { showServers = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.brand)
                    .frame(width: 34, height: 34)
                    .background(Theme.cardHi, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.selectedServer?.name ?? "No server selected")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textHi).lineLimit(1)
                    Text(serverSubtitle)
                        .font(.caption).foregroundStyle(Theme.textLo).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textLo)
            }
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Derived text

    private var serverSubtitle: String {
        guard let s = state.selectedServer else { return "Tap to import or choose a server" }
        var parts = [s.proto.rawValue.uppercased(), s.address]
        if s.security != .none { parts.append(s.security.rawValue) }
        return parts.joined(separator: " · ")
    }

    private var statusTitle: String {
        switch state.connection {
        case .connected: return state.tunnelActive ? "Protected" : "Connected (SOCKS)"
        case .connecting: return "Connecting…"
        case .error: return "Connection error"
        case .disconnected: return "Not connected"
        }
    }

    private var statusWord: String {
        switch state.connection {
        case .connected: return "On"
        case .connecting: return "…"
        case .error: return "Error"
        case .disconnected: return "Off"
        }
    }

    private var statusColor: Color {
        switch state.connection {
        case .connected: return state.tunnelActive ? Theme.accent : Theme.warn
        case .connecting: return Theme.warn
        case .error: return Theme.danger
        case .disconnected: return Theme.textLo
        }
    }
}

/// A compact up/down traffic stat.
struct StatPill: View {
    let icon: String
    let tint: Color
    let value: String
    let caption: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13, weight: .bold)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textHi)
                Text(caption).font(.system(size: 10)).foregroundStyle(Theme.textLo)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke))
    }
}

/// Small status pill showing whether a protection feature is active.
struct ProtectionChip: View {
    let title: String
    let on: Bool
    let icon: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(title).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(on ? Theme.accent : Theme.textLo)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(on ? Theme.accent.opacity(0.12) : Theme.card, in: Capsule())
        .overlay(Capsule().stroke(on ? Theme.accent.opacity(0.4) : Theme.stroke))
    }
}
