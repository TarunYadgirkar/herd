import SwiftUI

struct SensorsPerformanceView: View {
    let context: PerformanceContext

    var body: some View {
        if let sensors = context.system.sensors {
            PerformanceHeader(
                title: "Sensors",
                value: sensors.cpuCelsius.map(PerformanceFormat.celsius) ?? PerformanceFormat.missing,
                caption: "CPU temperature",
                stats: stats(sensors),
                range: context.range
            ) {
                if let pill = ThermalCopy.pill(context.system.thermal) { StatePill(text: pill.title, color: pill.color) }
            }
            PerformanceChart(
                title: "Temperature",
                series: [
                    ChartSeries(name: "CPU", color: ChartPalette.cpuTemperature, values: context.values { $0.cpuCelsius }, fill: .none, lineWidth: 2),
                    ChartSeries(name: "GPU", color: ChartPalette.gpuTemperature, values: context.values { $0.gpuCelsius }, fill: .none, lineWidth: 2),
                ],
                unit: .celsius,
                context: context,
                includesZero: false
            )
            if !sensors.fans.isEmpty {
                PerformanceChart(
                    title: "Fan speed",
                    series: [ChartSeries(name: "Fan", color: ChartPalette.fan, values: context.values { $0.fanRPM })],
                    unit: .rpm,
                    context: context,
                    height: 160
                )
            }
            SensorListCard(sensors: sensors)
        } else {
            SectionMessage(title: "Sensors", symbol: PerformanceSection.sensors.symbol, message: PerformanceCopy.unavailable)
        }
    }

    private func stats(_ sensors: SensorReading) -> [PerformanceStat] {
        let readings: [(String, Double?)] = [
            ("CPU hottest", sensors.cpuMaxCelsius),
            ("GPU", sensors.gpuCelsius),
            ("SSD", sensors.ssdCelsius),
            ("Battery", sensors.batteryCelsius),
        ]
        let temperatures = readings.compactMap { label, value in value.map { PerformanceStat(label: label, value: PerformanceFormat.celsius($0)) } }
        let fans = sensors.fans.map { PerformanceStat(label: $0.name, value: PerformanceFormat.rpm($0.rpm)) }
        let noFans = sensors.fans.isEmpty ? [PerformanceStat(label: "Fans", value: "None", help: "This Mac cools itself without fans.")] : []
        return temperatures + fans + noFans
    }
}

enum ThermalCopy {
    static func pill(_ thermal: ProcessInfo.ThermalState) -> (title: String, color: Color)? {
        switch thermal {
        case .nominal: nil
        case .fair: ("Warm", Theme.warning)
        case .serious: ("Hot", Theme.critical)
        case .critical: ("Throttling", Theme.critical)
        @unknown default: nil
        }
    }
}

enum HeatScale {
    static let warmCelsius = 70.0
    static let hotCelsius = 90.0

    static func color(for celsius: Double) -> Color? {
        if celsius >= hotCelsius { return Theme.hot }
        if celsius >= warmCelsius { return Theme.warm }
        return nil
    }
}

private struct SensorGroup: Identifiable {
    let name: String
    let readings: [TemperatureReading]

    var id: String { name }
}

private struct SensorListCard: View {
    let sensors: SensorReading

    private static let columnWidth: CGFloat = 220

    var body: some View {
        PerformanceCard(title: "All sensors", help: "Every temperature sensor macOS reports, updated live.") {
            if sensors.temperatures.isEmpty {
                ChartMessage(text: PerformanceCopy.unavailable, height: 60)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: Self.columnWidth), spacing: Theme.groupSpacing, alignment: .topLeading)],
                    alignment: .leading,
                    spacing: Theme.groupSpacing
                ) {
                    ForEach(groups) { SensorGroupView(group: $0) }
                }
            }
        }
    }

    private var groups: [SensorGroup] {
        Dictionary(grouping: sensors.temperatures) { $0.name.split(separator: " ").first.map(String.init) ?? $0.name }
            .map { SensorGroup(name: $0.key, readings: $0.value.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private struct SensorGroupView: View {
    let group: SensorGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.name)
                .font(.subheadline.weight(.semibold))
            ForEach(group.readings) { reading in
                HStack(spacing: Theme.itemSpacing) {
                    Text(reading.name)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: Theme.itemSpacing)
                    Text(PerformanceFormat.celsius(reading.celsius))
                        .font(.metric)
                        .foregroundStyle(HeatScale.color(for: reading.celsius) ?? .primary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
