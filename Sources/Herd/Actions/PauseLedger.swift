import Darwin
import Foundation

// Herd owns every process it pauses: a stopped process can't resume itself, so Herd resumes them when it quits,
// and on the next launch if it crashed while they were stopped. Start times guard against reused pids.
enum PauseLedger {
    private static let key = "pausedByHerd"
    private static let startTolerance: TimeInterval = 1

    static func record(_ sample: ProcessSample) {
        guard let start = sample.startTime else { return }
        var entries = stored
        entries[String(sample.pid)] = start.timeIntervalSince1970
        save(entries)
    }

    static func forget(_ sample: ProcessSample) {
        var entries = stored
        guard entries.removeValue(forKey: String(sample.pid)) != nil else { return }
        save(entries)
    }

    static var pausedCount: Int { stored.count }

    @discardableResult
    static func resumeAll() -> Int {
        let entries = stored
        save([:])
        return entries.reduce(0) { count, entry in
            guard let pid = pid_t(entry.key), isSameStoppedProcess(pid, startedAt: entry.value) else { return count }
            return kill(pid, SIGCONT) == 0 ? count + 1 : count
        }
    }

    private static func isSameStoppedProcess(_ pid: pid_t, startedAt start: TimeInterval) -> Bool {
        guard let process = KernelProcessList.process(pid) else { return false }
        return process.isStopped && abs(process.startTime.timeIntervalSince1970 - start) < startTolerance
    }

    private static var stored: [String: Double] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
    }

    private static func save(_ entries: [String: Double]) {
        UserDefaults.standard.set(entries, forKey: key)
    }
}
