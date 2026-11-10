import SwiftUI

enum ThroughputKind {
    case network, disk

    var title: String {
        switch self {
        case .network: "Network"
        case .disk: "Disk"
        }
    }

    var inName: String {
        switch self {
        case .network: "Download"
        case .disk: "Read"
        }
    }

    var outName: String {
        switch self {
        case .network: "Upload"
        case .disk: "Write"
        }
    }

    var inTotalLabel: String {
        switch self {
        case .network: "Downloaded"
        case .disk: "Read"
        }
    }

    var outTotalLabel: String {
        switch self {
        case .network: "Uploaded"
        case .disk: "Written"
        }
    }

    func inRate(_ point: SystemPoint) -> Double {
        self == .network ? point.netIn : point.diskRead
    }

    func outRate(_ point: SystemPoint) -> Double {
        self == .network ? point.netOut : point.diskWrite
    }

    func usage(_ app: AppUsage) -> Double {
        self == .network ? app.networkBytes : app.diskBytes
    }

    func liveRates(_ system: SystemSnapshot) -> (in: Double, out: Double) {
        self == .network ? (system.netInBps, system.netOutBps) : (system.diskReadBps, system.diskWriteBps)
    }
}

struct ThroughputPerformanceView: View {
    let context: PerformanceContext
    let kind: ThroughputKind
    let usage: [AppUsage]

    var body: some View {
        let live = kind.liveRates(context.system)
        PerformanceHeader(
            title: kind.title,
            value: Format.rate(live.in),
            symbol: "arrow.down",
            symbolTint: ChartPalette.download,
            symbolLabel: kind.inName,
            caption: Text("\(Image(systemName: "arrow.up")) \(Format.rate(live.out))").foregroundStyle(ChartPalette.upload),
            stats: stats
        )
        PerformanceChart(
            title: "Throughput",
            series: [
                ChartSeries(name: kind.inName, color: ChartPalette.download, values: context.values { kind.inRate($0) }),
                ChartSeries(name: kind.outName, color: ChartPalette.upload, values: context.values { kind.outRate($0) }, direction: -1),
            ],
            unit: .rate,
            context: context,
            height: 220
        )
        ThroughputTodayCard(kind: kind, usage: usage)
    }

    private var stats: [PerformanceStat] {
        [
            PerformanceStat(label: kind.inTotalLabel, value: PerformanceFormat.bytes(context.total { kind.inRate($0) })),
            PerformanceStat(label: kind.outTotalLabel, value: PerformanceFormat.bytes(context.total { kind.outRate($0) })),
            PerformanceStat(label: "Peak \(kind.inName.lowercased())", value: Format.rate(context.peak { kind.inRate($0) } ?? 0)),
            PerformanceStat(label: "Peak \(kind.outName.lowercased())", value: Format.rate(context.peak { kind.outRate($0) } ?? 0)),
        ]
    }
}

// Which apps moved the most data today, so a busy graph can be traced to its cause.
private struct ThroughputTodayCard: View {
    let kind: ThroughputKind
    let usage: [AppUsage]

    private static let rowLimit = 10
    private static let barHeight: CGFloat = 6
    private static let barWidth: CGFloat = 160

    var body: some View {
        let rows = usage.filter { kind.usage($0) > 0 }.sorted { kind.usage($0) > kind.usage($1) }.prefix(Self.rowLimit)
        PerformanceCard(title: "Today by app") {
            if let top = rows.first.map(kind.usage) {
                Grid(alignment: .leading, horizontalSpacing: Theme.groupSpacing, verticalSpacing: Theme.itemSpacing) {
                    ForEach(rows) { row in
                        GridRow {
                            UsageAppLabel(usage: row)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            bar(kind.usage(row) / top)
                            Text(PerformanceFormat.bytes(kind.usage(row)))
                                .font(.metric)
                                .gridColumnAlignment(.trailing)
                        }
                    }
                }
            } else {
                ChartMessage(text: PerformanceCopy.collecting, height: 80)
            }
        }
    }

    private func bar(_ fraction: Double) -> some View {
        Capsule()
            .fill(Theme.track)
            .frame(width: Self.barWidth, height: Self.barHeight)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(ChartPalette.download)
                    .frame(width: max(Self.barWidth * fraction, Self.barHeight))
            }
            .accessibilityHidden(true)
    }
}
