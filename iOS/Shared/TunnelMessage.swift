import Foundation
import LoaderCore

// The app and the tunnel extension share no App Group on purpose: GBox
// re-signs with the certificate's own group IDs. The app hands the server over
// inside the VPN configuration and asks the running extension for its state
// through NETunnelProviderSession.sendProviderMessage.

/// What the tunnel should run. Stored in the VPN configuration
/// (`providerConfiguration`), so the extension can also start on its own —
/// from Settings → VPN, or on demand after a network change.
struct TunnelSetup: Codable {
    var server: ProxyServer
    var masking: MaskingProfile
    /// Destinations that go around the VPN. Optional: configurations saved
    /// before split tunneling existed decode without it.
    var splitTunnel: SplitTunnelRules?
    /// Resolve through AdGuard DNS, which answers ad and tracker domains
    /// with nothing. Optional for the same reason.
    var adBlock: Bool?

    private static let key = "setup"

    init(server: ProxyServer, masking: MaskingProfile, splitTunnel: SplitTunnelRules?, adBlock: Bool) {
        self.server = server
        self.masking = masking
        self.splitTunnel = splitTunnel
        self.adBlock = adBlock
    }

    init?(providerConfiguration: [String: Any]?) {
        guard let data = providerConfiguration?[Self.key] as? Data,
              let setup = try? JSONDecoder().decode(Self.self, from: data)
        else { return nil }
        self = setup
    }

    var providerConfiguration: [String: Any] {
        [Self.key: (try? JSONEncoder().encode(self)) ?? Data()]
    }
}

/// A request from the app to the running tunnel.
struct TunnelRequest: Codable {
    enum Command: String, Codable {
        case status
        /// The tail of the engine log.
        case log
        /// Latency to `targets`, measured from the extension: its sockets skip
        /// the tunnel, the app's would ride it.
        case ping
        /// A real request through each of `probes` (EngineProbe).
        case probe
        /// The address the provider gave, seen from outside the tunnel
        /// (LeakCheck.IPInfo) — what the tunnel hides.
        case directAddress
    }

    var command: Command
    var targets: [PingTarget]?
    var probes: [EngineProbe.Item]?
    /// With `.status`: keep checking that the tunnel carries traffic
    /// (auto-switching is on). The checks cost a little traffic, so they run
    /// only while asked for.
    var wantsHealth: Bool?

    init(command: Command, targets: [PingTarget]? = nil, probes: [EngineProbe.Item]? = nil, wantsHealth: Bool? = nil) {
        self.command = command
        self.targets = targets
        self.probes = probes
        self.wantsHealth = wantsHealth
    }
}

/// The tunnel's answer to `.status`.
struct TunnelReport: Codable, Equatable {
    /// "xray" or "awg"; empty while starting or after a failed start.
    var engine: String
    var serverName: String
    var startedAt: Date
    var uploaded: Int64
    var downloaded: Int64
    /// AmneziaWG's latest handshake; nil before the first one and for Xray.
    var lastHandshake: Date?
    /// Round trip to the server in ms, measured by the extension every 30 s
    /// while the app is watching (the same probe as the server list). Nil
    /// before the first answer or when the server doesn't answer.
    var latency: Int?
    /// The last real check of the tunnel (a request through it): ms, or -1
    /// when it failed. Nil before the first check.
    var health: Int?
    /// Failed checks in a row — what auto-switching watches.
    var healthFailures: Int?
    /// Memory the extension uses (phys_footprint), bytes.
    var footprint: UInt64
    /// Headroom before iOS kills the extension, bytes.
    var available: UInt64
    var engineVersion: String
    /// Why the start failed. The extension keeps it for a moment before
    /// giving up, so the app can show it — iOS doesn't pass it on.
    var error: String?
    /// Wi‑Fi or mobile data under the tunnel. The app can't tell by itself
    /// while its own traffic rides the tunnel.
    var network: NetworkKind?
}

/// The tunnel's answer to `.log`.
struct TunnelLog: Codable {
    var text: String
}
