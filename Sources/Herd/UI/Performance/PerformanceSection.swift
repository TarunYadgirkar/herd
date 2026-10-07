import Foundation

enum PerformanceSection: String, CaseIterable, Identifiable {
    case cpu, memory, gpu, network, disk, energy, sensors, battery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .gpu: "GPU"
        case .network: "Network"
        case .disk: "Disk"
        case .energy: "Energy"
        case .sensors: "Sensors"
        case .battery: "Battery"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .gpu: "rectangle.3.group"
        case .network: "network"
        case .disk: "internaldrive"
        case .energy: "bolt"
        case .sensors: "thermometer.medium"
        case .battery: "battery.75percent"
        }
    }

    func summary(_ system: SystemSnapshot) -> String {
        switch self {
        case .cpu: Format.percent(system.cpuTotal * 100)
        case .memory: "\(PerformanceFormat.gigabytes(system.memoryUsed)) GB"
        case .gpu: system.gpuUtilization.map { Format.percent($0 * 100) } ?? PerformanceFormat.missing
        case .network: Format.rate(system.netInBps + system.netOutBps)
        case .disk: Format.rate(system.diskReadBps + system.diskWriteBps)
        case .energy: (system.sensors?.systemWatts ?? system.power?.packageWatts).map(Format.watts) ?? PerformanceFormat.missing
        case .sensors: system.sensors?.cpuCelsius.map(PerformanceFormat.celsius) ?? PerformanceFormat.missing
        case .battery: batteryPercent(system).map(Format.percent) ?? PerformanceFormat.missing
        }
    }

    private func batteryPercent(_ system: SystemSnapshot) -> Double? {
        system.batteryDetails?.percent ?? system.battery?.percent
    }
}
