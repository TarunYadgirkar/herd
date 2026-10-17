import Foundation

// A flat Float ring sized to what the charts show (60 samples in Light, 300 in Full). Once full, each tick overwrites
// the oldest value in place, so recording a tick neither copies nor shifts the history.
struct Series: Sendable {
    static let window: TimeInterval = 300
    static let capacity = 300

    private var storage: [Float] = []
    private var start = 0
    private(set) var capacity: Int

    init(capacity: Int = Series.capacity) {
        self.capacity = max(capacity, 1)
        storage.reserveCapacity(self.capacity)
    }

    var values: [Double] { ordered.map(Double.init) }

    var latest: Double {
        guard !storage.isEmpty else { return 0 }
        return Double(storage[(start + storage.count - 1) % storage.count])
    }

    var peak: Double { storage.max().map(Double.init) ?? 0 }

    private var ordered: [Float] { Array(storage[start...] + storage[..<start]) }

    mutating func append(_ value: Double) {
        let value = Float(value)
        guard storage.count == capacity else { return storage.append(value) }
        storage[start] = value
        start = (start + 1) % capacity
    }

    mutating func resize(to newCapacity: Int) {
        let newCapacity = max(newCapacity, 1)
        guard newCapacity != capacity else { return }
        var kept = Array(ordered.suffix(newCapacity))
        kept.reserveCapacity(newCapacity)
        storage = kept
        start = 0
        capacity = newCapacity
    }
}

extension Series: Equatable {
    static func == (lhs: Series, rhs: Series) -> Bool {
        lhs.capacity == rhs.capacity && lhs.ordered == rhs.ordered
    }
}

struct GroupHistory: Sendable, Equatable {
    // Key path literals are immutable; they just don't declare Sendable.
    nonisolated(unsafe) private static let allSeries: [WritableKeyPath<GroupHistory, Series>] = [
        \.cpu, \.memory, \.impact, \.energy, \.network, \.disk, \.gpu,
    ]

    private(set) var cpu: Series
    private(set) var memory: Series
    private(set) var impact: Series
    private(set) var energy: Series
    private(set) var network: Series
    private(set) var disk: Series
    private(set) var gpu: Series

    init(capacity: Int = Series.capacity) {
        let empty = Series(capacity: capacity)
        (cpu, memory, impact, energy, network, disk, gpu) = (empty, empty, empty, empty, empty, empty, empty)
    }

    mutating func append(_ metrics: Metrics) {
        cpu.append(metrics.cpu)
        memory.append(Double(metrics.memory))
        impact.append(metrics.energyImpact)
        energy.append(metrics.energy)
        network.append(metrics.network)
        disk.append(metrics.disk)
        gpu.append(metrics.gpu)
    }

    mutating func resize(to capacity: Int) {
        for path in Self.allSeries { self[keyPath: path].resize(to: capacity) }
    }

    func series(for column: MetricColumn) -> Series {
        switch column {
        case .cpu: cpu
        case .memory: memory
        case .impact: impact
        case .energy: energy
        case .network: network
        case .disk: disk
        case .gpu: gpu
        }
    }
}

struct SystemHistory: Sendable, Equatable {
    nonisolated(unsafe) private static let allSeries: [WritableKeyPath<SystemHistory, Series>] = [
        \.cpu, \.memory, \.gpu, \.netIn, \.netOut, \.diskRead, \.diskWrite,
    ]

    private(set) var cpu: Series
    private(set) var memory: Series
    private(set) var gpu: Series
    private(set) var netIn: Series
    private(set) var netOut: Series
    private(set) var diskRead: Series
    private(set) var diskWrite: Series

    init(capacity: Int = Series.capacity) {
        let empty = Series(capacity: capacity)
        (cpu, memory, gpu, netIn, netOut, diskRead, diskWrite) = (empty, empty, empty, empty, empty, empty, empty)
    }

    mutating func append(_ snapshot: SystemSnapshot) {
        let memoryFraction = snapshot.memoryTotal > 0 ? Double(snapshot.memoryUsed) / Double(snapshot.memoryTotal) : 0
        cpu.append(snapshot.cpuTotal)
        memory.append(memoryFraction)
        gpu.append(snapshot.gpuUtilization ?? 0)
        netIn.append(snapshot.netInBps)
        netOut.append(snapshot.netOutBps)
        diskRead.append(snapshot.diskReadBps)
        diskWrite.append(snapshot.diskWriteBps)
    }

    mutating func resize(to capacity: Int) {
        for path in Self.allSeries { self[keyPath: path].resize(to: capacity) }
    }
}
