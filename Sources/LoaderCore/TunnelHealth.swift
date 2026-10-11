import Foundation

/// Byte counters of a running engine, as the tunnel reports them.
public struct TrafficCounters: Equatable, Sendable {
    public var up: Int64
    public var down: Int64

    public init(up: Int64, down: Int64) {
        self.up = up
        self.down = down
    }
}

/// What one health check said. `measured` carries the number the report should
/// show — which is not always "-1" on failure: a request that answered in five
/// seconds was answered, and the report says five seconds, and still counts as
/// a failure.
public enum HealthOutcome: Equatable, Sendable {
    case silence
    case measured(ms: Int, failed: Bool)
}

/// The state the tunnel keeps about its own health: what the last check
/// measured, and how many in a row have failed.
public struct HealthState: Equatable, Sendable {
    public var health: Int?
    public var failures: Int

    public init(health: Int? = nil, failures: Int = 0) {
        self.health = health
        self.failures = failures
    }
}

/// "Does this tunnel carry traffic right now?" — the rules of
/// `PacketTunnelProvider.checkHealth`, pulled out of the extension so the
/// Android port can be compared against them at all: the tunnel target has no
/// test host, so inside the extension these lines were only ever verifiable by
/// watching a device.
///
/// Two engines, two ways to ask. Xray has a dialer: send one real request
/// through the running instance and time it. AmneziaWG has none, so the only
/// reading is the counters — if the phone is sending and nothing comes back for
/// a whole interval, the handshake is fine and the path is not.
public struct TunnelHealth: Equatable, Sendable {
    /// A tiny request that takes longer than this is a tunnel that carries
    /// nothing, however politely it answers.
    public var requestLimitMs: Int
    /// AmneziaWG needs evidence the phone actually tried: with an idle screen
    /// nothing is sent, and silence is not a failure.
    public var sendFloorBytes: Int64

    public init(requestLimitMs: Int = 3_000, sendFloorBytes: Int64 = 2_000) {
        self.requestLimitMs = requestLimitMs
        self.sendFloorBytes = sendFloorBytes
    }

    /// Xray: `nil` means the request never completed (including "the engine is
    /// not running" — both are a tunnel that carries nothing).
    public func request(_ ms: Int?) -> HealthOutcome {
        guard let ms else { return .measured(ms: -1, failed: true) }
        return .measured(ms: ms, failed: ms > requestLimitMs)
    }

    /// AmneziaWG, from two readings of the same engine run.
    ///
    /// `counters == nil` — the engine did not answer, so nothing is claimed and
    /// the caller must keep `previous` for the next round (a dropped reading
    /// widens the next interval rather than inventing a stall). The same
    /// "silence" comes back for a first reading, for a counter reset, and for
    /// a phone that sent nothing.
    public func counters(_ counters: TrafficCounters?, previous: TrafficCounters?, latency: Int?) -> HealthOutcome {
        guard let counters, let previous else { return .silence }
        let sent = counters.up - previous.up
        let received = counters.down - previous.down
        if received > 0 { return .measured(ms: latency ?? 1, failed: false) }
        // Отрицательная дельта — это перезапуск движка, а не молчание сервера.
        if sent > sendFloorBytes { return .measured(ms: -1, failed: true) }
        return .silence
    }

    /// How the report and the failure counter change after one outcome. The
    /// counter is what `AutoSwitchPolicy` eventually reads, so the meaning of
    /// "two in a row" lives here rather than in whoever calls the check.
    public func apply(_ outcome: HealthOutcome, to state: HealthState) -> HealthState {
        switch outcome {
        case .silence:
            return state
        case .measured(let ms, let failed):
            return HealthState(health: ms, failures: failed ? state.failures + 1 : 0)
        }
    }
}
