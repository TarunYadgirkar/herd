import Darwin
import Foundation

struct ReportedUsage: Sendable {
    let cpuPercent: Double
    let footprint: UInt64
    let energyImpact: Double
    let idleWakeups: Double
    let cpuSeconds: Double
    let threads: Int
}

// Root and other-user processes hide their counters from Herd, but /usr/bin/top holds com.apple.system-task-ports.read.
// One long-lived top is far cheaper than spawning a reader per tick, and its MEM column is phys_footprint like Activity Monitor's.
final class TopStream: @unchecked Sendable {
    struct Row: Equatable {
        let pid: pid_t
        let cpuPercent: Double
        let threads: Int
        let cpuSeconds: Double
        let footprint: UInt64
        let power: Double
        let idleWakeups: UInt64
    }

    private static let scriptURL = URL(fileURLWithPath: "/usr/bin/script")
    private static let topPath = "/usr/bin/top"
    private static let columns = "pid,cpu,th,time,mem,power,idlew"
    private static let columnCount = 7
    private static let restartInterval: TimeInterval = 10
    private static let minimumBackoff: TimeInterval = 1
    private static let staleIntervals = 3.0
    private static let nanosPerSecond = 1_000_000_000.0
    private static let newline = UInt8(ascii: "\n")
    private static let blockHeader = "Processes:"
    private static let tableHeader = "PID"
    private static let hoursSuffix: Substring = "hrs"
    private static let byteUnits: [Character] = ["B", "K", "M", "G", "T", "P"]
    private static let byteUnitBase = 1024.0
    private static let kernelPid: pid_t = 0

    private let lock = NSLock()
    private var interval: TimeInterval
    private var isRunning = false
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stdinPipe: Pipe?
    private var lastLaunch: Date = .distantPast
    private var lineBuffer: [UInt8] = []
    private var isInTable = false
    private var rows: [Row] = []
    private var blocksSeen = 0
    private var lastWakeups: [pid_t: UInt64] = [:]
    private var lastBlockAt: UInt64 = 0
    private var published: [pid_t: ReportedUsage] = [:]
    private var publishedAt: UInt64 = 0

    init(interval: TimeInterval = 2) {
        self.interval = Self.normalized(interval)
    }

    func start() {
        lock.withLock {
            guard !isRunning else { return }
            isRunning = true
            launchLocked()
        }
    }

    func stop() {
        lock.withLock {
            isRunning = false
            tearDownLocked()
        }
    }

    func setInterval(_ seconds: TimeInterval) {
        lock.withLock {
            let next = Self.normalized(seconds)
            guard next != interval else { return }
            interval = next
            guard isRunning else { return }
            tearDownLocked()
            launchLocked()
        }
    }

    // After a pause, the last reading stays on screen until top's next sample arrives instead of flashing empty rows.
    private static let maxStaleSeconds: Double = 300

    func usage() -> [pid_t: ReportedUsage] {
        lock.withLock {
            let age = Double(DispatchTime.now().uptimeNanoseconds &- publishedAt) / Self.nanosPerSecond
            guard publishedAt > 0, age <= Self.maxStaleSeconds || (isRunning && age <= interval * Self.staleIntervals) else { return [:] }
            return published
        }
    }

    private static func normalized(_ seconds: TimeInterval) -> TimeInterval {
        max(1, seconds.rounded())
    }

    private func launchLocked() {
        lastLaunch = Date()
        resetParserLocked()
        let output = Pipe()
        let input = Pipe()
        let child = Process()
        child.executableURL = Self.scriptURL
        child.arguments = arguments()
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self] exited in self?.childExited(exited) }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData, from: handle)
        }

        do {
            try child.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            scheduleRestartLocked()
            return
        }
        process = child
        stdoutPipe = output
        stdinPipe = input
    }

    // script(1) gives top a pty so it line-buffers, and makes that pty top's controlling terminal:
    // Herd can't signal the setuid top directly, but if Herd dies script exits and the hangup takes top down with it.
    // Sorting by descending pid puts kernel_task last, which marks the end of each sample.
    private func arguments() -> [String] {
        ["-q", "/dev/null", Self.topPath, "-l", "0", "-s", String(Int(interval)), "-o", "pid", "-F", "-R", "-stats", Self.columns]
    }

    private func receive(_ data: Data, from handle: FileHandle) {
        guard !data.isEmpty else {
            handle.readabilityHandler = nil
            return
        }
        lock.withLock {
            guard stdoutPipe?.fileHandleForReading === handle else { return }
            consumeLocked(data)
        }
    }

    private func childExited(_ exited: Process) {
        lock.withLock {
            guard process === exited else { return }
            tearDownLocked()
            guard isRunning else { return }
            scheduleRestartLocked()
        }
    }

    private func scheduleRestartLocked() {
        let wait = max(Self.minimumBackoff, Self.restartInterval - Date().timeIntervalSince(lastLaunch))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                guard self.isRunning, self.process == nil else { return }
                self.launchLocked()
            }
        }
    }

    private func tearDownLocked() {
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe?.fileHandleForWriting.close()
        stdoutPipe = nil
        stdinPipe = nil
    }

    private func resetParserLocked() {
        lineBuffer.removeAll(keepingCapacity: true)
        isInTable = false
        rows = []
        blocksSeen = 0
        lastWakeups = [:]
        lastBlockAt = 0
    }

    private func consumeLocked(_ bytes: Data) {
        lineBuffer.append(contentsOf: bytes)
        var lineStart = lineBuffer.startIndex
        while let newlineIndex = lineBuffer[lineStart...].firstIndex(of: Self.newline) {
            handleLineLocked(String(decoding: lineBuffer[lineStart..<newlineIndex], as: UTF8.self))
            lineStart = newlineIndex + 1
        }
        lineBuffer.removeSubrange(..<lineStart)
    }

    private func handleLineLocked(_ rawLine: String) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix(Self.blockHeader) {
            if isInTable { finishBlockLocked() }
            return
        }
        if line.hasPrefix(Self.tableHeader) {
            isInTable = true
            rows.removeAll(keepingCapacity: true)
            return
        }
        guard isInTable, let row = Self.parseRow(line) else { return }
        rows.append(row)
        if row.pid == Self.kernelPid { finishBlockLocked() }
    }

    // top's first sample has no previous sample to diff against, so its %CPU and POWER are meaningless.
    private func finishBlockLocked() {
        let now = DispatchTime.now().uptimeNanoseconds
        let seconds = lastBlockAt > 0 ? Double(now - lastBlockAt) / Self.nanosPerSecond : 0
        defer {
            lastWakeups = Dictionary(rows.map { ($0.pid, $0.idleWakeups) }, uniquingKeysWith: { _, last in last })
            lastBlockAt = now
            rows.removeAll(keepingCapacity: true)
            isInTable = false
        }
        blocksSeen += 1
        guard blocksSeen > 1, seconds > 0 else { return }
        published = Dictionary(rows.map { ($0.pid, usage(of: $0, seconds: seconds)) }, uniquingKeysWith: { _, last in last })
        publishedAt = now
    }

    private func usage(of row: Row, seconds: Double) -> ReportedUsage {
        let previous = lastWakeups[row.pid] ?? row.idleWakeups
        let wakeups = row.idleWakeups >= previous ? row.idleWakeups - previous : 0
        return ReportedUsage(
            cpuPercent: row.cpuPercent,
            footprint: row.footprint,
            energyImpact: row.power,
            idleWakeups: Double(wakeups) / seconds,
            cpuSeconds: row.cpuSeconds,
            threads: row.threads
        )
    }

    static func parseRow(_ line: String) -> Row? {
        var fields = line.split(separator: " ", omittingEmptySubsequences: true)
        if let hours = fields.firstIndex(of: hoursSuffix), hours > 0 {
            fields[hours - 1] = Substring(fields[hours - 1] + ":00:00")
            fields.remove(at: hours)
        }
        guard fields.count == columnCount,
              let pid = pid_t(fields[0]),
              let cpu = Double(fields[1]),
              let threads = leadingInteger(fields[2]),
              let cpuSeconds = parseClock(fields[3]),
              let footprint = parseBytes(withoutTrend(fields[4])),
              let power = Double(fields[5]),
              let wakeups = UInt64(withoutTrend(fields[6]))
        else { return nil }
        return Row(pid: pid, cpuPercent: cpu, threads: threads, cpuSeconds: cpuSeconds, footprint: footprint, power: power, idleWakeups: wakeups)
    }

    // Outside delta mode top appends + or - to counters that moved since the previous sample.
    private static func withoutTrend(_ field: Substring) -> Substring {
        guard let last = field.last, last == "+" || last == "-" else { return field }
        return field.dropLast()
    }

    private static func leadingInteger(_ field: Substring) -> Int? {
        Int(field.prefix(while: \.isNumber))
    }

    private static func parseBytes(_ field: Substring) -> UInt64? {
        guard let unit = field.last, let power = byteUnits.firstIndex(of: unit), let value = Double(field.dropLast()) else { return nil }
        return UInt64(value * pow(byteUnitBase, Double(power)))
    }

    static func parseClock<S: StringProtocol>(_ text: S) -> Double? {
        var seconds = 0.0
        for part in text.split(separator: ":") {
            guard let value = Double(part) else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }
}
