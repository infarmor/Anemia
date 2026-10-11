import Foundation
import SystemConfiguration
import LoaderCore
import LoaderShared

/// Pid of the tun2socks bridge currently owned by the running helper, or 0
/// when no tunnel is up. Read by the termination path's emergency branch,
/// which runs while the state queue may be wedged.
nonisolated(unsafe) var activeTun2socksPid: pid_t = 0

/// The live service instance, for the SIGTERM handler installed in main.swift
/// before the service exists (a stop request during launch recovery must not
/// be lost).
final class ServiceRegistry: @unchecked Sendable {
    static let shared = ServiceRegistry()
    private let lock = NSLock()
    private var _service: HelperService?

    var service: HelperService? {
        get { lock.lock(); defer { lock.unlock() }; return _service }
        set { lock.lock(); _service = newValue; lock.unlock() }
    }
}

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
/// Network safety: everything that would outlive this process — the system
/// resolver, the SOCKS proxy, the kill switch's pf reference — is changed only
/// through ``SystemSettingsGuard`` (a fsync'd journal written before the
/// change) and is replayed at every launch, so neither a crash nor a power
/// loss can leave a Mac offline across a reboot.
final class HelperService: NSObject, LoaderHelperProtocol, @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.loader.vpn.helper.state", qos: .userInitiated)
    /// Journal-backed DNS/proxy overrides and the kill switch's pf reference.
    private let settings: SystemSettingsGuard

    override init() {
        settings = SystemSettingsGuard(
            store: NetworkJournalStore(), shell: LiveNetworkSettingsShell(),
            log: { FileHandle.standardError.write(Data("[helper] \($0)\n".utf8)) })
        super.init()
        queue.sync { _ = recoverPreviousGeneration(repair: false) }
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
    private var killSwitchOn = false
    /// Split tunneling (guarded by `queue`): user-listed networks and domains
    /// whose traffic leaves via the physical gateway, never the utun.
    private var splitNetV4: [String] = []
    private var splitNetV6: [String] = []
    private var splitDomains: [String] = []
    private var splitHostV4: [String] = []
    private var splitHostV6: [String] = []
    /// Routes this session actually installed for them (directly connected
    /// destinations are skipped), so teardown removes exactly those.
    private var splitRoutes: [(destination: String, network: Bool, inet6: Bool)] = []

    /// Everything the kill switch lets out besides the tunnel itself: the
    /// server's addresses and the split-tunnel destinations.
    private var allowV4: [String] { bypassV4 + splitNetV4 + splitHostV4.filter { !bypassV4.contains($0) } }
    private var allowV6: [String] { bypassV6 + splitNetV6 + splitHostV6.filter { !bypassV6.contains($0) } }
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
    /// Independent safety net for the persistent overrides while no tunnel
    /// supervises them (see startOverrideWatchdog). Guarded by `queue`.
    private var overrideWatchdog: DispatchSourceTimer?
    private var proxyDeadTicks = 0
    private var dnsOrphanTicks = 0
    /// Ticks (5 s each) before the watchdog restores an override. Doubles
    /// after a restore that couldn't land, so a service that keeps refusing
    /// isn't hammered — and the DNS cache isn't flushed — every 15 s.
    private var proxyRestoreThreshold = 3
    private var dnsRestoreThreshold = 3

    // utun IPv6 address (ULA) used when tunneling IPv6.
    private let tunV6Address = "fd00:1972::1"

    /// Log to stderr (launchd captures it for `launchctl print`). The helper
    /// has no UI of its own; the app's log view only shows engine output.
    private func logErr(_ msg: String) {
        FileHandle.standardError.write(Data("[helper] \(msg)\n".utf8))
    }

    // MARK: - Recovery

    /// Undo everything a previous generation may have left behind — crash,
    /// SIGKILL, bootout mid-session, power loss: recorded DNS/proxy overrides
    /// go back, the kill switch anchor is flushed and its pf reference
    /// released, orphaned bridges are killed and their dead routes dropped,
    /// and resolvers still pinned to a tunnel range nothing holds are reset.
    /// Runs at every launch (boot via RunAtLoad, crash respawn, reinstall), so
    /// a reboot always brings a Mac back to a working network. `repair` (an
    /// explicit user request) additionally sweeps dead loopback proxies and
    /// legacy-range resolvers. Must run on `queue`, with no tunnel up.
    private func recoverPreviousGeneration(repair: Bool) -> [String] {
        var report: [String] = []
        report += settings.restoreDNS()
        report += settings.restoreProxy()
        let pf = settings.pfRecovery()
        report += KillSwitch.recover(token: pf.token, legacyMainRuleset: pf.legacyMainRuleset)
        // Only now, with the anchor flushed and the reference released, does
        // the ledger forget it — see `SystemSettingsGuard.pfRecovery`.
        settings.clearPFRecovery()
        report += sweepStaleTunnel()
        report += settings.sweepDeadPins(includeProxies: repair, includeLegacyRanges: repair)
        for line in report { logErr("recovery: \(line)") }
        return report
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
            // The bridge carries every packet of the machine: its upstream
            // must be the local engine, never a remote host.
            guard DirectResolver.isIPv4(socksHost), socksHost.hasPrefix("127.") else {
                reply(false, "refusing a non-loopback SOCKS upstream \(socksHost)"); return
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
            // cleanup and leave its bridge orphaned — tun2socks still alive,
            // still holding its utun, still owning the split routes. The sweep
            // is idempotent and near-free when nothing is stale.
            _ = self.sweepStaleTunnel()
            if self.tun2socks != nil {
                // A leftover tunnel points at the SOCKS port of an app session
                // that no longer exists, yet still owns the default route — a
                // full blackhole. Replace it.
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
            guard (1...65535).contains(port), NetworkSettingsPolicy.isLoopbackHost(host) else {
                // The override exists to point apps at the local engine; any
                // other target is a client bug, not something to persist.
                reply(false, "refusing a non-loopback proxy target \(host):\(port)"); return
            }
            let r = self.settings.applyProxy(host: host, port: port)
            if r.ok { self.startOverrideWatchdog() }
            reply(r.ok, r.error)
        }
    }

    func clearSystemProxy(reply: @escaping (Bool, String?) -> Void) {
        queue.async {
            for line in self.settings.restoreProxy() { self.logErr(line) }
            self.stopOverrideWatchdogIfIdle()
            reply(!self.settings.hasProxyOverride, self.settings.hasProxyOverride ? "some services could not be restored yet" : nil)
        }
    }

    func setSystemDNS(server: String, reply: @escaping (Bool, String?) -> Void) {
        queue.async {
            guard DirectResolver.isIPv4(server) || server.contains(":") else {
                reply(false, "invalid resolver address \(server)"); return
            }
            let r = self.settings.applyDNS(servers: [server])
            if r.ok { self.startOverrideWatchdog() }
            reply(r.ok, r.error)
        }
    }

    func clearSystemDNS(reply: @escaping (Bool, String?) -> Void) {
        queue.async {
            for line in self.settings.restoreDNS() { self.logErr(line) }
            self.stopOverrideWatchdogIfIdle()
            reply(!self.settings.hasDNSOverride, self.settings.hasDNSOverride ? "some services could not be restored yet" : nil)
        }
    }

    func tunnelStatus(reply: @escaping (Bool) -> Void) {
        queue.async {
            reply(self.utun != nil && (self.tun2socks?.isRunning ?? false))
        }
    }

    func repairNetwork(reply: @escaping (Bool, String) -> Void) {
        queue.async {
            reply(true, self.repairSummary())
        }
    }

    func networkDiagnostics(reply: @escaping (String) -> Void) {
        queue.async {
            var lines = ["helper \(LoaderHelperVersion)"]
            if let name = self.utun {
                lines.append("tunnel up on \(name)\(self.killSwitchOn ? ", kill switch armed" : "")")
            } else {
                lines.append("no tunnel")
            }
            lines.append(KillSwitch.statusSummary())
            let recorded = self.settings.summary()
            lines += recorded.isEmpty ? ["no recorded DNS/proxy overrides"] : recorded
            let route = SystemCommand.parseRouteGet(SystemCommand.run("/sbin/route", ["-n", "get", "default"]).output)
            lines.append("default route: \(route.interface ?? "none")\(route.gateway.map { " via \($0)" } ?? "")")
            // Whether the engine's own dial to the server can leave the machine.
            for (ip, inet6) in self.bypassV4.map({ ($0, false) }) + self.bypassV6.map({ ($0, true) }) {
                let get = SystemCommand.run("/sbin/route", ["-n", "get"] + (inet6 ? ["-inet6"] : []) + [ip])
                let hop = SystemCommand.parseRouteGet(get.output)
                let pinned = SystemCommand.isHostRoutePinned(get.output, host: ip, inet6: inet6)
                lines.append("server \(ip): \(pinned ? "bypass pinned" : "NOT pinned") → \(hop.interface ?? "no route")\(hop.gateway.map { " via \($0)" } ?? "")")
            }
            for row in SystemCommand.staleSplitRoutes() {
                lines.append("stale route \(row.destination) on dead \(row.iface)")
            }
            reply(lines.joined(separator: "\n"))
        }
    }

    func applyBypass(networks: [String], domains: [String], reply: @escaping (Bool, String?) -> Void) {
        queue.async {
            guard let tun = self.utun, self.tun2socks?.isRunning == true else {
                reply(false, "no tunnel is up"); return
            }
            // Never trust the client's validation: the same parser rejects
            // too-broad networks and the tunnel's own ranges here too.
            let parsed = SplitTunnelParser.parse(networks + domains)
            self.removeSplitRoutes()
            for entry in parsed.entries {
                switch entry {
                case .ipv4(let net) where self.splitNetV4.count < 256: self.splitNetV4.append(net)
                case .ipv6(let net) where self.splitNetV6.count < 256: self.splitNetV6.append(net)
                case .domain(let name) where self.splitDomains.count < 64: self.splitDomains.append(name)
                default: break
                }
            }
            let result = self.pinSplitDestinations(resolve: true)
            if self.killSwitchOn {
                KillSwitch.rearm(utun: tun, serverV4: self.allowV4, serverV6: self.allowV6)
            }
            self.logErr("split tunnel: \(self.splitNetV4.count + self.splitNetV6.count) networks, \(self.splitDomains.count) domains → \(self.splitRoutes.count) routes")
            let problems = parsed.rejected.map { "\($0.line): \($0.reason)" } + result.failures
            reply(result.failures.isEmpty, problems.isEmpty ? nil : problems.prefix(5).joined(separator: "; "))
        }
    }

    func uninstall(reply: @escaping (Bool) -> Void) {
        queue.async {
            self.tearDown()
            _ = self.recoverPreviousGeneration(repair: true)
            let clean = self.settings.journal.isEmpty
            if clean { self.settings.discard() }
            try? FileManager.default.removeItem(
                atPath: "/Library/PrivilegedHelperTools/\(LoaderIdentifiers.helperBundleID)")
            try? FileManager.default.removeItem(atPath: "/Library/PrivilegedHelperTools/tun2socks")
            // The root-owned engine the installer placed next to the helper.
            try? FileManager.default.removeItem(atPath: EngineBinaryPolicy.installedAWGEngine)
            let plistPath = "/Library/LaunchDaemons/\(LoaderIdentifiers.helperMachService).plist"
            try? FileManager.default.removeItem(atPath: plistPath)
            // A ledger that still holds entries (a restore that kept failing)
            // stays on disk for the standalone reset script.
            if clean { try? FileManager.default.removeItem(atPath: HelperPaths.stateDir) }
            // Reply BEFORE the self-bootout: `bootout` SIGTERMs this process.
            reply(true)
            SystemCommand.run("/bin/launchctl", ["remove", LoaderIdentifiers.helperMachService])
            SystemCommand.run("/bin/launchctl", ["bootout", "system", plistPath])
        }
    }

    // MARK: - Repair / termination entry points

    /// Tear down any tunnel and run the full recovery sweep. Must run on `queue`.
    private func repairChanges() -> [String] {
        var report: [String] = []
        if utun != nil || tun2socks != nil {
            tearDown()
            report.append("tunnel torn down")
        }
        report += recoverPreviousGeneration(repair: true)
        SystemCommand.flushDNSCache()
        return report
    }

    private func repairSummary() -> String {
        let lines = repairChanges()
        return lines.isEmpty
            ? "No leftovers found — network settings are clean. DNS cache flushed."
            : (lines + ["DNS cache flushed."]).joined(separator: "\n")
    }

    /// `--restore-network` CLI (run as root by the installer / uninstaller).
    func runRestoreCLI(uninstall: Bool) -> String {
        queue.sync {
            let report = repairSummary()
            if uninstall, settings.journal.isEmpty { settings.discard() }
            return report
        }
    }

    /// Orphaned-client teardown from the listener (its timer fires off-queue).
    func tearDownAsync() {
        queue.async { self.tearDown() }
    }

    /// launchd stop (bootout, uninstall, shutdown): tear everything down on
    /// the way out instead of leaving it to the next launch. Bounded — if the
    /// state queue is wedged (a start mid-flight), the essentials run
    /// directly after 10 s: the bridge dies, the kill switch anchor is
    /// flushed, the journal is replayed.
    func shutdownForTermination() {
        let done = DispatchSemaphore(value: 0)
        queue.async {
            self.tearDown()
            done.signal()
        }
        guard done.wait(timeout: .now() + 10) == .timedOut else { return }
        logErr("termination: state queue wedged — emergency cleanup")
        let pid = activeTun2socksPid
        if pid > 0 { kill(pid, SIGKILL) }
        KillSwitch.flush()
        settings.restoreDNS()
        settings.restoreProxy()
    }

    // MARK: - Override watchdog

    /// While a persistent override is recorded, check every 5 s that it still
    /// has something behind it: a proxy pointed at a loopback port nothing
    /// listens on, or a resolver override with no tunnel of ours up, is
    /// restored after 15 s. Covers every path where the app can't clear them
    /// itself — hung, killed, or superseded mid-connect. Must run on `queue`.
    private func startOverrideWatchdog() {
        guard overrideWatchdog == nil else { return }
        proxyDeadTicks = 0
        dnsOrphanTicks = 0
        proxyRestoreThreshold = 3
        dnsRestoreThreshold = 3
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.settings.hasProxyOverride, let port = self.settings.proxyOverridePort {
                self.proxyDeadTicks = PortFinder.canConnect(port) ? 0 : self.proxyDeadTicks + 1
                if self.proxyDeadTicks >= self.proxyRestoreThreshold {
                    self.logErr("watchdog: nothing listens on 127.0.0.1:\(port) — restoring the system proxy")
                    for line in self.settings.restoreProxy() { self.logErr(line) }
                    self.proxyRestoreThreshold = self.settings.hasProxyOverride
                        ? min(self.proxyRestoreThreshold * 2, 120) : 3
                    self.proxyDeadTicks = 0
                }
            }
            if self.settings.hasDNSOverride {
                let tunnelUp = self.utun != nil && (self.tun2socks?.isRunning ?? false)
                self.dnsOrphanTicks = tunnelUp ? 0 : self.dnsOrphanTicks + 1
                if self.dnsOrphanTicks >= self.dnsRestoreThreshold {
                    self.logErr("watchdog: resolver override with no tunnel — restoring system DNS")
                    let pending = self.settings.journal.dns.count
                    for line in self.settings.restoreDNS() { self.logErr(line) }
                    if self.settings.journal.dns.count < pending { SystemCommand.flushDNSCache() }
                    self.dnsRestoreThreshold = self.settings.hasDNSOverride
                        ? min(self.dnsRestoreThreshold * 2, 120) : 3
                    self.dnsOrphanTicks = 0
                }
            }
            self.stopOverrideWatchdogIfIdle()
        }
        timer.resume()
        overrideWatchdog = timer
    }

    private func stopOverrideWatchdogIfIdle() {
        guard !settings.hasProxyOverride, !settings.hasDNSOverride else { return }
        overrideWatchdog?.cancel()
        overrideWatchdog = nil
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
            // tunnel. Fall back to a direct DoH query.
            serverV4 = SystemCommand.resolveOverDoH(serverAddress)
        }
        let serverV6 = SystemCommand.resolveIPv6(serverAddress)
        // An unresolved hostname must fail loudly: without bypass routes the
        // engine's own dial follows the /1 routes back into our utun.
        if serverV4.isEmpty && serverV6.isEmpty {
            throw TunnelError(message: "Could not resolve server address: \(serverAddress)")
        }
        // A tunnel needs at least one address family that is BOTH reachable
        // on the wire (a default gateway) and resolved for the server.
        if serverV4.isEmpty && gatewayV6 == nil {
            throw TunnelError(message: "server resolves to IPv6 addresses only and this machine has no IPv6 default gateway — the tunnel would carry nothing")
        }
        for ip in serverV4 {
            // The bypass pin is load-bearing: a silently failed add sends the
            // engine's own dial back into our utun. Fail the connect instead.
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

        // 0. Pre-flight gates, before anything is spawned or routed: another
        // VPN owning the system routes, and a foreign interface holding our
        // endpoint's /24. Both would fail later anyway — after creating a
        // utun, pinning bypass routes and tearing it all down again on every
        // reconnect attempt.
        try checkRouteOwnership()
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
            // pflag long options need the double dash.
            "--device", "tun://\(name)",
            "--proxy", "socks5://\(socksHost):\(socksPort)",
            "--loglevel", "warning",
            // Set the device MTU ourselves (matches the ifconfig step below) and
            // let the gVisor netstack auto-tune TCP buffers — the default
            // fixed receive window stalls bulk throughput on high-BDP links.
            "--mtu", "\(mtu)",
            "--tcp-auto-tuning"
        ]
        // The bridge pumps every packet of the machine. User-interactive QoS
        // keeps it on the performance cores on Apple Silicon instead of being
        // throttled onto efficiency cores like background daemon work.
        proc.qualityOfService = .userInteractive
        // Watch the bridge: if tun2socks dies on its own the utun routes go
        // dead — with the kill switch armed that is a total blackhole behind a
        // still-"Connected" UI. Tear the tunnel down instead. Handler BEFORE
        // run(): a child exiting in between may not invoke it at all.
        proc.terminationHandler = { [weak self] p in
            guard let self else { return }
            self.queue.async { [self] in
                guard self.tun2socks === p else { return }
                self.logErr("tun2socks exited (\(p.terminationStatus)) — tearing the tunnel down")
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

        // 4. Split-default routes via the utun (v4), change-then-add.
        let r1 = SystemCommand.ensureNetRoute(destination: "0.0.0.0/1", interface: name, inet6: false)
        let r2 = SystemCommand.ensureNetRoute(destination: "128.0.0.0/1", interface: name, inet6: false)
        guard r1.ok, r2.ok else {
            throw TunnelError(message: "Failed to install default routes: \(r1.output)\(r2.output)")
        }

        // 4b. IPv6: tunnel it unconditionally (anti-leak). A v6 route failure
        // is fatal: browsers prefer v6, so a gap is a direct leak path.
        SystemCommand.run("/sbin/ifconfig", [name, "inet6", tunV6Address, "prefixlen", "64"])
        let r3 = SystemCommand.ensureNetRoute(destination: "::/1", interface: name, inet6: true)
        let r4 = SystemCommand.ensureNetRoute(destination: "8000::/1", interface: name, inet6: true)
        guard r3.ok, r4.ok else {
            throw TunnelError(message: "Failed to install IPv6 default routes: \(r3.output)\(r4.output)")
        }
        v6Enabled = true

        // 5. Kill switch (fail-closed) — armed last, after routes are in place.
        if killSwitch { try armKillSwitch(utun: name) }

        // 6. Keep the bypass routes pinned to the server's current IPs — on a
        // 60 s heartbeat and, more importantly, the instant the network changes.
        startResolveTimer()
        startNetworkMonitor()
    }

    /// Arm the kill switch for `utun` against the current bypass allow-list
    /// and record its pf reference in the journal. A kill switch that failed
    /// to arm must fail the connection: the user would believe they're
    /// fail-closed while egress is open. Must run on `queue`.
    private func armKillSwitch(utun name: String) throws {
        do {
            let token = try KillSwitch.arm(utun: name, serverV4: allowV4, serverV6: allowV6)
            settings.recordPFToken(token)
            killSwitchOn = true
        } catch {
            throw TunnelError(message: "kill switch failed to arm: \(error.localizedDescription)")
        }
    }

    /// Refuse to build a tunnel whose split routes would have to be stolen
    /// from another VPN client's live utun (the same ownership rule
    /// `ensureNetRoute` enforces, checked up front). Our own previous tunnel
    /// is always gone by now — torn down or swept before bring-up — so any
    /// tunnel owner here is foreign. Must run on `queue`.
    private func checkRouteOwnership() throws {
        for destination in ["0.0.0.0/1", "128.0.0.0/1"] {
            let get = SystemCommand.run("/sbin/route", ["-n", "get", "-net", destination])
            guard get.ok, let owner = SystemCommand.parseRouteGet(get.output).interface,
                  SystemCommand.isTunnelInterface(owner), SystemCommand.interfaceExists(owner) else { continue }
            throw TunnelError(message: "another VPN on \(owner) holds the system routes (owned by another tunnel) — disconnect it for the full tunnel, or use 'Route apps through Anemia'")
        }
    }

    /// The address-collision gate both bring-up paths share. Must run on `queue`.
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
            // The engine runs as root: only a binary only root can change
            // (allow-listed, root-owned, not writable by others, no symlink).
            if let refusal = EngineBinaryPolicy.refusal(
                path: enginePath, allowed: Self.awgEnginePaths(),
                facts: EngineBinaryPolicy.facts(at: enginePath)) {
                self.logErr(refusal)
                reply(false, refusal); return
            }
            _ = self.sweepStaleTunnel()
            if self.tun2socks != nil || self.utun != nil {
                self.tearDown()
            }
            do {
                try self.bringUpAWG(
                    enginePath: enginePath,
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
        enginePath: String, configScript: String,
        tunAddress: String, tunGateway: String, mtu: Int,
        serverAddress: String, killSwitch: Bool
    ) throws {
        self.serverAddress = serverAddress
        try checkRouteOwnership()
        try checkTunnelAddressCollision(tunAddress: tunAddress, tunGateway: tunGateway)
        try pinBypassRoutes(serverAddress: serverAddress)

        // 1. Spawn the engine as root (foreground) — its UAPI socket under
        //    /var/run/amneziawg can only be created by root. macOS creates
        //    TUN devices named utunN only (the engine refuses anything else:
        //    "Interface name must be utun[0-9]*"), so ask for "utun" and let
        //    the kernel pick; the engine reports the name it got through
        //    WG_TUN_NAME_FILE and names its UAPI socket after it.
        let runDir = "/var/run/amneziawg"
        try? FileManager.default.createDirectory(atPath: runDir, withIntermediateDirectories: true)
        let nameFile = "\(runDir)/anemia-\(UUID().uuidString).name"
        defer { try? FileManager.default.removeItem(atPath: nameFile) }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: enginePath)
        proc.arguments = ["-f", "utun"]
        proc.environment = ["WG_TUN_NAME_FILE": nameFile]
        // Same packet-path rationale as the tun2socks bridge.
        proc.qualityOfService = .userInteractive
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
        proc.terminationHandler = { [weak self] p in
            guard let self else { return }
            self.queue.async { [self] in
                guard self.tun2socks === p else { return }
                self.logErr("amneziawg-go exited (\(p.terminationStatus)) — tearing the tunnel down")
                self.tearDown()
            }
        }
        do { try proc.run() } catch {
            throw TunnelError(message: "failed to spawn \(enginePath): \(error.localizedDescription)")
        }
        tun2socks = proc          // supervised in the shared bridge slot…
        activeTun2socksPid = proc.processIdentifier

        // 2. The kernel-assigned utun, then a live UAPI listener named after
        //    it. A SIGKILLed engine can leave its socket file behind, refusing
        //    connects until the new engine replaces it — so wait for a connect
        //    to succeed, not for the file to exist.
        // Monotonic for the same reason `SystemCommand.run` is: a wall-clock
        // step backwards would make this wait never end, and the queue it
        // blocks is the one that also serves `stopTunnel`.
        let deadline = DispatchTime.now() + 6
        var assigned: String?
        while assigned == nil {
            if let text = try? String(contentsOfFile: nameFile, encoding: .utf8) {
                assigned = SystemCommand.parseTunNameFile(text)
            }
            guard assigned == nil else { break }
            if !proc.isRunning {
                throw TunnelError(message: "amneziawg-go exited during startup: \(tailBox.tail())")
            }
            if DispatchTime.now() > deadline {
                throw TunnelError(message: "amneziawg-go created no utun interface")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard let name = assigned, SystemCommand.interfaceExists(name) else {
            throw TunnelError(message: "engine created no utun interface")
        }
        utun = name
        let sockPath = "\(runDir)/\(name).sock"
        while true {
            if let fd = Self.connectUAPI(sockPath) {
                close(fd)
                break
            }
            if !proc.isRunning {
                throw TunnelError(message: "amneziawg-go exited during startup: \(tailBox.tail())")
            }
            if DispatchTime.now() > deadline {
                throw TunnelError(message: "engine UAPI socket \(sockPath) never appeared")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        // 3. Push the client-built config.
        try pushUAPIConfig(socketPath: sockPath, script: configScript)

        // 4. Address + MTU, split-default routes, kill switch, monitors — the
        //    same anti-leak grammar as the tun2socks path.
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
        if killSwitch { try armKillSwitch(utun: name) }
        startResolveTimer()
        startNetworkMonitor()
    }

    /// Push the `set=1` script into the engine's UAPI socket — a blocking
    /// POSIX round trip (connect → write → read `errno=`), bounded by
    /// SO_SNDTIMEO/SO_RCVTIMEO so a wedged daemon can't hang the XPC reply.
    /// Must run on `queue`.
    private func pushUAPIConfig(socketPath: String, script: String) throws {
        // The script is checked at the edge where the bytes are actually
        // written, not only in the builder that produced it — see `UAPIInput`.
        if let problem = UAPIInput.problem(script) {
            throw TunnelError(message: "refusing the UAPI script: \(problem)")
        }
        guard let fd = Self.connectUAPI(socketPath) else {
            throw TunnelError(message: "UAPI connect to \(socketPath) failed: errno \(errno)")
        }
        defer { close(fd) }
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
        // SOCK_STREAM gives no all-or-nothing on one read.
        var replyData = Data()
        var buf = [UInt8](repeating: 0, count: 512)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }          // EOF, timeout, or error — parse what we have
            replyData.append(contentsOf: buf[0..<n])
            if replyData.suffix(2) == Data("\n\n".utf8) { break }
            if replyData.count > 8 << 10 { break }
        }
        guard let reply = String(data: replyData, encoding: .utf8) else {
            throw TunnelError(message: "engine gave no UAPI reply")
        }
        guard let line = reply.split(separator: "\n").first(where: { $0.hasPrefix("errno=") }) else {
            throw TunnelError(message: "engine gave no UAPI reply")
        }
        let value = line.dropFirst("errno=".count)
        guard value == "0" else {
            throw TunnelError(message: "engine rejected the config (errno=\(value)) — check the keys against the server's AmneziaWG version")
        }
    }

    /// A stream socket connected to the engine's UAPI listener (the caller
    /// closes it), or nil with `errno` saying why.
    private static func connectUAPI(_ socketPath: String) -> Int32? {
        guard socketPath.utf8.count < 104 else {   // sockaddr_un.sun_path, NUL included
            errno = ENAMETOOLONG
            return nil
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = sa_family_t(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            dst.copyBytes(from: Array(socketPath.utf8))
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let saved = errno
            close(fd)
            errno = saved
            return nil
        }
        return fd
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

    /// Periodically re-resolve `serverAddress` and keep bypass routes pinned
    /// (see reassertBypassRoutes), and re-assert the split-default routes a
    /// third-party auto_route client may have rewritten. First tick after 60 s.
    private func startResolveTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            guard let self, let host = self.serverAddress, self.utun != nil else { return }
            // Refresh the physical gateways first: a same-link change (DHCP
            // renew, gateway swap by the router) can silently move the next-hop.
            // Keep the last known value when the read fails, for v6 too: the
            // v6 bypass pins and teardown's host-route removal both sit under
            // `if let gw6`, so one tick without a v6 default (RA renumbering,
            // or the privacy-extension route the query prefers not to answer)
            // used to strand every v6 host route of the session in the table,
            // permanently, in the pf allow-list.
            if let g4 = SystemCommand.defaultGateway() { self.gatewayV4 = g4 }
            if let g6 = SystemCommand.defaultGateway(inet6: true) { self.gatewayV6 = g6 }
            self.reassertBypassRoutes(host: host)
            self.reassertSplitRoutes()
            self.refreshSplitTunnel(resolve: true)
        }
        timer.resume()
        resolveTimer = timer
    }

    /// Kill tun2socks / amneziawg-go processes orphaned by a previous helper
    /// generation and drop the split-default routes they left. Only processes
    /// whose *executable* is one of our install locations are touched —
    /// `pgrep -f` matches the full argument string, so an editor or `tail -f`
    /// holding the path must not be swept up. Returns what it did. Must run
    /// on `queue`.
    private func sweepStaleTunnel() -> [String] {
        var report: [String] = []
        let keep = tun2socks?.processIdentifier ?? 0
        report += killOrphans(matching: "PrivilegedHelperTools/tun2socks", paths: Self.tun2socksPaths(),
                              keep: keep, label: "tun2socks")
        // Both engine kinds die BEFORE the route sweep: an orphaned
        // amneziawg-go still holds its utun, so its split routes read as live
        // and survived the sweep — then blocked the next bring-up.
        report += killOrphans(matching: "amneziawg-go", paths: Self.awgEnginePaths(),
                              keep: keep, label: "amneziawg-go")
        // Route sweep is scoped to dead utuns: a coexisting VPN client holds
        // the same prefixes legitimately on a live interface of its own.
        for row in SystemCommand.staleSplitRoutes() {
            var args = ["-n", "delete"]
            if row.inet6 { args.append("-inet6") }
            args += ["-net", row.destination, "-interface", row.iface]
            if SystemCommand.run("/sbin/route", args).ok {
                report.append("removed stale route \(row.destination) on dead \(row.iface)")
            }
        }
        return report
    }

    /// SIGTERM → grace → re-verified SIGKILL for orphans of our own binaries.
    private func killOrphans(matching pattern: String, paths: [String], keep: pid_t, label: String) -> [String] {
        let r = SystemCommand.run("/usr/bin/pgrep", ["-f", pattern])
        guard r.ok else { return [] }
        var pids: [pid_t] = []
        for line in r.output.split(separator: "\n") {
            guard let pid = pid_t(line.trimmingCharacters(in: .whitespacesAndNewlines)),
                  pid > 0, pid != keep,
                  let path = SystemCommand.executablePath(pid: pid),
                  paths.contains(path) else { continue }
            pids.append(pid)
        }
        guard !pids.isEmpty else { return [] }
        for pid in pids { kill(pid, SIGTERM) }
        // Grace, then force — re-verifying the executable right before the
        // SIGKILL: a pid freed during the grace window can be recycled by an
        // unrelated (possibly system) process.
        Thread.sleep(forTimeInterval: 0.3)
        for pid in pids where kill(pid, 0) == 0 {
            guard let path = SystemCommand.executablePath(pid: pid), paths.contains(path) else { continue }
            kill(pid, SIGKILL)
        }
        return pids.map { "killed orphaned \(label) (pid \($0))" }
    }

    /// Executable paths of a legitimate amneziawg-go engine we may sweep:
    /// only this helper's own install locations — a Homebrew binary may be
    /// running the user's own independent WireGuard session.
    private static func awgEnginePaths() -> [String] {
        var paths = [EngineBinaryPolicy.installedAWGEngine]
        if let env = ProcessInfo.processInfo.environment["LOADER_AWG_PATH"] { paths.append(env) }
        paths.append(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("amneziawg-go").path)
        return paths
    }

    /// Executable paths a legitimate tun2socks bridge can run from (mirrors
    /// `locateTun2socks`).
    private static func tun2socksPaths() -> [String] {
        var paths = ["/Library/PrivilegedHelperTools/tun2socks"]
        if let env = ProcessInfo.processInfo.environment["LOADER_TUN2SOCKS_PATH"] { paths.append(env) }
        paths.append(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("tun2socks").path)
        return paths
    }

    /// Re-assert the split-default routes via change-then-add. Must run on `queue`.
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
    /// current physical gateways, growing the kill switch allow-list when the
    /// server's domain rotated to new addresses. Must run on `queue`.
    private func reassertBypassRoutes(host: String) {
        guard let gw4 = gatewayV4 else { return }
        var allowlistGrew = false
        // Cap the allow-list: a CDN-backed domain can rotate dozens of
        // addresses per hour; 32 host routes cover any realistic rotation.
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
        // Without a re-arm pf keeps dropping the engine's dial to the new
        // address and the tunnel dies mid-session under the kill switch.
        if allowlistGrew, killSwitchOn, let tun = utun {
            KillSwitch.rearm(utun: tun, serverV4: allowV4, serverV6: allowV6)
        }
    }

    private func repinRoute(ip: String, gateway: String, inet6: Bool) {
        let r = SystemCommand.ensureHostRoute(host: ip, gateway: gateway, inet6: inet6)
        if !r.ok {
            logErr("reassert: bypass route \(ip) via \(gateway) failed: \(r.output)")
        }
    }

    /// Route split-tunnel destinations via the physical gateways. `resolve`
    /// refreshes the domains' addresses first — new ones are added, known ones
    /// kept (deleting a route mid-flight would cut a live connection).
    /// Returns failures and whether the address set grew. Must run on `queue`.
    private func pinSplitDestinations(resolve: Bool) -> (failures: [String], grew: Bool) {
        guard !splitNetV4.isEmpty || !splitNetV6.isEmpty || !splitDomains.isEmpty else { return ([], false) }
        guard let gw4 = gatewayV4 else { return (["no physical gateway"], false) }
        var failures: [String] = []
        var grew = false
        if resolve {
            for name in splitDomains {
                for ip in SystemCommand.resolveIPv4(name)
                where !DirectResolver.isFakeIP(ip) && !splitHostV4.contains(ip) && splitHostV4.count < 256 {
                    splitHostV4.append(ip)
                    grew = true
                }
                guard gatewayV6 != nil else { continue }
                for ip in SystemCommand.resolveIPv6(name) where !splitHostV6.contains(ip) && splitHostV6.count < 256 {
                    splitHostV6.append(ip)
                    grew = true
                }
            }
        }
        var installed = splitRoutes
        func pin(_ destination: String, network: Bool, inet6: Bool, gateway: String) {
            let known = installed.contains { $0.destination == destination && $0.inet6 == inet6 }
            if !known, SystemCommand.isDirectlyConnected(destination, network: network, inet6: inet6) { return }
            let r = network
                ? SystemCommand.ensureGatewayRoute(destination: destination, gateway: gateway, inet6: inet6)
                : SystemCommand.ensureHostRoute(host: destination, gateway: gateway, inet6: inet6)
            if r.ok {
                if !known { installed.append((destination, network, inet6)) }
            } else {
                failures.append("\(destination): \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        for net in splitNetV4 { pin(net, network: true, inet6: false, gateway: gw4) }
        // The server's own addresses keep their bypass route untouched.
        for ip in splitHostV4 where !bypassV4.contains(ip) { pin(ip, network: false, inet6: false, gateway: gw4) }
        if let gw6 = gatewayV6 {
            for net in splitNetV6 { pin(net, network: true, inet6: true, gateway: gw6) }
            for ip in splitHostV6 where !bypassV6.contains(ip) { pin(ip, network: false, inet6: true, gateway: gw6) }
        }
        splitRoutes = installed
        return (failures, grew)
    }

    /// Re-pin split-tunnel routes (link change, heartbeat) and grow the kill
    /// switch allow-list when re-resolution found new addresses. Must run on
    /// `queue`.
    private func refreshSplitTunnel(resolve: Bool) {
        let result = pinSplitDestinations(resolve: resolve)
        for failure in result.failures { logErr("split tunnel: \(failure)") }
        if result.grew, killSwitchOn, let tun = utun {
            KillSwitch.rearm(utun: tun, serverV4: allowV4, serverV6: allowV6)
        }
    }

    /// Remove the routes this session installed and forget the lists. Must
    /// run on `queue`.
    private func removeSplitRoutes() {
        for route in splitRoutes {
            var args = ["-n", "delete"]
            if route.inet6 { args.append("-inet6") }
            args += [route.network ? "-net" : "-host", route.destination]
            SystemCommand.run("/sbin/route", args)
        }
        splitRoutes = []
        splitNetV4 = []
        splitNetV6 = []
        splitDomains = []
        splitHostV4 = []
        splitHostV6 = []
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

    /// A network change fired: re-detect the physical gateways and re-pin the
    /// bypass + split routes. Runs on `queue`.
    private func handleNetworkChange() {
        guard utun != nil, let host = serverAddress else { return }
        if let g4 = SystemCommand.defaultGateway() { gatewayV4 = g4 }
        // Keep-last, exactly as the 60 s timer does (see the comment there):
        // teardown's v6 host-route removal and the v6 re-pin both sit under
        // `if let gw6`, so one unreadable v6 default during a link change used
        // to drop the gateway and strand every v6 bypass route of the session
        // in the table permanently. A link change is precisely when the query
        // is likeliest to fail — the new interface has not settled yet.
        if let g6 = SystemCommand.defaultGateway(inet6: true) { gatewayV6 = g6 }
        reassertBypassRoutes(host: host)
        reassertSplitRoutes()
        refreshSplitTunnel(resolve: false)
    }

    /// Tear the session down and restore the machine. Idempotent. Must run
    /// on `queue`.
    func tearDown() {
        resolveTimer?.cancel()
        resolveTimer = nil
        stopNetworkMonitor()
        serverAddress = nil
        // DNS first: with the utun going away, a resolver pointed at the
        // tunnel gateway would leave the machine name-resolution-dead.
        for line in settings.restoreDNS() { logErr(line) }
        // The SOCKS override points apps at this session's engine port.
        for line in settings.restoreProxy() { logErr(line) }
        stopOverrideWatchdogIfIdle()
        if killSwitchOn || settings.journal.pfToken != nil {
            let token = settings.pfRecovery().token
            KillSwitch.disarm(token: token)
            settings.clearPFRecovery()
            killSwitchOn = false
        }
        let tunName = utun
        if let name = utun {
            SystemCommand.run("/sbin/route", ["-n", "delete", "-net", "0.0.0.0/1", "-interface", name])
            SystemCommand.run("/sbin/route", ["-n", "delete", "-net", "128.0.0.0/1", "-interface", name])
            if v6Enabled {
                SystemCommand.run("/sbin/route", ["-n", "delete", "-inet6", "-net", "::/1", "-interface", name])
                SystemCommand.run("/sbin/route", ["-n", "delete", "-inet6", "-net", "8000::/1", "-interface", name])
            }
        }
        removeSplitRoutes()
        if let gw4 = gatewayV4 {
            for ip in bypassV4 { SystemCommand.run("/sbin/route", ["-n", "delete", "-host", ip, gw4]) }
        }
        if let gw6 = gatewayV6 {
            for ip in bypassV6 { SystemCommand.run("/sbin/route", ["-n", "delete", "-inet6", "-host", ip, gw6]) }
        }
        // Nil first: the termination handler watches `tun2socks === proc` to
        // distinguish spontaneous death from this intentional teardown.
        let proc = tun2socks
        tun2socks = nil
        activeTun2socksPid = 0
        if let proc, proc.isRunning {
            proc.terminate()
            // Bounded wait: SIGTERM, a short grace period, then SIGKILL — a
            // wedged bridge must never hang the XPC reply.
            let deadline = DispatchTime.now() + 3
            while proc.isRunning && DispatchTime.now() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            // Re-verify identity before the SIGKILL (pid recycling) — with both
            // paths resolved, see `SystemCommand.pid(_:isExecutable:)`: the raw
            // compare against `executableURL.path` was false for an engine
            // launched through a symlink or a `/tmp`-style alias, so this rung
            // silently never fired and a wedged bridge survived teardown.
            if proc.isRunning, let url = proc.executableURL,
               SystemCommand.pid(proc.processIdentifier, isExecutable: url.path) {
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
        // A machine that connected under a helper predating the add-first fix
        // carries the real default route on OUR utun (that `route change`
        // rewrite), and this teardown used to delete only the 0/1 + 128/1 pair
        // that never existed — so the interface went away and the default stayed
        // pointing at it: connected = fine, disconnected = nothing loads. Drop
        // it by name once the bridge is dead, not before: while the utun still
        // carries traffic a deleted default would leak that traffic to the
        // physical gateway. If the kernel already purged the row with the
        // interface, the delete is a no-op.
        if let name = tunName {
            SystemCommand.run("/sbin/route", ["-n", "delete", "-net", "default", "-interface", name])
            SystemCommand.run("/sbin/route", ["-n", "delete", "-inet6", "-net", "default", "-interface", name])
        }
        // …and now that nothing of ours is running, sweep the pins the ledger
        // does NOT know about. `restoreDNS`/`restoreProxy` above undo exactly
        // what this helper recorded; a resolver left on our tunnel range by an
        // older generation (0.9.2 and earlier captured their own leftover as
        // the "prior" value, and a pre-journal helper wrote pins with no
        // record at all) is not in that ledger, so before this line the
        // machine stayed unable to resolve anything until the next helper
        // launch — a reboot — or the user ran «Reset network». That is the
        // "everything stopped loading after I disconnected" report.
        // Legacy ranges stay off: a dead 198.18.0.x resolver is just as likely
        // somebody else's fake-IP client, and tearing that down on our
        // disconnect would be our own kind of leftover.
        for line in settings.sweepDeadPins(includeProxies: true, includeLegacyRanges: false,
                                              ourTunnelIsGoingAway: true) {
            logErr("teardown sweep: \(line)")
        }
    }

    // MARK: - Helpers

    private func waitForInterface(_ name: String, timeout: TimeInterval) -> Bool {
        let deadline = DispatchTime.now() + timeout
        while DispatchTime.now() < deadline {
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
