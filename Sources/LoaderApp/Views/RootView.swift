import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LoaderCore

/// Main window: a clean, minimal interface. The top-bar switch is the single
/// connect control, and the connection state reads out right next to the
/// brand — lamp + status (+ session time / latency / throughput while up), so
/// the whole window below can stay one compact column of actions and data.
struct RootView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme
    /// Reduced motion: slide-in transitions become plain cross-fades —
    /// gentler equivalents, not absence of feedback.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showServers = false
    @State private var showSettings = false
    @State private var showImport = false
    @State private var dropping = false
    @State private var hoverServerCard = false
    @State private var hoverGear = false

    var body: some View {
        ZStack {
            // Native window vibrancy (desktop blur) with the warm tint
            // layered over it — the System Settings material treatment.
            VibrancyBackground()
            VStack(spacing: 0) {
                topBar
                Divider().overlay(Theme.stroke)
                VStack(spacing: 10) {
                    // Hierarchy, top → bottom: act (pick a server), act again
                    // (fastest / re-ping), then read (traffic + where in the
                    // world you exit, side by side), then trust (protection).
                    serverCard
                    quickActions
                    bottomColumns
                    if let id = state.selectedServerID,
                       !state.isForeignExit(id) || state.isRussianExit(id) {
                        domesticExitWarning
                            .transition(columnReflowTransition)
                    }
                    if let rec = state.recommendedServer, rec.id != state.selectedServerID {
                        recommendationChip(rec)
                            .transition(columnReflowTransition)
                    }
                }
                // Warnings and the recommendation slide in/out with the
                // selection instead of popping: the column reflows smoothly
                // whenever the picked (or recommended) server changes.
                .animation(Theme.spring,
                           value: [state.selectedServerID, state.recommendedServer?.id])
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)
                Spacer(minLength: 0)
            }
        }
        // Wider, not taller: the bottom half pairs stats+protection with the
        // map side by side, so five stacked blocks never grow a tower taller
        // than the screen (the "UI doesn't fit" bug). The trailing Spacer
        // pins the column to the top — slack space stays at the bottom
        // instead of splitting into top/bottom gaps around a centered
        // column.
        .frame(minWidth: 560, minHeight: 470)
        .sheet(isPresented: $showServers) { ServersSheet().environmentObject(state) }
        .sheet(isPresented: $showSettings) { SettingsSheet().environmentObject(state) }
        .sheet(isPresented: $showImport) { ImportView().environmentObject(state) }
        // Drag & drop: share links (as text) or a .txt list dropped anywhere
        // on the window open the import sheet prefilled — no hunt for the
        // import button first.
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
                    .strokeBorder(Theme.accent.opacity(0.6), lineWidth: 2)
                    .padding(6)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(Theme.springQuick, value: dropping)
        // Live traffic stats are visible → the poller samples at full cadence.
        // Registered via onAppear/onDisappear so a closed window drops back to
        // the slow headless rate instead of spawning `xray api` for nobody.
        .onAppear { state.statsViewOpened() }
        .onDisappear { state.statsViewClosed() }
    }

    // MARK: - Top bar (the only place to connect)

    /// The transition for warnings/chips joining the column: slide-in by
    /// default (the arrival telegraphs the direction, §8), plain cross-fade
    /// under reduced motion.
    private var columnReflowTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }

    /// The bundled logo is pure white on transparency — built for dark
    /// chrome. On the ivory light theme a white mark would vanish, so it's
    /// multiplied down to warm ink there; on dark it passes through white.
    private var logoTint: Color { scheme == .dark ? .white : Theme.textHi }

    private var topBar: some View {
        HStack(spacing: 10) {
            if let logo = AppAssets.logo {
                Image(nsImage: logo).resizable().scaledToFit().frame(height: 24)
                    .colorMultiply(logoTint)
            }
            Text("Anemia").font(Theme.display(17)).tracking(Theme.tracking(for: 17))
                .foregroundStyle(Theme.textHi)

            statusCluster

            Spacer()

            Toggle("", isOn: connectBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .keyboardShortcut(.return, modifiers: .command)
                .pointerCursor()
                .help(connectHelp)
            // (In-flight feedback lives in the status cluster's mini spinner —
            // a second one here read as duplication.)

            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(Theme.ui(15))
            }
            .buttonStyle(.plain)
            .foregroundStyle(hoverGear ? Theme.textHi : Theme.textLo)
            .onHover { hoverGear = $0 }
            .pointerCursor()
            .keyboardShortcut(",", modifiers: .command)
            .help("Settings (⌘,)")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    /// Connection state beside the brand: lamp + status, and while connected
    /// the session timer, live latency and capacity on the same line. The
    /// full error message (or the why-behind the mode) rides in the tooltip.
    private var statusCluster: some View {
        HStack(spacing: 7) {
            if case .connecting = state.connection {
                ProgressView().controlSize(.mini)
            } else {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
            }
            Text(statusTitle)
                .font(Theme.ui(12, .semibold))
                .foregroundStyle(statusColor)
            if let since = state.connectedSince, state.isConnected {
                Text("·").foregroundStyle(Theme.textLo)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(Format.duration(since: since, now: ctx.date))
                        .font(Theme.metric(12))
                        .foregroundStyle(Theme.textLo)
                }
                if let ms = state.proxyLatency {
                    Text("·").foregroundStyle(Theme.textLo)
                    HStack(spacing: 3) {
                        Image(systemName: "bolt.horizontal.fill").font(Theme.ui(9))
                        Text(Format.ping(ms)).font(Theme.metric(12))
                    }
                    .foregroundStyle(latencyColor(ms))
                }
                if let tp = state.proxyThroughput {
                    Text("·").foregroundStyle(Theme.textLo)
                    HStack(spacing: 3) {
                        Image(systemName: "speedometer").font(Theme.ui(9))
                        Text(Format.speed(tp)).font(Theme.metric(12))
                    }
                    .foregroundStyle(Theme.textLo)
                }
            }
        }
        .padding(.leading, 6)
        .animation(Theme.spring, value: state.isConnected)
        .help(statusDetail)
    }

    /// One-line truth for the same session the Protection tile describes —
    /// reachability first, then tunnel mode — so the lamp, the mode row and
    /// the tooltip can never disagree with each other.
    private var statusDetail: String {
        if case .error(let msg) = state.connection { return msg }
        guard state.isConnected else { return state.selectedServer == nil
            ? "No server selected — pick one below"
            : "Not connected" }
        if !state.proxyReachable { return "The engine is up but traffic isn't getting through to the server" }
        if state.tunnelActive { return "All system traffic is routed through the tunnel" }
        if let err = state.systemTunnelError { return err }
        return "Only proxy-aware apps are routed; install the helper for the full tunnel (Settings → Routing)"
    }

    /// The switch drives everything. No server selected yet → flipping it ON
    /// opens the picker instead of doing nothing (or sitting disabled): the
    /// control still feels alive, and the visual state bounces back to off
    /// because `get` reads the real connection state.
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
        state.isConnected
            ? "Disconnect (⌘↩)"
            : (state.selectedServer == nil
               ? "Choose a server first — flipping this opens the picker (⌘↩)"
               : "Connect (⌘↩)")
    }

    // MARK: - Quick actions (fastest / re-ping, without opening a sheet)

    private var quickActions: some View {
        HStack(spacing: 10) {
            QuickActionButton(title: "Fastest", icon: "bolt.fill", busy: state.isPinging,
                              disabled: state.allServers.isEmpty || state.isPinging) {
                state.requestConnectFastest()
            }
            .keyboardShortcut("f", modifiers: .command)
            .help("Ping all, then connect the most stable, best foreign server (⌘F)")

            QuickActionButton(title: "Ping", icon: "speedometer",
                              busy: state.isPinging,
                              disabled: state.allServers.isEmpty || state.isPinging) {
                Task { await state.pingAll() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .help("Re-measure latency to every server (⌘R)")
        }
    }

    // MARK: - Protection

    /// The protection posture as its own tile — the three things that decide
    /// how exposed the user is, each readable AND touchable in place: the
    /// kill-switch toggle, the DPI-masking preset (menu), and the live
    /// traffic mode. Same eyebrow/row language as the settings sheet, so the
    /// two surfaces read as one app.
    private var protectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PROTECTION")
                .font(Theme.ui(11, .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.textLo)
            VStack(spacing: 0) {
                killSwitchRow
                protectionHairline
                maskingRow
                protectionHairline
                modeRow
            }
            .padding(6)
            .softCard(shadow: false)
        }
    }

    private var protectionHairline: some View { Divider().overlay(Theme.stroke) }

    private var killSwitchRow: some View {
        // Explicit grid (label left, bare switch right) instead of a Toggle
        // with an embedded label: the embedded layout was the one that let
        // the switch drift vertically when the caption wrapped.
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Kill switch").font(Theme.ui(13, .medium)).foregroundStyle(Theme.textHi)
                Text(killSwitchCaption)
                    .font(Theme.ui(11)).foregroundStyle(Theme.textLo)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { state.killSwitchEnabled },
                                     set: { state.setKillSwitch($0) }))
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .labelsHidden()
                .pointerCursor()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .help(state.isConnected
              ? "Arms at the next connect — the running tunnel keeps its current setting"
              : "Stop all traffic if the VPN connection is lost, until you reconnect")
    }

    /// The helper bakes the kill switch into the tunnel at `startTunnel`
    /// time, so flipping the toggle mid-session does not re-arm the live
    /// tunnel. Say so while connected instead of promising protection the
    /// current session doesn't have.
    private var killSwitchCaption: String {
        let base = "Fail-closed — block traffic if the tunnel drops"
        return state.isConnected ? base + " — arms at reconnect" : base
    }

    private var maskingRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("DPI masking").font(Theme.ui(13, .medium)).foregroundStyle(Theme.textHi)
                Text(maskingCaption)
                    .font(Theme.ui(11)).foregroundStyle(Theme.textLo)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Menu {
                ForEach(MaskingProfile.allCases, id: \.self) { profile in
                    Button(profile.title) { state.setMaskingProfile(profile) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(state.maskingProfile.title).font(Theme.ui(12, .semibold))
                    Image(systemName: "chevron.up.chevron.down").font(Theme.ui(9, .semibold))
                }
                .foregroundStyle(Theme.textHi)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(Theme.idle, in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .pointerCursor()
            .help("How the connection is disguised from DPI (fragmentation, junk, stealth SNI)")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    /// Masking is baked into the engine config at connect time — a live
    /// connection keeps the OLD profile until reconnect. Say so instead of
    /// silently not applying the user's choice.
    private var maskingCaption: String {
        var s = state.maskingProfile.subtitle
        if state.isConnected { s += " — applies on reconnect" }
        return s
    }

    private var modeRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Traffic mode").font(Theme.ui(13, .medium)).foregroundStyle(Theme.textHi)
                Text("How traffic leaves the machine")
                    .font(Theme.ui(11)).foregroundStyle(Theme.textLo)
            }
            Spacer(minLength: 12)
            HStack(spacing: 5) {
                Circle().fill(modeColor).frame(width: 6, height: 6)
                Text(modeTitle).font(Theme.ui(12, .semibold)).foregroundStyle(modeColor)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .help(modeHelp)
    }

    private var modeTitle: String {
        guard state.isConnected else { return "Off" }
        if !state.proxyReachable { return "No route" }
        if state.tunnelActive { return "System tunnel" }
        return state.systemTunnelError != nil ? "Tunnel failed" : "SOCKS only"
    }

    /// Color follows the same truth table as the hero (`statusColor`) —
    /// reachability checked first — so the Protection tile can never claim
    /// "SOCKS only, fine" in warn while the hero says "No route" in danger
    /// about the very same session.
    private var modeColor: Color {
        guard state.isConnected else { return Theme.textLo }
        if !state.proxyReachable { return Theme.danger }
        if state.tunnelActive { return Theme.accent }
        return state.systemTunnelError != nil ? Theme.danger : Theme.warn
    }

    private var modeHelp: String {
        guard state.isConnected else { return "Not connected" }
        if !state.proxyReachable { return "The engine is up but traffic isn't getting through to the server" }
        if state.tunnelActive { return "All system traffic is routed through the tunnel" }
        if let err = state.systemTunnelError { return err }
        return "Only proxy-aware apps are routed; install the helper for the full tunnel (Settings → Routing)"
    }

    // MARK: - Bottom columns (compact pairing)

    /// Read + trust in one row: the live numbers and the protection posture
    /// on the left, the world map tile on the right. Pairing them keeps the
    /// whole window inside a normal height instead of stacking five blocks
    /// into a tower taller than the screen.
    private var bottomColumns: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 10) {
                statsRow
                protectionSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MiniMap()
                .frame(width: 240)
                .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Stats

    /// Both directions share ONE tile — the down/up pair reads as a single
    /// fact ("traffic"), and the window gains breathing room it used to
    /// spend on a second card border and shadow.
    private var statsRow: some View {
        HStack(spacing: 0) {
            StatPill(icon: "arrow.down", tint: Theme.textLo,
                     value: Format.speed(state.downlinkSpeed),
                     caption: Format.bytes(state.downlinkTotal))
            Rectangle().fill(Theme.stroke).frame(width: 1, height: 20)
            StatPill(icon: "arrow.up", tint: Theme.textLo,
                     value: Format.speed(state.uplinkSpeed),
                     caption: Format.bytes(state.uplinkTotal))
        }
        .softCard()
        .opacity(state.isConnected ? 1 : 0.35)
    }

    // MARK: - Server card

    private var serverCard: some View {
        Button { showServers = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(Theme.ui(16))
                    .foregroundStyle(Theme.textLo)
                    .frame(width: 34, height: 34)
                    .background(Theme.cardHi, in: RoundedRectangle(cornerRadius: Theme.subRadius,
                                                                   style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.selectedServer?.name ?? "No server selected")
                        .font(Theme.ui(13, .semibold))
                        .foregroundStyle(Theme.textHi).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(serverSubtitle)
                            .font(Theme.ui(11)).foregroundStyle(Theme.textLo).lineLimit(1)
                        if let id = state.selectedServerID, let tier = state.qualityTier(id) {
                            QualityTag(tier: tier)
                        }
                        if let id = state.selectedServerID, let s = state.stability[id] {
                            StabilityBars(score: s)
                        }
                    }
                }
                Spacer()
                if let id = state.selectedServerID { PingBadge(result: state.pings[id]) }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textLo)
            }
            .padding(15)
            .softCard(fill: hoverServerCard ? Theme.cardHi : Theme.card)
            .animation(Theme.springQuick, value: hoverServerCard)
        }
        .buttonStyle(PressableStyle(scale: 0.99))
        .onHover { hoverServerCard = $0 }
        .pointerCursor()
        .keyboardShortcut("k", modifiers: .command)
        .help("Choose a server (⌘K)")
    }

    // MARK: - Domestic-exit warning

    /// Shown when the selected server can't circumvent the block: its exit is in
    /// the user's own country, or inside Russia (the app's target censorship) —
    /// either way traffic lands back inside the same filtering.
    private var domesticExitWarning: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Theme.ui(12, .bold))
            Text("This exit can't bypass the block — it's inside the censored region. Pick a foreign server.")
                .font(Theme.ui(11, .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.warn)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warn.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.subRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.subRadius, style: .continuous).stroke(Theme.warn.opacity(0.35)))
    }

    // MARK: - kxc recommendation

    /// Shown when the model's best-ranked server isn't the one selected. Tapping
    /// switches to it — live (reconnect) when connected, otherwise just selects.
    private func recommendationChip(_ rec: ProxyServer) -> some View {
        let neural = state.mlRankingEnabled && state.kxcLoaded
        return Button {
            if state.isConnected { state.quickConnect(rec.id) } else { state.select(rec.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: neural ? "sparkles" : "bolt.fill")
                    .font(Theme.ui(12, .bold))
                (Text(neural ? "kxc recommends " : "Fastest is ")
                    .font(Theme.ui(12))
                 + Text(rec.name).font(Theme.ui(12, .semibold)))
                    .lineLimit(1)
                Spacer()
                Text(state.isConnected ? "Switch" : "Select")
                    .font(Theme.ui(11, .semibold))
                Image(systemName: "arrow.right").font(Theme.ui(10, .bold))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Theme.accent.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: Theme.subRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.subRadius, style: .continuous)
                .stroke(Theme.accent.opacity(0.3)))
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .pointerCursor()
        .help("Switch to the server kxc ranks best")
    }

    private func latencyColor(_ ms: Int) -> Color {
        ms < 120 ? Theme.tierGood : (ms < 300 ? Theme.tierFair : Theme.tierPoor)
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
        case .connected:
            if !state.proxyReachable { return "No route to server" }
            if state.tunnelActive { return "Protected" }
            // A failed system tunnel must read as a failure, not as a working
            // connection: the reason itself lives in the log view.
            return state.systemTunnelError != nil ? "Tunnel failed — SOCKS only" : "Connected (SOCKS)"
        case .connecting: return "Connecting…"
        case .error: return "Connection error"
        case .disconnected: return "Not connected"
        }
    }

    private var statusColor: Color {
        switch state.connection {
        case .connected:
            if !state.proxyReachable { return Theme.danger }
            return state.tunnelActive ? Theme.accent : Theme.warn
        case .connecting: return Theme.accent
        case .error: return Theme.danger
        case .disconnected: return Theme.textLo
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

/// One direction of the shared traffic tile: icon + live speed over the
/// session total. No individual card — the pair sits inside one tile.
struct StatPill: View {
    let icon: String
    let tint: Color
    let value: String
    let caption: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(Theme.ui(12, .semibold)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(Theme.metric(13)).foregroundStyle(Theme.textHi)
                Text(caption).font(Theme.metric(11, .regular)).foregroundStyle(Theme.textLo)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(maxWidth: .infinity)
    }
}

/// Ghost quick-action button (Fastest / Ping) for the main window, so the two
/// most-used server actions don't require opening the servers sheet.
struct QuickActionButton: View {
    let title: String
    let icon: String
    let busy: Bool
    let disabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: icon).font(Theme.ui(12, .semibold))
                }
                Text(title).font(Theme.ui(12, .medium))
            }
            .foregroundStyle(disabled ? Theme.textLo.opacity(0.5) : Theme.textHi)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .softCard(Theme.subRadius, fill: hovering && !disabled ? Theme.cardHi : Theme.card,
                      shadow: false)
        }
        .buttonStyle(PressableStyle())
        .disabled(disabled)
        .onHover { hovering = $0 && !disabled }
        .pointerCursor(disabled ? .arrow : .pointingHand)
        .animation(Theme.springQuick, value: hovering)
    }
}

extension View {
    /// Sets the hover cursor (comfort: interactive elements feel clickable).
    /// Uses `.set()` rather than push/pop so it can't leave the stack unbalanced
    /// when a hovered view disappears.
    func pointerCursor(_ cursor: NSCursor = .pointingHand) -> some View {
        onHover { inside in (inside ? cursor : NSCursor.arrow).set() }
    }
}
