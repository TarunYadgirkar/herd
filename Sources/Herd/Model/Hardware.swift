import Foundation

struct ClusterReading: Sendable, Equatable, Identifiable {
    let name: String
    let cores: Int
    var frequencyMHz: Double
    var maxFrequencyMHz: Double
    var activeFraction: Double

    var id: String { name }
}

struct PowerReading: Sendable, Equatable {
    var cpuWatts: Double = 0
    var gpuWatts: Double = 0
    var aneWatts: Double = 0
    // Nil when the chip reports no memory energy; macOS 27 leaves the DRAM counter at zero on some Macs.
    var dramWatts: Double?
    var systemWatts: Double?
    var clusters: [ClusterReading] = []
    var gpuFrequencyMHz: Double = 0
    var gpuMaxFrequencyMHz: Double = 0
    var gpuActiveFraction: Double = 0

    var packageWatts: Double { cpuWatts + gpuWatts + aneWatts }
}

struct FanReading: Sendable, Equatable, Identifiable {
    let index: Int
    var rpm: Double
    var minRPM: Double
    var maxRPM: Double

    var id: Int { index }
    var name: String { "Fan \(index + 1)" }
}

enum SensorZone: Int, Sendable, CaseIterable, Comparable {
    case superCores, performanceCores, cpu, gpu, memory, storage, surface, inside

    static func < (lhs: SensorZone, rhs: SensorZone) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct TemperatureReading: Sendable, Equatable, Identifiable {
    let key: String
    let name: String
    let zone: SensorZone
    var celsius: Double

    var id: String { key }
}

struct SensorReading: Sendable, Equatable {
    var cpuCelsius: Double?
    var cpuMaxCelsius: Double?
    var gpuCelsius: Double?
    var ssdCelsius: Double?
    var batteryCelsius: Double?
    var lidCelsius: Double?
    var palmRestCelsius: Double?
    var systemWatts: Double?
    var adapterInWatts: Double?
    var fans: [FanReading] = []
    var temperatures: [TemperatureReading] = []
}

struct BatteryDetails: Sendable, Equatable {
    var percent: Double
    var isCharging: Bool
    var isOnAC: Bool
    var minutesRemaining: Int?
    var healthPercent: Double?
    var cycleCount: Int?
    var designCapacityMAh: Int?
    var maxCapacityMAh: Int?
    var currentCapacityMAh: Int?
    var voltage: Double?
    var amperage: Double?
    var adapterWatts: Double?
    var celsius: Double?
    var condition: String?

    // Positive while charging, negative while the battery is powering the Mac.
    var watts: Double? {
        guard let voltage, let amperage else { return nil }
        return voltage * amperage
    }
}
