import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

enum Theme {
    static let accent = Color(hex: 0x2F7D6D)
    static let neutral = Color(hex: 0x8A9690)
    static let warm = Color(hex: 0xD9A441)
    static let hot = Color(hex: 0xD9534F)

    static let good = Color(hex: 0x3E9A5B)
    static let warning = Color(hex: 0xD08A1E)
    static let critical = Color(hex: 0xC8423C)

    static let shadow = Color.black.opacity(0.15)

    static let netIn = Color(hex: 0x2F7D6D)
    static let netOut = Color(hex: 0x6E8FB8)

    static let cornerRadius: CGFloat = 10
    static let innerPadding: CGFloat = 12
    static let groupSpacing: CGFloat = 16
    static let itemSpacing: CGFloat = 8

    static func heatColor(_ heat: Double) -> Color {
        heat < 0.5 ? warm : hot
    }

    static func pressureColor(_ pressure: MemoryPressure) -> Color {
        switch pressure {
        case .normal: good
        case .warning: warning
        case .critical: critical
        }
    }
}

extension Font {
    static let metric = Font.system(.body, design: .monospaced).monospacedDigit()
    static let metricSmall = Font.system(.caption, design: .monospaced).monospacedDigit()
    static let display = Font.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit()
    static let displaySmall = Font.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit()
}
