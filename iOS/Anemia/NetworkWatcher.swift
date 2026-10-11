import Foundation
import LoaderCore
import Network
import Observation

/// Wi‑Fi or mobile data — what learned masking is kept per. While the tunnel
/// is down the app's own path says; while it runs, the app's traffic goes
/// into the tunnel, so the extension (whose sockets don't) reports it.
@MainActor
@Observable
final class NetworkWatcher {
    private(set) var kind: NetworkKind?

    /// Called when the device moves to the other kind of network.
    @ObservationIgnored var onChange: ((NetworkKind) -> Void)?

    @ObservationIgnored private var local: NetworkKind?
    @ObservationIgnored private var fromTunnel: NetworkKind?
    @ObservationIgnored private var lastKnown: NetworkKind?
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let kind = Self.kind(of: path)
            Task { @MainActor in
                self?.local = kind
                self?.update()
            }
        }
        monitor.start(queue: DispatchQueue(label: "Anemia.network"))
    }

    /// With every tunnel report; nil once the tunnel is down.
    func tunnelReported(_ kind: NetworkKind?) {
        guard fromTunnel != kind else { return }
        fromTunnel = kind
        update()
    }

    private func update() {
        let current = fromTunnel ?? local
        guard current != kind else { return }
        kind = current
        // A moment without any network in between is no change; neither is
        // the first answer after launch.
        guard let current else { return }
        defer { lastKnown = current }
        if let lastKnown, lastKnown != current { onChange?(current) }
    }

    nonisolated private static func kind(of path: NWPath) -> NetworkKind? {
        guard path.status == .satisfied else { return nil }
        if path.usesInterfaceType(.cellular) { return .cellular }
        if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) { return .wifi }
        return nil
    }
}

extension NetworkKind {
    var russianTitle: String {
        switch self {
        case .wifi: "Wi‑Fi"
        case .cellular: "сотовая сеть"
        }
    }
}
