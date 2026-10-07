import Darwin
import Foundation
import IOKit
import IOKit.ps

final class SystemSampler {
    private static let batteryRefreshInterval: Duration = .seconds(30)
    private static let percentScale = 100.0
    private static let attosecondsPerSecond = 1e18

    private let clock = ContinuousClock()
    private let host = mach_host_self()
    private let pageSize: UInt64
    private let memoryTotal: UInt64 = Sysctl.read("hw.memsize", as: UInt64(0)) ?? 0

    private var lastInstant: ContinuousClock.Instant?
    private var lastCPUTicks: CPUTicks?
    private var lastCoreTicks: [CPUTicks] = []
    private var lastInterfaceBytes: [String: InterfaceBytes] = [:]
    private var lastDiskBytes: DiskBytes?
    private var cachedBattery: BatteryInfo?
    private var lastBatteryRefresh: ContinuousClock.Instant?

    init() {
        var size: vm_size_t = 0
        host_page_size(host, &size)
        pageSize = UInt64(size)
    }

    deinit {
        mach_port_deallocate(mach_task_self_, host)
    }

    func sample() -> SystemSnapshot {
        let now = clock.now
        let elapsed = lastInstant.map { Self.seconds(now - $0) } ?? 0
        lastInstant = now

        var snapshot = SystemSnapshot()
        fillCPU(&snapshot)
        fillCores(&snapshot)
        fillMemory(&snapshot)
        fillNetwork(&snapshot, elapsed: elapsed)
        fillDisk(&snapshot, elapsed: elapsed)
        snapshot.loadAverage = Self.loadAverage()
        snapshot.gpuUtilization = Self.gpuUtilization()
        snapshot.thermal = ProcessInfo.processInfo.thermalState
        snapshot.battery = battery(at: now)
        snapshot.uptime = ProcessInfo.processInfo.systemUptime
        return snapshot
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / attosecondsPerSecond
    }

    private static func rate(_ delta: UInt64, over elapsed: Double) -> Double {
        guard elapsed > 0 else { return 0 }
        return Double(delta) / elapsed
    }
}

// MARK: - CPU

private struct CPUTicks {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32

    func busy(since old: CPUTicks) -> (user: Double, system: Double) {
        let user = Double(self.user &- old.user) + Double(nice &- old.nice)
        let system = Double(self.system &- old.system)
        let total = user + system + Double(idle &- old.idle)
        guard total > 0 else { return (0, 0) }
        return (user / total, system / total)
    }
}

extension SystemSampler {
    private func fillCPU(_ snapshot: inout SystemSnapshot) {
        guard let ticks = hostCPUTicks() else { return }
        defer { lastCPUTicks = ticks }
        guard let old = lastCPUTicks else { return }
        let busy = ticks.busy(since: old)
        snapshot.cpuUser = busy.user
        snapshot.cpuSystem = busy.system
    }

    private func fillCores(_ snapshot: inout SystemSnapshot) {
        let cores = coreTicks()
        defer { lastCoreTicks = cores }
        guard lastCoreTicks.count == cores.count else {
            snapshot.perCoreUsage = Array(repeating: 0, count: cores.count)
            return
        }
        snapshot.perCoreUsage = zip(cores, lastCoreTicks).map { new, old in
            let busy = new.busy(since: old)
            return min(1, busy.user + busy.system)
        }
    }

    private func hostCPUTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = Self.integerCount(of: host_cpu_load_info_data_t.self)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        return CPUTicks(user: t.0, system: t.1, idle: t.2, nice: t.3)
    }

    private func coreTicks() -> [CPUTicks] {
        var processorCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &processorCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return [] }
        defer {
            let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }
        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(processorCount)).map { core in
            let base = core * stride
            func tick(_ state: Int32) -> UInt32 { UInt32(bitPattern: info[base + Int(state)]) }
            return CPUTicks(
                user: tick(CPU_STATE_USER),
                system: tick(CPU_STATE_SYSTEM),
                idle: tick(CPU_STATE_IDLE),
                nice: tick(CPU_STATE_NICE)
            )
        }
    }

    private static func loadAverage() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, Int32(loads.count)) == loads.count else { return [0, 0, 0] }
        return loads
    }

    private static func integerCount<T>(of type: T.Type) -> mach_msg_type_number_t {
        mach_msg_type_number_t(MemoryLayout<T>.size / MemoryLayout<integer_t>.size)
    }
}

// MARK: - Memory

extension SystemSampler {
    private func fillMemory(_ snapshot: inout SystemSnapshot) {
        snapshot.memoryTotal = memoryTotal
        snapshot.pressure = Self.memoryPressure()
        if let swap = Sysctl.read("vm.swapusage", as: xsw_usage()) {
            snapshot.swapUsed = swap.xsu_used
            snapshot.swapTotal = swap.xsu_total
        }
        guard let vm = vmStatistics() else { return }
        let internalPages = UInt64(vm.internal_page_count)
        let purgeablePages = UInt64(vm.purgeable_count)
        snapshot.appMemory = (internalPages > purgeablePages ? internalPages - purgeablePages : 0) * pageSize
        snapshot.wiredMemory = UInt64(vm.wire_count) * pageSize
        snapshot.compressedMemory = UInt64(vm.compressor_page_count) * pageSize
        snapshot.cachedFiles = (UInt64(vm.external_page_count) + purgeablePages) * pageSize
        snapshot.memoryUsed = snapshot.appMemory + snapshot.wiredMemory + snapshot.compressedMemory
    }

    private func vmStatistics() -> vm_statistics64? {
        var stats = vm_statistics64()
        var count = Self.integerCount(of: vm_statistics64.self)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        return result == KERN_SUCCESS ? stats : nil
    }

    private static func memoryPressure() -> MemoryPressure {
        guard let level = Sysctl.read("kern.memorystatus_vm_pressure_level", as: Int32(0)) else { return .normal }
        return MemoryPressure(rawValue: Int(level)) ?? .normal
    }
}

// MARK: - Network

private struct InterfaceBytes {
    let input: UInt32
    let output: UInt32
}

extension SystemSampler {
    private func fillNetwork(_ snapshot: inout SystemSnapshot, elapsed: Double) {
        let current = Self.interfaceBytes()
        defer { lastInterfaceBytes = current }
        var input: UInt64 = 0
        var output: UInt64 = 0
        for (name, bytes) in current {
            guard let old = lastInterfaceBytes[name] else { continue }
            input += UInt64(bytes.input &- old.input)
            output += UInt64(bytes.output &- old.output)
        }
        snapshot.netInBps = Self.rate(input, over: elapsed)
        snapshot.netOutBps = Self.rate(output, over: elapsed)
    }

    private static func interfaceBytes() -> [String: InterfaceBytes] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }
        var result: [String: InterfaceBytes] = [:]
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_LINK) else { continue }
            guard entry.ifa_flags & UInt32(IFF_UP) != 0, let data = entry.ifa_data else { continue }
            let name = String(cString: entry.ifa_name)
            guard !name.hasPrefix("lo") else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            result[name] = InterfaceBytes(input: stats.ifi_ibytes, output: stats.ifi_obytes)
        }
        return result
    }
}

// MARK: - Disk and GPU

private struct DiskBytes {
    var read: UInt64 = 0
    var written: UInt64 = 0
}

extension SystemSampler {
    private func fillDisk(_ snapshot: inout SystemSnapshot, elapsed: Double) {
        let current = Self.diskBytes()
        defer { lastDiskBytes = current }
        guard let old = lastDiskBytes else { return }
        let read = current.read > old.read ? current.read - old.read : 0
        let written = current.written > old.written ? current.written - old.written : 0
        snapshot.diskReadBps = Self.rate(read, over: elapsed)
        snapshot.diskWriteBps = Self.rate(written, over: elapsed)
    }

    private static func diskBytes() -> DiskBytes {
        var total = DiskBytes()
        forEachService(matching: "IOBlockStorageDriver") { service in
            guard let stats = dictionaryProperty(service, "Statistics") else { return }
            total.read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            total.written += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return total
    }

    private static func gpuUtilization() -> Double? {
        var utilization: Double?
        forEachService(matching: "IOAccelerator") { service in
            guard let stats = dictionaryProperty(service, "PerformanceStatistics"),
                  let percent = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { return }
            utilization = max(utilization ?? 0, min(1, percent / percentScale))
        }
        return utilization
    }

    private static func forEachService(matching className: String, _ body: (io_object_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            body(service)
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    private static func dictionaryProperty(_ entry: io_registry_entry_t, _ key: String) -> [String: Any]? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
    }
}

// MARK: - Battery

extension SystemSampler {
    private func battery(at now: ContinuousClock.Instant) -> BatteryInfo? {
        if let last = lastBatteryRefresh, now - last < Self.batteryRefreshInterval {
            return cachedBattery
        }
        lastBatteryRefresh = now
        cachedBattery = Self.readBattery()
        return cachedBattery
    }

    private static func readBattery() -> BatteryInfo? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            return batteryInfo(from: description)
        }
        return nil
    }

    private static func batteryInfo(from description: [String: Any]) -> BatteryInfo? {
        guard let current = description[kIOPSCurrentCapacityKey] as? Int,
              let capacity = description[kIOPSMaxCapacityKey] as? Int, capacity > 0 else { return nil }
        let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
        let isOnAC = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        return BatteryInfo(
            percent: Double(current) / Double(capacity) * percentScale,
            isCharging: isCharging,
            isOnAC: isOnAC,
            minutesRemaining: minutesRemaining(description, isCharging: isCharging, isOnAC: isOnAC)
        )
    }

    private static func minutesRemaining(_ description: [String: Any], isCharging: Bool, isOnAC: Bool) -> Int? {
        if isOnAC && !isCharging { return nil }
        let key = isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
        guard let minutes = description[key] as? Int, minutes >= 0 else { return nil }
        return minutes
    }
}

// MARK: - sysctl

private enum Sysctl {
    static func read<T: BitwiseCopyable>(_ name: String, as initial: T) -> T? {
        var value = initial
        var size = MemoryLayout<T>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
