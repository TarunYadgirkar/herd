import Darwin
import Foundation

enum GroupKind: Int, CaseIterable, Sendable, Identifiable {
    case apps, background, system

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .apps: "Apps"
        case .background: "Background"
        case .system: "macOS"
        }
    }
}

struct Metrics: Sendable, Equatable {
    var cpu: Double = 0
    var memory: UInt64 = 0
    var energy: Double = 0
    var gpu: Double = 0
    var diskRead: Double = 0
    var diskWrite: Double = 0
    var netIn: Double = 0
    var netOut: Double = 0
    var threads: Int = 0

    var disk: Double { diskRead + diskWrite }
    var network: Double { netIn + netOut }

    init() {}

    init(_ sample: ProcessSample) {
        cpu = sample.cpuPercent
        memory = sample.memoryBytes
        energy = sample.energyWatts
        gpu = sample.gpuPercent
        diskRead = sample.diskReadBps
        diskWrite = sample.diskWriteBps
        netIn = sample.netInBps
        netOut = sample.netOutBps
        threads = sample.threads
    }

    static func + (lhs: Metrics, rhs: Metrics) -> Metrics {
        var sum = Metrics()
        sum.cpu = lhs.cpu + rhs.cpu
        sum.memory = lhs.memory + rhs.memory
        sum.energy = lhs.energy + rhs.energy
        sum.gpu = lhs.gpu + rhs.gpu
        sum.diskRead = lhs.diskRead + rhs.diskRead
        sum.diskWrite = lhs.diskWrite + rhs.diskWrite
        sum.netIn = lhs.netIn + rhs.netIn
        sum.netOut = lhs.netOut + rhs.netOut
        sum.threads = lhs.threads + rhs.threads
        return sum
    }
}

struct GroupedProcess: Sendable, Identifiable {
    let sample: ProcessSample
    let title: String
    let subtitle: String?

    var id: String { sample.id }
}

struct AppGroup: Sendable, Identifiable {
    let id: String
    let name: String
    let kind: GroupKind
    let bundlePath: String?
    let runtime: Runtime?
    let mainPid: pid_t?
    let processes: [GroupedProcess]
    let metrics: Metrics

    var pids: [pid_t] { processes.map(\.sample.pid) }
    var isSuspended: Bool { !processes.isEmpty && processes.allSatisfy(\.sample.isSuspended) }
    var hasApproximateData: Bool { processes.contains(where: \.sample.isApproximate) }
    var executablePath: String? { processes.first(where: { $0.sample.pid == mainPid })?.sample.path ?? processes.first?.sample.path }
}
