import Foundation

protocol Dated {
    var date: Date { get }
}

extension SystemPoint: Dated {}
extension CorePoint: Dated {}

// Trimming advances a head index and compacts only once dead entries outnumber live ones, so each tick stays O(1) amortized.
struct DatedRing<Element: Dated> {
    private static var compactionFloor: Int { 64 }

    private var storage: [Element] = []
    private var head = 0

    var elements: ArraySlice<Element> { storage[head...] }
    var last: Element? { head < storage.count ? storage.last : nil }

    init(_ elements: [Element] = []) {
        storage = elements
    }

    mutating func append(_ element: Element) {
        storage.append(element)
    }

    mutating func drop(before cutoff: Date) {
        while head < storage.count, storage[head].date < cutoff { head += 1 }
        guard head >= Self.compactionFloor, head > storage.count - head else { return }
        storage.removeFirst(head)
        head = 0
    }

    mutating func drop(from cutoff: Date) {
        let start = firstIndex(atOrAfter: cutoff)
        storage.removeSubrange(start...)
    }

    func slice(since cutoff: Date) -> ArraySlice<Element> {
        storage[firstIndex(atOrAfter: cutoff)...]
    }

    private func firstIndex(atOrAfter cutoff: Date) -> Int {
        var low = head
        var high = storage.count
        while low < high {
            let mid = (low + high) / 2
            if storage[mid].date < cutoff { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

struct PointAccumulator {
    // Key path literals are immutable; they just don't declare Sendable.
    nonisolated(unsafe) private static let meanFields: [WritableKeyPath<SystemPoint, Double>] = [
        \.cpuUser, \.cpuSystem, \.memoryUsed, \.appMemory, \.wiredMemory, \.compressedMemory,
        \.cachedFiles, \.swapUsed, \.gpu, \.netIn, \.netOut, \.diskRead, \.diskWrite,
    ]
    nonisolated(unsafe) private static let optionalFields: [WritableKeyPath<SystemPoint, Double?>] = [
        \.cpuWatts, \.gpuWatts, \.aneWatts, \.dramWatts, \.systemWatts,
        \.cpuCelsius, \.gpuCelsius, \.lidCelsius, \.fanRPM, \.batteryPercent, \.batteryWatts,
    ]

    private(set) var count = 0
    private var dateSum: Double = 0
    private var pressure = 0
    private var sums = [Double](repeating: 0, count: meanFields.count)
    private var optionalSums = [Double](repeating: 0, count: optionalFields.count)
    private var optionalCounts = [Int](repeating: 0, count: optionalFields.count)
    private var contributors = ContributorAccumulator()

    var date: Date? { count > 0 ? Date(timeIntervalSinceReferenceDate: dateSum / Double(count)) : nil }

    mutating func add(_ point: SystemPoint) {
        count += 1
        contributors.add(point.contributors)
        dateSum += point.date.timeIntervalSinceReferenceDate
        pressure = max(pressure, point.pressure)
        for (index, field) in Self.meanFields.enumerated() { sums[index] += point[keyPath: field] }
        for (index, field) in Self.optionalFields.enumerated() {
            guard let value = point[keyPath: field] else { continue }
            optionalSums[index] += value
            optionalCounts[index] += 1
        }
    }

    func average() -> SystemPoint? {
        guard let date else { return nil }
        let total = Double(count)
        var point = SystemPoint.empty(at: date)
        point.pressure = pressure
        point.contributors = contributors.merged()
        for (index, field) in Self.meanFields.enumerated() { point[keyPath: field] = sums[index] / total }
        for (index, field) in Self.optionalFields.enumerated() where optionalCounts[index] > 0 {
            point[keyPath: field] = optionalSums[index] / Double(optionalCounts[index])
        }
        return point
    }
}

// Samples without contributor data (older files) don't count, so they can't dilute the averages of samples that have it.
struct ContributorAccumulator {
    private struct Totals {
        var latest: Contributor
        var cpu: Double = 0
        var energy: Double = 0
        var memory: UInt64 = 0
    }

    private var totals: [String: Totals] = [:]
    private var samples = 0

    mutating func add(_ contributors: [Contributor]?) {
        guard let contributors else { return }
        samples += 1
        for contributor in contributors {
            var entry = totals[contributor.id] ?? Totals(latest: contributor)
            entry.latest = contributor
            entry.cpu += contributor.cpu
            entry.energy += contributor.energy
            entry.memory = max(entry.memory, contributor.memory)
            totals[contributor.id] = entry
        }
    }

    func merged() -> [Contributor]? {
        guard samples > 0 else { return nil }
        let count = Double(samples)
        return Contributor.leaders(totals.values.map { entry in
            Contributor(
                id: entry.latest.id, name: entry.latest.name, bundlePath: entry.latest.bundlePath,
                cpu: entry.cpu / count, memory: entry.memory, energy: entry.energy / count
            )
        })
    }
}

// A resolution of zero keeps every sample; otherwise samples are averaged into fixed wall-clock buckets.
struct HistoryTier {
    let resolution: TimeInterval
    let retention: TimeInterval
    private(set) var ring: DatedRing<SystemPoint>
    private var pending = PointAccumulator()
    private var pendingBucket: Int64?

    init(resolution: TimeInterval, retention: TimeInterval, restoring points: [SystemPoint] = []) {
        self.resolution = resolution
        self.retention = retention
        ring = DatedRing(points)
    }

    var partial: SystemPoint? { pending.average() }
    var latestDate: Date? { pending.date ?? ring.last?.date }

    mutating func add(_ point: SystemPoint) {
        defer { ring.drop(before: point.date.addingTimeInterval(-retention)) }
        guard resolution > 0 else { return ring.append(point) }
        let bucket = Int64((point.date.timeIntervalSinceReferenceDate / resolution).rounded(.down))
        if bucket != pendingBucket { flush() }
        pendingBucket = bucket
        pending.add(point)
    }

    mutating func rewind(to date: Date) {
        flush()
        ring.drop(from: date)
    }

    func count(since cutoff: Date) -> Int {
        ring.slice(since: cutoff).count + (partialIncluded(since: cutoff) ? 1 : 0)
    }

    func firstDate(since cutoff: Date) -> Date? {
        ring.slice(since: cutoff).first?.date ?? (partialIncluded(since: cutoff) ? pending.date : nil)
    }

    func points(since cutoff: Date) -> [SystemPoint] {
        var result = Array(ring.slice(since: cutoff))
        if partialIncluded(since: cutoff), let partial { result.append(partial) }
        return result
    }

    func persisted() -> [SystemPoint] {
        points(since: .distantPast)
    }

    private func partialIncluded(since cutoff: Date) -> Bool {
        guard let date = pending.date else { return false }
        return date >= cutoff
    }

    private mutating func flush() {
        if let point = pending.average() { ring.append(point) }
        pending = PointAccumulator()
        pendingBucket = nil
    }
}

extension SystemPoint {
    static func empty(at date: Date) -> SystemPoint {
        SystemPoint(
            date: date, cpuUser: 0, cpuSystem: 0, memoryUsed: 0, appMemory: 0, wiredMemory: 0,
            compressedMemory: 0, cachedFiles: 0, swapUsed: 0, pressure: MemoryPressure.normal.rawValue, gpu: 0,
            netIn: 0, netOut: 0, diskRead: 0, diskWrite: 0
        )
    }

    init(_ snapshot: SystemSnapshot, at date: Date) {
        let power = snapshot.power
        let sensors = snapshot.sensors
        self.init(
            date: date,
            cpuUser: snapshot.cpuUser,
            cpuSystem: snapshot.cpuSystem,
            memoryUsed: Double(snapshot.memoryUsed),
            appMemory: Double(snapshot.appMemory),
            wiredMemory: Double(snapshot.wiredMemory),
            compressedMemory: Double(snapshot.compressedMemory),
            cachedFiles: Double(snapshot.cachedFiles),
            swapUsed: Double(snapshot.swapUsed),
            pressure: snapshot.pressure.rawValue,
            gpu: snapshot.gpuUtilization ?? 0,
            netIn: snapshot.netInBps,
            netOut: snapshot.netOutBps,
            diskRead: snapshot.diskReadBps,
            diskWrite: snapshot.diskWriteBps,
            cpuWatts: power?.cpuWatts,
            gpuWatts: power?.gpuWatts,
            aneWatts: power?.aneWatts,
            dramWatts: power?.dramWatts,
            systemWatts: power?.systemWatts,
            cpuCelsius: sensors?.cpuCelsius,
            gpuCelsius: sensors?.gpuCelsius,
            lidCelsius: sensors?.lidCelsius,
            fanRPM: sensors?.fans.map(\.rpm).max(),
            batteryPercent: snapshot.batteryDetails?.percent ?? snapshot.battery?.percent,
            batteryWatts: snapshot.batteryDetails?.watts
        )
    }
}

extension Contributor {
    init(_ group: AppGroup) {
        let metrics = group.metrics
        self.init(id: group.id, name: group.name, bundlePath: group.bundlePath, cpu: metrics.cpu, memory: metrics.memory, energy: metrics.energy)
    }
}

extension CorePoint {
    init(_ snapshot: SystemSnapshot, at date: Date) {
        let clusters = snapshot.power?.clusters ?? []
        self.init(
            date: date,
            usage: snapshot.perCoreUsage,
            clusterFrequenciesMHz: Dictionary(clusters.map { ($0.name, $0.frequencyMHz) }, uniquingKeysWith: { first, _ in first })
        )
    }
}
