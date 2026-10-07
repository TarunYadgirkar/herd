import SwiftUI

struct PulseHeader: View {
    @Environment(MonitorStore.self) private var store
    @Environment(ActionController.self) private var actions

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemSpacing) {
            PulseTiles(system: store.system, history: store.systemHistory)
            CulpritLine(groups: store.groups, isReady: store.hasFirstFrame, actions: actions)
        }
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

    var body: some View {
        let kinds = prioritizedKinds
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: kinds.count, through: Self.minimumTiles, by: -1)), id: \.self) { count in
                TileRow(kinds: kinds.prefix(count).sorted(), system: system, history: history)
            }
        }
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
                kind: .network, title: "Network", quietCeiling: 102_400,
                down: RateLine(name: "Download", rate: system.netInBps, series: history.netIn, color: Theme.netIn),
                up: RateLine(name: "Upload", rate: system.netOutBps, series: history.netOut, color: Theme.netOut),
                help: "Data coming in and going out over all network connections."
            )
        case .disk:
            RateTile(
                kind: .disk, title: "Disk", quietCeiling: 1_048_576,
                down: RateLine(name: "Read", rate: system.diskReadBps, series: history.diskRead, color: Theme.netIn),
                up: RateLine(name: "Write", rate: system.diskWriteBps, series: history.diskWrite, color: Theme.netOut),
                help: "Data read from and written to your drives."
            )
        case .power: PowerTile(battery: system.battery, thermal: system.thermal)
        }
    }
}

private struct TileTrace {
    let series: Series
    let color: Color
}

private struct Tile<Accessory: View, Content: View>: View {
    let title: String
    let kind: TileKind
    let summary: String
    let help: String
    var traces: [TileTrace] = []
    var traceCeiling: Double?
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    private static var headerHeight: CGFloat { 18 }
    private static var traceHeight: CGFloat { 34 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Theme.itemSpacing) {
                Text(title)
                    .font(.captionText)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                accessory
            }
            .frame(minHeight: Self.headerHeight)
            HStack(alignment: .bottom, spacing: Theme.groupSpacing) {
                content
                if !traces.isEmpty { trace }
            }
        }
        .padding(.horizontal, Theme.innerPadding)
        .padding(.vertical, Theme.itemSpacing)
        .frame(minWidth: kind.idealWidth, idealWidth: kind.idealWidth, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .surface()
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summary)
    }

    private var trace: some View {
        ZStack {
            ForEach(traces.indices, id: \.self) { index in
                Sparkline(values: traces[index].series.values, color: traces[index].color, ceiling: traceCeiling, fillsWidth: true)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .frame(height: Self.traceHeight)
        .clipped()
    }
}

extension Tile where Accessory == EmptyView {
    init(
        title: String, kind: TileKind, summary: String, help: String,
        traces: [TileTrace] = [], traceCeiling: Double? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title, kind: kind, summary: summary, help: help, traces: traces, traceCeiling: traceCeiling,
            accessory: { EmptyView() }, content: content
        )
    }
}

private struct CPUTile: View {
    let system: SystemSnapshot
    let history: Series

    private static let hotThreshold = 0.9

    var body: some View {
        let percent = Format.percent(system.cpuTotal * 100)
        Tile(
            title: "CPU", kind: .cpu,
            summary: "CPU, \(percent) in use across \(system.perCoreUsage.count) cores",
            help: "How much of all CPU cores is in use. Each small bar is one core.",
            traces: [TileTrace(series: history, color: Theme.accent)],
            traceCeiling: 1
        ) {
            CoreStrip(usage: system.perCoreUsage)
        } content: {
            Text(percent)
                .font(.display)
                .foregroundStyle(system.cpuTotal > Self.hotThreshold ? Theme.hot : .primary)
                .fixedSize()
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
            Capsule().fill(Theme.track)
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
        Tile(
            title: "GPU", kind: .gpu, summary: "GPU, \(percent) busy", help: "How busy the graphics processor is.",
            traces: [TileTrace(series: history, color: Theme.accent)], traceCeiling: 1
        ) {
            Text(percent)
                .font(.display)
                .fixedSize()
        }
    }
}

private struct MemoryTile: View {
    let system: SystemSnapshot

    private static let gigabyte = 1_073_741_824.0
    private static let heavySwapShare = 0.5

    var body: some View {
        Tile(
            title: "Memory", kind: .memory, summary: summary,
            help: "Memory pressure shows how hard macOS is working to find free memory. Swap is memory moved to disk, which is much slower."
        ) {
            StatePill(text: pressureTitle, color: Theme.pressureColor(system.pressure))
        } content: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Format.bytes(system.memoryUsed)).font(.displaySmall)
                    Text("of \(totalLabel)").font(.captionText.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack(spacing: Theme.itemSpacing) {
                    MemoryBar(system: system)
                    if system.swapUsed > 0 { swapLabel }
                }
            }
        }
    }

    private var swapLabel: some View {
        Text("Swap \(Format.bytes(system.swapUsed))")
            .font(.metricSmall)
            .foregroundStyle(isSwapHeavy ? Theme.warning : .secondary)
            .fixedSize()
    }

    private var isSwapHeavy: Bool {
        system.swapTotal > 0 && Double(system.swapUsed) > Double(system.swapTotal) * Self.heavySwapShare
    }

    private var totalLabel: String {
        String(format: "%.0f GB", Double(system.memoryTotal) / Self.gigabyte)
    }

    private var pressureTitle: String {
        switch system.pressure {
        case .normal: "Normal"
        case .warning: "Under pressure"
        case .critical: "Critical"
        }
    }

    private var summary: String {
        let swap = system.swapUsed > 0 ? ", swap \(Format.bytes(system.swapUsed))" : ""
        return "Memory, \(Format.bytes(system.memoryUsed)) of \(totalLabel) used, pressure \(pressureTitle)\(swap)"
    }
}

private struct MemorySegment: Identifiable {
    let name: String
    let explanation: String
    let bytes: UInt64
    let color: Color

    var id: String { name }
}

private struct MemoryBar: View {
    let system: SystemSnapshot

    private static let height: CGFloat = 8
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
        .background(Theme.track)
        .clipShape(Capsule())
        .help(tooltip)
    }

    private var segments: [MemorySegment] {
        [
            MemorySegment(name: "App memory", explanation: "used by open apps and their helpers.", bytes: system.appMemory, color: Theme.accent),
            MemorySegment(name: "Wired", explanation: "reserved by macOS itself and can't be freed.", bytes: system.wiredMemory, color: Theme.netOut),
            MemorySegment(name: "Compressed", explanation: "squeezed to make room. A lot of it means memory is tight.", bytes: system.compressedMemory, color: Theme.warm),
            MemorySegment(name: "Cached files", explanation: "recently used files kept for speed. macOS frees these first when apps need room.", bytes: system.cachedFiles, color: Theme.neutral),
        ]
    }

    private func share(of segment: MemorySegment) -> CGFloat {
        guard system.memoryTotal > 0 else { return 0 }
        return min(CGFloat(segment.bytes) / CGFloat(system.memoryTotal), 1)
    }

    private var tooltip: String {
        segments.map { "\($0.name), \(Format.bytes($0.bytes)): \($0.explanation)" }.joined(separator: "\n")
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
    let quietCeiling: Double
    let down: RateLine
    let up: RateLine
    let help: String

    var body: some View {
        Tile(
            title: title, kind: kind,
            summary: "\(title), \(down.name.lowercased()) \(Format.rate(down.rate)), \(up.name.lowercased()) \(Format.rate(up.rate))",
            help: help,
            traces: [TileTrace(series: down.series, color: down.color), TileTrace(series: up.series, color: up.color)],
            traceCeiling: sharedCeiling
        ) {
            VStack(alignment: .leading, spacing: 2) {
                rateText(down, symbol: "arrow.down")
                rateText(up, symbol: "arrow.up")
            }
            .fixedSize()
        }
    }

    private var sharedCeiling: Double { max(down.series.peak, up.series.peak, quietCeiling) }

    private func rateText(_ line: RateLine, symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.calloutText.weight(.bold))
                .foregroundStyle(line.color)
            Text(Format.rate(line.rate)).font(.displaySmall)
        }
    }
}

private struct PowerTile: View {
    let battery: BatteryInfo?
    let thermal: ProcessInfo.ThermalState

    private static let lowBattery = 20.0

    var body: some View {
        Tile(title: battery == nil ? "Temperature" : "Battery", kind: .power, summary: summary, help: help) {
            if let pill = thermalPill { StatePill(text: pill.title, color: pill.color) }
        } content: {
            if let battery {
                batteryContent(battery)
            } else {
                Text(thermalDetail)
                    .font(.captionText)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func batteryContent(_ battery: BatteryInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: Self.symbol(for: battery))
                    .font(.calloutText)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(glyphColor(battery))
                Text(Format.percent(battery.percent)).font(.display)
            }
            if let remaining = Self.remaining(of: battery) {
                Text(remaining)
                    .font(.captionText.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func isLow(_ battery: BatteryInfo) -> Bool {
        !battery.isOnAC && battery.percent < Self.lowBattery
    }

    private func glyphColor(_ battery: BatteryInfo) -> Color {
        if isLow(battery) { return Theme.critical }
        return battery.isOnAC ? Theme.good : .secondary
    }

    private static func symbol(for battery: BatteryInfo) -> String {
        if battery.isOnAC { return "battery.100percent.bolt" }
        switch battery.percent {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private static func remaining(of battery: BatteryInfo) -> String? {
        guard let minutes = battery.minutesRemaining, battery.isCharging || !battery.isOnAC else { return nil }
        let duration = Format.duration(TimeInterval(minutes * 60))
        return battery.isCharging ? "Full in \(duration)" : "\(duration) left"
    }

    private static func status(of battery: BatteryInfo) -> String {
        let remaining = battery.minutesRemaining.map { Format.duration(TimeInterval($0 * 60)) }
        if battery.isCharging { return remaining.map { "Full in \($0)" } ?? "Charging" }
        if battery.isOnAC { return "Plugged in" }
        return remaining.map { "\($0) left" } ?? "On battery"
    }

    private var thermalPill: (title: String, color: Color)? {
        switch thermal {
        case .nominal: nil
        case .fair: ("Warm", Theme.warning)
        case .serious: ("Hot", Theme.critical)
        case .critical: ("Throttling", Theme.critical)
        @unknown default: nil
        }
    }

    private var thermalDetail: String {
        switch thermal {
        case .serious, .critical: "macOS is slowing the CPU to cool down."
        default: "Running warmer than usual."
        }
    }

    private var help: String {
        thermalPill == nil
            ? "Battery charge and time remaining."
            : "When your Mac gets hot, macOS slows the CPU to cool it down, which makes everything feel slower."
    }

    private var summary: String {
        let charge = battery.map { "Battery \(Format.percent($0.percent)), \(Self.status(of: $0))" }
        let heat = thermalPill.map { "Temperature \($0.title)" }
        return [charge, heat].compactMap { $0 }.joined(separator: ", ")
    }
}

private struct CulpritLine: View {
    let groups: [AppGroup]
    let isReady: Bool
    let actions: ActionController

    private static let cpuThreshold = 15.0
    private static let rowHeight: CGFloat = 26

    var body: some View {
        HStack(spacing: Theme.itemSpacing) {
            if isReady {
                culprits
            } else {
                Text("Checking which apps use the most CPU and memory")
                    .font(.calloutText)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: Self.rowHeight)
    }

    @ViewBuilder
    private var culprits: some View {
        let cpu = topCPU
        let memory = topMemory
        if let cpu, let memory, cpu.id == memory.id {
            CulpritChip(group: cpu, readings: [cpuReading(cpu), memoryReading(memory)], actions: actions)
        } else {
            if let cpu { CulpritChip(group: cpu, readings: [cpuReading(cpu)], actions: actions) }
            if let memory { CulpritChip(group: memory, readings: [memoryReading(memory)], actions: actions) }
        }
    }

    private var topCPU: AppGroup? {
        groups.max { $0.metrics.cpu < $1.metrics.cpu }.flatMap { $0.metrics.cpu >= Self.cpuThreshold ? $0 : nil }
    }

    private var topMemory: AppGroup? {
        groups.max { $0.metrics.memory < $1.metrics.memory }.flatMap { $0.metrics.memory > 0 ? $0 : nil }
    }

    private func cpuReading(_ group: AppGroup) -> CulpritReading {
        let percent = Format.percent(group.metrics.cpu)
        let count = group.processes.count
        let detail = count > 1 ? "\(percent) across \(count) processes" : percent
        return CulpritReading(column: .cpu, value: detail, phrase: "the most CPU, \(detail)")
    }

    private func memoryReading(_ group: AppGroup) -> CulpritReading {
        let bytes = Format.bytes(group.metrics.memory)
        return CulpritReading(column: .memory, value: bytes, phrase: "the most memory, \(bytes)")
    }
}

private struct CulpritReading: Identifiable {
    let column: MetricColumn
    let value: String
    let phrase: String

    var id: MetricColumn { column }
}

private struct CulpritChip: View {
    let group: AppGroup
    let readings: [CulpritReading]
    let actions: ActionController

    var body: some View {
        HStack(spacing: Theme.itemSpacing) {
            HStack(spacing: 6) {
                GroupIcon(group: group, size: 16)
                Text(group.name)
                    .font(.calloutText.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                ForEach(readings) { reading in
                    Label {
                        Text(reading.value).font(.metric)
                    } icon: {
                        Image(systemName: reading.column.symbol).foregroundStyle(Theme.warm)
                    }
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(sentence)
            if ProcessActions.canAct(on: group) {
                Button("Quit") { actions.request(.quit, on: group) }
                    .buttonStyle(.borderless)
                    .font(.calloutText.weight(.medium))
                    .help("Quit \(group.name)")
                    .accessibilityLabel("Quit \(group.name)")
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(Theme.surface, in: Capsule())
        .help(sentence)
    }

    private var sentence: String {
        "\(group.name) is using " + readings.map(\.phrase).joined(separator: " and ")
    }
}
