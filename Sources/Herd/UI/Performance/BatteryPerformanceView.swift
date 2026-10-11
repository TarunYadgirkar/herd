import SwiftUI

struct BatteryPerformanceView: View {
    let context: PerformanceContext

    private var system: SystemSnapshot { context.system }

    var body: some View {
        if let percent = system.batteryDetails?.percent ?? system.battery?.percent {
            PerformanceHeader(
                title: "Battery",
                value: Format.percent(percent),
                symbol: BatteryGlyph.symbol(percent: percent, isPowered: isCharging || isOnAC),
                symbolTint: BatteryGlyph.tint(percent: percent, isCharging: isCharging, isOnAC: isOnAC),
                symbolLabel: status,
                caption: remaining.map { Text($0) },
                stats: headlineStats
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
                height: 180
            )
            if let details = system.batteryDetails {
                BatteryDetailsCard(details: details)
            }
        } else {
            SectionMessage(title: "No battery", symbol: "battery.0percent")
        }
    }

    private var isCharging: Bool {
        system.batteryDetails?.isCharging ?? system.battery?.isCharging ?? false
    }

    private var isOnAC: Bool {
        system.batteryDetails?.isOnAC ?? system.battery?.isOnAC ?? false
    }

    private var remaining: String? {
        (system.batteryDetails?.minutesRemaining ?? system.battery?.minutesRemaining)
            .map { Format.duration(TimeInterval($0 * 60)) }
    }

    private var flowSeries: [ChartSeries] {
        let watts = context.points.map(\.batteryWatts)
        return [
            ChartSeries(name: "Charge", color: ChartPalette.charging, values: watts.map { $0.map { max($0, 0) } }, hidesZeroInCallout: true),
            ChartSeries(name: "Drain", color: ChartPalette.draining, values: watts.map { $0.map { max(-$0, 0) } }, direction: -1, hidesZeroInCallout: true),
        ]
    }

    private var status: String {
        if isCharging { return remaining.map { "Charging, full in \($0)" } ?? "Charging" }
        if isOnAC { return "Plugged in, not charging" }
        return remaining.map { "On battery, \($0) left" } ?? "On battery"
    }

    private var headlineStats: [PerformanceStat] {
        guard let details = system.batteryDetails else { return [] }
        return [
            BatteryHealth.stat(details),
            details.cycleCount.map { PerformanceStat(label: "Cycles", value: "\($0)") },
            details.watts.map { PerformanceStat(label: "Power", value: Format.watts($0), tint: $0 >= 0 ? Theme.good : nil) },
        ]
        .compactMap { $0 }
    }
}

private enum BatteryGlyph {
    private static let lowPercent = 20.0
    private static let criticalPercent = 10.0

    static func symbol(percent: Double, isPowered: Bool) -> String {
        if isPowered { return "battery.100percent.bolt" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    static func tint(percent: Double, isCharging: Bool, isOnAC: Bool) -> Color {
        if isCharging { return Theme.good }
        if isOnAC { return .secondary }
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
            ("Current", details.amperage.map { String(format: "%.2f A", $0) }),
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
