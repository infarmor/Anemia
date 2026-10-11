import Foundation
import Testing
@testable import LoaderCore

struct PersistenceTests {
    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("loader-persist-tests-\(UUID().uuidString).json")
    }

    @Test func testLoadMissingFileReturnsDefaults() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let state = StatePersistence(fileURL: url).load()
        #expect(state.servers.isEmpty)
        #expect(state.selectedServerID == nil)
    }

    @Test func testMalformedStateIsBackedUpAndReset() throws {
        let url = tempURL()
        let base = url.deletingPathExtension().lastPathComponent
        defer {
            try? FileManager.default.removeItem(at: url)
            // The corrupt-store backup too — a stale .corrupt-*.bak would let
            // a later regression pass via prefix leftovers.
            let fm = FileManager.default
            if let files = try? fm.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) {
                for f in files where f.hasPrefix(base + ".json.corrupt-") {
                    try? fm.removeItem(at: url.deletingLastPathComponent().appendingPathComponent(f))
                }
            }
        }
        let server = ProxyServer(name: "kept", proto: .vless, address: "a.example.com", port: 443, credential: "u")
        let good = PersistedState(servers: [server], selectedServerID: server.id)
        try StatePersistence(fileURL: url).save(good)

        // Corrupt the store in place with JSON the lenient decoder can't map
        // (`{}` alone decodes to defaults — a *type-mismatched* field fails).
        try Data(#"{"servers": 42}"#.utf8).write(to: url)

        let reloaded = StatePersistence(fileURL: url).load()
        #expect(reloaded.servers.isEmpty, "corrupt state must fall back to defaults")

        // …but the previous data is recoverable from the timestamped backup.
        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        let backup = files.first { $0.hasPrefix(base + ".json.corrupt-") }
        #expect(backup != nil, "a .corrupt-*.bak backup of the malformed store must exist")
        if let backup {
            let raw = try? Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(backup))
            #expect(raw == Data(#"{"servers": 42}"#.utf8), "the backup must contain the raw malformed bytes")
        }
    }

    /// The drift detector used to compare only `servers`, `subscriptions` and
    /// `learnedMasking`, while its comment promised every collection — so a
    /// `splitTunnel` whose `entries` no longer decode (a renamed field, a
    /// downgraded build, an edited file) loaded as "no bypass rules" with no
    /// backup, and the next save() overwrote the only copy the user had.
    @Test func testUnreadableSplitTunnelRulesAreBackedUp() throws {
        let url = tempURL()
        let base = url.deletingPathExtension().lastPathComponent
        func backupsNow() -> [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path))?
                .filter { $0.hasPrefix(base + ".json.corrupt-") } ?? []
        }
        defer {
            try? FileManager.default.removeItem(at: url)
            for f in backupsNow() {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent().appendingPathComponent(f))
            }
        }

        // Control: the same shape with decodable rules must NOT be treated as
        // drift — otherwise every ordinary load would write a backup.
        try Data(#"{"servers":[],"splitTunnel":{"enabled":true,"entries":["example.com","172.28.0.0/24"]}}"#.utf8)
            .write(to: url)
        let clean = StatePersistence(fileURL: url).load()
        #expect(clean.splitTunnel.entries == ["example.com", "172.28.0.0/24"])
        #expect(backupsNow().isEmpty, "a healthy store must not be called corrupt")

        // An entry that cannot be a String empties the whole array through the
        // lenient decoder — the loss the backup exists to make recoverable.
        try Data(#"{"servers":[],"splitTunnel":{"enabled":true,"entries":[{"poisoned":true}]}}"#.utf8)
            .write(to: url)
        let drifted = StatePersistence(fileURL: url).load()
        #expect(drifted.splitTunnel.entries.isEmpty)
        #expect(!backupsNow().isEmpty, "a silently-emptied splitTunnel must still get a backup")
    }

    @Test func testRoundTripPreservesState() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = ProxyServer(name: "n", proto: .trojan, address: "h", port: 1, credential: "p")
        let original = PersistedState(servers: [server], selectedServerID: server.id)
        try StatePersistence(fileURL: url).save(original)
        #expect(StatePersistence(fileURL: url).load() == original)
    }

    /// The learned per-server masking map survives a save/load round-trip, and a
    /// store written before the field existed still decodes (empty map).
    @Test func testLearnedMaskingRoundTripAndLegacyDecode() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = ProxyServer(name: "n", proto: .vless, address: "h", port: 443, credential: "u")
        let original = PersistedState(servers: [server],
                                      learnedMasking: [server.identityKey: MaskingProfile.ruYandex.rawValue])
        try StatePersistence(fileURL: url).save(original)
        let reloaded = StatePersistence(fileURL: url).load()
        #expect(reloaded.learnedMasking[server.identityKey] == MaskingProfile.ruYandex.rawValue)

        // Legacy store without the key → empty map, no data loss.
        try #"{"servers":[],"subscriptions":[]}"#.data(using: .utf8)!.write(to: url)
        #expect(StatePersistence(fileURL: url).load().learnedMasking.isEmpty)
    }
}

struct ServerIdentityTests {
    @Test func testIdentityKeyIgnoresCosmeticFields() {
        let a = ProxyServer(name: "Alpha", proto: .vless, address: "h", port: 443, credential: "u",
                            network: .tcp, security: .tls, sni: "sni.example.com")
        let b = ProxyServer(name: "Beta", proto: .vless, address: "h", port: 443, credential: "u",
                            network: .ws, security: .none, path: "/ws")
        #expect(a.identityKey == b.identityKey, "name/sni/transport must not change identity")
    }

    @Test func testIdentityKeyDistinguishesCredentialsAndProtocols() {
        let base = ProxyServer(name: "A", proto: .vless, address: "h", port: 443, credential: "u1")
        #expect(base.identityKey != ProxyServer(name: "A", proto: .vless, address: "h", port: 443, credential: "u2").identityKey)
        #expect(base.identityKey != ProxyServer(name: "A", proto: .trojan, address: "h", port: 443, credential: "u1").identityKey)
        #expect(base.identityKey != ProxyServer(name: "A", proto: .vless, address: "h", port: 8443, credential: "u1").identityKey)
    }

    /// A refresh keeps known servers' IDs, and a link listed twice never
    /// shares one ID between both copies (duplicate IDs break every id-keyed
    /// list, selection and lookup).
    @Test func testRefreshCarriesIDsWithoutDuplicates() {
        let a = ProxyServer(name: "A", proto: .vless, address: "a.example.com", port: 443, credential: "u")
        let b = ProxyServer(name: "B", proto: .trojan, address: "b.example.com", port: 443, credential: "p")
        let renamed = ProxyServer(name: "A (renamed)", proto: .vless, address: "a.example.com", port: 443, credential: "u")
        let again = ProxyServer(name: "A again", proto: .vless, address: "a.example.com", port: 443, credential: "u")
        let bFresh = ProxyServer(name: "B", proto: .trojan, address: "b.example.com", port: 443, credential: "p")
        let c = ProxyServer(name: "C", proto: .shadowsocks, address: "c.example.com", port: 8388, credential: "s")
        let result = SubscriptionParser.carryingIDs(from: [a, b], into: [renamed, again, bFresh, c])
        #expect(result[0].id == a.id)
        #expect(result[1].id != a.id)
        #expect(result[2].id == b.id)
        #expect(result[3].id == c.id)
        #expect(Set(result.map(\.id)).count == 4)

        // Duplicates an older build already persisted are split apart too.
        var twin = a
        twin.name = "twin"
        let healed = SubscriptionParser.carryingIDs(from: [a, twin], into: [renamed, again])
        #expect(healed[0].id == a.id)
        #expect(Set(healed.map(\.id)).count == 2)
    }

    @Test func testSubscriptionTLSgateForAutomaticRefresh() {
        // Автоматический проход берёт только TLS-панели; нажатие пользователя
        // может и http. Единственное, на что это опирается, — `tlsProtected`.
        func protected(_ url: String) -> Bool {
            Subscription(name: "n", url: url).tlsProtected
        }
        #expect(protected("https://panel.example/abc"))
        #expect(protected("HTTPS://panel.example/abc"))          // регистр схемы не значим
        #expect(!protected("http://panel.example/abc"))
        #expect(!protected("ftp://panel.example/abc"))
        #expect(!protected("panel.example/abc"))                 // без схемы — не TLS
        #expect(!protected("httpsx://panel.example/abc"))        // не обманчивый префикс
        #expect(!protected(""))
    }

    @Test func testSubscriptionAutoRefreshDecision() {
        // Всё решение «обновлять ли панель без пользователя» — в одном
        // предикате, и он же золотой для Kotlin (`sub/due.golden.txt`).
        // Здесь те же границы, но независимым тестом: чтобы порча предиката
        // была красной и на Swift-стороне, а не только в сравнении портов.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func due(_ url: String, age: TimeInterval?, interval: TimeInterval? = nil,
                 defaultAge: TimeInterval = 6 * 3_600, allowInsecure: Bool = false) -> Bool {
            Subscription(name: "n", url: url, lastUpdated: age.map { now.addingTimeInterval(-$0) })
                .refreshIsDue(now: now, panelInterval: interval, defaultAge: defaultAge,
                              allowInsecure: allowInsecure)
        }
        func maxAge(_ url: String, interval: TimeInterval?,
                    defaultAge: TimeInterval = 6 * 3_600) -> TimeInterval {
            Subscription(name: "n", url: url)
                .refreshMaxAge(panelInterval: interval, defaultAge: defaultAge)
        }

        // Без TLS раунд не трогает панель вовсе — какой бы свежее она ни была.
        #expect(!due("http://p/sub", age: nil))
        #expect(!due("http://p/sub", age: 30 * 3_600))
        // …а нажатие пользователя — трогает.
        #expect(due("http://p/sub", age: 30 * 3_600, allowInsecure: true))
        // TLS: нет истории — пора; за секунду до срока — ещё нет; ровно в срок — да.
        #expect(due("https://p/sub", age: nil))
        #expect(!due("https://p/sub", age: 21_599))
        #expect(due("https://p/sub", age: 21_600))
        // Ушедшая вперёд дата (часовой пояс, кривые часы, бандл с другого
        // устройства) — не «ждать окончания перекоса», а «пора».
        #expect(due("https://p/sub", age: -3_600))
        // Нечисловая просьба панели — это сломанная просьба: она не должна
        // выключать обновление навсегда (`age >= NaN` ложно всегда).
        #expect(due("https://p/sub", age: 30 * 3_600, interval: .nan))
        #expect(maxAge("https://p/sub", interval: .nan) == 21_600)
        #expect(maxAge("https://p/sub", interval: .infinity) == 21_600)
        #expect(maxAge("https://p/sub", interval: 1e400) == 21_600)
        // Панель не может попросить чаще часа и реже суток; врать знаком — тоже.
        #expect(!due("https://p/sub", age: 2_000, interval: 1_800))
        #expect(due("https://p/sub", age: 400_000, interval: 365 * 24 * 3_600))
        #expect(!due("https://p/sub", age: 2_000, interval: -5))
        // Явный defaultAge зажимается наравне с просьбой панели.
        #expect(!due("https://p/sub", age: 20, defaultAge: 10))
        #expect(due("https://p/sub", age: 100_000, defaultAge: 1_000_000))
        #expect(maxAge("https://p/sub", interval: nil) == 21_600)
        #expect(maxAge("https://p/sub", interval: 60) == 3_600)
        #expect(maxAge("https://p/sub", interval: 900_000) == 86_400)
        #expect(maxAge("https://p/sub", interval: nil, defaultAge: 1) == 3_600)
    }

    @Test func testPanelIntervalSurvivesALyingHeader() {
        // `profile-update-interval: 1e400` — это Infinity. Он переживает
        // `hours > 0` и попадает в `[UUID: SubscriptionInfo]`, который macOS и
        // iOS пишут через `try? JSONEncoder().encode(...)`: одна бесконечность
        // роняет кодирование ВСЕГО словаря, и заголовки всех панелей
        // (остаток, срок, имя) перестают сохраняться — молча, без строчки в
        // журнале. Поэтому не-число отсекается на входе.
        func parsed(_ value: String) -> SubscriptionInfo? {
            SubscriptionInfo.parse(headers: ["profile-update-interval": value])
        }
        #expect(parsed("24")?.updateInterval == 86_400)
        #expect(parsed("1e400")?.updateInterval == nil)
        #expect(parsed("inf")?.updateInterval == nil)
        #expect(parsed("nan")?.updateInterval == nil)
        #expect(parsed("-5")?.updateInterval == nil)
        #expect(parsed("0")?.updateInterval == nil)
        // Остальное из того же ответа не портится: панель остаётся подписанной.
        #expect(parsed("1e400")?.used == nil)
    }
}
