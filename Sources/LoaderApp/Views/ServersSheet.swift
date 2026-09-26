import SwiftUI
import LoaderCore

/// Server picker: a native inset list with the sheet's actions in its
/// toolbar — choose, ping, connect the fastest, import, refresh.
struct ServersSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showImport = false
    @State private var refreshing = false
    @State private var query = ""

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
            .searchable(text: $query, placement: .toolbar, prompt: "Country, city or address")
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
                            // A user press, so unencrypted panels refresh too
                            // — the row shows the "no TLS" mark.
                            await state.refreshAllSubscriptions(allowInsecure: true)
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

                    Button { Task { await state.checkServers() } } label: {
                        Label("Check Servers", systemImage: "checkmark.seal")
                    }
                    .disabled(state.allServers.isEmpty || state.checkProgress != nil)
                    .help("Send a real request through every server — finds the ones that answer pings but carry nothing")

                    Button { showImport = true } label: {
                        Label("Import", systemImage: "plus")
                    }
                    .help("Import a share link or subscription")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !state.allServers.isEmpty {
                    HStack {
                        if let progress = state.checkProgress {
                            ProgressView().controlSize(.small)
                            Text("Checked \(progress.done) of \(progress.total)")
                                .foregroundStyle(.secondary)
                        } else if state.isPinging || refreshing {
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

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// By name, country (in English or the system's language), protocol or
    /// address.
    private func matches(_ server: ProxyServer) -> Bool {
        let code = state.serverCountry(server.name)
        let fields = [server.name, server.address, server.proto.rawValue, code ?? "",
                      code.flatMap { Locale(identifier: "en_US").localizedString(forRegionCode: $0) } ?? "",
                      code.flatMap { Locale.current.localizedString(forRegionCode: $0) } ?? ""]
        return fields.contains { $0.range(of: trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    private var serverList: some View {
        List(selection: selection) {
            if !trimmedQuery.isEmpty {
                let found = state.allServers.filter(matches)
                Section(found.isEmpty ? "No matches" : "Found \(found.count)") {
                    ForEach(found) { server in
                        ServerRow(server: server)
                            .tag(server.id)
                            .contextMenu { rowMenu(server, removable: state.servers.contains { $0.id == server.id }) }
                    }
                }
            } else {
                groupedSections
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

    @ViewBuilder private var groupedSections: some View {
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
                    if let info = state.subscriptionInfo[sub.id] {
                        SubscriptionInfoRow(info: info)
                    }
                    ForEach(sub.servers) { server in
                        ServerRow(server: server)
                            .tag(server.id)
                            .contextMenu { rowMenu(server, removable: false) }
                    }
                } header: {
                    HStack {
                        Text(state.displayName(of: sub))
                        if !sub.tlsProtected {
                            // Same mark the Android list shows: a panel
                            // without TLS is skipped by auto-refresh.
                            Image(systemName: "lock.open.fill")
                                .foregroundStyle(.orange)
                                .help("No TLS — never refreshed automatically, only on press")
                        }
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
            if let learned = state.learnedMasking(for: server), learned != state.maskingProfile {
                Image(systemName: "theatermasks.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                    .help("\(learned.title) masking gets this server through on this network")
            }
            if let s = state.stability[server.id] { StabilityBars(score: s) }
            switch state.verdicts[server.id] {
            case .works(let ms):
                Label(Format.ping(ms), systemImage: "checkmark.seal.fill")
                    .labelStyle(.titleAndIcon)
                    .font(Theme.metric(11))
                    .foregroundStyle(Theme.textHi)
                    .help("A real request through this server took \(ms) ms")
            case .broken(let reason):
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                    .help("Answers, but a real request didn't get through: \(reason)")
            case nil:
                PingBadge(result: state.pings[server.id])
                    .frame(minWidth: 44, alignment: .trailing)
            }
        }
        .padding(.vertical, 3)
    }
}

/// What the panel says about a subscription: traffic left, how long, its
/// notice and links.
private struct SubscriptionInfoRow: View {
    let info: SubscriptionInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let traffic = info.trafficText {
                HStack {
                    Text(traffic)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.textHi)
                    Spacer(minLength: 8)
                    if let fraction = info.usedFraction {
                        Text("\(Int((fraction * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.textLo)
                    }
                }
            }
            if let fraction = info.usedFraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(fraction > 0.9 ? Theme.accent : Theme.textHi)
            }
            HStack(spacing: 12) {
                if let expiry = info.expiryText {
                    Label(expiry, systemImage: "calendar")
                        .foregroundStyle(info.needsAttention() ? Theme.accent : Theme.textLo)
                }
                Spacer(minLength: 0)
                if let url = info.webPageURL {
                    Link("Account", destination: url)
                }
                if let url = info.supportURL {
                    Link("Support", destination: url)
                }
            }
            .font(.caption)
            if let announcement = info.announcement {
                Text(announcement)
                    .font(.caption)
                    .foregroundStyle(Theme.textLo)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
        .selectionDisabled()
    }
}
