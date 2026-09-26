import SwiftUI

/// Live view of recent engine log lines, Console-style.
struct LogView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(state.logLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(12)
                }
                .background(Theme.ground)
                .overlay {
                    if state.logLines.isEmpty {
                        ContentUnavailableView("No Log Lines", systemImage: "doc.text",
                                               description: Text("Engine output appears here while connecting."))
                    }
                }
                // Follow the revision, not the count: the count saturates at
                // the buffer cap (append one, drop one).
                .onChange(of: state.logRevision) {
                    if let last = state.logLines.indices.last { proxy.scrollTo(last, anchor: .bottom) }
                }
                .onAppear {
                    if let last = state.logLines.indices.last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            .navigationTitle("Engine Log")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { state.revealLogFile() } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    Button { state.clearLogs() } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .disabled(state.logLines.isEmpty)
                }
            }
        }
        .frame(width: 620, height: 420)
    }
}
