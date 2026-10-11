import SwiftUI

struct AppHistoryView: View {
    @Environment(MonitorStore.self) private var store
    @State private var sortOrder = [KeyPathComparator(\AppUsage.energyWattHours, order: .reverse)]

    var body: some View {
        let usage = store.archive.appUsageToday
        let total = usage.reduce(0) { $0 + $1.energyWattHours }
        Group {
            if usage.isEmpty {
                SectionMessage(title: "No history yet", symbol: "clock.arrow.circlepath")
                    .frame(maxHeight: .infinity)
            } else {
                AppUsageTable(rows: usage.sorted(using: sortOrder), sortOrder: $sortOrder)
            }
        }
        .navigationSubtitle("\(PerformanceFormat.wattHours(total)) used today")
    }
}

private struct AppUsageTable: View {
    let rows: [AppUsage]
    @Binding var sortOrder: [KeyPathComparator<AppUsage>]

    private static let numberWidth: CGFloat = 90

    var body: some View {
        Table(rows, sortOrder: $sortOrder) {
            TableColumn("App", value: \.name) { UsageAppLabel(usage: $0) }
                .width(min: 180, ideal: 240)
            TableColumn("CPU Energy", value: \.energyWattHours) { number(PerformanceFormat.wattHours($0.energyWattHours)) }
                .width(min: Self.numberWidth)
            TableColumn("CPU time", value: \.cpuSeconds) { number(PerformanceFormat.cpuTime($0.cpuSeconds)) }
                .width(min: Self.numberWidth)
            TableColumn("Network", value: \.networkBytes) { number(PerformanceFormat.bytes($0.networkBytes)) }
                .width(min: Self.numberWidth)
            TableColumn("Disk", value: \.diskBytes) { number(PerformanceFormat.bytes($0.diskBytes)) }
                .width(min: Self.numberWidth)
            TableColumn("Peak memory", value: \.peakMemory) { number(PerformanceFormat.bytes($0.peakMemory)) }
                .width(min: Self.numberWidth)
            TableColumn("Last seen", value: \.lastSeen) { row in
                Text(row.lastSeen, format: .relative(presentation: .named))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 110)
        }
    }

    private func number(_ value: String) -> some View {
        Text(value)
            .font(.metric)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
