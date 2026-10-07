import Darwin
import Foundation

// Root-owned daemons hide their counters from unprivileged callers, but /bin/ps is setuid root and can read them.
// Spawning ps costs more than every other probe combined, so it only runs every few ticks and its rates are reused in between.
final class PrivilegedFallback {
    struct Usage {
        let cpuPercent: Double
        let residentBytes: UInt64
    }

    private struct Raw {
        let cpuNanos: UInt64
        let residentBytes: UInt64
    }

    private static let psPath = "/bin/ps"
    private static let kilobyte: UInt64 = 1024
    private static let refreshEveryTicks = 3

    private var tick = 0
    private var reads = 0
    private static let readsBeforeRatesExist = 2
    private var lastRaw: [pid_t: Raw] = [:]
    private var lastReadTime: UInt64 = 0
    private var cached: [pid_t: Usage] = [:]

    func read(pids: [pid_t]) -> [pid_t: Usage] {
        defer { tick += 1 }
        let targets = pids.filter { $0 > 0 }
        let isWarmingUp = reads < Self.readsBeforeRatesExist
        let isDue = isWarmingUp || tick % Self.refreshEveryTicks == 0 || targets.contains { cached[$0] == nil }
        if isDue, !targets.isEmpty, let output = runPs(targets) {
            refresh(with: parse(output))
        }
        return cached.filter { targets.contains($0.key) }
    }

    private func refresh(with raw: [pid_t: Raw]) {
        let now = DispatchTime.now().uptimeNanoseconds
        let seconds = lastReadTime > 0 ? Double(now - lastReadTime) / 1_000_000_000 : 0
        var next: [pid_t: Usage] = [:]
        for (pid, current) in raw {
            var percent = 0.0
            if seconds > 0, let previous = lastRaw[pid], current.cpuNanos >= previous.cpuNanos {
                percent = Double(current.cpuNanos - previous.cpuNanos) / 1_000_000_000 / seconds * 100
            }
            next[pid] = Usage(cpuPercent: percent, residentBytes: current.residentBytes)
        }
        cached = next
        lastRaw = raw
        lastReadTime = now
        reads += 1
    }

    private func parse(_ output: String) -> [pid_t: Raw] {
        var result: [pid_t: Raw] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3,
                  let pid = pid_t(fields[0]),
                  let rss = UInt64(fields[1]),
                  let cpu = Self.parseCPUTime(fields[2]) else { continue }
            result[pid] = Raw(cpuNanos: cpu, residentBytes: rss * Self.kilobyte)
        }
        return result
    }

    private func runPs(_ pids: [pid_t]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.psPath)
        process.arguments = ["-o", "pid=,rss=,cputime=", "-p", pids.map(String.init).joined(separator: ",")]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static func parseCPUTime<S: StringProtocol>(_ text: S) -> UInt64? {
        var days = 0.0
        var clock = Substring(text)
        if let dash = clock.firstIndex(of: "-") {
            guard let parsedDays = Double(clock[..<dash]) else { return nil }
            days = parsedDays
            clock = clock[clock.index(after: dash)...]
        }
        var seconds = 0.0
        for part in clock.split(separator: ":") {
            guard let value = Double(part) else { return nil }
            seconds = seconds * 60 + value
        }
        return UInt64((seconds + days * 86_400) * 1_000_000_000)
    }
}
