import Foundation

/// What the app should do about a tunnel that stopped carrying traffic.
///
/// The raw signal — consecutive failed health checks — is produced by the
/// tunnel process (iOS runs one real request through the live engine every 30 s,
/// the Android port asks the engine inside its own process). This is the other
/// half: *when it is worth acting on that signal*, and how often. Acting too
/// eagerly moves a working connection over one lost packet or a session that
/// never had a chance to settle; acting too often turns a blocked server into a
/// reboot loop over every entry the panel offers.
public enum SwitchVerdict: String, Equatable, Sendable {
    /// Turned off by the user, or there is nothing to move to.
    case off
    /// Not "connected", so there is no session whose health could fail.
    case notConnected
    /// Something else already owns the tunnel.
    case busy
    /// Not enough evidence: one miss, no signal yet, or the session is too young.
    case unproven
    /// The budget for the window is spent, or the last move is too recent.
    case throttled
    /// Move now.
    case go
}

/// The auto-switching decision in one place, so the apps cannot drift apart on
/// thresholds. Ported from `AutoSwitch.evaluate()` in `iOS/Anemia/AppModel.swift`,
/// which is the code that actually runs this; macOS reaches the same situation
/// through its recovery ladder instead (`attemptReconnect`, triggered by its own
/// health loop) and deliberately keeps its own pacing.
public struct AutoSwitchPolicy: Equatable, Sendable {
    /// Consecutive failed health checks before anything moves. One miss is a
    /// lost packet; a server that has stopped carrying traffic fails repeatedly.
    public var failuresToAct: Int
    /// A session younger than this gets to finish setting up: the first checks
    /// of a just-started tunnel fail for reasons the tunnel itself fixes.
    public var minSessionAge: TimeInterval
    /// How far back the budget looks.
    public var window: TimeInterval
    /// How many moves the window allows in total.
    public var maxSwitches: Int
    /// Smallest gap between two moves.
    public var minGap: TimeInterval

    public init(
        failuresToAct: Int = 2,
        minSessionAge: TimeInterval = 60,
        window: TimeInterval = 15 * 60,
        maxSwitches: Int = 3,
        minGap: TimeInterval = 3 * 60
    ) {
        self.failuresToAct = failuresToAct
        self.minSessionAge = minSessionAge
        self.window = window
        self.maxSwitches = maxSwitches
        self.minGap = minGap
    }

    /// `recentSwitches` are ages in seconds of the moves already made this
    /// window, in any order — the gap is measured against the *nearest* one, so
    /// an unsorted list cannot be read as a long pause. Negative ages (a wall
    /// clock stepping backwards under iOS) count as "just happened" and hold
    /// the switch off rather than opening a bypass.
    ///
    /// `healthFailures` is nil until the tunnel has answered a health request
    /// at least once; "no signal" must not be read as "the server is fine",
    /// nor as "it is dead".
    public func decide(
        enabled: Bool,
        connected: Bool,
        busy: Bool,
        serverCount: Int,
        healthFailures: Int?,
        sessionAge: TimeInterval,
        recentSwitches: [TimeInterval]
    ) -> SwitchVerdict {
        guard enabled, serverCount > 1 else { return .off }
        guard connected else { return .notConnected }
        guard !busy else { return .busy }
        guard let failures = healthFailures, failures >= failuresToAct else { return .unproven }
        // Сравнение с NaN ложно всегда — «неизвестный возраст сессии» означает
        // «не переключаться», а не «сессия вечная».
        guard sessionAge > minSessionAge else { return .unproven }
        let kept = retained(recentSwitches: recentSwitches)
        guard kept.count < maxSwitches else { return .throttled }
        guard kept.allSatisfy({ $0 > minGap }) else { return .throttled }
        return .go
    }

    /// The switches that still count toward the budget. The caller keeps its
    /// own list of dates and prunes it with this; without pruning the list
    /// grows for the whole lifetime of the process.
    public func retained(recentSwitches: [TimeInterval]) -> [TimeInterval] {
        recentSwitches.filter { $0 <= window }
    }
}
