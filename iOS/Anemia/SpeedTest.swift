import Foundation
import LoaderCore
import Observation

/// The speed test screen's state around LoaderCore's SpeedTester: the phase,
/// the live rate for the dial, and the last results.
@MainActor
@Observable
final class SpeedTest {
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

    private(set) var phase: Phase = .idle
    private(set) var latency: Int?
    private(set) var download: Double?
    private(set) var upload: Double?
    /// The running phase's current rate, bits per second.
    private(set) var live: Double = 0
    private(set) var history: [Result] = []

    var isRunning: Bool {
        phase == .latency || phase == .download || phase == .upload
    }

    private static let historyKey = "speedTests"
    @ObservationIgnored private var current: Task<Void, Never>?
    /// Номер текущего замера. Отмена не останавливает `URLSession` мгновенно,
    /// поэтому старый замер ещё может донести события — по номеру видно, что
    /// показывать уже не ему, а тому, что запустили позже.
    @ObservationIgnored private var round = 0

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.historyKey),
           let saved = try? JSONDecoder().decode([Result].self, from: data) {
            history = saved
        }
    }

    /// Who the bytes really went through, read when the measurement ends. The
    /// tunnel can drop mid-run, and a measurement that left directly must not
    /// be filed under "Через VPN · …" in «Прошлые замеры».
    @ObservationIgnored var serverProvider: () -> String? = { nil }

    /// Starts a run and keeps its handle. Before this the screen had no way
    /// to stop a measurement: leaving it running spent up to 225 МБ through
    /// the tunnel after the user was gone, and «Начать» stayed disabled.
    func start() {
        guard !isRunning else { return }
        current?.cancel()
        round += 1
        let mine = round
        current = Task { [weak self] in await self?.run(mine: mine) }
    }

    func stop() {
        current?.cancel()
        current = nil
        round += 1        // уходящий замер теряет право что-либо показывать
        guard isRunning else { return }
        live = 0
        phase = .idle
    }

    private func run(mine: Int) async {
        guard mine == round, !isRunning else { return }
        latency = nil
        download = nil
        upload = nil
        live = 0
        phase = .latency
        do {
            let result = try await SpeedTester.run { [weak self] event in
                Task { @MainActor in self?.show(event, mine: mine) }
            }
            // Stopped mid-run: the numbers belong to a half measurement — and a
            // newer run has the screen, so a late finisher says nothing at all.
            guard mine == round else { return }
            if Task.isCancelled {
                live = 0
                phase = .idle
                return
            }
            latency = result.latency
            download = result.download
            upload = result.upload
            live = 0
            phase = .done
            // Read at the end, not at the start: if the tunnel dropped while
            // the test ran, the bytes went out directly and the entry has to
            // say "Без VPN".
            history.insert(Result(date: .now, server: serverProvider(), latency: result.latency,
                                  download: result.download, upload: result.upload), at: 0)
            if history.count > 10 { history.removeLast(history.count - 10) }
            if let data = try? JSONEncoder().encode(history) {
                UserDefaults.standard.set(data, forKey: Self.historyKey)
            }
        } catch is CancellationError {
            guard mine == round else { return }
            live = 0
            phase = .idle
        } catch {
            guard mine == round else { return }
            live = 0
            if (error as? URLError)?.code == .cancelled {
                phase = .idle
                return
            }
            phase = .failed("Сервер теста не ответил: \(error.localizedDescription)")
        }
    }

    private func show(_ event: SpeedTester.Event, mine: Int) {
        guard isRunning, mine == round else { return }
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
