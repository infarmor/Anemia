import SwiftUI
import LoaderCore

/// Settings: kill switch, masking profile + fingerprint, advanced tweaks, logs.
struct SettingsSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showLogs = false

    private let fingerprints = ["chrome", "firefox", "safari", "ios", "edge", "randomized"]

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Settings").font(.system(size: 18, weight: .bold))
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Theme.textLo)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        section("Protection") {
                            toggleRow("Kill switch", "Block all traffic if the VPN drops (fail-closed).",
                                      isOn: Binding(get: { state.killSwitchEnabled },
                                                    set: { state.setKillSwitch($0) }))
                        }

                        section("Startup") {
                            toggleRow("Auto-connect fastest", "On launch, ping servers and connect the fastest.",
                                      isOn: Binding(get: { state.autoConnectOnLaunch },
                                                    set: { state.setAutoConnectOnLaunch($0) }))
                        }

                        section("\(state.kxcName) · server ranking (ML)") {
                            toggleRow("Use \(state.kxcName)", "Rank servers with the on-device neural model instead of raw ping.",
                                      isOn: Binding(get: { state.mlRankingEnabled },
                                                    set: { state.setMLRanking($0) }))
                            Divider().overlay(Theme.stroke)
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Model").font(.system(size: 13, weight: .medium))
                                    Text(state.kxcLoaded
                                         ? "Loaded · fp16 mlprogram"
                                         : state.rankerBackend)
                                        .font(.caption2).foregroundStyle(Theme.textLo)
                                }
                                Spacer()
                                Label(state.kxcDevice, systemImage: "cpu")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(state.kxcDevice == "Neural Engine" ? Theme.accent : Theme.textLo)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                        }

                        section("Masking") {
                            VStack(alignment: .leading, spacing: 8) {
                                Picker("", selection: Binding(get: { state.maskingProfile },
                                                              set: { state.setMaskingProfile($0) })) {
                                    ForEach(MaskingProfile.allCases, id: \.self) { Text($0.title).tag($0) }
                                }
                                .pickerStyle(.segmented).labelsHidden()
                                Text(state.maskingProfile.subtitle)
                                    .font(.caption2).foregroundStyle(Theme.textLo)
                            }
                            .padding(.horizontal, 10).padding(.top, 8)

                            Divider().overlay(Theme.stroke)

                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Fingerprint").font(.system(size: 13, weight: .medium))
                                    Text("uTLS handshake to imitate")
                                        .font(.caption2).foregroundStyle(Theme.textLo)
                                }
                                Spacer()
                                Picker("", selection: Binding(get: { state.anti.fingerprint },
                                                              set: { state.setFingerprint($0) })) {
                                    ForEach(fingerprints, id: \.self) { Text($0.capitalized).tag($0) }
                                }
                                .pickerStyle(.menu).labelsHidden().fixedSize()
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                        }

                        section("Advanced") {
                            toggleRow("Multiplex (mux)", "Padded multiplexing (ignored under XTLS-Vision).",
                                      isOn: Binding(get: { state.anti.muxEnabled },
                                                    set: { state.anti.muxEnabled = $0; state.persist() }))
                            toggleRow("TCP Fast Open", "Shave a round-trip on connect.",
                                      isOn: Binding(get: { state.anti.tcpFastOpen },
                                                    set: { state.anti.tcpFastOpen = $0; state.persist() }))
                        }

                        section("Diagnostics") {
                            Button { showLogs = true } label: {
                                HStack {
                                    Label("View logs", systemImage: "doc.text")
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textLo)
                                }
                            }
                            .buttonStyle(.plain).foregroundStyle(Theme.textHi)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                        }
                    }
                }
            }
            .padding(20)
            .foregroundStyle(Theme.textHi)
        }
        .frame(width: 440, height: 620)
        .preferredColorScheme(.dark)
        .task { await state.refreshKxcInfo() }
        .sheet(isPresented: $showLogs) { LogView().environmentObject(state) }
    }

    // MARK: - Building blocks

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textLo)
            VStack(spacing: 0) { content() }
                .padding(4)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke))
        }
    }

    private func toggleRow(_ title: String, _ subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textHi)
                Text(subtitle).font(.caption2).foregroundStyle(Theme.textLo)
            }
        }
        .toggleStyle(.switch)
        .tint(Theme.accent)
        .padding(.horizontal, 10).padding(.vertical, 8)
    }
}
