import Foundation
import LoaderCore
import LoaderShared

/// The system calls ``SystemSettingsGuard`` needs. A protocol so the whole
/// apply → crash → relaunch → restore cycle is testable against a fake system.
protocol NetworkSettingsShell {
    /// Every service that exists, enabled or not — a ledger entry for a
    /// service that was deleted since can be forgotten.
    func allServiceNames() -> [String]
    /// Services an override may touch (enabled, hardware-backed).
    func overridableServices() -> [String]
    func dnsServers(service: String) -> [String]?
    /// Empty `servers` = automatic (DHCP).
    func setDNSServers(service: String, servers: [String]) -> Bool
    func socksProxy(service: String) -> ProxySetting?
    func setSocksProxy(service: String, setting: ProxySetting) -> Bool
    func liveIPv4Addresses() -> Set<String>
    func isLoopbackPortLive(_ port: Int) -> Bool
}

/// `networksetup`-backed shell used by the running helper.
struct LiveNetworkSettingsShell: NetworkSettingsShell {
    private func serviceOrder() -> [NetworkSettingsPolicy.NetworkService] {
        NetworkSettingsPolicy.parseServiceOrder(
            SystemCommand.run("/usr/sbin/networksetup", ["-listnetworkserviceorder"]).output)
    }

    func allServiceNames() -> [String] {
        let names = serviceOrder().map(\.name)
        return names.isEmpty ? SystemCommand.allNetworkServices() : names
    }

    func overridableServices() -> [String] {
        let order = serviceOrder()
        // Output-format drift: fall back to every enabled service rather than
        // refusing to work at all.
        return order.isEmpty ? SystemCommand.enabledNetworkServices() : NetworkSettingsPolicy.overridableServices(order)
    }

    func dnsServers(service: String) -> [String]? {
        SystemCommand.getDNSServers(service: service)
    }

    func setDNSServers(service: String, servers: [String]) -> Bool {
        SystemCommand.run("/usr/sbin/networksetup",
                          ["-setdnsservers", service] + (servers.isEmpty ? ["empty"] : servers)).ok
    }

    func socksProxy(service: String) -> ProxySetting? {
        guard let p = SystemCommand.getSocksProxy(service: service) else { return nil }
        return ProxySetting(enabled: p.enabled, host: p.host, port: Int(p.port) ?? 0)
    }

    func setSocksProxy(service: String, setting: ProxySetting) -> Bool {
        if setting.enabled, !setting.host.isEmpty, (1...65535).contains(setting.port) {
            let a = SystemCommand.run("/usr/sbin/networksetup",
                                      ["-setsocksfirewallproxy", service, setting.host, "\(setting.port)"])
            let b = SystemCommand.run("/usr/sbin/networksetup", ["-setsocksfirewallproxystate", service, "on"])
            return a.ok && b.ok
        }
        return SystemCommand.run("/usr/sbin/networksetup", ["-setsocksfirewallproxystate", service, "off"]).ok
    }

    func liveIPv4Addresses() -> Set<String> {
        let holders = SystemCommand.parseInetHolders(SystemCommand.run("/sbin/ifconfig", ["-a"]).output)
        return Set(holders.values.flatMap { $0 })
    }

    func isLoopbackPortLive(_ port: Int) -> Bool {
        PortFinder.canConnect(port)
    }
}

/// Applies and reverts the persistent network overrides — the system resolver
/// and the SOCKS proxy — strictly through ``NetworkJournal``. See the ledger's
/// contract; this class is its only writer. Not thread-safe: the helper drives
/// it from its serial state queue.
final class SystemSettingsGuard {
    private let store: NetworkJournalStore
    private let shell: NetworkSettingsShell
    private let log: (String) -> Void
    private(set) var journal: NetworkJournal

    init(store: NetworkJournalStore, shell: NetworkSettingsShell, log: @escaping (String) -> Void) {
        self.store = store
        self.shell = shell
        self.log = log
        journal = store.load()
        if store.hasLegacyFiles {
            // The merged ledger must be on disk before the legacy files go.
            do {
                try store.save(journal)
                store.removeLegacyFiles()
                log("migrated pre-0.8 backup files into the network journal")
            } catch {
                log("journal migration deferred: \(error)")
            }
        }
    }

    var hasDNSOverride: Bool { !journal.dns.isEmpty }
    var hasProxyOverride: Bool { !journal.proxy.isEmpty }
    /// Loopback port the recorded proxy override points at, when known.
    var proxyOverridePort: Int? { journal.proxy.first { $0.applied.port > 0 }?.applied.port }

    // MARK: - System resolver

    /// Point every overridable service's resolver at `servers`.
    func applyDNS(servers: [String]) -> (ok: Bool, error: String?) {
        let services = shell.overridableServices()
        guard !services.isEmpty else { return (false, "no active network services") }
        let live = shell.liveIPv4Addresses()
        var planned = journal
        var targets: [String] = []
        for service in services {
            // A service whose resolvers can't be read is left alone: changing
            // it without a restorable record is exactly how DNS got stranded.
            guard let current = shell.dnsServers(service: service) else {
                log("DNS: skipping \(service) — current resolvers unreadable")
                continue
            }
            if let i = planned.dns.firstIndex(where: { $0.service == service }) {
                planned.dns[i].applied = servers
            } else {
                planned.dns.append(.init(service: service,
                                         prior: NetworkSettingsPolicy.sanitizePriorDNS(current, liveIPv4: live),
                                         applied: servers))
            }
            targets.append(service)
        }
        guard !targets.isEmpty else { return (false, "could not read the resolver state of any service") }
        do {
            try store.save(planned)
            journal = planned
        } catch {
            return (false, "network journal write failed (\(error)) — refusing to change DNS without a restore record")
        }
        let done = targets.filter { shell.setDNSServers(service: $0, servers: servers) }
        return done.isEmpty ? (false, "failed to set DNS on any service") : (true, nil)
    }

    /// Put every recorded service's resolvers back. Entries whose restore
    /// fails stay in the ledger for the next attempt.
    @discardableResult
    func restoreDNS() -> [String] {
        guard !journal.dns.isEmpty else { return [] }
        let existing = Set(shell.allServiceNames())
        var remaining: [NetworkJournal.DNSEntry] = []
        var report: [String] = []
        for entry in journal.dns {
            let action = NetworkSettingsPolicy.dnsRestoreAction(
                entry: entry, current: shell.dnsServers(service: entry.service),
                serviceExists: existing.contains(entry.service))
            switch action {
            case .restore(let prior):
                if shell.setDNSServers(service: entry.service, servers: prior) {
                    report.append("DNS \(entry.service) → \(prior.isEmpty ? "automatic" : prior.joined(separator: ", "))")
                } else {
                    remaining.append(entry)
                    report.append("DNS \(entry.service): restore failed — will retry")
                }
            case .forget:
                report.append("DNS \(entry.service): changed since the override — left as is")
            case .retryLater:
                remaining.append(entry)
                report.append("DNS \(entry.service): unreadable — will retry")
            }
        }
        journal.dns = remaining
        persist()
        return report
    }

    // MARK: - SOCKS proxy

    func applyProxy(host: String, port: Int) -> (ok: Bool, error: String?) {
        let services = shell.overridableServices()
        guard !services.isEmpty else { return (false, "no active network services") }
        let applied = ProxySetting(enabled: true, host: host, port: port)
        var planned = journal
        var targets: [String] = []
        for service in services {
            guard let current = shell.socksProxy(service: service) else {
                log("proxy: skipping \(service) — current proxy unreadable")
                continue
            }
            if let i = planned.proxy.firstIndex(where: { $0.service == service }) {
                planned.proxy[i].applied = applied
            } else {
                let prior = NetworkSettingsPolicy.sanitizePriorProxy(
                    current, applyingPort: port, isPortLive: shell.isLoopbackPortLive)
                planned.proxy.append(.init(service: service, prior: prior, applied: applied))
            }
            targets.append(service)
        }
        guard !targets.isEmpty else { return (false, "could not read the proxy state of any service") }
        do {
            try store.save(planned)
            journal = planned
        } catch {
            return (false, "network journal write failed (\(error)) — refusing to change the proxy without a restore record")
        }
        let done = targets.filter { shell.setSocksProxy(service: $0, setting: applied) }
        return done.isEmpty ? (false, "failed to set the proxy on any service") : (true, nil)
    }

    @discardableResult
    func restoreProxy() -> [String] {
        guard !journal.proxy.isEmpty else { return [] }
        let existing = Set(shell.allServiceNames())
        var remaining: [NetworkJournal.ProxyEntry] = []
        var report: [String] = []
        for entry in journal.proxy {
            let action = NetworkSettingsPolicy.proxyRestoreAction(
                entry: entry, current: shell.socksProxy(service: entry.service),
                serviceExists: existing.contains(entry.service))
            switch action {
            case .restore(let prior):
                if shell.setSocksProxy(service: entry.service, setting: prior) {
                    report.append("proxy \(entry.service) → \(prior.enabled ? "\(prior.host):\(prior.port)" : "off")")
                } else {
                    remaining.append(entry)
                    report.append("proxy \(entry.service): restore failed — will retry")
                }
            case .forget:
                report.append("proxy \(entry.service): changed since the override — left as is")
            case .retryLater:
                remaining.append(entry)
                report.append("proxy \(entry.service): unreadable — will retry")
            }
        }
        journal.proxy = remaining
        persist()
        return report
    }

    // MARK: - pf enable reference

    func recordPFToken(_ token: String) {
        journal.pfToken = token
        persist()
    }

    /// Hand the recorded pf state to recovery and clear it from the ledger.
    func takePFRecovery() -> (token: String?, legacyMainRuleset: Bool) {
        let result = (journal.pfToken, journal.legacyMainRuleset)
        if result.0 != nil || result.1 {
            journal.pfToken = nil
            journal.legacyMainRuleset = false
            persist()
        }
        return result
    }

    // MARK: - Dead pins without a ledger entry

    /// Reset settings that can't possibly work and aren't in the ledger: a
    /// resolver on a tunnel range nothing local holds (left by a helper
    /// generation that kept no usable record), and — on explicit repair only —
    /// a loopback proxy nothing listens on. Proxies are never swept at launch:
    /// at boot a user's own local proxy app hasn't started yet and would read
    /// as dead.
    func sweepDeadPins(includeProxies: Bool, includeLegacyRanges: Bool) -> [String] {
        var report: [String] = []
        let live = shell.liveIPv4Addresses()
        let trackedDNS = Set(journal.dns.map(\.service))
        let trackedProxy = Set(journal.proxy.map(\.service))
        for service in shell.allServiceNames() {
            if !trackedDNS.contains(service), let dns = shell.dnsServers(service: service),
               NetworkSettingsPolicy.isDeadDNSPin(dns, liveIPv4: live, includeLegacy: includeLegacyRanges) {
                report.append(shell.setDNSServers(service: service, servers: [])
                    ? "DNS \(service): dead tunnel resolver \(dns.joined(separator: ", ")) → automatic"
                    : "DNS \(service): could not reset dead resolver \(dns.joined(separator: ", "))")
            }
            if includeProxies, !trackedProxy.contains(service), let proxy = shell.socksProxy(service: service),
               NetworkSettingsPolicy.isDeadProxyPin(proxy, isPortLive: shell.isLoopbackPortLive) {
                report.append(shell.setSocksProxy(service: service, setting: .off)
                    ? "proxy \(service): dead loopback proxy \(proxy.host):\(proxy.port) → off"
                    : "proxy \(service): could not switch off dead proxy \(proxy.host):\(proxy.port)")
            }
        }
        return report
    }

    /// Ledger contents for diagnostics.
    func summary() -> [String] {
        var lines: [String] = []
        for e in journal.dns {
            lines.append("DNS override on \(e.service): \(e.applied.isEmpty ? "unknown" : e.applied.joined(separator: ", ")) (restores to \(e.prior.isEmpty ? "automatic" : e.prior.joined(separator: ", ")))")
        }
        for e in journal.proxy {
            lines.append("proxy override on \(e.service): \(e.applied.host):\(e.applied.port) (restores to \(e.prior.enabled ? "\(e.prior.host):\(e.prior.port)" : "off"))")
        }
        if let t = journal.pfToken { lines.append("pf kill-switch reference held (token \(t))") }
        if journal.legacyMainRuleset { lines.append("legacy main-ruleset kill switch pending repair") }
        return lines
    }

    /// Remove the ledger file entirely (helper uninstall, after a full restore).
    func discard() {
        journal = NetworkJournal()
        unlink(store.path)
    }

    private func persist() {
        do { try store.save(journal) } catch { log("network journal write failed: \(error)") }
    }
}
