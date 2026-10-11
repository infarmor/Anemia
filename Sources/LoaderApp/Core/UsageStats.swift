import Foundation
import LoaderCore

/// Traffic through the VPN per day and per server (Statistics): LoaderCore's
/// TrafficLedger, fed by the stats poller, kept in the app's defaults.
@MainActor
final class UsageStats: ObservableObject {
    @Published private(set) var ledger: TrafficLedger

    /// Monotonic, and started at zero so the first sample always saves: the
    /// throttle is a duration, and on wall-clock seconds a step backwards
    /// stopped persisting the session's bytes for the size of the step — the
    /// crash or quit in between loses them.
    private var lastSave = DispatchTime(uptimeNanoseconds: 0)
    private static let key = "usageLedger"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
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

    /// With every stats sample: the session's totals since `runStartedAt`.
    func record(runStartedAt: Date, received: Int64, sent: Int64, server: ProxyServer?) {
        ledger.record(runStartedAt: runStartedAt, received: received, sent: sent,
                      server: server.map { ($0.id, $0.name) })
        if EngineProcess.seconds(since: lastSave) > 30 { save() }
    }

    /// The session ended: the next sample starts a new run.
    func sessionEnded() {
        ledger.stopped()
        save()
    }

    func reset() {
        ledger.reset()
        save()
    }

    #if DEBUG
    /// Headless snapshots: shown, never saved.
    func showPreview(_ sample: TrafficLedger) {
        ledger = sample
    }
    #endif

    private func save() {
        lastSave = DispatchTime.now()
        if let data = try? JSONEncoder().encode(ledger) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

extension TrafficLedger.Day {
    var date: Date { TrafficLedger.date(ofDay: id) ?? .distantPast }
}
