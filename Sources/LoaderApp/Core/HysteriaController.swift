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
                return "hysteria binary not found. Bundle it next to the app, install it via Homebrew, or set LOADER_HYSTERIA_PATH."
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
    private var pipe: Pipe?
    private var configURL: URL?
    private var logTail: [String] = []
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
        guard !isRunning else { throw XrayError.alreadyRunning }
        try validate(server: server)
        guard let binary = Self.resolveBinary() else { throw HysteriaError.binaryNotFound }
        logTail.removeAll()

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

        // Same per-run line buffering discipline as the xray pipe: the engine
        // writes arbitrary chunks, so a naive split emits partial lines.
        let lineBuffer = LogLineBuffer()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self, lineBuffer] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let lines = lineBuffer.append(chunk)
            guard !lines.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for line in lines {
                    self.logTail.append(line)
                    if self.logTail.count > 20 { self.logTail.removeFirst(self.logTail.count - 20) }
                    self.onLog?(line)
                }
            }
        }

        proc.terminationHandler = { [weak self] p in
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

        // The bridge is what xray will dial: a "connected" state over a dead
        // hysteria process would blackhole every page. Same gate as the xray
        // start path, with a longer deadline (QUIC handshake + possible port
        // hopping on first dial).
        let ready = await Task.detached(priority: .userInitiated) { [port] in
            Self.waitForPort(port, timeout: 10)
        }.value
        guard ready, process?.isRunning == true else {
            let alive = process?.isRunning ?? false
            let reason = alive
                ? "hysteria did not open bridge port \(port) in time"
                : (logTail.last ?? "hysteria exited during startup")
            stop()
            throw XrayError.failedToStart(reason)
        }
        socksPort = port
        runToken = UUID()
        return port
    }

    func stop() {
        guard let proc = process else { return }
        pipe?.fileHandleForReading.readabilityHandler = nil
        pipe = nil
        process = nil
        runToken = nil
        socksPort = nil
        // Same re-verify-before-kill discipline as XrayController.stop: the
        // pid can be recycled between isRunning and the signal, so an
        // unguarded terminate would land on an innocent new owner.
        if proc.isRunning, Self.pidStillIs(proc) { proc.terminate() }
        cleanupConfig()
    }

    /// proc_pidpath re-verification (same contract as XrayController): the
    /// child at this pid must still be OUR binary before signaling it.
    nonisolated private static func pidStillIs(_ proc: Process) -> Bool {
        var buf = [CChar](repeating: 0, count: 1024)   // PROC_PIDPATHINFO_MAXSIZE
        let n = proc_pidpath(proc.processIdentifier, &buf, UInt32(buf.count))
        guard n > 0 else { return false }
        return String(decoding: buf.prefix(Int(n)).map(UInt8.init), as: UTF8.self) == proc.executableURL?.path
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
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(exeDir.appendingPathComponent("hysteria"))
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/hysteria"))
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    /// Poll until 127.0.0.1:port accepts TCP connections (the bridge is TCP
    /// even though the upstream wire is QUIC). Blocking — call detached.
    nonisolated private static func waitForPort(_ port: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if PortFinder.canConnect(port) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }
}

/// Byte-chunk → complete-log-lines buffer for the hysteria pipe (same shape
/// as XrayController's). `readabilityHandler` is invoked serially per handle,
/// and each run owns its own buffer, so no locking is needed.
private final class LogLineBuffer: @unchecked Sendable {
    private var pending = Data()

    /// Append a chunk; returns any complete lines it finished (trimmed, empty
    /// lines dropped).
    func append(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            let slice = Data(pending[..<nl])
            pending.removeSubrange(pending.startIndex...nl)
            guard let text = String(data: slice, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            else { continue }
            lines.append(text)
        }
        return lines
    }
}