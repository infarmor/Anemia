import LoaderCore
import SwiftUI

/// Import a share link (or a pasted list / WireGuard config), or add a
/// subscription URL — a native grouped form with Cancel / Import in the
/// sheet's toolbar.
struct ImportView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case link = "Share Link"
        case subscription = "Subscription"
        var id: String { rawValue }
    }

    init(initialMode: Mode = .link) {
        _mode = State(initialValue: initialMode)
    }

    @State private var mode: Mode
    @State private var linkText = ""
    @State private var subName = ""
    @State private var subURL = ""
    @State private var working = false
    @State private var clipboardLinks: [String] = []
    @State private var dropping = false
    /// Text that turned out to be a transfer bundle from another device.
    @State private var incoming: IncomingSync?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Import", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                switch mode {
                case .link:
                    Section {
                        TextEditor(text: $linkText)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 110)
                            .overlay(alignment: .topLeading) {
                                if linkText.isEmpty {
                                    Text("vless://…  hy2://…  or a WireGuard [Interface] config")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .padding(.top, 1).padding(.leading, 5)
                                        .allowsHitTesting(false)
                                }
                            }
                        if !clipboardLinks.isEmpty, linkText.isEmpty {
                            Button {
                                linkText = clipboardLinks.joined(separator: "\n")
                                clipboardLinks = []
                            } label: {
                                Label("Paste \(clipboardLinks.count) link\(clipboardLinks.count == 1 ? "" : "s") from the clipboard",
                                      systemImage: "doc.on.clipboard")
                            }
                        }
                    } footer: {
                        Text("One link per line; lines that can't be parsed are skipped. You can also drop links or a text file onto the window.")
                            .foregroundStyle(.secondary)
                    }
                case .subscription:
                    Section {
                        TextField("Name", text: $subName, prompt: Text("Optional"))
                        TextField("URL", text: $subURL, prompt: Text("https://…"))
                    } footer: {
                        Text("Fetched now, then refreshed on launch and every 6 hours.")
                            .foregroundStyle(.secondary)
                    }
                }

                if let err = state.lastImportError {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Theme.ground)
            .navigationTitle("Import")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Import") { submit() }
                            .disabled(!canSubmit)
                    }
                }
            }
        }
        .frame(width: 440, height: 400)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            state.lastImportError = nil
            if let staged = state.pendingImportText {
                linkText = staged
                state.pendingImportText = nil
                mode = .link
            } else {
                clipboardLinks = state.clipboardShareLinks() ?? []
            }
        }
        .dropDestination(for: String.self) { text, _ in
            let payload = text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty else { return false }
            let current = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
            linkText = current.isEmpty ? payload : current + "\n" + payload
            mode = .link
            return true
        } isTargeted: { dropping = $0 }
        .sheet(item: $incoming) { incoming in
            SyncImportView(bundle: incoming.bundle, onDone: { dismiss() })
                .environmentObject(state)
        }
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
            // A transfer bundle (an iPhone's QR text or an .anemia file
            // dropped on the window) gets a preview instead.
            if SyncBundle.looksLikeBundle(linkText) {
                do {
                    incoming = IncomingSync(bundle: try SyncBundle.decode(Data(linkText.utf8)))
                } catch SyncBundle.DecodeError.newerVersion {
                    state.lastImportError = "That comes from a newer Anemia — update this one first."
                } catch {
                    state.lastImportError = "That transfer data is damaged."
                }
                return
            }
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
