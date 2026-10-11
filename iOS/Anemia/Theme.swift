import SwiftUI
import UIKit

/// Claude's palette in two tones, as in the macOS app: warm ink and clay.
/// Clay means "active, or act on this"; the SF Symbol and the words say what
/// actually happened, so every state still reads in grayscale.
enum Theme {
    /// Ground: ivory #FAF9F5 / charcoal #262624.
    static let ground = dynamic(light: 0xFAF9F5, dark: 0x262624)
    /// Grouped rows: oat on ivory, a lighter charcoal on charcoal.
    static let card = dynamic(light: 0xF0EEE6, dark: 0x30302E)
    static let cardHigh = dynamic(light: 0xE8E6DC, dark: 0x3A3936)
    static let ink = dynamic(light: 0x141413, dark: 0xFAF9F5)
    static let inkSoft = dynamic(light: 0x6B6A64, dark: 0xA6A39B)
    /// Clay: #C6613F on ivory, the brighter #D97757 on charcoal.
    static let accent = dynamic(light: 0xC6613F, dark: 0xD97757)

    /// Hairlines and quiet fills — warm ink at a whisper.
    static var stroke: Color { ink.opacity(0.12) }
    static var idle: Color { ink.opacity(0.06) }
    /// The map's land.
    static var mapLand: Color { ink.opacity(0.16) }

    static let cardRadius: CGFloat = 14

    /// Critically damped: no overshoot on state changes a finger didn't flick.
    static let spring = Animation.spring(response: 0.35, dampingFraction: 1.0)
    static let springQuick = Animation.spring(response: 0.22, dampingFraction: 1.0)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat(rgb >> 16 & 0xFF) / 255,
            green: CGFloat(rgb >> 8 & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension View {
    /// Claude's ground under a grouped list.
    func anemiaList() -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.ground)
    }

    /// A grouped box, the shape iOS settings use.
    func anemiaCard(_ radius: CGFloat = Theme.cardRadius, fill: Color = Theme.card) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// The system button look for the running iOS: Liquid Glass on 26 and
    /// later, bordered before. Prominent buttons fill with clay.
    @ViewBuilder
    func nativeButtonStyle(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent).tint(Theme.accent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            if prominent {
                buttonStyle(.borderedProminent).tint(Theme.accent)
            } else {
                buttonStyle(.bordered)
            }
        }
    }
}
