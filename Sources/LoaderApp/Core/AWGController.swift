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
        case missingProfile
        case invalidConfig([String])

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "amneziawg-go binary not found. Bundle it next to the app, install it via Homebrew, or set LOADER_AWG_PATH."
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
    func makeConfigScript(server: ProxyServer) throws -> String {
        try AmneziaWGConfigBuilder.makeUAPISetScript(server: server)
    }

    /// MTU for the helper's ifconfig step (a profile's own value wins —
    /// AWG 3.1 configs usually carry MTU = 1280).
    func effectiveMTU(server: ProxyServer) -> Int {
        server.wgProfile?.mtu ?? LoaderIdentifiers.defaultAWGMTU
    }

    /// Locate the `amneziawg-go` engine: the `LOADER_AWG_PATH` override
    /// (dev), a binary bundled next to the app, or Homebrew. Nil → the
    /// user-facing `binaryNotFound` error.
    nonisolated static func resolveBinary() -> URL? {
        let fm = FileManager.default
        if let p = ProcessInfo.processInfo.environment["LOADER_AWG_PATH"], !p.isEmpty,
           fm.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        var candidates: [URL] = []
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(exeDir.appendingPathComponent("amneziawg-go"))
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/amneziawg-go"))
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
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