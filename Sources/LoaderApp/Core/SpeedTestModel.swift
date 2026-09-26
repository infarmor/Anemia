import Foundation
import LoaderCore

/// The Speed Test pane around LoaderCore's SpeedTester: the phase, the live
/// rate for the dial, and the last results.
@MainActor
final class SpeedTestModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case latency
        case download
        case upload
        case done
        case failed(String)
    }

    struct Result: Codable, Identifiable {
        var id = UUID()
        var date: Date
        /// The server it went through; nil without the VPN.
        var server: String?
        var latency: Int?
        /// Bits per second.
        var download: Double
        var upload: Double?
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var latency: Int?
    @Published private(set) var download: Double?
    @Published private(set) var upload: Double?
    /// The running phase's current rate, bits per second.
    @Published private(set) var live: Double = 0
    @Published private(set) var history: [Result] = []

    var isRunning: Bool {
        phase == .latency || phase == .download || phase == .upload
    }

    private static let historyKey = "speedTests"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.historyKey),
           let saved = try? JSONDecoder().decode([Result].self, from: data) {
            history = saved
        }
    }

    /// `proxy`: the engine's SOCKS inbound when the system tunnel doesn't
    /// carry the app's own traffic.
    func run(through server: String?, proxy: LocalProxy?) async {
        guard !isRunning else { return }
        latency = nil
        download = nil
        upload = nil
        live = 0
        phase = .latency
        do {
            let result = try await SpeedTester.run(proxy: proxy) { [weak self] event in
                Task { @MainActor in self?.show(event) }
            }
            latency = result.latency
            download = result.download
            upload = result.upload
            live = 0
            phase = .done
            history.insert(Result(date: .now, server: server, latency: result.latency,
                                  download: result.download, upload: result.upload), at: 0)
            if history.count > 10 { history.removeLast(history.count - 10) }
            if let data = try? JSONEncoder().encode(history) {
                UserDefaults.standard.set(data, forKey: Self.historyKey)
            }
        } catch {
            live = 0
            phase = .failed("The test server didn't answer: \(error.localizedDescription)")
        }
    }

    private func show(_ event: SpeedTester.Event) {
        guard isRunning else { return }
        switch event {
        case .live(.latency, _):
            phase = .latency
        case .live(.download, let rate):
            phase = .download
            live = rate
        case .live(.upload, let rate):
            phase = .upload
            live = rate
        case .measured(.latency, let ms):
            latency = Int(ms)
        case .measured(.download, let rate):
            download = rate
            live = 0
        case .measured(.upload, let rate):
            upload = rate
        }
    }
}
