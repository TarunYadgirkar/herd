import SwiftUI

struct GPUPerformanceView: View {
    let context: PerformanceContext

    private var system: SystemSnapshot { context.system }

    var body: some View {
        if let utilization = system.gpuUtilization {
            PerformanceHeader(
                title: "GPU",
                value: Format.percent(utilization * 100),
                caption: "Graphics processor in use",
                stats: stats,
                range: context.range
            )
            PerformanceChart(
                title: "GPU usage",
                series: [ChartSeries(name: "GPU", color: ChartPalette.primary, values: context.values(\.gpu))],
                unit: .fraction,
                context: context,
                yDomain: 0...1
            )
            if system.power != nil {
                PerformanceChart(
                    title: "GPU power",
                    series: [ChartSeries(name: "GPU", color: ChartPalette.gpuPower, values: context.values(\.gpuWatts))],
                    unit: .watts,
                    context: context,
                    height: 160
                )
            }
        } else {
            SectionMessage(title: "GPU", symbol: PerformanceSection.gpu.symbol, message: PerformanceCopy.unavailable)
        }
    }

    private var stats: [PerformanceStat] {
        guard let power = system.power else {
            return [PerformanceStat(label: "Peak", value: context.peak(\.gpu).map { Format.percent($0 * 100) } ?? PerformanceFormat.missing)]
        }
        return [
            PerformanceStat(label: "Frequency", value: PerformanceFormat.megahertz(power.gpuFrequencyMHz), help: "Current GPU clock speed"),
            PerformanceStat(label: "Top speed", value: PerformanceFormat.megahertz(power.gpuMaxFrequencyMHz)),
            PerformanceStat(label: "Power", value: Format.watts(power.gpuWatts)),
            PerformanceStat(label: "Peak", value: context.peak(\.gpu).map { Format.percent($0 * 100) } ?? PerformanceFormat.missing),
        ]
    }
}
