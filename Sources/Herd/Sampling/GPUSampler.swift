import Darwin
import Foundation
import IOKit

final class GPUSampler {
    private static let acceleratorClass = "IOAccelerator"
    private static let creatorKey = "IOUserClientCreator"
    private static let usageKey = "AppUsage"
    private static let gpuTimeKey = "accumulatedGPUTime"
    private static let pidPrefix = "pid "
    private static let fullScale = 100.0

    private var previousTotals: [pid_t: UInt64] = [:]
    private var previousTime: UInt64?

    init() {}

    func sample() -> [pid_t: Double] {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let totals = Self.readTotals()
        defer {
            previousTotals = totals
            previousTime = now
        }
        guard let previousTime, now > previousTime else { return [:] }
        return rates(totals: totals, elapsed: Double(now - previousTime))
    }

    private func rates(totals: [pid_t: UInt64], elapsed: Double) -> [pid_t: Double] {
        var result: [pid_t: Double] = [:]
        result.reserveCapacity(totals.count)
        for (pid, total) in totals {
            let previous = previousTotals[pid] ?? 0
            let delta = total > previous ? Double(total - previous) : 0
            result[pid] = delta / elapsed * Self.fullScale
        }
        return result
    }

    private static func readTotals() -> [pid_t: UInt64] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(acceleratorClass), &iterator) == KERN_SUCCESS else {
            return [:]
        }
        defer { IOObjectRelease(iterator) }

        var totals: [pid_t: UInt64] = [:]
        forEach(in: iterator) { accelerator in
            accumulateClients(of: accelerator, into: &totals)
        }
        return totals
    }

    private static func accumulateClients(of accelerator: io_object_t, into totals: inout [pid_t: UInt64]) {
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &children) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(children) }

        forEach(in: children) { client in
            guard let pid = creatorPid(of: client) else { return }
            totals[pid, default: 0] += gpuTime(of: client)
        }
    }

    private static func forEach(in iterator: io_iterator_t, _ body: (io_object_t) -> Void) {
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            body(entry)
            IOObjectRelease(entry)
        }
    }

    private static func property(_ key: String, of entry: io_object_t) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func creatorPid(of client: io_object_t) -> pid_t? {
        guard let creator = property(creatorKey, of: client) as? String, creator.hasPrefix(pidPrefix) else { return nil }
        let digits = creator.dropFirst(pidPrefix.count).prefix { $0.isNumber }
        return pid_t(digits)
    }

    private static func gpuTime(of client: io_object_t) -> UInt64 {
        guard let usage = property(usageKey, of: client) as? [[String: Any]] else { return 0 }
        return usage.reduce(0) { sum, entry in
            sum + ((entry[gpuTimeKey] as? NSNumber)?.uint64Value ?? 0)
        }
    }
}
