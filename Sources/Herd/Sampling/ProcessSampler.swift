import Darwin
import Foundation

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
        let energyNanojoules: UInt64
        let diskRead: UInt64
        let diskWrite: UInt64
        let time: UInt64
    }

    private struct Reading {
        let counters: Counters?
        let fallbackCPU: Double?
        let memory: UInt64
        let threads: Int
        let isApproximate: Bool
    }

    private let ticksToNanos: Double
    private let fallback = PrivilegedFallback()
    private var staticCache: [ProcessKey: StaticInfo] = [:]
    private var previous: [ProcessKey: Counters] = [:]
    private var ports: [ProcessKey: [UInt16]] = [:]
    private var tick = 0
    private static let portRefreshTicks = 5
    private static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/", "/usr/bin/", "/bin/"]
    private let currentUid = getuid()
    private var argumentBuffer = [UInt8](repeating: 0, count: ProcessIntrospection.argumentBufferSize())

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        ticksToNanos = Double(timebase.numer) / Double(timebase.denom)
    }

    func sample() -> [ProcessSample] {
        let now = DispatchTime.now().uptimeNanoseconds
        let kernelList = KernelProcessList.all()
        var readings: [pid_t: Reading] = [:]
        var denied: [pid_t] = []
        for proc in kernelList {
            if let reading = readDirect(proc.pid, now: now) {
                readings[proc.pid] = reading
            } else {
                denied.append(proc.pid)
            }
        }
        for (pid, usage) in fallback.read(pids: denied) {
            readings[pid] = Reading(
                counters: nil,
                fallbackCPU: usage.cpuPercent,
                memory: usage.residentBytes,
                threads: 0,
                isApproximate: true
            )
        }
        return buildSamples(kernelList, readings: readings)
    }

    private func buildSamples(_ kernelList: [KernelProcess], readings: [pid_t: Reading]) -> [ProcessSample] {
        var nextPrevious: [ProcessKey: Counters] = [:]
        var nextCache: [ProcessKey: StaticInfo] = [:]
        var nextPorts: [ProcessKey: [UInt16]] = [:]
        let refreshPorts = tick % Self.portRefreshTicks == 0
        tick += 1
        var samples: [ProcessSample] = []
        samples.reserveCapacity(kernelList.count)
        for proc in kernelList {
            let key = ProcessKey(pid: proc.pid, start: proc.startTime)
            let info = staticCache[key].flatMap { $0.comm == proc.comm ? $0 : nil } ?? loadStaticInfo(proc)
            nextCache[key] = info
            let reading = readings[proc.pid]
            if let counters = reading?.counters { nextPrevious[key] = counters }
            var sample = makeSample(proc, info: info, reading: reading, last: previous[key])
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

    private func makeSample(_ proc: KernelProcess, info: StaticInfo, reading: Reading?, last: Counters?) -> ProcessSample {
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
            isApproximate: reading?.isApproximate ?? true,
            isSuspended: proc.isStopped,
            workingDirectory: info.workingDirectory
        )
        sample.isUnavailable = reading == nil
        if let fallbackCPU = reading?.fallbackCPU {
            sample.cpuPercent = fallbackCPU
            return sample
        }
        guard let current = reading?.counters, let last, current.time > last.time else { return sample }
        let seconds = Double(current.time - last.time) / 1_000_000_000
        sample.cpuPercent = Double(current.cpuNanos.saturatingSub(last.cpuNanos)) / 1_000_000_000 / seconds * 100
        sample.energyWatts = Double(current.energyNanojoules.saturatingSub(last.energyNanojoules)) / 1_000_000_000 / seconds
        sample.diskReadBps = Double(current.diskRead.saturatingSub(last.diskRead)) / seconds
        sample.diskWriteBps = Double(current.diskWrite.saturatingSub(last.diskWrite)) / seconds
        return sample
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
        let counters = Counters(
            cpuNanos: UInt64(Double(ticks) * ticksToNanos),
            energyNanojoules: usage.ri_energy_nj,
            diskRead: usage.ri_diskio_bytesread,
            diskWrite: usage.ri_diskio_byteswritten,
            time: now
        )
        return Reading(counters: counters, fallbackCPU: nil, memory: usage.ri_phys_footprint, threads: threadCount(pid), isApproximate: false)
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
