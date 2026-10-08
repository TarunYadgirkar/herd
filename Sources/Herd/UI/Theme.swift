import AppKit
import SwiftUI

struct ColorPair: Sendable {
    let light: UInt32
    let dark: UInt32
}

enum Palette {
    static let pine = ColorPair(light: 0x28725E, dark: 0x5FB89E)
    static let slate = ColorPair(light: 0x577594, dark: 0x86A8CC)
    static let ochre = ColorPair(light: 0xA67628, dark: 0xE0AE5D)
    static let stone = ColorPair(light: 0x747D76, dark: 0x98A19A)
    static let ember = ColorPair(light: 0xCA4B20, dark: 0xF37344)
    static let fern = ColorPair(light: 0x337344, dark: 0x6FC082)
    static let amber = ColorPair(light: 0x955816, dark: 0xEAA950)
    static let brick = ColorPair(light: 0xAF342F, dark: 0xEA6A64)
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    static func adaptive(_ pair: ColorPair) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? pair.dark : pair.light)
        }
    }
}

extension Color {
    init(_ pair: ColorPair) {
        self.init(nsColor: .adaptive(pair))
    }
}

enum Theme {
    static let accent = Color(Palette.pine)
    static let neutral = Color(Palette.stone)
    static let warm = Color(Palette.ochre)
    static let hot = Color(Palette.ember)

    static let good = Color(Palette.fern)
    static let warning = Color(Palette.amber)
    static let critical = Color(Palette.brick)

    static let shadow = Color.black.opacity(0.15)
    static let surface = Color.primary.opacity(0.045)
    static let surfaceRaised = Color.primary.opacity(0.07)
    static let track = Color.primary.opacity(0.08)

    static let netIn = Color(Palette.pine)
    static let netOut = Color(Palette.slate)

    static let cornerRadius: CGFloat = 12
    static let innerRadius: CGFloat = 8
    static let innerPadding: CGFloat = 12
    static let groupSpacing: CGFloat = 16
    static let itemSpacing: CGFloat = 8

    static let cellRadius: CGFloat = 4
    static let heatFillOpacity = 0.4

    static func heatColor(_ heat: Double) -> Color {
        warm.mix(with: hot, by: heat)
    }

    static func heatFill(_ heat: Double) -> Color {
        heatColor(heat).opacity(heatFillOpacity * heat)
    }

    static func pressureColor(_ pressure: MemoryPressure) -> Color {
        switch pressure {
        case .normal: good
        case .warning: warning
        case .critical: critical
        }
    }
}

enum Typeface {
    static let text = "Red Hat Text"
    static let display = "Red Hat Display"
}

extension Font {
    static let titleText = Font.custom(Typeface.display, size: 22, relativeTo: .title).weight(.semibold)
    static let sectionTitle = Font.custom(Typeface.display, size: 18, relativeTo: .title2).weight(.semibold)
    static let headlineText = Font.custom(Typeface.text, size: 14, relativeTo: .headline).weight(.semibold)
    static let bodyText = Font.custom(Typeface.text, size: 14, relativeTo: .body)
    static let calloutText = Font.custom(Typeface.text, size: 13, relativeTo: .callout)
    static let subheadText = Font.custom(Typeface.text, size: 12.5, relativeTo: .subheadline)
    static let captionText = Font.custom(Typeface.text, size: 12, relativeTo: .caption)
    static let footnoteText = Font.custom(Typeface.text, size: 11, relativeTo: .caption2)

    static let metric = Font.custom(Typeface.text, size: 13, relativeTo: .body).monospacedDigit()
    static let metricSmall = Font.custom(Typeface.text, size: 12, relativeTo: .caption).monospacedDigit()
    static let display = Font.custom(Typeface.display, size: 30, relativeTo: .largeTitle).weight(.semibold).monospacedDigit()
    static let displaySmall = Font.custom(Typeface.display, size: 19, relativeTo: .title3).weight(.semibold).monospacedDigit()
}

extension View {
    func herdStyle() -> some View {
        font(.bodyText).tint(Theme.accent)
    }

    func surface(cornerRadius: CGFloat = Theme.cornerRadius) -> some View {
        background(Theme.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
