import Foundation

enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
    case minute = "1m"
    case fiveMinutes = "5m"
    case hour = "1h"
    case day = "24h"

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .minute: 60
        case .fiveMinutes: 300
        case .hour: 3_600
        case .day: 86_400
        }
    }

    var title: String {
        switch self {
        case .minute: "1 min"
        case .fiveMinutes: "5 min"
        case .hour: "1 hour"
        case .day: "24 hours"
        }
    }
}

struct SystemPoint: Sendable, Codable, Identifiable, Equatable {
    var date: Date
    var cpuUser: Double
    var cpuSystem: Double
    var memoryUsed: Double
    var appMemory: Double
    var wiredMemory: Double
    var compressedMemory: Double
    var cachedFiles: Double
    var swapUsed: Double
    var pressure: Int
    var gpu: Double
    var netIn: Double
    var netOut: Double
    var diskRead: Double
    var diskWrite: Double
    var cpuWatts: Double?
    var gpuWatts: Double?
    var aneWatts: Double?
    var dramWatts: Double?
    var systemWatts: Double?
    var cpuCelsius: Double?
    var gpuCelsius: Double?
    var lidCelsius: Double?
    var fanRPM: Double?
    var batteryPercent: Double?
    var batteryWatts: Double?

    var id: Date { date }
    var cpuTotal: Double { cpuUser + cpuSystem }
}

struct CorePoint: Sendable, Identifiable, Equatable {
    var date: Date
    var usage: [Double]
    var clusterFrequenciesMHz: [String: Double]

    var id: Date { date }
}

struct AppUsage: Sendable, Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var bundlePath: String?
    var cpuSeconds: Double
    var energyWattHours: Double
    var energyImpactSum: Double
    var networkBytes: Double
    var diskBytes: Double
    var peakMemory: Double
    var lastSeen: Date
}
