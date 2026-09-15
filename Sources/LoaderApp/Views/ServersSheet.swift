import SwiftUI
import LoaderCore

/// Server picker: a native inset list with the sheet's actions in its
/// toolbar — choose, ping, connect the fastest, import, refresh.
struct ServersSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showImport = false
    @State private var refreshing = false

    var body: some View {
        NavigationStack {
            Group {
                if state.allServers.isEmpty {
                    emptyState
                } else {
                    serverList
                }
            }
            .background(GroundBackground())
            .navigationTitle("Servers")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        Task {
                            refreshing = true
                            // The full round, not per-subscription refreshes:
                            // it also reselects a vanished server, ends a
                            // session whose server is gone and prunes history.
                            await state.refreshAllSubscriptions()
                            refreshing = false
                        }
                    } label: {
                        Label("Refresh Subscriptions", systemImage: "arrow.clockwise")
                    }
                    .disabled(state.subscriptions.isEmpty || refreshing)
                    .help("Refresh subscriptions")

                    Button { Task { await state.pingAll() } } label: {
                        Label("Ping All", systemImage: "gauge.with.dots.needle.bottom.50percent")
                    }
                    .disabled(state.allServers.isEmpty || state.isPinging)
                    .help("Re-measure latency to every server")

                    Button { showImport = true } label: {
                        Label("Import", systemImage: "plus")
                    }
                    .help("Import a share link or subscription")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !state.allServers.isEmpty {
                    HStack {
                        if state.isPinging || refreshing {
                            ProgressView().controlSize(.small)
                            Text(refreshing ? "Refreshing…" : "Measuring…")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(state.allServers.count) servers")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            state.requestConnectFastest()
                            dismiss()
                        } label: {
                            Label("Connect Fastest", systemImage: "bolt.fill")
                        }
                        .nativeButtonStyle(prominent: true)
                        .disabled(state.isPinging)
                    }
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.bar)
                }
            }
        }
        .frame(width: 480, height: 560)
        .sheet(isPresented: $showImport) { ImportView().environmentObject(state) }
    }

    private var selection: Binding<UUID?> {
        Binding(get: { state.selectedServerID },
                set: { if let id = $0 { state.select(id) } })
    }

    private var serverList: some View {
        List(selection: selection) {
            if !state.servers.isEmpty {
                Section("Added manually") {
                    ForEach(state.servers) { server in
                        ServerRow(server: server)
                            .tag(server.id)
                            .contextMenu { rowMenu(server, removable: true) }
                    }
                    .onDelete { offsets in
                        // IDs first: each removal shifts the indices the
                        // remaining offsets point at (and can run past the end).
                        let ids = offsets.map { state.servers[$0].id }
                        for id in ids { state.removeServer(id) }
                    }
                }
            }
            ForEach(state.subscriptions) { sub in
                Section {
                    ForEach(sub.servers) { server in
                        ServerRow(server: server)
                            .tag(server.id)
                            .contextMenu { rowMenu(server, removable: false) }
                    }
                } header: {
                    HStack {
                        Text(sub.name)
                        Spacer()
                        if let updated = sub.lastUpdated {
                            Text(updated, style: .relative).foregroundStyle(.tertiary)
                        }
                        Button {
                            Task {
                                refreshing = true
                                await state.refreshSubscription(sub.id)
                                refreshing = false
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Refresh \(sub.name)")
                        .disabled(refreshing)
                        Button(role: .destructive) {
                            state.removeSubscription(sub.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Delete \(sub.name)")
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .onDeleteCommand {
            if let id = state.selectedServerID, state.servers.contains(where: { $0.id == id }) {
                state.removeServer(id)
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ server: ProxyServer, removable: Bool) -> some View {
        Button("Connect") {
            state.quickConnect(server.id)
            dismiss()
        }
        Button("Select") { state.select(server.id) }
        if removable {
            Divider()
            Button("Delete", role: .destructive) { state.removeServer(server.id) }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if #available(macOS 14.0, *) {
            ContentUnavailableView {
                Label("No Servers", systemImage: "server.rack")
            } description: {
                Text("Import a vless, vmess, ss, trojan, hysteria2 or AmneziaWG link, or a subscription URL.")
            } actions: {
                Button("Import…") { showImport = true }
                    .nativeButtonStyle(prominent: true)
            }
        }
    }
}

/// One server row: name over protocol and endpoint, quality badges trailing.
private struct ServerRow: View {
    @EnvironmentObject var state: AppState
    let server: ProxyServer

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(server.proto.rawValue.uppercased()) · \(server.address):\(String(server.port))")
                        .lineLimit(1)
                    if let tier = state.qualityTier(server.id) { QualityTag(tier: tier) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if server.id == state.recommendedServerID {
                BestBadge(neural: state.mlRankingEnabled && state.kxcLoaded)
            }
            if let s = state.stability[server.id] { StabilityBars(score: s) }
            PingBadge(result: state.pings[server.id])
                .frame(minWidth: 44, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }
}
