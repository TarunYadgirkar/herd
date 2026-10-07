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
    var energyImpact: Double = 0
    var idleWakeups: Double = 0

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
        energyImpact = sample.energyImpact
        idleWakeups = sample.idleWakeups
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
        sum.energyImpact = lhs.energyImpact + rhs.energyImpact
        sum.idleWakeups = lhs.idleWakeups + rhs.idleWakeups
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
    let project: String?

    var pids: [pid_t] { processes.map(\.sample.pid) }
    // Quitting a whole group is only safe when it's one app or one project; a runtime catch-all mixes unrelated work.
    var isSafeQuitTarget: Bool { bundlePath != nil || project != nil || processes.count == 1 }
    // Root-owned members can't be paused by Herd, so only the user's own processes decide whether the group reads as paused.
    var isSuspended: Bool {
        let own = processes.filter { $0.sample.uid == getuid() }
        return !own.isEmpty && own.allSatisfy(\.sample.isSuspended)
    }
    var hasApproximateData: Bool { processes.contains(where: \.sample.isApproximate) }
    var executablePath: String? { processes.first(where: { $0.sample.pid == mainPid })?.sample.path ?? processes.first?.sample.path }
}
