import Foundation
import LoaderShared
import os

/// Entry point for the privileged helper daemon. Advertises the XPC mach
/// service and serves a single shared ``HelperService`` to connecting clients.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let service: HelperService
    /// Every live app connection, tracked so "no client left" can be detected.
    /// The app is the ONLY XPC client; when its connection invalidates and none
    /// remains, the tunnel's reason for existing is gone. Guarded on the
    /// delegate's own lock — the handlers fire on libxpc queues.
    private let lock = NSLock()
    private var clients = Set<NSXPCConnection>()
    private var orphanTeardownTask: DispatchWorkItem?

    init(service: HelperService) {
        self.service = service
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        // Only the genuine signed Loader app may drive the helper.
        guard ClientVerifier.isValid(conn) else {
            FileHandle.standardError.write(Data("[helper] rejected unverified client\n".utf8))
            return false
        }
        ClientVerifier.enforce(on: conn)
        conn.exportedInterface = NSXPCInterface(with: LoaderHelperProtocol.self)
        conn.exportedObject = service
        // SIGKILL'd / crashed app: the connection goes invalid with no word
        // from the app side. Without this watch the helper keeps the routes,
        // the kill switch and the DNS override armed against an upstream that
        // lives in a dead process. Wait out a grace window (the app reconnects
        // across hiccups), then tear down if no client returned.
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
        guard clients.isEmpty, orphanTeardownTask == nil else { lock.unlock(); return }
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.orphanTeardownTask = nil
            let stillEmpty = self.clients.isEmpty
            self.lock.unlock()
            if stillEmpty {
                // Hop onto the service's state queue — tearDown's state is
                // guarded by it, and this timer fires on the main queue.
                self.service.tearDownAsync()
                FileHandle.standardError.write(Data("[helper] client gone — tunnel torn down\n".utf8))
            }
        }
        orphanTeardownTask = task
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: task)
    }
}

let arguments = CommandLine.arguments

if arguments.contains("--version") {
    print(LoaderHelperVersion)
    exit(0)
}

// `--restore-network [--uninstall]`: run by the installer/uninstaller (as
// root) and by the app's repair fallback. Replays the journal, flushes the
// kill switch, sweeps orphans and dead pins, prints a report, exits. Never
// hangs an admin script: a hard deadline ends the process.
if arguments.contains("--restore-network") {
    DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
        FileHandle.standardError.write(Data("[helper] restore timed out\n".utf8))
        _exit(2)
    }
    guard getuid() == 0 else {
        FileHandle.standardError.write(Data("--restore-network must run as root\n".utf8))
        exit(1)
    }
    let service = HelperService()
    print(service.runRestoreCLI(uninstall: arguments.contains("--uninstall")))
    exit(0)
}

// launchctl bootout / system shutdown sends SIGTERM; launchd then waits
// ExitTimeOut before SIGKILL. Handle it on a dispatch source — not in signal
// context — so the full teardown can run: DNS and proxy restored, kill switch
// flushed, bridge stopped, routes removed. Installed before the service is
// created, so a stop request during launch recovery is not lost.
signal(SIGTERM, SIG_IGN)
// Recovery runs *inside* `HelperService.init` (journal replay: networksetup,
// route, pfctl), and the service only reaches the registry after that returns.
// A `bootout` landing in that window took the `?.` path below — no service,
// nothing torn down, `exit(0)` — leaving the machine half-restored by the very
// replay it interrupted, and telling launchd the exit was clean. So an
// early request is remembered and honoured once there is something to tear
// down.
let earlyTermination = OSAllocatedUnfairLock(initialState: false)
let terminationSource = DispatchSource.makeSignalSource(
    signal: SIGTERM, queue: DispatchQueue(label: "com.loader.vpn.helper.sigterm"))
terminationSource.setEventHandler {
    guard let service = ServiceRegistry.shared.service else {
        earlyTermination.withLock { $0 = true }
        return
    }
    service.shutdownForTermination()
    exit(0)
}
terminationSource.resume()

let service = HelperService()   // replays the journal before serving anything
ServiceRegistry.shared.service = service
if earlyTermination.withLock({ $0 }) {
    service.shutdownForTermination()
    exit(0)
}
let delegate = ListenerDelegate(service: service)
let listener = NSXPCListener(machServiceName: LoaderIdentifiers.helperMachService)
listener.delegate = delegate
listener.resume()

RunLoop.current.run()
