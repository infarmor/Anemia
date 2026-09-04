import Foundation
import LoaderShared

/// Thin async wrapper around the XPC connection to the privileged helper.
///
/// The helper owns utun creation + routing. Until it is installed (blessed via
/// SMAppService with a Developer ID signature), calls surface a clear
/// "helper not installed" error rather than crashing.
///
/// Every call is bounded by a timeout so a hung helper can never wedge the UI
/// in `.connecting` forever — the app degrades to SOCKS-only mode instead.
///
/// Main-actor isolated so the app can call it directly without crossing actor
/// boundaries. XPC replies arrive on background queues but resume the awaiting
/// continuation, which is safe from any thread.
@MainActor
final class HelperClient {
    /// How long to wait for a helper reply before giving up.
    private static let callTimeout: TimeInterval = 20

    private var connection: NSXPCConnection?

    private func makeConnection() -> NSXPCConnection {
        if let c = connection { return c }
        let c = NSXPCConnection(machServiceName: LoaderIdentifiers.helperMachService, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: LoaderHelperProtocol.self)
        c.invalidationHandler = { [weak self] in self?.connection = nil }
        c.interruptionHandler = { [weak self] in self?.connection = nil }
        c.resume()
        connection = c
        return c
    }

    private func proxy(_ onError: @escaping (String) -> Void) -> LoaderHelperProtocol? {
        makeConnection().remoteObjectProxyWithErrorHandler { err in
            onError(err.localizedDescription)
        } as? LoaderHelperProtocol
    }

    /// Whether the helper responds to a version ping (i.e. is installed + valid).
    func isInstalledAndCurrent() async -> Bool {
        await version() == LoaderHelperVersion
    }

    func version() async -> String? {
        await withBoundedContinuation(timeout: 10, fallback: nil) { reply in
            guard let helper = proxy({ _ in reply.finish(nil) }) else {
                reply.finish(nil); return
            }
            helper.getVersion { v in reply.finish(v) }
        }
    }

    func startTunnel(socksPort: Int, serverAddress: String, killSwitch: Bool) async -> (ok: Bool, error: String?) {
        await withBoundedContinuation(timeout: Self.callTimeout, fallback: (false, "helper timeout")) { reply in
            guard let helper = proxy({ e in reply.finish((false, e)) }) else {
                reply.finish((false, "Helper not installed")); return
            }
            helper.startTunnel(
                socksHost: "127.0.0.1",
                socksPort: socksPort,
                tunAddress: LoaderIdentifiers.defaultTunAddress,
                tunGateway: LoaderIdentifiers.defaultTunGateway,
                mtu: LoaderIdentifiers.defaultMTU,
                serverAddress: serverAddress,
                killSwitch: killSwitch
            ) { ok, err in reply.finish((ok, err)) }
        }
    }

    func stopTunnel() async -> (ok: Bool, error: String?) {
        await withBoundedContinuation(timeout: Self.callTimeout, fallback: (false, "helper timeout")) { reply in
            guard let helper = proxy({ e in reply.finish((false, e)) }) else {
                reply.finish((false, "Helper not installed")); return
            }
            helper.stopTunnel { ok, err in reply.finish((ok, err)) }
        }
    }

    func invalidate() {
        connection?.invalidate()
        connection = nil
    }

    // MARK: - Bounded continuation plumbing

    /// A resume-once box for an XPC call: whichever of {reply, error handler,
    /// timeout} fires first wins; the others are ignored. Guarantees every
    /// continuation resumes exactly once, so a hung helper neither leaks the
    /// caller nor leaves it awaiting forever.
    private final class BoundedReply<T: Sendable> {
        private let lock = NSLock()
        private var resumed = false
        private var cont: CheckedContinuation<T, Never>?
        private let fallback: T

        init(_ cont: CheckedContinuation<T, Never>, fallback: T) {
            self.cont = cont
            self.fallback = fallback
        }

        /// Deliver a value (first call wins).
        func finish(_ value: T) {
            lock.lock()
            guard !resumed, let c = cont else { lock.unlock(); return }
            resumed = true
            cont = nil
            lock.unlock()
            c.resume(returning: value)
        }

        /// Timeout path — deliver the fallback if nobody replied in time.
        func expire() { finish(fallback) }
    }

    private func withBoundedContinuation<T: Sendable>(
        timeout: TimeInterval,
        fallback: T,
        _ body: (BoundedReply<T>) -> Void
    ) async -> T {
        await withCheckedContinuation { cont in
            let reply = BoundedReply(cont, fallback: fallback)
            body(reply)
            Task { [reply] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                reply.expire()
            }
        }
    }
}