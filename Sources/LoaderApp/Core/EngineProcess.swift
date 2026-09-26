import Foundation
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
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        while Date() < deadline {
            if exited.isMarked { return .exited }
            if PortFinder.canConnect(port) { return exited.isMarked ? .exited : .ready }
            Thread.sleep(forTimeInterval: Date().timeIntervalSince(start) < 0.5 ? 0.005 : 0.05)
        }
        return exited.isMarked ? .exited : .timeout
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
    private let lock = NSLock()
    private let eof = DispatchSemaphore(value: 0)
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
