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
    @State private var clipboardLinks: [String] = []
    @State private var dropping = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedField: Field?

    private enum Field { case name, url, link }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import").font(Theme.display(17)).tracking(Theme.tracking(for: 17))

            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            switch mode {
            case .link:
                Text("Paste a vless:// / vmess:// / ss:// / trojan:// link, an amnezia:// / wireguard:// link, or a whole WireGuard config")
                    .font(Theme.ui(11)).foregroundStyle(Theme.textLo)
                TextEditor(text: $linkText)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .focused($focusedField, equals: .link)
                    // TextEditor keeps its system (light) scroll background
                    // unless explicitly hidden — in the dark theme it rendered
                    // as a white slab. Hide it and lay the field on the theme.
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(height: 90)
                    .background(Theme.idle, in: fieldShape)
                    .overlay(fieldShape.stroke(dropping || focusedField == .link
                                               ? Theme.accent.opacity(0.55) : Theme.stroke))
                if !clipboardLinks.isEmpty, linkText.isEmpty {
                    Button {
                        linkText = clipboardLinks.joined(separator: "\n")
                        clipboardLinks = []
                    } label: {
                        Label("Add \(clipboardLinks.count) link\(clipboardLinks.count == 1 ? "" : "s") from clipboard",
                              systemImage: "doc.on.clipboard")
                            .font(Theme.ui(12, .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .softCard(Theme.subRadius, fill: Theme.cardHi, shadow: false)
                    }
                    .buttonStyle(PressableStyle())
                    .pointerCursor()
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                }
            case .subscription:
                TextField("Name (optional)", text: $subName)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .name)
                    .fieldChrome(focused: focusedField == .name)
                TextField("https://…", text: $subURL)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .url)
                    .fieldChrome(focused: focusedField == .url)
            }

            if let err = state.lastImportError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(Theme.ui(10, .bold))
                    Text(err)
                        .font(Theme.ui(11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Theme.danger)
            }

            HStack(spacing: 8) {
                Spacer()
                GhostButton(title: "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if working {
                    ProgressView().controlSize(.small).padding(.horizontal, 8)
                } else {
                    PillButton(title: "Import", icon: "tray.and.arrow.down") { submit() }
                        .disabled(!canSubmit)
                        .opacity(canSubmit ? 1 : 0.45)
                }
            }
        }
        .padding(16)
        .frame(width: 360)
        // Same native vibrancy as every other surface.
        .background(VibrancyBackground())
        .onAppear {
            state.lastImportError = nil
            focusedField = nil
            // Drag & drop prefill: a drop on the main window stages text here.
            if let staged = state.pendingImportText {
                linkText = staged
                state.pendingImportText = nil
                mode = .link
            } else {
                clipboardLinks = state.clipboardShareLinks() ?? []
            }
        }
        .animation(Theme.springQuick, value: focusedField)
        .animation(Theme.springQuick, value: dropping)
        .animation(Theme.spring, value: linkText.isEmpty)
        // Dropping text straight onto the sheet appends it to the field —
        // the same drop anywhere on the main window opens this sheet prefilled.
        .dropDestination(for: String.self) { text, _ in
            let payload = text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty else { return false }
            let current = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
            linkText = current.isEmpty ? payload : current + "\n" + payload
            mode = .link
            return true
        } isTargeted: { dropping = $0 }
    }

    private var fieldShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.subRadius, style: .continuous)
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
