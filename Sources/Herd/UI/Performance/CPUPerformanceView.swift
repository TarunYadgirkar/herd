import SwiftUI

struct CPUPerformanceView: View {
    let context: PerformanceContext
    let cores: [CorePoint]

    private var system: SystemSnapshot { context.system }

    var body: some View {
        PerformanceHeader(
            title: "CPU",
            value: Format.percent(system.cpuTotal * 100),
            stats: stats
        )
        PerformanceChart(
            title: "CPU usage",
            series: ChartSeries.stacked([
                ChartLayer(name: "User", color: ChartPalette.cpuUser, values: context.points.map(\.cpuUser)),
                ChartLayer(name: "System", color: ChartPalette.cpuSystem, values: context.points.map(\.cpuSystem)),
            ]),
            unit: .fraction,
            context: context,
            yDomain: 0...1,
            contributors: .cpu
        )
        CoreGrid(
            usage: system.perCoreUsage,
            history: cores,
            range: context.historyRange,
            readings: system.power?.clusters,
            temperatures: system.sensors?.temperatures ?? []
        )
    }

    private var stats: [PerformanceStat] {
        var stats = [
            PerformanceStat(label: "User", value: Format.percent(system.cpuUser * 100), swatch: ChartPalette.cpuUser),
            PerformanceStat(label: "System", value: Format.percent(system.cpuSystem * 100), swatch: ChartPalette.cpuSystem),
            PerformanceStat(label: "Load", value: PerformanceFormat.load(system.loadAverage), help: "1, 5, 15 min"),
        ]
        if let kernel = system.kernelCPUPercent {
            stats.append(PerformanceStat(label: "kernel_task", value: Format.percent(kernel)))
        }
        stats.append(PerformanceStat(label: "Uptime", value: Format.duration(system.uptime)))
        return stats
    }
}
