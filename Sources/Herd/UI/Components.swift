import AppKit
import SwiftUI

// Workspace icons carry 1024 px representations; drawing those at 18 pt on every update re-rasterizes them each time,
// so each icon is rendered once at the size it's shown and reused.
@MainActor
enum IconProvider {
    private static let cache = NSCache<NSString, NSImage>()
    private static let renderScale: CGFloat = 2

    static func icon(for group: AppGroup, size: CGFloat) -> NSImage? {
        group.bundlePath.map { icon(forPath: $0, size: size) }
    }

    static func icon(forPath path: String, size: CGFloat) -> NSImage {
        let key = "\(path)@\(Int(size))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = rendered(NSWorkspace.shared.icon(forFile: path), size: size)
        cache.setObject(image, forKey: key)
        return image
    }

    private static func rendered(_ source: NSImage, size: CGFloat) -> NSImage {
        let pixels = Int(size * renderScale)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return source }
        bitmap.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        return image
    }
}

struct GroupIcon: View {
    let group: AppGroup
    var size: CGFloat = 18

    var body: some View {
        if let image = IconProvider.icon(for: group, size: size) {
            Image(nsImage: image)
                .frame(width: size, height: size)
        } else {
            FallbackIcon(symbol: fallbackSymbol, size: size)
        }
    }

    private var fallbackSymbol: String {
        if let runtime = group.runtime { return runtime.symbolName }
        return group.kind == .system ? "gearshape" : "terminal"
    }
}

struct FallbackIcon: View {
    let symbol: String
    let size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.72))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
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
    var fillsWidth = false

    @Environment(\.historySamples) private var historySamples

    private static let minimumPoints = 2

    var body: some View {
        let window = capacity ?? historySamples
        let capacity = fillsWidth ? max(min(values.count, window), Self.minimumPoints) : window
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
        Text((isApproximate ? "≈ " : "") + column.format(value))
            .font(.metric)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Theme.heatFill(column.heat(value)),
                in: RoundedRectangle(cornerRadius: Theme.cellRadius, style: .continuous)
            )
    }
}

struct StatePill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.captionText.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}
