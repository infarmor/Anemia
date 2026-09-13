import SwiftUI
import LoaderCore

/// Server picker: choose the active server, import links/subscriptions, refresh.
struct ServersSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showImport = false

    var body: some View {
        ZStack {
            // Same native vibrancy as every other surface of the app.
            VibrancyBackground()
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Servers").font(Theme.display(19)).tracking(Theme.tracking(for: 19))
                    Spacer()
                    Button { Task { await refreshAll() } } label: {
                        Image(systemName: "arrow.clockwise").font(Theme.ui(13))
                    }
                    .buttonStyle(PressableStyle(scale: 0.88)).foregroundStyle(Theme.textLo)
                    .pointerCursor()
                    .disabled(state.subscriptions.isEmpty)
                    .help("Refresh subscriptions")
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(Theme.ui(15)) }
                        .buttonStyle(PressableStyle(scale: 0.88)).foregroundStyle(Theme.textLo)
                        .pointerCursor()
                        .keyboardShortcut(.cancelAction)
                        .help("Close (Esc)")
                }

                if state.allServers.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(state.allServers) { server in
                                ServerRow(server: server)
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    PillButton(title: "Import", icon: "plus") { showImport = true }
                    GhostButton(title: "Ping all",
                                icon: "gauge.with.dots.needle.bottom.50percent",
                                busy: state.isPinging) {
                        Task { await state.pingAll() }
                    }
                    .disabled(state.allServers.isEmpty || state.isPinging)
                    GhostButton(title: "Fastest", icon: "bolt.fill",
                                tint: Theme.accent) {
                        state.requestConnectFastest()
                        dismiss()
                    }
                    .disabled(state.allServers.isEmpty || state.isPinging)
                    Spacer()
                }
            }
            .padding(20)
            .foregroundStyle(Theme.textHi)
        }
        .frame(width: 420, height: 520)
        .sheet(isPresented: $showImport) { ImportView().environmentObject(state) }
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Spacer()
            Image(systemName: "tray").font(Theme.ui(34)).foregroundStyle(Theme.textLo)
            Text("No servers yet").font(Theme.display(17)).tracking(Theme.tracking(for: 17))
                .foregroundStyle(Theme.textHi)
            Text("Import a vless:// / vmess:// / ss:// / trojan:// link or a subscription URL.")
                .font(Theme.ui(11)).foregroundStyle(Theme.textLo)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            // The action next to the explanation — the empty state should
            // lead somewhere, not just describe the wall.
            PillButton(title: "Import", icon: "plus") { showImport = true }
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func refreshAll() async {
        for sub in state.subscriptions { await state.refreshSubscription(sub.id) }
    }
}

/// One server row. Hover highlight + soft selected stroke, on the shared
/// radius system. Tap gesture instead of an outer Button: a Button nested
/// inside a .plain row Button can fire both actions on click (trash = select).
private struct ServerRow: View {
    @EnvironmentObject var state: AppState
    let server: ProxyServer
    @State private var hovering = false

    private var selected: Bool { server.id == state.selectedServerID }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Theme.accent : Theme.textLo)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).font(Theme.ui(13, .medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(server.proto.rawValue.uppercased()) · \(server.address):\(server.port)")
                        .font(Theme.ui(11)).foregroundStyle(Theme.textLo).lineLimit(1)
                    if let tier = state.qualityTier(server.id) { QualityTag(tier: tier) }
                }
            }
            Spacer()
            if server.id == state.recommendedServerID {
                BestBadge(neural: state.mlRankingEnabled && state.kxcLoaded)
            }
            if let s = state.stability[server.id] { StabilityBars(score: s) }
            PingBadge(result: state.pings[server.id])
            if state.servers.contains(where: { $0.id == server.id }) {
                Button { state.removeServer(server.id) } label: {
                    Image(systemName: "trash").font(Theme.ui(11))
                }
                .buttonStyle(PressableStyle(scale: 0.85))
                .foregroundStyle(hovering ? Theme.danger : Theme.textLo)
                .pointerCursor()
                .animation(Theme.springQuick, value: hovering)
            }
        }
        .padding(12)
        .softCard(fill: (selected || hovering) ? Theme.cardHi : Theme.card, shadow: false)
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .strokeBorder(selected ? Theme.accent.opacity(0.6) : Color.clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture { state.select(server.id) }
        .onHover { hovering = $0 }
        .animation(Theme.springQuick, value: hovering)
    }
}
