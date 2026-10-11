import SwiftUI

struct PerformanceView: View {
    let section: PerformanceSection

    @Environment(MonitorStore.self) private var store
    @AppStorage("performanceRange") private var range: HistoryRange = .fiveMinutes
    @State private var selection: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.groupSpacing) {
                content
            }
            .padding(Theme.groupSpacing)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { RangePicker(range: $range) }
        }
        .onChange(of: section) { selection = nil }
        .onChange(of: range) { selection = nil }
    }

    @ViewBuilder
    private var content: some View {
        if store.hasFirstFrame {
            sectionView(PerformanceContext(
                system: store.system,
                window: store.archive.window(in: range),
                range: $range,
                selection: $selection
            ))
        } else {
            SectionMessage(title: section.title, symbol: section.symbol, message: PerformanceCopy.collecting)
        }
    }

    @ViewBuilder
    private func sectionView(_ context: PerformanceContext) -> some View {
        switch section {
        case .cpu: CPUPerformanceView(context: context, cores: store.archive.corePoints(in: range))
        case .memory: MemoryPerformanceView(context: context)
        case .gpu: GPUPerformanceView(context: context)
        case .network: ThroughputPerformanceView(context: context, kind: .network)
        case .disk: ThroughputPerformanceView(context: context, kind: .disk)
        case .energy: EnergyPerformanceView(context: context, usage: store.archive.appUsageToday)
        case .sensors: SensorsPerformanceView(context: context)
        case .battery: BatteryPerformanceView(context: context)
        }
    }
}
