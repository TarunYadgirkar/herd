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
    var contributors: [Contributor]? = nil

    var id: Date { date }
    var cpuTotal: Double { cpuUser + cpuSystem }
}

struct Contributor: Sendable, Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var bundlePath: String?
    var cpu: Double
    var memory: UInt64
    var energy: Double
}

extension Contributor {
    static let leadersPerMetric = 3

    static func leaders(_ candidates: [Contributor]) -> [Contributor] {
        let byCPU = ranked(candidates) { $0.cpu }
        let byMemory = ranked(candidates) { Double($0.memory) }
        let cpuIDs = Set(byCPU.map(\.id))
        return byCPU + byMemory.filter { !cpuIDs.contains($0.id) }
    }

    private static func ranked(_ candidates: [Contributor], by value: (Contributor) -> Double) -> [Contributor] {
        let sorted = candidates.sorted { lhs, rhs in
            let left = value(lhs)
            let right = value(rhs)
            return left != right ? left > right : lhs.id < rhs.id
        }
        return Array(sorted.prefix(leadersPerMetric))
    }
}

// A tier's points normally sit one resolution apart; a wider step means the Mac slept or Herd wasn't running.
enum HistoryGaps {
    static let spacingMultiple = 3.0
    static let minimumLimit: TimeInterval = 10

    static func limit(spacing: TimeInterval, stretch: Double = 1) -> TimeInterval {
        max(spacing * stretch * spacingMultiple, minimumLimit)
    }

    static func medianSpacing(_ dates: [Date]) -> TimeInterval? {
        let spacings = zip(dates, dates.dropFirst()).map { $1.timeIntervalSince($0) }.sorted()
        guard !spacings.isEmpty else { return nil }
        return spacings[spacings.count / 2]
    }

    static func segmentIndices(_ dates: [Date], maxGap: TimeInterval) -> [Int] {
        var segment = 0
        return dates.indices.map { index in
            if index > 0, dates[index].timeIntervalSince(dates[index - 1]) > maxGap { segment += 1 }
            return segment
        }
    }
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
