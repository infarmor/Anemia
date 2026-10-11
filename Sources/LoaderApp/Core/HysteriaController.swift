import Foundation
import LoaderCore

/// App-side half of a Hysteria session. Unlike the WireGuard family, hysteria
/// needs no root: the client binary runs as the user, dials the server over
/// QUIC and serves a local SOCKS5 bridge that Xray routes through (see
/// ``HysteriaConfigBuilder`` for the split of responsibilities). This class
/// owns the process lifecycle — locate the binary, generate the YAML, spawn,
/// gate on the bridge port opening, and stop exactly the run that started.
@MainActor
final class HysteriaController {
    enum HysteriaError: LocalizedError {
        case binaryNotFound

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "This build has no Hysteria engine. Fetch it with Scripts/fetch-extra-engines.sh hysteria and rebuild, install it via Homebrew, or set LOADER_HYSTERIA_PATH."
            }
        }
    }

    /// Identity of the live engine run, compared by the supersede/teardown
    /// sweep like XrayController.runToken. Nil when not running.
    private(set) var runToken: UUID?
    /// The local SOCKS5 bridge port this run is serving — the xray config's
    /// socks outbound targets it via `userData["hySocksPort"]`.
    private(set) var socksPort: Int?

    var isRunning: Bool { runToken != nil }

    private var process: Process?
    /// True while a `start` is between its guard and the readiness gate (the
    /// XrayController contract). `isRunning` stays false until the bridge
    /// answers, so without this a second start spawned a second client over
    /// the first: the first was orphaned with its QUIC session and port, and
    /// its failing readiness gate then stopped the *second* one.
    private var starting = false
    /// Set by stop() when `starting` is true: start() checks this after
    /// spawning the process and terminates the orphan before returning.
    /// Mirrors XrayController.stopRequested (same race, same fix).
    private var stopRequested = false
    private var pipe: Pipe?
    private var configURL: URL?
    /// Set by AppState to mirror engine log lines into the app log.
    var onLog: ((String) -> Void)?

    /// Up-front validation — a v1 link or a broken endpoint must fail with a
    /// clear message before anything spawns.
    func validate(server: ProxyServer) throws {
        let problems = HysteriaConfigBuilder.validate(server: server)
        guard problems.isEmpty else {
            struct Invalid: LocalizedError { let errorDescription: String? }
            throw Invalid(errorDescription: problems.joined(separator: "\n"))
        }
    }

    /// Generate the YAML, spawn `hysteria client -c <file>`, and wait until
    /// the local SOCKS bridge accepts connections. Returns the bridge port.
    func start(server: ProxyServer) async throws -> Int {
        guard !isRunning, !starting else { throw XrayError.alreadyRunning }
        starting = true
        stopRequested = false
        defer { starting = false }
        try validate(server: server)
        guard let binary = Self.resolveBinary() else { throw HysteriaError.binaryNotFound }

        let port = PortFinder.pick(preferred: 21180)
        let yaml = try HysteriaConfigBuilder.makeClientConfig(server: server, socksPort: port)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loader-hysteria-\(UUID().uuidString).yaml")
        try Data(yaml.utf8).write(to: url, options: [.atomic])
        configURL = url

        let proc = Process()
        proc.executableURL = binary
        proc.arguments = ["client", "-c", url.path]
        proc.qualityOfService = .userInitiated

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = outPipe
        pipe = outPipe

        // Same per-run line buffering and exit latch as the xray engine (see
        // EngineProcess): the readiness gate reads both off the main actor.
        let lineBuffer = LogLineBuffer()
        let exited = ExitLatch()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self, lineBuffer] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                lineBuffer.finish()
                return
            }
            let lines = lineBuffer.append(chunk)
            guard !lines.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for line in lines { self.onLog?(line) }
            }
        }

        proc.terminationHandler = { [weak self, exited] p in
            exited.mark()
            let status = p.terminationStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.process === p else { return }
                self.pipe?.fileHandleForReading.readabilityHandler = nil
                self.pipe = nil
                self.process = nil
                self.runToken = nil
                self.socksPort = nil
                self.cleanupConfig()
                if status != 0 { self.onLog?("hysteria exited (\(status))") }
            }
        }

        do { try proc.run() } catch {
            cleanupConfig()
            throw XrayError.failedToStart(error.localizedDescription)
        }
        process = proc
        // stop() may have landed while the spawn was still in flight (before
        // the process was registered): honor it now instead of leaving the
        // hysteria client running orphaned.
        if stopRequested {
            stop()
            throw XrayError.cancelled
        }

        // The bridge is what xray will dial: a "connected" state over a dead
        // hysteria process would blackhole every page. Same gate as the xray
        // start path, with a longer deadline (QUIC handshake + possible port
        // hopping on first dial). A client that dies on a bad password or an
        // unreachable server reports why at once instead of after 10 s.
        let outcome = await Task.detached(priority: .userInitiated) { [port, exited] in
            EngineProcess.waitForReady(port: port, exited: exited, timeout: 10)
        }.value
        guard outcome == .ready, process?.isRunning == true else {
            let reason: String
            if outcome == .timeout, process?.isRunning == true {
                reason = "hysteria did not open bridge port \(port) in time"
            } else {
                let lines = await Task.detached(priority: .userInitiated) { [lineBuffer] in
                    lineBuffer.waitForEOF(timeout: 0.3)
                    return lineBuffer.tailLines()
                }.value
                reason = EngineLog.failureReason(from: lines)
            }
            stop()
            throw XrayError.failedToStart(reason)
        }
        socksPort = port
        runToken = UUID()
        return port
    }

    func stop() {
        guard let proc = process else {
            // A start is still in flight: it checks stopRequested after
            // spawning the process and cleans up after itself.
            if starting { stopRequested = true }
            return
        }
        pipe?.fileHandleForReading.readabilityHandler = nil
        pipe = nil
        process = nil
        runToken = nil
        socksPort = nil
        // Same re-verify-before-kill discipline as XrayController.stop: the
        // pid can be recycled between isRunning and the signal, so an
        // unguarded terminate would land on an innocent new owner.
        if proc.isRunning, Self.pidStillIs(proc) {
            proc.terminate()
            // xray gets a SIGTERM → SIGKILL ladder for exactly this wedge; the
            // hysteria client deserves the same. A client stuck in QUIC
            // teardown ignores SIGTERM, and once `stop()` has dropped the
            // process reference every later stop() is a no-op — the orphan
            // (with its live UDP session and bound bridge port) lingered until
            // the user killed it by hand. Escalate off-actor: stop() must
            // return immediately.
            Task.detached(priority: .utility) { [proc] in
                // Monotonic grace, same reason as in XrayController: a clock
                // stepped forwards would SIGKILL a client that was closing its
                // QUIC session on SIGTERM just fine.
                let grace = DispatchTime.now()
                while proc.isRunning, EngineProcess.seconds(since: grace) < 2 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                if proc.isRunning, Self.pidStillIs(proc) { kill(proc.processIdentifier, SIGKILL) }
            }
        }
        cleanupConfig()
    }

    /// proc_pidpath re-verification (same contract as XrayController): the
    /// child at this pid must still be OUR binary before signaling it.
    nonisolated private static func pidStillIs(_ proc: Process) -> Bool {
        EngineProcess.pid(proc.processIdentifier,
                          isExecutable: proc.executableURL?.path ?? "")
    }

    /// Stop only if the live run is still the one `token` identifies.
    func stop(ifRunning token: UUID) {
        guard runToken == token else { return }
        stop()
    }

    private func cleanupConfig() {
        if let url = configURL { try? FileManager.default.removeItem(at: url) }
        configURL = nil
    }

    /// Locate the hysteria engine: `LOADER_HYSTERIA_PATH` override (dev), a
    /// binary bundled next to the app, or Homebrew.
    nonisolated static func resolveBinary() -> URL? {
        let fm = FileManager.default
        if let p = ProcessInfo.processInfo.environment["LOADER_HYSTERIA_PATH"], !p.isEmpty,
           fm.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        var candidates: [URL] = []
        // build-app.sh bundles engines into Contents/Resources.
        if let bundled = Bundle.main.url(forResource: "hysteria", withExtension: nil) {
            candidates.append(bundled)
        }
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(exeDir.appendingPathComponent("hysteria"))
        }
        // Homebrew's prefix is CPU-specific — Apple Silicon installs under
        // /opt/homebrew, Intel under /usr/local — the same two paths
        // `EngineInventory.xrayPath()` searches. Looking only at the first
        // made a brewed engine invisible on Intel Macs.
        candidates.append(contentsOf: ["/opt/homebrew/bin/hysteria", "/usr/local/bin/hysteria"]
            .map { URL(fileURLWithPath: $0) })
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

}
