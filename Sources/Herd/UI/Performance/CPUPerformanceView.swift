import SwiftUI

struct CPUPerformanceView: View {
    let context: PerformanceContext
    let cores: [CorePoint]

    private var system: SystemSnapshot { context.system }

    var body: some View {
        PerformanceHeader(
            title: "CPU",
            value: Format.percent(system.cpuTotal * 100),
            caption: Text("User \(Format.percent(system.cpuUser * 100)) · System \(Format.percent(system.cpuSystem * 100))"),
            stats: stats,
            range: context.range
        )
        PerformanceChart(
            title: "CPU usage",
            series: ChartSeries.stacked([
                ChartLayer(name: "User", color: ChartPalette.cpuUser, values: context.points.map(\.cpuUser)),
                ChartLayer(name: "System", color: ChartPalette.cpuSystem, values: context.points.map(\.cpuSystem)),
            ]),
            unit: .fraction,
            context: context,
            yDomain: 0...1
        )
        CoreGrid(usage: system.perCoreUsage, history: cores, readings: system.power?.clusters, temperatures: system.sensors?.temperatures ?? [])
    }

    private var stats: [PerformanceStat] {
        var stats = [
            PerformanceStat(label: "Load", value: PerformanceFormat.load(system.loadAverage), help: "1, 5, 15 min"),
        ]
        if let kernel = system.kernelCPUPercent {
            stats.append(PerformanceStat(label: "kernel_task", value: Format.percent(kernel)))
        }
        stats.append(PerformanceStat(label: "Uptime", value: Format.duration(system.uptime)))
        return stats
    }
}
