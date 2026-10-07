import SwiftUI

struct CPUPerformanceView: View {
    let context: PerformanceContext
    let cores: [CorePoint]

    private var system: SystemSnapshot { context.system }

    var body: some View {
        PerformanceHeader(
            title: "CPU",
            value: Format.percent(system.cpuTotal * 100),
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
            yDomain: 0...1,
            help: "User is work done by apps. System is work done by macOS on their behalf."
        )
        CoreGrid(usage: system.perCoreUsage, history: cores, readings: system.power?.clusters)
    }

    private var stats: [PerformanceStat] {
        var stats = [
            PerformanceStat(label: "User", value: Format.percent(system.cpuUser * 100), help: "Work done by apps", color: ChartPalette.cpuUser),
            PerformanceStat(label: "System", value: Format.percent(system.cpuSystem * 100), help: "Work done by macOS on their behalf", color: ChartPalette.cpuSystem),
            PerformanceStat(label: "Cores", value: "\(system.perCoreUsage.count)"),
            PerformanceStat(
                label: "Load average",
                value: PerformanceFormat.load(system.loadAverage),
                help: "Average number of tasks waiting to run over the last 1, 5 and 15 minutes."
            ),
        ]
        if let kernel = system.kernelCPUPercent {
            stats.append(PerformanceStat(
                label: "kernel_task",
                value: Format.percent(kernel),
                help: "macOS raises kernel_task to keep the CPU cool when your Mac is hot."
            ))
        }
        stats.append(PerformanceStat(label: "Uptime", value: Format.duration(system.uptime)))
        return stats
    }
}
