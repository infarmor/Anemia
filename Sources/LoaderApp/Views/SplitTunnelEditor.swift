import SwiftUI
import LoaderCore

/// The bypass list editor (Settings → Split tunneling): one destination per
/// line — or pasted comma-separated — validated as you type with the same
/// parser the engine config and the helper use, so what reads as accepted
/// here is exactly what gets routed around the VPN.
struct SplitTunnelEditor: View {
    @EnvironmentObject var state: AppState
    @State private var text = ""
    @State private var loaded = false
    @FocusState private var focused: Bool

    private var parsed: SplitTunnelParser.Result { SplitTunnelParser.parse(text: text) }

    /// Stored form: one trimmed entry per line, comments dropped.
    private var lines: [String] {
        parsed.entries.map(\.value) + parsed.rejected.map(\.line)
    }

    private var dirty: Bool {
        normalized(text) != normalized(state.splitTunnel.entries.joined(separator: "\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 6).padding(.vertical, 6)
                if text.isEmpty {
                    Text("10.8.0.0/16\n203.0.113.7\nbank.ru\n*.gosuslugi.ru\nсбербанк.рф")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(Theme.textLo.opacity(0.6))
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 104)
            .background(Theme.idle, in: fieldShape)
            .overlay(fieldShape.strokeBorder(focused ? Theme.accent.opacity(0.55) : Theme.stroke))
            .animation(Theme.springQuick, value: focused)

            HStack(alignment: .center, spacing: 8) {
                Text(summary)
                    .font(Theme.ui(11)).foregroundStyle(Theme.textLo)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                PillButton(title: "Save", icon: "checkmark") {
                    state.setSplitTunnel(entries: lines)
                    text = state.splitTunnel.entries.joined(separator: "\n")
                }
                .disabled(!dirty)
                .opacity(dirty ? 1 : 0.45)
            }

            ForEach(Array(parsed.rejected.prefix(4).enumerated()), id: \.offset) { _, rejection in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(Theme.ui(10, .bold))
                    Text("\(rejection.line) — \(rejection.reason)")
                        .font(Theme.ui(11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .onAppear {
            guard !loaded else { return }
            text = state.splitTunnel.entries.joined(separator: "\n")
            loaded = true
        }
    }

    private var fieldShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.subRadius, style: .continuous)
    }

    private var summary: String {
        let entries = parsed.entries
        guard !entries.isEmpty else {
            return "One per line: IP address or network (CIDR), or a domain — subdomains are included."
        }
        let domains = entries.filter(\.isDomain).count
        let networks = entries.count - domains
        var parts: [String] = []
        if networks > 0 { parts.append("\(networks) network\(networks == 1 ? "" : "s")") }
        if domains > 0 { parts.append("\(domains) domain\(domains == 1 ? "" : "s")") }
        var s = parts.joined(separator: " · ") + " bypass the VPN"
        if dirty { s += " — not saved" } else if state.isConnected { s += " · from the next connect" }
        return s
    }

    private func normalized(_ s: String) -> [String] {
        let r = SplitTunnelParser.parse(text: s)
        return r.entries.map(\.value) + r.rejected.map(\.line)
    }
}
