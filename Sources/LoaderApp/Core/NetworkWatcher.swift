import AppKit
import Foundation
import Network

/// Watches the physical network for the changes a tunnel can't survive: a
/// Wi-Fi↔Ethernet swap, a link drop-and-return, or a wake from sleep.
///
/// Why app-side: the engine pins its server socket to the physical interface
/// it saw at start (`sockopt.interface`, IP_BOUND_IF), and the helper's
/// SCDynamicStore monitor only re-pins the *bypass routes* — nothing re-dials
/// the engine's connection. When the pinned link goes away the engine keeps
/// trying a dead NIC, so only a full teardown + reconnect recovers. A
/// `NWPathMonitor` also fires on wake-from-sleep reassociation, which static
/// route re-pinning does not.
///
/// Only *physical* interfaces count. Our own utun (and any third-party VPN's)
/// changes the path too, and reacting to it would tear the tunnel down on
/// its own creation.
@MainActor
final class NetworkWatcher {
    /// Debounce window: a link flap fires several path updates in a row, and
    /// interface scans during a Wi-Fi join spam transient unsatisfied paths.
    private static let debounce: UInt64 = 1_500_000_000

    private let monitor = NWPathMonitor()
    private var wakeObserver: NSObjectProtocol?
    private let onChange: () -> Void

    /// Last observed network state, as a comparison key. Nil until the first
    /// (baseline) update lands — the baseline never fires, only changes do.
    private var lastKey: String?
    private var debounceTask: Task<Void, Never>?
    /// A wake reconnect is pending inside the debounce window. Path updates
    /// that land in the same window must MERGE with it, not replace it: an
    /// update with an *unchanged* key (the common post-wake case — the path
    /// looks satisfied again) used to cancel the wake task outright, losing
    /// the reconnect and leaving a dead tunnel for the watchdog's 25 s.
    private var pendingWake = false

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let key = Self.key(for: path)
            Task { @MainActor [weak self] in self?.schedule(key: key) }
        }
        monitor.start(queue: DispatchQueue(label: "loader.network-watcher"))

        // Wake from sleep: the path often stays "satisfied" across sleep from
        // NWPathMonitor's point of view (same interface, same network), but
        // long-lived TCP through the tunnel is dead and NAT mappings expired.
        // Fires on its own WITHOUT updating lastKey — the path monitor then
        // revalidates after wake, and that update must compare against the
        // PRE-sleep key: an unchanged interface would otherwise fire a second
        // reconnect right behind this one.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.fireOnWake() }
        }
    }

    func stop() {
        monitor.cancel()
        debounceTask?.cancel()
        debounceTask = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    // MARK: - Change detection

    /// Collapse a path into a comparison key: the name of the first physical
    /// interface when satisfied, "down" when not. A Wi-Fi↔Ethernet swap
    /// changes the key; flapping radio noise debounces into one.
    nonisolated private static func key(for path: NWPath) -> String {
        guard path.status == .satisfied else { return "down" }
        let physical = path.availableInterfaces.first { iface in
            iface.type == .wifi || iface.type == .wiredEthernet || iface.type == .cellular
        }
        // Tunnel-only satisfaction (utun present, physical link down) reads
        // as down: nothing to reconnect onto yet.
        return physical?.name ?? "down"
    }

    private func schedule(key: String) {
        debounceTask?.cancel()
        let wasWakePending = pendingWake
        let last = lastKey
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounce)
            guard let self, !Task.isCancelled else { return }
            self.pendingWake = false
            if wasWakePending {
                // A wake reconnect was swallowed by this update's cancel —
                // fire it now, merged with this path change. `lastKey` moves
                // to the current key: the reconnect just landed on it, so a
                // later identical update must not re-fire.
                self.lastKey = key
                self.onChange()
                return
            }
            self.lastKey = key
            // The first update after start() is the baseline, not a change.
            guard let last, last != key else { return }
            self.onChange()
        }
    }

    /// Wake-from-sleep path: reconnect unconditionally (sleep killed the
    /// engine's sockets regardless of the path looking unchanged) but leave
    /// `lastKey` alone, so the path revalidation that follows wake compares
    /// against the pre-sleep key instead of double-firing. See start().
    private func fireOnWake() {
        debounceTask?.cancel()
        pendingWake = true
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounce)
            guard let self, !Task.isCancelled else { return }
            self.pendingWake = false
            self.onChange()
        }
    }
}