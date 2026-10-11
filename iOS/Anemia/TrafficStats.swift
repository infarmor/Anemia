import Foundation
import LoaderCore
import Observation

/// How much went through the VPN, per day and per server — LoaderCore's
/// TrafficLedger fed with the running tunnel's counters, kept on disk.
///
/// Only what the app sees is counted: while it's not running (no Live
/// Activity keep-alive), the next report after it returns catches up on the
/// run's traffic, which then lands on that day.
@MainActor
@Observable
final class TrafficStats {
    private(set) var ledger: TrafficLedger

    /// Монотонные часы: `Date` идёт назад вместе с переводом времени и
    /// сверкой по NTP, и на длину такого шага условие `> 30` не выполнялось
    /// вовсе — дневные и серверные суммы копились в памяти, а в UserDefaults не
    /// ложились, и jetsam терял всё с последней записи. Тот же класс, что
    /// уже починен в `TunnelController.since(_:)`.
    @ObservationIgnored private var lastSave = DispatchTime(uptimeNanoseconds: 0)
    private static let storeKey = "trafficStats"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let saved = try? JSONDecoder().decode(TrafficLedger.self, from: data) {
            ledger = saved
        } else {
            ledger = TrafficLedger()
        }
    }

    var today: TrafficLedger.Day { ledger.today() }
    var month: TrafficLedger.Day { ledger.month() }
    var topServers: [TrafficLedger.ServerTotal] { ledger.topServers }

    func recentDays(_ count: Int) -> [TrafficLedger.Day] {
        ledger.recentDays(count)
    }

    /// With every fresh report from the running tunnel.
    func take(_ report: TunnelReport, server: ProxyServer?) {
        ledger.record(runStartedAt: report.startedAt, received: report.downloaded, sent: report.uploaded,
                      server: server.map { ($0.id, $0.name) })
        if DispatchTime.now() >= lastSave + 30 { save() }
    }

    /// The tunnel stopped: the next report starts a new connected stretch.
    func tunnelStopped() {
        ledger.stopped()
        save()
    }

    func reset() {
        ledger.reset()
        save()
    }

    /// Forgets the servers the user deleted, so «Топ серверов» doesn't list
    /// exits that no longer exist.
    func forgetServers(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let before = ledger.servers.count
        ledger.forget(Set(ids))
        guard ledger.servers.count != before else { return }
        save()
    }

    private func save() {
        lastSave = DispatchTime.now()
        if let data = try? JSONEncoder().encode(ledger) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }
}

extension TrafficLedger.Day {
    var date: Date { TrafficLedger.date(ofDay: id) ?? .distantPast }
}
