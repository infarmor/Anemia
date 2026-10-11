import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LoaderCore

/// Main window — one continuous column on the window's own material: the
/// world map as the hero with the connection state laid over it, the server
/// you exit through, live traffic, and the protection posture as a grouped
/// settings box. The VPN switch and Settings live in the window toolbar.
struct RootView: View {
    @EnvironmentObject var state: AppState
    /// Reduced motion: slides become cross-fades, springs become instant.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showServers = false
    @State private var showImport = false
    @State private var showStats = false
    @State private var showLeakTest = false
    @State private var dropping = false

    var body: some View {
        VStack(spacing: 0) {
            // A broken network outranks everything: it comes first.
            if !state.networkIssues.isEmpty {
                networkIssuesBanner
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .transition(noticeTransition)
            }
            hero
            VStack(spacing: 18) {
                serverBar
                trafficStrip
                protectionGroup
                notices
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            Spacer(minLength: 0)
        }
        .animation(reduceMotion ? nil : Theme.spring, value: state.networkIssues)
        .animation(reduceMotion ? nil : Theme.spring, value: noticeKey)
        .frame(minWidth: 520, minHeight: 540)
        .background(GroundBackground())
        // One continuous window: no title band — Settings and, to its right,
        // the VPN switch sit on the ground beside the traffic lights.
        .navigationTitle("Anemia")
        .toolbar { windowToolbar }
        .seamlessWindowChrome()
        .sheet(isPresented: $showServers) { ServersSheet().environmentObject(state) }
        .sheet(isPresented: $showImport) { ImportView().environmentObject(state) }
        .sheet(isPresented: $showStats) { StatsSheet().environmentObject(state) }
        .sheet(isPresented: $showLeakTest) { LeakTestSheet().environmentObject(state) }
        // Drag & drop: share links (as text) or a .txt list dropped anywhere
        // on the window open the import sheet prefilled.
        .onDrop(of: [UTType.text, UTType.fileURL], isTargeted: $dropping) { providers in
            Task { @MainActor in
                guard let text = await Self.droppedText(from: providers) else { return }
                state.pendingImportText = text
                showImport = true
            }
            return true
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 2)
                    .padding(6)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(Theme.springQuick, value: dropping)
        // Live traffic stats are visible → the poller samples at full cadence.
        .onAppear { state.statsViewOpened() }
        .onDisappear { state.statsViewClosed() }
    }

    private var noticeTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var windowToolbar: some ToolbarContent {
        // Leading: the app's mark where the title used to be.
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) { BrandMark() }
                .sharedBackgroundVisibility(.hidden)
            // Without a title nothing pushed the controls to the trailing
            // edge: they bunched up beside the traffic lights.
            ToolbarSpacer(.flexible)
        } else {
            ToolbarItem(placement: .navigation) { BrandMark() }
        }
        if state.killSwitchEnabled {
            ToolbarItem(placement: .primaryAction) {
                Image(systemName: state.tunnelActive ? "lock.shield.fill" : "lock.shield")
                    .foregroundStyle(state.tunnelActive ? Theme.accent : Theme.textLo)
                    .help(state.tunnelActive
                          ? "Kill switch armed — traffic is blocked if the tunnel drops"
                          : "Kill switch on — arms with the system tunnel")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings (⌘,)")
        }
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: connectBinding) {
                Label("VPN", systemImage: "power")
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)
            .labelsHidden()
            .keyboardShortcut(.return, modifiers: .command)
            .help(connectHelp)
            .accessibilityLabel("VPN")
        }
    }

    /// The switch drives the connection. No server yet → turning it on opens
    /// the picker instead (the switch reads the real state, so it bounces back
    /// off); from an error it cleans up and reconnects.
    private var connectBinding: Binding<Bool> {
        Binding(
            get: { state.isConnected || state.connection == .connecting },
            set: { on in
                if on, state.selectedServer == nil, !state.isConnected {
                    showServers = true
                    return
                }
                state.setConnected(on)
            }
        )
    }

    private var connectHelp: String {
        state.isConnected || state.connection == .connecting
            ? "Disconnect (⌘↩)"
            : (state.selectedServer == nil ? "Choose a server first (⌘↩)" : "Connect (⌘↩)")
    }

    // MARK: - Hero (map + state)

    /// The map carries the session — exit, home, the live route — and the
    /// state is written straight onto it; its edges fade into the window, so
    /// there is no box around the most important thing on screen.
    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            MiniMap()
                .frame(maxWidth: .infinity)
                .frame(height: 230)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    statusGlyph
                    Text(statusTitle)
                        .font(.system(size: 28, weight: .medium, design: .serif))
                        .tracking(-0.3)
                        .foregroundStyle(headlineColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .contentTransition(.opacity)
                }
                heroDetail
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
            .help(statusDetail)
        }
        .animation(reduceMotion ? nil : Theme.spring, value: statusTitle)
    }

    @ViewBuilder private var statusGlyph: some View {
        if state.connection == .connecting && !state.waitingForNetwork {
            ProgressView()
                .controlSize(.regular)
                .frame(width: 28, height: 28)
        } else {
            Image(systemName: statusSymbol)
                .font(.system(size: 22, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(state.connection == .disconnected ? Theme.textLo : headlineColor)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 28)
        }
    }

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

    /// Under the headline: the live session (time · latency · capacity) while
    /// connected; otherwise what to do next, or why the last attempt failed.
    @ViewBuilder private var heroDetail: some View {
        if let since = state.connectedSince, state.isConnected {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                HStack(spacing: 5) {
                    Text(Format.duration(since: since, now: ctx.date))
                    if let ms = state.proxyLatency {
                        Text("·")
                        Text(Format.ping(ms)).foregroundStyle(latencyColor(ms))
                    }
                    if let tp = state.proxyThroughput {
                        Text("·")
                        Text(Format.speed(tp))
                    }
                }
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textLo)
                .lineLimit(1)
            }
        } else {
            Text(heroHint)
                .font(.system(size: 13))
                .foregroundStyle(state.connection.isError ? Theme.textHi : Theme.textLo)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var heroHint: String {
        if case .error(let message) = state.connection { return message }
        if state.waitingForNetwork {
            return "No network — the tunnel stays armed and resumes on its own"
        }
        if state.connection == .connecting {
            return state.selectedServer.map { "Reaching \($0.name)…" } ?? "Connecting…"
        }
        return state.selectedServer == nil
            ? "Choose a server to get started"
            : "Turn on the switch above to connect"
    }

    // MARK: - Server

    /// The server the bar names. While a session is up (or coming up) that is
    /// the one it dials: picking a row in the list moves the selection without
    /// reconnecting, so naming `selectedServer` there printed the address of an
    /// exit no traffic was going through, under "Protected". MiniMap and
    /// StatsSheet already read the session this way.
    private var shownServer: ProxyServer? {
        let live = state.isConnected || state.connection == .connecting
        return (live ? state.sessionServer : nil) ?? state.selectedServer
    }

    private var serverBar: some View {
        HStack(spacing: 10) {
            Button { showServers = true } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(shownServer?.name ?? "Choose a Server")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textHi)
                            .lineLimit(1)
                        Text(serverSubtitle)
                            .font(.caption)
                            .foregroundStyle(Theme.textLo)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let id = shownServer?.id {
                        if let s = state.stability[id] { StabilityBars(score: s) }
                        PingBadge(result: state.pings[id])
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textLo)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
            }
            .controlSize(.large)
            .nativeButtonStyle()
            .keyboardShortcut("k", modifiers: .command)
            .help("Choose a server (⌘K)")

            roundAction(symbol: "bolt.fill", busy: false,
                        help: "Ping all, then connect the most stable foreign server (⌘F)") {
                state.requestConnectFastest()
            }
            .keyboardShortcut("f", modifiers: .command)

            roundAction(symbol: "gauge.with.dots.needle.bottom.50percent", busy: state.isPinging,
                        help: "Re-measure latency to every server (⌘R)") {
                Task { await state.pingAll() }
            }
            .keyboardShortcut("r", modifiers: .command)
        }
    }

    private func roundAction(symbol: String, busy: Bool, help: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol)
                }
            }
            .frame(width: 22, height: 22)
        }
        .controlSize(.large)
        .buttonBorderShape(.circle)
        .nativeButtonStyle()
        .disabled(state.allServers.isEmpty || state.isPinging)
        .help(help)
    }

    private var serverSubtitle: String {
        guard let s = shownServer else { return "Import a link or pick from your list" }
        var parts = [s.proto.rawValue.uppercased(), s.address]
        if s.security != .none { parts.append(s.security.rawValue) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Traffic

    /// Click for Statistics (what went through the VPN, the speed test).
    private var trafficStrip: some View {
        Button { showStats = true } label: {
            HStack(spacing: 18) {
                trafficMetric(symbol: "arrow.down.circle.fill", tint: Theme.accent, label: "Download",
                              speed: state.downlinkSpeed, total: state.downlinkTotal)
                trafficMetric(symbol: "arrow.up.circle.fill", tint: Theme.textLo, label: "Upload",
                              speed: state.uplinkSpeed, total: state.uplinkTotal)
                TrafficSparkline()
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
            }
            .opacity(state.isConnected ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("y", modifiers: .command)
        .help("Statistics and speed test (⌘Y)")
        .animation(reduceMotion ? nil : Theme.spring, value: state.isConnected)
    }

    private func trafficMetric(symbol: String, tint: Color, label: String,
                               speed: Int64, total: Int64) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(Format.speed(speed))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textHi)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .snappy, value: speed)
                Text(Format.bytes(total))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textLo)
            }
            .lineLimit(1)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(Format.speed(speed)), \(Format.bytes(total)) total")
    }

    // MARK: - Protection

    /// The System Settings row grammar: a colored glyph tile, title over
    /// caption, the control trailing.
    private var protectionGroup: some View {
        VStack(spacing: 0) {
            protectionRow(symbol: "lock.shield.fill", active: state.killSwitchEnabled,
                          title: "Kill switch", caption: killSwitchCaption) {
                Toggle("Kill switch", isOn: Binding(get: { state.killSwitchEnabled },
                                                    set: { state.setKillSwitch($0) }))
                    .toggleStyle(.switch)
                    .tint(Theme.accent)
                    .labelsHidden()
            }
            rowDivider
            protectionRow(symbol: "theatermasks.fill", active: state.maskingProfile != .off,
                          title: "DPI masking", caption: maskingCaption) {
                Picker("DPI masking", selection: Binding(get: { state.maskingProfile },
                                                         set: { state.setMaskingProfile($0) })) {
                    ForEach(MaskingProfile.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(Theme.accent)
                .fixedSize()
            }
            rowDivider
            protectionRow(symbol: "hand.raised.fill", active: state.adBlockEnabled,
                          title: "Block ads", caption: adBlockCaption) {
                Toggle("Block ads", isOn: Binding(get: { state.adBlockEnabled },
                                                  set: { state.setAdBlock($0) }))
                    .toggleStyle(.switch)
                    .tint(Theme.accent)
                    .labelsHidden()
            }
            rowDivider
            protectionRow(symbol: "eye.slash.fill", active: leakTestPassed,
                          title: "Leak test", caption: leakCaption) {
                Button("Test…") { showLeakTest = true }
                    .nativeButtonStyle()
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .help("Which address sites see, and whether DNS or IPv6 leak (⇧⌘L)")
            }
            rowDivider
            protectionRow(symbol: "arrow.triangle.branch", active: state.tunnelActive && state.proxyReachable,
                          title: "Traffic mode", caption: modeCaption) {
                HStack(spacing: 6) {
                    Circle().fill(modeColor).frame(width: 7, height: 7)
                    Text(modeTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(modeColor)
                }
                .fixedSize()
            }
            .help(statusDetail)
        }
        .padding(.vertical, 2)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 50)
    }

    /// The glyph tile is the row's state at a glance: filled accent while the
    /// feature is doing its job, a quiet ink tile while it isn't.
    private func protectionRow<Accessory: View>(symbol: String, active: Bool, title: String,
                                                caption: String,
                                                @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? Color.white : Theme.textLo)
                .frame(width: 26, height: 26)
                .background(active ? AnyShapeStyle(Theme.accent.gradient) : AnyShapeStyle(Theme.idle),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .animation(reduceMotion ? nil : Theme.spring, value: active)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textHi)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(Theme.textLo)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            accessory()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    /// The helper bakes the kill switch into the tunnel at connect time, so a
    /// mid-session flip applies from the next connect — say so.
    private var killSwitchCaption: String {
        state.isConnected ? "Blocks traffic if the tunnel drops · next connect" : "Blocks traffic if the tunnel drops"
    }

    /// AdGuard DNS is baked into the engine's DNS at connect time.
    private var adBlockCaption: String {
        let base = "Ads and trackers blocked by DNS (AdGuard)"
        return state.isConnected ? base + " · next connect" : base
    }

    private var leakTestServer: UUID? {
        state.isConnected ? state.sessionServerID : nil
    }

    private var leakTestPassed: Bool {
        state.leakTest.isCurrent(server: leakTestServer) && state.leakTest.report?.verdict == .clean
    }

    /// The last result while it still describes the connection.
    private var leakCaption: String {
        guard state.leakTest.isCurrent(server: leakTestServer), let report = state.leakTest.report else {
            return "Which address sites see; whether DNS or IPv6 leak"
        }
        let ip = report.exit?.ip ?? ""
        switch report.verdict {
        case .clean: return "Sites see \(ip) — no leaks"
        case .leaks: return "Leaks found — open the test"
        case .unknown: return "Sites see \(ip)"
        case .unprotected: return "Without the VPN sites see \(ip)"
        case .failed: return "The last test failed"
        }
    }

    /// Masking is baked into the engine config at connect time.
    private var maskingCaption: String {
        state.isConnected ? state.maskingProfile.subtitle + " · next connect" : state.maskingProfile.subtitle
    }

    private var modeCaption: String {
        let bypassed = state.splitTunnel.activeEntries.count
        return bypassed == 0 ? "Where your traffic goes" : "\(bypassed) destination\(bypassed == 1 ? "" : "s") bypass the VPN"
    }

    private var modeTitle: String {
        guard state.isConnected else { return "Off" }
        if !state.proxyReachable { return "No route" }
        if state.tunnelActive { return "System tunnel" }
        return state.systemTunnelError != nil ? "Tunnel failed" : "SOCKS only"
    }

    /// Same truth table as the headline — reachability first.
    private var modeColor: Color {
        guard state.isConnected else { return Theme.textLo }
        return state.tunnelActive && state.proxyReachable ? Theme.accent : Theme.textHi
    }

    // MARK: - Notices

    private var showsDomesticWarning: Bool {
        guard let id = state.selectedServerID else { return false }
        return !state.isForeignExit(id) || state.isRussianExit(id)
    }

    private var showsCoexistHint: Bool {
        state.isConnected && state.tunnelBlockedByAnotherVPN && !state.systemProxyEnabled && state.helperInstalled
    }

    private var recommendation: ProxyServer? {
        guard let rec = state.recommendedServer, rec.id != state.selectedServerID else { return nil }
        return rec
    }

    /// A helper that answered with another version: the full tunnel stays off
    /// until it's updated (connect checks the same thing).
    private var showsHelperUpdate: Bool {
        state.helperInstalled && state.helperVersion != nil && !state.helperCurrent
    }

    /// The subscription behind the selected server, when it's about to run
    /// out (time or traffic) — with what its panel says.
    private var endingSubscription: (sub: Subscription, info: SubscriptionInfo)? {
        guard let id = state.selectedServerID, let sub = state.subscription(containing: id),
              let info = state.subscriptionInfo[sub.id], info.needsAttention()
        else { return nil }
        return (sub, info)
    }

    private var noticeKey: String {
        "\(showsHelperUpdate)|\(showsDomesticWarning)|\(recommendation?.id.uuidString ?? "")|\(showsCoexistHint)|\(endingSubscription?.sub.id.uuidString ?? "")"
    }

    @ViewBuilder private var notices: some View {
        if showsHelperUpdate || showsDomesticWarning || recommendation != nil || showsCoexistHint
            || endingSubscription != nil {
            VStack(spacing: 8) {
                if let ending = endingSubscription {
                    NoticeRow(symbol: "clock.badge.exclamationmark.fill", tint: Theme.accent,
                              title: "\(state.displayName(of: ending.sub)): \(ending.info.expiryText ?? "running out")",
                              message: ending.info.trafficText) {
                        if let url = ending.info.webPageURL ?? ending.info.supportURL {
                            Link("Renew", destination: url)
                                .nativeButtonStyle()
                        }
                    }
                    .transition(noticeTransition)
                }
                if showsHelperUpdate {
                    NoticeRow(symbol: "arrow.down.circle.fill", tint: Theme.accent,
                              title: "Update the privileged helper",
                              message: "The installed version can't carry the system tunnel.") {
                        if state.helperBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Update…") { Task { _ = await state.installHelper() } }
                                .nativeButtonStyle(prominent: true)
                        }
                    }
                    .transition(noticeTransition)
                }
                if showsDomesticWarning {
                    NoticeRow(symbol: "exclamationmark.triangle.fill", tint: Theme.textHi,
                              title: "This exit can't bypass the block",
                              message: "It's inside the censored region — pick a foreign server.")
                        .transition(noticeTransition)
                }
                if let rec = recommendation {
                    let neural = state.mlRankingEnabled && state.kxcLoaded
                    NoticeRow(symbol: neural ? "sparkles" : "bolt.fill", tint: Theme.accent,
                              title: (neural ? "kxc recommends " : "Faster: ") + rec.name) {
                        Button(state.isConnected ? "Switch" : "Select") {
                            if state.isConnected { state.quickConnect(rec.id) } else { state.select(rec.id) }
                        }
                        .nativeButtonStyle()
                    }
                    .transition(noticeTransition)
                }
                if showsCoexistHint {
                    NoticeRow(symbol: "arrow.triangle.branch", tint: Theme.accent,
                              title: "Another VPN owns the system routes",
                              message: "Apps aren't going through Anemia yet.") {
                        Button("Route Apps") { state.setSystemProxyEnabled(true) }
                            .nativeButtonStyle(prominent: true)
                            .help("Point the system SOCKS proxy at Anemia while connected — restored on disconnect")
                    }
                    .transition(noticeTransition)
                }
            }
        }
    }

    /// Leftover network settings that keep the Mac offline (found by the
    /// launch / disconnect scan) — with the one-click fix, helper or not.
    private var networkIssuesBanner: some View {
        NoticeRow(symbol: "wifi.exclamationmark", tint: Theme.accent,
                  title: "Network settings need repair",
                  message: state.networkIssues.first?.message) {
            if state.repairInProgress {
                ProgressView().controlSize(.small)
            } else {
                Button("Repair") { Task { await state.repairNetwork() } }
                    .nativeButtonStyle(prominent: true)
            }
        }
        .help(state.networkIssues.map(\.message).joined(separator: "\n"))
    }

    // MARK: - Derived

    /// One-line truth for the session — reachability first, then tunnel mode.
    private var statusDetail: String {
        if case .error(let msg) = state.connection { return msg }
        guard state.isConnected else {
            return state.selectedServer == nil ? "No server selected — pick one" : "Not connected"
        }
        if !state.proxyReachable { return "The engine is up but traffic isn't getting through to the server" }
        if state.tunnelActive { return "All system traffic is routed through the tunnel" }
        if let err = state.systemTunnelError { return err }
        return "Only proxy-aware apps are routed; install the helper for the full tunnel (Settings → Network)"
    }

    private func latencyColor(_ ms: Int) -> Color {
        ms < 120 ? Theme.textHi : (ms < 300 ? Theme.textLo : Theme.tierFair)
    }

    private var statusTitle: String {
        switch state.connection {
        case .connected:
            if !state.proxyReachable { return "No route to server" }
            if state.tunnelActive { return "Protected" }
            // A failed system tunnel must read as a failure, not as a working
            // connection: the reason is in the tooltip and the log.
            return state.systemTunnelError != nil ? "Tunnel failed" : "Connected (SOCKS)"
        case .connecting: return state.waitingForNetwork ? "Waiting for network" : "Connecting…"
        case .error: return "Connection error"
        case .disconnected: return "Not connected"
        }
    }

    private var headlineColor: Color {
        switch state.connection {
        case .connected:
            // Only a working, fully protected session earns the accent; every
            // degraded state is ink, told apart by its shield glyph and words.
            return state.tunnelActive && state.proxyReachable ? Theme.accent : Theme.textHi
        case .connecting: return Theme.accent
        case .error: return Theme.textHi
        case .disconnected: return Theme.textHi
        }
    }

    /// Pulls usable text out of drop providers: dragged text, or the contents
    /// of a dropped file (a .txt server list). nil when nothing readable.
    private static func droppedText(from providers: [NSItemProvider]) async -> String? {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                if case let item as Data = try? await provider.loadItem(
                    forTypeIdentifier: UTType.fileURL.identifier, options: nil),
                   let url = URL(dataRepresentation: item, relativeTo: nil),
                   let text = try? String(contentsOf: url, encoding: .utf8),
                   !text.isEmpty {
                    return text
                }
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                if case let item as Data = try? await provider.loadItem(
                    forTypeIdentifier: UTType.text.identifier, options: nil),
                   let text = String(data: item, encoding: .utf8), !text.isEmpty {
                    return text
                }
                if case let text as String = try? await provider.loadItem(
                    forTypeIdentifier: UTType.text.identifier, options: nil),
                   !text.isEmpty {
                    return text
                }
            }
        }
        return nil
    }
}

private extension AppState.ConnectionState {
    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}

/// A soft, tinted notice: glyph, title over an optional message, an optional
/// trailing action. No border — the tint alone sets it apart.
struct NoticeRow<Accessory: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var message: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textHi)
                    .lineLimit(1)
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Theme.textLo)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            accessory
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension NoticeRow where Accessory == EmptyView {
    init(symbol: String, tint: Color, title: String, message: String? = nil) {
        self.init(symbol: symbol, tint: tint, title: title, message: message, accessory: { EmptyView() })
    }
}

extension View {
    /// Sets the hover cursor on custom, non-button tiles. Uses `.set()` rather
    /// than push/pop so it can't leave the stack unbalanced when a hovered
    /// view disappears.
    func pointerCursor(_ cursor: NSCursor = .pointingHand) -> some View {
        onHover { inside in (inside ? cursor : NSCursor.arrow).set() }
    }
}

extension View {
    /// One continuous surface, the way Claude's window reads: no toolbar band,
    /// no separator hairline — the traffic lights and the toolbar controls sit
    /// straight on the warm ground. `keepsTitle` leaves the window title in
    /// place (the Settings window names its tab there).
    func seamlessWindowChrome(keepsTitle: Bool = false) -> some View {
        modifier(SeamlessWindowChrome(keepsTitle: keepsTitle))
    }
}

private struct SeamlessWindowChrome: ViewModifier {
    let keepsTitle: Bool
    @Environment(\.snapshotRendering) private var snapshotRendering

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .toolbar(removing: keepsTitle ? nil : .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .background { if !snapshotRendering { WindowChromeConfigurator(keepsTitle: keepsTitle) } }
        } else {
            content
                .background { if !snapshotRendering { WindowChromeConfigurator(keepsTitle: keepsTitle) } }
        }
    }
}

/// The AppKit half: a transparent titlebar without its separator (macOS 14
/// has no SwiftUI spelling for either, and later systems keep the hairline).
private struct WindowChromeConfigurator: NSViewRepresentable {
    let keepsTitle: Bool

    func makeNSView(context: Context) -> NSView { ChromeView(keepsTitle: keepsTitle) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ChromeView: NSView {
        let keepsTitle: Bool

        init(keepsTitle: Bool) {
            self.keepsTitle = keepsTitle
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            if !keepsTitle { window.titleVisibility = .hidden }
            window.titlebarSeparatorStyle = .none
        }
    }
}

/// The window's mark where the title used to be: the Anemia glyph in clay
/// beside the name in the headline serif.
private struct BrandMark: View {
    var body: some View {
        HStack(spacing: 7) {
            if let logo = AppAssets.logo {
                Image(nsImage: logo)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 17, height: 17)
                    .foregroundStyle(Theme.accent)
            }
            Text("Anemia")
                .font(.system(size: 15, weight: .semibold, design: .serif))
                .foregroundStyle(Theme.textHi)
        }
        .fixedSize()
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Anemia")
    }
}
