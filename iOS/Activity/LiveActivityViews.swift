import ActivityKit
import SwiftUI
import WidgetKit

// The Live Activity's views. They live here, in code the app compiles as
// well, so the app can draw them in its simulator gallery
// (LiveActivityGallery.swift) — the system's own rendering needs a device
// and a permission prompt answered. The widget extension puts them into the
// Lock Screen and the Dynamic Island (TunnelLiveActivity.swift).
//
// The island drives the design: its regions are narrow and the system drops
// what doesn't fit, so every island view is one short line. The Lock Screen
// only has to exist (Apple requires all presentations), so it is a single
// strip and all the detail lives in the island.

/// Claude's dark ground with ivory text and clay — the activity sits on the
/// Lock Screen and in the always-black island, so it keeps one dark look.
enum ActivityPalette {
    static let charcoal = Color(red: 0x26 / 255, green: 0x26 / 255, blue: 0x24 / 255)
    static let ivory = Color(red: 0xFA / 255, green: 0xF9 / 255, blue: 0xF5 / 255)
    static let soft = ivory.opacity(0.62)
    static let faint = ivory.opacity(0.10)
    static let clay = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
}

private typealias Palette = ActivityPalette
typealias ActivityState = TunnelActivityAttributes.ContentState

// MARK: - Session clock

/// Minutes into the current hour, 0…1 — the ring's sweep. The session has no
/// end to count down to, so the ring is a minute hand rather than a progress
/// bar: it fills over an hour and starts over.
enum SessionRing {
    static func fraction(_ state: ActivityState, now: Date = .now) -> Double {
        let end = state.endedAt ?? now
        let seconds = max(0, end.timeIntervalSince(state.connectedSince))
        return seconds.truncatingRemainder(dividingBy: 3600) / 3600
    }
}

/// The session as a ring around the flag, like the Clock app's timer. It
/// moves with the app's feed, not on its own: only a timer *text* ticks
/// without updates, and that text never fits the island's corner.
struct ActivitySessionRing: View {
    let state: ActivityState
    let size: CGFloat
    var showsFlag = true
    var dimmed = false

    var body: some View {
        let line = size * 0.11
        ZStack {
            Circle()
                .stroke(Palette.faint, lineWidth: line)
            Circle()
                .trim(from: 0, to: SessionRing.fraction(state))
                .stroke(dimmed ? Palette.soft : Palette.clay,
                        style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if showsFlag {
                ActivityFlag(code: state.countryCode, size: size * 0.5)
            }
        }
        .frame(width: size, height: size)
        .opacity(state.phase == .ended ? 0.6 : 1)
        .accessibilityHidden(true)
    }
}

/// The session's clock, ticking on its own — for the app and the widgets. The
/// Live Activity can't use it: the system lays a timer text out for the
/// longest value it could ever show, which is wider than the island's corner.
struct SessionClock: View {
    let start: Date

    var body: some View {
        Text(timerInterval: start...start.addingTimeInterval(99 * 3600 + 59 * 60 + 59),
             countsDown: false)
            .monospacedDigit()
    }

    /// "1:12" — hours and minutes.
    static func text(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds)) / 60
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}

/// The session's length inside the activity, as a string the app refreshes.
/// A `Text(timerInterval:)` would tick on its own while the app sleeps, but
/// it is laid out for the longest value it could ever show — which is what
/// stretched the island's pill across the screen and left it blank.
struct ActivityClock: View {
    let state: ActivityState

    var body: some View {
        Text(SessionClock.text(max(0, (state.endedAt ?? .now).timeIntervalSince(state.connectedSince))))
            .monospacedDigit()
    }
}

// MARK: - Lock Screen

/// One strip: the flag, the country, what's happening. Apple requires the
/// Lock Screen presentation but the app's home is the island, so this stays
/// a single line — no graph, no buttons, nothing to keep in sync.
struct ActivityLockScreenView: View {
    let state: ActivityState
    let isStale: Bool

    var body: some View {
        HStack(spacing: 8) {
            ActivityFlag(code: state.countryCode, size: 15)
            Text(state.title)
                .font(.system(size: 15, weight: .semibold, design: .serif))
                .foregroundStyle(Palette.ivory)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 6)
            Text(ActivityStatus.text(state, isStale: isStale))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(state.phase == .reconnecting ? Palette.clay : Palette.soft)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    private var accessibilityText: String {
        switch state.phase {
        case .connected where !isStale:
            "\(state.title), загрузка \(Speed.text(state.download)), отдача \(Speed.text(state.upload))"
        case .connected: "\(state.title), в сети \(SessionClock.text(Date().timeIntervalSince(state.connectedSince)))"
        case .connecting: "\(state.title), подключение"
        case .reconnecting: "\(state.title), связь прервалась"
        case .searching: "\(state.title), поиск сервера"
        case .ended: "\(state.title), отключено"
        }
    }
}

// MARK: - Apple Watch and CarPlay

/// The Lock Screen strip — or, in the small family (the Smart Stack on
/// Apple Watch, CarPlay), its short form.
struct ActivityContentView: View {
    let state: ActivityState
    let isStale: Bool
    @Environment(\.activityFamily) private var family

    var body: some View {
        switch family {
        case .small:
            ActivitySmallView(state: state, isStale: isStale)
        default:
            ActivityLockScreenView(state: state, isStale: isStale)
        }
    }
}

/// The Smart Stack on Apple Watch: the ring beside the country and, under
/// it, the live speed or what's happening; the graph below. The watch is
/// narrow, so nothing sits on the right. No buttons — a tap opens Anemia.
struct ActivitySmallView: View {
    let state: ActivityState
    let isStale: Bool
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                ActivitySessionRing(state: state, size: 28, dimmed: isStale)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.title)
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .foregroundStyle(Palette.ivory)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(ActivityStatus.text(state, isStale: isStale))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ActivityStatus.tint(state, isStale: isStale))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 0)
            }
            if isLive, !isLuminanceReduced {
                ActivitySpeedGraph(state: state, isStale: isStale)
                    .frame(height: 14)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.large)
    }

    private var isLive: Bool {
        state.phase == .connected && !isStale
    }
}

// MARK: - Dynamic Island

/// Expanded, leading: the session ring with the flag in it.
struct ActivityIslandLeading: View {
    let state: ActivityState

    var body: some View {
        ActivitySessionRing(state: state, size: 34)
            .padding(.leading, 2)
    }
}

/// Expanded, trailing: one short line beside the camera — the region is
/// narrow and the system drops what overflows it.
struct ActivityIslandTrailing: View {
    let state: ActivityState
    let isStale: Bool

    var body: some View {
        Group {
            if state.phase == .connected && !isStale {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.down").font(.system(size: 9, weight: .heavy))
                    Text(Speed.compact(state.download))
                }
                .foregroundStyle(Palette.clay)
            } else if state.phase == .connected {
                ActivityClock(state: state)
                    .foregroundStyle(Palette.soft)
            } else {
                Text(ActivityStatus.text(state, isStale: isStale))
                    .foregroundStyle(ActivityStatus.tint(state, isStale: isStale))
            }
        }
        .font(.system(size: 16, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.trailing, 2)
        .accessibilityLabel(ActivityStatus.accessibilityText(state, isStale: isStale))
    }
}

/// Expanded, centre: the country and the server, below the camera where the
/// room is.
struct ActivityIslandCenter: View {
    let state: ActivityState

    var body: some View {
        VStack(spacing: 1) {
            Text(state.title)
                .font(.system(size: 17, weight: .semibold, design: .serif))
                .foregroundStyle(Palette.ivory)
            Text(state.subtitle)
                .font(.caption2)
                .foregroundStyle(Palette.soft)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .dynamicTypeSize(...DynamicTypeSize.large)
    }
}

/// Expanded, bottom: the last two minutes and the session's numbers, with
/// the two actions on the right.
struct ActivityIslandBottom: View {
    let state: ActivityState
    let isStale: Bool

    var body: some View {
        VStack(spacing: 6) {
            ActivitySpeedGraph(state: state, isStale: isStale)
                .frame(height: 20)
            HStack(alignment: .center, spacing: 8) {
                ActivityStats(state: state, isStale: isStale)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ActivityButtons(state: state)
            }
            .frame(height: 30)
        }
        .padding(.horizontal, 4)
        .dynamicTypeSize(...DynamicTypeSize.large)
    }
}

/// Compact and minimal, leading: the exit country. The status and the clock
/// go to the right, the way the Clock app's timer does.
struct ActivityCompactMark: View {
    let state: ActivityState
    let size: CGFloat

    var body: some View {
        ActivityFlag(code: state.countryCode, size: size)
            .opacity(state.phase == .ended ? 0.6 : 1)
            .fixedSize()
            .accessibilityLabel(state.title)
    }
}

/// Compact, trailing: the session ring, or what's happening. Everything here
/// has a size the view decides itself — a `Text(timerInterval:)` is laid out
/// for the longest value it could ever show, which stretched the pill across
/// the screen and then drew nothing at all.
struct ActivityCompactStatus: View {
    let state: ActivityState
    let isStale: Bool

    var body: some View {
        Group {
            switch state.phase {
            case .connected:
                ActivitySessionRing(state: state, size: 16, showsFlag: false, dimmed: isStale)
            case .connecting:
                Image(systemName: "ellipsis")
            case .reconnecting:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(Palette.clay)
            case .searching:
                Image(systemName: "bolt.fill")
                    .foregroundStyle(Palette.clay)
            case .ended:
                Image(systemName: "shield.slash")
            }
        }
        .font(.system(size: 13, weight: .semibold, design: .rounded))
        .foregroundStyle(Palette.soft)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(label)
    }

    /// The ring stands for the session's length, not for the speed — the
    /// speed only appears in the expanded island, so saying it here would
    /// have VoiceOver read a number that isn't on the screen.
    private var label: String {
        switch state.phase {
        case .connected: "В сети \(SessionClock.text(max(0, Date().timeIntervalSince(state.connectedSince))))"
        case .connecting: "Подключение"
        case .reconnecting: "Связь прервалась, переподключение"
        case .searching: "Поиск самого быстрого сервера"
        case .ended: "Отключено"
        }
    }
}

// MARK: - Parts

/// What's happening, in as few characters as the island's regions take.
enum ActivityStatus {
    static func text(_ state: ActivityState, isStale: Bool) -> String {
        if let note = state.note { return note }
        switch state.phase {
        case .connected where !isStale: return Speed.compact(state.download)
        case .connected: return SessionClock.text(Date().timeIntervalSince(state.connectedSince))
        case .connecting: return "…"
        case .reconnecting: return "Нет связи"
        case .searching: return "Поиск"
        case .ended: return "Отключено"
        }
    }

    static func tint(_ state: ActivityState, isStale: Bool) -> Color {
        if state.note != nil || state.phase == .reconnecting || state.phase == .searching {
            return Palette.clay
        }
        return Palette.soft
    }

    static func accessibilityText(_ state: ActivityState, isStale: Bool) -> String {
        // The note replaces the numbers on screen, so it has to replace them
        // in VoiceOver too.
        if let note = state.note { return note }
        switch state.phase {
        case .connected where !isStale: return "Загрузка \(Speed.text(state.download))"
        case .connected: return "В сети"
        case .connecting: return "Подключение"
        case .reconnecting: return "Связь прервалась, переподключение"
        case .searching: return "Поиск самого быстрого сервера"
        case .ended: return "Отключено"
        }
    }
}

/// The flag, or a globe when the country is unknown.
struct ActivityFlag: View {
    let code: String?
    let size: CGFloat

    var body: some View {
        if let code {
            Text(Country.flag(code))
                .font(.system(size: size))
        } else {
            Image(systemName: "globe.europe.africa.fill")
                .font(.system(size: size * 0.8))
                .foregroundStyle(Palette.clay)
        }
    }
}

/// The two actions. Only the island carries them; the Lock Screen strip
/// doesn't, so there is one place to look at the buttons.
struct ActivityButtons: View {
    let state: ActivityState

    var body: some View {
        if state.phase != .ended, state.phase != .searching, state.phase != .connecting {
            Button(intent: FastestServerIntent()) {
                Label("Быстрее", systemImage: "bolt.fill")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 11)
                    .frame(height: 28)
                    .foregroundStyle(Palette.clay)
                    .background(Palette.clay.opacity(0.18), in: Capsule())
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Переключиться на самый быстрый сервер")
        }
        if state.phase != .ended {
            Button(intent: DisconnectIntent()) {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(Palette.ivory)
                    .background(Palette.faint, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Отключить VPN")
        }
    }
}

/// The last two minutes: download as a clay area, upload as a thin line,
/// scaled together. New points enter from the right.
struct ActivitySpeedGraph: View {
    let state: ActivityState
    let isStale: Bool

    var body: some View {
        let slots = ActivityState.historyLength
        let peak = max(state.downHistory.max() ?? 0, state.upHistory.max() ?? 0, 64)
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(Palette.faint)
                .frame(height: 1)
            if state.downHistory.count >= 2 {
                GraphShape(values: state.downHistory, slots: slots, peak: peak, closed: true)
                    .fill(LinearGradient(colors: [Palette.clay.opacity(0.5), Palette.clay.opacity(0.04)],
                                         startPoint: .top, endPoint: .bottom))
                GraphShape(values: state.downHistory, slots: slots, peak: peak)
                    .stroke(Palette.clay, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                GraphShape(values: state.upHistory, slots: slots, peak: peak)
                    .stroke(Palette.soft.opacity(0.75), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .opacity(isStale || state.phase != .connected ? 0.35 : 1)
        .accessibilityHidden(true)
    }
}

private struct GraphShape: Shape {
    let values: [Int]
    let slots: Int
    let peak: Int
    var closed = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count >= 2, slots >= 2, peak > 0 else { return path }
        let step = rect.width / CGFloat(slots - 1)
        let offset = max(slots - values.count, 0)
        let points = values.suffix(slots).enumerated().map { index, value in
            CGPoint(x: rect.minX + CGFloat(offset + index) * step,
                    y: rect.maxY - 1 - CGFloat(min(value, peak)) / CGFloat(peak) * (rect.height - 3))
        }
        path.move(to: points[0])
        // Midpoint curves: smooth without overshooting the samples.
        for index in 1..<points.count {
            let previous = points[index - 1]
            let mid = CGPoint(x: (previous.x + points[index].x) / 2, y: (previous.y + points[index].y) / 2)
            path.addQuadCurve(to: mid, control: previous)
        }
        path.addLine(to: points[points.count - 1])
        if closed {
            path.addLine(to: CGPoint(x: points[points.count - 1].x, y: rect.maxY))
            path.addLine(to: CGPoint(x: points[0].x, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

/// Two quiet lines: the clock (or a note), then latency and traffic.
struct ActivityStats: View {
    let state: ActivityState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let note = state.note {
                // A note takes the clock's line; the numbers stay below it.
                Text(note)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.clay)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else {
                firstLine
            }
            Text(numbers)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Palette.soft)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    @ViewBuilder private var firstLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state.phase == .connected && !isStale ? Palette.clay : Palette.soft)
                .frame(width: 6, height: 6)
            Group {
                switch state.phase {
                case .connected, .reconnecting, .searching:
                    ActivityClock(state: state)
                        .font(.caption.weight(.semibold))
                case .ended:
                    Text("Итог · \(SessionLength.text((state.endedAt ?? .now).timeIntervalSince(state.connectedSince)))")
                        .font(.caption.weight(.semibold))
                case .connecting:
                    Text("Anemia")
                        .font(.system(size: 13, weight: .semibold, design: .serif))
                }
            }
            .foregroundStyle(Palette.ivory)
            .lineLimit(1)
        }
    }

    /// Shortened from the right until it fits the line.
    private var numbers: String {
        var parts: [String] = []
        if state.phase == .connecting { return "соединяюсь с сервером…" }
        if state.phase != .ended, let latency = state.latency { parts.append("\(latency) мс") }
        parts.append("↓ \(Bytes.text(state.received))")
        if state.sent > 0 { parts.append("↑ \(Bytes.text(state.sent))") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Samples

/// States for Xcode previews and the simulator gallery.
enum ActivitySamples {
    static let down = [
        22, 30, 41, 38, 52, 61, 58, 70, 66, 74, 80, 77, 69, 64, 58, 61, 66, 72, 84, 90,
        88, 79, 71, 64, 60, 57, 63, 69, 75, 82, 86, 83, 78, 70, 66, 62, 59, 64, 70, 76,
    ].map { $0 * 600 }
    static let up = down.map { $0 / 9 }

    static let connected = ActivityState(
        phase: .connected, countryCode: "NL", title: "Нидерланды", subtitle: "Амстердам · XHTTP · Reality",
        download: 48_200_000, upload: 3_100_000, downHistory: down, upHistory: up,
        connectedSince: .now.addingTimeInterval(-4_324), received: 1_240_000_000, sent: 86_000_000, latency: 42
    )

    static let connecting = ActivityState(
        phase: .connecting, countryCode: "CH", title: "Швейцария", subtitle: "Цюрих · Reality",
        connectedSince: .now
    )

    static func with(_ phase: ActivityState.Phase, note: String? = nil) -> ActivityState {
        var state = connected
        state.phase = phase
        state.note = note
        if phase == .ended { state.endedAt = .now }
        return state
    }

    static let all: [(name: String, state: ActivityState, stale: Bool)] = [
        ("Подключено", connected, false),
        ("Нет свежих данных", connected, true),
        ("Подключение", connecting, false),
        ("Обрыв", with(.reconnecting), false),
        ("Поиск", with(.searching), false),
        ("Итог", with(.ended, note: "Соединение прервалось"), false),
        ("Заметка", with(.connected, note: "Переключился: Нидерланды"), false),
    ]
}
