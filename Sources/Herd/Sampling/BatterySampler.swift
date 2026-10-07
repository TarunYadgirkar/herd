import Darwin
import Foundation
import IOKit
import IOKit.ps

private struct PowerSourceState {
    let percent: Double
    let isCharging: Bool
    let isOnAC: Bool
    let minutesRemaining: Int?
    let healthCondition: String?
}

private struct BatteryRegistry {
    let cycleCount: Int?
    let designCapacityMAh: Int?
    let maxCapacityMAh: Int?
    let nominalCapacityMAh: Int?
    let currentCapacityMAh: Int?
    let voltage: Double?
    let amperage: Double?
    let celsius: Double?
    let adapterWatts: Double?
    let hasPermanentFailure: Bool

    var healthPercent: Double? {
        guard let design = designCapacityMAh, design > 0, let full = nominalCapacityMAh ?? maxCapacityMAh else { return nil }
        return min(Double(full) / Double(design) * 100, 100)
    }
}

final class BatterySampler {
    private static let registryRefreshNanoseconds: UInt64 = 10_000_000_000
    private static let serviceClass = "AppleSmartBattery"
    private static let packClass = "AppleSmartBatteryPack"
    private static let batteryDataKey = "BatteryData"
    private static let serviceRecommendedBelowPercent = 80.0
    private static let failingHealthConditions: Set<String> = ["Check Battery", "Permanent Battery Failure", "Poor"]

    private var registry: BatteryRegistry?
    private var registryReadAt: UInt64?
    private var hasRegistry = true

    init() {}

    func sample() -> BatteryDetails? {
        guard let state = Self.powerSourceState() else { return nil }
        let registry = currentRegistry()
        let health = registry?.healthPercent
        return BatteryDetails(
            percent: state.percent,
            isCharging: state.isCharging,
            isOnAC: state.isOnAC,
            minutesRemaining: state.minutesRemaining,
            healthPercent: health,
            cycleCount: registry?.cycleCount,
            designCapacityMAh: registry?.designCapacityMAh,
            maxCapacityMAh: registry?.maxCapacityMAh,
            currentCapacityMAh: registry?.currentCapacityMAh,
            voltage: registry?.voltage,
            amperage: registry?.amperage,
            adapterWatts: state.isOnAC ? Self.adapterWatts() ?? registry?.adapterWatts : nil,
            celsius: registry?.celsius,
            condition: Self.condition(state: state, registry: registry, health: health)
        )
    }

    private func currentRegistry() -> BatteryRegistry? {
        guard hasRegistry else { return nil }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if let registryReadAt, now - registryReadAt < Self.registryRefreshNanoseconds { return registry }
        registryReadAt = now
        registry = Self.readRegistry()
        hasRegistry = registry != nil
        return registry
    }

    private static func condition(state: PowerSourceState, registry: BatteryRegistry?, health: Double?) -> String {
        let isFailing = registry?.hasPermanentFailure == true
            || state.healthCondition.map(failingHealthConditions.contains) == true
            || (health ?? 100) < serviceRecommendedBelowPercent
        return isFailing ? "Service Recommended" : "Normal"
    }
}

extension BatterySampler {
    private static func powerSourceState() -> PowerSourceState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        let descriptions = list.compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
        guard let battery = descriptions.first(where: { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }),
              battery[kIOPSIsPresentKey] as? Bool != false,
              let current = battery[kIOPSCurrentCapacityKey] as? Int,
              let maximum = battery[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { return nil }
        let isCharging = battery[kIOPSIsChargingKey] as? Bool ?? false
        let isOnAC = battery[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        return PowerSourceState(
            percent: min(Double(current) / Double(maximum) * 100, 100),
            isCharging: isCharging,
            isOnAC: isOnAC,
            minutesRemaining: minutesRemaining(battery, isCharging: isCharging, isOnAC: isOnAC),
            healthCondition: battery[kIOPSBatteryHealthConditionKey] as? String ?? battery[kIOPSBatteryHealthKey] as? String
        )
    }

    private static func minutesRemaining(_ battery: [String: Any], isCharging: Bool, isOnAC: Bool) -> Int? {
        let key: String
        switch (isCharging, isOnAC) {
        case (true, _): key = kIOPSTimeToFullChargeKey
        case (false, false): key = kIOPSTimeToEmptyKey
        default: return nil
        }
        guard let minutes = battery[key] as? Int, minutes > 0 else { return nil }
        return minutes
    }

    private static func adapterWatts() -> Double? {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any],
              let watts = details[kIOPSPowerAdapterWattsKey] as? Int, watts > 0 else { return nil }
        return Double(watts)
    }
}

extension BatterySampler {
    private static let millisPerUnit = 1000.0
    private static let centiDegreesPerDegree = 100.0

    private static func readRegistry() -> BatteryRegistry? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(serviceClass))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let top = properties(of: service) else { return nil }
        let pack = packProperties(of: service)
        let sources = [top, top[batteryDataKey] as? [String: Any], pack, pack?[batteryDataKey] as? [String: Any]].compactMap { $0 }
        let int = { (keys: [String]) in integer(keys, in: sources) }
        return BatteryRegistry(
            cycleCount: int(["CycleCount"]),
            designCapacityMAh: int(["DesignCapacity"]),
            maxCapacityMAh: int(["AppleRawMaxCapacity", "FullChargeCapacity"]),
            nominalCapacityMAh: int(["NominalChargeCapacity"]),
            currentCapacityMAh: int(["AppleRawCurrentCapacity", "RemainingCapacity"]),
            voltage: int(["Voltage", "AppleRawBatteryVoltage"]).map { Double($0) / millisPerUnit },
            amperage: int(["Amperage", "InstantAmperage"]).map { Double($0) / millisPerUnit },
            celsius: int(["Temperature", "VirtualTemperature"]).map { Double($0) / centiDegreesPerDegree },
            adapterWatts: ((top["AdapterDetails"] as? [String: Any])?["Watts"] as? Int).flatMap { $0 > 0 ? Double($0) : nil },
            hasPermanentFailure: (int(["PermanentFailureStatus"]) ?? 0) != 0
        )
    }

    private static func integer(_ keys: [String], in sources: [[String: Any]]) -> Int? {
        for key in keys {
            for source in sources {
                if let number = source[key] as? NSNumber { return Int(truncatingIfNeeded: number.int64Value) }
            }
        }
        return nil
    }

    private static func properties(of entry: io_registry_entry_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return nil }
        return unmanaged?.takeRetainedValue() as? [String: Any]
    }

    private static func packProperties(of service: io_registry_entry_t) -> [String: Any]? {
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(children) }
        while case let child = IOIteratorNext(children), child != 0 {
            defer { IOObjectRelease(child) }
            if IOObjectConformsTo(child, packClass) != 0 { return properties(of: child) }
        }
        return nil
    }
}
