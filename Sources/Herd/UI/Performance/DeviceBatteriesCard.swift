import SwiftUI

struct DeviceBatteriesCard: View {
    let devices: [DeviceBattery]

    static let howDevicesAppear = "Bluetooth accessories show up while they are connected to this Mac. "
        + "An iPhone or iPad shows up while it is plugged in, or when it reports its battery (Settings, Other devices)."

    var body: some View {
        PerformanceCard(title: "Devices") {
            if devices.isEmpty {
                Text(Self.howDevicesAppear)
                    .font(.captionText)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: Theme.itemSpacing) {
                    ForEach(devices) { DeviceBatteryRow(device: $0) }
                }
            }
        }
    }
}

private struct DeviceBatteryRow: View {
    let device: DeviceBattery

    private static let symbolWidth: CGFloat = 22
    private static let percentWidth: CGFloat = 38

    var body: some View {
        HStack(spacing: Theme.itemSpacing) {
            Image(systemName: device.symbol)
                .foregroundStyle(.secondary)
                .frame(width: Self.symbolWidth)
                .accessibilityHidden(true)
            Text(device.name)
                .font(.bodyText)
                .lineLimit(1)
            Spacer(minLength: Theme.groupSpacing)
            ForEach(device.cells) { cell in
                cellView(cell)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func cellView(_ cell: DeviceBattery.Cell) -> some View {
        HStack(spacing: 5) {
            if let label = cell.label {
                Text(label)
                    .font(.captionText)
                    .foregroundStyle(.secondary)
            }
            if cell.isCharging {
                Image(systemName: "bolt.fill")
                    .font(.footnoteText)
                    .foregroundStyle(Theme.good)
                    .accessibilityLabel("charging")
            }
            LevelRing(level: cell.percent / 100, color: BatteryGlyph.levelTint(percent: cell.percent, isCharging: cell.isCharging))
            Text(Format.percent(cell.percent))
                .font(.metric)
                .frame(minWidth: Self.percentWidth, alignment: .trailing)
        }
    }
}

extension DeviceBattery {
    var symbol: String {
        switch kind {
        case .audio: cells.count > 1 ? "airpodspro" : "headphones"
        case .keyboard: "keyboard"
        case .mouse: "computermouse"
        case .trackpad: "rectangle.and.hand.point.up.left"
        case .controller: "gamecontroller"
        case .phone: "iphone"
        case .tablet: "ipad"
        case .watch: "applewatch"
        case .other: "dot.radiowaves.left.and.right"
        }
    }
}
