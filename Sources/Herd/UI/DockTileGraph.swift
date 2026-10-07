import AppKit

enum DockGraphSettings {
    static let enabledKey = "dockCPUGraph"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
}

// Drawn with AppKit into a plain image so updating the Dock every tick stays cheap.
@MainActor
final class DockTileGraph {
    private static let samples = 24
    private static let tileSize: CGFloat = 128
    private static let inset: CGFloat = 14
    private static let corner: CGFloat = 28

    private var values: [Double] = []
    private var imageView: NSImageView?

    func update(cpu: Double) {
        guard DockGraphSettings.isEnabled else {
            reset()
            return
        }
        values = Array((values + [min(max(cpu, 0), 1)]).suffix(Self.samples))
        let view = imageView ?? install()
        view.image = render()
        NSApp.dockTile.display()
    }

    private func install() -> NSImageView {
        let view = NSImageView(frame: NSRect(x: 0, y: 0, width: Self.tileSize, height: Self.tileSize))
        NSApp.dockTile.contentView = view
        imageView = view
        return view
    }

    private func reset() {
        guard imageView != nil else { return }
        imageView = nil
        values = []
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
    }

    private func render() -> NSImage {
        let size = NSSize(width: Self.tileSize, height: Self.tileSize)
        return NSImage(size: size, flipped: false) { rect in
            let plate = rect.insetBy(dx: Self.inset, dy: Self.inset)
            NSColor(white: 0.1, alpha: 0.92).setFill()
            NSBezierPath(roundedRect: plate, xRadius: Self.corner, yRadius: Self.corner).fill()
            self.drawBars(in: plate.insetBy(dx: 10, dy: 12))
            return true
        }
    }

    private func drawBars(in area: NSRect) {
        let count = CGFloat(Self.samples)
        let gap: CGFloat = 1.5
        let width = (area.width - gap * (count - 1)) / count
        let offset = CGFloat(Self.samples - values.count)
        for (index, value) in values.enumerated() {
            let x = area.minX + (offset + CGFloat(index)) * (width + gap)
            let height = max(area.height * value, 2)
            barColor(value).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: area.minY, width: width, height: height), xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    private func barColor(_ value: Double) -> NSColor {
        let accent = NSColor(srgbRed: 0x3A / 255, green: 0xB0 / 255, blue: 0x94 / 255, alpha: 1)
        let warm = NSColor(srgbRed: 0xD9 / 255, green: 0xA4 / 255, blue: 0x41 / 255, alpha: 1)
        let hot = NSColor(srgbRed: 0xD9 / 255, green: 0x53 / 255, blue: 0x4F / 255, alpha: 1)
        if value > 0.85 { return hot }
        return value > 0.6 ? warm : accent
    }
}
