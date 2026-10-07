import SwiftUI

struct MiniMonitorView: View {
    @Environment(MonitorStore.self) private var store

    private static let width: CGFloat = 260
    private static let topCount = 3

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemSpacing) {
            HStack(alignment: .top, spacing: Theme.groupSpacing) {
                stat("CPU", value: Format.percent(store.system.cpuTotal * 100)) {
                    Sparkline(values: store.systemHistory.cpu.values, ceiling: 1).frame(height: 18)
                }
                stat("Memory", value: Format.bytes(store.system.memoryUsed)) {
                    StatePill(text: pressureTitle, color: Theme.pressureColor(store.system.pressure))
                }
                if let power = store.system.power {
                    stat("Power", value: Format.watts(store.system.sensors?.systemWatts ?? power.packageWatts)) {
                        Text("CPU \(Format.watts(power.cpuWatts))").font(.metricSmall).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            ForEach(topGroups) { group in
                HStack(spacing: 6) {
                    GroupIcon(group: group, size: 14)
                    Text(group.name).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Format.percent(group.metrics.cpu)).font(.metricSmall)
                }
                .font(.callout)
            }
        }
        .padding(Theme.innerPadding)
        .frame(width: Self.width)
        .redacted(reason: store.hasFirstFrame ? [] : .placeholder)
        .background(WindowVisibilityReader { store.setSurface("mini", visible: $0) })
    }

    private var topGroups: [AppGroup] {
        Array(store.groups.sorted { $0.metrics.cpu > $1.metrics.cpu }.prefix(Self.topCount))
    }

    private var pressureTitle: String {
        switch store.system.pressure {
        case .normal: "Normal"
        case .warning: "Under pressure"
        case .critical: "Critical"
        }
    }

    private func stat<Detail: View>(_ title: String, value: String, @ViewBuilder detail: () -> Detail) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.displaySmall)
            detail()
        }
        .accessibilityElement(children: .combine)
    }
}
