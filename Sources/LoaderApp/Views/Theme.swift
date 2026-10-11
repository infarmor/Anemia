import SwiftUI
import AppKit

/// Claude's palette, in two tones.
///
/// The ground is Claude's ivory by day and its warm charcoal by night. Tone
/// one is warm ink — near-black #141413 (ivory in dark mode) at a few
/// densities for text, hairlines and fills. Tone two is Claude's clay orange.
/// Nothing else: no green "connected", no red or blue. The clay means
/// "active, or act on this"; what exactly happened is carried by the SF Symbol
/// and the words, so every state still reads in grayscale and with color
/// blindness. Both clays clear 4.5:1 against their ground.
enum Theme {
    // MARK: Surfaces

    /// Claude's ground: ivory #FAF9F5 / charcoal #262624.
    static let ground    = dyn(light: Color(hex: 0xFAF9F5), dark: Color(hex: 0x262624))
    static let bgTop     = ground
    static let bgBottom  = ground

    /// Grouped-content fill — Claude's raised surfaces: oat on ivory, a
    /// lighter charcoal on charcoal.
    static let card      = dyn(light: Color(hex: 0xF0EEE6), dark: Color(hex: 0x30302E))
    static let cardHi    = dyn(light: Color(hex: 0xE8E6DC), dark: Color(hex: 0x3A3936))

    static let stroke    = dyn(light: Color(hex: 0x141413).opacity(0.12), dark: Color(hex: 0xFAF9F5).opacity(0.12))
    static let textHi    = dyn(light: Color(hex: 0x141413), dark: Color(hex: 0xFAF9F5))
    static let textLo    = dyn(light: Color(hex: 0x6B6A64), dark: Color(hex: 0xA6A39B))

    // MARK: Accent & state

    /// Claude's clay: deeper #C6613F on ivory, the brighter #D97757 on charcoal.
    static let accent    = dyn(light: Color(hex: 0xC6613F), dark: Color(hex: 0xD97757))
    static let accentDim = accent
    static let brand     = accent.opacity(0.75)
    /// Neutral hover / track fill — warm ink at a whisper.
    static let idle      = dyn(light: Color(hex: 0x141413).opacity(0.06), dark: Color(hex: 0xFAF9F5).opacity(0.08))

    /// State aliases — all the accent tone (see the type comment).
    static let connected = accent
    static let danger    = accent
    static let warn      = accent
    static let info      = accent

    // MARK: Quality / latency tiers

    static let mapLand = dyn(light: Color(hex: 0x141413).opacity(0.16), dark: Color(hex: 0xFAF9F5).opacity(0.20))

    /// Best → worst as warm-ink density.
    static let tierExcellent = textHi
    static let tierGood      = textLo
    static let tierFair      = dyn(light: Color(hex: 0x9C9A92), dark: Color(hex: 0x7D7B74))
    static let tierPoor      = dyn(light: Color(hex: 0xC2C0B6), dark: Color(hex: 0x5A5954))

    /// macOS 26 geometry: grouped boxes use the gentle system radii.
    static let cardRadius: CGFloat = 12
    static let subRadius: CGFloat = 8

    // MARK: Backgrounds (kept for surfaces that draw their own ground)

    static var background: LinearGradient {
        LinearGradient(colors: [bgTop, bgBottom], startPoint: .top, endPoint: .bottom)
    }
    static var edge: LinearGradient {
        LinearGradient(colors: [.clear, .clear], startPoint: .top, endPoint: .bottom)
    }
    static let shadowColor = Color.clear
    static let shadowRadius: CGFloat = 0
    static let shadowY: CGFloat = 0

    // MARK: Motion

    /// Critically damped springs: no overshoot on state changes a finger
    /// didn't flick.
    static let spring = Animation.spring(response: 0.35, dampingFraction: 1.0)
    static let springQuick = Animation.spring(response: 0.22, dampingFraction: 1.0)

    // MARK: Type (SF Pro, the system scale)

    static func tracking(for size: CGFloat) -> CGFloat { 0 }

    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight)
    }

    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// Monospaced digits for ticking metrics — the text face, digits fixed-width.
    static func metric(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }

    private static func dyn(light: Color, dark: Color) -> Color {
        Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
    }
}

/// Claude's ground behind a whole surface — under the unified toolbar too, so
/// the window reads as one warm sheet instead of gray chrome over cream.
struct GroundBackground: View {
    var body: some View {
        Theme.ground.ignoresSafeArea()
    }
}

private struct SnapshotRenderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set by the headless snapshot renderer (Tests/LoaderAppSnapshotTests).
    var snapshotRendering: Bool {
        get { self[SnapshotRenderingKey.self] }
        set { self[SnapshotRenderingKey.self] = newValue }
    }
}

extension View {
    /// Single-line input chrome for custom fields (quiet fill, focus ring in
    /// the accent color).
    func fieldChrome(focused: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.subRadius, style: .continuous)
        return self
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Theme.idle, in: shape)
            .overlay(shape.strokeBorder(focused ? Theme.accent : Theme.stroke, lineWidth: focused ? 1.5 : 1))
            .animation(Theme.springQuick, value: focused)
    }

    /// Grouped box — the System Settings section shape: a flat fill, no
    /// shadow, no edge highlight. (`shadow` is accepted for call-site
    /// compatibility and ignored.)
    func softCard(_ radius: CGFloat = Theme.cardRadius,
                  fill: Color = Theme.card,
                  shadow: Bool = true) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// Human-readable byte + speed + duration formatting for the stats UI.
enum Format {
    static func bytes(_ n: Int64) -> String {
        // Decimal, like the labels say and like both other ports
        // (`Formatting.kt`'s bytes ladder, `ActivityText.swift`): with 1024 the
        // Mac showed 953.7 MB for the same allowance the phone and the island
        // called 1,0 ГБ. `bitRate` below already divides by 1000 — two ladders
        // in one sheet were the other half of the same inconsistency.
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(max(0, n))
        var i = 0
        while value >= 999.5 && i < units.count - 1 { value /= 1000; i += 1 }
        return i == 0 ? "\(Int(value)) B" : String(format: "%.1f %@", value, units[i])
    }

    static func speed(_ bytesPerSec: Int64) -> String { "\(bytes(bytesPerSec))/s" }

    /// Latency label: sub-millisecond reads "<1 ms"; negative (failed) reads "—".
    static func ping(_ ms: Int) -> String { ms < 0 ? "—" : (ms == 0 ? "<1 ms" : "\(ms) ms") }

    /// Network speed in bits: "48.2 Mbps", "950 kbps".
    static func bitRate(_ bitsPerSecond: Double) -> String {
        let units = ["kbps", "Mbps", "Gbps"]
        var value = max(bitsPerSecond, 0) / 1000
        var i = 0
        while value >= 999.5 && i < units.count - 1 { value /= 1000; i += 1 }
        return value > 0 && value < 9.95
            ? String(format: "%.1f %@", value, units[i])
            : String(format: "%.0f %@", value, units[i])
    }

    /// How long: "1 h 12 min", "4 min", "35 s".
    static func span(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        guard total >= 60 else { return "\(total) s" }
        let h = total / 3600, m = total % 3600 / 60
        guard h > 0 else { return "\(m) min" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    static func duration(since start: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%02d:%02d", m, sec)
    }
}
