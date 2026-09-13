import SwiftUI
import LoaderCore

/// Settings: kill switch, masking profile + fingerprint, advanced tweaks, logs.
///
/// One row grammar carries the whole sheet: title (13 medium) over subtitle
/// (11 quiet), trailing control right-aligned and vertically centered —
/// switches, pill buttons, pickers and the logs row all sit on that same
/// grid, so nothing drifts when a subtitle wraps to two lines. System chrome
/// (borderedProminent, caption2) is kept out: buttons use the app's pill
/// language, text stays on the theme's scale.
struct SettingsSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showLogs = false
    @State private var hoverLogs = false
    @State private var helperError: String?

    /// Includes the Russian-service aliases (yandex/vk) — the engine maps them
    /// onto the closest real uTLS ClientHello at config-build time.
    private let fingerprints = ["chrome", "firefox", "safari", "ios", "android", "edge",
                                "yandex", "vk", "randomized"]

    /// The menu choices, plus whatever value is currently persisted: a value
    /// from an older version (or another write path) absent from the list
    /// would otherwise render as an empty menu pick and be silently reset by
    /// the next tap.
    private var fingerprintChoices: [String] {
        state.anti.fingerprint.isEmpty || fingerprints.contains(state.anti.fingerprint)
            ? fingerprints
            : fingerprints + [state.anti.fingerprint]
    }

    private var helperStatusText: String {
        if !state.helperInstalled { return "Install to enable browser routing and the full tunnel." }
        if !state.helperCurrent { return "Update needed — the installed helper is an older version." }
        return "Installed and current — browser routing & full tunnel ready."
    }

    var body: some View {
        ZStack {
            // Same native vibrancy as the main window and the menu popover —
            // the sheet reads as part of the app, not a separate gradient box.
            VibrancyBackground()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Settings").font(Theme.display(19)).tracking(Theme.tracking(for: 19))
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(PressableStyle(scale: 0.88)).foregroundStyle(Theme.textLo)
                        .keyboardShortcut(.cancelAction)
                        .help("Close (Esc)")
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        section("Protection") {
                            toggleRow("Kill switch", "Block all traffic if the VPN drops (fail-closed).",
                                      isOn: Binding(get: { state.killSwitchEnabled },
                                                    set: { state.setKillSwitch($0) }))
                        }

                        section("Startup") {
                            toggleRow("Launch at login", "Start Anemia automatically when you log in.",
                                      isOn: Binding(get: { state.launchAtLogin },
                                                    set: { state.setLaunchAtLogin($0) }))
                            if let err = state.launchAtLoginError {
                                errorNote(err)
                            }
                            Divider().overlay(Theme.stroke)
                            toggleRow("Auto-connect fastest", "On launch, ping servers and connect the fastest.",
                                      isOn: Binding(get: { state.autoConnectOnLaunch },
                                                    set: { state.setAutoConnectOnLaunch($0) }))
                            Divider().overlay(Theme.stroke)
                            toggleRow("Auto-refresh subscriptions",
                                      "Fetch each subscription on launch and every 6 hours; log when servers change.",
                                      isOn: Binding(get: { state.subscriptionAutoRefresh },
                                                    set: { state.setSubscriptionAutoRefresh($0) }))
                        }

                        section("Routing") {
                            toggleRow("Route apps through Anemia",
                                      "Send your browser & proxy-aware apps out through Anemia's foreign server while another VPN (e.g. sing-box) handles the rest. Needs the helper.",
                                      isOn: Binding(get: { state.systemProxyEnabled },
                                                    set: { state.setSystemProxyEnabled($0) }))
                            Divider().overlay(Theme.stroke)
                            settingRow("Privileged helper", helperStatusText) {
                                if state.helperBusy {
                                    ProgressView().controlSize(.small)
                                } else if !state.helperInstalled {
                                    PillButton(title: "Enable", icon: "arrow.down.circle.fill") {
                                        Task { helperError = await state.installHelper() }
                                    }
                                } else if !state.helperCurrent {
                                    PillButton(title: "Update", icon: "arrow.triangle.2.circlepath",
                                               tint: Theme.warn) {
                                        Task { helperError = await state.installHelper() }
                                    }
                                } else {
                                    Label("On", systemImage: "checkmark.seal.fill")
                                        .font(Theme.ui(12, .semibold)).foregroundStyle(Theme.accent)
                                }
                            }
                            if let helperError {
                                errorNote(helperError)
                            }
                            if state.helperInstalled {
                                Divider().overlay(Theme.stroke)
                                Button {
                                    Task { helperError = await state.uninstallHelper() }
                                } label: {
                                    Label("Remove helper", systemImage: "trash")
                                        .font(Theme.ui(11, .medium)).foregroundStyle(Theme.textLo)
                                }
                                .buttonStyle(.plain).pointerCursor()
                                .padding(.horizontal, 10).padding(.vertical, 6)
                            }
                        }

                        section("\(state.kxcName) · server ranking (ML)") {
                            toggleRow("Use \(state.kxcName)", "Rank servers with the on-device neural net — trend, jitter and loss bursts, not just the average.",
                                      isOn: Binding(get: { state.mlRankingEnabled },
                                                    set: { state.setMLRanking($0) }))
                            Divider().overlay(Theme.stroke)
                            settingRow("Model",
                                       state.kxcLoaded ? "Loaded · fp16 mlprogram" : state.rankerBackend) {
                                Label(state.kxcDevice, systemImage: "cpu")
                                    .font(Theme.ui(12, .semibold))
                                    .foregroundStyle(state.kxcDevice == "Neural Engine" ? Theme.accent : Theme.textLo)
                            }
                            if let rec = state.recommendedServer {
                                Divider().overlay(Theme.stroke)
                                settingRow("Recommends", rec.name) {
                                    BestBadge(neural: state.mlRankingEnabled && state.kxcLoaded)
                                }
                                .lineLimit(1)
                            }
                        }

                        section("Masking") {
                            VStack(alignment: .leading, spacing: 8) {
                                Picker("", selection: Binding(get: { state.maskingProfile },
                                                              set: { state.setMaskingProfile($0) })) {
                                    ForEach(MaskingProfile.allCases, id: \.self) { Text($0.title).tag($0) }
                                }
                                .pickerStyle(.segmented).labelsHidden()
                                Text(state.isConnected
                                     ? state.maskingProfile.subtitle + " — applies on reconnect"
                                     : state.maskingProfile.subtitle)
                                    .font(Theme.ui(11)).foregroundStyle(Theme.textLo)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal, 10).padding(.top, 8)

                            Divider().overlay(Theme.stroke)

                            settingRow("Fingerprint", "uTLS handshake to imitate") {
                                fingerprintMenu
                            }
                        }

                        section("Advanced") {
                            toggleRow("Multiplex (mux)", "Padded multiplexing (ignored under XTLS-Vision).",
                                      isOn: Binding(get: { state.anti.muxEnabled },
                                                    set: { state.anti.muxEnabled = $0; state.persist() }))
                            // No "TCP Fast Open" row: on Darwin the engine
                            // ignores the flag (xray's TFO probe corrupts the
                            // fragmented ClientHello), so a switch here would
                            // promise a round-trip saving that never happens.
                            // The model field stays for persisted-state compat.
                        }

                        section("Diagnostics") {
                            Button { showLogs = true } label: {
                                HStack {
                                    Label("View logs", systemImage: "doc.text")
                                        .font(Theme.ui(13, .medium))
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(Theme.ui(10, .semibold)).foregroundStyle(Theme.textLo)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .background(hoverLogs ? Theme.idle : Color.clear,
                                            in: RoundedRectangle(cornerRadius: Theme.subRadius, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PressableStyle(scale: 0.98))
                            .pointerCursor()
                            .onHover { hoverLogs = $0 }
                            .animation(Theme.springQuick, value: hoverLogs)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
            .padding(20)
            .foregroundStyle(Theme.textHi)
        }
        .frame(width: 440, height: 620)
        .task { await state.refreshKxcInfo(); state.refreshHelperStatus() }
        .sheet(isPresented: $showLogs) { LogView().environmentObject(state) }
    }

    // MARK: - Fingerprint picker

    /// Themed menu: the system `.menu` picker ships its own chrome that
    /// clashes with the warm tiles, so the value lives in a quiet capsule
    /// (value + chevron) with a native pull-down attached.
    private var fingerprintMenu: some View {
        Menu {
            ForEach(fingerprintChoices, id: \.self) { choice in
                Button(choice.capitalized) { state.setFingerprint(choice) }
            }
        } label: {
            HStack(spacing: 5) {
                Text(state.anti.fingerprint.isEmpty ? "Default" : state.anti.fingerprint.capitalized)
                    .font(Theme.ui(12, .medium)).foregroundStyle(Theme.textHi)
                Image(systemName: "chevron.up.chevron.down")
                    .font(Theme.ui(9, .semibold)).foregroundStyle(Theme.textLo)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.idle, in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointerCursor()
    }

    // MARK: - Building blocks

    /// Section card: an uppercase eyebrow over the inset tile — the System
    /// Settings grouping grammar.
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(Theme.ui(11, .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.textLo)
            VStack(spacing: 0) { content() }
                .padding(6)
                .softCard(shadow: false)
        }
    }

    /// The row grid everything sits on: title + subtitle left, trailing
    /// control right. `fixedSize` on the subtitle lets it wrap to its own
    /// width instead of pushing the trailing control around; the HStack's
    /// center alignment keeps the control steady across 1–3 line subtitles.
    private func settingRow<Trailing: View>(_ title: String, _ subtitle: String,
                                            @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.ui(13, .medium)).foregroundStyle(Theme.textHi)
                Text(subtitle)
                    .font(Theme.ui(11)).foregroundStyle(Theme.textLo)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    /// Switch row on the same grid: a bare switch (labelsHidden) can't drag
    /// the label layout the way an embedded Toggle label does — titles and
    /// subtitles stay put regardless of wrap.
    private func toggleRow(_ title: String, _ subtitle: String, isOn: Binding<Bool>) -> some View {
        settingRow(title, subtitle) {
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .labelsHidden()
                .pointerCursor()
        }
    }

    /// Quiet danger note for helper/login errors — same inset as the rows it
    /// follows, with a speaking icon instead of bare red text.
    private func errorNote(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Theme.ui(10, .bold))
                .foregroundStyle(Theme.danger)
            Text(text)
                .font(Theme.ui(11)).foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 10).padding(.vertical, 2)
    }
}