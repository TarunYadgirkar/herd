import SwiftUI

struct BatteryPerformanceView: View {
    let context: PerformanceContext

    private var system: SystemSnapshot { context.system }

    var body: some View {
        if let percent = system.batteryDetails?.percent ?? system.battery?.percent {
            PerformanceHeader(
                title: "Battery",
                value: Format.percent(percent),
                caption: status,
                stats: headlineStats,
                range: context.range
            )
            PerformanceChart(
                title: "Charge",
                series: [ChartSeries(name: "Charge", color: ChartPalette.charge, values: context.values { $0.batteryPercent })],
                unit: .percent,
                context: context,
                yDomain: 0...100,
                height: 180
            )
            PerformanceChart(
                title: "Power flow",
                series: flowSeries,
                unit: .watts,
                context: context,
                height: 180,
                help: "Above the line, power is charging the battery. Below it, the battery is powering your Mac."
            )
            if let details = system.batteryDetails {
                BatteryDetailsCard(details: details)
            }
        } else {
            SectionMessage(title: "Battery", symbol: "battery.0percent", message: "This Mac has no battery")
        }
    }

    private var flowSeries: [ChartSeries] {
        let watts = context.points.map(\.batteryWatts)
        return [
            ChartSeries(name: "Charging", color: ChartPalette.charging, values: watts.map { $0.map { max($0, 0) } }, hidesZeroInCallout: true),
            ChartSeries(name: "On battery", color: ChartPalette.draining, values: watts.map { $0.map { max(-$0, 0) } }, direction: -1, hidesZeroInCallout: true),
        ]
    }

    private var status: String {
        let remaining = (system.batteryDetails?.minutesRemaining ?? system.battery?.minutesRemaining)
            .map { Format.duration(TimeInterval($0 * 60)) }
        let isCharging = system.batteryDetails?.isCharging ?? system.battery?.isCharging ?? false
        let isOnAC = system.batteryDetails?.isOnAC ?? system.battery?.isOnAC ?? false
        if isCharging { return remaining.map { "Charging, full in \($0)" } ?? "Charging" }
        if isOnAC { return "Plugged in, not charging" }
        return remaining.map { "On battery, \($0) left" } ?? "On battery"
    }

    private var headlineStats: [PerformanceStat] {
        guard let details = system.batteryDetails else { return [] }
        return [
            details.healthPercent.map { PerformanceStat(label: "Health", value: Format.percent($0), help: "Capacity left compared with when the battery was new") },
            details.cycleCount.map { PerformanceStat(label: "Cycle count", value: "\($0)") },
            details.watts.map { PerformanceStat(label: $0 >= 0 ? "Charging at" : "Drawing", value: Format.watts($0)) },
        ]
        .compactMap { $0 }
    }
}

private struct BatteryDetailsCard: View {
    let details: BatteryDetails

    var body: some View {
        PerformanceCard(title: "Battery details") {
            StatGrid(stats: stats)
        }
    }

    private var stats: [PerformanceStat] {
        let entries: [(String, String?)] = [
            ("Health", details.healthPercent.map(Format.percent)),
            ("Cycle count", details.cycleCount.map { "\($0)" }),
            ("Full charge capacity", details.maxCapacityMAh.map(Self.milliampHours)),
            ("Design capacity", details.designCapacityMAh.map(Self.milliampHours)),
            ("Voltage", details.voltage.map { String(format: "%.2f V", $0) }),
            ("Current", details.amperage.map { String(format: "%.2f A", $0) }),
            ("Charger", details.adapterWatts.map { String(format: "%.0f W", $0) }),
            ("Temperature", details.celsius.map(PerformanceFormat.celsius)),
            ("Condition", details.condition),
        ]
        return entries.compactMap { label, value in value.map { PerformanceStat(label: label, value: $0) } }
    }

    private static func milliampHours(_ value: Int) -> String {
        "\(value.formatted()) mAh"
    }
}
