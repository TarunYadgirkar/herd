import AppKit
import SwiftUI

@MainActor
enum IconProvider {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for group: AppGroup) -> NSImage? {
        guard let path = group.bundlePath else { return nil }
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

struct GroupIcon: View {
    let group: AppGroup
    var size: CGFloat = 18

    var body: some View {
        if let image = IconProvider.icon(for: group) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: fallbackSymbol)
                .font(.system(size: size * 0.62, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        }
    }

    private var fallbackSymbol: String {
        if let runtime = group.runtime { return runtime.symbolName }
        return group.kind == .system ? "gearshape" : "terminal"
    }
}

extension EnvironmentValues {
    @Entry var historySamples: Int = Series.capacity
}

struct Sparkline: View {
    let values: [Double]
    var color: Color = Theme.accent
    var ceiling: Double?
    var capacity: Int?

    @Environment(\.historySamples) private var historySamples

    var body: some View {
        let capacity = capacity ?? historySamples
        let values = Array(values.suffix(capacity))
        Canvas { context, size in
            guard values.count > 1 else { return }
            let top = max(ceiling ?? 0, values.max() ?? 0, .leastNonzeroMagnitude)
            let step = size.width / CGFloat(max(capacity - 1, 1))
            let startX = size.width - CGFloat(values.count - 1) * step
            var line = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(
                    x: startX + CGFloat(index) * step,
                    y: size.height - CGFloat(value / top) * (size.height - 1)
                )
                index == 0 ? line.move(to: point) : line.addLine(to: point)
            }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: startX, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .color(color.opacity(0.18)))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.25, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

struct HeatValue: View {
    let column: MetricColumn
    let value: Double
    var isApproximate = false

    var body: some View {
        let heat = column.heat(value)
        Text((isApproximate ? "≈ " : "") + column.format(value))
            .font(.metric)
            .foregroundStyle(heat > 0.85 ? Theme.hot : .primary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background {
                if heat > 0 {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Theme.heatColor(heat).opacity(0.10 + heat * 0.22))
                }
            }
    }
}

struct StatePill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }
}
