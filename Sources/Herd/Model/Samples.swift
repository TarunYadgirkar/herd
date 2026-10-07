import Darwin
import Foundation

struct ProcessSample: Sendable, Identifiable, Hashable {
    let id: String
    let pid: pid_t
    let ppid: pid_t
    let responsiblePid: pid_t
    let uid: uid_t
    let name: String
    let path: String
    let arguments: [String]
    let startTime: Date?
    var cpuPercent: Double
    var memoryBytes: UInt64
    var energyWatts: Double
    var diskReadBps: Double
    var diskWriteBps: Double
    var netInBps: Double
    var netOutBps: Double
    var gpuPercent: Double
    var threads: Int
    var isApproximate: Bool
    var isSuspended: Bool
    var isUnavailable: Bool = false
    var energyImpact: Double = 0
    var idleWakeups: Double = 0
    var cpuSeconds: Double = 0
    var workingDirectory: String? = nil
    var listeningPorts: [UInt16] = []
    var sleepAssertions: [String] = []
}

enum MemoryPressure: Int, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4
}

struct BatteryInfo: Sendable, Equatable {
    var percent: Double
    var isCharging: Bool
    var isOnAC: Bool
    var minutesRemaining: Int?
}

struct SystemSnapshot: Sendable {
    var cpuUser: Double = 0
    var cpuSystem: Double = 0
    var perCoreUsage: [Double] = []
    var loadAverage: [Double] = [0, 0, 0]

    var memoryTotal: UInt64 = 0
    var memoryUsed: UInt64 = 0
    var appMemory: UInt64 = 0
    var wiredMemory: UInt64 = 0
    var compressedMemory: UInt64 = 0
    var cachedFiles: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var pressure: MemoryPressure = .normal

    var netInBps: Double = 0
    var netOutBps: Double = 0
    var diskReadBps: Double = 0
    var diskWriteBps: Double = 0

    var gpuUtilization: Double?
    var thermal: ProcessInfo.ThermalState = .nominal
    var battery: BatteryInfo?
    var batteryDetails: BatteryDetails?
    var power: PowerReading?
    var sensors: SensorReading?
    var kernelCPUPercent: Double?
    var uptime: TimeInterval = 0

    var cpuTotal: Double { cpuUser + cpuSystem }
}

struct Snapshot: Sendable {
    let date: Date
    let processes: [ProcessSample]
    let system: SystemSnapshot
}
