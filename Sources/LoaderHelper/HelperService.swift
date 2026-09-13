import Foundation
import SystemConfiguration
import LoaderCore
import LoaderShared

/// Pid of the tun2socks bridge currently owned by the running helper, or 0
/// when no tunnel is up. Written on the service's serial queue; read by the
/// SIGTERM handler in main.swift, which may only do async-signal-safe work
/// (single-word load + kill()) so the helper's death never leaks the bridge.
/// `nonisolated(unsafe)`: the deliberate signal-handler pattern — a single
/// machine-word store/load with no lock allowed in the handler.
nonisolated(unsafe) var activeTun2socksPid: pid_t = 0

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
        // Same resilience for the DNS/SOCKS overrides: both backup files
        // persist in /var/db/Loader, and a backup file existing means the
        // previous generation set the override and never restored it (crash,
        // SIGKILL, bootout — anything that skipped tearDown). The machine is
        // then name-resolution-dead or proxy-pinned to a dead port until the
        // next app session. The restores are no-ops when no backup exists,
        // and idempotent otherwise; app-start sessions re-set their overrides
        // afterward if the tunnel comes back up.
        restoreSystemDNS()
        restoreSystemProxy()
    }

    // Active tunnel state (guarded by `queue`).
    private var tun2socks: Process?
    private var utun: String?
    private var serverAddress: String?
    private var gatewayV4: String?
    private var gatewayV6: String?
    private var bypassV4: [String] = []
    private var bypassV6: [String] = []
    private var v6Enabled = false
    private var pfToken: String?
    private var killSwitchOn = false
    /// Network services we set the SOCKS proxy on, so clearing targets the same.
    private var proxyServices: [String] = []
    /// Network services we set the DNS server on, so clearing targets the same.
    private var dnsServices: [String] = []
    /// Re-resolves the VPN server periodically while the tunnel is up: if the
    /// server's IP changes mid-session (DNS/CDN), a stale bypass route sends
    /// the engine's own connection back into the tunnel (loop) — or, with the
    /// kill switch on, into a blackhole. Guarded by `queue`.
    private var resolveTimer: DispatchSourceTimer?
    /// Watches the system's global IPv4/IPv6 config so a network change
    /// (Wi-Fi ⇄ Ethernet, new DHCP lease, tethering) is handled the instant it
    /// happens instead of up to 60 s later: a switch moves the physical default
    /// gateway, and bypass routes pinned to the *old* gateway then dump the
    /// engine's own connection back into the tunnel. Guarded by `queue`.
    private var netStore: SCDynamicStore?

    // utun IPv6 address (ULA) used when tunneling IPv6.
    private let tunV6Address = "fd00:1972::1"

    /// Root-owned state directory shared with KillSwitch. Backups of the
    /// user's pre-override DNS/proxy settings persist here so a relaunched
    /// helper (launchd respawn after a crash) can still restore them.
    private static let stateDir = "/var/db/Loader"
    private static var dnsBackupPath: String { stateDir + "/dns.backup.json" }
    private static var proxyBackupPath: String { stateDir + "/proxy.backup.json" }

    private static func readJSON(_ path: String) -> [String: [String]]? {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String]]
        else { return nil }
        return obj
    }

    private static func writeJSON(_ obj: [String: [String]], to path: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    /// Log to stderr (launchd captures it for `launchctl print`). The helper
    /// has no UI of its own; the app's log view only shows engine output.
    private func logErr(_ msg: String) {
        FileHandle.standardError.write(Data("[helper] \(msg)\n".utf8))
    }

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
            // Validate client-supplied numbers before any system call: a
            // buggy/malicious client passing mtu 0 or a port outside 1–65535
            // would otherwise flow straight into `ifconfig`/tun2socks args.
            // No shell is involved (argv passing only), so this is sanity,
            // not injection defense.
            guard (1...65535).contains(socksPort) else {
                reply(false, "invalid socksPort \(socksPort)"); return
            }
            guard (576...9000).contains(mtu) else {
                reply(false, "invalid mtu \(mtu)"); return
            }
            guard DirectResolver.isIPv4(tunAddress), DirectResolver.isIPv4(tunGateway) else {
                reply(false, "invalid tunnel addressing \(tunAddress) / \(tunGateway)"); return
            }
            guard !serverAddress.isEmpty else {
                reply(false, "empty server address"); return
            }
            // Self-healing first: a previous helper generation can die without
            // cleanup (launchctl bootout during a reinstall, kill, crash) and
            // leave its bridge orphaned — tun2socks still alive (re-parented to
            // launchd), still holding utun90, still owning the split routes.
            // The next connect then fails the 5 s interface wait and the app
            // silently falls back to SOCKS-only: the "tunnel half-works"
            // state. The sweep is idempotent and near-free when nothing is
            // stale, so run it on every startTunnel.
            self.sweepStaleTunnel()
            if self.tun2socks != nil {
                // A leftover tunnel is a dead end: its bridge points at the
                // SOCKS port of an app session that no longer exists (crash,
                // force-quit), yet the utun still owns the default route —
                // a full blackhole. Failing here (the old behavior) left that
                // stale tunnel in place while the app showed "Connected
                // (SOCKS)". Tear it down and bring the requested one up.
                self.tearDown()
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

    func setSystemProxy(host: String, port: Int, reply: @escaping (Bool, String?) -> Void) {
        queue.async {
            let services = SystemCommand.enabledNetworkServices()
            guard !services.isEmpty else { reply(false, "no active network services"); return }
            // Capture each service's own proxy state before the first
            // override, so teardown restores the user's configuration
            // (including "no proxy") instead of blindly switching off.
            if Self.readJSON(Self.proxyBackupPath) == nil {
                var prior: [String: [String]] = [:]
                for svc in services {
                    guard let p = SystemCommand.getSocksProxy(service: svc) else { continue }
                    prior[svc] = [p.enabled ? "1" : "0", p.host, p.port]
                }
                Self.writeJSON(prior, to: Self.proxyBackupPath)
            }
            var done: [String] = []
            for svc in services {
                let a = SystemCommand.run("/usr/sbin/networksetup", ["-setsocksfirewallproxy", svc, host, "\(port)"])
                let b = SystemCommand.run("/usr/sbin/networksetup", ["-setsocksfirewallproxystate", svc, "on"])
                if a.ok && b.ok { done.append(svc) }
            }
            self.proxyServices = done
            done.isEmpty ? reply(false, "failed to set proxy on any service") : reply(true, nil)
        }
    }

    func clearSystemProxy(reply: @escaping (Bool, String?) -> Void) {
        queue.async {
            self.restoreSystemProxy()
            reply(true, nil)
        }
    }

    /// Restore the SOCKS proxy state each service had before we overrode it
    /// (from the persisted backup, so a helper relaunch can still undo its
    /// predecessor's override). Without a backup we only touch the services
    /// this process set — resetting services we never configured would wipe
    /// a user's manually configured proxy. Must run on `queue`.
    private func restoreSystemProxy() {
        if let prior = Self.readJSON(Self.proxyBackupPath), !prior.isEmpty {
            for (svc, parts) in prior {
                guard parts.count == 3 else { continue }
                if parts[0] == "1", !parts[1].isEmpty, !parts[2].isEmpty {
                    SystemCommand.run("/usr/sbin/networksetup", ["-setsocksfirewallproxy", svc, parts[1], parts[2]])
                    SystemCommand.run("/usr/sbin/networksetup", ["-setsocksfirewallproxystate", svc, "on"])
                } else {
                    SystemCommand.run("/usr/sbin/networksetup", ["-setsocksfirewallproxystate", svc, "off"])
                }
            }
            try? FileManager.default.removeItem(atPath: Self.proxyBackupPath)
            proxyServices = []
            return
        }
        for svc in proxyServices {
            SystemCommand.run("/usr/sbin/networksetup", ["-setsocksfirewallproxystate", svc, "off"])
        }
        proxyServices = []
    }

    func setSystemDNS(server: String, reply: @escaping (Bool, String?) -> Void) {
        queue.async {
            let services = SystemCommand.enabledNetworkServices()
            guard !services.isEmpty else { reply(false, "no active network services"); return }
            // Capture each service's resolvers before the first override, so
            // teardown puts back exactly what was there — a user's manual
            // 1.1.1.1 / Pi-hole setup, not a silent reset to DHCP.
            if Self.readJSON(Self.dnsBackupPath) == nil {
                var prior: [String: [String]] = [:]
                for svc in services {
                    // A nil capture (transient networksetup failure) must not
                    // be recorded as "automatic (DHCP)" — restoring that
                    // would wipe the user's real resolvers. Services whose
                    // capture failed fall out of the backup entirely and
                    // restore to "empty" via this process's dnsServices
                    // list, the best available guess for a service we did
                    // override.
                    if let cur = SystemCommand.getDNSServers(service: svc) { prior[svc] = cur }
                }
                Self.writeJSON(prior, to: Self.dnsBackupPath)
            }
            var done: [String] = []
            for svc in services {
                let r = SystemCommand.run("/usr/sbin/networksetup", ["-setdnsservers", svc, server])
                if r.ok { done.append(svc) }
            }
            self.dnsServices = done
            done.isEmpty ? reply(false, "failed to set DNS on any service") : reply(true, nil)
        }
    }

    func clearSystemDNS(reply: @escaping (Bool, String?) -> Void) {
        queue.async {
            self.restoreSystemDNS()
            reply(true, nil)
        }
    }

    /// Restore each service's DNS to what it had before we overrode it (from
    /// the persisted backup, so a helper relaunch can undo its predecessor's
    /// override). Without a backup we only touch the services this process
    /// set — resetting services we never configured would silently wipe the
    /// user's manually configured resolvers. Must run on `queue`.
    private func restoreSystemDNS() {
        if let prior = Self.readJSON(Self.dnsBackupPath), !prior.isEmpty {
            for (svc, servers) in prior {
                // Empty saved list = automatic (DHCP) before we touched it.
                var args = ["-setdnsservers", svc]
                args += servers.isEmpty ? ["empty"] : servers
                SystemCommand.run("/usr/sbin/networksetup", args)
            }
            try? FileManager.default.removeItem(atPath: Self.dnsBackupPath)
            dnsServices = []
            return
        }
        for svc in dnsServices {
            SystemCommand.run("/usr/sbin/networksetup", ["-setdnsservers", svc, "empty"])
        }
        dnsServices = []
    }

    func tunnelStatus(reply: @escaping (Bool) -> Void) {
        queue.async {
            reply(self.utun != nil && (self.tun2socks?.isRunning ?? false))
        }
    }

    func uninstall(reply: @escaping (Bool) -> Void) {
        queue.async {
            self.tearDown()
            // Remove the installed artifacts: the bridge binary, the
            // LaunchDaemon plist (a dev install leaves it registered, and
            // launchd then keeps advertising a MachService whose binary is
            // gone — every later connect spawns nothing and times out), and
            // the state dir. `remove` is the legacy verb; `bootout` is the
            // correct one for a system-domain daemon.
            try? FileManager.default.removeItem(
                atPath: "/Library/PrivilegedHelperTools/\(LoaderIdentifiers.helperBundleID)")
            try? FileManager.default.removeItem(atPath: "/Library/PrivilegedHelperTools/tun2socks")
            let plistPath = "/Library/LaunchDaemons/\(LoaderIdentifiers.helperMachService).plist"
            try? FileManager.default.removeItem(atPath: plistPath)
            try? FileManager.default.removeItem(atPath: "/var/db/Loader")
            // Reply BEFORE the self-bootout: `bootout` SIGTERMs this process,
            // and the SIGTERM handler _exit(0)s — the legacy verb and the
            // XPC reply used to land after death, so the client hung on its
            // timeout and the last cleanup step never ran.
            reply(true)
            SystemCommand.run("/bin/launchctl", ["remove", LoaderIdentifiers.helperMachService])
            SystemCommand.run("/bin/launchctl", ["bootout", "system", plistPath])
        }
    }

    // MARK: - Bring up / tear down (must run on `queue`)

    private struct TunnelError: Error { let message: String }

    /// Gateways + server bypass host routes, shared by both engine paths
    /// (tun2socks bridge and the AmneziaWG daemon): the engine's own dial to
    /// the server must leave via the physical NIC, never re-enter the tunnel.
    /// Must run on `queue`.
    private func pinBypassRoutes(serverAddress: String) throws {
        guard let gw4 = SystemCommand.defaultGateway() else {
            throw TunnelError(message: "No default gateway found")
        }
        gatewayV4 = gw4
        gatewayV6 = SystemCommand.defaultGateway(inet6: true)

        // Fake-IP answers never route to the real server — a concurrently
        // running sing-box/clash client answers the system resolver from its
        // 198.18.0.0/15 pool. Filtering them here keeps the bypass routes (and
        // the kill switch allow-list) pointed at genuine addresses.
        var serverV4 = SystemCommand.resolveIPv4(serverAddress).filter { !DirectResolver.isFakeIP($0) }
        if serverV4.isEmpty {
            // getaddrinfo came up empty — most often a mid-session reconnect
            // where the system resolver is pointed at the (restarting)
            // tunnel. Fall back to a direct DoH query: encrypted, no system
            // resolver involved, and it leaves via whatever default route
            // exists (physical, or a third-party VPN's TUN).
            serverV4 = SystemCommand.resolveOverDoH(serverAddress)
        }
        let serverV6 = SystemCommand.resolveIPv6(serverAddress)
        // An unresolved hostname must fail loudly, not silently: without
        // bypass routes the engine's own dial follows the /1 routes back into
        // our utun (self-loop) — and with the kill switch on it is simply
        // dropped by `block out all`. Either way: tunnel "up", zero traffic.
        if serverV4.isEmpty && serverV6.isEmpty {
            throw TunnelError(message: "Could not resolve server address: \(serverAddress)")
        }
        // A tunnel needs at least one address family that is BOTH reachable
        // on the wire (a default gateway) and resolved for the server. An
        // IPv6-only answer with no v6 gateway (or vice versa) pins zero
        // bypass routes yet still "succeeds" — under the kill switch the pf
        // allow-list then holds nothing and the engine's every dial is
        // dropped: tunnel up, zero traffic, "Connected" UI.
        if serverV4.isEmpty && gatewayV6 == nil {
            throw TunnelError(message: "server resolves to IPv6 addresses only and this machine has no IPv6 default gateway — the tunnel would carry nothing")
        }
        for ip in serverV4 {
            // The bypass pin is load-bearing: if the add silently fails (EEXIST
            // against a wrong next-hop, transient error), the engine's own
            // dial follows the /1 routes back into our utun — the "tunnel up,
            // zero traffic" self-loop. Fail the connect instead.
            let r = SystemCommand.ensureHostRoute(host: ip, gateway: gw4, inet6: false)
            guard r.ok else {
                throw TunnelError(message: "Failed to pin bypass route for \(ip): \(r.output)")
            }
            bypassV4.append(ip)
        }
        if let gw6 = gatewayV6 {
            for ip in serverV6 {
                let r = SystemCommand.ensureHostRoute(host: ip, gateway: gw6, inet6: true)
                guard r.ok else {
                    throw TunnelError(message: "Failed to pin bypass route for \(ip): \(r.output)")
                }
                bypassV6.append(ip)
            }
        }
    }

    private func bringUp(
        socksHost: String, socksPort: Int,
        tunAddress: String, tunGateway: String,
        mtu: Int, serverAddress: String, killSwitch: Bool
    ) throws {
        self.serverAddress = serverAddress

        // 0. Address-collision gate. A foreign interface already holding an
        // address in our endpoint's /24 (or our gateway host) makes
        // source-address selection ambiguous: the system resolver pointed at
        // our gateway can have its queries swallowed by the foreign TUN
        // (every lookup times out — "everything is slow"), and traffic to the
        // overlapping range gets tunneled to a remote SOCKS that cannot route
        // it (sites break). Building that tunnel is worse than refusing it:
        // fail loudly, the app falls back to its "Route apps through Anemia"
        // coexist mode which is designed for exactly this case. (Our own
        // utun doesn't exist yet — swept beforehand — so any holder here is
        // foreign.)
        try checkTunnelAddressCollision(tunAddress: tunAddress, tunGateway: tunGateway)

        // 1. Gateways + server bypass routes (v4 and v6).
        try pinBypassRoutes(serverAddress: serverAddress)

        // 2. Start tun2socks on a fresh utun.
        guard let name = SystemCommand.freeUtunName() else {
            throw TunnelError(message: "no free utun device (utun90…utun199 all in use)")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: try locateTun2socks())
        proc.arguments = [
            // pflag: single-dash is shorthand bundling — `-loglevel` died as
            // "unknown shorthand flag: 'l'" and tun2socks exited with the
            // usage text before ever creating the interface. Long options
            // need the double dash.
            "--device", "tun://\(name)",
            "--proxy", "socks5://\(socksHost):\(socksPort)",
            "--loglevel", "warning",
            // Set the device MTU ourselves (matches the ifconfig step below) and
            // let the gVisor netstack auto-tune TCP buffers — the default
            // fixed receive window stalls bulk throughput on high-BDP links.
            "--mtu", "\(mtu)",
            "--tcp-auto-tuning"
        ]
        // Watch the bridge: if tun2socks dies on its own the utun routes go
        // dead — with the kill switch armed that is a total traffic blackhole
        // behind a still-"Connected" UI. Tear the tunnel down instead so the
        // machine stays reachable; the app's health loop reports/reconnects.
        // Handler BEFORE run(): a child exiting between run() and the
        // assignment may not invoke the handler at all.
        proc.terminationHandler = { [weak self] p in
            guard let self else { return }
            self.queue.async { [self] in
                guard self.tun2socks === p else { return }
                self.tearDown()
            }
        }
        try proc.run()
        tun2socks = proc
        activeTun2socksPid = proc.processIdentifier

        // 3. Wait for the interface, then address + MTU it.
        guard waitForInterface(name, timeout: 5.0) else {
            throw TunnelError(message: "utun \(name) did not appear")
        }
        utun = name
        let addr = SystemCommand.run("/sbin/ifconfig", [name, "inet", tunAddress, tunGateway, "up"])
        guard addr.ok else {
            throw TunnelError(message: "Failed to address \(name): \(addr.output)")
        }
        SystemCommand.run("/sbin/ifconfig", [name, "mtu", "\(mtu)"])

        // 4. Split-default routes via the utun (v4). change-then-add: a
        // coexisting client's same-prefix entries make a bare `add` fail
        // with EEXIST; `route change` moves them onto our interface instead.
        let r1 = SystemCommand.ensureNetRoute(destination: "0.0.0.0/1", interface: name, inet6: false)
        let r2 = SystemCommand.ensureNetRoute(destination: "128.0.0.0/1", interface: name, inet6: false)
        guard r1.ok, r2.ok else {
            throw TunnelError(message: "Failed to install default routes: \(r1.output)\(r2.output)")
        }

        // 4b. IPv6: tunnel it unconditionally (anti-leak). Tunneling only
        // when a v6 gateway was detected left a hole: if detection failed on
        // a host that DOES have v6, every v6 flow bypassed the tunnel via the
        // physical default route — v6 traffic reaches the same blocked
        // destinations unfettered. With no v6 on the host, the utun routes
        // are inert. (The bypass routes for the server's own v6 stay
        // conditional on gatewayV6 — those genuinely need a next-hop.)
        // A v6 route failure is fatal, not cosmetic: browsers are
        // dual-stack and prefer v6, so a v6 gap is a direct leak path around
        // the tunnel (and around the kill switch it is a blackhole anyway).
        SystemCommand.run("/sbin/ifconfig", [name, "inet6", tunV6Address, "prefixlen", "64"])
        let r3 = SystemCommand.ensureNetRoute(destination: "::/1", interface: name, inet6: true)
        let r4 = SystemCommand.ensureNetRoute(destination: "8000::/1", interface: name, inet6: true)
        guard r3.ok, r4.ok else {
            throw TunnelError(message: "Failed to install IPv6 default routes: \(r3.output)\(r4.output)")
        }
        v6Enabled = true

        // 5. Kill switch (fail-closed) — armed last, after routes are in place.
        if killSwitch {
            do {
                pfToken = try KillSwitch.enable(utun: name, serverV4: bypassV4, serverV6: bypassV6)
            } catch {
                // A kill switch that silently failed to arm means the user
                // believes they're fail-closed while egress is open — worse
                // than no tunnel. Refuse the connection instead.
                throw TunnelError(message: "kill switch failed to arm: \(error.localizedDescription)")
            }
            killSwitchOn = true
        }

        // 6. Keep the bypass routes pinned to the server's current IPs — on a
        // 60 s heartbeat and, more importantly, the instant the network changes.
        startResolveTimer()
        startNetworkMonitor()
    }

    /// The address-collision gate both bring-up paths share (see the long
    /// comment inside ``bringUp``). Must run on `queue`.
    private func checkTunnelAddressCollision(tunAddress: String, tunGateway: String) throws {
        let ifconfig = SystemCommand.run("/sbin/ifconfig", ["-a"])
        if let hit = SystemCommand.tunnelCollision(
            SystemCommand.parseInetHolders(ifconfig.output),
            address: tunAddress, gateway: tunGateway
        ) {
            throw TunnelError(message: "another interface (\(hit.iface)) already owns \(hit.ip) — collides with our tunnel range \(tunAddress)/24; disconnect it or use 'Route apps through Anemia'")
        }
    }

    // MARK: - AmneziaWG / WireGuard engine (root-owned daemon + routing)

    func startAWGTunnel(
        enginePath: String,
        interfaceName: String,
        configScript: String,
        tunAddress: String,
        tunGateway: String,
        mtu: Int,
        serverAddress: String,
        killSwitch: Bool,
        reply: @escaping (Bool, String?) -> Void
    ) {
        queue.async {
            // Client input validation before any system call (see startTunnel).
            guard interfaceName.range(of: "^[A-Za-z0-9_-]{1,15}$", options: .regularExpression) != nil else {
                reply(false, "invalid interface name \(interfaceName)"); return
            }
            guard !configScript.isEmpty, configScript.utf8.count <= 64 << 10 else {
                reply(false, "config script missing or oversized"); return
            }
            guard (576...9000).contains(mtu) else {
                reply(false, "invalid mtu \(mtu)"); return
            }
            guard DirectResolver.isIPv4(tunAddress), DirectResolver.isIPv4(tunGateway) else {
                reply(false, "invalid tunnel addressing \(tunAddress) / \(tunGateway)"); return
            }
            guard !serverAddress.isEmpty else {
                reply(false, "empty server address"); return
            }
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.isExecutableFile(atPath: enginePath),
                  fm.fileExists(atPath: enginePath, isDirectory: &isDir), !isDir.boolValue else {
                reply(false, "engine binary not found or not executable: \(enginePath)"); return
            }
            // Refuse anything that resolves through a symlinked directory the
            // user can't own? Overkill: the client is code-signature-verified
            // (same trust domain as the app that runs xray from anywhere).
            self.sweepStaleTunnel()
            if self.tun2socks != nil || self.utun != nil {
                self.tearDown()
            }
            do {
                try self.bringUpAWG(
                    enginePath: enginePath, interfaceName: interfaceName,
                    configScript: configScript, tunAddress: tunAddress,
                    tunGateway: tunGateway, mtu: mtu,
                    serverAddress: serverAddress, killSwitch: killSwitch
                )
                // Success message carries the kernel-assigned utun name — the
                // app uses it to poll netstat counters for the traffic UI.
                reply(true, self.utun)
            } catch {
                self.tearDown()
                reply(false, (error as? TunnelError)?.message ?? error.localizedDescription)
            }
        }
    }

    private func bringUpAWG(
        enginePath: String, interfaceName: String, configScript: String,
        tunAddress: String, tunGateway: String, mtu: Int,
        serverAddress: String, killSwitch: Bool
    ) throws {
        self.serverAddress = serverAddress
        try checkTunnelAddressCollision(tunAddress: tunAddress, tunGateway: tunGateway)
        try pinBypassRoutes(serverAddress: serverAddress)

        // Snapshot the utun set before the spawn: the kernel assigns the real
        // utunN itself, so the engine's interface is found by diffing.
        let before = Self.utunNames(in: SystemCommand.run("/sbin/ifconfig", ["-a"]).output)

        // 1. Spawn the engine as root (foreground) — its UAPI socket under
        //    /var/run/amneziawg can only be created by root, which is why this
        //    whole path lives in the helper rather than the app.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: enginePath)
        proc.arguments = ["-f", interfaceName]
        proc.qualityOfService = .userInitiated
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = outPipe
        let tailBox = OutputTail()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil   // EOF self-clear (no busy-spin)
                return
            }
            tailBox.append(chunk)
        }
        // A previous generation's engine that was SIGKILLed (helper crash,
        // tearDown escalation) leaves the socket FILE behind — the file
        // survives its creator, so the wait loop below would exit instantly,
        // the UAPI connect would fail with ECONNREFUSED, and every retry
        // would fail the same way until something removes the file. Unlink
        // it before the spawn; root owns /var/run/amneziawg.
        let sockPath = "/var/run/amneziawg/\(interfaceName).sock"
        try? FileManager.default.removeItem(atPath: sockPath)
        // Termination handler BEFORE run(): a child that exits between run()
        // and the handler assignment may not invoke the handler — the death
        // would then be unsupervised until this function's own checks fail.
        proc.terminationHandler = { [weak self] p in
            guard let self else { return }
            self.queue.async { [self] in
                guard self.tun2socks === p else { return }
                self.tearDown()
            }
        }
        do { try proc.run() } catch {
            throw TunnelError(message: "failed to spawn \(enginePath): \(error.localizedDescription)")
        }
        tun2socks = proc          // supervised in the shared bridge slot…
        activeTun2socksPid = proc.processIdentifier

        // 2. Wait for the UAPI socket, then push the client-built config.
        let deadline = Date().addingTimeInterval(6)
        while !FileManager.default.fileExists(atPath: sockPath) {
            if !proc.isRunning {
                try? FileManager.default.removeItem(atPath: sockPath)
                throw TunnelError(message: "amneziawg-go exited during startup: \(tailBox.tail())")
            }
            if Date() > deadline {
                try? FileManager.default.removeItem(atPath: sockPath)
                throw TunnelError(message: "engine UAPI socket \(sockPath) never appeared")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        do {
            try pushUAPIConfig(socketPath: sockPath, script: configScript)
        } catch {
            // A config the engine rejected usually kills it; its socket file
            // must not outlive it and wedge the next connect.
            try? FileManager.default.removeItem(atPath: sockPath)
            throw error
        }

        // 3. Detect the engine's utun — with ambiguity rejection. Any OTHER
        // utun created inside this multi-second window (a coexisting
        // sing-box/clash reconnecting, an IPsec SA coming up) adopted as
        // "ours" would get this session's addressing, split routes and kill
        // switch installed on it — a silent hijack of the neighbor's tunnel.
        // Require a stable, unambiguous diff instead: exactly one new
        // interface, present in two samples ~300 ms apart. Two or more
        // persistent newcomers → refuse loudly rather than pick one.
        var name: String?
        var prevNew = Set<String>()
        let detectDeadline = Date().addingTimeInterval(6)
        while Date() < detectDeadline {
            if !proc.isRunning {
                throw TunnelError(message: "amneziawg-go exited before creating its utun: \(tailBox.tail())")
            }
            let current = Self.utunNames(in: SystemCommand.run("/sbin/ifconfig", ["-a"]).output)
            let fresh = current.subtracting(before)
            if !fresh.isEmpty {
                let stable = fresh.intersection(prevNew)
                if stable.count == 1, let only = stable.first {
                    name = only
                    break
                }
                if fresh.count > 1, !prevNew.isEmpty {
                    throw TunnelError(
                        message: "ambiguous utun detection (\(fresh.joined(separator: ", ")) — another tunnel came up concurrently); retry")
                }
            }
            prevNew = fresh
            Thread.sleep(forTimeInterval: 0.3)
        }
        guard let name, SystemCommand.interfaceExists(name) else {
            throw TunnelError(message: "engine created no utun interface")
        }
        utun = name

        // 4. Address + MTU, split-default routes, kill switch, monitors —
        //    the same anti-leak grammar as the tun2socks path (IPv6 tunneled
        //    unconditionally, kill switch armed last).
        let addr = SystemCommand.run("/sbin/ifconfig", [name, "inet", tunAddress, tunGateway, "up"])
        guard addr.ok else {
            throw TunnelError(message: "Failed to address \(name): \(addr.output)")
        }
        SystemCommand.run("/sbin/ifconfig", [name, "mtu", "\(mtu)"])
        let r1 = SystemCommand.ensureNetRoute(destination: "0.0.0.0/1", interface: name, inet6: false)
        let r2 = SystemCommand.ensureNetRoute(destination: "128.0.0.0/1", interface: name, inet6: false)
        guard r1.ok, r2.ok else {
            throw TunnelError(message: "Failed to install default routes: \(r1.output)\(r2.output)")
        }
        SystemCommand.run("/sbin/ifconfig", [name, "inet6", tunV6Address, "prefixlen", "64"])
        let r3 = SystemCommand.ensureNetRoute(destination: "::/1", interface: name, inet6: true)
        let r4 = SystemCommand.ensureNetRoute(destination: "8000::/1", interface: name, inet6: true)
        guard r3.ok, r4.ok else {
            throw TunnelError(message: "Failed to install IPv6 default routes: \(r3.output)\(r4.output)")
        }
        v6Enabled = true
        if killSwitch {
            do {
                pfToken = try KillSwitch.enable(utun: name, serverV4: bypassV4, serverV6: bypassV6)
            } catch {
                throw TunnelError(message: "kill switch failed to arm: \(error.localizedDescription)")
            }
            killSwitchOn = true
        }
        startResolveTimer()
        startNetworkMonitor()
    }

    /// Push the `set=1` script into the engine's UAPI socket — a blocking
    /// POSIX round trip (connect → write → read `errno=`), bounded by
    /// SO_SNDTIMEO/SO_RCVTIMEO so a wedged daemon can't hang the XPC reply.
    /// Must run on `queue`.
    private func pushUAPIConfig(socketPath: String, script: String) throws {
        guard socketPath.utf8.count < 104 else {
            throw TunnelError(message: "UAPI socket path too long")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw TunnelError(message: "socket() failed: errno \(errno)")
        }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = sa_family_t(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            dst.copyBytes(from: Array(socketPath.utf8))
        }
        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw TunnelError(message: "UAPI connect failed: errno \(errno)")
        }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let data = Array(script.utf8)
        var sent = 0
        while sent < data.count {
            let n = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
                send(fd, raw.baseAddress!.advanced(by: sent), data.count - sent, 0)
            }
            guard n > 0 else {
                throw TunnelError(message: "UAPI send failed: errno \(errno)")
            }
            sent += n
        }
        // Read the reply to its terminating blank line, not a single recv:
        // SOCK_STREAM gives no all-or-nothing on one read — a partial first
        // read (or a reply arriving late in a second segment after a heavy
        // junk-packet set) used to be misreported as "engine gave no UAPI
        // reply", and a healthy engine was torn down.
        var replyData = Data()
        var buf = [UInt8](repeating: 0, count: 512)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }          // EOF, timeout, or error — parse what we have
            replyData.append(contentsOf: buf[0..<n])
            // UAPI replies end with a blank line.
            if replyData.suffix(2) == Data("\n\n".utf8) { break }
            if replyData.count > 8 << 10 { break }
        }
        guard let reply = String(data: replyData, encoding: .utf8) else {
            throw TunnelError(message: "engine gave no UAPI reply")
        }
        // The errno line may be preceded by other reply lines — scan them all.
        guard let line = reply.split(separator: "\n").first(where: { $0.hasPrefix("errno=") }) else {
            throw TunnelError(message: "engine gave no UAPI reply")
        }
        let value = line.dropFirst("errno=".count)
        guard value == "0" else {
            throw TunnelError(message: "engine rejected the config (errno=\(value)) — check the keys against the server's AmneziaWG version")
        }
    }

    /// utun interface names present in an `ifconfig -a` dump.
    private static func utunNames(in output: String) -> Set<String> {
        Set(output.split(separator: "\n").compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("utun"), let colon = t.firstIndex(of: ":") else { return nil }
            return String(t[t.startIndex..<colon])
        })
    }

    /// Bounded tail of a child process's output, for failure reporting.
    private final class OutputTail: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) {
            lock.lock(); data.append(chunk)
            if data.count > 8 << 10 { data.removeFirst(data.count - (8 << 10)) }
            lock.unlock()
        }
        func tail() -> String {
            lock.lock(); defer { lock.unlock() }
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .suffix(400).description ?? "no output"
        }
    }

    /// Periodically re-resolve `serverAddress` and keep bypass routes pinned:
    /// any new IP gets a route, and every known route is re-asserted (another
    /// VPN client swapping the route table can silently drop ours). Routes for
    /// addresses that disappeared are left to expire — deleting them
    /// mid-flight risks cutting the engine's live connection. The first tick
    /// fires after 60s (not 300): a DNS/CDN rotation inside that window was
    /// enough to send the engine's own dial back into the utun — a self-loop
    /// that surfaces as endless "connection reset by peer" after the fragment
    /// dialer runs. The split-default routes are re-asserted on the same tick:
    /// a third-party client with auto_route (sing-box/clash) rewrites the
    /// table when it reconnects, and dropped split routes leave the tunnel
    /// "up" while system traffic exits elsewhere.
    private func startResolveTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            guard let self, let host = self.serverAddress, self.utun != nil else { return }
            // Refresh the physical gateways first: SCDynamicStore covers
            // link switches, but a same-link change (DHCP renew, gateway
            // swap by the router) can silently move the next-hop.
            if let g4 = SystemCommand.defaultGateway() { self.gatewayV4 = g4 }
            self.gatewayV6 = SystemCommand.defaultGateway(inet6: true)
            self.reassertBypassRoutes(host: host)
            self.reassertSplitRoutes()
        }
        timer.resume()
        resolveTimer = timer
    }

    /// Kill tun2socks processes orphaned by a previous helper generation and
    /// drop the split-default routes they left. Only processes whose
    /// *executable* is our installed bridge are touched — `pgrep -f` matches
    /// the full argument string, so a user's `tail -f`/editor/grep holding
    /// that path in its argv must not be swept up, and a tun2socks the user
    /// runs themselves is never killed. Killing the process releases its utun
    /// (the kernel drops interface-scoped routes with it); the explicit route
    /// deletes cover the belt-and-braces case where another client re-added
    /// our prefixes against a dead interface. Must run on `queue`.
    private func sweepStaleTunnel() {
        let keep = tun2socks?.processIdentifier ?? 0
        let r = SystemCommand.run("/usr/bin/pgrep", ["-f", "PrivilegedHelperTools/tun2socks"])
        if r.ok {
            let candidates = Self.tun2socksPaths()
            var pids: [pid_t] = []
            for line in r.output.split(separator: "\n") {
                guard let pid = pid_t(line.trimmingCharacters(in: .whitespacesAndNewlines)),
                      pid > 0, pid != keep,
                      let path = SystemCommand.executablePath(pid: pid),
                      candidates.contains(path) else { continue }
                pids.append(pid)
            }
            if !pids.isEmpty {
                for pid in pids { kill(pid, SIGTERM) }
                // Grace, then force: a gVisor bridge can be slow to honor SIGTERM.
                // Re-verify the target's executable immediately before the
                // SIGKILL — a process that exited during the grace window can
                // have its pid recycled against an unrelated (possibly system)
                // process, and `kill(pid, 0)` alone would then sign that
                // innocent process's death warrant from root.
                Thread.sleep(forTimeInterval: 0.3)
                for pid in pids where kill(pid, 0) == 0 {
                    guard let path = SystemCommand.executablePath(pid: pid),
                          candidates.contains(path) else { continue }
                    kill(pid, SIGKILL)
                }
            }
        }
        // Route sweep is scoped to dead utuns: deleting the split-default
        // prefixes globally would rip the same entries out from under a
        // coexisting VPN client (sing-box/clash auto_route) that legitimately
        // holds them on a *live* interface of its own.
        for row in SystemCommand.staleSplitRoutes() {
            var args = ["-n", "delete"]
            if row.inet6 { args.append("-inet6") }
            args += ["-net", row.destination, "-interface", row.iface]
            _ = SystemCommand.run("/sbin/route", args)
        }
        // Stale AmneziaWG engines from a dead helper generation: unlike
        // tun2socks these are Go daemons re-parented to launchd, still root,
        // still holding their utun + split routes (a full blackhole). Same
        // executable-path filter — only OUR engine locations are touched.
        let awgKeep = tun2socks?.processIdentifier ?? 0
        let awg = SystemCommand.run("/usr/bin/pgrep", ["-f", "amneziawg-go"])
        if awg.ok {
            let candidates = Self.awgEnginePaths()
            var pids: [pid_t] = []
            for line in awg.output.split(separator: "\n") {
                guard let pid = pid_t(line.trimmingCharacters(in: .whitespacesAndNewlines)),
                      pid > 0, pid != awgKeep,
                      let path = SystemCommand.executablePath(pid: pid),
                      candidates.contains(path) else { continue }
                pids.append(pid)
            }
            for pid in pids { kill(pid, SIGTERM) }
            if !pids.isEmpty {
                Thread.sleep(forTimeInterval: 0.3)
                for pid in pids where kill(pid, 0) == 0 {
                    guard let path = SystemCommand.executablePath(pid: pid),
                          candidates.contains(path) else { continue }
                    kill(pid, SIGKILL)
                }
            }
        }
    }

    /// Executable paths a legitimate amneziawg-go engine can run from: the
    /// installed helper-tools copy, the dev override, a sibling of this
    /// binary, and the Homebrew locations (a root helper executing a
    /// user-writable Homebrew binary mirrors what the app itself does with
    /// xray; the XPC client is code-signature-verified either way).
    private static func awgEnginePaths() -> [String] {
        // Homebrew locations are deliberately NOT on this list: the sweep
        // fires SIGTERM→SIGKILL at any process running one of these binaries,
        // and a user-writable path may also be running the user's own
        // independent WireGuard/AWG session — same promise the tun2socks
        // sweep keeps. Only this helper's own install locations are swept;
        // resolveBinary() (app side) still finds a Homebrew engine for
        // spawning.
        var paths = ["/Library/PrivilegedHelperTools/amneziawg-go"]
        if let env = ProcessInfo.processInfo.environment["LOADER_AWG_PATH"] { paths.append(env) }
        paths.append(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("amneziawg-go").path)
        return paths
    }

    /// Executable paths a legitimate tun2socks bridge can run from (mirrors
    /// `locateTun2socks`): the installed helper-tools copy, the dev override,
    /// and a sibling of this binary.
    private static func tun2socksPaths() -> [String] {
        var paths = ["/Library/PrivilegedHelperTools/tun2socks"]
        if let env = ProcessInfo.processInfo.environment["LOADER_TUN2SOCKS_PATH"] { paths.append(env) }
        paths.append(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("tun2socks").path)
        return paths
    }

    /// Re-assert the split-default routes via change-then-add: another VPN
    /// client swapping the route table can leave its *own* entries for these
    /// prefixes in place, and a bare `route add` fails with EEXIST against
    /// them — the re-assert would silently do nothing while the system's
    /// traffic exits via the other client. Must run on `queue`.
    private func reassertSplitRoutes() {
        guard let name = utun, tun2socks?.isRunning ?? false else { return }
        var specs: [(String, Bool)] = [("0.0.0.0/1", false), ("128.0.0.0/1", false)]
        if v6Enabled { specs += [("::/1", true), ("8000::/1", true)] }
        for (dest, inet6) in specs {
            let r = SystemCommand.ensureNetRoute(destination: dest, interface: name, inet6: inet6)
            if !r.ok {
                logErr("reassert: route \(dest) via \(name) failed: \(r.output)")
            }
        }
    }

    /// Re-resolve the server and (re-)pin every bypass host route via the
    /// current physical gateways. `route change` (falling back to `add`) keeps
    /// a route already in the table moving with the next-hop: a bare `add`
    /// just reports EEXIST and leaves the bypass pointing at a gateway that
    /// died with the old link. Must run on `queue`.
    private func reassertBypassRoutes(host: String) {
        guard let gw4 = gatewayV4 else { return }
        // Fake-IP answers (a concurrently running sing-box/clash resolver
        // replying from its 198.18.0.0/15 pool) must never enter the bypass
        // set — a route pinned to a pool address sends the engine's dial into
        // the foreign VPN (or nowhere), with the kill switch then failing
        // closed on everything.
        var allowlistGrew = false
        // Cap the allow-list: a CDN-backed server domain can rotate dozens of
        // addresses per hour, and every append both grows the pinned-route
        // table and rewrites the pf ruleset. Past the cap, stale entries keep
        // being re-pinned but new ones are dropped — 32 host routes cover any
        // realistic rotation while bounding the growth.
        let bypassCap = 32
        for ip in SystemCommand.resolveIPv4(host)
            .filter({ !DirectResolver.isFakeIP($0) })
            .filter({ !bypassV4.contains($0) })
            where bypassV4.count < bypassCap {
            bypassV4.append(ip)
            allowlistGrew = true
        }
        for ip in bypassV4 {
            repinRoute(ip: ip, gateway: gw4, inet6: false)
        }
        if let gw6 = gatewayV6 {
            for ip in SystemCommand.resolveIPv6(host)
                where !bypassV6.contains(ip) && bypassV6.count < bypassCap {
                bypassV6.append(ip)
                allowlistGrew = true
            }
            for ip in bypassV6 {
                repinRoute(ip: ip, gateway: gw6, inet6: true)
            }
        }
        // The kill switch's allow-list was armed with the server IPs known at
        // connect. When re-resolution discovered new ones, a DNS rotation of
        // the server domain, re-arm the ruleset — otherwise pf keeps dropping
        // the engine's dial to the new address and the tunnel dies
        // mid-session with no recovery while the kill switch holds.
        if allowlistGrew, killSwitchOn, let tun = utun {
            KillSwitch.rearm(utun: tun, serverV4: bypassV4, serverV6: bypassV6)
        }
    }

    /// Re-pin a bypass host route via `route change`, falling back to
    /// `route add` when the entry isn't in the table yet.
    private func repinRoute(ip: String, gateway: String, inet6: Bool) {
        let r = SystemCommand.ensureHostRoute(host: ip, gateway: gateway, inet6: inet6)
        if !r.ok {
            logErr("reassert: bypass route \(ip) via \(gateway) failed: \(r.output)")
        }
    }

    /// Subscribe to global IPv4/IPv6 config changes so a link switch is handled
    /// immediately (not on the 60 s timer's schedule). Callbacks run on `queue`.
    private func startNetworkMonitor() {
        var ctx = SCDynamicStoreContext(version: 0,
                                        info: Unmanaged.passUnretained(self).toOpaque(),
                                        retain: nil, release: nil, copyDescription: nil)
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            Unmanaged<HelperService>.fromOpaque(info).takeUnretainedValue().handleNetworkChange()
        }
        guard let store = SCDynamicStoreCreate(nil,
                "com.loader.vpn.helper.netmon" as CFString, callback, &ctx) else { return }
        let keys = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] as CFArray
        SCDynamicStoreSetNotificationKeys(store, keys, nil)
        SCDynamicStoreSetDispatchQueue(store, queue)   // callbacks land on `queue`
        netStore = store
    }

    private func stopNetworkMonitor() {
        if let store = netStore { SCDynamicStoreSetDispatchQueue(store, nil) }
        netStore = nil
    }

    /// A network change fired. Re-detect the physical gateways (a link switch
    /// moves them) and re-pin the bypass routes via the new next-hop, so the
    /// engine's own encrypted connection keeps leaving through the real NIC
    /// instead of looping into the tunnel. The split-defaults are re-asserted
    /// too — a link change often rebuilds the route table, dropping ours.
    /// Runs on `queue`.
    private func handleNetworkChange() {
        guard utun != nil, let host = serverAddress else { return }
        if let g4 = SystemCommand.defaultGateway() { gatewayV4 = g4 }
        gatewayV6 = SystemCommand.defaultGateway(inet6: true)
        reassertBypassRoutes(host: host)
        reassertSplitRoutes()
    }

    func tearDown() {
        resolveTimer?.cancel()
        resolveTimer = nil
        stopNetworkMonitor()
        serverAddress = nil
        // DNS first: with the utun going away, a resolver pointed at the
        // tunnel gateway would leave the machine name-resolution-dead even
        // though the network itself is fine.
        restoreSystemDNS()
        // The SOCKS override points apps at this session's engine port, which
        // is about to die — leave it armed and every proxy-aware app loses the
        // network with nothing left to restore it (the old code only restored
        // DNS here, so an uninstall/reinstall or any helper teardown with
        // coexist mode on left the system proxy stranded on a dead port).
        restoreSystemProxy()
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
        // Nil first: the termination handler watches `tun2socks === proc` to
        // distinguish spontaneous death from this intentional teardown, which
        // must not re-enter tearDown().
        let proc = tun2socks
        tun2socks = nil
        activeTun2socksPid = 0
        if let proc, proc.isRunning {
            proc.terminate()
            // Bounded wait: SIGTERM, a short grace period, then SIGKILL —
            // so a wedged tun2socks can never hang the XPC reply (and the
            // app's UI) indefinitely.
            let deadline = Date().addingTimeInterval(3)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            // Re-verify identity before the SIGKILL: between isRunning and
            // the kill the pid can be reaped and recycled by an unrelated
            // process, and a root kill would land on the innocent owner.
            // The live binary path must still match the one we spawned.
            if proc.isRunning,
               SystemCommand.executablePath(pid: proc.processIdentifier) == proc.executableURL?.path {
                kill(proc.processIdentifier, SIGKILL)
            }
            proc.waitUntilExit()
        }
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
