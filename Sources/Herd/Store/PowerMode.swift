import Foundation
import IOKit.ps

// Measured with the window open: Full (1-second samples) costs about 5.5% of a core, Light (5-second samples) about 2%,
// close to Activity Monitor's 1.5%. Light is the default; Full spends more to catch short spikes.
enum PowerMode: String, CaseIterable, Identifiable {
    case efficient, precise, automatic

    static let key = "powerMode"
    static let standard = PowerMode.efficient

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .precise: "Full"
        case .efficient: "Light"
        }
    }

    // Automatic follows the Mac: Full on the power adapter, Light on battery or in Low Power Mode.
    func effort(onBattery: Bool, lowPowerMode: Bool) -> SamplingEffort {
        switch self {
        case .precise: .precise
        case .efficient: .efficient
        case .automatic: onBattery || lowPowerMode ? .efficient : .precise
        }
    }
}

enum SamplingEffort: Sendable, Equatable {
    case precise, efficient

    var interval: UpdateInterval {
        switch self {
        case .precise: .fast
        case .efficient: .relaxed
        }
    }

    // Per-app network comes from a long-running nettop. Light stops it while no window shows per-app numbers.
    var tracksNetworkWhileHidden: Bool { self == .precise }

    var title: String {
        switch self {
        case .precise: "Full"
        case .efficient: "Light"
        }
    }

    var symbol: String {
        switch self {
        case .precise: "scope"
        case .efficient: "leaf"
        }
    }
}

enum PowerSource {
    static var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }

    static var isLowPowerMode: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
}
