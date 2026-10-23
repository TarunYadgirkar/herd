import Foundation
import Network
import SystemConfiguration

// The few numbers worth checking on another Mac from this one: battery, temperature, and whether it is keeping up.
struct RemoteStats: Codable, Sendable, Equatable {
    var name: String
    var date: Date
    var batteryPercent: Double?
    var isCharging: Bool?
    var isOnAC: Bool?
    var batteryHealthPercent: Double?
    var batteryCycles: Int?
    var cpuCelsius: Double?
    var gpuCelsius: Double?
    var fanRPM: Double?
    var systemWatts: Double?
    var cpuPercent: Double
    var loadAverage: [Double]
    var memoryUsed: UInt64
    var memoryTotal: UInt64
    var memoryPressure: Int
    var diskFree: UInt64?
    var diskTotal: UInt64?
    var uptime: TimeInterval
    var thermalState: Int

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

extension RemoteStats {
    init(system: SystemSnapshot, name: String, disk: (free: UInt64, total: UInt64)?, date: Date = Date()) {
        let battery = system.batteryDetails
        self.init(
            name: name,
            date: date,
            batteryPercent: battery?.percent ?? system.battery?.percent,
            isCharging: battery?.isCharging ?? system.battery?.isCharging,
            isOnAC: battery?.isOnAC ?? system.battery?.isOnAC,
            batteryHealthPercent: battery?.healthPercent,
            batteryCycles: battery?.cycleCount,
            cpuCelsius: system.sensors?.cpuCelsius,
            gpuCelsius: system.sensors?.gpuCelsius,
            fanRPM: system.sensors?.fans.map(\.rpm).max(),
            systemWatts: system.sensors?.systemWatts ?? system.power?.packageWatts,
            cpuPercent: system.cpuTotal * 100,
            loadAverage: system.loadAverage,
            memoryUsed: system.memoryUsed,
            memoryTotal: system.memoryTotal,
            memoryPressure: system.pressure.rawValue,
            diskFree: disk?.free,
            diskTotal: disk?.total,
            uptime: system.uptime,
            thermalState: system.thermal.rawValue
        )
    }

    static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ProcessInfo.processInfo.hostName
    }

    static func startupDisk() -> (free: UInt64, total: UInt64)? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let free = values.volumeAvailableCapacityForImportantUsage,
              let total = values.volumeTotalCapacity else { return nil }
        return (UInt64(max(free, 0)), UInt64(max(total, 0)))
    }
}

enum RemoteNetwork {
    static let port: UInt16 = 47787
    static let path = "/stats"

    // Tailscale hands out 100.64.0.0/10 and fd7a:115c:a1e0::/48. Loopback is allowed so the Mac itself can check the endpoint.
    static func isTrusted(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case let .ipv4(address):
            return isTrusted(ipv4: [UInt8](address.rawValue))
        case let .ipv6(address):
            let bytes = [UInt8](address.rawValue)
            if address.isLoopback { return true }
            if bytes.count == 16, bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
                return isTrusted(ipv4: Array(bytes[12...]))
            }
            return bytes.starts(with: [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0])
        default:
            return false
        }
    }

    static func isTrusted(ipv4 bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        return bytes[0] == 127 || (bytes[0] == 100 && bytes[1] & 0xC0 == 64)
    }

    // Hosts are typed by hand in Settings, separated by commas or spaces.
    static func hosts(from text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
