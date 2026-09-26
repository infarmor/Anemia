import SwiftUI
import LoaderCore
import LoaderShared
import UserNotifications

enum SettingsTab: Hashable {
    case general, protection, network, diagnostics, about
}

/// The Settings window (⌘,): toolbar tabs over grouped forms on Claude's
/// ground, every row led by the same glyph tile the main window uses — clay
/// while the thing is on, quiet ink while it isn't.
struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var tab: SettingsTab

    init(initialTab: SettingsTab = .general) {
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ProtectionSettingsPane()
                .tabItem { Label("Protection", systemImage: "lock.shield") }
                .tag(SettingsTab.protection)
            NetworkSettingsPane()
                .tabItem { Label("Network", systemImage: "network") }
                .tag(SettingsTab.network)
            DiagnosticsSettingsPane()
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
                .tag(SettingsTab.diagnostics)
            AboutSettingsPane()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(width: 580)
        .seamlessWindowChrome(keepsTitle: true)
        .task {
            await state.refreshKxcInfo()
            state.refreshHelperStatus()
        }
    }
}

// MARK: - Shared pieces

/// The rounded glyph tile that leads a row.
private struct GlyphTile: View {
    let symbol: String
    var active = true

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(active ? Color.white : Theme.textLo)
            .frame(width: 24, height: 24)
            .background(active ? AnyShapeStyle(Theme.accent.gradient) : AnyShapeStyle(Theme.idle),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .animation(Theme.springQuick, value: active)
    }
}

/// System Settings row grammar: glyph tile, title over an optional caption.
private struct SettingLabel: View {
    let symbol: String
    let title: String
    var caption: String?
    var active = true

    var body: some View {
        HStack(spacing: 10) {
            GlyphTile(symbol: symbol, active: active)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(Theme.textHi)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(Theme.textLo)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The app mark in a clay tile, the name in the headline serif.
private struct AppIdentityHeader: View {
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.accent.gradient)
                if let logo = AppAssets.logo {
                    Image(nsImage: logo)
                        .renderingMode(.template)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .foregroundStyle(.white)
                        .padding(11)
                }
            }
            .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text("Anemia")
                    .font(.system(size: 22, weight: .medium, design: .serif))
                    .foregroundStyle(Theme.textHi)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(Theme.textLo)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

private struct StatusChip: View {
    let title: String
    let ok: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(ok ? Theme.accent : Theme.textLo.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(title)
                .lineLimit(1)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(ok ? Theme.textHi : Theme.textLo)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Theme.idle, in: Capsule())
    }
}

/// Inline error under a row.
private struct ErrorNote: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(Theme.accent)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private extension View {
    /// Grouped form on the ground, clay switches and popup caps.
    func settingsForm(height: CGFloat) -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Theme.ground)
            .tint(Theme.accent)
            .frame(height: height)
    }

    /// Same, without the tint — for panes of plain glass buttons, which would
    /// otherwise pick the clay up.
    func untintedSettingsForm(height: CGFloat) -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Theme.ground)
            .frame(height: height)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension AppState {
    /// "kxc v4 · CPU" once loaded (device omitted until it's known); the
    /// loader's status otherwise.
    var kxcSummary: String {
        guard kxcLoaded else { return rankerBackend }
        let name = rankerBackend.replacingOccurrences(of: " (CoreML)", with: "")
        return kxcDevice == "—" ? name : "\(name) · \(kxcDevice)"
    }
}

private var appVersion: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
    let build = info?["CFBundleVersion"] as? String
    return build.map { "\(short) (\($0))" } ?? short
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @EnvironmentObject var state: AppState
    @State private var showAddSubscription = false
    @State private var refreshingSubID: UUID? = nil

    private var sessionLine: String {
        guard state.isConnected else {
            return state.waitingForNetwork ? "Waiting for the network" : "Not connected"
        }
        let mode = state.tunnelActive ? "Protected" : "Connected (proxy only)"
        return state.selectedServer.map { "\(mode) · \($0.name)" } ?? mode
    }

    private var reminderCaption: String {
        let base = "Three days and a day before it ends, and when 90 % of its traffic is used."
        switch state.alerts.permission {
        case .denied: return base + " Notifications are off for Anemia in System Settings."
        case .provisional, .notDetermined: return base + " Delivered quietly to Notification Center."
        default: return base
        }
    }

    private var helperChip: (String, Bool) {
        if !state.helperInstalled { return ("No helper", false) }
        return state.helperCurrent ? ("Helper \(LoaderHelperVersion)", true) : ("Helper update", false)
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    AppIdentityHeader(subtitle: sessionLine)
                    HStack(spacing: 6) {
                        StatusChip(title: helperChip.0, ok: helperChip.1)
                        StatusChip(title: state.kxcLoaded ? state.rankerBackend.replacingOccurrences(of: " (CoreML)", with: "") : "kxc loading",
                                   ok: state.kxcLoaded)
                        StatusChip(title: "\(state.allServers.count) server\(state.allServers.count == 1 ? "" : "s")",
                                   ok: !state.allServers.isEmpty)
                    }
                }
            }

            Section {
                ForEach(state.subscriptions) { sub in
                    HStack(spacing: 10) {
                        GlyphTile(symbol: "arrow.triangle.2.circlepath", active: true)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(state.displayName(of: sub))
                                    .foregroundStyle(Theme.textHi)
                                    .lineLimit(1)
                                if !sub.tlsProtected {
                                    Image(systemName: "lock.open.fill")
                                        .foregroundStyle(.orange)
                                        .help("No TLS — never refreshed automatically, only on press")
                                }
                            }
                            if let info = state.subscriptionInfo[sub.id],
                               let line = [info.trafficText, info.expiryText].compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                                Text(line)
                                    .font(.caption)
                                    .foregroundStyle(info.needsAttention() ? Theme.accent : Theme.textLo)
                                    .lineLimit(1)
                                if let fraction = info.usedFraction {
                                    ProgressView(value: fraction)
                                        .progressViewStyle(.linear)
                                        .tint(fraction > 0.9 ? Theme.accent : Theme.textHi)
                                        .frame(maxWidth: 220)
                                }
                            } else {
                                Text(sub.url)
                                    .font(.caption)
                                    .foregroundStyle(Theme.textLo)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        if refreshingSubID == sub.id {
                            ProgressView().controlSize(.small)
                        } else {
                            Button {
                                refreshingSubID = sub.id
                                Task {
                                    await state.refreshSubscription(sub.id)
                                    if refreshingSubID == sub.id { refreshingSubID = nil }
                                }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.textLo)
                            .help("Refresh \(sub.name)")
                        }
                        Button(role: .destructive) {
                            state.removeSubscription(sub.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textLo)
                        .help("Delete \(sub.name)")
                    }
                    .padding(.vertical, 2)
                }
                Button {
                    state.lastImportError = nil
                    showAddSubscription = true
                } label: {
                    Label("Add Subscription…", systemImage: "plus")
                }
            } header: {
                Text("Subscriptions")
            } footer: {
                if let err = state.lastImportError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.accent)
                }
            }

            TransferSettingsSection()

            Section("Startup") {
                Toggle(isOn: Binding(get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) })) {
                    SettingLabel(symbol: "power", title: "Launch at login",
                                 caption: "Start Anemia when you log in.", active: state.launchAtLogin)
                }
                if let err = state.launchAtLoginError { ErrorNote(text: err) }
                Toggle(isOn: Binding(get: { state.autoConnectOnLaunch }, set: { state.setAutoConnectOnLaunch($0) })) {
                    SettingLabel(symbol: "bolt.fill", title: "Connect the fastest server on launch",
                                 caption: "Pings every server first, then connects the best one.",
                                 active: state.autoConnectOnLaunch)
                }
                Toggle(isOn: Binding(get: { state.subscriptionAutoRefresh }, set: { state.setSubscriptionAutoRefresh($0) })) {
                    SettingLabel(symbol: "arrow.triangle.2.circlepath", title: "Refresh subscriptions",
                                 caption: "On launch and every 6 hours.", active: state.subscriptionAutoRefresh)
                }
                Toggle(isOn: Binding(get: { state.alerts.isEnabled }, set: { state.alerts.isEnabled = $0 })) {
                    SettingLabel(symbol: "bell.badge.fill", title: "Remind before a subscription ends",
                                 caption: reminderCaption, active: state.alerts.isEnabled)
                }
                if state.alerts.isEnabled, state.alerts.permission == .provisional || state.alerts.permission == .notDetermined {
                    Button("Show Reminders as Banners…") { Task { await state.alerts.askForBanners() } }
                } else if state.alerts.isEnabled, state.alerts.permission == .denied {
                    Button("Allow Notifications in System Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }

            Section {
                Toggle(isOn: Binding(get: { state.mlRankingEnabled }, set: { state.setMLRanking($0) })) {
                    SettingLabel(symbol: "sparkles", title: "Rank servers with \(state.kxcName)",
                                 caption: "Forecasts how each server will behave next from its ping history — loss bursts, drift, jitter — instead of averaging the past.",
                                 active: state.mlRankingEnabled)
                }
                LabeledContent {
                    Text(state.kxcSummary)
                        .foregroundStyle(Theme.textLo)
                } label: {
                    SettingLabel(symbol: "cpu", title: "Model", active: state.kxcLoaded)
                }
                if let rec = state.recommendedServer {
                    LabeledContent {
                        Text(rec.name).foregroundStyle(Theme.textHi)
                    } label: {
                        SettingLabel(symbol: "star.fill", title: "Recommends")
                    }
                }
            } header: {
                Text("Server ranking")
            }
        }
        .settingsForm(height: 760)
        .task { await state.alerts.refreshPermission() }
        .sheet(isPresented: $showAddSubscription) {
            ImportView(initialMode: .subscription).environmentObject(state)
        }
    }
}

// MARK: - Protection

private struct ProtectionSettingsPane: View {
    @EnvironmentObject var state: AppState

    /// Includes the Russian-service aliases (yandex/vk) — the engine maps them
    /// onto the closest real uTLS ClientHello at config-build time.
    private let fingerprints = ["chrome", "firefox", "safari", "ios", "android", "edge",
                                "yandex", "vk", "randomized"]

    /// The choices plus whatever value is persisted, so an unknown stored
    /// value never renders as an empty picker and gets silently reset.
    private var fingerprintChoices: [String] {
        state.anti.fingerprint.isEmpty || fingerprints.contains(state.anti.fingerprint)
            ? fingerprints
            : fingerprints + [state.anti.fingerprint]
    }

    private var killSwitchArmed: Bool { state.killSwitchEnabled && state.tunnelActive }

    private var killSwitchStatus: String {
        guard state.killSwitchEnabled else { return "Off" }
        return state.tunnelActive ? "Armed" : "Arms with the system tunnel"
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { state.killSwitchEnabled }, set: { state.setKillSwitch($0) })) {
                    SettingLabel(symbol: "lock.shield.fill", title: "Kill switch",
                                 caption: "Block all traffic if the VPN connection drops.",
                                 active: state.killSwitchEnabled)
                }
                LabeledContent {
                    Text(killSwitchStatus)
                        .foregroundStyle(killSwitchArmed ? Theme.accent : Theme.textLo)
                } label: {
                    SettingLabel(symbol: "checkmark.shield.fill", title: "Status", active: killSwitchArmed)
                }
            } header: {
                Text("Kill switch")
            } footer: {
                Text("Built into the tunnel at connect. It stays armed through reconnects, network changes and while the network is down.")
                    .foregroundStyle(Theme.textLo)
            }

            Section {
                Toggle(isOn: Binding(get: { state.adBlockEnabled }, set: { state.setAdBlock($0) })) {
                    SettingLabel(symbol: "hand.raised.fill", title: "Block ads",
                                 caption: "The engine asks AdGuard DNS, through the VPN: ad and tracker domains don't resolve. Works under the system tunnel; applies at connect.",
                                 active: state.adBlockEnabled)
                }
            } header: {
                Text("Ads and trackers")
            }

            Section {
                Picker(selection: Binding(get: { state.maskingProfile }, set: { state.setMaskingProfile($0) })) {
                    ForEach(MaskingProfile.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    SettingLabel(symbol: "theatermasks.fill", title: "Profile", active: state.maskingProfile != .off)
                }
                Picker(selection: Binding(get: { state.anti.fingerprint }, set: { state.setFingerprint($0) })) {
                    ForEach(fingerprintChoices, id: \.self) { Text($0.capitalized).tag($0) }
                } label: {
                    SettingLabel(symbol: "touchid", title: "TLS fingerprint",
                                 caption: "The browser a TLS or REALITY handshake looks like.")
                }
                Toggle(isOn: Binding(get: { state.anti.muxEnabled },
                                     set: { state.anti.muxEnabled = $0; state.persist() })) {
                    SettingLabel(symbol: "square.stack.3d.up.fill", title: "Multiplexing (mux)",
                                 caption: "Padded multiplexing; skipped under XTLS Vision and XHTTP.",
                                 active: state.anti.muxEnabled)
                }
            } header: {
                Text("DPI masking")
            } footer: {
                Text((state.isConnected
                     ? state.maskingProfile.subtitle + ". Applies on the next connect."
                     : state.maskingProfile.subtitle + ".")
                     + " What keeps a server flowing is learned per network — Wi‑Fi or Ethernet, and an iPhone hotspot apart — and Check Servers tries stronger masking on servers that are blocked.")
                    .foregroundStyle(Theme.textLo)
            }
        }
        .settingsForm(height: 660)
    }
}

// MARK: - Network

private struct NetworkSettingsPane: View {
    @EnvironmentObject var state: AppState
    @State private var helperError: String?

    private var helperStatusText: String {
        if !state.helperInstalled { return "Required for the system-wide tunnel, the kill switch and AmneziaWG." }
        if !state.helperCurrent {
            let installed = state.helperVersion.map { " (\($0) installed)" } ?? ""
            return "Version \(LoaderHelperVersion) is available\(installed) — update to keep AmneziaWG and every safety fix."
        }
        return "Version \(LoaderHelperVersion), up to date."
    }

    var body: some View {
        Form {
            Section("System tunnel") {
                LabeledContent {
                    if state.helperBusy {
                        ProgressView().controlSize(.small)
                    } else if !state.helperInstalled {
                        Button("Install…") { Task { helperError = await state.installHelper() } }
                            .nativeButtonStyle(prominent: true)
                    } else if !state.helperCurrent {
                        Button("Update…") { Task { helperError = await state.installHelper() } }
                            .nativeButtonStyle(prominent: true)
                    } else {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.accent)
                    }
                } label: {
                    SettingLabel(symbol: "shield.lefthalf.filled", title: "Privileged helper",
                                 caption: helperStatusText,
                                 active: state.helperInstalled && state.helperCurrent)
                }
                if let helperError { ErrorNote(text: helperError) }
                if state.helperInstalled {
                    Button("Remove Helper…", role: .destructive) {
                        Task { helperError = await state.uninstallHelper() }
                    }
                    .disabled(state.helperBusy)
                }
            }

            Section("Routing") {
                Toggle(isOn: Binding(get: { state.systemProxyEnabled }, set: { state.setSystemProxyEnabled($0) })) {
                    SettingLabel(symbol: "arrow.triangle.branch", title: "Route apps through Anemia",
                                 caption: "When another VPN owns the system routes, point the system SOCKS proxy at Anemia so browsers still use it. Restored on disconnect.",
                                 active: state.systemProxyEnabled)
                }
            }

            Section {
                Toggle(isOn: Binding(get: { state.splitTunnel.enabled }, set: { state.setSplitTunnel(enabled: $0) })) {
                    SettingLabel(symbol: "signpost.right.and.left.fill", title: "Bypass the VPN for listed destinations",
                                 caption: "A local bank or government site, a work network. Applied at connect.",
                                 active: state.splitTunnel.enabled)
                }
                SplitTunnelEditor()
            } header: {
                Text("Split tunneling")
            }
        }
        .settingsForm(height: 640)
    }
}

// MARK: - Diagnostics

private struct DiagnosticsSettingsPane: View {
    @EnvironmentObject var state: AppState
    @State private var showLogs = false
    @State private var copied = false

    var body: some View {
        Form {
            Section("Network safety") {
                LabeledContent {
                    if state.repairInProgress {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Repair…") { Task { await state.repairNetwork() } }
                            .nativeButtonStyle(prominent: !state.networkIssues.isEmpty)
                    }
                } label: {
                    SettingLabel(symbol: "wrench.and.screwdriver.fill", title: "Repair network settings",
                                 caption: "Restore DNS, proxy, routes and the firewall — works even without the helper.",
                                 active: !state.networkIssues.isEmpty)
                }
                ForEach(state.networkIssues) { issue in
                    ErrorNote(text: issue.message)
                }
                if let report = state.lastRepairReport {
                    Text(report)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textLo)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Troubleshooting") {
                LabeledContent {
                    HStack {
                        Button(copied ? "Copied" : "Copy Report") {
                            Task {
                                await state.copyDiagnosticsToPasteboard()
                                copied = true
                            }
                        }
                        Button("Show Log File") { state.revealLogFile() }
                    }
                    .nativeButtonStyle()
                } label: {
                    SettingLabel(symbol: "doc.on.clipboard.fill", title: "Diagnostics",
                                 caption: "Versions, session state, the helper's view and the recent log.")
                }
                LabeledContent {
                    Button("View…") { showLogs = true }
                        .nativeButtonStyle()
                } label: {
                    SettingLabel(symbol: "text.alignleft", title: "Engine log")
                }
            }
        }
        .untintedSettingsForm(height: 440)
        .sheet(isPresented: $showLogs) { LogView().environmentObject(state) }
    }
}

// MARK: - About

private struct AboutSettingsPane: View {
    @EnvironmentObject var state: AppState
    @State private var inventory: EngineInventory?

    var body: some View {
        Form {
            Section {
                AppIdentityHeader(subtitle: "Version \(appVersion)")
            }

            Section {
                engineRow(symbol: "bolt.horizontal.fill", title: "Xray-core",
                          caption: "VLESS · VMess · Trojan · Shadowsocks",
                          value: inventory.map { $0.xrayVersion.map { "v\($0)" } ?? "Missing" },
                          ok: inventory?.xrayVersion != nil)
                engineRow(symbol: "arrow.left.arrow.right", title: "tun2socks",
                          caption: "The system-wide tunnel bridge",
                          value: inventory.map { $0.tun2socks ? "Bundled" : "Missing" },
                          ok: inventory?.tun2socks == true)
                engineRow(symbol: "waveform.path.ecg", title: "AmneziaWG",
                          caption: "AmneziaWG 1.0 – 3.1 and WireGuard (amneziawg-go)",
                          value: inventory.map(awgValue), ok: inventory?.awg == .installed)
                engineRow(symbol: "hare.fill", title: "Hysteria 2",
                          caption: "QUIC with Salamander obfuscation and port hopping",
                          value: inventory.map { $0.hysteria ?? "Not in this build" },
                          ok: inventory?.hysteria != nil)
                engineRow(symbol: "shield.lefthalf.filled", title: "Privileged helper",
                          caption: "System tunnel, kill switch, network safety",
                          value: helperValue, ok: state.helperInstalled && state.helperCurrent)
                engineRow(symbol: "sparkles", title: state.kxcName,
                          caption: "Server-quality forecast",
                          value: state.kxcSummary,
                          ok: state.kxcLoaded)
            } header: {
                Text("Engines")
            } footer: {
                Text("Missing engines: Scripts/fetch-extra-engines.sh builds AmneziaWG and fetches Hysteria; rebuild the app, then update the helper.")
                    .foregroundStyle(Theme.textLo)
            }

            Section("Transports") {
                Text("REALITY · XTLS Vision · XHTTP · gRPC · WebSocket · HTTPUpgrade · mKCP · VLESS Encryption (ML-KEM-768) · Shadowsocks 2022 · Salamander")
                    .font(.callout)
                    .foregroundStyle(Theme.textLo)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsForm(height: 640)
        .task { inventory = await EngineInventory.scan() }
    }

    private var helperValue: String {
        guard state.helperInstalled else { return "Not installed" }
        if state.helperCurrent { return LoaderHelperVersion }
        return "\(state.helperVersion ?? "older") → \(LoaderHelperVersion)"
    }

    private func awgValue(_ inventory: EngineInventory) -> String {
        switch inventory.awg {
        case .installed: return "Installed"
        case .bundled: return "Update the helper"
        case .missing: return "Not in this build"
        }
    }

    private func engineRow(symbol: String, title: String, caption: String, value: String?, ok: Bool) -> some View {
        LabeledContent {
            if let value {
                Text(value)
                    .foregroundStyle(ok ? Theme.textHi : Theme.textLo)
            } else {
                ProgressView().controlSize(.small)
            }
        } label: {
            SettingLabel(symbol: symbol, title: title, caption: caption, active: ok)
        }
    }
}
