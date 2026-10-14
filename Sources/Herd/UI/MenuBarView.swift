import AppKit
import SwiftUI

enum MenuBarLabelStyle: String, CaseIterable, Identifiable {
    case iconOnly, cpu, cpuAndMemory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iconOnly: "Icon only"
        case .cpu: "CPU"
        case .cpuAndMemory: "CPU and memory"
        }
    }
}

private enum MenuBarFormat {
    static func cpu(_ percent: Double) -> String {
        String(format: "%.0f%%", min(max(percent, 0), 100))
    }

    static func gigabytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return String(format: gb < 100 ? "%.1f GB" : "%.0f GB", gb)
    }
}

extension Notification.Name {
    static let openMainWindow = Notification.Name("HerdOpenMainWindow")
}

struct MenuBarLabel: View {
    let store: MonitorStore
    @AppStorage("menuBarLabelStyle") private var style: MenuBarLabelStyle = .cpuAndMemory
    @Environment(\.openWindow) private var openWindow

    private static let appSymbol = "gauge.with.dots.needle.33percent"

    // The label lives as long as the app, so it can reopen the main window after it was closed (e.g. from a notification).
    var body: some View {
        label
            .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { _ in
                openWindow(id: "main")
                NSApp.activate()
            }
    }

    @ViewBuilder
    private var label: some View {
        if style == .iconOnly || !store.hasFirstFrame {
            Image(systemName: Self.appSymbol)
                .accessibilityLabel("Herd")
        } else {
            Image(nsImage: renderedReadout)
                .accessibilityLabel(accessibilityText)
        }
    }

    private var readout: LabelReadout {
        LabelReadout(
            cpu: MenuBarFormat.cpu(store.headline.cpu * 100),
            memory: style == .cpuAndMemory ? MenuBarFormat.gigabytes(store.headline.memoryUsed) : nil
        )
    }

    private var renderedReadout: NSImage {
        MenuBarReadoutImage.image(cpu: readout.cpu, memory: readout.memory)
    }

    private var accessibilityText: String {
        let cpu = "Herd, CPU \(MenuBarFormat.cpu(store.headline.cpu * 100))"
        guard style == .cpuAndMemory else { return cpu }
        return "\(cpu), memory \(MenuBarFormat.gigabytes(store.headline.memoryUsed)) used"
    }
}

private struct LabelReadout {
    let cpu: String
    let memory: String?
}

// MenuBarExtra labels drop custom fonts and frames, so the readout is drawn as a template image to keep digits fixed-width.
// Drawing with AppKit and caching by text keeps this off the per-tick cost; a SwiftUI ImageRenderer rebuilt a view graph every update.
@MainActor
private enum MenuBarReadoutImage {
    private static var cacheKey = ""
    private static var cached = NSImage()
    private static let height: CGFloat = 16
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    private static let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)

    static func image(cpu: String, memory: String?) -> NSImage {
        let key = cpu + "|" + (memory ?? "")
        if key == cacheKey { return cached }
        let segments = [("cpu", cpu, "100%")] + (memory.map { [("memorychip", $0, "00.0 GB")] } ?? [])
        let image = draw(segments)
        cacheKey = key
        cached = image
        return image
    }

    private static func draw(_ segments: [(symbol: String, text: String, template: String)]) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let pieces = segments.map { segment in
            (icon: NSImage(systemSymbolName: segment.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(symbolConfig),
             text: segment.text as NSString,
             width: (segment.template as NSString).size(withAttributes: attributes).width)
        }
        let iconGap: CGFloat = 3
        let segmentGap: CGFloat = 7
        let totalWidth = pieces.reduce(0) { $0 + ($1.icon?.size.width ?? 0) + iconGap + $1.width } + segmentGap * CGFloat(max(pieces.count - 1, 0))
        let image = NSImage(size: NSSize(width: ceil(totalWidth), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for piece in pieces {
                if let icon = piece.icon {
                    icon.draw(in: NSRect(x: x, y: (height - icon.size.height) / 2, width: icon.size.width, height: icon.size.height))
                    x += icon.size.width + iconGap
                }
                let textSize = piece.text.size(withAttributes: attributes)
                piece.text.draw(at: NSPoint(x: x + piece.width - textSize.width, y: (height - textSize.height) / 2), withAttributes: attributes)
                x += piece.width + segmentGap
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

struct MenuBarView: View {
    @Environment(MonitorStore.self) private var store
    @Environment(ActionController.self) private var actions
    @Environment(\.openWindow) private var openWindow
    @AppStorage("menuBarMetric") private var metric: MetricColumn = .cpu
    @State private var frozenOrder: [String]?

    private static let width: CGFloat = 340
    private static let rowLimit = 6

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.groupSpacing) {
            SystemStats(store: store)
                .redacted(reason: store.hasFirstFrame ? [] : .placeholder)
            VStack(alignment: .leading, spacing: Theme.itemSpacing) {
                RankingHeader(metric: $metric)
                groupList
            }
            if let toast = actions.toast {
                FeedbackLine(message: toast)
            }
            Divider()
            MenuBarFooter(openMain: openMain)
        }
        .padding(Theme.innerPadding)
        .frame(width: Self.width)
        .animation(.easeOut(duration: 0.2), value: actions.toast)
        .background(WindowVisibilityReader { store.setSurface("menu", visible: $0) })
        .background(MenuBarPanel.Reader())
    }

    @ViewBuilder
    private var groupList: some View {
        VStack(spacing: 2) {
            if store.hasFirstFrame {
                ForEach(topGroups) { group in
                    GroupRow(
                        group: group,
                        metric: metric,
                        open: { openMain(selecting: group) },
                        quit: { quit(group) },
                        forceQuit: { forceQuit(group) }
                    )
                }
            } else {
                ForEach(0..<Self.rowLimit, id: \.self) { _ in PlaceholderRow() }
            }
        }
        .padding(.horizontal, -6)
        .onHover { hovering in
            frozenOrder = hovering ? rankedGroups.map(\.id) : nil
        }
    }

    private var rankedGroups: [AppGroup] {
        Array(store.groups.sorted { metric.value($0.metrics) > metric.value($1.metrics) }.prefix(Self.rowLimit))
    }

    // Rows hold their places while the pointer is over the list, so the quit button can't land on a different app mid-click.
    private var topGroups: [AppGroup] {
        guard let frozenOrder else { return rankedGroups }
        return frozenOrder.compactMap { id in store.groups.first { $0.id == id } }
    }

    private func openMain() {
        MenuBarPanel.dismiss()
        openWindow(id: "main")
        NSApp.activate()
    }

    private func openMain(selecting group: AppGroup) {
        store.requestedSelection = group.id
        openMain()
    }

    // A regular app quits through its own Quit command, which is safe to send in one click. Anything else gets signalled, so it asks first.
    private func quit(_ group: AppGroup) {
        guard ProcessActions.hasRunningApp(group) || ConfirmAlert.confirm(.quit, group) else { return }
        actions.runConfirmed(.quit, on: group)
    }

    private func forceQuit(_ group: AppGroup) {
        guard ConfirmAlert.confirm(.forceQuit, group) else { return }
        actions.runConfirmed(.forceQuit, on: group)
    }
}

// Confirmation dialogs attached to a MenuBarExtra window don't present reliably, so the menu bar asks through a modal alert.
@MainActor
private enum ConfirmAlert {
    static func confirm(_ action: ProcessAction, _ group: AppGroup) -> Bool {
        let pending = PendingAction(action: action, group: group)
        let alert = NSAlert()
        alert.alertStyle = action.isDestructive ? .warning : .informational
        alert.messageText = pending.title
        alert.informativeText = pending.message
        alert.addButton(withTitle: action.title).hasDestructiveAction = action.isDestructive
        alert.addButton(withTitle: "Cancel")
        MenuBarPanel.dismiss()
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MenuBarExtra has no API to close its panel, and opening another window only covers it: the panel stays up behind the
// window, the menu bar item still counts it as open, and the next click on the item closes it unseen, so nothing appears.
// Escape is the panel's own way out, so dismissing sends the same cancel action and the item's state stays in step.
@MainActor
private enum MenuBarPanel {
    private static weak var window: NSWindow?

    static func dismiss() {
        guard let window, window.isVisible else { return }
        let responder = window.firstResponder ?? window
        responder.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil)
    }

    struct Reader: NSViewRepresentable {
        func makeNSView(context: Context) -> ReaderView { ReaderView() }
        func updateNSView(_ nsView: ReaderView, context: Context) {}
    }

    final class ReaderView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { MenuBarPanel.window = window }
        }
    }
}

private struct SystemStats: View {
    let store: MonitorStore

    private static let sparklineSamples = 60

    var body: some View {
        HStack(alignment: .top, spacing: Theme.groupSpacing) {
            StatColumn(title: "CPU") {
                Text(Format.percent(store.system.cpuTotal * 100)).font(.displaySmall)
                Sparkline(
                    values: Array(store.systemHistory.cpu.values.suffix(Self.sparklineSamples)),
                    ceiling: 1,
                    capacity: Self.sparklineSamples
                )
                .frame(height: 16)
            }
            .frame(width: 72)
            StatColumn(title: "Memory") { memoryContent }
                .frame(maxWidth: .infinity, alignment: .leading)
            StatColumn(title: nil) { networkContent }
                .fixedSize()
        }
    }

    @ViewBuilder
    private var memoryContent: some View {
        Text(MenuBarFormat.gigabytes(store.system.memoryUsed))
            .font(.displaySmall)
            .lineLimit(1)
        PressureGauge(used: store.system.memoryUsed, total: store.system.memoryTotal, pressure: store.system.pressure)
    }

    @ViewBuilder
    private var networkContent: some View {
        RateLine(symbol: "arrow.down", color: Theme.netIn, label: "Download", rate: store.system.netInBps)
        RateLine(symbol: "arrow.up", color: Theme.netOut, label: "Upload", rate: store.system.netOutBps)
    }
}

private struct StatColumn<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                Text(title)
                    .font(.captionText)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .accessibilityElement(children: .combine)
    }
}

private struct RateLine: View {
    let symbol: String
    let color: Color
    let label: String
    let rate: Double

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.footnoteText.weight(.bold))
                .foregroundStyle(color)
            Text(Format.rate(rate))
                .font(.calloutText.monospacedDigit())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(Format.rate(rate))")
    }
}

private struct RankingHeader: View {
    @Binding var metric: MetricColumn

    private static let options: [MetricColumn] = [.cpu, .memory, .energy]

    var body: some View {
        HStack {
            Spacer()
            Picker("Rank apps by", selection: $metric) {
                ForEach(Self.options) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }
}

private struct GroupRow: View {
    let group: AppGroup
    let metric: MetricColumn
    let open: () -> Void
    let quit: () -> Void
    let forceQuit: () -> Void

    @State private var isHovered = false

    private var canAct: Bool { ProcessActions.canAct(on: group) }
    private var processCount: Int { group.processes.count }

    var body: some View {
        HStack(spacing: Theme.itemSpacing) {
            Button(action: open) {
                HStack(spacing: Theme.itemSpacing) {
                    GroupIcon(group: group, size: 16)
                    Text(group.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("\(processCount)")
                        .font(.metricSmall)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(processCount == 1 ? "1 process" : "\(processCount) processes")
                    Spacer(minLength: 4)
                    HeatValue(column: metric, value: metric.value(group.metrics), isApproximate: group.hasApproximateData)
                        .frame(width: 92)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAction(named: "Quit \(group.name)") { if canAct { quit() } }
            quitSlot
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: Theme.cornerRadius - 4, style: .continuous)
                .fill(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
        }
        .onHover { isHovered = $0 }
        .contextMenu { menuItems }
    }

    @ViewBuilder
    private var quitSlot: some View {
        if isHovered && canAct {
            Button(action: quit) {
                Image(systemName: "xmark")
                    .font(.captionText.weight(.semibold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Quit")
            .accessibilityLabel("Quit \(group.name)")
        } else {
            Color.clear.frame(width: 16, height: 16)
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Open in Herd", action: open)
        Divider()
        Button("Quit \(group.name)", action: quit)
            .disabled(!canAct)
        Button("Force Quit \(group.name)…", action: forceQuit)
            .disabled(!canAct)
    }
}

private struct PlaceholderRow: View {
    var body: some View {
        HStack(spacing: Theme.itemSpacing) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Theme.track)
                .frame(width: 16, height: 16)
            Text("Application name")
            Spacer()
            Text("00.0%").font(.metric)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }
}

private struct FeedbackLine: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "info.circle")
            .font(.calloutText)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .transition(.opacity)
    }
}

private struct MenuBarFooter: View {
    let openMain: () -> Void
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: Theme.itemSpacing) {
            Button("Open Herd", action: openMain)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            Spacer()
            Button {
                MenuBarPanel.dismiss()
                openSettings()
                NSApp.activate()
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Settings")
            .accessibilityLabel("Settings")
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .accessibilityLabel("Quit Herd")
        }
    }
}

struct PressureGauge: View {
    let used: UInt64
    let total: UInt64
    let pressure: MemoryPressure

    private var fraction: Double {
        total > 0 ? min(Double(used) / Double(total), 1) : 0
    }

    private var color: Color {
        pressure == .normal ? Theme.accent : Theme.pressureColor(pressure)
    }

    private var accessibilityText: String {
        switch pressure {
        case .normal: "Memory \(Int(fraction * 100)) percent used"
        case .warning: "Memory pressure high"
        case .critical: "Memory pressure critical"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule().fill(color).frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 4)
            if pressure != .normal {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.footnoteText)
                    .foregroundStyle(color)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
}
