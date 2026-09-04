import SwiftUI
import LoaderCore

/// Server picker: choose the active server, import links/subscriptions, refresh.
struct ServersSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showImport = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Servers").font(.system(size: 18, weight: .bold))
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Theme.textLo)
                }

                if state.allServers.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(state.allServers) { server in
                                row(server)
                            }
                        }
                    }
                }

                HStack {
                    Button { showImport = true } label: {
                        Label("Import", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accentDim)
                    Button { Task { await state.pingAll() } } label: {
                        HStack(spacing: 4) {
                            if state.isPinging { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "gauge.with.dots.needle.bottom.50percent") }
                            Text("Ping all")
                        }
                    }
                    .buttonStyle(.bordered).tint(Theme.textLo)
                    .disabled(state.allServers.isEmpty || state.isPinging)
                    Button { Task { await state.connectFastest(); dismiss() } } label: {
                        Label("Fastest", systemImage: "bolt.fill")
                    }
                    .buttonStyle(.bordered).tint(Theme.accent)
                    .disabled(state.allServers.isEmpty || state.isPinging)
                    Spacer()
                }
            }
            .padding(20)
            .foregroundStyle(Theme.textHi)
        }
        .frame(width: 420, height: 520)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showImport) { ImportView().environmentObject(state) }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray").font(.system(size: 34)).foregroundStyle(Theme.textLo)
            Text("No servers yet").foregroundStyle(Theme.textHi)
            Text("Import a vless:// / vmess:// / ss:// / trojan:// link or a subscription URL.")
                .font(.caption).foregroundStyle(Theme.textLo)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ server: ProxyServer) -> some View {
        let selected = server.id == state.selectedServerID
        return Button {
            state.select(server.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Theme.accent : Theme.textLo)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Text("\(server.proto.rawValue.uppercased()) · \(server.address):\(server.port)")
                        .font(.caption2).foregroundStyle(Theme.textLo).lineLimit(1)
                }
                Spacer()
                PingBadge(result: state.pings[server.id])
                if state.servers.contains(where: { $0.id == server.id }) {
                    Button { state.removeServer(server.id) } label: {
                        Image(systemName: "trash").font(.caption)
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.danger)
                }
            }
            .padding(12)
            .background(selected ? Theme.cardHi : Theme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Theme.accent.opacity(0.5) : Theme.stroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func refreshAll() async {
        for sub in state.subscriptions { await state.refreshSubscription(sub.id) }
    }
}
