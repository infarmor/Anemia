import AVFoundation
import CoreImage
import SwiftUI
import VisionKit

/// Reads share links and subscription addresses from QR codes: live from
/// the camera, or from a picture in the photo library.
enum QRReader {
    /// Every QR payload in an image.
    static func payloads(in data: Data) -> [String] {
        guard let image = CIImage(data: data),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        else { return [] }
        return detector.features(in: image)
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            .filter { !$0.isEmpty }
    }

    /// Asks for the camera if iOS hasn't asked yet, then reports whether the
    /// scanner can run. `DataScannerViewController.isAvailable` is false
    /// while the answer is still outstanding — and the scanner is what would
    /// have prompted for it, so reading availability alone left a fresh
    /// install with "camera unavailable" and no entry in Настройки to fix.
    @MainActor
    static func requestCamera() async -> Bool {
        guard DataScannerViewController.isSupported else { return false }
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            guard await AVCaptureDevice.requestAccess(for: .video) else { return false }
        }
        return DataScannerViewController.isAvailable
    }
}

/// The camera, looking for QR codes; the first one found is the result.
struct QRScannerView: UIViewControllerRepresentable {
    let onFound: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        // Starting in makeUIViewController can fail before the view is in the
        // hierarchy; the retry costs nothing once it is running.
        if !controller.isScanning { try? controller.startScanning() }
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onFound: onFound)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onFound: (String) -> Void
        private var done = false

        init(onFound: @escaping (String) -> Void) {
            self.onFound = onFound
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in items {
                if case .barcode(let code) = item, let payload = code.payloadStringValue, !payload.isEmpty {
                    done = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onFound(payload)
                    return
                }
            }
        }
    }
}

/// The camera sheet: the scanner under a short hint.
struct QRScannerSheet: View {
    let onFound: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    /// nil while iOS waits for the answer to the camera prompt.
    @State private var ready: Bool?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                switch ready {
                case .some(true):
                    QRScannerView { payload in
                        onFound(payload)
                        dismiss()
                    }
                    .ignoresSafeArea()
                case .some(false):
                    ContentUnavailableView(
                        "Камера недоступна",
                        systemImage: "camera.metering.unknown",
                        description: Text("Разрешите Anemia доступ к камере в Настройках или выберите снимок QR-кода из Фото.")
                    )
                default:
                    ProgressView()
                }
                Text("Наведите камеру на QR-код сервера или подписки")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 28)
            }
            .navigationTitle("QR-код")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
        }
        .task { ready = await QRReader.requestCamera() }
    }
}
