import Darwin
import Foundation
import HerdHelperKit

// Per-process values other samplers measure, merged into each sample as it is built so the list isn't copied again.
struct ProcessExtras {
    var gpu: [pid_t: Double] = [:]
    var network: [pid_t: NetworkSampler.Rate] = [:]
    var sleepAssertions: [pid_t: [String]] = [:]
}

final class ProcessSampler {
    private struct ProcessKey: Hashable {
        let pid: pid_t
        let start: Date
    }

    private struct StaticInfo {
        let id: String
        let path: String
        let name: String
        let arguments: [String]
        let responsiblePid: pid_t
        let comm: String
        let workingDirectory: String?
        let tracksPorts: Bool
    }

    private struct Counters {
        let cpuNanos: UInt64
        var childCpuNanos: UInt64 = 0
        let energyNanojoules: UInt64
        let idleWakeups: UInt64
        let diskRead: UInt64
        let diskWrite: UInt64
        let time: UInt64

        static func zero(at time: UInt64) -> Counters {
            Counters(cpuNanos: 0, energyNanojoules: 0, idleWakeups: 0, diskRead: 0, diskWrite: 0, time: time)
        }
    }

    private struct Seen {
        let counters: Counters
        let ppid: pid_t
    }

    private struct Tick {
        let uptime: UInt64
        let date: Date
    }

    private struct Reading {
        let counters: Counters?
        let reported: ReportedUsage?
        let memory: UInt64
        let threads: Int
    }

    private let ticksToNanos: Double
    // top walks every thread on the Mac, so it samples slowly and only while someone is looking at per-app numbers.
    private static let topInterval: TimeInterval = 10
    private let top = TopStream(interval: topInterval)
    private let helper = RootHelper.shared
    private var isDetailVisible = false
    private var staticCache: [ProcessKey: StaticInfo] = [:]
    private var previous: [ProcessKey: Seen] = [:]
    private var lastTick: Tick?
    private var kinfoBuffer: [kinfo_proc] = []
    private var ports: [ProcessKey: [UInt16]] = [:]
    private var tick = 0
    private static let portRefreshTicks = 5
    private static let nanosPerSecond = 1_000_000_000.0
    private static let kernelPid: pid_t = 0
    private static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/", "/usr/bin/", "/bin/"]
    private let currentUid = getuid()
    private var argumentBuffer = [UInt8](repeating: 0, count: ProcessIntrospection.argumentBufferSize())

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        ticksToNanos = Double(timebase.numer) / Double(timebase.denom)
    }

    deinit {
        pendingTopStop?.cancel()
        top.stop()
    }

    // Restarting top costs about a second of CPU and blanks root processes until its second sample,
    // so a quick Space switch or window cover keeps it running instead of churning.
    private static let topIdleGrace: Duration = .seconds(120)
    private var pendingTopStop: Task<Void, Never>?

    func setDetailVisible(_ isVisible: Bool) {
        isDetailVisible = isVisible
        pendingTopStop?.cancel()
        pendingTopStop = nil
        if isVisible {
            if helper.state != .on { top.start() }
            return
        }
        pendingTopStop = Self.stopAfterGrace(top)
    }

    private static func stopAfterGrace(_ top: TopStream) -> Task<Void, Never> {
        Task.detached {
            try? await Task.sleep(for: topIdleGrace)
            guard !Task.isCancelled else { return }
            top.stop()
        }
    }

    func sample(extras: ProcessExtras = ProcessExtras()) -> [ProcessSample] {
        let now = Tick(uptime: DispatchTime.now().uptimeNanoseconds, date: Date())
        let kernelList = KernelProcessList.all(reusing: &kinfoBuffer)
        var readings = [Reading?](repeating: nil, count: kernelList.count)
        var unreadable: [Int] = []
        for (index, proc) in kernelList.enumerated() {
            let direct = proc.pid == Self.kernelPid ? nil : readDirect(proc.pid, now: now.uptime)
            if let direct { readings[index] = direct } else { unreadable.append(index) }
        }
        fillUnreadable(unreadable, of: kernelList, into: &readings, now: now.uptime)
        let samples = buildSamples(kernelList, readings: readings, extras: extras)
        lastTick = now
        return samples
    }

    // The root helper gives the same exact counters Herd reads for its own processes; top only stands in when the helper can't answer.
    private func fillUnreadable(_ indices: [Int], of kernelList: [KernelProcess], into readings: inout [Reading?], now: UInt64) {
        guard !indices.isEmpty else { return }
        if let helped = helper.usage(for: indices.map { kernelList[$0].pid }) {
            if top.isActive { top.stop() }
            for index in indices { readings[index] = helped[kernelList[index].pid].map { reading($0, now: now) } }
            return
        }
        if isDetailVisible { top.start() }
        let reported = top.usage()
        for index in indices { readings[index] = reported[kernelList[index].pid].map(Self.reading) }
    }

    private static func reading(_ usage: ReportedUsage) -> Reading {
        Reading(counters: nil, reported: usage, memory: usage.footprint, threads: usage.threads)
    }

    private func reading(_ usage: RawUsage, now: UInt64) -> Reading {
        let counters = Counters(
            cpuNanos: UInt64(Double(usage.cpuTicks) * ticksToNanos),
            energyNanojoules: usage.energyNanojoules,
            idleWakeups: usage.idleWakeups,
            diskRead: usage.diskRead,
            diskWrite: usage.diskWrite,
            time: now
        )
        return Reading(counters: counters, reported: nil, memory: usage.footprint, threads: Int(usage.threads))
    }

    private func buildSamples(_ kernelList: [KernelProcess], readings: [Reading?], extras: ProcessExtras) -> [ProcessSample] {
        let keys = kernelList.map { ProcessKey(pid: $0.pid, start: $0.startTime) }
        let reaped = reapedChildCpu(current: Set(keys))
        var nextPrevious: [ProcessKey: Seen] = [:]
        var nextCache: [ProcessKey: StaticInfo] = [:]
        var nextPorts: [ProcessKey: [UInt16]] = [:]
        nextPrevious.reserveCapacity(kernelList.count)
        nextCache.reserveCapacity(kernelList.count)
        let refreshPorts = tick % Self.portRefreshTicks == 0
        tick += 1
        var samples: [ProcessSample] = []
        samples.reserveCapacity(kernelList.count)
        for (index, proc) in kernelList.enumerated() {
            let key = keys[index]
            let info = staticCache[key].flatMap { $0.comm == proc.comm ? $0 : nil } ?? loadStaticInfo(proc)
            nextCache[key] = info
            let reading = readings[index]
            if let counters = reading?.counters { nextPrevious[key] = Seen(counters: counters, ppid: proc.ppid) }
            let last = previous[key]?.counters ?? newcomerBaseline(proc)
            var sample = makeSample(proc, info: info, reading: reading, last: last, reapedCpu: reaped[proc.pid] ?? 0)
            Self.apply(extras, to: &sample)
            if info.tracksPorts {
                let known = refreshPorts ? nil : ports[key]
                nextPorts[key] = known ?? ProcessResources.listeningPorts(proc.pid)
                sample.listeningPorts = nextPorts[key] ?? []
            }
            samples.append(sample)
        }
        previous = nextPrevious
        staticCache = nextCache
        ports = nextPorts
        return samples
    }

    // A process that started after the previous tick has run only inside this interval, so all of its counters belong
    // to it. Without this baseline every process read 0% on its first tick and short-lived ones were never counted.
    private func newcomerBaseline(_ proc: KernelProcess) -> Counters? {
        guard let lastTick, proc.startTime >= lastTick.date else { return nil }
        return .zero(at: lastTick.uptime)
    }

    // A parent's child CPU grows when it reaps a child. Children Herd already saw have had their CPU counted up to the
    // last tick, so only the rest (children that lived and died between ticks) is added to the parent.
    private func reapedChildCpu(current: Set<ProcessKey>) -> [pid_t: UInt64] {
        var seenByParent: [pid_t: UInt64] = [:]
        for (key, seen) in previous where !current.contains(key) {
            seenByParent[seen.ppid, default: 0] += seen.counters.cpuNanos &+ seen.counters.childCpuNanos
        }
        return seenByParent
    }

    private static func apply(_ extras: ProcessExtras, to sample: inout ProcessSample) {
        sample.gpuPercent = extras.gpu[sample.pid] ?? 0
        sample.sleepAssertions = extras.sleepAssertions[sample.pid] ?? []
        guard let rate = extras.network[sample.pid] else { return }
        sample.netInBps = rate.inBps
        sample.netOutBps = rate.outBps
    }

    private func makeSample(_ proc: KernelProcess, info: StaticInfo, reading: Reading?, last: Counters?, reapedCpu: UInt64) -> ProcessSample {
        var sample = ProcessSample(
            id: info.id,
            pid: proc.pid,
            ppid: proc.ppid,
            responsiblePid: info.responsiblePid,
            uid: proc.uid,
            name: info.name,
            path: info.path,
            arguments: info.arguments,
            startTime: proc.startTime,
            cpuPercent: 0,
            memoryBytes: reading?.memory ?? 0,
            energyWatts: 0,
            diskReadBps: 0,
            diskWriteBps: 0,
            netInBps: 0,
            netOutBps: 0,
            gpuPercent: 0,
            threads: reading?.threads ?? 0,
            isApproximate: reading == nil,
            isSuspended: proc.isStopped,
            workingDirectory: info.workingDirectory
        )
        sample.isUnavailable = reading == nil
        if let reported = reading?.reported {
            Self.apply(reported, to: &sample)
            return sample
        }
        guard let current = reading?.counters else { return sample }
        sample.cpuSeconds = Double(current.cpuNanos) / Self.nanosPerSecond
        guard let last, current.time > last.time else { return sample }
        Self.applyRates(from: last, to: current, reapedCpu: reapedCpu, on: &sample)
        return sample
    }

    private static func apply(_ reported: ReportedUsage, to sample: inout ProcessSample) {
        sample.hasDetailedCounters = false
        sample.cpuPercent = reported.cpuPercent
        sample.energyImpact = reported.energyImpact
        sample.idleWakeups = reported.idleWakeups
        sample.cpuSeconds = reported.cpuSeconds
    }

    private static func applyRates(from last: Counters, to current: Counters, reapedCpu: UInt64, on sample: inout ProcessSample) {
        let seconds = Double(current.time - last.time) / nanosPerSecond
        let unseenChildren = current.childCpuNanos.saturatingSub(last.childCpuNanos).saturatingSub(reapedCpu)
        let cpuNanos = current.cpuNanos.saturatingSub(last.cpuNanos) &+ unseenChildren
        let wakeups = current.idleWakeups.saturatingSub(last.idleWakeups)
        sample.cpuPercent = Double(cpuNanos) / nanosPerSecond / seconds * 100
        sample.energyWatts = Double(current.energyNanojoules.saturatingSub(last.energyNanojoules)) / nanosPerSecond / seconds
        sample.energyImpact = EnergyImpact.score(cpuNanos: cpuNanos, idleWakeups: wakeups, seconds: seconds)
        sample.idleWakeups = Double(wakeups) / seconds
        sample.diskReadBps = Double(current.diskRead.saturatingSub(last.diskRead)) / seconds
        sample.diskWriteBps = Double(current.diskWrite.saturatingSub(last.diskWrite)) / seconds
    }

    private func readDirect(_ pid: pid_t, now: UInt64) -> Reading? {
        var usage = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        guard status == 0 else { return nil }
        let ticks = usage.ri_user_time &+ usage.ri_system_time
        let childTicks = usage.ri_child_user_time &+ usage.ri_child_system_time
        let counters = Counters(
            cpuNanos: UInt64(Double(ticks) * ticksToNanos),
            childCpuNanos: UInt64(Double(childTicks) * ticksToNanos),
            energyNanojoules: usage.ri_energy_nj,
            idleWakeups: usage.ri_pkg_idle_wkups,
            diskRead: usage.ri_diskio_bytesread,
            diskWrite: usage.ri_diskio_byteswritten,
            time: now
        )
        return Reading(counters: counters, reported: nil, memory: usage.ri_phys_footprint, threads: threadCount(pid))
    }

    private func threadCount(_ pid: pid_t) -> Int {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return 0 }
        return Int(info.pti_threadnum)
    }

    private func loadStaticInfo(_ proc: KernelProcess) -> StaticInfo {
        let path = ProcessIntrospection.executablePath(proc.pid)
        let arguments = ProcessIntrospection.arguments(proc.pid, buffer: &argumentBuffer)
        let name = path.isEmpty ? (proc.pid == 0 ? "kernel_task" : proc.comm) : (path as NSString).lastPathComponent
        let isRuntime = Runtime.detect(executableName: name) != nil
        let isUserTool = proc.uid == currentUid && !path.isEmpty && !path.contains(".app/") && !Self.systemPrefixes.contains { path.hasPrefix($0) }
        return StaticInfo(
            id: "\(proc.pid)@\(Int64(proc.startTime.timeIntervalSince1970 * 1_000_000))",
            path: path,
            name: name,
            arguments: arguments,
            responsiblePid: ProcessIntrospection.responsiblePid(proc.pid),
            comm: proc.comm,
            workingDirectory: isRuntime ? ProcessResources.workingDirectory(proc.pid) : nil,
            tracksPorts: isRuntime || isUserTool
        )
    }
}

private extension UInt64 {
    func saturatingSub(_ other: UInt64) -> UInt64 { self > other ? self - other : 0 }
}
