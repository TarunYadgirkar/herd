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
        \.cpuCelsius, \.gpuCelsius, \.fanRPM, \.batteryPercent, \.batteryWatts,
    ]

    private(set) var count = 0
    private var dateSum: Double = 0
    private var pressure = 0
    private var sums = [Double](repeating: 0, count: meanFields.count)
    private var optionalSums = [Double](repeating: 0, count: optionalFields.count)
    private var optionalCounts = [Int](repeating: 0, count: optionalFields.count)

    mutating func add(_ point: SystemPoint) {
        count += 1
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
        guard count > 0 else { return nil }
        let total = Double(count)
        var point = SystemPoint.empty(at: Date(timeIntervalSinceReferenceDate: dateSum / total))
        point.pressure = pressure
        for (index, field) in Self.meanFields.enumerated() { point[keyPath: field] = sums[index] / total }
        for (index, field) in Self.optionalFields.enumerated() where optionalCounts[index] > 0 {
            point[keyPath: field] = optionalSums[index] / Double(optionalCounts[index])
        }
        return point
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
    var latestDate: Date? { partial?.date ?? ring.last?.date }

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
        ring.slice(since: cutoff).first?.date ?? (partialIncluded(since: cutoff) ? partial?.date : nil)
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
        guard let partial else { return false }
        return partial.date >= cutoff
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
            fanRPM: sensors?.fans.map(\.rpm).max(),
            batteryPercent: snapshot.batteryDetails?.percent ?? snapshot.battery?.percent,
            batteryWatts: snapshot.batteryDetails?.watts
        )
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
