import Foundation
import LoaderCore

enum XrayError: LocalizedError {
    case binaryNotFound
    case alreadyRunning
    case failedToStart(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "Xray-core binary not found. Bundle it in Resources/xray or set LOADER_XRAY_PATH."
        case .alreadyRunning:
            return "Xray is already running."
        case .failedToStart(let m):
            return "Failed to start Xray: \(m)"
        }
    }
}

/// Supervises a local `xray` process that runs the generated config and exposes
/// the SOCKS/HTTP inbounds. It does not touch the system route table — that is
/// the privileged helper's job. This class only owns the proxy engine.
///
/// Main-actor isolated: Process/FileHandle callbacks are `@Sendable` and fire on
/// background queues, so they hop back to the main actor before touching state.
@MainActor
final class XrayController {
    private var process: Process?
    private var pipe: Pipe?
    private var configURL: URL?
    private var builder: XrayConfigBuilder

    /// Streamed log lines from the xray process (already trimmed).
    var onLog: ((String) -> Void)?
    /// Called when the process exits, with its termination status.
    var onExit: ((Int32) -> Void)?

    init(builder: XrayConfigBuilder = XrayConfigBuilder()) {
        self.builder = builder
    }

    var isRunning: Bool { process?.isRunning ?? false }
    var socksPort: Int { builder.socksPort }
    var httpPort: Int { builder.httpPort }
    var apiPort: Int? { builder.apiPort }

    /// Locate the xray binary. Search order:
    ///   1. `LOADER_XRAY_PATH` env override (dev convenience)
    ///   2. app bundle `Resources/xray` (production, bundled + signed)
    ///   3. common Homebrew / local install paths
    func resolveBinary() -> URL? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["LOADER_XRAY_PATH"],
           fm.isExecutableFile(atPath: env) {
            return URL(fileURLWithPath: env)
        }
        if let bundled = Bundle.main.url(forResource: "xray", withExtension: nil),
           fm.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        for candidate in ["/opt/homebrew/bin/xray", "/usr/local/bin/xray"] {
            if fm.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }

    /// Write the config for `server` and launch xray. Throws if already running
    /// or the binary is missing.
    ///
    /// Async: `xray run -test` validation is spawned off the main actor so the
    /// UI never freezes while the engine checks its own config.
    func start(server: ProxyServer, anti: AntiCensorshipOptions) async throws {
        guard !isRunning else { throw XrayError.alreadyRunning }
        guard let binary = resolveBinary() else { throw XrayError.binaryNotFound }

        // Pick free ports so a lingering process or another app can't block the
        // bind and crash the engine on start.
        let socks = PortFinder.pick(preferred: builder.socksPort)
        let http = PortFinder.pick(preferred: builder.httpPort, exclude: [socks])
        builder.socksPort = socks
        builder.httpPort = http
        if let ap = builder.apiPort {
            builder.apiPort = PortFinder.pick(preferred: ap, exclude: [socks, http])
        }

        let data = try builder.makeConfigData(server: server, anti: anti)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loader-xray-\(UUID().uuidString).json")
        try data.write(to: url, options: [.atomic])
        configURL = url

        // Validate the config with the real engine before launching, so a bad
        // profile fails with a clear message instead of a crash loop. Runs in
        // a detached task — spawning + running xray takes 100ms+.
        let binaryPath = binary.path
        let check = await Task.detached(priority: .userInitiated) {
            Self.validateConfig(binaryPath: binaryPath, configPath: url.path)
        }.value
        if !check.ok {
            cleanupConfig()
            throw XrayError.failedToStart(check.message)
        }

        let proc = Process()
        proc.executableURL = binary
        proc.arguments = ["run", "-c", url.path]
        proc.qualityOfService = .userInitiated

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = outPipe
        pipe = outPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
            let lines = text
                .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for line in lines { self.onLog?(line) }
            }
        }

        proc.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Only tear down state if THIS run is still current. A stale
                // handler (fired after a quick stop/start cycle) must not wipe
                // the new process or delete the new run's config file.
                guard self.process === p else { return }
                self.pipe?.fileHandleForReading.readabilityHandler = nil
                self.pipe = nil
                self.process = nil
                self.cleanupConfig()
                self.onExit?(status)
            }
        }

        do {
            try proc.run()
        } catch {
            cleanupConfig()
            throw XrayError.failedToStart(error.localizedDescription)
        }
        process = proc
    }

    func stop() {
        guard let proc = process else { return }
        // Clean up synchronously: the termination handler will see a
        // mismatched/stale process and skip its cleanup (see start()).
        pipe?.fileHandleForReading.readabilityHandler = nil
        pipe = nil
        process = nil
        if proc.isRunning { proc.terminate() }
        cleanupConfig()
    }

    private func cleanupConfig() {
        if let url = configURL { try? FileManager.default.removeItem(at: url) }
        configURL = nil
    }

    /// Run `xray -test` on a config file. Returns success and, on failure, the
    /// most relevant error line. Blocking by design — call it from a detached
    /// task (see `start`). Nonisolated: the class is @MainActor, but this must
    /// be callable from any executor.
    nonisolated private static func validateConfig(binaryPath: String, configPath: String) -> (ok: Bool, message: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = ["run", "-c", configPath, "-test"]
        proc.qualityOfService = .userInitiated
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = out
        do { try proc.run() } catch {
            return (false, "validation spawn failed: \(error.localizedDescription)")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        if proc.terminationStatus == 0 { return (true, "") }
        let lines = (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").map(String.init)
        let msg = lines.last { $0.contains("failed") || $0.contains("invalid") } ?? lines.last ?? "config invalid"
        return (false, msg)
    }
}

/// Cumulative proxy traffic counters (bytes) from Xray's Stats API, queried via
/// the `xray api statsquery` CLI. Runnable off the main actor.
func queryXrayTraffic(binaryPath: String, apiPort: Int) -> (up: Int64, down: Int64)? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: binaryPath)
    proc.arguments = ["api", "statsquery", "--server=127.0.0.1:\(apiPort)"]
    proc.qualityOfService = .background   // diagnostics path — keep the CPU quiet
    let out = Pipe()
    proc.standardOutput = out
    proc.standardError = Pipe()
    do { try proc.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0,
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let stats = obj["stat"] as? [[String: Any]] else { return nil }

    var up: Int64 = 0, down: Int64 = 0
    for s in stats {
        guard let name = s["name"] as? String else { continue }
        let value = Int64((s["value"] as? String) ?? "0") ?? 0
        if name == "outbound>>>proxy>>>traffic>>>uplink" { up = value }
        else if name == "outbound>>>proxy>>>traffic>>>downlink" { down = value }
    }
    return (up, down)
}
