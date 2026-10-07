import SwiftUI

struct PulseHeader: View {
    @Environment(MonitorStore.self) private var store

    var body: some View {
        PulseTiles(system: store.system, history: store.systemHistory)
        .padding(.horizontal, Theme.innerPadding)
        .padding(.vertical, Theme.itemSpacing)
        .redacted(reason: store.hasFirstFrame ? [] : .placeholder)
    }
}

private enum TileKind: Int, Identifiable, Comparable {
    case cpu, memory, gpu, network, disk, power

    var id: Int { rawValue }

    // Fixed ideal widths keep ViewThatFits from flipping tiles in and out as digit widths change.
    var idealWidth: CGFloat {
        switch self {
        case .cpu: 170
        case .memory: 210
        case .gpu: 130
        case .network, .disk: 150
        case .power: 120
        }
    }

    static func < (lhs: TileKind, rhs: TileKind) -> Bool { lhs.rawValue < rhs.rawValue }
}

private struct PulseTiles: View {
    let system: SystemSnapshot
    let history: SystemHistory

    private static let minimumTiles = 2

    @State private var width: CGFloat = 0

    // ViewThatFits lays out every candidate row on each update; counting against fixed ideal widths is one arithmetic pass.
    var body: some View {
        let kinds = prioritizedKinds
        TileRow(kinds: kinds.prefix(fittingCount(kinds)).sorted(), system: system, history: history)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { width = $0 })
    }

    private func fittingCount(_ kinds: [TileKind]) -> Int {
        var used: CGFloat = 0
        var count = 0
        for kind in kinds {
            let next = used + kind.idealWidth + (count > 0 ? Theme.itemSpacing : 0)
            guard next <= width else { break }
            used = next
            count += 1
        }
        return max(count, Self.minimumTiles)
    }

    private var prioritizedKinds: [TileKind] {
        let isThermalAlert = system.thermal != .nominal
        let hasPowerTile = system.battery != nil || isThermalAlert
        var kinds: [TileKind] = [.cpu, .memory]
        if isThermalAlert { kinds.append(.power) }
        kinds.append(.network)
        if system.gpuUtilization != nil { kinds.append(.gpu) }
        kinds.append(.disk)
        if hasPowerTile && !isThermalAlert { kinds.append(.power) }
        return kinds
    }
}

private struct TileRow: View {
    let kinds: [TileKind]
    let system: SystemSnapshot
    let history: SystemHistory

    var body: some View {
        HStack(alignment: .top, spacing: Theme.itemSpacing) {
            ForEach(kinds) { tile(for: $0) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func tile(for kind: TileKind) -> some View {
        switch kind {
        case .cpu: CPUTile(system: system, history: history.cpu)
        case .memory: MemoryTile(system: system)
        case .gpu: GPUTile(utilization: system.gpuUtilization ?? 0, history: history.gpu)
        case .network:
            RateTile(
                kind: .network, title: "Network",
                down: RateLine(name: "Download", rate: system.netInBps, series: history.netIn, color: Theme.netIn),
                up: RateLine(name: "Upload", rate: system.netOutBps, series: history.netOut, color: Theme.netOut)
            )
        case .disk:
            RateTile(
                kind: .disk, title: "Disk",
                down: RateLine(name: "Read", rate: system.diskReadBps, series: history.diskRead, color: Theme.netIn),
                up: RateLine(name: "Write", rate: system.diskWriteBps, series: history.diskWrite, color: Theme.netOut)
            )
        case .power: PowerTile(battery: system.battery, thermal: system.thermal)
        }
    }
}

private struct Tile<Accessory: View, Content: View>: View {
    let title: String
    let kind: TileKind
    let summary: String
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    private static var headerHeight: CGFloat { 18 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Theme.itemSpacing) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                accessory
            }
            .frame(minHeight: Self.headerHeight)
            content
        }
        .padding(.horizontal, Theme.innerPadding)
        .padding(.vertical, Theme.itemSpacing)
        .frame(minWidth: kind.idealWidth, idealWidth: kind.idealWidth, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summary)
    }
}

extension Tile where Accessory == EmptyView {
    init(title: String, kind: TileKind, summary: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, kind: kind, summary: summary, accessory: { EmptyView() }, content: content)
    }
}

private enum Spark {
    static let height: CGFloat = 28
    static let minWidth: CGFloat = 36
}

private struct CPUTile: View {
    let system: SystemSnapshot
    let history: Series

    private static let hotThreshold = 0.9

    var body: some View {
        let percent = Format.percent(system.cpuTotal * 100)
        Tile(
            title: "CPU", kind: .cpu,
            summary: "CPU, \(percent) in use across \(system.perCoreUsage.count) cores"
        ) {
            CoreStrip(usage: system.perCoreUsage)
        } content: {
            HStack(spacing: Theme.itemSpacing) {
                Text(percent)
                    .font(.display)
                    .foregroundStyle(system.cpuTotal > Self.hotThreshold ? Theme.hot : .primary)
                    .fixedSize()
                Sparkline(values: history.values, ceiling: 1)
                    .frame(minWidth: Spark.minWidth, maxWidth: .infinity)
                    .frame(height: Spark.height)
            }
        }
    }
}

private struct CoreStrip: View {
    let usage: [Double]

    private static let height: CGFloat = 12
    private static let denseCoreCount = 16

    var body: some View {
        let isDense = usage.count > Self.denseCoreCount
        HStack(alignment: .bottom, spacing: isDense ? 1 : 2) {
            ForEach(usage.indices, id: \.self) { index in
                CoreBar(usage: usage[index], width: isDense ? 2.5 : 3, height: Self.height)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct CoreBar: View {
    let usage: Double
    let width: CGFloat
    let height: CGFloat

    private static let calmCeiling = 0.4
    private static let hotFloor = 0.8

    var body: some View {
        ZStack(alignment: .bottom) {
            Capsule().fill(.quaternary)
            Capsule()
                .fill(color)
                .frame(height: max(width, height * usage))
        }
        .frame(width: width, height: height)
    }

    private var color: Color {
        guard usage >= Self.calmCeiling else { return Theme.accent }
        return Theme.heatColor(usage >= Self.hotFloor ? 1 : 0)
    }
}

private struct GPUTile: View {
    let utilization: Double
    let history: Series

    var body: some View {
        let percent = Format.percent(utilization * 100)
        Tile(title: "GPU", kind: .gpu, summary: "GPU, \(percent) busy") {
            HStack(spacing: Theme.itemSpacing) {
                Text(percent)
                    .font(.display)
                    .fixedSize()
                Sparkline(values: history.values, ceiling: 1)
                    .frame(minWidth: Spark.minWidth, maxWidth: .infinity)
                    .frame(height: Spark.height)
            }
        }
    }
}

private struct MemoryTile: View {
    let system: SystemSnapshot

    private static let gigabyte = 1_073_741_824.0
    private static let heavySwapShare = 0.5

    var body: some View {
        Tile(title: "Memory", kind: .memory, summary: summary) {
            if system.pressure != .normal {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.pressureColor(system.pressure))
            }
        } content: {
            VStack(alignment: .leading, spacing: 4) {
                Text(Format.bytes(system.memoryUsed)).font(.displaySmall)
                HStack(spacing: Theme.itemSpacing) {
                    MemoryBar(system: system)
                    if system.swapUsed > 0 { swapLabel }
                }
            }
        }
    }

    private var swapLabel: some View {
        HStack(spacing: 3) {
            Image(systemName: "externaldrive.fill").font(.caption2)
            Text(Format.bytes(system.swapUsed)).font(.metricSmall)
        }
        .foregroundStyle(isSwapHeavy ? Theme.warning : .secondary)
        .fixedSize()
        .help("Swap")
    }

    private var isSwapHeavy: Bool {
        system.swapTotal > 0 && Double(system.swapUsed) > Double(system.swapTotal) * Self.heavySwapShare
    }

    private var totalLabel: String {
        String(format: "%.0f GB", Double(system.memoryTotal) / Self.gigabyte)
    }

    private var pressureName: String {
        switch system.pressure {
        case .normal: "normal"
        case .warning: "high"
        case .critical: "critical"
        }
    }

    private var summary: String {
        let swap = system.swapUsed > 0 ? ", swap \(Format.bytes(system.swapUsed))" : ""
        return "Memory, \(Format.bytes(system.memoryUsed)) of \(totalLabel) used, pressure \(pressureName)\(swap)"
    }
}

private struct MemorySegment: Identifiable {
    let name: String
    let bytes: UInt64
    let color: Color

    var id: String { name }
}

private struct MemoryBar: View {
    let system: SystemSnapshot

    private static let height: CGFloat = 6
    private static let minWidth: CGFloat = 60

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: proxy.size.width * share(of: segment))
                }
            }
        }
        .frame(minWidth: Self.minWidth, maxWidth: .infinity)
        .frame(height: Self.height)
        .background(.quaternary)
        .clipShape(Capsule())
        .help(tooltip)
    }

    private var segments: [MemorySegment] {
        [
            MemorySegment(name: "App memory", bytes: system.appMemory, color: Theme.accent),
            MemorySegment(name: "Wired", bytes: system.wiredMemory, color: Theme.netOut),
            MemorySegment(name: "Compressed", bytes: system.compressedMemory, color: Theme.warm),
            MemorySegment(name: "Cached files", bytes: system.cachedFiles, color: Theme.neutral),
        ]
    }

    private func share(of segment: MemorySegment) -> CGFloat {
        guard system.memoryTotal > 0 else { return 0 }
        return min(CGFloat(segment.bytes) / CGFloat(system.memoryTotal), 1)
    }

    private var tooltip: String {
        segments.map { "\($0.name) \(Format.bytes($0.bytes))" }.joined(separator: "\n")
    }
}

private struct RateLine {
    let name: String
    let rate: Double
    let series: Series
    let color: Color
}

private struct RateTile: View {
    let kind: TileKind
    let title: String
    let down: RateLine
    let up: RateLine

    var body: some View {
        Tile(
            title: title, kind: kind,
            summary: "\(title), \(down.name.lowercased()) \(Format.rate(down.rate)), \(up.name.lowercased()) \(Format.rate(up.rate))"
        ) {
            HStack(spacing: Theme.itemSpacing) {
                VStack(alignment: .leading, spacing: 2) {
                    rateText(down, symbol: "arrow.down")
                    rateText(up, symbol: "arrow.up")
                }
                .fixedSize()
                ZStack {
                    Sparkline(values: down.series.values, color: down.color, ceiling: sharedCeiling)
                    Sparkline(values: up.series.values, color: up.color, ceiling: sharedCeiling)
                }
                .frame(minWidth: Spark.minWidth, maxWidth: .infinity)
                .frame(height: Spark.height)
            }
        }
    }

    private var sharedCeiling: Double { max(down.series.peak, up.series.peak) }

    private func rateText(_ line: RateLine, symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(line.color)
            Text(Format.rate(line.rate)).font(.metric)
        }
    }
}

private struct PowerTile: View {
    let battery: BatteryInfo?
    let thermal: ProcessInfo.ThermalState

    private static let lowBattery = 20.0

    var body: some View {
        Tile(title: battery == nil ? "Temperature" : "Battery", kind: .power, summary: summary) {
            ThermalGlyph(thermal: thermal)
        } content: {
            if let battery {
                batteryContent(battery)
            } else {
                ThermalGlyph(thermal: thermal).font(.displaySmall)
            }
        }
    }

    private func batteryContent(_ battery: BatteryInfo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: Self.symbol(for: battery))
                .foregroundStyle(isLow(battery) ? Theme.critical : .secondary)
            Text(Format.percent(battery.percent)).font(.displaySmall)
            if let remaining = Self.remaining(battery) {
                Text(remaining)
                    .font(.metricSmall)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }

    private func isLow(_ battery: BatteryInfo) -> Bool {
        !battery.isOnAC && battery.percent < Self.lowBattery
    }

    private static func symbol(for battery: BatteryInfo) -> String {
        if battery.isCharging || battery.isOnAC { return "battery.100percent.bolt" }
        switch battery.percent {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private static func remaining(_ battery: BatteryInfo) -> String? {
        guard !battery.isOnAC else { return nil }
        return battery.minutesRemaining.map { Format.duration(TimeInterval($0 * 60)) }
    }

    private static func status(of battery: BatteryInfo) -> String {
        if battery.isCharging { return "charging" }
        if battery.isOnAC { return "plugged in" }
        return remaining(battery).map { "\($0) remaining" } ?? "on battery"
    }

    private var summary: String {
        let charge = battery.map { "Battery \(Format.percent($0.percent)), \(Self.status(of: $0))" }
        let heat = ThermalGlyph.spokenState(thermal).map { "Temperature \($0)" }
        return [charge, heat].compactMap { $0 }.joined(separator: ", ")
    }
}

private struct ThermalGlyph: View {
    let thermal: ProcessInfo.ThermalState

    var body: some View {
        if let color {
            HStack(spacing: 2) {
                Image(systemName: thermal == .fair ? "thermometer.medium" : "thermometer.high")
                if isThrottling { Image(systemName: "tortoise.fill") }
            }
            .foregroundStyle(color)
            .accessibilityLabel(Self.spokenState(thermal) ?? "")
        }
    }

    private var isThrottling: Bool { thermal == .serious || thermal == .critical }

    private var color: Color? {
        switch thermal {
        case .fair: Theme.warning
        case .serious, .critical: Theme.critical
        default: nil
        }
    }

    static func spokenState(_ thermal: ProcessInfo.ThermalState) -> String? {
        switch thermal {
        case .fair: "warm"
        case .serious, .critical: "hot, CPU slowed to cool down"
        default: nil
        }
    }
}
