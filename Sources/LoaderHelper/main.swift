import Foundation
import LoaderShared

/// Entry point for the privileged helper daemon. Advertises the XPC mach
/// service and serves a single shared ``HelperService`` to connecting clients.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let service = HelperService()
    /// Every live app connection, tracked so "no client left" can be detected.
    /// The app is the ONLY XPC client; when its connection invalidates and none
    /// remains, the tunnel's reason for existing is gone. Guarded on the
    /// delegate's own lock — the handlers fire on libxpc queues.
    private let lock = NSLock()
    private var clients = Set<NSXPCConnection>()
    private var orphanTeardownTask: DispatchWorkItem?

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        // Only the genuine signed Loader app may drive the helper.
        guard ClientVerifier.isValid(conn) else {
            FileHandle.standardError.write(Data("[helper] rejected unverified client\n".utf8))
            return false
        }
        conn.exportedInterface = NSXPCInterface(with: LoaderHelperProtocol.self)
        conn.exportedObject = service
        // SIGKILL'd / crashed app: the connection goes invalid with no word
        // from the app side, and the graceful shutdownForTermination restores
        // never run. Without this watch the helper keeps the /1 routes, the
        // kill switch and the DNS override armed against an upstream that
        // lives in a dead process — a machine-wide blackhole until the user
        // happens to relaunch and connect. On invalidation, wait out a grace
        // window (the app reconnects across reconnect hiccups, and a
        // mid-session invalidate/interrupt that the app immediately retries
        // must not tear its tunnel down), then tear down if no client
        // returned.
        conn.invalidationHandler = { [weak self] in
            guard let self else { return }
            self.clientInvalidated(conn)
        }
        lock.lock()
        clients.insert(conn)
        // A reconnect inside the grace window cancels the pending teardown.
        if let t = orphanTeardownTask { t.cancel(); orphanTeardownTask = nil }
        lock.unlock()
        conn.resume()
        return true
    }

    /// See the comment at the invalidation handler.
    private func clientInvalidated(_ conn: NSXPCConnection) {
        lock.lock()
        clients.remove(conn)
        let empty = clients.isEmpty
        if empty, orphanTeardownTask == nil {
            let task = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.orphanTeardownTask = nil
                let stillEmpty = self.clients.isEmpty
                self.lock.unlock()
                if stillEmpty {
                    self.service.tearDown()
                    FileHandle.standardError.write(Data("[helper] client gone — tunnel torn down\n".utf8))
                }
            }
            orphanTeardownTask = task
            lock.unlock()
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: task)
            return
        }
        lock.unlock()
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: LoaderIdentifiers.helperMachService)
listener.delegate = delegate

// launchctl bootout / kill sends SIGTERM. Default handling would leave a
// live bridge behind: tun2socks survives (re-parented to launchd) holding
// the utun and the split routes, and the next connect fails its 5 s
// interface wait — the "tunnel half-works" state (observed after a helper
// reinstall). Kill the bridge on the way down: kill() and _exit() are
// async-signal-safe, and the kernel drops interface-scoped routes with the
// utun. System DNS is restored by the app (next connect/disconnect) or the
// install script. Registered BEFORE the listener starts advertising, so
// there is no unguarded window where a SIGTERM falls back to default.
signal(SIGTERM) { _ in
    let pid = activeTun2socksPid
    if pid > 0 { kill(pid, SIGKILL) }
    _exit(0)
}

listener.resume()

RunLoop.current.run()
