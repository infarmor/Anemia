import AppKit
import CoreImage.CIFilterBuiltins
import LoaderCore
import SwiftUI
import UniformTypeIdentifiers

// Moving servers and settings to Anemia on an iPhone (or another Mac) and
// back: a `.anemia` file over AirDrop or a QR code the iPhone scans. The
// format is LoaderCore's SyncBundle; the iPhone app reads the same thing.

private extension UTType {
    static let anemiaBundle = UTType(filenameExtension: SyncBundle.fileExtension, conformingTo: .json) ?? .json
}

/// The bundle as a file for the share menu (AirDrop, Messages, …).
private struct SyncFile: Transferable {
    let bundle: SyncBundle

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .anemiaBundle) { file in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Anemia.\(SyncBundle.fileExtension)")
            try file.bundle.fileData().write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

/// Settings → General → "Transfer to iPhone".
struct TransferSettingsSection: View {
    @EnvironmentObject var state: AppState
    @State private var showingQR = false
    @State private var incoming: IncomingSync?
    @State private var problem: String?

    var body: some View {
        Section {
            HStack(spacing: 8) {
                ShareLink(item: SyncFile(bundle: state.syncBundle()),
                          preview: SharePreview("Anemia servers and settings")) {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
                Button("Show QR Code", systemImage: "qrcode") { showingQR = true }
                Button("Save File…", systemImage: "arrow.down.doc") { saveFile() }
                Spacer(minLength: 0)
                Button("Import File…", systemImage: "arrow.up.doc") { openFile() }
            }
            .labelStyle(.titleAndIcon)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.accent)
            }
        } header: {
            Text("Transfer to iPhone")
        } footer: {
            Text("Servers, subscriptions and settings for Anemia on your iPhone or another Mac: AirDrop the file, or scan the QR code in Anemia on the iPhone (Servers → + → Scan QR). The file holds your server keys — don't publish it.")
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showingQR) {
            TransferQRView(bundle: state.syncBundle())
        }
        .sheet(item: $incoming) { incoming in
            SyncImportView(bundle: incoming.bundle).environmentObject(state)
        }
    }

    private func saveFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Anemia.\(SyncBundle.fileExtension)"
        panel.allowedContentTypes = [.anemiaBundle]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try state.syncBundle().fileData().write(to: url, options: .atomic)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.anemiaBundle, .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            incoming = IncomingSync(bundle: try SyncBundle.decode(Data(contentsOf: url)))
            problem = nil
        } catch SyncBundle.DecodeError.newerVersion {
            problem = "That file comes from a newer Anemia — update this one first."
        } catch {
            problem = "That isn't an Anemia transfer file."
        }
    }
}

struct IncomingSync: Identifiable {
    let id = UUID()
    let bundle: SyncBundle
}

private struct TransferQRView: View {
    let bundle: SyncBundle
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            if let link = try? bundle.link(), let image = Self.qrImage(link) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 280, height: 280)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text("In Anemia on the iPhone: Servers → + → Scan QR.")
                    .font(.callout)
                    .foregroundStyle(Theme.textLo)
            } else {
                Label("Too much for a QR code — share the file instead.", systemImage: "qrcode")
                    .foregroundStyle(Theme.textLo)
                    .frame(width: 300, height: 200)
            }
            Text("\(bundle.servers.count) servers · \(bundle.subscriptions.count) subscriptions · settings")
                .font(.caption)
                .foregroundStyle(Theme.textLo)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .nativeButtonStyle(prominent: true)
        }
        .padding(24)
        .background(GroundBackground())
    }

    private static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "L"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let image = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}

/// What a bundle from another device would add, and the button that adds it.
struct SyncImportView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let bundle: SyncBundle
    var onDone: (() -> Void)?
    @State private var applySettings = true
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("From", value: bundle.device)
                    LabeledContent("Exported", value: bundle.exportedAt.formatted(.relative(presentation: .named)))
                }
                Section {
                    LabeledContent("New servers") {
                        Text(countText(preview.addedServers, known: preview.knownServers))
                    }
                    LabeledContent("New subscriptions") {
                        Text(countText(preview.newSubscriptions.count, known: preview.knownSubscriptions))
                    }
                    if bundle.settings != nil {
                        Toggle("Take its settings (masking, kill switch, split tunneling)", isOn: $applySettings)
                            .tint(Theme.accent)
                    }
                } footer: {
                    Text("Servers you already have (same endpoint and key) aren't duplicated. Subscriptions are fetched again on this Mac.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Theme.ground)
            .navigationTitle("Import from \(bundle.device)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Import") {
                            working = true
                            Task {
                                await state.importSync(bundle, applySettings: applySettings && bundle.settings != nil)
                                working = false
                                dismiss()
                                onDone?()
                            }
                        }
                        .disabled(preview.addsNothing)
                    }
                }
            }
        }
        .frame(width: 440, height: 360)
    }

    private var preview: SyncBundle.Summary {
        bundle.preview(against: state.persistedSnapshot(), applySettings: applySettings && bundle.settings != nil)
    }

    private func countText(_ count: Int, known: Int) -> String {
        known > 0 ? "\(count) (\(known) already here)" : "\(count)"
    }
}
