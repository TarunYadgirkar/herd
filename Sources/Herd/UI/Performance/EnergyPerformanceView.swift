import SwiftUI

struct EnergyPerformanceView: View {
    let context: PerformanceContext
    let usage: [AppUsage]

    private static let secondsPerHour = 3_600.0

    var body: some View {
        if let power = context.system.power {
            PerformanceHeader(
                title: "Energy",
                value: Format.watts(power.systemWatts ?? power.packageWatts),
                caption: power.systemWatts == nil ? "used by the chip" : "used by the whole Mac",
                stats: stats(power),
                range: context.range
            )
            PerformanceChart(
                title: "Power use",
                series: powerSeries,
                unit: .watts,
                context: context,
                help: "Power drawn by each part of the chip. The line shows the whole Mac when macOS reports it."
            )
            EnergyTodayCard(usage: usage)
        } else {
            SectionMessage(title: "Energy", symbol: PerformanceSection.energy.symbol, message: PerformanceCopy.unavailable)
        }
    }

    private var powerSeries: [ChartSeries] {
        let points = context.points
        let stack = ChartSeries.stacked([
            ChartLayer(name: "CPU", color: ChartPalette.cpuPower, values: points.map { $0.cpuWatts ?? 0 }),
            ChartLayer(name: "GPU", color: ChartPalette.gpuPower, values: points.map { $0.gpuWatts ?? 0 }),
            ChartLayer(name: "Neural Engine", color: ChartPalette.anePower, values: points.map { $0.aneWatts ?? 0 }),
            ChartLayer(name: "Memory", color: ChartPalette.dramPower, values: points.map { $0.dramWatts ?? 0 }),
        ])
        let system = ChartSeries(name: "Whole Mac", color: ChartPalette.total, values: points.map(\.systemWatts), fill: .none, lineWidth: 1.25)
        return system.hasData ? stack + [system] : stack
    }

    private func stats(_ power: PowerReading) -> [PerformanceStat] {
        let used = context.total { point in
            point.systemWatts ?? point.cpuWatts.map { $0 + (point.gpuWatts ?? 0) + (point.aneWatts ?? 0) }
        }
        return [
            PerformanceStat(label: "CPU", value: Format.watts(power.cpuWatts), color: ChartPalette.cpuPower),
            PerformanceStat(label: "GPU", value: Format.watts(power.gpuWatts), color: ChartPalette.gpuPower),
            PerformanceStat(label: "Neural Engine", value: Format.watts(power.aneWatts), help: "Power used for on-device machine learning", color: ChartPalette.anePower),
            PerformanceStat(label: "Memory", value: Format.watts(power.dramWatts), color: ChartPalette.dramPower),
            PerformanceStat(
                label: "Used",
                value: PerformanceFormat.wattHours(used / Self.secondsPerHour),
                help: "Energy used over the last \(context.historyRange.title)"
            ),
        ]
    }
}

private struct EnergyTodayCard: View {
    let usage: [AppUsage]

    private static let rowLimit = 15
    private static let numberWidth: CGFloat = 84

    var body: some View {
        PerformanceCard(title: "Energy by app today", help: "Energy each app has used since midnight.") {
            Text("Since midnight").font(.captionText).foregroundStyle(.secondary)
        } content: {
            if usage.isEmpty {
                ChartMessage(text: "No app activity recorded yet today.", height: 80)
            } else {
                table
            }
        }
    }

    private var table: some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.groupSpacing, verticalSpacing: Theme.itemSpacing) {
            GridRow {
                Text("App")
                numberHeader("Energy")
                numberHeader("CPU time")
                numberHeader("Network")
                numberHeader("Disk")
            }
            .font(.captionText)
            .foregroundStyle(.secondary)
            Divider()
            ForEach(usage.prefix(Self.rowLimit)) { row in
                GridRow {
                    UsageAppLabel(usage: row)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    number(PerformanceFormat.wattHours(row.energyWattHours))
                    number(PerformanceFormat.cpuTime(row.cpuSeconds))
                    number(PerformanceFormat.bytes(row.networkBytes))
                    number(PerformanceFormat.bytes(row.diskBytes))
                }
            }
        }
    }

    private func numberHeader(_ title: String) -> some View {
        Text(title)
            .frame(minWidth: Self.numberWidth, alignment: .trailing)
            .gridColumnAlignment(.trailing)
    }

    private func number(_ value: String) -> some View {
        Text(value)
            .font(.metric)
            .frame(minWidth: Self.numberWidth, alignment: .trailing)
    }
}
