import SwiftUI

/// Live view of recent xray log lines.
struct LogView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Logs").font(Theme.display(17)).tracking(Theme.tracking(for: 17))
                Text("xray engine").font(Theme.ui(10)).foregroundStyle(Theme.textLo)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.idle, in: Capsule())
                Spacer()
                GhostButton(title: "Clear") { state.clearLogs() }
                    .help("Clear the log buffer")
                GhostButton(title: "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(state.logLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: 10, weight: .regular, design: .monospaced))
                                .foregroundStyle(Theme.textLo)
                                .textSelection(.enabled)
                                .id(idx)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Follow the revision, not the count: the count saturates at
                // the buffer cap (append one, drop one), so observing it
                // stopped firing exactly when the engine was chattiest.
                // Two-parameter onChange needs macOS 14; the deployment target
                // is 13, so the single-parameter form stays.
                .onChange(of: state.logRevision, perform: { _ in
                    if let last = state.logLines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                })
                // Open at the newest line: without this a chatty engine's
                // log sheet opened at the TOP (oldest), and only jumped to
                // the bottom when the next line arrived.
                .onAppear {
                    if let last = state.logLines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            .frame(height: 260)
            .padding(.horizontal, 10).padding(.vertical, 8)
            // Console slab: a quiet recessed panel (fill + hairline) instead
            // of a bare stroked rectangle — same field language as the import
            // fields, so sheets read as one app.
            .background(Theme.idle, in: RoundedRectangle(cornerRadius: Theme.subRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.subRadius, style: .continuous).stroke(Theme.stroke))
        }
        .padding(16)
        .frame(width: 460)
        // Same native vibrancy as every other surface.
        .background(VibrancyBackground())
    }
}
