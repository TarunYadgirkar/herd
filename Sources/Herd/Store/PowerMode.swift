import Foundation
import IOKit.ps

// Herd costs about 5% of a core with its window open at the old 2-second default. Precise spends more to catch short
// spikes; Efficient samples less often and drops per-app network tracking while no Herd window is open.
enum PowerMode: String, CaseIterable, Identifiable {
    case automatic, precise, efficient

    static let key = "powerMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .precise: "Precise"
        case .efficient: "Efficient"
        }
    }

    // Automatic follows the Mac: full detail on the power adapter, light sampling on battery or in Low Power Mode.
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

    // Per-app network comes from a long-running nettop. Efficient stops it while no window shows per-app numbers.
    var tracksNetworkWhileHidden: Bool { self == .precise }

    var title: String {
        switch self {
        case .precise: "Precise"
        case .efficient: "Efficient"
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
