import Foundation

public enum AsyncRace {
    /// Run every operation concurrently and return the first non-nil result,
    /// cancelling the others; nil only once all of them came back nil.
    ///
    /// The group still waits for cancelled losers to unwind, so operations
    /// must honor cancellation (URLSession requests and `Task.sleep` do).
    public static func firstNonNil<T: Sendable>(_ operations: [@Sendable () async -> T?]) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            for operation in operations {
                group.addTask { await operation() }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }

    /// Race `operation` against a deadline: its result, or `fallback` when the
    /// deadline fires first.
    ///
    /// Deliberately NOT a task group. The group body returns only after every
    /// child unwinds, and `cancelAll()` does nothing to a child parked on a
    /// continuation that bridged a completion-handler API — so a group-based
    /// race with a sleeping loser waits exactly as long as the operation, and
    /// its "timeout" bounds nothing. It bit `TunnelController.savedManager()`:
    /// the first read of a VPN configuration can wait forever on iOS's
    /// "Allow VPN configurations?" prompt, which a background launch (Siri, a
    /// widget button) has no screen to show. Here the loser keeps running on
    /// its own and its result is dropped.
    public static func withTimeout<T: Sendable>(
        seconds: TimeInterval, fallback: T,
        _ operation: @escaping @Sendable () async -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            let race = RaceBox(continuation, fallback: fallback)
            Task.detached(priority: .userInitiated) { race.finish(await operation()) }
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                race.expire()
            }
        }
    }
}

/// One-shot resumer for ``AsyncRace/withTimeout(seconds:fallback:_:)``: only
/// the first of {result, deadline} reaches the continuation.
private final class RaceBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private let fallback: T

    init(_ continuation: CheckedContinuation<T, Never>, fallback: T) {
        self.continuation = continuation
        self.fallback = fallback
    }

    func finish(_ value: T) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
    }

    func expire() { finish(fallback) }
}
