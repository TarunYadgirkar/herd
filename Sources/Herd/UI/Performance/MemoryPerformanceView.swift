import Charts
import SwiftUI

struct MemoryPerformanceView: View {
    let context: PerformanceContext

    private var system: SystemSnapshot { context.system }

    var body: some View {
        PerformanceHeader(
            title: "Memory",
            value: Format.bytes(system.memoryUsed),
            caption: Text("of \(PerformanceFormat.gigabytes(system.memoryTotal, decimals: 0)) GB"),
            stats: stats,
            range: context.range
        ) {
            Image(systemName: MemoryPressureCopy.symbol(system.pressure))
                .font(.headline)
                .foregroundStyle(Theme.pressureColor(system.pressure))
                .accessibilityLabel("Memory pressure \(MemoryPressureCopy.title(system.pressure))")
        }
        PerformanceChart(
            title: "Memory in use",
            series: memorySeries,
            unit: .bytes,
            context: context,
            yDomain: 0...Double(max(system.memoryTotal, 1)),
            contributors: .memory
        )
        PressureCard(context: context)
        PerformanceChart(
            title: "Swap used",
            series: [ChartSeries(name: "Swap", color: ChartPalette.swap, values: context.values { $0.swapUsed })],
            unit: .bytes,
            context: context,
            height: 160
        )
    }

    private var memorySeries: [ChartSeries] {
        let points = context.points
        let stack = ChartSeries.stacked([
            ChartLayer(name: "App", color: ChartPalette.appMemory, values: points.map(\.appMemory)),
            ChartLayer(name: "Wired", color: ChartPalette.wiredMemory, values: points.map(\.wiredMemory)),
            ChartLayer(name: "Compressed", color: ChartPalette.compressedMemory, values: points.map(\.compressedMemory)),
        ])
        let cached = ChartSeries(
            name: "Cached", color: ChartPalette.cachedFiles, values: points.map(\.cachedFiles),
            baseline: points.map { $0.appMemory + $0.wiredMemory + $0.compressedMemory },
            fill: .solid(opacity: ChartPalette.bandOpacity), lineWidth: 0
        )
        let used = ChartSeries(name: "Used", color: ChartPalette.total, values: points.map(\.memoryUsed), fill: .none, lineWidth: 1.25)
        return stack + [cached, used]
    }

    private var stats: [PerformanceStat] {
        [
            PerformanceStat(label: "App", value: Format.bytes(system.appMemory)),
            PerformanceStat(label: "Wired", value: Format.bytes(system.wiredMemory), help: "Can't be freed"),
            PerformanceStat(label: "Compressed", value: Format.bytes(system.compressedMemory)),
            PerformanceStat(label: "Cached", value: Format.bytes(system.cachedFiles), help: "Freed first"),
            PerformanceStat(label: "Swap", value: swapValue),
        ]
    }

    private var swapValue: String {
        guard system.swapTotal > 0 else { return Format.bytes(system.swapUsed) }
        return "\(Format.bytes(system.swapUsed)) of \(Format.bytes(system.swapTotal))"
    }
}

enum MemoryPressureCopy {
    static func title(_ pressure: MemoryPressure) -> String {
        switch pressure {
        case .normal: "Normal"
        case .warning: "High"
        case .critical: "Critical"
        }
    }

    static func symbol(_ pressure: MemoryPressure) -> String {
        switch pressure {
        case .normal: "gauge.with.dots.needle.33percent"
        case .warning: "gauge.with.dots.needle.67percent"
        case .critical: "gauge.with.dots.needle.100percent"
        }
    }
}

private struct PressureSegment: Identifiable {
    let start: Date
    let end: Date
    let pressure: MemoryPressure

    var id: Date { start }
}

private struct PressureCard: View {
    let context: PerformanceContext

    private static let stripHeight: CGFloat = 14

    var body: some View {
        PerformanceCard(title: "Memory pressure") {
            ChartLegend(items: [MemoryPressure.normal, .warning, .critical].map {
                LegendItem(name: MemoryPressureCopy.title($0), color: Theme.pressureColor($0))
            })
        } content: {
            strip
        }
    }

    @ViewBuilder
    private var strip: some View {
        if context.isCollecting {
            ChartMessage(text: PerformanceCopy.collecting, height: Self.stripHeight * 2)
        } else {
            let segments = self.segments
            let selected = context.selectedIndex
            Chart {
                ForEach(segments) { segment in
                    RectangleMark(xStart: .value("Start", segment.start), xEnd: .value("End", segment.end), yStart: .value("Low", 0), yEnd: .value("High", 1))
                        .foregroundStyle(Theme.pressureColor(segment.pressure))
                }
                if let selected {
                    RuleMark(x: .value("Time", context.dates[selected]))
                        .foregroundStyle(ChartPalette.rule)
                }
            }
            .chartXScale(domain: context.xDomain)
            .chartYScale(domain: 0...1)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: Self.stripHeight)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .accessibilityLabel("Memory pressure over time")
            .accessibilityValue(accessibilitySummary(segments))
        }
    }

    private var segments: [PressureSegment] {
        let points = context.points
        guard let first = points.first, let last = points.last else { return [] }
        var result: [PressureSegment] = []
        let runs = context.segments
        var start = first.date
        var level = MemoryPressure(rawValue: first.pressure) ?? .normal
        for index in points.indices.dropFirst() {
            let point = points[index]
            let next = MemoryPressure(rawValue: point.pressure) ?? .normal
            let isGap = runs[index] != runs[index - 1]
            guard next != level || isGap else { continue }
            result.append(PressureSegment(start: start, end: isGap ? points[index - 1].date : point.date, pressure: level))
            start = point.date
            level = next
        }
        result.append(PressureSegment(start: start, end: last.date, pressure: level))
        return result
    }

    private func accessibilitySummary(_ segments: [PressureSegment]) -> String {
        let tight = segments.filter { $0.pressure != .normal }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        guard tight > 0 else { return "Normal the whole time" }
        return "High for \(Format.duration(tight)). Now \(MemoryPressureCopy.title(context.system.pressure))"
    }
}
