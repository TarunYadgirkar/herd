import Darwin

struct CoreCluster: Identifiable, Sendable {
    let name: String
    let level: Int
    let cores: Range<Int>

    var id: Int { level }
}

enum CPUTopology {
    static let clusters: [CoreCluster] = load()

    static func clusters(coreCount: Int) -> [CoreCluster] {
        let fitted = clusters.compactMap { cluster -> CoreCluster? in
            let upper = min(cluster.cores.upperBound, coreCount)
            guard cluster.cores.lowerBound < upper else { return nil }
            return CoreCluster(name: cluster.name, level: cluster.level, cores: cluster.cores.lowerBound..<upper)
        }
        guard fitted.isEmpty else { return fitted }
        return [CoreCluster(name: "Cores", level: 0, cores: 0..<coreCount)]
    }

    // The per-cluster readings carry no perflevel, so slowest readings are paired with the slowest level by core count.
    static func frequencies(for clusters: [CoreCluster], readings: [ClusterReading]) -> [Int: Double] {
        var remaining = readings.sorted { $0.maxFrequencyMHz < $1.maxFrequencyMHz }[...]
        var result: [Int: Double] = [:]
        for cluster in clusters.sorted(by: { $0.level > $1.level }) {
            var cores = 0
            var weighted = 0.0
            while cores < cluster.cores.count, let next = remaining.popFirst() {
                cores += next.cores
                weighted += next.frequencyMHz * Double(next.cores)
            }
            guard cores == cluster.cores.count, cores > 0 else { return [:] }
            result[cluster.level] = weighted / Double(cores)
        }
        return result
    }

    // host_processor_info lists the slowest perflevel first, so perflevel0 owns the last cores (verified on M5 Pro under background-QoS load).
    private static func load() -> [CoreCluster] {
        guard let levels = integer("hw.nperflevels"), levels > 0 else { return [] }
        var start = 0
        return (0..<levels).reversed().compactMap { level in
            guard let count = integer("hw.perflevel\(level).logicalcpu"), count > 0 else { return nil }
            defer { start += count }
            // Intel Macs have one level and may leave it unnamed.
            let name = string("hw.perflevel\(level).name") ?? (levels == 1 ? "Cores" : "Level \(level)")
            return CoreCluster(name: name, level: level, cores: start..<(start + count))
        }
    }

    private static func integer(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }

    private static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}
