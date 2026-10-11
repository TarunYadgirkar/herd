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

    func liveRates(_ system: SystemSnapshot) -> (in: Double, out: Double) {
        self == .network ? (system.netInBps, system.netOutBps) : (system.diskReadBps, system.diskWriteBps)
    }
}

struct ThroughputPerformanceView: View {
    let context: PerformanceContext
    let kind: ThroughputKind

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
