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

    /// Timeout for the two start* calls. The helper's bring-up can
    /// legitimately take ~25 s+ (unbounded getaddrinfo on a wedged resolver,
    /// DoH fallback, utun wait, UAPI push, pfctl); a client timeout shorter
    /// than that reported failure while the helper went on to finish — a
    /// routed, kill-switch-armed tunnel with no health loop watching it.
    private static let startCallTimeout: TimeInterval = 45

    private func makeConnection() -> NSXPCConnection {
        if let c = connection { return c }
        let c = NSXPCConnection(machServiceName: LoaderIdentifiers.helperMachService, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: LoaderHelperProtocol.self)
        // These fire on libxpc's internal queues, not the main actor — hop
        // before touching MainActor-isolated state (a direct nil assignment
        // here is a data race against makeConnection's read/write).
        c.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        c.interruptionHandler = { @Sendable [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        c.resume()
        connection = c
        return c
    }

    private func proxy(_ onError: @escaping @Sendable (String) -> Void) -> LoaderHelperProtocol? {
        makeConnection().remoteObjectProxyWithErrorHandler { @Sendable err in
            onError(err.localizedDescription)
        } as? LoaderHelperProtocol
    }

    /// Whether the helper responds to a version ping (i.e. is installed + valid).
    func isInstalledAndCurrent() async -> Bool {
        await version() == LoaderHelperVersion
    }

    func version() async -> String? {
        await withBoundedContinuation(timeout: 10, fallback: nil) { reply in
            guard let helper = self.proxy({ _ in reply.finish(nil) }) else {
                reply.finish(nil); return
            }
            helper.getVersion { v in reply.finish(v) }
        }
    }

    func startTunnel(socksPort: Int, serverAddress: String, killSwitch: Bool) async -> (ok: Bool, error: String?) {
        await withBoundedContinuation(timeout: Self.startCallTimeout, fallback: (false, "helper timeout")) { reply in
            guard let helper = self.proxy({ e in reply.finish((false, e)) }) else {
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
            guard let helper = self.proxy({ e in reply.finish((false, e)) }) else {
                reply.finish((false, "Helper not installed")); return
            }
            helper.stopTunnel { ok, err in reply.finish((ok, err)) }
        }
    }

    /// WireGuard-family tunnel: the helper spawns the amneziawg-go engine,
    /// pushes `configScript` into its UAPI socket, and arms routing/kill
    /// switch — see the XPC contract. Requires helper ≥ 0.7.0.
    func startAWGTunnel(
        enginePath: String,
        configScript: String,
        serverAddress: String,
        killSwitch: Bool,
        mtu: Int
    ) async -> (ok: Bool, error: String?) {
        await withBoundedContinuation(timeout: Self.startCallTimeout, fallback: (false, "helper timeout")) { reply in
            guard let helper = self.proxy({ e in reply.finish((false, e)) }) else {
                reply.finish((false, "Helper not installed")); return
            }
            helper.startAWGTunnel(
                enginePath: enginePath,
                interfaceName: LoaderIdentifiers.defaultAWGInterfaceName,
                configScript: configScript,
                tunAddress: LoaderIdentifiers.defaultAWGTunAddress,
                tunGateway: LoaderIdentifiers.defaultAWGTunGateway,
                mtu: mtu,
                serverAddress: serverAddress,
                killSwitch: killSwitch
            ) { ok, err in reply.finish((ok, err)) }
        }
    }

    /// Point the system resolver at an explicit server (a WireGuard profile's
    /// own DNS, or the tunnel gateway for xray sessions).
    func setSystemDNS(server: String) async -> (ok: Bool, error: String?) {
        await withBoundedContinuation(timeout: Self.callTimeout, fallback: (false, "helper timeout")) { reply in
            guard let helper = self.proxy({ e in reply.finish((false, e)) }) else {
                reply.finish((false, "Helper not installed")); return
            }
            helper.setSystemDNS(server: server) { ok, err in reply.finish((ok, err)) }
        }
    }

    func setSystemProxy(port: Int) async -> (ok: Bool, error: String?) {
        await withBoundedContinuation(timeout: Self.callTimeout, fallback: (false, "helper timeout")) { reply in
            guard let helper = self.proxy({ e in reply.finish((false, e)) }) else {
                reply.finish((false, "Helper not installed")); return
            }
            helper.setSystemProxy(host: "127.0.0.1", port: port) { ok, err in reply.finish((ok, err)) }
        }
    }

    func clearSystemProxy() async -> (ok: Bool, error: String?) {
        await withBoundedContinuation(timeout: Self.callTimeout, fallback: (false, "helper timeout")) { reply in
            guard let helper = self.proxy({ e in reply.finish((false, e)) }) else {
                reply.finish((false, "Helper not installed")); return
            }
            helper.clearSystemProxy { ok, err in reply.finish((ok, err)) }
        }
    }

    /// Point the system resolver at the tunnel gateway (anti-DNS-poison).
    func setSystemDNS() async -> (ok: Bool, error: String?) {
        await withBoundedContinuation(timeout: Self.callTimeout, fallback: (false, "helper timeout")) { reply in
            guard let helper = self.proxy({ e in reply.finish((false, e)) }) else {
                reply.finish((false, "Helper not installed")); return
            }
            helper.setSystemDNS(server: LoaderIdentifiers.defaultTunGateway) { ok, err in reply.finish((ok, err)) }
        }
    }

    func clearSystemDNS() async -> (ok: Bool, error: String?) {
        await withBoundedContinuation(timeout: Self.callTimeout, fallback: (false, "helper timeout")) { reply in
            guard let helper = self.proxy({ e in reply.finish((false, e)) }) else {
                reply.finish((false, "Helper not installed")); return
            }
            helper.clearSystemDNS { ok, err in reply.finish((ok, err)) }
        }
    }

    /// Explicit "is the tunnel really up" probe for the health loop. Fallback
    /// is `true` on purpose: an unreachable/erroring helper must not, by
    /// itself, trigger reconnects — only an explicit "down" answer does.
    func isTunnelUp() async -> Bool {
        await withBoundedContinuation(timeout: 10, fallback: true) { reply in
            guard let helper = self.proxy({ _ in reply.finish(true) }) else {
                reply.finish(true); return
            }
            helper.tunnelStatus { up in reply.finish(up) }
        }
    }

    func invalidate() {
        connection?.invalidate()
        connection = nil
    }

    // MARK: Synchronous restores on the CACHED connection (app termination)

    // applicationWillTerminate can't await, so these block on a semaphore —
    // but unlike the *Blocking(static) variants below they run over the
    // instance's long-lived connection, which makes ordering with any XPC
    // already in flight guaranteed (per-connection FIFO): a connect's
    // setSystemDNS sent before the quit is processed by the helper BEFORE
    // the quit's clear, never after it. The static variants race exactly
    // that way — cross-connection order is unspecified — which used to let
    // an in-flight connect re-pin the resolver after the quit's restore
    // landed, leaving the machine DNS-dead with the app gone.

    /// See the comment above the group.
    func stopTunnelOnConnectionBlocking(timeout: TimeInterval = 3) {
        guard let helper = makeConnection().remoteObjectProxyWithErrorHandler({ _ in }) as? LoaderHelperProtocol
        else { return }
        let sem = DispatchSemaphore(value: 0)
        helper.stopTunnel { _, _ in sem.signal() }
        _ = sem.wait(timeout: .now() + timeout)
    }

    /// See the comment above the group.
    func clearSystemProxyOnConnectionBlocking(timeout: TimeInterval = 3) {
        guard let helper = makeConnection().remoteObjectProxyWithErrorHandler({ _ in }) as? LoaderHelperProtocol
        else { return }
        let sem = DispatchSemaphore(value: 0)
        helper.clearSystemProxy { _, _ in sem.signal() }
        _ = sem.wait(timeout: .now() + timeout)
    }

    /// See the comment above the group.
    func clearSystemDNSOnConnectionBlocking(timeout: TimeInterval = 3) {
        guard let helper = makeConnection().remoteObjectProxyWithErrorHandler({ _ in }) as? LoaderHelperProtocol
        else { return }
        let sem = DispatchSemaphore(value: 0)
        helper.clearSystemDNS { _, _ in sem.signal() }
        _ = sem.wait(timeout: .now() + timeout)
    }

    // MARK: - Bounded continuation plumbing

    /// A resume-once box for an XPC call: whichever of {reply, error handler,
    /// timeout} fires first wins; the others are ignored. Guarantees every
    /// continuation resumes exactly once, so a hung helper neither leaks the
    /// caller nor leaves it awaiting forever. Thread-safe by construction —
    /// every touch of the shared box is under `lock` — hence @unchecked Sendable.
    private final class BoundedReply<T: Sendable>: @unchecked Sendable {
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
        _ body: @escaping (BoundedReply<T>) -> Void
    ) async -> T {
        await withCheckedContinuation { cont in
            let reply = BoundedReply(cont, fallback: fallback)
            // `body` reaches MainActor-isolated state (makeConnection, the
            // connection cache). In Swift 5 mode a call chain that entered
            // from a background context can land here off-main — the runtime
            // data-race checker flagged exactly that. Route it onto the main
            // thread asynchronously: sync dispatch could deadlock when the
            // main thread itself is mid-teardown, and the continuation has
            // no ordering requirement — it completes on reply.finish.
            if Thread.isMainThread {
                body(reply)
            } else {
                DispatchQueue.main.async { body(reply) }
            }
            Task { [reply] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                reply.expire()
            }
        }
    }
}