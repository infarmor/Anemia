import AVFoundation
import os

/// Keeps the app running in the background while the Live Activity shows the
/// live speed. iOS lets only the app update the activity, and a suspended app
/// updates nothing — the tunnel extension can't reach it (checked: extensions
/// see no activities). So the app plays silence through a session that mixes
/// with other apps: nothing is heard and other audio keeps playing.
/// It costs battery; the user can switch it off in the app.
@MainActor
final class BackgroundKeeper {
    private var engine = AVAudioEngine()
    private var silenceAttached = false
    private var startedOnce = false
    private var observers: [NSObjectProtocol] = []
    private var watchdog: Task<Void, Never>?
    private let log = Logger(subsystem: "Anemia", category: "keeper")
    private(set) var isRunning = false
    /// Frames the audio thread has rendered — the only real proof the output
    /// is being pulled. `engine.isRunning` is the engine's own claim, and iOS
    /// can stop taking the stream while it stays true.
    private let frames = OSAllocatedUnfairLock(initialState: UInt64(0))
    private var framesSeen: UInt64 = 0
    private var pulledAt = Date.distantPast
    /// Whether the silent stream is actually reaching the hardware at this
    /// moment; 25 s of quiet means the watchdog is about to take it back.
    var isProducing: Bool { engine.isRunning && Date().timeIntervalSince(pulledAt) < 25 }
    /// How many times iOS took the output away and it had to be taken back —
    /// the number that says why the Live Activity stopped moving.
    private(set) var restarts = 0
    private(set) var lastRestart: Date?

    func start() {
        guard !isRunning else {
            // Already playing: make sure the output is still alive — iOS
            // stops it on a route change and the watchdog may not have run.
            resume()
            return
        }
        isRunning = true
        observe()
        resume()
        framesSeen = frames.withLock { $0 }
        pulledAt = Date()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, self.isRunning else { return }
                let seen = self.frames.withLock { $0 }
                guard seen == self.framesSeen else {
                    self.framesSeen = seen
                    self.pulledAt = Date()
                    continue
                }
                self.log.notice("keeper: the output stopped being pulled")
                self.engine.stop()
                self.resume()
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        startedOnce = false
        watchdog?.cancel()
        watchdog = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        log.notice("keeper stopped")
    }

    /// (Re)starts the silent output, also after a call or a route change
    /// stopped it.
    private func resume() {
        guard isRunning else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            // The output is silence: fewer render callbacks are enough.
            try? session.setPreferredIOBufferDuration(0.2)
            try session.setActive(true)
            if !silenceAttached {
                let silence = Self.makeSilence(frames)
                engine.attach(silence)
                engine.connect(silence, to: engine.mainMixerNode, format: nil)
                silenceAttached = true
            }
            if !engine.isRunning {
                if startedOnce {
                    restarts += 1
                    lastRestart = Date()
                    log.notice("keeper: the output had to be taken back")
                }
                try engine.start()
            }
            startedOnce = true
        } catch {
            log.error("keeper: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// After a media-services reset every engine is dead; build a new one.
    private func rebuild() {
        engine.stop()
        engine = AVAudioEngine()
        silenceAttached = false
        resume()
    }

    private func observe() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                guard raw.flatMap(AVAudioSession.InterruptionType.init) == .ended else { return }
                MainActor.assumeIsolated { self?.resume() }
            },
            // The engine stops itself when the output route changes.
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuild() }
            },
        ]
    }

    /// Built outside the main actor: the render block runs on the audio thread.
    nonisolated private static func makeSilence(_ frames: OSAllocatedUnfairLock<UInt64>) -> AVAudioSourceNode {
        // A format of our own, so the block knows what it writes into.
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        return AVAudioSourceNode(format: format) { _, _, count, output in
            // Not a stream of zeros: iOS treats those as a dead output and
            // takes the background audio away after a few minutes. The dither
            // is some 100 dB below anything audible.
            let size = MemoryLayout<Float>.size
            var frame = 0
            for buffer in UnsafeMutableAudioBufferListPointer(output) {
                guard let raw = buffer.mData else { continue }
                let written = min(Int(count), Int(buffer.mDataByteSize) / size)
                let samples = raw.bindMemory(to: Float.self, capacity: written)
                for index in 0..<written {
                    samples[index] = frame & 1 == 0 ? 1e-5 : -1e-5
                    frame += 1
                }
            }
            frames.withLock { $0 += UInt64(max(1, Int(count))) }
            return noErr
        }
    }
}
