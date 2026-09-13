import Foundation
import LoaderCore
import Darwin

enum XrayError: LocalizedError {
    case binaryNotFound
    case alreadyRunning
    case failedToStart(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "Xray-core binary not found. Bundle it in Resources/xray or set LOADER_XRAY_PATH."
        case .alreadyRunning:
            return "Xray is already running."
        case .failedToStart(let m):
            return "Failed to start Xray: \(m)"
        case .cancelled:
            return "Engine start cancelled."
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
    /// True while a `start` is between its guards and the readiness gate: a
    /// concurrent `start` sees it and refuses (the running-process guard
    /// alone can't see an engine that hasn't been registered yet).
    private var starting = false
    /// Set when `stop()` is called while a start is still in flight: the
    /// start checks it after each suspension and cleans up after itself —
    /// otherwise the stop was a no-op (no process registered yet) and the
    /// start would spawn an orphaned engine behind a "Not connected" UI.
    private var stopRequested = false
    private var builder: XrayConfigBuilder
    /// Identity of the current engine run, handed to the caller by `start`.
    /// Lets a superseded task tear down the engine IT spawned (an orphan)
    /// without risk of killing a successor's freshly started one: the token
    /// comparison fails the moment any other code path stopped/rotated the
    /// engine. Nil whenever no engine is running.
    private(set) var runToken: UUID?
    /// Tail of recent engine output, kept so startup failures can report the
    /// actual xray complaint instead of a bare "process died".
    private var logTail: [String] = []
    /// Last-known IPv4 per server domain. Mid-session reconnects happen
    /// while the system resolver is pointed at the (dying) tunnel, where a
    /// fresh lookup of the server's own domain can loop; the cache pins the
    /// hosts entry anyway.
    private var resolvedServerIPs: [String: String] = [:]
    /// Server+profile shapes that already passed `xray run -test` this
    /// session — reconnecting to a validated shape skips the validator
    /// spawn. Session-scoped on purpose: the engine binary is fixed per
    /// session, so a validation result stays valid as long as it runs.
    private var validatedKeys: Set<String> = []

    /// Everything about a (server, anti) pair that decides whether the
    /// engine accepts its config: protocol identity, transport, TLS layer,
    /// and the emitted anti-DPI shape. Ports and the resolved server IP are
    /// deliberately excluded — they change per run but never flip a
    /// validation verdict.
    private func validationKey(server: ProxyServer, anti: AntiCensorshipOptions) -> String {
        let frag = anti.fragment.map { "\($0.packets)|\($0.length)|\($0.interval)" } ?? "-"
        let noises = anti.noises.map { "\($0.type)/\($0.packet)/\($0.delay)" }
            .joined(separator: ";")
        return [
            server.identityKey,
            server.network.rawValue,
            server.security.rawValue,
            // alterId/vmessCipher shape the emitted vmess user object; leaving
            // them out reused a verdict cached for a different user config.
            String(server.alterId),
            server.vmessCipher ?? "-",
            server.sni ?? "-",
            server.alpn.joined(separator: ","),
            server.headerType ?? "-",
            server.host ?? "-",
            server.path ?? "-",
            server.grpcMultiMode.map(String.init) ?? "-",
            server.realityPublicKey ?? "-", server.realityShortId ?? "-",
            server.fingerprint ?? anti.fingerprint,
            server.allowInsecure ? "insecure" : "-",
            anti.mimicry.joined(separator: ","),
            anti.muxEnabled ? "mux\(anti.muxConcurrency)" : "-",
            frag,
            noises,
            builder.blockQUIC ? "bq" : "-", builder.hijackDNS ? "hd" : "-",
            String(builder.bufferSizeKB)
        ].joined(separator: "|")
    }

    /// Race an async operation against a deadline; deliver its result, or
    /// `fallback` if the deadline wins. Implemented as two unstructured tasks
    /// resuming a one-shot continuation — NOT withTaskGroup: the group body
    /// implicitly waits for every child, and a child blocked on
    /// `await someUnstructuredTask.value` (getaddrinfo) ignores
    /// `cancelAll()`, so a group-based race returned only when the *loser*
    /// finally finished, i.e. the deadline never bounded the wait. Here the
    /// losing operation keeps running on its own thread and its result is
    /// simply discarded once the deadline fires.
    nonisolated private static func withTimeout<T: Sendable>(
        seconds: TimeInterval, fallback: T,
        _ op: @escaping @Sendable () async -> T
    ) async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            let race = TimeoutRace(cont, fallback: fallback)
            Task.detached(priority: .userInitiated) { race.finish(await op()) }
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                race.expire()
            }
        }
    }

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
        guard !isRunning, !starting else { throw XrayError.alreadyRunning }
        starting = true
        stopRequested = false
        defer { starting = false }
        guard let binary = resolveBinary() else { throw XrayError.binaryNotFound }
        // Fresh tail per run: the reason a NEW start failed must never be the
        // PREVIOUS run's last log line (stale tail survived stop/start and was
        // reported as the failure reason of an engine that never logged).
        logTail.removeAll()

        // Pick free ports so a lingering process or another app can't block the
        // bind and crash the engine on start.
        let socks = PortFinder.pick(preferred: builder.socksPort)
        let http = PortFinder.pick(preferred: builder.httpPort, exclude: [socks])
        builder.socksPort = socks
        builder.httpPort = http
        if let ap = builder.apiPort {
            builder.apiPort = PortFinder.pick(preferred: ap, exclude: [socks, http])
        }
        // Interface pin (route get / scutil) and the server's DNS resolution
        // (getaddrinfo) share nothing — run them CONCURRENTLY instead of as
        // two sequential blocking waits. That shaves a full interface-scan +
        // resolver round trip off every connect and every reconnect.
        //
        // Pin engine sockets to the physical NIC (sockopt.interface →
        // IP_BOUND_IF) so the server connection can never be swallowed by a
        // TUN — ours during a reconnect race, or a third-party VPN client
        // holding the default route (observed: a sing-box client on
        // 198.18.0.1 looping the engine's fragmented ClientHello into RSTs).
        // Off-actor: both shell out / block and must never run on the main
        // thread inside the connect path.
        //
        // getaddrinfo honors NO timeout of its own: on a wedged resolver it
        // hangs for the system's full resolver timeout (tens of seconds),
        // which used to stall the whole connect. Race it against 3 s and fall
        // back to the cached IP — exactly the mid-session case where a fresh
        // lookup of the server's own domain can't succeed anyway (the system
        // resolver points into the dying tunnel), so the cache is not just a
        // fallback but the expected path.
        let serverHost = server.address
        let ifaceTask = Task.detached(priority: .userInitiated) {
            PhysicalInterface.primary()
        }
        let resolveTask = Task.detached(priority: .userInitiated) {
            DirectResolver.ipv4(serverHost)
        }
        let ips = await Self.withTimeout(seconds: 3, fallback: []) {
            await resolveTask.value
        }
        // The winner is done; if the timeout fired first, cancel the loser so
        // it doesn't keep a wedged getaddrinfo alive for tens of seconds past
        // its deadline (the resolver isn't cancellation-aware, but the flag
        // lets it bail and drops the value reference either way).
        resolveTask.cancel()
        // The interface scan shells out to `route`/`scutil`; a hung child would
        // otherwise hold the whole connect hostage with no deadline. Nil just
        // omits the NIC pin — a degraded connect beats no connect.
        builder.dialerInterface = await Self.withTimeout(seconds: 2, fallback: nil) {
            await ifaceTask.value
        }
        ifaceTask.cancel()
        if Task.isCancelled || stopRequested {
            cleanupConfig(); throw XrayError.cancelled
        }

        // Pin the server's domain → IP into the engine's DNS hosts. After the
        // app points the system resolver at the tunnel, any lookup of the
        // server's own domain would otherwise loop: tunnel → engine → DoH
        // through the proxy → and reaching the proxy requires resolving that
        // same domain. That loop is why a healthy connection died ~30 s after
        // connect (TTL expiry) and why reconnects failed from the first
        // health check.
        if let ip = ips.first { resolvedServerIPs[serverHost] = ip }
        var hosts: [String: String] = [:]
        if !DirectResolver.isIPv4(serverHost),
           let ip = resolvedServerIPs[serverHost] {
            hosts[serverHost] = ip
        }
        builder.dnsHosts = hosts

        let data = try builder.makeConfigData(server: server, anti: anti)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loader-xray-\(UUID().uuidString).json")
        try data.write(to: url, options: [.atomic])
        configURL = url

        // Validate the config with the real engine before launching, so a bad
        // profile fails with a clear message instead of a crash loop. The
        // validation outcome is fully determined by the server+profile shape
        // (ports and the resolved IP never decide it), so a shape that
        // already passed this session skips the re-spawn — reconnects and
        // manual re-connects to the same server stop paying a fresh
        // `xray run -test` process (~70 ms + ~29 MB churn each time).
        let key = validationKey(server: server, anti: anti)
        if !validatedKeys.contains(key) {
            let binaryPath = binary.path
            let check = await Task.detached(priority: .userInitiated) {
                Self.validateConfig(binaryPath: binaryPath, configPath: url.path)
            }.value
            if !check.ok {
                cleanupConfig()
                throw XrayError.failedToStart(check.message)
            }
            validatedKeys.insert(key)
        }
        // The awaited validation (up to 15 s) is the wide cancellation
        // window: bailing here instead of spawning leaves no orphan.
        if Task.isCancelled || stopRequested {
            cleanupConfig()
            throw XrayError.cancelled
        }

        let proc = Process()
        proc.executableURL = binary
        proc.arguments = ["run", "-c", url.path]
        proc.qualityOfService = .userInitiated

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = outPipe
        pipe = outPipe

        // Buffer per run: xray writes in arbitrary chunks, so a naive
        // split-on-newline would emit partial lines whenever a read boundary
        // lands mid-line. The handler is serialized per handle, making plain
        // buffered mutation safe here.
        let lineBuffer = LogLineBuffer()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self, lineBuffer] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                // EOF: the engine closed its output (clean exit or crash).
                // readabilityHandler keeps firing on a readable-but-empty
                // handle — without clearing it here the block busy-spins
                // until the termination handler runs. Self-clear on EOF.
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
                // Only tear down state if THIS run is still current. A stale
                // handler (fired after a quick stop/start cycle) must not wipe
                // the new process or delete the new run's config file.
                guard self.process === p else { return }
                self.pipe?.fileHandleForReading.readabilityHandler = nil
                self.pipe = nil
                self.process = nil
                self.runToken = nil
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
        // stop() may have landed while the spawn was still in flight (before
        // the process was registered): honor it now instead of leaving the
        // engine this start just spawned running orphaned.
        if Task.isCancelled || stopRequested {
            stop()
            throw XrayError.cancelled
        }

        // Readiness gate: a successful spawn only means exec worked. Wait until
        // the SOCKS inbound actually accepts connections — otherwise connect()
        // would report "connected" on top of a crashed engine, and the helper
        // would tunnel into a dead upstream. Polls off-actor, max 5s.
        let ready = await Task.detached(priority: .userInitiated) { [socks] in
            Self.waitForPort(socks, timeout: 5)
        }.value
        // Both conditions must hold: `canConnect` alone could be answered by a
        // squatter that grabbed the port between PortFinder.pick and launch
        // (TOCTOU) while our engine was already dead.
        guard ready, process?.isRunning == true else {
            let alive = process?.isRunning ?? false
            let reason = alive
                ? "engine did not open SOCKS port \(socks) in time"
                : (logTail.last ?? "engine exited during startup")
            stop()  // nils process first, so the termination handler stays inert
            throw XrayError.failedToStart(reason)
        }
        runToken = UUID()
    }

    func stop() {
        guard let proc = process else {
            // A start is still in flight: it checks this flag after each
            // suspension and cleans up after itself — a plain no-op here
            // would let it spawn an orphaned engine.
            if starting { stopRequested = true }
            return
        }
        // Clean up synchronously: the termination handler will see a
        // mismatched/stale process and skip its cleanup (see start()).
        pipe?.fileHandleForReading.readabilityHandler = nil
        pipe = nil
        process = nil
        runToken = nil
        if proc.isRunning {
            proc.terminate()
            // xray can ignore SIGTERM while wedged in teardown (busy API
            // handler, blocked stats flush) — then stop() would return while
            // the engine keeps holding the freshly picked ports and the next
            // start squats or fails. Escalate to SIGKILL after a short grace
            // period, mirroring runCapturing's ladder but off-actor: stop()
            // must return immediately.
            Task.detached(priority: .utility) { [proc] in
                let deadline = Date().addingTimeInterval(2)
                while proc.isRunning && Date() < deadline {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                if proc.isRunning, Self.pidStillIs(proc) { kill(proc.processIdentifier, SIGKILL) }
            }
        }
        cleanupConfig()
    }

    /// Stop the engine only if it is still the run `token` identifies. A
    /// superseded connect tears down its orphan this way: if the successor
    /// has already stopped that engine and started its own, the token no
    /// longer matches and the successor's engine is untouched.
    func stop(ifRunning token: UUID) {
        guard runToken == token else { return }
        stop()
    }

    private func cleanupConfig() {
        if let url = configURL { try? FileManager.default.removeItem(at: url) }
        configURL = nil
    }

    /// Poll until 127.0.0.1:`port` accepts TCP connections or the deadline
    /// passes. Blocking sync function — Thread.sleep is banned directly inside
    /// async closures, hence the helper. Call via a detached task.
    nonisolated private static func waitForPort(_ port: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if PortFinder.canConnect(port) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    /// Re-verify a child's identity right before a SIGKILL. Foundation reaps
    /// children on its own dispatch source, so between the `isRunning` check
    /// and the kill the pid can be freed and recycled by an unrelated process
    /// — an unguarded `kill(pid, SIGKILL)` would land on the innocent new
    /// owner. proc_pidpath is the same re-verification the helper's
    /// stale-engine sweep does; if the child already exited, proc_pidpath
    /// finds nothing and no signal is sent at all.
    nonisolated private static func pidStillIs(_ proc: Process) -> Bool {
        var buf = [CChar](repeating: 0, count: 1024)   // PROC_PIDPATHINFO_MAXSIZE
        let n = proc_pidpath(proc.processIdentifier, &buf, UInt32(buf.count))
        guard n > 0 else { return false }
        return String(decoding: buf.prefix(Int(n)).map(UInt8.init), as: UTF8.self) == proc.executableURL?.path
    }

    /// Run `xray -test` on a config file. Returns success and, on failure, the
    /// most relevant error line. Bounded by a timeout: a hung validator used to
    /// block this detached task forever. Nonisolated: the class is @MainActor,
    /// but this must be callable from any executor.
    nonisolated private static func validateConfig(binaryPath: String, configPath: String) -> (ok: Bool, message: String) {
        guard let result = runCapturing(binaryPath: binaryPath,
                                        arguments: ["run", "-c", configPath, "-test"],
                                        qos: .userInitiated,
                                        timeout: 15) else {
            return (false, "config validation timed out or failed to spawn")
        }
        if result.status == 0 { return (true, "") }
        let lines = result.output.split(separator: "\n").map(String.init)
        let msg = lines.last { $0.contains("failed") || $0.contains("invalid") } ?? lines.last ?? "config invalid"
        return (false, msg.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Spawn a short-lived xray subprocess, capture its stdout (merging stderr
    /// unless told otherwise) and bound the whole run by `timeout`. On timeout
    /// the child is SIGTERMed (SIGKILL as a fallback) and nil is returned, so
    /// hung children never stack up — the stats poller spawns one every 2s.
    /// Blocking by design: call from a detached task.
    nonisolated static func runCapturing(
        binaryPath: String,
        arguments: [String],
        qos: QualityOfService,
        timeout: TimeInterval,
        mergeStderr: Bool = true
    ) -> (status: Int32, output: String)? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = arguments
        proc.qualityOfService = qos

        let box = OutputBox()
        let out = Pipe()
        proc.standardOutput = out
        // nullDevice, not a bare Pipe: an undrained stderr pipe fills its 64 KB
        // kernel buffer and the child blocks on write forever — every stats
        // poll would then pay the full 6 s timeout while SIGTERMping it.
        proc.standardError = mergeStderr ? out : FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                // EOF: clear the handler instead of letting readability fire
                // on a readable-but-empty handle until the wait path clears
                // it — the same self-clear the engine pipe got.
                handle.readabilityHandler = nil
                return
            }
            box.append(chunk)
        }

        do { try proc.run() } catch { return nil }

        // Event-driven wait, not a 20 ms busy poll: the termination handler
        // signals a semaphore the moment the child exits, so the poller wakes
        // immediately instead of on the next poll tick (the stats loop calls
        // this every 2–5 s; each tick used to trail the child's exit by up to
        // one sleep interval while also burning wakeups on the polling loop).
        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }
        // The `!proc.isRunning` disjunct closes the race where the child exits
        // before the handler is installed: no signal would ever arrive, and a
        // fast-exiting stats query (the common case) would be misread as a
        // timeout and discarded.
        if exited.wait(timeout: .now() + timeout) == .success || !proc.isRunning {
            proc.terminationHandler = nil
            proc.waitUntilExit()
            out.fileHandleForReading.readabilityHandler = nil
            // Drain anything written between the last callback and EOF.
            box.append(out.fileHandleForReading.readDataToEndOfFile())
            return (proc.terminationStatus,
                    String(data: box.snapshot(), encoding: .utf8) ?? "")
        }
        // Timeout: bounded SIGTERM→SIGKILL ladder — a child that ignores
        // SIGTERM must not wedge the poll cycle forever.
        proc.terminationHandler = nil
        if proc.isRunning { proc.terminate() }
        if exited.wait(timeout: .now() + 1) != .success, proc.isRunning, Self.pidStillIs(proc) {
            kill(proc.processIdentifier, SIGKILL)
        }
        proc.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        return nil
    }
}

/// One-shot continuation box for `withTimeout`: whichever of {operation,
/// deadline} completes first resumes the continuation; the loser is ignored.
/// `CheckedContinuation` traps on a double resume, so the latch is load-bearing
/// (same contract as HelperClient.BoundedReply).
private final class TimeoutRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Never>?
    private let fallback: T

    init(_ cont: CheckedContinuation<T, Never>, fallback: T) {
        self.cont = cont
        self.fallback = fallback
    }

    func finish(_ value: T) {
        lock.lock()
        guard let c = cont else { lock.unlock(); return }
        cont = nil
        lock.unlock()
        c.resume(returning: value)
    }

    /// Deadline path — deliver the fallback if the operation hasn't yet.
    func expire() { finish(fallback) }
}

/// Thread-safe accumulator for subprocess output (readability callbacks arrive
/// on a private queue; drains happen after waitUntilExit).
private final class OutputBox: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

/// Reassembles newline-terminated log lines from arbitrarily-chunked pipe
/// reads. `readabilityHandler` is invoked serially per handle, and each engine
/// run owns its own buffer, so no locking is needed.
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

/// Cumulative proxy traffic counters (bytes) from Xray's Stats API. Runnable
/// off the main actor. Native-first: a single gRPC-over-h2c connection to the
/// API port — the old path forked the whole engine binary per poll cycle
/// (~28 MB RSS churn per sample, every 2–10 s). Falls back to the
/// `xray api statsquery` CLI, bounded by a timeout, when the native RPC
/// doesn't complete — a hung CLI used to wedge one detached task per cycle.
func queryXrayTraffic(binaryPath: String, apiPort: Int) -> (up: Int64, down: Int64)? {
    // Narrow pattern keeps the response tiny and the RPC fast.
    if let stats = XrayStatsAPI.query(port: UInt16(apiPort), pattern: "outbound>>>proxy>>>") {
        var up: Int64 = 0, down: Int64 = 0
        for s in stats where s.name == "outbound>>>proxy>>>traffic>>>uplink" { up = s.value }
        for s in stats where s.name == "outbound>>>proxy>>>traffic>>>downlink" { down = s.value }
        return (up, down)
    }

    guard let result = XrayController.runCapturing(
        binaryPath: binaryPath,
        arguments: ["api", "statsquery", "--server=127.0.0.1:\(apiPort)"],
        qos: .background,
        timeout: 6,
        mergeStderr: false
    ), result.status == 0,
          let data = result.output.data(using: .utf8),
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
