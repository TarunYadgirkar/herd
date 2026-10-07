import SwiftUI

struct CoreGrid: View {
    let usage: [Double]
    let history: [CorePoint]
    let readings: [ClusterReading]?

    var body: some View {
        let clusters = CPUTopology.clusters(coreCount: usage.count)
        let frequencies = readings.map { CPUTopology.frequencies(for: clusters, readings: $0) } ?? [:]
        let series = coreSeries
        PerformanceCard(title: "Cores", help: "Each tile is one CPU core, grouped by cluster.") {
            VStack(alignment: .leading, spacing: Theme.groupSpacing) {
                ForEach(clusters) { cluster in
                    ClusterBlock(
                        cluster: cluster,
                        frequency: frequencies[cluster.level],
                        usage: usage,
                        series: series,
                        capacity: history.count
                    )
                }
            }
        }
    }

    private var coreSeries: [[Double]] {
        usage.indices.map { core in history.map { $0.usage.indices.contains(core) ? $0.usage[core] : 0 } }
    }
}

private struct ClusterBlock: View {
    let cluster: CoreCluster
    let frequency: Double?
    let usage: [Double]
    let series: [[Double]]
    let capacity: Int

    private static let tileWidth: CGFloat = 104

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemSpacing) {
            HStack(spacing: Theme.itemSpacing) {
                Text(cluster.name).font(.subheadText.weight(.semibold))
                Text("\(cluster.cores.count) cores").font(.captionText).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(frequency.map(PerformanceFormat.megahertz) ?? PerformanceFormat.missing)
                    .font(.metricSmall)
                    .foregroundStyle(.secondary)
                    .help("Current clock speed of this cluster")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.tileWidth), spacing: Theme.itemSpacing)], spacing: Theme.itemSpacing) {
                ForEach(Array(cluster.cores), id: \.self) { core in
                    CoreTile(index: core, usage: usage[core], history: series[core], capacity: capacity)
                }
            }
        }
    }
}

private struct CoreTile: View {
    let index: Int
    let usage: Double
    let history: [Double]
    let capacity: Int

    private static let sparkHeight: CGFloat = 26
    private static let minimumCapacity = 2

    var body: some View {
        let percent = Format.percent(usage * 100)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Core \(index + 1)").font(.captionText).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(percent).font(.metricSmall)
            }
            Sparkline(values: history, color: ChartPalette.cpuUser, ceiling: 1, capacity: max(capacity, Self.minimumCapacity))
                .frame(height: Self.sparkHeight)
        }
        .padding(Theme.itemSpacing)
        .surface(cornerRadius: Theme.innerRadius)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Core \(index + 1)")
        .accessibilityValue("\(percent) in use")
    }
}
