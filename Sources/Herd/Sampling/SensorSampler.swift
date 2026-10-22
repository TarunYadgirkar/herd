import Darwin
import Foundation

private enum SensorRole {
    case cpu, gpu, ssd, battery, lid, palmRest, other
}

private struct RoleTemperature {
    let role: SensorRole
    let reading: TemperatureReading
}

private struct SMCChannel {
    let key: SMCKey
    let info: SMCKeyInfo
}

private struct TemperatureChannel {
    let channel: SMCChannel
    let id: String
    let name: String
    let role: SensorRole
    let zone: SensorZone
}

private struct FanChannel {
    let index: Int
    let actual: SMCChannel
    let minimumRPM: Double
    let maximumRPM: Double
}

private struct SMCPlan {
    let temperatures: [TemperatureChannel]
    let fans: [FanChannel]
    let systemPower: SMCChannel?
    let adapterPower: SMCChannel?
    let cpuPower: SMCChannel?
    let gpuPower: SMCChannel?
}

private enum SensorCatalog {
    static let plausibleCelsius = 1.0...150.0
    static let temperaturePrefix = UInt32(UInt8(ascii: "T"))
    static let floatType = SMCKey("flt ")
    static let signedFixedPointPrefix = "sp"

    // Key meanings follow exelban/stats and dkorunic/iSMC, which agree on the M5 core and GPU tables.
    static let m5SuperCores = ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K"]
    static let m5PerformanceCores = ["Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"]
    static let m5GPUClusters = ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"]
    static let memoryPrefix = "Tm"
    // iSMC: these two mirror a Performance core instead of measuring memory.
    static let memoryMirrors: Set<String> = ["Tm0y", "Tm2T"]
    static let cpuFallbackPrefix = "Tp"
    static let gpuFallbackPrefix = "Tg"

    // Intel Macs use upper-case keys (VirtualSMC's SMCSensorKeys.txt, exelban/stats): TCnC per core, die and proximity otherwise.
    static func isIntelCore(_ key: String) -> Bool {
        let characters = Array(key)
        return characters.count == 4 && key.hasPrefix("TC") && characters[2].isNumber && characters[3] == "C"
    }

    static let intelCPU: [(key: String, name: String)] = [
        ("TCXC", "CPU die"), ("TC0F", "CPU die"), ("TC0E", "CPU die"), ("TC0D", "CPU die"), ("TCAD", "CPU package"), ("TC0P", "CPU proximity"),
    ]
    static let intelGPU: [(key: String, name: String)] = [
        ("TCGC", "Intel graphics"), ("TGDD", "Radeon"), ("TG0D", "GPU die"), ("TG0P", "GPU proximity"),
    ]
    // CPU package and graphics power, best key first; Macs differ in which of these they publish.
    static let intelCPUPower = ["PCPC", "PCPT", "PCTR", "PC0C"].map(SMCKey.init)
    static let intelGPUPower = ["PCPG", "PCGC", "PG0R"].map(SMCKey.init)

    static let ssdKeys = ["TH0x", "TH0a", "TH0b"]
    static let batteryPriority = ["TB0T", "TB1T", "TB2T"]
    static let lid = "TAOL"
    static let palmRest = ["Ts0P", "Ts1P"]
    static let body: [(key: String, name: String)] = [
        ("TaLP", "Airflow left"), ("TaRF", "Airflow right"), ("TCHP", "Charger"), ("TW0P", "Wi-Fi"),
    ]

    static let fanCount = SMCKey("FNum")
    static let systemPower = SMCKey("PSTR")
    static let adapterPower = SMCKey("PDTR")
    static let maxFans = 8
}

private struct SMCSample {
    let temperatures: [RoleTemperature]
    let fans: [FanReading]
    let systemWatts: Double?
    let adapterInWatts: Double?
    let cpuWatts: Double?
    let gpuWatts: Double?
}

// Each SMC read is a ~150 µs firmware round trip, so a full sweep of every temperature
// costs ~5 ms. Temperatures are refreshed in a rotating batch sized so that every channel
// is re-read within `fullCycleNanoseconds`; fans and power are read every tick.
private final class SMCSensorSource {
    private static let fullCycleNanoseconds = 5_000_000_000.0

    private let smc: SMC
    private let plan: SMCPlan
    private var celsius: [Double?]
    private var cursor = 0
    private var lastRefresh: UInt64

    init(smc: SMC, plan: SMCPlan) {
        self.smc = smc
        self.plan = plan
        celsius = plan.temperatures.map { _ in nil }
        lastRefresh = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        refresh(count: plan.temperatures.count)
    }

    func sample() -> SMCSample {
        refreshDueTemperatures()
        let temperatures = zip(plan.temperatures, celsius).compactMap { channel, celsius in
            celsius.map {
                RoleTemperature(role: channel.role, reading: TemperatureReading(key: channel.id, name: channel.name, zone: channel.zone, celsius: $0))
            }
        }
        return SMCSample(
            temperatures: temperatures,
            fans: plan.fans.compactMap(readFan),
            systemWatts: plan.systemPower.flatMap(read),
            adapterInWatts: plan.adapterPower.flatMap(read),
            cpuWatts: plan.cpuPower.flatMap(read).map { max($0, 0) },
            gpuWatts: plan.gpuPower.flatMap(read).map { max($0, 0) }
        )
    }

    private func refreshDueTemperatures() {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let elapsed = Double(now - lastRefresh)
        lastRefresh = now
        let total = plan.temperatures.count
        let due = (Double(total) * elapsed / Self.fullCycleNanoseconds).rounded(.up)
        refresh(count: min(total, max(1, Int(due))))
    }

    private func refresh(count: Int) {
        let total = plan.temperatures.count
        guard total > 0 else { return }
        for offset in 0..<count {
            let index = (cursor + offset) % total
            celsius[index] = read(plan.temperatures[index].channel).flatMap { SensorCatalog.plausibleCelsius.contains($0) ? $0 : nil }
        }
        cursor = (cursor + count) % total
    }

    private func readFan(_ fan: FanChannel) -> FanReading? {
        guard let rpm = read(fan.actual) else { return nil }
        return FanReading(index: fan.index, rpm: max(rpm, 0), minRPM: fan.minimumRPM, maxRPM: fan.maximumRPM)
    }

    private func read(_ channel: SMCChannel) -> Double? {
        smc.read(channel.key, info: channel.info)
    }
}

final class SensorSampler {
    private enum Source {
        case smc(SMCSensorSource)
        case hid(HIDThermalSource)
    }

    private let source: Source?

    init() {
        if let smc = SMC(), let plan = Self.plan(for: smc) {
            source = .smc(SMCSensorSource(smc: smc, plan: plan))
        } else if let hid = HIDThermalSource() {
            source = .hid(hid)
        } else {
            source = nil
        }
    }

    func sample() -> SensorReading? {
        switch source {
        case let .smc(smc): Self.reading(from: smc.sample())
        case let .hid(hid): Self.summarize(hid.sample())
        case nil: nil
        }
    }

    private static func reading(from sample: SMCSample) -> SensorReading? {
        guard !sample.temperatures.isEmpty || !sample.fans.isEmpty || sample.systemWatts != nil || sample.cpuWatts != nil else { return nil }
        let summary = summarize(sample.temperatures)
        return SensorReading(
            cpuCelsius: summary?.cpuCelsius,
            cpuMaxCelsius: summary?.cpuMaxCelsius,
            gpuCelsius: summary?.gpuCelsius,
            ssdCelsius: summary?.ssdCelsius,
            batteryCelsius: summary?.batteryCelsius,
            lidCelsius: summary?.lidCelsius,
            palmRestCelsius: summary?.palmRestCelsius,
            systemWatts: sample.systemWatts,
            adapterInWatts: sample.adapterInWatts,
            cpuWatts: sample.cpuWatts,
            gpuWatts: sample.gpuWatts,
            fans: sample.fans,
            temperatures: summary?.temperatures ?? []
        )
    }

    private static func summarize(_ temperatures: [RoleTemperature]) -> SensorReading? {
        guard !temperatures.isEmpty else { return nil }
        let cpu = celsius(of: .cpu, in: temperatures)
        return SensorReading(
            cpuCelsius: mean(cpu),
            cpuMaxCelsius: cpu.max(),
            gpuCelsius: mean(celsius(of: .gpu, in: temperatures)),
            ssdCelsius: celsius(of: .ssd, in: temperatures).max(),
            batteryCelsius: celsius(of: .battery, in: temperatures).max(),
            lidCelsius: celsius(of: .lid, in: temperatures).max(),
            palmRestCelsius: celsius(of: .palmRest, in: temperatures).max(),
            temperatures: temperatures.map(\.reading)
        )
    }

    private static func celsius(of role: SensorRole, in temperatures: [RoleTemperature]) -> [Double] {
        temperatures.filter { $0.role == role }.map(\.reading.celsius)
    }

    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

extension SensorSampler {
    private static func plan(for smc: SMC) -> SMCPlan? {
        let discovered = discoverTemperatures(smc)
        let temperatures = temperatureChannels(from: discovered)
        let fans = fanChannels(smc)
        let systemPower = channel(SensorCatalog.systemPower, smc: smc)
        let chipPower = chipPowerChannels(smc)
        guard !temperatures.isEmpty || !fans.isEmpty || systemPower != nil || chipPower.cpu != nil else { return nil }
        return SMCPlan(
            temperatures: temperatures,
            fans: fans,
            systemPower: systemPower,
            adapterPower: channel(SensorCatalog.adapterPower, smc: smc),
            cpuPower: chipPower.cpu,
            gpuPower: chipPower.gpu
        )
    }

    // Apple Silicon reads chip power from IOReport, so only Intel spends SMC reads on it.
    private static func chipPowerChannels(_ smc: SMC) -> (cpu: SMCChannel?, gpu: SMCChannel?) {
        #if arch(x86_64)
        let readable = { (keys: [SMCKey]) in
            keys.lazy.compactMap { channel($0, smc: smc) }.first { smc.read($0.key, info: $0.info) != nil }
        }
        return (readable(SensorCatalog.intelCPUPower), readable(SensorCatalog.intelGPUPower))
        #else
        return (nil, nil)
        #endif
    }

    private static func discoverTemperatures(_ smc: SMC) -> [SMCChannel] {
        (0..<smc.keyCount()).compactMap { index in
            guard let key = smc.key(at: index), key.code >> 24 == SensorCatalog.temperaturePrefix,
                  let info = smc.info(for: key), isTemperatureType(info.type),
                  let celsius = smc.read(key, info: info),
                  SensorCatalog.plausibleCelsius.contains(celsius) else { return nil }
            return SMCChannel(key: key, info: info)
        }
    }

    private static func isTemperatureType(_ type: SMCKey) -> Bool {
        type == SensorCatalog.floatType || type.name.hasPrefix(SensorCatalog.signedFixedPointPrefix)
    }

    private static func temperatureChannels(from discovered: [SMCChannel]) -> [TemperatureChannel] {
        let byName = Dictionary(discovered.map { ($0.key.name, $0) }, uniquingKeysWith: { first, _ in first })
        let named = { (key: String, label: String, role: SensorRole, zone: SensorZone) -> TemperatureChannel? in
            byName[key].map { TemperatureChannel(channel: $0, id: key, name: label, role: role, zone: zone) }
        }
        let battery = SensorCatalog.batteryPriority.lazy.compactMap { named($0, "Battery", .battery, .inside) }.first
        return cpuChannels(discovered, named: named)
            + gpuChannels(discovered, named: named)
            + memoryChannels(discovered)
            + numbered(SensorCatalog.ssdKeys, "SSD").compactMap { named($0.key, $0.label, .ssd, .storage) }
            + [named(SensorCatalog.lid, "Lid", .lid, .surface)].compactMap { $0 }
            + numbered(SensorCatalog.palmRest, "Palm rest").compactMap { named($0.key, $0.label, .palmRest, .surface) }
            + [battery].compactMap { $0 }
            + SensorCatalog.body.compactMap { named($0.key, $0.name, .other, .inside) }
    }

    private static func cpuChannels(
        _ discovered: [SMCChannel],
        named: (String, String, SensorRole, SensorZone) -> TemperatureChannel?
    ) -> [TemperatureChannel] {
        guard isM5 else { return fallbackCPUChannels(discovered, named: named) }
        let superCores = numbered(SensorCatalog.m5SuperCores, "Super").compactMap { named($0.key, $0.label, .cpu, .superCores) }
        let performance = numbered(SensorCatalog.m5PerformanceCores, "Performance").compactMap { named($0.key, $0.label, .cpu, .performanceCores) }
        let channels = superCores + performance
        return channels.isEmpty ? fallbackCPUChannels(discovered, named: named) : channels
    }

    private static func fallbackCPUChannels(
        _ discovered: [SMCChannel],
        named: (String, String, SensorRole, SensorZone) -> TemperatureChannel?
    ) -> [TemperatureChannel] {
        // Some Intel Macs also have lower-case Tp keys, which measure the power supply there, so each slice keeps to its own table.
        #if arch(x86_64)
        let cores = discovered.map(\.key.name).filter(SensorCatalog.isIntelCore).sorted()
        if !cores.isEmpty {
            return numbered(cores, "Core").compactMap { named($0.key, $0.label, .cpu, .cpu) }
        }
        for entry in SensorCatalog.intelCPU {
            if let channel = named(entry.key, entry.name, .cpu, .cpu) { return [channel] }
        }
        return []
        #else
        return rawChannels(discovered, prefix: SensorCatalog.cpuFallbackPrefix, role: .cpu, zone: .cpu)
        #endif
    }

    private static func gpuChannels(
        _ discovered: [SMCChannel],
        named: (String, String, SensorRole, SensorZone) -> TemperatureChannel?
    ) -> [TemperatureChannel] {
        let known = isM5 ? numbered(SensorCatalog.m5GPUClusters, "GPU") : []
        let channels = known.compactMap { named($0.key, $0.label, .gpu, .gpu) }
        guard channels.isEmpty else { return channels }
        #if arch(x86_64)
        return SensorCatalog.intelGPU.compactMap { named($0.key, $0.name, .gpu, .gpu) }
        #else
        return rawChannels(discovered, prefix: SensorCatalog.gpuFallbackPrefix, role: .gpu, zone: .gpu)
        #endif
    }

    private static func memoryChannels(_ discovered: [SMCChannel]) -> [TemperatureChannel] {
        discovered
            .filter { $0.key.name.hasPrefix(SensorCatalog.memoryPrefix) && !SensorCatalog.memoryMirrors.contains($0.key.name) }
            .enumerated()
            .map { TemperatureChannel(channel: $0.element, id: $0.element.key.name, name: "Memory \($0.offset + 1)", role: .other, zone: .memory) }
    }

    private static func numbered(_ keys: [String], _ label: String) -> [(key: String, label: String)] {
        keys.enumerated().map { ($0.element, "\(label) \($0.offset + 1)") }
    }

    private static func rawChannels(_ discovered: [SMCChannel], prefix: String, role: SensorRole, zone: SensorZone) -> [TemperatureChannel] {
        discovered.filter { $0.key.name.hasPrefix(prefix) }.map {
            TemperatureChannel(channel: $0, id: $0.key.name, name: $0.key.name, role: role, zone: zone)
        }
    }

    private static func fanChannels(_ smc: SMC) -> [FanChannel] {
        guard let count = value(SensorCatalog.fanCount, smc: smc) else { return [] }
        return (0..<min(Int(count), SensorCatalog.maxFans)).compactMap { index in
            guard let actual = channel(SMCKey("F\(index)Ac"), smc: smc) else { return nil }
            return FanChannel(
                index: index,
                actual: actual,
                minimumRPM: value(SMCKey("F\(index)Mn"), smc: smc) ?? 0,
                maximumRPM: value(SMCKey("F\(index)Mx"), smc: smc) ?? 0
            )
        }
    }

    private static func channel(_ key: SMCKey, smc: SMC) -> SMCChannel? {
        smc.info(for: key).map { SMCChannel(key: key, info: $0) }
    }

    private static func value(_ key: SMCKey, smc: SMC) -> Double? {
        smc.info(for: key).flatMap { smc.read(key, info: $0) }
    }

    private static var isM5: Bool {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return false }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return false }
        let brand = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return brand.contains(" M5")
    }
}

final class HIDThermalSource {
    private typealias ClientCreate = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    private typealias SetMatching = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
    private typealias CopyProperty = @convention(c) (UnsafeRawPointer, CFString) -> UnsafeMutableRawPointer?
    private typealias CopyEvent = @convention(c) (UnsafeRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias GetFloatValue = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double

    private struct Service {
        let handle: UnsafeRawPointer
        let role: SensorRole
        let zone: SensorZone
        let id: String
        let name: String
    }

    private static let frameworkPath = "/System/Library/Frameworks/IOKit.framework/IOKit"
    private static let vendorUsagePage = 0xff00
    private static let temperatureUsage = 5
    private static let temperatureEventType: Int64 = 15
    private static let temperatureField = Int32(15 << 16)
    private static let roles: [(prefix: String, role: SensorRole, zone: SensorZone, label: String?)] = [
        ("PMU tdie", .cpu, .cpu, nil), ("gas gauge battery", .battery, .inside, "Battery"), ("NAND CH", .ssd, .storage, "SSD"),
    ]

    private let client: Unmanaged<AnyObject>
    private let servicesArray: CFArray
    private let services: [Service]
    private let copyEvent: CopyEvent
    private let getFloatValue: GetFloatValue

    init?() {
        guard let library = dlopen(Self.frameworkPath, RTLD_NOW),
              let create: ClientCreate = Self.symbol("IOHIDEventSystemClientCreate", in: library),
              let setMatching: SetMatching = Self.symbol("IOHIDEventSystemClientSetMatching", in: library),
              let copyServices: CopyServices = Self.symbol("IOHIDEventSystemClientCopyServices", in: library),
              let copyProperty: CopyProperty = Self.symbol("IOHIDServiceClientCopyProperty", in: library),
              let copyEvent: CopyEvent = Self.symbol("IOHIDServiceClientCopyEvent", in: library),
              let getFloatValue: GetFloatValue = Self.symbol("IOHIDEventGetFloatValue", in: library),
              let clientPointer = create(kCFAllocatorDefault) else { return nil }
        let client = Unmanaged<AnyObject>.fromOpaque(clientPointer)
        let matching = ["PrimaryUsagePage": Self.vendorUsagePage, "PrimaryUsage": Self.temperatureUsage] as CFDictionary
        _ = setMatching(clientPointer, matching)
        guard let arrayPointer = copyServices(clientPointer) else {
            client.release()
            return nil
        }
        let array = Unmanaged<CFArray>.fromOpaque(arrayPointer).takeRetainedValue()
        self.client = client
        servicesArray = array
        services = Self.classify(array, copyProperty: copyProperty)
        self.copyEvent = copyEvent
        self.getFloatValue = getFloatValue
        guard !services.isEmpty else { return nil }
    }

    deinit {
        client.release()
    }

    fileprivate func sample() -> [RoleTemperature] {
        services.compactMap { service in
            guard let celsius = temperature(of: service.handle), SensorCatalog.plausibleCelsius.contains(celsius) else { return nil }
            return RoleTemperature(role: service.role, reading: TemperatureReading(key: service.id, name: service.name, zone: service.zone, celsius: celsius))
        }
    }

    private func temperature(of service: UnsafeRawPointer) -> Double? {
        guard let event = copyEvent(service, Self.temperatureEventType, 0, 0) else { return nil }
        defer { Unmanaged<AnyObject>.fromOpaque(event).release() }
        return getFloatValue(event, Self.temperatureField)
    }

    private static func symbol<T>(_ name: String, in library: UnsafeMutableRawPointer) -> T? {
        dlsym(library, name).map { unsafeBitCast($0, to: T.self) }
    }

    private static func classify(_ array: CFArray, copyProperty: CopyProperty) -> [Service] {
        var seen = Set<String>()
        return (0..<CFArrayGetCount(array)).compactMap { index in
            guard let handle = CFArrayGetValueAtIndex(array, index),
                  let property = copyProperty(handle, "Product" as CFString),
                  let name = Unmanaged<AnyObject>.fromOpaque(property).takeRetainedValue() as? String,
                  let match = roles.first(where: { name.hasPrefix($0.prefix) }),
                  seen.insert(name).inserted else { return nil }
            return Service(handle: handle, role: match.role, zone: match.zone, id: name, name: match.label ?? name)
        }
        .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
}
