import SwiftUI

// One accessory, phone or tablet whose battery this Mac can read.
struct DeviceBatteryView: View {
    let device: DeviceBattery?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.groupSpacing) {
                if let device, let percent = device.percent {
                    content(device, percent: percent)
                } else {
                    SectionMessage(title: "Not connected", symbol: "battery.0percent", message: DeviceBatteriesCard.howDevicesAppear)
                }
            }
            .padding(Theme.groupSpacing)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func content(_ device: DeviceBattery, percent: Double) -> some View {
        PerformanceHeader(
            title: device.name,
            value: Format.percent(percent),
            symbol: BatteryGlyph.symbol(percent: percent, isPowered: device.isCharging),
            symbolTint: BatteryGlyph.tint(percent: percent, isCharging: device.isCharging, isOnAC: false),
            symbolLabel: device.isCharging ? "Charging" : "On battery",
            caption: Text(device.isCharging ? "Charging" : "On battery"),
            stats: device.cells.count > 1 ? device.cells.map(Self.stat) : []
        ) {
            EmptyView()
        }
        if !device.details.isEmpty {
            PerformanceCard(title: "Details") {
                StatGrid(stats: device.details.map { PerformanceStat(label: $0.label, value: $0.value) })
            }
        }
    }

    private static func stat(_ cell: DeviceBattery.Cell) -> PerformanceStat {
        PerformanceStat(
            label: cell.label ?? "Battery",
            value: Format.percent(cell.percent),
            help: cell.isCharging ? "Charging" : nil,
            level: cell.percent / 100,
            tint: BatteryGlyph.levelTint(percent: cell.percent, isCharging: cell.isCharging)
        )
    }
}
