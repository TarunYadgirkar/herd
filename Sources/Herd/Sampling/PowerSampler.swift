import Darwin
import Foundation
import IOKit

final class PowerSampler {
    enum EnergySource: Sendable {
        case clpc
        case energyModel
    }

    private static let minimumIntervalSeconds = 0.01
    private static let clpcZeroSamplesBeforeFallback = 3

    private let api: IOReportAPI?
    private let subscription: IOReportSubscription?
    private let channelsKey = "IOReportChannels" as CFString
    private var previous: (sample: CFDictionary, nanos: UInt64)?
    private var layout: SampleLayout?
    private var clpcZeroStreak = 0
    private(set) var energySource: EnergySource = .clpc

    // Intel Macs publish no IOReport energy or cluster channels; their chip power comes from the SMC instead (SensorSampler).
    var isAvailable: Bool { subscription != nil }

    init() {
        #if arch(x86_64)
        let api: IOReportAPI? = nil
        #else
        let api = IOReportAPI()
        #endif
        self.api = api
        subscription = api.flatMap(IOReportSubscription.init)
        if subscription?.hasCLPC != true { energySource = .energyModel }
    }

    func sample() -> PowerReading? {
        guard let api, let subscription,
              let current = api.createSamples(subscription.ref, subscription.channels, nil)?.takeRetainedValue()
        else { return nil }
        let now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        guard let previous else {
            self.previous = (current, now)
            layout = SampleLayout(sample: current, api: api, channelsKey: channelsKey)
            return nil
        }
        let seconds = Double(now &- previous.nanos) / 1e9
        guard seconds >= Self.minimumIntervalSeconds else { return nil }
        self.previous = (current, now)
        guard let delta = api.createDelta(previous.sample, current, nil)?.takeRetainedValue() else { return nil }
        return reading(from: delta, seconds: seconds, api: api)
    }

    private func reading(from delta: CFDictionary, seconds: Double, api: IOReportAPI) -> PowerReading {
        var tally = SampleTally()
        forEachChannel(in: delta) { channel in
            accumulate(channel, into: &tally, seconds: seconds, api: api)
        }
        let energy = resolveEnergy(tally)
        var reading = PowerReading(cpuWatts: energy.cpu, gpuWatts: energy.gpu, aneWatts: energy.ane, dramWatts: energy.dram > 0 ? energy.dram : nil)
        reading.clusters = clusterReadings(tally.clusters)
        guard let gpu = layout?.gpu else { return reading }
        reading.gpuFrequencyMHz = tally.gpu.frequencyMHz
        reading.gpuMaxFrequencyMHz = gpu.frequencies.last ?? 0
        reading.gpuActiveFraction = tally.gpu.activeFraction
        return reading
    }

    private func accumulate(_ channel: CFDictionary, into tally: inout SampleTally, seconds: Double, api: IOReportAPI) {
        let group = api.string(api.group(channel))
        let name = api.string(api.channelName(channel))
        switch group {
        case "CLPC":
            tally.clpcPresent = true
            tally.clpc.add(watts(channel, seconds: seconds, api: api), clpcName: name)
        case "Energy Model":
            tally.model.add(watts(channel, seconds: seconds, api: api), modelName: name)
        case "CPU Stats":
            accumulateCore(channel, name: name, into: &tally, api: api)
        case "GPU Stats" where name == SampleLayout.gpuChannel:
            guard let gpu = layout?.gpu else { return }
            tally.gpu = residency(channel, layout: gpu, api: api)
        default:
            return
        }
    }

    private func accumulateCore(_ channel: CFDictionary, name: String, into tally: inout SampleTally, api: IOReportAPI) {
        guard let prefix = SampleLayout.corePrefix(of: name),
              let cluster = layout?.clusters.first(where: { $0.prefix == prefix })
        else { return }
        let core = residency(channel, layout: cluster.states, api: api)
        tally.clusters[prefix, default: ClusterTally()].add(core)
    }

    private func residency(_ channel: CFDictionary, layout: StateLayout, api: IOReportAPI) -> Residency {
        var result = Residency()
        let count = Int(api.stateCount(channel))
        for index in 0..<count {
            let value = Double(max(0, api.stateResidency(channel, Int32(index))))
            result.total += value
            guard index >= layout.firstActive else { continue }
            result.active += value
            result.weightedMHz += value * layout.frequency(atActiveIndex: index - layout.firstActive)
        }
        return result
    }

    private func watts(_ channel: CFDictionary, seconds: Double, api: IOReportAPI) -> Double? {
        let value = api.integerValue(channel, 0)
        guard value >= 0 else { return nil }
        let unit = api.string(api.unitLabel(channel)).trimmingCharacters(in: .whitespaces)
        guard let divisor = Self.joulesDivisor[unit] else { return nil }
        return Double(value) / divisor / seconds
    }

    private static let joulesDivisor: [String: Double] = ["mJ": 1e3, "uJ": 1e6, "nJ": 1e9]

    private func resolveEnergy(_ tally: SampleTally) -> EnergyComponents {
        guard tally.clpcPresent else {
            energySource = .energyModel
            return tally.model
        }
        clpcZeroStreak = tally.clpc.cpu > 0 ? 0 : clpcZeroStreak + 1
        energySource = clpcZeroStreak >= Self.clpcZeroSamplesBeforeFallback ? .energyModel : .clpc
        let primary = energySource == .clpc ? tally.clpc : tally.model
        let secondary = energySource == .clpc ? tally.model : tally.clpc
        return EnergyComponents(
            cpu: primary.cpu > 0 ? primary.cpu : secondary.cpu,
            gpu: primary.gpu > 0 ? primary.gpu : secondary.gpu,
            ane: primary.ane > 0 ? primary.ane : secondary.ane,
            dram: tally.model.dram
        )
    }

    private func clusterReadings(_ tallies: [String: ClusterTally]) -> [ClusterReading] {
        guard let layout else { return [] }
        return layout.clusters.map { cluster in
            let tally = tallies[cluster.prefix] ?? ClusterTally()
            return ClusterReading(
                name: cluster.name,
                cores: cluster.cores,
                frequencyMHz: tally.frequencyMHz,
                maxFrequencyMHz: cluster.states.frequencies.last ?? 0,
                activeFraction: tally.activeFraction
            )
        }
    }

    private func forEachChannel(in samples: CFDictionary, _ body: (CFDictionary) -> Void) {
        guard let raw = CFDictionaryGetValue(samples, Unmanaged.passUnretained(channelsKey).toOpaque()) else { return }
        let array = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue()
        for index in 0..<CFArrayGetCount(array) {
            guard let item = CFArrayGetValueAtIndex(array, index) else { continue }
            body(Unmanaged<CFDictionary>.fromOpaque(item).takeUnretainedValue())
        }
    }
}

private struct EnergyComponents {
    var cpu = 0.0
    var gpu = 0.0
    var ane = 0.0
    var dram = 0.0

    mutating func add(_ watts: Double?, clpcName name: String) {
        guard let watts else { return }
        switch name {
        case "CPU Energy": cpu += watts
        case "GPU Energy": gpu += watts
        case "ANE": ane += watts
        default: return
        }
    }

    mutating func add(_ watts: Double?, modelName name: String) {
        guard let watts else { return }
        if name.hasSuffix("CPU Energy") { cpu += watts }
        else if name == "GPU Energy" { gpu += watts }
        else if name.hasPrefix("ANE") { ane += watts }
        else if name.hasPrefix("DRAM") { dram += watts }
    }
}

private struct Residency {
    var weightedMHz = 0.0
    var active = 0.0
    var total = 0.0

    var frequencyMHz: Double { active > 0 ? weightedMHz / active : 0 }
    var activeFraction: Double { total > 0 ? min(1, active / total) : 0 }
}

private struct ClusterTally {
    var weightedMHz = 0.0
    var active = 0.0
    var fractionSum = 0.0
    var cores = 0

    mutating func add(_ core: Residency) {
        weightedMHz += core.weightedMHz
        active += core.active
        fractionSum += core.activeFraction
        cores += 1
    }

    var frequencyMHz: Double { active > 0 ? weightedMHz / active : 0 }
    var activeFraction: Double { cores > 0 ? fractionSum / Double(cores) : 0 }
}

private struct SampleTally {
    var clpc = EnergyComponents()
    var model = EnergyComponents()
    var clpcPresent = false
    var clusters: [String: ClusterTally] = [:]
    var gpu = Residency()
}

private struct StateLayout {
    let firstActive: Int
    let frequencies: [Double]

    func frequency(atActiveIndex index: Int) -> Double {
        guard let last = frequencies.last else { return 0 }
        return index < frequencies.count ? frequencies[index] : last
    }
}

private struct ClusterLayout {
    let prefix: String
    let name: String
    let cores: Int
    let states: StateLayout
}

private struct ChannelShape {
    let firstActive: Int
    let activeCount: Int
}

private struct SampleLayout {
    static let gpuChannel = "GPUPH"
    private static let rankedCorePrefixes = ["PCPU", "MCPU", "ECPU"]
    private static let inactiveStates: Set<String> = ["IDLE", "DOWN", "OFF"]

    let clusters: [ClusterLayout]
    let gpu: StateLayout?

    static func corePrefix(of name: String) -> String? {
        rankedCorePrefixes.first { name.contains($0) }
    }

    init(sample: CFDictionary, api: IOReportAPI, channelsKey: CFString) {
        var coreShapes: [String: (shape: ChannelShape, cores: Int)] = [:]
        var gpuShape: ChannelShape?
        let channels = ((sample as NSDictionary)[channelsKey as String] as? [NSDictionary]) ?? []
        for item in channels {
            let channel = item as CFDictionary
            let group = api.string(api.group(channel))
            let name = api.string(api.channelName(channel))
            if group == "GPU Stats", name == Self.gpuChannel {
                gpuShape = Self.shape(of: channel, api: api)
            } else if group == "CPU Stats", let prefix = Self.corePrefix(of: name) {
                let shape = coreShapes[prefix]?.shape ?? Self.shape(of: channel, api: api)
                coreShapes[prefix] = (shape, (coreShapes[prefix]?.cores ?? 0) + 1)
            }
        }
        let tables = FrequencyTables.load()
        clusters = Self.clusters(from: coreShapes, tables: tables)
        gpu = gpuShape.map { StateLayout(firstActive: $0.firstActive, frequencies: tables.gpu) }
    }

    private static func shape(of channel: CFDictionary, api: IOReportAPI) -> ChannelShape {
        let names = (0..<api.stateCount(channel)).map { api.string(api.stateName(channel, $0)) }
        let firstActive = names.firstIndex { !inactiveStates.contains($0) } ?? names.count
        return ChannelShape(firstActive: firstActive, activeCount: names.count - firstActive)
    }

    private static func clusters(
        from shapes: [String: (shape: ChannelShape, cores: Int)],
        tables: FrequencyTables
    ) -> [ClusterLayout] {
        let levels = PerformanceLevels.load()
        var usedNames: Set<String> = []
        let present = rankedCorePrefixes.filter { shapes[$0] != nil }
        return present.enumerated().compactMap { rank, prefix in
            guard let entry = shapes[prefix] else { return nil }
            let name = levels.name(rank: rank, cores: entry.cores, excluding: usedNames) ?? prefix
            usedNames.insert(name)
            let frequencies = tables.cpuTable(rank: rank, activeCount: entry.shape.activeCount)
            let states = StateLayout(firstActive: entry.shape.firstActive, frequencies: frequencies)
            return ClusterLayout(prefix: prefix, name: name, cores: entry.cores, states: states)
        }
    }
}

private struct PerformanceLevels {
    let levels: [(name: String, cores: Int)]

    static func load() -> PerformanceLevels {
        let count = SysctlValue.integer("hw.nperflevels") ?? 0
        let levels = (0..<max(0, count)).compactMap { level -> (String, Int)? in
            guard let name = SysctlValue.string("hw.perflevel\(level).name") else { return nil }
            return (name, SysctlValue.integer("hw.perflevel\(level).logicalcpu") ?? 0)
        }
        return PerformanceLevels(levels: levels)
    }

    func name(rank: Int, cores: Int, excluding used: Set<String>) -> String? {
        if rank < levels.count, levels[rank].cores == cores, !used.contains(levels[rank].name) {
            return levels[rank].name
        }
        if let match = levels.first(where: { $0.cores == cores && !used.contains($0.name) }) {
            return match.name
        }
        guard rank < levels.count, !used.contains(levels[rank].name) else { return nil }
        return levels[rank].name
    }
}

private struct FrequencyTables {
    private static let pmgrNodes: Set<String> = ["pmgr", "pmgr-child"]
    private static let legacyCPUKeys = ["voltage-states5-sram", "voltage-states1-sram"]
    private static let gpuKey = "voltage-states9"
    private static let accClustersKey = "acc-clusters"
    private static let entryStride = 8
    private static let hertzThreshold = 50_000_000.0
    private static let kilohertzThreshold = 50_000.0

    let rankedCPU: [[Double]]
    let gpu: [Double]

    func cpuTable(rank: Int, activeCount: Int) -> [Double] {
        if rank < rankedCPU.count, rankedCPU[rank].count == activeCount { return rankedCPU[rank] }
        if let match = rankedCPU.first(where: { $0.count == activeCount }) { return match }
        return rank < rankedCPU.count ? rankedCPU[rank] : []
    }

    static func load() -> FrequencyTables {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator) == KERN_SUCCESS else {
            return FrequencyTables(rankedCPU: [], gpu: [])
        }
        defer { IOObjectRelease(iterator) }
        var cpu: [[Double]] = []
        var gpu: [Double] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard pmgrNodes.contains(registryName(entry)) else { continue }
            if cpu.isEmpty { cpu = rankedCPUKeys(entry).map { table(entry, key: $0) }.filter { !$0.isEmpty } }
            if gpu.isEmpty { gpu = table(entry, key: gpuKey) }
        }
        return FrequencyTables(rankedCPU: cpu, gpu: gpu)
    }

    private static func rankedCPUKeys(_ entry: io_registry_entry_t) -> [String] {
        let bytes = data(entry, key: accClustersKey)
        guard bytes.count >= entryStride * 2 else { return legacyCPUKeys }
        let clusters = stride(from: 0, to: bytes.count - entryStride + 1, by: entryStride).map { offset in
            (table: bytes[offset], tier: bytes[offset + 1])
        }
        return clusters.sorted { $0.tier > $1.tier }.map { "voltage-states\($0.table)-sram" }
    }

    private static func table(_ entry: io_registry_entry_t, key: String) -> [Double] {
        let bytes = data(entry, key: key)
        let raw = stride(from: 0, to: bytes.count - entryStride + 1, by: entryStride).map { offset in
            Double(bytes[offset..<(offset + 4)].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        }.filter { $0 > 0 }
        guard let peak = raw.max() else { return [] }
        let scale = peak >= hertzThreshold ? 1e6 : peak >= kilohertzThreshold ? 1e3 : 1
        return raw.map { $0 / scale }
    }

    private static func data(_ entry: io_registry_entry_t, key: String) -> [UInt8] {
        guard let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let data = value as? Data
        else { return [] }
        return [UInt8](data)
    }

    private static func registryName(_ entry: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(entry, &buffer) == KERN_SUCCESS else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

private enum SysctlValue {
    static func integer(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}

private struct IOReportAPI {
    typealias CopyGroup = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    typealias CreateSubscription = @convention(c) (
        UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?
    ) -> Unmanaged<CFTypeRef>?
    typealias CreateSamples = @convention(c) (CFTypeRef, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias CreateDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias GetString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    typealias GetIndexed = @convention(c) (CFDictionary, Int32) -> Int64
    typealias GetCount = @convention(c) (CFDictionary) -> Int32
    typealias GetIndexedString = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?

    private static let libraryPath = "/usr/lib/libIOReport.dylib"

    let copyGroup: CopyGroup
    let createSubscription: CreateSubscription
    let createSamples: CreateSamples
    let createDelta: CreateDelta
    let group: GetString
    let channelName: GetString
    let unitLabel: GetString
    let integerValue: GetIndexed
    let stateCount: GetCount
    let stateName: GetIndexedString
    let stateResidency: GetIndexed

    init?() {
        guard let handle = dlopen(Self.libraryPath, RTLD_NOW) else { return nil }
        func load<T>(_ symbol: String, as type: T.Type) -> T? {
            dlsym(handle, symbol).map { unsafeBitCast($0, to: type) }
        }
        guard let copyGroup = load("IOReportCopyChannelsInGroup", as: CopyGroup.self),
              let createSubscription = load("IOReportCreateSubscription", as: CreateSubscription.self),
              let createSamples = load("IOReportCreateSamples", as: CreateSamples.self),
              let createDelta = load("IOReportCreateSamplesDelta", as: CreateDelta.self),
              let group = load("IOReportChannelGetGroup", as: GetString.self),
              let channelName = load("IOReportChannelGetChannelName", as: GetString.self),
              let unitLabel = load("IOReportChannelGetUnitLabel", as: GetString.self),
              let integerValue = load("IOReportSimpleGetIntegerValue", as: GetIndexed.self),
              let stateCount = load("IOReportStateGetCount", as: GetCount.self),
              let stateName = load("IOReportStateGetNameForIndex", as: GetIndexedString.self),
              let stateResidency = load("IOReportStateGetResidency", as: GetIndexed.self)
        else { return nil }
        self.copyGroup = copyGroup
        self.createSubscription = createSubscription
        self.createSamples = createSamples
        self.createDelta = createDelta
        self.group = group
        self.channelName = channelName
        self.unitLabel = unitLabel
        self.integerValue = integerValue
        self.stateCount = stateCount
        self.stateName = stateName
        self.stateResidency = stateResidency
    }

    func string(_ value: Unmanaged<CFString>?) -> String {
        guard let value else { return "" }
        return value.takeUnretainedValue() as String
    }

    func channels(group: String, subgroup: String?) -> (container: NSDictionary, items: [NSDictionary])? {
        guard let copied = copyGroup(group as CFString, subgroup as CFString?, 0, 0, 0)?.takeRetainedValue() else { return nil }
        let container = copied as NSDictionary
        return (container, (container["IOReportChannels"] as? [NSDictionary]) ?? [])
    }
}

private struct IOReportSubscription {
    private static let energyGroup = "Energy Model"

    let ref: CFTypeRef
    let channels: CFMutableDictionary
    let hasCLPC: Bool

    init?(api: IOReportAPI) {
        let base = Self.baseChannels(api: api)
        guard let container = base.container else { return nil }
        let clpc = CLPCChannels.descriptors()
        if !clpc.isEmpty, let subscribed = Self.subscribe(api: api, container: container, items: base.items + clpc) {
            (ref, channels, hasCLPC) = (subscribed.ref, subscribed.channels, true)
            return
        }
        guard let subscribed = Self.subscribe(api: api, container: container, items: base.items) else { return nil }
        (ref, channels, hasCLPC) = (subscribed.ref, subscribed.channels, false)
    }

    private static func baseChannels(api: IOReportAPI) -> (container: NSDictionary?, items: [NSDictionary]) {
        let sources = [
            api.channels(group: "CPU Stats", subgroup: "CPU Core Performance States"),
            api.channels(group: "GPU Stats", subgroup: "GPU Performance States"),
            api.channels(group: energyGroup, subgroup: nil),
        ].compactMap { $0 }
        let items = sources.flatMap { source in
            source.items.filter { isWanted($0, api: api) }
        }
        return (sources.first?.container, items)
    }

    private static func isWanted(_ item: NSDictionary, api: IOReportAPI) -> Bool {
        let channel = item as CFDictionary
        guard api.string(api.group(channel)) == energyGroup else { return true }
        let name = api.string(api.channelName(channel))
        return name.hasSuffix("CPU Energy") || name == "GPU Energy" || name.hasPrefix("ANE") || name.hasPrefix("DRAM")
    }

    private static func subscribe(
        api: IOReportAPI,
        container: NSDictionary,
        items: [NSDictionary]
    ) -> (ref: CFTypeRef, channels: CFMutableDictionary)? {
        guard !items.isEmpty else { return nil }
        let request = NSMutableDictionary(dictionary: container)
        request["IOReportChannels"] = NSMutableArray(array: items)
        var subscribed: Unmanaged<CFMutableDictionary>?
        let ref = api.createSubscription(nil, request as CFMutableDictionary, &subscribed, 0, nil)?.takeRetainedValue()
        guard let channels = subscribed?.takeRetainedValue(), let ref else { return nil }
        return (ref, channels)
    }
}

// AppleCLPC energy report IDs for macOS 27, from macmon (src_lib/clpc.rs). Energy Model CPU/ANE counters
// read zero there without Apple's entitlement, but these hand-built CLPC channels still report nJ totals.
private enum CLPCChannels {
    private static let supportedOSMajor = "27"
    private static let cpuIndex: UInt64 = 16
    private static let gpuIndex: UInt64 = 25
    private static let aneIndex: UInt64 = 24
    private static let channelType: Int64 = 1 | (2 << 16) | (1 << 32)
    private static let nanojouleUnit: Int64 = (3 << 56) | (118 << 32)

    private static let keysByBundle: [String: (cpu: UInt64, gpu: UInt64, ane: UInt64)] = [
        "com.apple.driver.AppleT6000CLPCv3": (0x4747_9059, 0x4519_bf1e, 0x9aaa_17f8),
        "com.apple.driver.AppleT6002CLPC": (0xb501_816b, 0x9e2c_3e8b, 0x14d5_a574),
        "com.apple.driver.AppleT6020CLPC": (0xe301_cd75, 0x8f34_cc7a, 0x7415_fb0f),
        "com.apple.driver.AppleT6022CLPC": (0x76f5_fd21, 0x9062_4499, 0x3c09_7307),
        "com.apple.driver.AppleT6030CLPC": (0xbe03_a01a, 0x472d_6c9c, 0xb899_0c38),
        "com.apple.driver.AppleT6031CLPC": (0xd81e_0084, 0x1085_f98b, 0x313a_3be1),
        "com.apple.driver.AppleT6032CLPC": (0xf4a2_1308, 0x85e8_0513, 0x63dc_8e25),
        "com.apple.driver.AppleT6041CLPC": (0x263c_f1f0, 0x22e4_cf59, 0x7849_fb5c),
        "com.apple.driver.AppleT6050CLPC": (0xd3ab_60bb, 0x27cd_4ce5, 0x8c0f_1c59),
        "com.apple.driver.AppleT6050dCLPC": (0x18b3_010e, 0xedec_a11a, 0x188b_d883),
        "com.apple.driver.AppleT8103CLPCv3": (0x2cdd_31f2, 0x21be_cf42, 0x0667_fb81),
        "com.apple.driver.AppleT8112CLPC": (0xb543_5137, 0x638d_9d52, 0xea08_9c36),
        "com.apple.driver.AppleT8122CLPC": (0x54b5_1c99, 0xce2d_d9dc, 0x960a_fe2f),
        "com.apple.driver.AppleT8132CLPC": (0x4a85_4d94, 0x3b3e_3b79, 0x1ff4_a9ec),
        "com.apple.driver.AppleT8140CLPC": (0x9bf5_4436, 0xef70_589c, 0x569d_941b),
        "com.apple.driver.AppleT8142CLPC": (0x4370_8744, 0x6a01_0933, 0xbc5e_fdf0),
        "com.apple.driver.AppleT8152CLPC": (0x485d_4bfc, 0x1178_4654, 0x9380_c6bb),
    ]

    static func descriptors() -> [NSDictionary] {
        guard SysctlValue.string("kern.osproductversion")?.split(separator: ".").first == Substring(supportedOSMajor) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleCLPC"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [NSDictionary] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            result += descriptors(for: entry)
        }
        return result
    }

    private static func descriptors(for entry: io_registry_entry_t) -> [NSDictionary] {
        var driver: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(entry, &driver) == KERN_SUCCESS,
              let bundle = IORegistryEntryCreateCFProperty(entry, "CFBundleIdentifier" as CFString, kCFAllocatorDefault, 0)?
                  .takeRetainedValue() as? String,
              let keys = keysByBundle[bundle]
        else { return [] }
        return [
            channel(driver: driver, id: cpuIndex << 32 | keys.cpu, name: "CPU Energy"),
            channel(driver: driver, id: gpuIndex << 32 | keys.gpu, name: "GPU Energy"),
            channel(driver: driver, id: aneIndex << 32 | keys.ane, name: "ANE"),
        ]
    }

    // IOReport's getters cache derived fields in the channel dictionary, so it must be mutable.
    private static func channel(driver: UInt64, id: UInt64, name: String) -> NSDictionary {
        NSMutableDictionary(dictionary: [
            "DriverID": NSNumber(value: Int64(bitPattern: driver)),
            "DriverName": "AppleCLPC",
            "IOReportGroupName": "CLPC",
            "IOReportSubGroupName": "Energy Counters",
            "IOReportChannelInfo": ["IOReportChannelUnit": NSNumber(value: nanojouleUnit)],
            "LegendChannel": [NSNumber(value: Int64(bitPattern: id)), NSNumber(value: channelType), name],
        ])
    }
}
