import SwiftUI

/// Import a single share link, or add a subscription URL.
struct ImportView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case link = "Share link"
        case subscription = "Subscription"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .link
    @State private var linkText = ""
    @State private var subName = ""
    @State private var subURL = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import").font(.headline)

            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            switch mode {
            case .link:
                Text("Paste a vless:// / vmess:// / ss:// / trojan:// link")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $linkText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            case .subscription:
                TextField("Name (optional)", text: $subName)
                TextField("https://…", text: $subURL)
                    .textFieldStyle(.roundedBorder)
            }

            if let err = state.lastImportError {
                Text(err).font(.caption2).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(action: submit) {
                    if working { ProgressView().controlSize(.small) } else { Text("Import") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(working || !canSubmit)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private var canSubmit: Bool {
        switch mode {
        case .link: return !linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .subscription: return !subURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func submit() {
        switch mode {
        case .link:
            state.importLink(linkText)
            if state.lastImportError == nil { dismiss() }
        case .subscription:
            working = true
            Task {
                await state.addSubscription(name: subName, url: subURL)
                working = false
                if state.lastImportError == nil { dismiss() }
            }
        }
    }
}
