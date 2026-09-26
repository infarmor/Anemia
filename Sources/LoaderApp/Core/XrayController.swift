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
    /// Last-known IPv4 per server domain. Mid-session reconnects happen
    /// while the system resolver is pointed at the (dying) tunnel, where a
    /// fresh lookup of the server's own domain can loop; the cache pins the
    /// hosts entry anyway.
    private var resolvedServerIPs: [String: String] = [:]
    /// Race an async operation against a deadline; deliver its result, or
    /// `fallback` if the deadline wins. Implemented as two unstructured tasks
    /// resuming a one-shot continuation — NOT withTaskGroup: the group body
    /// implicitly waits for every child, and a child blocked on
    /// `await someUnstructuredTask.value` (getaddrinfo) ignores
    /// `cancelAll()`, so a group-based race returned only when the *loser*
    /// finally finished, i.e. the deadline never bounded the wait. Here the
    /// losing operation keeps running on its own thread and its result is
    /// simply discarded once the deadline fires.
    nonisolated static func withTimeout<T: Sendable>(
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
    /// Split-tunnel destinations for the next start (see XrayConfigBuilder.bypass).
    var bypass: [BypassEntry] {
        get { builder.bypass }
        set { builder.bypass = newValue }
    }
    /// Block ads for the next start: the engine's DNS (which answers every
    /// lookup under the system tunnel) asks AdGuard DNS, through the proxy.
    var adBlock = false
    private static let defaultRemoteDNS = XrayConfigBuilder().remoteDNS

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
    /// Async: resolution, the interface scan and the readiness wait all run off
    /// the main actor, so the UI never freezes while the engine comes up.
    func start(server: ProxyServer, anti: AntiCensorshipOptions) async throws {
        guard !isRunning, !starting else { throw XrayError.alreadyRunning }
        starting = true
        stopRequested = false
        defer { starting = false }
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
        // AdGuard's DoH host is pinned like the server: reaching it must not
        // take a lookup of its own.
        builder.remoteDNS = adBlock ? AdBlockDNS.remoteDNS : Self.defaultRemoteDNS
        if adBlock { hosts[AdBlockDNS.dohHost] = AdBlockDNS.servers[0] }
        builder.dnsHosts = hosts
        onLog?("engine: server dial \(builder.dialerInterface.map { "bound to \($0)" } ?? "not bound to a physical interface"), \(hosts.isEmpty ? "server name left to the system resolver" : "server name pinned")")

        let data = try builder.makeConfigData(server: server, anti: anti)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loader-xray-\(UUID().uuidString).json")
        try data.write(to: url, options: [.atomic])
        configURL = url

        // No separate `xray run -test` pass. `run` loads the config through the
        // same code path and exits ~10 ms after launch with the identical
        // message, which the readiness gate below reports directly — the
        // pre-check only added a whole engine spawn in front of every server
        // shape the session hadn't dialed yet.
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
        // lands mid-line. Per run, too, so the reason a NEW start failed can
        // never be the PREVIOUS run's last line. The buffer keeps the recent
        // tail readable off the main actor: the readiness gate needs the
        // engine's last words the moment it dies, before any actor hop lands.
        let lineBuffer = LogLineBuffer()
        let exited = ExitLatch()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self, lineBuffer] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                // EOF: the engine closed its output (clean exit or crash).
                // readabilityHandler keeps firing on a readable-but-empty
                // handle — without clearing it here the block busy-spins
                // until the termination handler runs. Self-clear on EOF.
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
            // Synchronously, before the main-actor hop: the readiness gate
            // polls the latch from its own thread.
            exited.mark()
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
                // While a start is still in flight, the readiness gate owns this
                // failure: it checks `process?.isRunning` and throws a clean
                // failedToStart that connect() reports (or feeds into the
                // recovery ladder exactly once). Firing onExit here as well made
                // the outcome depend on main-actor resume order — when the exit
                // handler won, attemptReconnect ran first, the generation moved
                // on, and connect()'s own catch silently swallowed the error,
                // trading a clear "Failed to start Xray" for a surprise
                // 8-attempt reconnect ladder. (A start that already succeeded
                // has `starting == false` by the time the engine can exit.)
                if !self.starting {
                    self.onExit?(status)
                }
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
        // the SOCKS inbound accepts connections — otherwise connect() would
        // report "connected" on top of a crashed engine, and the helper would
        // tunnel into a dead upstream — or until the engine dies (see
        // EngineProcess.waitForReady). Off-actor.
        let outcome = await Task.detached(priority: .userInitiated) { [socks, exited] in
            EngineProcess.waitForReady(port: socks, exited: exited, timeout: 5)
        }.value
        // Both conditions must hold: `canConnect` alone could be answered by a
        // squatter that grabbed the port between PortFinder.pick and launch
        // (TOCTOU) while our engine was already dead.
        guard outcome == .ready, process?.isRunning == true else {
            let reason: String
            if outcome == .timeout, process?.isRunning == true {
                reason = "engine did not open SOCKS port \(socks) in time"
            } else {
                // The engine's last words explain the death; EOF on its pipe
                // trails the exit by a few ms, so give the tail a moment.
                let lines = await Task.detached(priority: .userInitiated) { [lineBuffer] in
                    lineBuffer.waitForEOF(timeout: 0.3)
                    return lineBuffer.tailLines()
                }.value
                reason = EngineLog.failureReason(from: lines)
            }
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
