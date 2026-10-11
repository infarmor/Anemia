import Foundation
import Darwin
import LoaderCore

/// Process plumbing shared by the user-side engines (xray, hysteria): how a
/// start waits for the engine to come up, and how it learns why it didn't.

/// How a readiness wait ended.
enum EngineReadiness: Sendable {
    case ready, exited, timeout
}

enum EngineProcess {
    /// Poll until 127.0.0.1:`port` accepts TCP connections, the engine exits,
    /// or the deadline passes. A config the engine rejects or a port it can't
    /// bind kills it within ~10 ms, and that ends the wait at once instead of
    /// polling a dead port to the deadline. The first half second ticks every
    /// 5 ms — a healthy xray listens ~10 ms after launch — then relaxes to
    /// 50 ms. Blocking (Thread.sleep is banned inside async closures): call
    /// via a detached task.
    static func waitForReady(port: Int, exited: ExitLatch, timeout: TimeInterval) -> EngineReadiness {
        // Monotonic, not `Date()`: a clock stepped backwards (an NTP correction
        // after wake, a manual change) would stretch this poll by the size of
        // the step, and one stepped forwards ends it immediately — the engine
        // then reads "did not open its port in time" while it is up and
        // working. The interval is elapsed time, so uptime is the right clock.
        let start = DispatchTime.now()
        while seconds(since: start) < timeout {
            if exited.isMarked { return .exited }
            if PortFinder.canConnect(port) { return exited.isMarked ? .exited : .ready }
            Thread.sleep(forTimeInterval: seconds(since: start) < 0.5 ? 0.005 : 0.05)
        }
        return exited.isMarked ? .exited : .timeout
    }

    /// Seconds of monotonic time since `mark`.
    static func seconds(since mark: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- mark.uptimeNanoseconds) / 1_000_000_000
    }

    // MARK: - Who is this pid

    /// The executable a pid is running, as the kernel names it — fully resolved,
    /// so `/tmp/…` comes back as `/private/tmp/…` and a brew symlink as its
    /// `Cellar/…` target. Nil when the process is gone.
    nonisolated static func executablePath(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 1024)   // PROC_PIDPATHINFO_MAXSIZE
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(decoding: buf.prefix(Int(n)).map(UInt8.init), as: UTF8.self)
    }

    /// realpath(3): the same resolution the kernel applies. Falls back to the
    /// input when the path cannot be resolved, which then simply fails the
    /// comparison below rather than killing anything.
    nonisolated static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Whether `pid` still runs the executable launched at `launchPath`.
    ///
    /// Both sides have to be resolved before comparing. Measured on this Mac:
    /// launching `/tmp/linktest/bin/sleep` (a symlink) reports
    /// `/private/tmp/linktest/real/sleep`, while `executableURL.path` is the
    /// launch path and even `resolvingSymlinksInPath()` stops at `/tmp/…` — so
    /// a raw string compare is false for every symlinked or temp-dir engine,
    /// and the SIGKILL rung that checks it never fires.
    nonisolated static func pid(_ pid: pid_t, isExecutable launchPath: String) -> Bool {
        guard let live = executablePath(of: pid) else { return false }
        return live == canonical(launchPath)
    }
}

/// Set from an engine's termination handler, read by the readiness gate on
/// its own thread.
final class ExitLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false
    func mark() { lock.lock(); marked = true; lock.unlock() }
    var isMarked: Bool { lock.lock(); defer { lock.unlock() }; return marked }
}

/// Reassembles newline-terminated log lines from arbitrarily-chunked pipe
/// reads, and keeps the last few for failure reporting. Appends arrive
/// serially from the readability handler; the tail is read from the readiness
/// gate's thread, hence the lock. One buffer per run, so the reason a new
/// start failed can never be the previous run's last line.
final class LogLineBuffer: @unchecked Sendable {
    private static let tailCapacity = 20
    /// Ceiling on one unterminated line. `tailCapacity` bounds how much is
    /// *kept*, but nothing bounded what is *accumulated*: an engine that writes
    /// without ever emitting `\n` (a `\r` progress loop, or anything dumping
    /// binary on stdout) grew `pending` by one allocation per read for the
    /// whole run, and the readiness gate holds this buffer until the process
    /// is reaped.
    static let pendingCapacity = 64 * 1024
    private let lock = NSLock()
    private let eof = DispatchSemaphore(value: 0)
    private(set) var pendingCount = 0
    private var pending = Data()
    private var tail: [String] = []
    private var finished = false

    /// Append a chunk; returns any complete lines it finished (trimmed, empty
    /// lines dropped).
    func append(_ chunk: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending.append(chunk)
        var lines: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            let slice = Data(pending[..<nl])
            pending.removeSubrange(pending.startIndex...nl)
            if let line = Self.text(slice) { lines.append(line) }
        }
        if pending.count > Self.pendingCapacity {
            let fragment = Data(pending.prefix(Self.pendingCapacity))
            pending.removeAll(keepingCapacity: false)
            if let line = Self.text(fragment) { lines.append(line + " …[truncated]") }
        }
        pendingCount = pending.count
        remember(lines)
        return lines
    }

    /// EOF: keep an unterminated last line (a crash may not end with a
    /// newline) and release anyone waiting for the engine's last words.
    func finish() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        if let line = Self.text(pending) { remember([line]) }
        pending.removeAll()
        lock.unlock()
        eof.signal()
    }

    func waitForEOF(timeout: TimeInterval) {
        _ = eof.wait(timeout: .now() + timeout)
    }

    func tailLines() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return tail
    }

    private func remember(_ lines: [String]) {
        tail.append(contentsOf: lines)
        if tail.count > Self.tailCapacity { tail.removeFirst(tail.count - Self.tailCapacity) }
    }

    private static func text(_ data: Data) -> String? {
        guard let s = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}
