import SwiftUI

struct CoreGrid: View {
    let usage: [Double]
    let history: [CorePoint]
    let range: HistoryRange
    let readings: [ClusterReading]?
    let temperatures: [TemperatureReading]

    // HistoryArchive keeps per-core samples only for its raw window.
    private static let trendWindow: TimeInterval = 600

    var body: some View {
        // Apple numbers perflevel0 as the fastest cores, so the fastest cluster leads.
        let clusters = CPUTopology.clusters(coreCount: usage.count).sorted { $0.level < $1.level }
        let frequencies = readings.map { CPUTopology.frequencies(for: clusters, readings: $0) } ?? [:]
        PerformanceCard(title: "Cores") {
            if range.seconds > Self.trendWindow {
                Text("Trends show the last 10 min")
                    .font(.captionText)
                    .foregroundStyle(.secondary)
            }
        } content: {
            VStack(alignment: .leading, spacing: Theme.groupSpacing) {
                ForEach(clusters) { cluster in
                    ClusterRow(
                        cluster: cluster,
                        usage: Array(usage[cluster.cores]),
                        trend: trend(for: cluster),
                        capacity: history.count,
                        frequency: frequencies[cluster.level],
                        celsius: hottest(in: cluster, isOnlyCluster: clusters.count == 1)
                    )
                    if cluster.id != clusters.last?.id { Divider() }
                }
            }
        }
    }

    private func trend(for cluster: CoreCluster) -> [Double] {
        history.map { point in
            let values = cluster.cores.compactMap { point.usage.indices.contains($0) ? point.usage[$0] : nil }
            return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        }
    }

    private func hottest(in cluster: CoreCluster, isOnlyCluster: Bool) -> Double? {
        guard let zone = isOnlyCluster ? SensorZone.cpu : SensorZone(clusterName: cluster.name) else { return nil }
        return temperatures.filter { $0.zone == zone }.map(\.celsius).max()
    }
}

extension SensorZone {
    init?(clusterName: String) {
        switch clusterName.lowercased() {
        case "super": self = .superCores
        case "performance": self = .performanceCores
        default: return nil
        }
    }
}

private struct ClusterRow: View {
    let cluster: CoreCluster
    let usage: [Double]
    let trend: [Double]
    let capacity: Int
    let frequency: Double?
    let celsius: Double?

    private static let trendWidth: CGFloat = 180
    private static let minimumCapacity = 2

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemSpacing) {
            header
            HStack(alignment: .bottom, spacing: Theme.groupSpacing) {
                CoreBars(usage: usage, firstIndex: cluster.cores.lowerBound)
                Sparkline(values: trend, color: ChartPalette.cpuUser, ceiling: 1, capacity: max(capacity, Self.minimumCapacity))
                    .frame(width: Self.trendWidth, height: CoreBars.barHeight)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var average: Double {
        usage.isEmpty ? 0 : usage.reduce(0, +) / Double(usage.count)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.itemSpacing) {
            Text(cluster.name).font(.headlineText)
            Text("\(usage.count)")
                .font(.metricSmall)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .background(Theme.surfaceRaised, in: Capsule())
                .accessibilityLabel("\(usage.count) cores")
            Spacer(minLength: Theme.groupSpacing)
            Text(Format.percent(average * 100))
                .font(.displaySmall)
                .foregroundStyle(average < CoreLoad.calmCeiling ? .primary : CoreLoad.textColor(average))
                .accessibilityLabel("\(cluster.name) average \(Format.percent(average * 100))")
            if let frequency {
                Label(PerformanceFormat.gigahertz(frequency), systemImage: "speedometer")
                    .font(.metric)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clock \(PerformanceFormat.gigahertz(frequency))")
            }
            if let celsius {
                Label(PerformanceFormat.celsius(celsius), systemImage: "thermometer.medium")
                    .font(.metric)
                    .foregroundStyle(HeatScale.textColor(for: celsius, zone: .superCores) ?? .secondary)
                    .accessibilityLabel("Hottest sensor \(PerformanceFormat.celsius(celsius))")
            }
        }
    }
}

private struct CoreBars: View {
    let usage: [Double]
    let firstIndex: Int

    static let barHeight: CGFloat = 56
    private static let maxBarWidth: CGFloat = 22
    private static let barRadius: CGFloat = 3

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(usage.indices, id: \.self) { index in
                VStack(spacing: 4) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: Self.barRadius, style: .continuous).fill(Theme.track)
                        RoundedRectangle(cornerRadius: Self.barRadius, style: .continuous)
                            .fill(CoreLoad.color(usage[index]))
                            .frame(height: max(Self.barRadius * 2, Self.barHeight * usage[index]))
                    }
                    .frame(maxWidth: Self.maxBarWidth)
                    .frame(height: Self.barHeight)
                    Text(Format.percent(usage[index] * 100))
                        .font(.metricSmall)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: Self.maxBarWidth + 14)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Core \(firstIndex + index + 1)")
                .accessibilityValue(Format.percent(usage[index] * 100))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum CoreLoad {
    static let calmCeiling = 0.4
    private static let hotFloor = 0.8

    static func color(_ usage: Double) -> Color {
        if usage >= hotFloor { return Theme.hot }
        if usage >= calmCeiling { return Theme.warm }
        return Theme.accent
    }

    static func textColor(_ usage: Double) -> Color {
        usage >= hotFloor ? Theme.hotText : Theme.warmText
    }
}
