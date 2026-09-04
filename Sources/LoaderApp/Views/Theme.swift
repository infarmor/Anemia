import SwiftUI

/// Dark visual theme inspired by AmneziaVPN: near-black background, a big
/// central connect control, soft cards, a mint accent for the secure state.
enum Theme {
    static let bgTop     = Color(hex: 0x0B0B0D)
    static let bgBottom  = Color(hex: 0x000000)
    static let card      = Color(hex: 0x121214)
    static let cardHi    = Color(hex: 0x1A1A1E)
    static let stroke    = Color.white.opacity(0.08)
    static let textHi    = Color.white
    static let textLo    = Color.white.opacity(0.5)
    static let accent    = Color(hex: 0x2FD180)   // connected / secure
    static let accentDim = Color(hex: 0x176B45)
    static let brand     = Color(hex: 0x8093C4)   // logo periwinkle
    static let idle      = Color(hex: 0x2A2A2E)
    static let danger    = Color(hex: 0xFF5A5F)
    static let warn      = Color(hex: 0xF5A623)

    static var background: LinearGradient {
        LinearGradient(colors: [bgTop, bgBottom], startPoint: .top, endPoint: .bottom)
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

    static func duration(since start: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%02d:%02d", m, sec)
    }
}
