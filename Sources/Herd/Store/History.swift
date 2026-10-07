import Foundation

struct Series: Sendable, Equatable {
    static let window: TimeInterval = 300
    static let capacity = 300

    private(set) var values: [Double] = []

    var latest: Double { values.last ?? 0 }

    func recentAverage(_ count: Int) -> Double? {
        let recent = values.suffix(count)
        guard !recent.isEmpty else { return nil }
        return recent.reduce(0, +) / Double(recent.count)
    }
    var peak: Double { values.max() ?? 0 }

    func appending(_ value: Double) -> Series {
        var next = self
        next.values.append(value)
        if next.values.count > Self.capacity { next.values.removeFirst(next.values.count - Self.capacity) }
        return next
    }
}

struct GroupHistory: Sendable, Equatable {
    var cpu = Series()
    var memory = Series()
    var energy = Series()
    var network = Series()
    var disk = Series()
    var gpu = Series()

    func appending(_ metrics: Metrics) -> GroupHistory {
        GroupHistory(
            cpu: cpu.appending(metrics.cpu),
            memory: memory.appending(Double(metrics.memory)),
            energy: energy.appending(metrics.energy),
            network: network.appending(metrics.network),
            disk: disk.appending(metrics.disk),
            gpu: gpu.appending(metrics.gpu)
        )
    }

    func series(for column: MetricColumn) -> Series {
        switch column {
        case .cpu: cpu
        case .memory: memory
        case .energy: energy
        case .network: network
        case .disk: disk
        case .gpu: gpu
        }
    }
}

struct SystemHistory: Sendable, Equatable {
    var cpu = Series()
    var memory = Series()
    var gpu = Series()
    var netIn = Series()
    var netOut = Series()
    var diskRead = Series()
    var diskWrite = Series()

    func appending(_ snapshot: SystemSnapshot) -> SystemHistory {
        let memoryFraction = snapshot.memoryTotal > 0 ? Double(snapshot.memoryUsed) / Double(snapshot.memoryTotal) : 0
        return SystemHistory(
            cpu: cpu.appending(snapshot.cpuTotal),
            memory: memory.appending(memoryFraction),
            gpu: gpu.appending(snapshot.gpuUtilization ?? 0),
            netIn: netIn.appending(snapshot.netInBps),
            netOut: netOut.appending(snapshot.netOutBps),
            diskRead: diskRead.appending(snapshot.diskReadBps),
            diskWrite: diskWrite.appending(snapshot.diskWriteBps)
        )
    }
}
