import Foundation
import Testing
@testable import LoaderCore

/// Subscription info and reminders, the traffic ledger, the leak check —
/// shared by the Mac and the iPhone apps.
struct SubscriptionInfoTests {
    @Test func parsesPanelHeaders() throws {
        let info = try #require(SubscriptionInfo.parse(headers: [
            "Subscription-Userinfo": "upload=1000000000; download=5000000000; total=100000000000; expire=1790000000",
            "profile-title": "base64:0JzQvtC5INCS0J/QnQ==",
            "Profile-Update-Interval": "12",
            "support-url": "https://t.me/anemia_support",
            "announce": "Plain%20text%20notice",
        ]))
        #expect(info.used == 6_000_000_000)
        #expect(info.remaining == 94_000_000_000)
        #expect(info.usedFraction == 0.06)
        #expect(info.expires == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(info.title == "Мой ВПН")
        #expect(info.updateInterval == TimeInterval(12 * 3600))
        #expect(info.supportURL?.absoluteString == "https://t.me/anemia_support")
        #expect(info.announcement == "Plain text notice")
    }

    @Test func unlimitedAndMissing() throws {
        let unlimited = try #require(SubscriptionInfo.parse(headers: ["subscription-userinfo": "upload=5; download=10; total=0; expire=0"]))
        #expect(unlimited.isUnlimited)
        #expect(unlimited.remaining == nil)
        #expect(unlimited.used == 15)
        #expect(unlimited.expires == nil)
        #expect(SubscriptionInfo.parse(headers: ["content-type": "text/plain"]) == nil)
        // Links other than http(s)/tg are dropped.
        #expect(SubscriptionInfo.parse(headers: ["support-url": "javascript:alert(1)"]) == nil)
    }

    /// Traffic sizes a panel can lie about used to crash the app: `Int(Double)`
    /// traps before any clamping, and `+` traps on the sum, so a header
    /// `total=99999999999999999999` killed the refresh mid-flight.
    @Test func trafficBeyondInt64ClampsInsteadOfTrapping() throws {
        let huge = try #require(SubscriptionInfo.parse(
            headers: ["subscription-userinfo": "total=9223372036854775807; download=-5"]))
        #expect(huge.total == .max)
        #expect(huge.used == -5)
        #expect(huge.remaining == .max)

        let summed = try #require(SubscriptionInfo.parse(
            headers: ["subscription-userinfo": "upload=9223372036854775807; download=1; total=100"]))
        #expect(summed.used == .max)
        #expect(summed.remaining == 0)
        #expect(summed.remaining == 0)

        let forever = try #require(SubscriptionInfo.parse(
            headers: ["subscription-userinfo": "upload=1; expire=99999999999999999999"]))
        #expect(forever.expires == Date(timeIntervalSince1970: TimeInterval(Int64.max)))
    }

        /// The "top servers" board and the prune both sort. `sorted` is not stable
    /// and a dictionary's order is random per launch, so entries sharing a total
    /// used to shuffle between openings — the board reordered itself for no
    /// reason the user could see.
    @Test func tiedTrafficOrdersDeterministically() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let names = [("в", "11111111-1111-1111-1111-111111111111"),
                     ("а", "22222222-2222-2222-2222-222222222222"),
                     ("б", "33333333-3333-3333-3333-333333333333")]
        var forward = TrafficLedger()
        var backward = TrafficLedger()
        for (index, pair) in names.enumerated() {
            // Отдельные прогоны движка: в одном накопительный счётчик дал бы нулевую дельту.
            forward.record(runStartedAt: now.addingTimeInterval(Double(index)), received: 100, sent: 10,
                           server: (UUID(uuidString: pair.1)!, pair.0), at: now)
            let offset = names.count - 1 - index
            backward.record(runStartedAt: now.addingTimeInterval(Double(offset)), received: 100, sent: 10,
                            server: (UUID(uuidString: names[offset].1)!, names[offset].0), at: now)
        }
        let ordered = ["а", "б", "в"]
        #expect(forward.topServers.map(\.name) == ordered)
        #expect(backward.topServers.map(\.name) == ordered)

        let older = TrafficLedger.ServerTotal(id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                                             name: "x", lastUsed: now.addingTimeInterval(-60))
        let newer = TrafficLedger.ServerTotal(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                              name: "y", lastUsed: now)
        #expect(TrafficLedger.newestFirst(newer, older))
        #expect(!TrafficLedger.newestFirst(older, newer))
        let tied = TrafficLedger.ServerTotal(id: older.id, name: "z", lastUsed: now)
        #expect(TrafficLedger.newestFirst(newer, tied))    // равное время — по id
        #expect(!TrafficLedger.newestFirst(tied, newer))
    }

    @Test func repairsUTF8ReadAsLatin1() {
        // "Мой" as UTF-8 bytes, read as Latin-1 by the HTTP stack.
        let latin1 = String(data: Data("Мой".utf8), encoding: .isoLatin1)!
        #expect(latin1 != "Мой")
        #expect(SubscriptionInfo.text(latin1) == "Мой")
    }

    @Test func attentionNearTheEnd() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(SubscriptionInfo(expires: now.addingTimeInterval(86_400)).needsAttention(now: now))
        #expect(!SubscriptionInfo(expires: now.addingTimeInterval(10 * 86_400)).needsAttention(now: now))
        #expect(SubscriptionInfo(uploaded: 0, downloaded: 95, total: 100).needsAttention(now: now))
        #expect(!SubscriptionInfo(uploaded: 0, downloaded: 50, total: 100).needsAttention(now: now))
    }

    @Test func remindersBeforeExpiryAndOnLowTraffic() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let soon = UUID()
        let low = UUID()
        let plan = SubscriptionReminders.plan([
            (soon, "A", SubscriptionInfo(expires: now.addingTimeInterval(2 * 86_400))),
            (low, "B", SubscriptionInfo(uploaded: 0, downloaded: 95, total: 100)),
        ], alreadyWarned: [], now: now)
        // Two days left: the 3-day reminder has passed, the 1-day one is ahead.
        #expect(plan.filter { $0.subscriptionID == soon }.map(\.kind) == [.expiresSoon(days: 1)])
        #expect(plan.first { $0.subscriptionID == soon }?.date == now.addingTimeInterval(86_400))
        #expect(plan.first { $0.subscriptionID == low }?.kind == .lowTraffic(remaining: 5, usedFraction: 0.95))
        // Warned once, not again.
        let again = SubscriptionReminders.plan([(low, "B", SubscriptionInfo(uploaded: 0, downloaded: 95, total: 100))],
                                               alreadyWarned: [low], now: now)
        #expect(again.isEmpty)
    }
}

struct TrafficLedgerTests {
    private let utc = TimeZone(identifier: "UTC")!

    @Test func countsDeltasWithinARunAndRestartsWithANewOne() {
        var ledger = TrafficLedger()
        let server = (id: UUID(), name: "NL")
        let run1 = Date(timeIntervalSince1970: 1_000_000)
        let t0 = run1.addingTimeInterval(10)
        ledger.record(runStartedAt: run1, received: 100, sent: 10, server: server, at: t0, timeZone: utc)
        ledger.record(runStartedAt: run1, received: 250, sent: 30, server: server, at: t0.addingTimeInterval(2), timeZone: utc)
        // A new run (reconnect): its counters start again.
        let run2 = t0.addingTimeInterval(60)
        ledger.record(runStartedAt: run2, received: 40, sent: 5, server: server, at: run2.addingTimeInterval(2), timeZone: utc)
        let today = ledger.today(now: run2, timeZone: utc)
        #expect(today.received == 290)
        #expect(today.sent == 35)
        #expect(ledger.topServers.first?.total == 325)
        // Connected time: the 2 s step counts, the minute-long gap doesn't.
        #expect(today.time == 2 + TrafficLedger.maxStep)
    }

    @Test func daysAndMonths() {
        var ledger = TrafficLedger()
        let day1 = TrafficLedger.date(ofDay: "2026-09-01", timeZone: utc)!.addingTimeInterval(3600)
        let day2 = TrafficLedger.date(ofDay: "2026-09-17", timeZone: utc)!.addingTimeInterval(3600)
        ledger.record(runStartedAt: day1, received: 1_000, sent: 0, server: nil, at: day1, timeZone: utc)
        ledger.record(runStartedAt: day2, received: 500, sent: 20, server: nil, at: day2, timeZone: utc)
        #expect(ledger.month(now: day2, timeZone: utc).total == 1_520)
        let recent = ledger.recentDays(3, now: day2, timeZone: utc)
        #expect(recent.map(\.id) == ["2026-09-15", "2026-09-16", "2026-09-17"])
        #expect(recent.last?.received == 500)
        #expect(ledger.servers.isEmpty)
    }

    @Test func roundTripsThroughJSON() throws {
        var ledger = TrafficLedger()
        ledger.record(runStartedAt: Date(), received: 7, sent: 3, server: (UUID(), "X"))
        let decoded = try JSONDecoder().decode(TrafficLedger.self, from: JSONEncoder().encode(ledger))
        #expect(decoded == ledger)
    }
}

struct LeakCheckTests {
    @Test func parsesIPSB() throws {
        let data = Data("""
        {"region":"Hesse","isp":"Ints Danebergs","city":"Frankfurt am Main","asn_organization":"Ints Danebergs",\
        "asn":219443,"ip":"177.1.194.1","country":"Germany","country_code":"DE"}
        """.utf8)
        let info = try LeakCheck.parseIPSB(data)
        #expect(info == LeakCheck.IPInfo(ip: "177.1.194.1", countryCode: "DE", country: "Germany",
                                         city: "Frankfurt am Main", isp: "Ints Danebergs"))
    }

    @Test func parsesCloudflareTrace() throws {
        let info = try LeakCheck.parseTrace(Data("fl=1\nh=www.cloudflare.com\nip=177.1.194.1\ncolo=FRA\nloc=de\n".utf8))
        #expect(info == LeakCheck.IPInfo(ip: "177.1.194.1", countryCode: "DE"))
    }

    @Test func parsesBashWSKeepingResolversOnly() throws {
        let data = Data("""
        [{"ip":"177.1.194.1","country":"de","country_name":"Germany","asn":"AS219443 X","org":"X","type":"ip"},
         {"ip":"172.217.33.149","country":"us","country_name":"United States","asn":"AS15169 Google LLC","org":"Google LLC","type":"dns"},
         {"ip":"172.217.33.149","country":"us","country_name":"United States","asn":"AS15169 Google LLC","org":"Google LLC","type":"dns"},
         {"ip":"0","country":"","asn":"","type":"conclusion"}]
        """.utf8)
        let servers = try LeakCheck.parseBashWS(data)
        #expect(servers == [LeakCheck.DNSServer(ip: "172.217.33.149", countryCode: "US", country: "United States", org: "Google LLC")])
    }

    @Test func findings() {
        let home = LeakCheck.IPInfo(ip: "95.1.1.1", countryCode: "RU")
        let exit = LeakCheck.IPInfo(ip: "166.88.228.200", countryCode: "FR")
        let russianDNS = LeakCheck.DNSServer(ip: "95.2.2.2", countryCode: "RU")
        let foreignDNS = LeakCheck.DNSServer(ip: "1.1.1.1", countryCode: "US")
        // All good.
        #expect(LeakCheck.findings(exit: exit, direct: home, ipv6: nil, dns: [foreignDNS]).isEmpty)
        // The tunnel isn't carrying the traffic.
        #expect(LeakCheck.findings(exit: home, direct: home, ipv6: nil, dns: []) == [.tunnelBypassed])
        // IPv6 and DNS escaping from the home country.
        let v6 = LeakCheck.IPInfo(ip: "2a00::1", countryCode: "RU")
        #expect(LeakCheck.findings(exit: exit, direct: home, ipv6: v6, dns: [russianDNS, foreignDNS])
                == [.ipv6Leak(v6), .dnsLeak([russianDNS])])
        // Without the provider's own address there is nothing to compare.
        #expect(LeakCheck.findings(exit: exit, direct: nil, ipv6: v6, dns: [russianDNS]).isEmpty)
    }
}

struct LearnedMaskingTests {
    private let server = ProxyServer(name: "NL", proto: .vless, address: "nl.example.com", port: 443,
                                     credential: "uuid-1", security: .reality)

    @Test func networkEntryComesFirstThenTheGeneralOne() {
        var state = PersistedState()
        // Learned on the Mac (or before networks mattered): applies everywhere.
        state.learnedMasking[server.identityKey] = MaskingProfile.maximum.rawValue
        #expect(state.learnedMasking(for: server, on: .cellular) == .maximum)
        // The phone learns something stronger on mobile data only.
        state.learnMasking(.ruYandex, for: server, on: .cellular)
        #expect(state.learnedMasking(for: server, on: .cellular) == .ruYandex)
        #expect(state.learnedMasking(for: server, on: .wifi) == .maximum)
        #expect(state.learnedMasking(for: server, on: nil) == .maximum)
        #expect(state.learnedMasking[server.identityKey + "#cellular"] == "ruYandex")
    }

    @Test func forgettingClearsTheNetworkAndTheGeneralEntry() {
        var state = PersistedState()
        state.learnMasking(.maximum, for: server, on: nil)
        state.learnMasking(.ruVK, for: server, on: .wifi)
        state.learnMasking(.ruYandex, for: server, on: .cellular)
        state.learnMasking(nil, for: server, on: .wifi)
        #expect(state.learnedMasking(for: server, on: .wifi) == nil)
        // The other network keeps its own.
        #expect(state.learnedMasking(for: server, on: .cellular) == .ruYandex)
    }

    @Test func serverKeyStripsTheNetwork() {
        let key = server.identityKey
        #expect(PersistedState.serverKey(ofLearnedMaskingKey: key + "#wifi") == key)
        #expect(PersistedState.serverKey(ofLearnedMaskingKey: key + "#cellular") == key)
        #expect(PersistedState.serverKey(ofLearnedMaskingKey: key) == key)
    }
}
