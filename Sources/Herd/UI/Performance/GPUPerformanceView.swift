import SwiftUI

struct GPUPerformanceView: View {
    let context: PerformanceContext

    private var system: SystemSnapshot { context.system }

    var body: some View {
        if let utilization = system.gpuUtilization {
            PerformanceHeader(
                title: "GPU",
                value: Format.percent(utilization * 100),
                stats: stats
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
            SectionMessage(title: PerformanceCopy.unavailable, symbol: PerformanceSection.gpu.symbol)
        }
    }

    private var stats: [PerformanceStat] {
        let peak = PerformanceStat(label: "Peak", value: context.peak(\.gpu).map { Format.percent($0 * 100) } ?? PerformanceFormat.missing)
        guard let power = system.power else { return [peak] }
        let wattage = PerformanceStat(label: "Power", value: Format.watts(power.gpuWatts))
        // Intel Macs have no GPU frequency table, so clocks are left out rather than shown as zero.
        guard power.gpuMaxFrequencyMHz > 0 else { return [wattage, peak] }
        return [
            PerformanceStat(label: "Frequency", value: PerformanceFormat.megahertz(power.gpuFrequencyMHz)),
            PerformanceStat(label: "Max", value: PerformanceFormat.megahertz(power.gpuMaxFrequencyMHz)),
            wattage,
            peak,
        ]
    }
}
