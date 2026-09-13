import SwiftUI
import AppKit

/// Warm, Claude-inspired theme. Two palettes, both first-class:
///
///  * Light — the signature ivory/cream surfaces (#FAF9F5) with near-solid
///    white cards floating on them, warm ink text, soft shadows.
///  * Dark — warm charcoal (never pure black, which reads cold), the same
///    translucency the old graphite theme had.
///
/// A single saturated hue carries the whole UI: Claude's terracotta
/// (#D97757), used for "protected / active / recommended" — the connected
/// state, switches, chips, recommendations, the hero ring. Display type is a
/// serif (New York), the other visual signature of the look; body text stays
/// the system sans. Every token is a dynamic NSColor, so switching the system
/// appearance restyles the app with no view-level branching.
enum Theme {
    // MARK: Surfaces

    /// Page ground. Light: Claude's ivory with the faintest warm shift;
    /// dark: warm charcoal.
    static let bgTop     = dyn(light: Color(hex: 0xFAF9F5), dark: Color(hex: 0x262624))
    static let bgBottom  = dyn(light: Color(hex: 0xF0EEE6), dark: Color(hex: 0x1F1E1D))

    /// Card fills. Light: near-solid white tiles on the cream (0.88 — solid
    /// enough to read as a raised tile without going clinical white); dark:
    /// light-on-dark translucent panels.
    static let card      = dyn(light: Color.white.opacity(0.88), dark: Color.white.opacity(0.055))
    static let cardHi    = dyn(light: Color.white.opacity(0.97), dark: Color.white.opacity(0.085))

    /// Hairline separators / card borders.
    static let stroke    = dyn(light: Color(hex: 0x141413).opacity(0.10), dark: Color.white.opacity(0.07))
    static let textHi    = dyn(light: Color(hex: 0x141413), dark: Color.white.opacity(0.92))
    /// Secondary text — kept readable on charcoal (0.50, not the 0.45 it
    /// used to sink to): captions are load-bearing here (subtitles, helper
    /// status) and low-contrast grey-on-charcoal reads as "disabled".
    static let textLo    = dyn(light: Color(hex: 0x6E6D68), dark: Color.white.opacity(0.50))

    // MARK: Accent — Claude's terracotta

    /// The one saturated hue in the UI: Claude's terracotta. Slightly
    /// brightened on dark for legibility against charcoal.
    static let accent    = dyn(light: Color(hex: 0xD97757), dark: Color(hex: 0xDF8A67))
    /// Fill for prominent (`.borderedProminent`) buttons — the pressed/CTA
    /// terracotta Claude uses for filled controls, a step deeper than the
    /// text accent so white label text keeps its contrast.
    static let accentDim = dyn(light: Color(hex: 0xC96442), dark: Color(hex: 0xD97757))
    /// Quiet brand tint for non-emphatic accents (dimmer terracotta).
    static let brand     = dyn(light: Color(hex: 0xC96442).opacity(0.75), dark: Color(hex: 0xDF8A67).opacity(0.70))
    /// Neutral hover/track fill.
    static let idle      = dyn(light: Color(hex: 0x141413).opacity(0.06), dark: Color.white.opacity(0.10))

    /// Attention/fault states — deliberately kept outside the accent so
    /// terracotta never means "error".
    static let danger    = dyn(light: Color(hex: 0xB8442F), dark: Color(hex: 0xF0705E))
    static let warn      = dyn(light: Color(hex: 0xB7791F), dark: Color(hex: 0xE0A82E))
    static let info      = dyn(light: Color(hex: 0x3B6FA0), dark: Color(hex: 0x5E9BDC))

    // MARK: Quality / latency tiers

    /// Dot-matrix landmass on the mini-map — present, never loud: a touch
    /// denser than a hairline so continents carry, two steps quieter than
    /// text so they never compete with the dots that mean something.
    static let mapLand = dyn(light: Color(hex: 0x141413).opacity(0.17),
                             dark: Color.white.opacity(0.22))

    /// Best → worst as an ink-density ramp: darker = better on light,
    /// brighter = better on dark. Hue stays reserved for the accent and
    /// genuine alerts, so a column of tier badges reads as neutral
    /// information rather than a wall of colour.
    static let tierExcellent = dyn(light: Color(hex: 0x141413).opacity(0.92), dark: Color.white.opacity(0.95))
    static let tierGood      = dyn(light: Color(hex: 0x141413).opacity(0.68), dark: Color.white.opacity(0.72))
    static let tierFair      = dyn(light: Color(hex: 0x141413).opacity(0.48), dark: Color.white.opacity(0.52))
    static let tierPoor      = dyn(light: Color(hex: 0x141413).opacity(0.32), dark: Color.white.opacity(0.40))

    /// System-Settings-class corner geometry: grouped surfaces use the
    /// tighter radii macOS itself uses for inset cards (10–14 pt), not the
    /// oversized 18 pt tiles. Chips stay fully rounded (Capsule).
    static let cardRadius: CGFloat = 14
    static let subRadius: CGFloat = 10

    // MARK: Gradients & shadows

    static var background: LinearGradient {
        LinearGradient(colors: [bgTop, bgBottom], startPoint: .top, endPoint: .bottom)
    }

    /// Specular top edge: a hairline brightest along the top, fading down
    /// the sides — the "raised tile" cue. Subtle on light (the shadow does
    /// most of the work there), stronger on dark where fills are fainter.
    static var edge: LinearGradient {
        LinearGradient(colors: [edgeHi, edgeLo], startPoint: .top, endPoint: .bottom)
    }
    private static let edgeHi = dyn(light: Color.white.opacity(0.85), dark: Color.white.opacity(0.12))
    private static let edgeLo = dyn(light: Color.white.opacity(0.10), dark: Color.white.opacity(0.03))
    static let shadowColor = dyn(light: Color(hex: 0x141413).opacity(0.10), dark: Color.black.opacity(0.28))
    static let shadowRadius: CGFloat = 11
    static let shadowY: CGFloat = 4

    // MARK: Motion

    /// House motion (fluid-interfaces discipline): critically damped springs
    /// everywhere by default — no overshoot on state changes a finger didn't
    /// flick. Two speeds cover the whole app; a bouncier spring is added only
    /// where the gesture itself carried momentum. Springs, not eased timers:
    /// they start from the live on-screen value, so an interrupting state
    /// change redirects the motion instead of fighting a scripted duration.
    static let spring = Animation.spring(response: 0.35, dampingFraction: 1.0)
    static let springQuick = Animation.spring(response: 0.22, dampingFraction: 1.0)

    // MARK: Type scale

    /// Size-specific tracking for the display voice — the optical-sizing
    /// rule that letter-spacing is never one value for every size. Headline
    /// sizes tighten (letters read too far apart as they grow); body and
    /// caption sizes stay neutral, where SF's small-size spacing already
    /// reads right.
    static func tracking(for size: CGFloat) -> CGFloat {
        size >= 17 ? -0.015 * size : 0
    }

    /// The whole app stays on one scale so hierarchy is rhythm, not accident:
    ///
    ///   Display (the headline voice, .display):
    ///     22  hero status        19  sheet titles / menu headline
    ///     17  section titles     15  inline headers     13  small headers
    ///
    ///   UI (sans — the control voice, .ui):
    ///     14  primary buttons     13  body / row titles
    ///     12  secondary controls  11  captions, eyebrows
    ///      9  micro badges
    ///
    /// Digits that line up (pings, byte counts, durations) are always
    /// monospaced. Off-scale sizes are a bug.
    ///
    /// The headline voice is the system font (SF Pro), Apple's own hierarchy
    /// move: one typeface everywhere, hierarchy carried by size and weight
    /// alone — exactly how System Settings, Finder and every first-party app
    /// type-set their windows.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight)
    }

    /// Sans control voice on the scale above. A named helper (not raw
    /// `.system(size:)`) so every call site is greppable and auditable
    /// against the scale.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// Monospaced digits for metrics so ticking values don't jitter their
    /// own layout.
    static func metric(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // MARK: Dynamic color plumbing

    /// A Color that resolves per-appearance. `NSColor(name:)` re-resolves on
    /// every system appearance change, so views re-render with the other
    /// palette live — no view-level `colorScheme` branching anywhere.
    private static func dyn(light: Color, dark: Color) -> Color {
        Color(NSColor(name: "loader.theme") { appearance in
            let isDark: Bool
            switch appearance.name {
            case .darkAqua, .vibrantDark,
                 .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark:
                isDark = true
            default:
                isDark = false
            }
            return isDark ? NSColor(dark) : NSColor(light)
        })
    }
}

/// Native window vibrancy — the same desktop-blur System Settings, Mail and
/// every first-party Mac app put behind their content. SwiftUI `.material`
/// can only blur in-window layers; NSVisualEffectView in `.underWindowBackground`
/// mode reaches through to whatever is behind the window. A whisper of the
/// warm ivory/charcoal gradient stays on top so the brand temperature
/// survives, at an opacity low enough that the blur clearly reads through.
struct VibrancyBackground: View {
    /// Reduced transparency: the desktop blur is exactly the effect the
    /// setting asks to drop — fall back to the opaque gradient so surfaces
    /// go frostier/solid instead of legibility collapsing over a busy
    /// desktop.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            Theme.background.ignoresSafeArea()
        } else {
            VisualEffectRep()
                .overlay(
                    LinearGradient(colors: [Theme.bgTop.opacity(0.20), Theme.bgBottom.opacity(0.32)],
                                   startPoint: .top, endPoint: .bottom)
                        .allowsHitTesting(false)
                )
                .ignoresSafeArea()
        }
    }
}

private struct VisualEffectRep: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

extension View {
    /// Themed single-line input: quiet fill, hairline stroke, accent ring on
    /// focus — replaces `.roundedBorder`, whose cool system chrome clashes
    /// with the warm ivory/charcoal surfaces (and whose white text background
    /// glared in the dark theme).
    func fieldChrome(focused: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.subRadius, style: .continuous)
        return self
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Theme.idle, in: shape)
            .overlay(shape.strokeBorder(focused ? Theme.accent.opacity(0.55) : Theme.stroke))
            .animation(Theme.springQuick, value: focused)
    }

    /// Grouped tile: a soft fill, a specular top edge, and a gentle shadow —
    /// warm and floating on light, quietly raised on dark.
    func softCard(_ radius: CGFloat = Theme.cardRadius,
                  fill: Color = Theme.card,
                  shadow: Bool = true) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(Theme.edge, lineWidth: 1))
            .shadow(color: shadow ? Theme.shadowColor : .clear,
                    radius: shadow ? Theme.shadowRadius : 0,
                    x: 0, y: shadow ? Theme.shadowY : 0)
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
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(max(0, n))
        var i = 0
        while value >= 1024 && i < units.count - 1 { value /= 1024; i += 1 }
        return i == 0 ? "\(Int(value)) B" : String(format: "%.1f %@", value, units[i])
    }

    static func speed(_ bytesPerSec: Int64) -> String { "\(bytes(bytesPerSec))/s" }

    /// Latency label: sub-millisecond reads "<1 ms" rather than a bare "0 ms",
    /// which looks like a placeholder. Negative (failed) reads "—".
    static func ping(_ ms: Int) -> String { ms < 0 ? "—" : (ms == 0 ? "<1 ms" : "\(ms) ms") }

    static func duration(since start: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%02d:%02d", m, sec)
    }
}