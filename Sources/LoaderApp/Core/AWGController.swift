import Foundation
import LoaderCore
import LoaderShared

/// App-side half of a WireGuard-family session. The root work — spawning
/// `amneziawg-go`, pushing the UAPI config, routing — belongs to the
/// privileged helper (the engine's UAPI socket lives under /var/run/amneziawg,
/// which only root can create). This class owns the non-root part of the
/// contract: locating the engine binary, validating the profile up front,
/// building the UAPI script, and tracking the session so superseded connects
/// can tear down exactly their own run.
///
/// The engine process itself is never visible to the app — liveness comes
/// from the helper's `tunnelStatus` (it supervises the daemon in the same
/// bridge slot as tun2socks).
@MainActor
final class AWGController {
    enum AWGError: LocalizedError {
        case binaryNotFound
        case engineNotInstalled
        case missingProfile
        case invalidConfig([String])

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "This build has no AmneziaWG engine (amneziawg-go). Build it with Scripts/fetch-extra-engines.sh, rebuild the app, then update the helper in Settings → Network."
            case .engineNotInstalled:
                return "The AmneziaWG engine is bundled but not installed for the helper yet — update the helper in Settings → Network."
            case .missingProfile:
                return "This WireGuard server carries no peer profile (server public key) — re-import the config or link."
            case .invalidConfig(let problems):
                return problems.joined(separator: "\n")
            }
        }
    }

    /// Identity of the live session, handed to the caller (the supersede
    /// check compares it like XrayController.runToken). Nil when no session.
    private(set) var runToken: UUID?
    /// The kernel-assigned utun the engine created (the helper reports it on
    /// success). Powers the netstat-based traffic counters.
    private(set) var utunName: String?

    var isSessionUp: Bool { runToken != nil }

    /// Validate the profile up front — obfuscation mistakes (overlapping
    /// header ranges, S1+56 = S2, Jmax ≥ MTU) fail *silently* on the wire
    /// (packets dropped, no log anywhere), so surface them before the helper
    /// spawns anything.
    func validate(server: ProxyServer) throws {
        guard server.wgProfile != nil, !server.credential.isEmpty else {
            throw AWGError.missingProfile
        }
        let problems = AmneziaWGConfigBuilder.validate(server: server, mtu: effectiveMTU(server: server))
        guard problems.isEmpty else { throw AWGError.invalidConfig(problems) }
    }

    /// The UAPI `set=1` script the helper pushes into the daemon.
    /// `endpoint` replaces a domain endpoint with its resolved address.
    func makeConfigScript(server: ProxyServer, endpoint: String? = nil) throws -> String {
        try AmneziaWGConfigBuilder.makeUAPISetScript(server: server, endpointAddress: endpoint)
    }

    /// Last-known address per endpoint domain. A reconnect can run while the
    /// system resolver points into the dying tunnel, where a fresh lookup of
    /// the endpoint's own name can't succeed (XrayController keeps the same
    /// cache for its server pin).
    private var resolvedEndpoints: [String: String] = [:]

    /// The endpoint as the address literal amneziawg-go requires: its UAPI
    /// parses `endpoint=` with netip.ParseAddrPort, so a domain fails the
    /// whole set. Literals pass through; a domain gets a bounded lookup with
    /// the cached answer as the fallback. Nil when it can't be resolved.
    func resolveEndpoint(_ host: String) async -> String? {
        if DirectResolver.isIPv4(host) || host.contains(":") { return host }
        let ips = await XrayController.withTimeout(seconds: 3, fallback: [String]()) {
            DirectResolver.ipv4(host)
        }
        if let ip = ips.first { resolvedEndpoints[host] = ip }
        return resolvedEndpoints[host]
    }

    /// The utun's address: the profile's own interface address — the only
    /// source the server accepts inner packets from — or the app's default
    /// range when the profile names none.
    func tunnelAddress(server: ProxyServer) -> String {
        AmneziaWGConfigBuilder.tunnelIPv4(server: server) ?? LoaderIdentifiers.defaultAWGTunAddress
    }

    /// MTU for the helper's ifconfig step (a profile's own value wins —
    /// AWG 3.1 configs usually carry MTU = 1280).
    func effectiveMTU(server: ProxyServer) -> Int {
        server.wgProfile?.mtu ?? LoaderIdentifiers.defaultAWGMTU
    }

    /// The engine the helper will run: the root-owned copy its installer puts
    /// in /Library/PrivilegedHelperTools. A bundled or Homebrew binary is
    /// never handed to the root helper (EngineBinaryPolicy refuses it), so it
    /// isn't offered here either. Nil → `engineNotInstalled` when this build
    /// bundles the engine (update the helper), else `binaryNotFound`.
    nonisolated static func resolveBinary() -> URL? {
        let installed = EngineBinaryPolicy.installedAWGEngine
        return FileManager.default.isExecutableFile(atPath: installed) ? URL(fileURLWithPath: installed) : nil
    }

    /// Whether this app build carries the engine (Contents/Resources).
    nonisolated static var isBundled: Bool {
        Bundle.main.url(forResource: "amneziawg-go", withExtension: nil) != nil
    }

    /// Register the session once the helper confirms the tunnel is up.
    func beginSession(utun: String?) {
        utunName = utun
        runToken = UUID()
    }

    func endSession() {
        runToken = nil
        utunName = nil
    }

    /// Stop the session only if it is still the run `token` identifies —
    /// the superseded-connect orphan sweep (same contract as XrayController;
    /// the actual engine stop is the helper's stopTunnel).
    func endSession(ifRunning token: UUID) {
        guard runToken == token else { return }
        endSession()
    }

    // MARK: - Traffic counters

    /// Cumulative interface byte counters for the live AWG session, via
    /// `netstat -ib` (the engine has no stats API). One subprocess per poll
    /// cycle — cheap, and the stats loop already spaces samples 2–10 s apart.
    /// Blocking: call off the main actor.
    nonisolated static func trafficCounters(interface: String) -> (up: Int64, down: Int64)? {
        guard let result = XrayController.runCapturing(
            binaryPath: "/usr/sbin/netstat",
            arguments: ["-inb"],
            qos: .background,
            timeout: 4,
            mergeStderr: false
        ) else { return nil }
        return AmneziaWGConfigBuilder.parseNetstatCounters(result.output, interface: interface)
    }
}