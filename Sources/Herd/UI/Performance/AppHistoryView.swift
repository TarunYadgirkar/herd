import SwiftUI

struct AppHistoryView: View {
    @Environment(MonitorStore.self) private var store
    @State private var sortOrder = [KeyPathComparator(\AppUsage.energyWattHours, order: .reverse)]

    var body: some View {
        let usage = store.archive.appUsageToday
        VStack(alignment: .leading, spacing: 0) {
            header(usage)
                .padding(.horizontal, Theme.groupSpacing)
                .padding(.vertical, Theme.itemSpacing + 4)
            Divider()
            if usage.isEmpty {
                SectionMessage(
                    title: "No app history yet",
                    symbol: "clock.arrow.circlepath",
                    message: "Herd records what each app uses while it runs. Check back in a few minutes."
                )
                .frame(maxHeight: .infinity)
            } else {
                AppUsageTable(rows: usage.sorted(using: sortOrder), sortOrder: $sortOrder)
            }
        }
    }

    private func header(_ usage: [AppUsage]) -> some View {
        let total = usage.reduce(0) { $0 + $1.energyWattHours }
        return HStack(alignment: .firstTextBaseline, spacing: Theme.itemSpacing) {
            Text("App history").font(.sectionTitle)
            Text("Since midnight").foregroundStyle(.secondary)
            Spacer(minLength: Theme.groupSpacing)
            Text("\(PerformanceFormat.wattHours(total)) used")
                .font(.displaySmall)
                .help("Energy all apps have used since midnight")
        }
        .accessibilityElement(children: .combine)
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
            TableColumn("Energy", value: \.energyWattHours) { number(PerformanceFormat.wattHours($0.energyWattHours)) }
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
