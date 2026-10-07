import SwiftUI

struct SensorsPerformanceView: View {
    let context: PerformanceContext

    var body: some View {
        if let sensors = context.system.sensors {
            PerformanceHeader(
                title: "Sensors",
                value: sensors.cpuCelsius.map(PerformanceFormat.celsius) ?? PerformanceFormat.missing,
                caption: Text("CPU"),
                stats: stats(sensors),
                range: context.range
            ) {
                ThermalBadge(thermal: context.system.thermal)
            }
            PerformanceChart(
                title: "Temperature",
                series: [
                    ChartSeries(name: "CPU", color: ChartPalette.cpuTemperature, values: context.values { $0.cpuCelsius }, fill: .none, lineWidth: 2),
                    ChartSeries(name: "GPU", color: ChartPalette.gpuTemperature, values: context.values { $0.gpuCelsius }, fill: .none, lineWidth: 2),
                    ChartSeries(name: "Lid", color: ChartPalette.lidTemperature, values: context.values { $0.lidCelsius }, fill: .none, lineWidth: 2),
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
            SectionMessage(title: PerformanceCopy.unavailable, symbol: PerformanceSection.sensors.symbol)
        }
    }

    private func stats(_ sensors: SensorReading) -> [PerformanceStat] {
        let readings: [(String, Double?)] = [
            ("CPU max", sensors.cpuMaxCelsius),
            ("GPU", sensors.gpuCelsius),
            ("Lid", sensors.lidCelsius),
            ("Palm rest", sensors.palmRestCelsius),
            ("SSD", sensors.ssdCelsius),
            ("Battery", sensors.batteryCelsius),
        ]
        let temperatures = readings.compactMap { label, value in value.map { PerformanceStat(label: label, value: PerformanceFormat.celsius($0)) } }
        let fans = sensors.fans.map { PerformanceStat(label: $0.name, value: PerformanceFormat.rpm($0.rpm)) }
        let noFans = sensors.fans.isEmpty ? [PerformanceStat(label: "Fans", value: "None")] : []
        return temperatures + fans + noFans
    }
}

struct ThermalBadge: View {
    let thermal: ProcessInfo.ThermalState

    var body: some View {
        if let style {
            HStack(spacing: 3) {
                Image(systemName: style.symbol)
                if thermal == .critical { Image(systemName: "tortoise.fill") }
            }
            .font(.headline)
            .foregroundStyle(style.color)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(style.label)
        }
    }

    private var style: (symbol: String, color: Color, label: String)? {
        switch thermal {
        case .nominal: nil
        case .fair: ("thermometer.medium", Theme.warning, "Warm")
        case .serious: ("thermometer.high", Theme.critical, "Hot")
        case .critical: ("thermometer.high", Theme.critical, "Hot, throttling")
        @unknown default: nil
        }
    }
}

// Chips run hot by design; skin and storage feel or throttle at much lower temperatures.
enum HeatScale {
    static func color(for celsius: Double, zone: SensorZone) -> Color? {
        let limits = thresholds(zone)
        if celsius >= limits.hot { return Theme.hot }
        if celsius >= limits.warm { return Theme.warm }
        return nil
    }

    private static func thresholds(_ zone: SensorZone) -> (warm: Double, hot: Double) {
        switch zone {
        case .surface: (38, 45)
        case .inside, .storage: (60, 75)
        case .memory: (75, 90)
        case .superCores, .performanceCores, .cpu, .gpu: (70, 90)
        }
    }
}

private struct SensorListCard: View {
    let sensors: SensorReading

    var body: some View {
        PerformanceCard(title: "Sensors") {
            if sensors.temperatures.isEmpty {
                ChartMessage(text: PerformanceCopy.unavailable, height: 60)
            } else {
                VStack(alignment: .leading, spacing: Theme.groupSpacing) {
                    ForEach(zones, id: \.self) { zone in
                        ZoneRow(zone: zone, readings: sensors.temperatures.filter { $0.zone == zone })
                    }
                }
            }
        }
    }

    private var zones: [SensorZone] {
        Set(sensors.temperatures.map(\.zone)).sorted()
    }
}

private struct ZoneRow: View {
    let zone: SensorZone
    let readings: [TemperatureReading]

    private static let titleWidth: CGFloat = 110

    var body: some View {
        HStack(alignment: .top, spacing: Theme.groupSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                if let hottest {
                    Text(PerformanceFormat.celsius(hottest))
                        .font(.displaySmall)
                        .foregroundStyle(HeatScale.color(for: hottest, zone: zone) ?? .primary)
                }
            }
            .frame(width: Self.titleWidth, alignment: .leading)
            .accessibilityElement(children: .combine)
            if zone == .surface || zone == .inside {
                NamedReadings(readings: readings, zone: zone)
            } else if readings.count > HeatStrip.threshold {
                HeatStrip(readings: readings, zone: zone)
            } else {
                HeatCells(readings: readings, zone: zone)
            }
        }
    }

    private var hottest: Double? { readings.map(\.celsius).max() }

    private var title: String {
        switch zone {
        case .superCores: "Super"
        case .performanceCores: "Performance"
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .storage: "Storage"
        case .surface: "Surface"
        case .inside: "Inside"
        }
    }
}

private struct HeatCells: View {
    let readings: [TemperatureReading]
    let zone: SensorZone

    private static let cellWidth: CGFloat = 44

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cellWidth), spacing: 4)], alignment: .leading, spacing: 4) {
            ForEach(readings) { reading in
                let tint = HeatScale.color(for: reading.celsius, zone: zone)
                Text(String(format: "%.0f°", reading.celsius))
                    .font(.metricSmall)
                    .foregroundStyle(tint ?? .primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background((tint ?? Color.secondary).opacity(tint == nil ? 0.10 : 0.18), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .help(reading.key)
                    .accessibilityLabel("\(reading.name), \(PerformanceFormat.celsius(reading.celsius))")
            }
        }
    }
}

private struct HeatStrip: View {
    let readings: [TemperatureReading]
    let zone: SensorZone

    static let threshold = 16
    private static let height: CGFloat = 22

    var body: some View {
        let low = readings.map(\.celsius).min() ?? 0
        HStack(spacing: 2) {
            ForEach(readings) { reading in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(HeatScale.color(for: reading.celsius, zone: zone) ?? Theme.accent)
                    .opacity(0.35 + 0.65 * relative(reading.celsius, low: low))
                    .help("\(reading.key) \(PerformanceFormat.celsius(reading.celsius))")
            }
        }
        .frame(height: Self.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(readings.count) sensors, \(PerformanceFormat.celsius(low)) to \(PerformanceFormat.celsius(readings.map(\.celsius).max() ?? low))")
    }

    private func relative(_ celsius: Double, low: Double) -> Double {
        let high = readings.map(\.celsius).max() ?? low
        return high > low ? (celsius - low) / (high - low) : 1
    }
}

private struct NamedReadings: View {
    let readings: [TemperatureReading]
    let zone: SensorZone

    private static let columnWidth: CGFloat = 170

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.columnWidth), spacing: Theme.groupSpacing)], alignment: .leading, spacing: 6) {
            ForEach(readings) { reading in
                HStack(spacing: Theme.itemSpacing) {
                    Text(reading.name)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: Theme.itemSpacing)
                    Text(PerformanceFormat.celsius(reading.celsius))
                        .font(.metric)
                        .foregroundStyle(HeatScale.color(for: reading.celsius, zone: zone) ?? .primary)
                }
                .help(reading.key)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
