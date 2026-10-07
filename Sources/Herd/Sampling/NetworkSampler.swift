import Darwin
import Foundation

final class NetworkSampler: @unchecked Sendable {
    typealias Rate = (inBps: Double, outBps: Double)

    private static let scriptURL = URL(fileURLWithPath: "/usr/bin/script")
    private static let nettopPath = "/usr/bin/nettop"
    private static let restartInterval: TimeInterval = 10
    private static let minimumBackoff: TimeInterval = 1
    private static let staleIntervals = 3.0
    private static let newline = UInt8(ascii: "\n")

    private let interval: TimeInterval
    private let lock = NSLock()

    private var isRunning = false
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stdinPipe: Pipe?
    private var lastLaunch: Date = .distantPast
    private var lineBuffer: [UInt8] = []
    private var currentBlock: [pid_t: Rate] = [:]
    private var hasHeader = false
    private var blocksSeen = 0
    private var published: [pid_t: Rate] = [:]
    private var publishedAt: Date = .distantPast

    init(interval: TimeInterval = 2) {
        self.interval = max(1, interval.rounded())
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

    func rates() -> [pid_t: Rate] {
        lock.withLock {
            guard Date().timeIntervalSince(publishedAt) <= interval * Self.staleIntervals else { return [:] }
            return published
        }
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

    // nettop block-buffers into pipes and spins at >100% CPU on stdin EOF, so script(1) gives it a pty.
    // script also makes that pty nettop's controlling terminal: if Herd dies, script takes SIGPIPE and nettop SIGHUP.
    private func arguments() -> [String] {
        ["-q", "/dev/null", Self.nettopPath, "-P", "-x", "-d", "-n", "-s", String(Int(interval)), "-L", "0", "-J", "bytes_in,bytes_out"]
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
        currentBlock = [:]
        hasHeader = false
        blocksSeen = 0
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
        if line.hasPrefix(",") {
            finishBlockLocked()
            return
        }
        guard hasHeader, let (pid, bytesIn, bytesOut) = Self.parseRow(line) else { return }
        let existing = currentBlock[pid] ?? (0, 0)
        currentBlock[pid] = (existing.inBps + bytesIn, existing.outBps + bytesOut)
    }

    // nettop's first delta-mode block holds cumulative totals, not deltas, so it is discarded.
    private func finishBlockLocked() {
        defer {
            currentBlock = [:]
            hasHeader = true
        }
        guard hasHeader else { return }
        blocksSeen += 1
        guard blocksSeen > 1 else { return }
        published = currentBlock.mapValues { ($0.inBps / interval, $0.outBps / interval) }
        publishedAt = Date()
    }

    private static func parseRow(_ line: String) -> (pid_t, Double, Double)? {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 4, fields[fields.count - 1].isEmpty else { return nil }
        let name = fields[0..<(fields.count - 3)].joined(separator: ",")
        guard let dot = name.lastIndex(of: "."),
              let pid = pid_t(name[name.index(after: dot)...]),
              let bytesIn = Double(fields[fields.count - 3]),
              let bytesOut = Double(fields[fields.count - 2])
        else { return nil }
        return (pid, bytesIn, bytesOut)
    }
}
