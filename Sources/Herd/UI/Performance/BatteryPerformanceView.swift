import SwiftUI

struct BatteryPerformanceView: View {
    let context: PerformanceContext

    private var system: SystemSnapshot { context.system }

    var body: some View {
        if let percent = system.batteryDetails?.percent ?? system.battery?.percent {
            PerformanceHeader(
                title: "Battery",
                value: Format.percent(percent),
                symbol: BatteryGlyph.symbol(percent: percent, flow: flow),
                symbolTint: BatteryGlyph.tint(percent: percent, flow: flow),
                symbolLabel: status,
                caption: Text(status),
                stats: headlineStats
            )
            PerformanceChart(
                title: "Charge level",
                series: [ChartSeries(name: "Charge", color: ChartPalette.charge, values: context.values { $0.batteryPercent })],
                unit: .percent,
                context: context,
                yDomain: 0...100,
                height: 180
            )
            PerformanceChart(
                title: "Battery power",
                series: BatteryPowerSeries.series(context.points.map(\.batteryWatts)),
                unit: .watts,
                context: context,
                height: 180,
                emptyMessage: BatteryPowerSeries.emptyMessage(context.points.map(\.batteryWatts))
            )
            if let details = system.batteryDetails {
                BatteryDetailsCard(details: details)
            }
        } else {
            SectionMessage(title: "No battery", symbol: "battery.0percent")
        }
    }

    private var flow: BatteryFlow {
        if let details = system.batteryDetails { return BatteryFlow(details) }
        return BatteryFlow(isCharging: system.battery?.isCharging ?? false, isOnAC: system.battery?.isOnAC ?? false, watts: nil)
    }

    private var status: String {
        flow.summary(minutesRemaining: system.batteryDetails?.minutesRemaining ?? system.battery?.minutesRemaining)
    }

    private var headlineStats: [PerformanceStat] {
        guard let details = system.batteryDetails else { return [] }
        return [
            BatteryHealth.stat(details),
            details.cycleCount.map { PerformanceStat(label: "Cycles", value: "\($0)") },
            flow.watts.map { PerformanceStat(label: flow.powerLabel, value: Format.watts($0), tint: flow.isCharging ? Theme.good : nil) },
        ]
        .compactMap { $0 }
    }
}

// Both directions plot upward from 0 W, told apart by color, and each line only appears while that direction is happening.
enum BatteryPowerSeries {
    static func series(_ watts: [Double?]) -> [ChartSeries] {
        [
            ChartSeries(
                name: "Charging", color: ChartPalette.charging, values: values(watts, sign: 1),
                hidesZeroInCallout: true, breaksAtMissingValues: true
            ),
            ChartSeries(
                name: "Draining", color: ChartPalette.draining, values: values(watts, sign: -1),
                hidesZeroInCallout: true, breaksAtMissingValues: true
            ),
        ]
    }

    static func emptyMessage(_ watts: [Double?]) -> String {
        watts.contains { $0 != nil } ? "Not charging or draining" : PerformanceCopy.unavailable
    }

    // Samples next to a run read 0 W, so each run rises from and returns to the axis instead of floating.
    static func values(_ watts: [Double?], sign: Double) -> [Double?] {
        let magnitudes = watts.map { $0.map { $0 * sign } }
        let isActive = magnitudes.map { ($0 ?? 0) >= BatteryFlow.idleWatts }
        return magnitudes.indices.map { index in
            if isActive[index] { return magnitudes[index] }
            let touchesRun = (index > 0 && isActive[index - 1]) || (index + 1 < isActive.count && isActive[index + 1])
            return touchesRun && magnitudes[index] != nil ? 0 : nil
        }
    }
}

private enum BatteryGlyph {
    private static let lowPercent = 20.0
    private static let criticalPercent = 10.0

    static func symbol(percent: Double, flow: BatteryFlow) -> String {
        if flow.isCharging { return "battery.100percent.bolt" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    static func tint(percent: Double, flow: BatteryFlow) -> Color {
        switch flow {
        case .charging: return Theme.good
        case .pluggedInDraining: return Theme.warning
        case .pluggedInIdle: return .secondary
        case .draining: break
        }
        if percent <= criticalPercent { return Theme.critical }
        if percent <= lowPercent { return Theme.warning }
        return .secondary
    }
}

private enum BatteryHealth {
    private static let goodPercent = 80.0
    private static let normalCondition = "Normal"

    static func stat(_ details: BatteryDetails) -> PerformanceStat? {
        guard let health = details.healthPercent else { return nil }
        return PerformanceStat(
            label: "Health",
            value: Format.percent(health),
            help: details.condition == normalCondition ? nil : details.condition,
            level: health / 100,
            tint: tint(health: health, condition: details.condition)
        )
    }

    static func tint(health: Double, condition: String?) -> Color {
        if let condition, condition != normalCondition { return Theme.critical }
        return health >= goodPercent ? Theme.good : Theme.warning
    }
}

private struct BatteryDetailsCard: View {
    let details: BatteryDetails

    var body: some View {
        PerformanceCard(title: "Details") {
            StatGrid(stats: stats)
        }
    }

    private var stats: [PerformanceStat] {
        let entries: [(String, String?)] = [
            ("Cycles", details.cycleCount.map { "\($0)" }),
            ("Max capacity", details.maxCapacityMAh.map(Self.milliampHours)),
            ("Design capacity", details.designCapacityMAh.map(Self.milliampHours)),
            ("Voltage", details.voltage.map { String(format: "%.2f V", $0) }),
            ("Current", details.amperage.map { String(format: "%.2f A", abs($0)) }),
            ("Charger", details.adapterWatts.map { String(format: "%.0f W", $0) }),
            ("Temperature", details.celsius.map(PerformanceFormat.celsius)),
        ]
        let rest = entries.compactMap { label, value in value.map { PerformanceStat(label: label, value: $0) } }
        return [BatteryHealth.stat(details)].compactMap { $0 } + rest
    }

    private static func milliampHours(_ value: Int) -> String {
        "\(value.formatted()) mAh"
    }
}
