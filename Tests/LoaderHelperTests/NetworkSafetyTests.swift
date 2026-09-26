import Foundation
import Testing
import LoaderShared
@testable import LoaderHelper

// MARK: - Fake system

/// In-memory stand-in for networksetup / ifconfig / the loopback port probe.
/// The full apply → crash → next-generation restore cycle runs against it.
final class FakeSystem: NetworkSettingsShell, @unchecked Sendable {
    struct Service { var device: String; var enabled: Bool }

    var order: [String]
    var services: [String: Service]
    var dns: [String: [String]] = [:]
    var proxy: [String: ProxySetting] = [:]
    var live: Set<String> = ["192.168.0.103"]
    var listening: Set<Int> = []
    var unreadable: Set<String> = []
    var failingWrites: Set<String> = []

    /// This Mac's real layout: two hardware services, a bridge, and a
    /// device-less VPN service (a third-party client).
    init() {
        order = ["USB 10/100/1000 LAN", "Thunderbolt Bridge", "Wi-Fi", "Happ"]
        services = [
            "USB 10/100/1000 LAN": Service(device: "en5", enabled: true),
            "Thunderbolt Bridge": Service(device: "bridge0", enabled: true),
            "Wi-Fi": Service(device: "en0", enabled: true),
            "Happ": Service(device: "", enabled: true)
        ]
    }

    func allServiceNames() -> [String] { order }
    func overridableServices() -> [String] {
        order.filter { services[$0]!.enabled && !services[$0]!.device.isEmpty }
    }
    func dnsServers(service: String) -> [String]? {
        guard services[service] != nil, !unreadable.contains(service) else { return nil }
        return dns[service] ?? []
    }
    func setDNSServers(service: String, servers: [String]) -> Bool {
        guard services[service] != nil, !failingWrites.contains(service) else { return false }
        dns[service] = servers
        return true
    }
    func socksProxy(service: String) -> ProxySetting? {
        guard services[service] != nil, !unreadable.contains(service) else { return nil }
        return proxy[service] ?? .off
    }
    func setSocksProxy(service: String, setting: ProxySetting) -> Bool {
        guard services[service] != nil, !failingWrites.contains(service) else { return false }
        if setting.enabled {
            proxy[service] = setting
        } else {
            // networksetup keeps host/port configured when switching off.
            let old = proxy[service] ?? .off
            proxy[service] = ProxySetting(enabled: false, host: old.host, port: old.port)
        }
        return true
    }
    func liveIPv4Addresses() -> Set<String> { live }
    func isLoopbackPortLive(_ port: Int) -> Bool { listening.contains(port) }
}

private func tempStore() -> NetworkJournalStore {
    NetworkJournalStore(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("anemia-journal-\(UUID().uuidString)").path)
}

private let gateway = LoaderIdentifiers.defaultTunGateway

// MARK: - Journal storage

struct NetworkJournalTests {

    @Test func testRoundTripAndPrivatePermissions() throws {
        let store = tempStore()
        var j = NetworkJournal()
        j.dns = [.init(service: "Wi-Fi", prior: ["1.1.1.1"], applied: [gateway])]
        j.proxy = [.init(service: "Wi-Fi", prior: .off, applied: ProxySetting(enabled: true, host: "127.0.0.1", port: 10808))]
        j.pfToken = "123"
        try store.save(j)
        #expect(store.load() == j)
        let attrs = try FileManager.default.attributesOfItem(atPath: store.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: store.directory)
        #expect((dirAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func testMissingOrCorruptFileIsAnEmptyLedger() throws {
        let store = tempStore()
        #expect(store.load().isEmpty)
        try FileManager.default.createDirectory(atPath: store.directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: URL(fileURLWithPath: store.path))
        #expect(store.load().isEmpty)
    }

    @Test func testMigratesLegacyBackupsWithoutTheirLeftoverPins() throws {
        let store = tempStore()
        try FileManager.default.createDirectory(atPath: store.directory, withIntermediateDirectories: true)
        // The pre-0.8 failure: a backup that captured the tunnel resolver and
        // the engine's proxy as "the user's settings".
        try Data(#"{"Wi-Fi": ["172.28.0.2"], "USB 10/100/1000 LAN": ["9.9.9.9"]}"#.utf8)
            .write(to: URL(fileURLWithPath: store.directory + "/dns.backup.json"))
        try Data(#"{"Wi-Fi": ["1", "127.0.0.1", "10808"]}"#.utf8)
            .write(to: URL(fileURLWithPath: store.directory + "/proxy.backup.json"))
        try Data("4242\n".utf8).write(to: URL(fileURLWithPath: store.directory + "/killswitch.token"))

        let j = store.load()
        #expect(j.dns.first { $0.service == "Wi-Fi" }?.prior == [])
        #expect(j.dns.first { $0.service == "USB 10/100/1000 LAN" }?.prior == ["9.9.9.9"])
        #expect(j.proxy.first?.prior == .off)
        #expect(j.proxy.first?.applied.port == 0)
        #expect(j.pfToken == "4242")
        #expect(j.legacyMainRuleset)

        // The guard persists the merge, then removes the legacy files.
        _ = SystemSettingsGuard(store: store, shell: FakeSystem(), log: { _ in })
        #expect(!store.hasLegacyFiles)
        #expect(store.load().pfToken == "4242")
    }
}

// MARK: - Policy

struct NetworkSettingsPolicyTests {

    @Test func testParsesServiceOrderAndSkipsVPNAndDisabledServices() {
        let output = """
        An asterisk (*) denotes that a network service is disabled.
        (1) USB 10/100/1000 LAN
        (Hardware Port: USB 10/100/1000 LAN, Device: en5)

        (2) Thunderbolt Bridge
        (Hardware Port: Thunderbolt Bridge, Device: bridge0)

        (3) Wi-Fi
        (Hardware Port: Wi-Fi, Device: en0)

        (4) Happ
        (Hardware Port: su.ffg.happ, Device: )

        (*) Old iPhone USB
        (Hardware Port: iPhone USB, Device: en7)
        """
        let services = NetworkSettingsPolicy.parseServiceOrder(output)
        #expect(services.map(\.name) == ["USB 10/100/1000 LAN", "Thunderbolt Bridge", "Wi-Fi", "Happ", "Old iPhone USB"])
        #expect(services.first { $0.name == "Happ" }?.device == "")
        #expect(services.first { $0.name == "Old iPhone USB" }?.enabled == false)
        #expect(NetworkSettingsPolicy.overridableServices(services) == ["USB 10/100/1000 LAN", "Thunderbolt Bridge", "Wi-Fi"])
    }

    @Test func testPriorDNSNeverRecordsOurOwnResolvers() {
        #expect(NetworkSettingsPolicy.sanitizePriorDNS([gateway], liveIPv4: []) == [])
        #expect(NetworkSettingsPolicy.sanitizePriorDNS(["172.29.0.2"], liveIPv4: []) == [])
        #expect(NetworkSettingsPolicy.sanitizePriorDNS(["1.1.1.1", "8.8.8.8"], liveIPv4: []) == ["1.1.1.1", "8.8.8.8"])
        // Legacy range: a leftover while nothing holds it, a real resolver
        // while a fake-IP VPN is up on it.
        #expect(NetworkSettingsPolicy.sanitizePriorDNS(["198.18.0.2"], liveIPv4: ["192.168.0.5"]) == [])
        #expect(NetworkSettingsPolicy.sanitizePriorDNS(["198.18.0.2"], liveIPv4: ["198.18.0.1"]) == ["198.18.0.2"])
    }

    @Test func testPriorProxyNeverRecordsAnEnginePin() {
        let live: (Int) -> Bool = { $0 == 7890 }
        let engine = ProxySetting(enabled: true, host: "127.0.0.1", port: 49152)
        #expect(NetworkSettingsPolicy.sanitizePriorProxy(engine, applyingPort: 49152, isPortLive: { _ in true }) == .off)
        let defaultPort = ProxySetting(enabled: true, host: "127.0.0.1", port: LoaderIdentifiers.defaultSocksPort)
        #expect(NetworkSettingsPolicy.sanitizePriorProxy(defaultPort, applyingPort: 1, isPortLive: { _ in true }) == .off)
        let dead = ProxySetting(enabled: true, host: "localhost", port: 51000)
        #expect(NetworkSettingsPolicy.sanitizePriorProxy(dead, applyingPort: 1, isPortLive: live) == .off)
        let usersOwn = ProxySetting(enabled: true, host: "127.0.0.1", port: 7890)
        #expect(NetworkSettingsPolicy.sanitizePriorProxy(usersOwn, applyingPort: 10808, isPortLive: live) == usersOwn)
        let corporate = ProxySetting(enabled: true, host: "proxy.corp.example", port: 1080)
        #expect(NetworkSettingsPolicy.sanitizePriorProxy(corporate, applyingPort: 10808, isPortLive: live) == corporate)
    }

    @Test func testDNSRestoreDecisions() {
        let entry = NetworkJournal.DNSEntry(service: "Wi-Fi", prior: ["1.1.1.1"], applied: [gateway])
        #expect(NetworkSettingsPolicy.dnsRestoreAction(entry: entry, current: [gateway], serviceExists: true) == .restore(["1.1.1.1"]))
        #expect(NetworkSettingsPolicy.dnsRestoreAction(entry: entry, current: ["9.9.9.9"], serviceExists: true) == .forget)
        #expect(NetworkSettingsPolicy.dnsRestoreAction(entry: entry, current: nil, serviceExists: true) == .retryLater)
        #expect(NetworkSettingsPolicy.dnsRestoreAction(entry: entry, current: nil, serviceExists: false) == .forget)
        let legacy = NetworkJournal.DNSEntry(service: "Wi-Fi", prior: [], applied: [])
        #expect(NetworkSettingsPolicy.dnsRestoreAction(entry: legacy, current: ["198.18.0.2"], serviceExists: true) == .restore([]))
        #expect(NetworkSettingsPolicy.dnsRestoreAction(entry: legacy, current: [], serviceExists: true) == .forget)
    }

    @Test func testProxyRestoreDecisions() {
        let applied = ProxySetting(enabled: true, host: "127.0.0.1", port: 10808)
        let entry = NetworkJournal.ProxyEntry(service: "Wi-Fi", prior: .off, applied: applied)
        #expect(NetworkSettingsPolicy.proxyRestoreAction(entry: entry, current: applied, serviceExists: true) == .restore(.off))
        let otherPort = ProxySetting(enabled: true, host: "127.0.0.1", port: 7890)
        #expect(NetworkSettingsPolicy.proxyRestoreAction(entry: entry, current: otherPort, serviceExists: true) == .forget)
        #expect(NetworkSettingsPolicy.proxyRestoreAction(entry: entry, current: .off, serviceExists: true) == .forget)
        #expect(NetworkSettingsPolicy.proxyRestoreAction(entry: entry, current: nil, serviceExists: true) == .retryLater)
    }

    @Test func testDeadPinDetection() {
        #expect(NetworkSettingsPolicy.isDeadDNSPin([gateway], liveIPv4: ["192.168.0.2"], includeLegacy: false))
        // Our own live tunnel holds the /24 — the resolver works.
        #expect(!NetworkSettingsPolicy.isDeadDNSPin([gateway], liveIPv4: ["172.28.0.1"], includeLegacy: false))
        #expect(!NetworkSettingsPolicy.isDeadDNSPin(["198.18.0.2"], liveIPv4: [], includeLegacy: false))
        #expect(NetworkSettingsPolicy.isDeadDNSPin(["198.18.0.2"], liveIPv4: [], includeLegacy: true))
        #expect(!NetworkSettingsPolicy.isDeadDNSPin([gateway, "1.1.1.1"], liveIPv4: [], includeLegacy: true))
        #expect(!NetworkSettingsPolicy.isDeadDNSPin([], liveIPv4: [], includeLegacy: true))

        let pin = ProxySetting(enabled: true, host: "127.0.0.1", port: 10808)
        #expect(NetworkSettingsPolicy.isDeadProxyPin(pin, isPortLive: { _ in false }))
        #expect(!NetworkSettingsPolicy.isDeadProxyPin(pin, isPortLive: { _ in true }))
        #expect(!NetworkSettingsPolicy.isDeadProxyPin(ProxySetting(enabled: true, host: "10.0.0.1", port: 1080),
                                                      isPortLive: { _ in false }))
    }
}

// MARK: - Guard: the crash / reinstall scenarios that stranded machines

struct SystemSettingsGuardTests {

    @Test func testCrashAfterDNSOverrideIsUndoneByTheNextGeneration() {
        let sys = FakeSystem()
        sys.dns["Wi-Fi"] = ["1.1.1.1"]
        let store = tempStore()
        do {
            let first = SystemSettingsGuard(store: store, shell: sys, log: { _ in })
            #expect(first.applyDNS(servers: [gateway]).ok)
            #expect(sys.dns["Wi-Fi"] == [gateway])
            #expect(sys.dns["USB 10/100/1000 LAN"] == [gateway])
            // The third-party VPN's service is never rewritten.
            #expect(sys.dns["Happ"] == nil)
        }   // ← crash: no restore ran
        let next = SystemSettingsGuard(store: store, shell: sys, log: { _ in })
        next.restoreDNS()
        #expect(sys.dns["Wi-Fi"] == ["1.1.1.1"])
        #expect(sys.dns["USB 10/100/1000 LAN"] == [])
        #expect(!next.hasDNSOverride)
    }

    @Test func testLeftoverPinIsNeverRestoredAsTheUsersSetting() {
        let sys = FakeSystem()
        sys.dns["Wi-Fi"] = [gateway]          // a dead pin from an older helper
        let g = SystemSettingsGuard(store: tempStore(), shell: sys, log: { _ in })
        #expect(g.applyDNS(servers: [gateway]).ok)
        g.restoreDNS()
        #expect(sys.dns["Wi-Fi"] == [])       // automatic — not the dead pin again
    }

    @Test func testFailedRestoreKeepsTheEntryForTheNextAttempt() {
        let sys = FakeSystem()
        sys.dns["Wi-Fi"] = ["1.1.1.1"]
        let store = tempStore()
        let g = SystemSettingsGuard(store: store, shell: sys, log: { _ in })
        #expect(g.applyDNS(servers: [gateway]).ok)
        sys.failingWrites = ["Wi-Fi"]
        g.restoreDNS()
        #expect(g.hasDNSOverride)
        #expect(store.load().dns.contains { $0.service == "Wi-Fi" })
        sys.failingWrites = []
        let next = SystemSettingsGuard(store: store, shell: sys, log: { _ in })
        next.restoreDNS()
        #expect(sys.dns["Wi-Fi"] == ["1.1.1.1"])
        #expect(!next.hasDNSOverride)
    }

    @Test func testUserChangeAfterTheOverrideIsLeftAlone() {
        let sys = FakeSystem()
        let g = SystemSettingsGuard(store: tempStore(), shell: sys, log: { _ in })
        #expect(g.applyDNS(servers: [gateway]).ok)
        sys.dns["Wi-Fi"] = ["9.9.9.9"]
        g.restoreDNS()
        #expect(sys.dns["Wi-Fi"] == ["9.9.9.9"])
        #expect(!g.hasDNSOverride)
    }

    @Test func testUnreadableServiceIsNeverChanged() {
        let sys = FakeSystem()
        sys.dns["Wi-Fi"] = ["1.1.1.1"]
        sys.unreadable = ["Wi-Fi"]
        let g = SystemSettingsGuard(store: tempStore(), shell: sys, log: { _ in })
        #expect(g.applyDNS(servers: [gateway]).ok)
        #expect(sys.dns["Wi-Fi"] == ["1.1.1.1"])
        #expect(!g.journal.dns.contains { $0.service == "Wi-Fi" })
    }

    @Test func testNoDurableRecordMeansNoChange() {
        let sys = FakeSystem()
        sys.dns["Wi-Fi"] = ["1.1.1.1"]
        let g = SystemSettingsGuard(store: NetworkJournalStore(directory: "/dev/null/anemia"),
                                    shell: sys, log: { _ in })
        let r = g.applyDNS(servers: [gateway])
        #expect(!r.ok)
        #expect(sys.dns["Wi-Fi"] == ["1.1.1.1"])
    }

    @Test func testProxyOverrideRestoresTheUsersOwnProxyAndDropsDeadPins() {
        let sys = FakeSystem()
        sys.listening = [7890, 10808]
        sys.proxy["USB 10/100/1000 LAN"] = ProxySetting(enabled: true, host: "127.0.0.1", port: 7890)
        sys.proxy["Wi-Fi"] = ProxySetting(enabled: true, host: "127.0.0.1", port: 10808)   // leftover
        let store = tempStore()
        do {
            let g = SystemSettingsGuard(store: store, shell: sys, log: { _ in })
            #expect(g.applyProxy(host: "127.0.0.1", port: 10808).ok)
            #expect(g.proxyOverridePort == 10808)
            #expect(sys.proxy["Happ"] == nil)
        }
        let next = SystemSettingsGuard(store: store, shell: sys, log: { _ in })
        next.restoreProxy()
        #expect(sys.proxy["USB 10/100/1000 LAN"] == ProxySetting(enabled: true, host: "127.0.0.1", port: 7890))
        #expect(sys.proxy["Wi-Fi"]?.enabled == false)
        #expect(sys.proxy["Thunderbolt Bridge"]?.enabled == false)
        #expect(!next.hasProxyOverride)
    }

    @Test func testSweepResetsOnlyPinsThatCannotWork() {
        let sys = FakeSystem()
        sys.dns["Wi-Fi"] = [gateway]                     // dead: no utun holds 172.28.0.0/24
        sys.dns["USB 10/100/1000 LAN"] = ["1.1.1.1"]     // a real resolver
        sys.dns["Thunderbolt Bridge"] = ["198.18.0.2"]   // legacy range
        sys.proxy["Wi-Fi"] = ProxySetting(enabled: true, host: "127.0.0.1", port: 10808)
        let g = SystemSettingsGuard(store: tempStore(), shell: sys, log: { _ in })

        _ = g.sweepDeadPins(includeProxies: false, includeLegacyRanges: false)   // launch
        #expect(sys.dns["Wi-Fi"] == [])
        #expect(sys.dns["USB 10/100/1000 LAN"] == ["1.1.1.1"])
        #expect(sys.dns["Thunderbolt Bridge"] == ["198.18.0.2"])
        #expect(sys.proxy["Wi-Fi"]?.enabled == true)     // never swept at launch

        let report = g.sweepDeadPins(includeProxies: true, includeLegacyRanges: true)   // explicit repair
        #expect(sys.dns["Thunderbolt Bridge"] == [])
        #expect(sys.proxy["Wi-Fi"]?.enabled == false)
        #expect(report.count == 2)

        #expect(g.sweepDeadPins(includeProxies: true, includeLegacyRanges: true).isEmpty)
    }

    @Test func testLiveTunnelResolverIsNotSwept() {
        let sys = FakeSystem()
        sys.dns["Wi-Fi"] = [gateway]
        sys.live.insert(LoaderIdentifiers.defaultTunAddress)
        let g = SystemSettingsGuard(store: tempStore(), shell: sys, log: { _ in })
        #expect(g.sweepDeadPins(includeProxies: true, includeLegacyRanges: true).isEmpty)
        #expect(sys.dns["Wi-Fi"] == [gateway])
    }

    @Test func testPFReferenceIsHandedToRecoveryExactlyOnce() {
        let store = tempStore()
        let g = SystemSettingsGuard(store: store, shell: FakeSystem(), log: { _ in })
        g.recordPFToken("777")
        let next = SystemSettingsGuard(store: store, shell: FakeSystem(), log: { _ in })
        #expect(next.takePFRecovery().token == "777")
        #expect(next.takePFRecovery().token == nil)
        #expect(store.load().pfToken == nil)
    }
}

// MARK: - LaunchDaemon definition

struct HelperLaunchdTests {

    @Test func testDaemonRecoversAtBootAndAfterCrashes() throws {
        let data = Data(HelperLaunchd.plist().utf8)
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == LoaderIdentifiers.helperMachService)
        #expect((plist["MachServices"] as? [String: Bool])?[LoaderIdentifiers.helperMachService] == true)
        #expect(plist["RunAtLoad"] as? Bool == true)
        // Respawned only after a crash, so the next generation restores.
        #expect((plist["KeepAlive"] as? [String: Bool])?["SuccessfulExit"] == false)
        #expect(plist["ProcessType"] as? String == "Interactive")
        #expect((plist["EnvironmentVariables"] as? [String: String])?["LOADER_CLIENT_REQUIREMENT"]?.isEmpty == false)
    }

    @Test func testPackagingPlistMatchesTheInstallerDefinition() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Packaging/LoaderHelper-launchd.plist"))
        let packaged = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary)
        let installer = try #require(try PropertyListSerialization.propertyList(
            from: Data(HelperLaunchd.plist().utf8), format: nil) as? NSDictionary)
        #expect(packaged == installer)
    }
}
