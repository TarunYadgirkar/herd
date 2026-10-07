import Foundation

enum MetricColumn: String, CaseIterable, Identifiable, Sendable {
    case cpu, memory, impact, energy, gpu, network, disk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .impact: "Energy Impact"
        case .energy: "CPU Power"
        case .gpu: "GPU"
        case .network: "Network"
        case .disk: "Disk"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .impact: "leaf"
        case .energy: "bolt"
        case .gpu: "square.stack.3d.up"
        case .network: "arrow.up.arrow.down"
        case .disk: "internaldrive"
        }
    }

    func value(_ metrics: Metrics) -> Double {
        switch self {
        case .cpu: metrics.cpu
        case .memory: Double(metrics.memory)
        case .impact: metrics.energyImpact
        case .energy: metrics.energy
        case .gpu: metrics.gpu
        case .network: metrics.network
        case .disk: metrics.disk
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .cpu, .gpu: Format.percent(value)
        case .memory: Format.bytes(UInt64(max(value, 0)))
        case .impact: String(format: "%.1f", value)
        case .energy: Format.watts(value)
        case .network, .disk: Format.rate(value)
        }
    }

    // Thresholds where a cell starts to look warm and where it is fully hot.
    var heatRange: ClosedRange<Double> {
        switch self {
        case .cpu: 10...150
        case .memory: 500_000_000...4_000_000_000
        case .impact: 10...150
        case .energy: 0.5...8
        case .gpu: 5...60
        case .network: 100_000...20_000_000
        case .disk: 1_000_000...100_000_000
        }
    }

    func heat(_ value: Double) -> Double {
        let range = heatRange
        guard value > range.lowerBound else { return 0 }
        return min((value - range.lowerBound) / (range.upperBound - range.lowerBound), 1)
    }
}

enum Format {
    static func bytes(_ value: UInt64) -> String {
        guard value > 0 else { return "0 KB" }
        let mb = Double(value) / 1_048_576
        if mb < 1 { return String(format: "%.0f KB", Double(value) / 1024) }
        if mb < 1024 { return String(format: mb < 10 ? "%.1f MB" : "%.0f MB", mb) }
        return String(format: mb < 10_240 ? "%.2f GB" : "%.1f GB", mb / 1024)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond >= 1 else { return "0 KB/s" }
        let kb = bytesPerSecond / 1024
        if kb < 1024 { return String(format: kb < 10 ? "%.1f KB/s" : "%.0f KB/s", kb) }
        return String(format: "%.1f MB/s", kb / 1024)
    }

    static func percent(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f%%", value) : String(format: "%.0f%%", value)
    }

    static func watts(_ value: Double) -> String {
        value < 10 ? String(format: "%.2f W", value) : String(format: "%.1f W", value)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? ""
    }
}
