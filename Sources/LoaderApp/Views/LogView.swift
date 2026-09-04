import SwiftUI

/// Live view of recent xray log lines.
struct LogView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Logs").font(.headline)
                Spacer()
                Button("Clear") { state.clearLogs() }
                Button("Close") { dismiss() }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(state.logLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .id(idx)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: state.logLines.count) { _, _ in
                    if let last = state.logLines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            .frame(height: 260)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
        .padding(16)
        .frame(width: 460)
    }
}
