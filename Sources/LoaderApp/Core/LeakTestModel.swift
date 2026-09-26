import Foundation
import LoaderCore

/// Leak Test: the address sites see and the resolvers answering this Mac's
/// lookups, compared with the address the provider gave — asked over the
/// physical interface, around the tunnel.
@MainActor
final class LeakTestModel: ObservableObject {
    struct Report {
        var date = Date()
        /// The server the check went through; nil with the VPN off.
        var serverID: UUID?
        /// Only proxy-aware apps used the VPN (no system tunnel).
        var socksOnly = false
        /// What sites see.
        var exit: LeakCheck.IPInfo?
        /// The provider's own address. With the VPN off it's `exit`.
        var direct: LeakCheck.IPInfo?
        /// Nil: IPv6 doesn't get out at all.
        var ipv6: LeakCheck.IPInfo?
        /// Nil when the DNS test didn't answer.
        var dns: [LeakCheck.DNSServer]?
        var findings: [LeakCheck.Finding] = []

        enum Verdict: Equatable {
            /// The VPN is off.
            case unprotected
            /// The address check itself failed.
            case failed
            /// The exit is hidden; without the provider's address there is
            /// nothing to compare with (the kill switch blocks the direct
            /// request, typically).
            case unknown
            case leaks
            case clean
        }

        var verdict: Verdict {
            guard exit != nil else { return .failed }
            guard serverID != nil else { return .unprotected }
            if !findings.isEmpty { return .leaks }
            return direct == nil ? .unknown : .clean
        }

        var bypassed: Bool { findings.contains(.tunnelBypassed) }

        var ipv6Leak: LeakCheck.IPInfo? {
            for case .ipv6Leak(let info) in findings { return info }
            return nil
        }

        var dnsLeak: [LeakCheck.DNSServer] {
            for case .dnsLeak(let servers) in findings { return servers }
            return []
        }
    }

    @Published private(set) var report: Report?
    /// What the running test is doing; nil when idle.
    @Published private(set) var step: String?

    var isRunning: Bool { step != nil }

    #if DEBUG
    /// Headless snapshots (Tests/LoaderAppSnapshotTests).
    func showPreview(_ report: Report) {
        self.report = report
    }
    #endif

    /// Whether the last report still describes the connection: same server,
    /// not too old.
    func isCurrent(server: UUID?) -> Bool {
        guard let report else { return false }
        return report.serverID == server && Date().timeIntervalSince(report.date) < 30 * 60
    }

    /// `server`: the session's server, nil while disconnected. `proxy`: the
    /// engine's SOCKS inbound when the system tunnel doesn't carry the app.
    func run(server: UUID?, proxy: LocalProxy?) async {
        guard step == nil else { return }
        step = "Finding the address sites see…"
        defer { step = nil }
        var fresh = Report(serverID: server, socksOnly: server != nil && proxy != nil)
        // A fresh session: connections kept alive from before the VPN came
        // up would still go around it.
        let session = URLSession(configuration: LocalProxy.sessionConfiguration(proxy))
        defer { session.finishTasksAndInvalidate() }

        async let exit = try? LeakCheck.publicAddress(session: session)
        async let ipv6 = try? LeakCheck.publicAddress(ipv6: true, session: session)
        var direct: LeakCheck.IPInfo?
        if server != nil {
            direct = await Self.directAddress()
        }
        fresh.exit = await exit
        fresh.ipv6 = await ipv6
        fresh.direct = server == nil ? fresh.exit : direct

        step = "Checking DNS…"
        fresh.dns = try? await LeakCheck.dnsServers(session: session) { name in await Self.lookUp(name) }
        if server != nil {
            fresh.findings = LeakCheck.findings(exit: fresh.exit, direct: fresh.direct,
                                                ipv6: fresh.ipv6, dns: fresh.dns ?? [])
        }
        fresh.date = Date()
        report = fresh
    }

    // MARK: - Around the tunnel

    /// The provider's address: ip.sb (then Cloudflare) through curl bound to
    /// the physical interface, which the tunnel's routes don't capture. Nil
    /// when there's no physical interface or the kill switch blocks it.
    nonisolated private static func directAddress() async -> LeakCheck.IPInfo? {
        guard let interface = PhysicalInterface.primary() else { return nil }
        if let data = await curl(interface: interface, url: "https://api-ipv4.ip.sb/geoip"),
           let info = try? LeakCheck.parseIPSB(data) {
            return info
        }
        if let data = await curl(interface: interface, url: "https://www.cloudflare.com/cdn-cgi/trace") {
            return try? LeakCheck.parseTrace(data)
        }
        return nil
    }

    nonisolated private static func curl(interface: String, url: String) async -> Data? {
        await Task.detached(priority: .userInitiated) { () -> Data? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = ["--interface", interface, "-s", "--max-time", "6",
                                 "-A", "Anemia", url]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 && !data.isEmpty ? data : nil
        }.value
    }

    /// Looks `name` up through the system resolver, the way any app here
    /// would — giving up after a few seconds.
    nonisolated private static func lookUp(_ name: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = LockedFlag()
            let finish: @Sendable () -> Void = {
                if resumed.setOnce() { continuation.resume() }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                var result: UnsafeMutablePointer<addrinfo>?
                if getaddrinfo(name, nil, nil, &result) == 0, let result {
                    freeaddrinfo(result)
                }
                finish()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { finish() }
        }
    }
}

/// True the first time only.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false

    func setOnce() -> Bool {
        lock.withLock {
            defer { set = true }
            return !set
        }
    }
}
