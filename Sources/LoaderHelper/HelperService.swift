import Foundation
import LoaderShared

/// Root-privileged implementation of ``LoaderHelperProtocol``.
///
/// Tunnel bring-up strategy (the standard tun2socks split-default approach):
///   1. Resolve the VPN server (v4 + v6) and pin bypass host routes via the
///      original gateways, so the engine's own encrypted connection to the
///      server does not re-enter the tunnel.
///   2. Start tun2socks on a fresh utun, forwarding to the local SOCKS inbound.
///   3. Configure the utun address/MTU (v4, and v6 when the host has IPv6).
///   4. Override the default route with two /1 routes via the utun (v4 and v6),
///      so both stacks are tunneled and IPv6 can't leak. Teardown just removes
///      them and the original defaults are restored automatically.
///   5. Optionally arm a pf kill switch that fails closed if the engine dies.
///
/// NOTE: This performs real privileged networking and must be exercised as root
/// (see Scripts/install-helper-dev.sh). It has not been run as root inside the
/// build environment.
final class HelperService: NSObject, LoaderHelperProtocol, @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.loader.vpn.helper.state")

    override init() {
        super.init()
        // A previous helper generation may have died with the kill switch
        // armed (pf keeps blocking after a crash). Release its stale token so
        // the relaunch restores connectivity — resilience to launchd respawns.
        KillSwitch.releaseStale()
    }

    // Active tunnel state (guarded by `queue`).
    private var tun2socks: Process?
    private var utun: String?
    private var gatewayV4: String?
    private var gatewayV6: String?
    private var bypassV4: [String] = []
    private var bypassV6: [String] = []
    private var v6Enabled = false
    private var pfToken: String?
    private var killSwitchOn = false

    // utun IPv6 address (ULA) used when tunneling IPv6.
    private let tunV6Address = "fd00:1972::1"

    // MARK: - LoaderHelperProtocol

    func getVersion(reply: @escaping (String) -> Void) {
        reply(LoaderHelperVersion)
    }

    func startTunnel(
        socksHost: String,
        socksPort: Int,
        tunAddress: String,
        tunGateway: String,
        mtu: Int,
        serverAddress: String,
        killSwitch: Bool,
        reply: @escaping (Bool, String?) -> Void
    ) {
        queue.async {
            if self.tun2socks != nil {
                reply(false, "Tunnel already active"); return
            }
            do {
                try self.bringUp(
                    socksHost: socksHost, socksPort: socksPort,
                    tunAddress: tunAddress, tunGateway: tunGateway,
                    mtu: mtu, serverAddress: serverAddress, killSwitch: killSwitch
                )
                reply(true, nil)
            } catch {
                self.tearDown()
                reply(false, (error as? TunnelError)?.message ?? error.localizedDescription)
            }
        }
    }

    func stopTunnel(reply: @escaping (Bool, String?) -> Void) {
        queue.async {
            self.tearDown()
            reply(true, nil)
        }
    }

    func uninstall(reply: @escaping (Bool) -> Void) {
        queue.async {
            self.tearDown()
            SystemCommand.run("/bin/launchctl", ["remove", LoaderIdentifiers.helperMachService])
            try? FileManager.default.removeItem(
                atPath: "/Library/PrivilegedHelperTools/\(LoaderIdentifiers.helperBundleID)")
            reply(true)
        }
    }

    // MARK: - Bring up / tear down (must run on `queue`)

    private struct TunnelError: Error { let message: String }

    private func bringUp(
        socksHost: String, socksPort: Int,
        tunAddress: String, tunGateway: String,
        mtu: Int, serverAddress: String, killSwitch: Bool
    ) throws {
        // 1. Gateways + server bypass routes (v4 and v6).
        guard let gw4 = SystemCommand.defaultGateway() else {
            throw TunnelError(message: "No default gateway found")
        }
        gatewayV4 = gw4
        gatewayV6 = SystemCommand.defaultGateway(inet6: true)

        let serverV4 = SystemCommand.resolveIPv4(serverAddress)
        let serverV6 = SystemCommand.resolveIPv6(serverAddress)
        for ip in serverV4 {
            SystemCommand.run("/sbin/route", ["-n", "add", "-host", ip, gw4])
            bypassV4.append(ip)
        }
        if let gw6 = gatewayV6 {
            for ip in serverV6 {
                SystemCommand.run("/sbin/route", ["-n", "add", "-inet6", "-host", ip, gw6])
                bypassV6.append(ip)
            }
        }

        // 2. Start tun2socks on a fresh utun.
        let name = SystemCommand.freeUtunName()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: try locateTun2socks())
        proc.arguments = [
            "-device", "tun://\(name)",
            "-proxy", "socks5://\(socksHost):\(socksPort)",
            "-loglevel", "warning"
        ]
        try proc.run()
        tun2socks = proc

        // 3. Wait for the interface, then address + MTU it.
        guard waitForInterface(name, timeout: 5.0) else {
            throw TunnelError(message: "utun \(name) did not appear")
        }
        utun = name
        SystemCommand.run("/sbin/ifconfig", [name, "inet", tunAddress, tunGateway, "up"])
        SystemCommand.run("/sbin/ifconfig", [name, "mtu", "\(mtu)"])

        // 4. Split-default routes via the utun (v4).
        let r1 = SystemCommand.run("/sbin/route", ["-n", "add", "-net", "0.0.0.0/1", "-interface", name])
        let r2 = SystemCommand.run("/sbin/route", ["-n", "add", "-net", "128.0.0.0/1", "-interface", name])
        guard r1.ok, r2.ok else {
            throw TunnelError(message: "Failed to install default routes: \(r1.output)\(r2.output)")
        }

        // 4b. IPv6: tunnel it too (prevents v6 leaks) when the host has IPv6.
        if gatewayV6 != nil {
            SystemCommand.run("/sbin/ifconfig", [name, "inet6", tunV6Address, "prefixlen", "64"])
            let r3 = SystemCommand.run("/sbin/route", ["-n", "add", "-inet6", "-net", "::/1", "-interface", name])
            let r4 = SystemCommand.run("/sbin/route", ["-n", "add", "-inet6", "-net", "8000::/1", "-interface", name])
            v6Enabled = r3.ok && r4.ok
        }

        // 5. Kill switch (fail-closed) — armed last, after routes are in place.
        if killSwitch {
            pfToken = try? KillSwitch.enable(utun: name, serverV4: bypassV4, serverV6: bypassV6)
            killSwitchOn = true
        }
    }

    private func tearDown() {
        if killSwitchOn {
            KillSwitch.disable(token: pfToken)
            killSwitchOn = false
            pfToken = nil
        }
        if let name = utun {
            SystemCommand.run("/sbin/route", ["-n", "delete", "-net", "0.0.0.0/1", "-interface", name])
            SystemCommand.run("/sbin/route", ["-n", "delete", "-net", "128.0.0.0/1", "-interface", name])
            if v6Enabled {
                SystemCommand.run("/sbin/route", ["-n", "delete", "-inet6", "-net", "::/1", "-interface", name])
                SystemCommand.run("/sbin/route", ["-n", "delete", "-inet6", "-net", "8000::/1", "-interface", name])
            }
        }
        if let gw4 = gatewayV4 {
            for ip in bypassV4 { SystemCommand.run("/sbin/route", ["-n", "delete", "-host", ip, gw4]) }
        }
        if let gw6 = gatewayV6 {
            for ip in bypassV6 { SystemCommand.run("/sbin/route", ["-n", "delete", "-inet6", "-host", ip, gw6]) }
        }
        if let proc = tun2socks, proc.isRunning {
            proc.terminate()
            // Bounded wait: SIGTERM, a short grace period, then SIGKILL —
            // so a wedged tun2socks can never hang the XPC reply (and the
            // app's UI) indefinitely.
            let deadline = Date().addingTimeInterval(3)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            proc.waitUntilExit()
        }
        tun2socks = nil
        utun = nil
        gatewayV4 = nil
        gatewayV6 = nil
        bypassV4 = []
        bypassV6 = []
        v6Enabled = false
    }

    // MARK: - Helpers

    private func waitForInterface(_ name: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if SystemCommand.interfaceExists(name) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    /// Locate tun2socks from a trusted location (never a client-supplied path).
    private func locateTun2socks() throws -> String {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["LOADER_TUN2SOCKS_PATH"],
           fm.isExecutableFile(atPath: env) { return env }
        let selfDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let sibling = selfDir.appendingPathComponent("tun2socks").path
        if fm.isExecutableFile(atPath: sibling) { return sibling }
        let installed = "/Library/PrivilegedHelperTools/tun2socks"
        if fm.isExecutableFile(atPath: installed) { return installed }
        throw TunnelError(message: "tun2socks binary not found")
    }
}
