import Darwin
import Foundation

enum ProcessTools {
    enum SampleResult: Sendable {
        case report(URL)
        case failed(String)
    }

    private static let sampleTool = "/usr/bin/sample"
    private static let sampleSeconds = 3
    private static let lowerNice: Int32 = 10

    static func sample(pid: pid_t, name: String) async -> SampleResult {
        let report = reportURL(pid: pid, name: name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sampleTool)
        process.arguments = [String(pid), String(sampleSeconds), "-file", report.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = Pipe()
        let (status, errorText) = await run(process)
        if status == 0 && FileManager.default.fileExists(atPath: report.path) { return .report(report) }
        return .failed(sampleFailure(name: name, output: errorText))
    }

    private static func run(_ process: Process) async -> (Int32, String) {
        await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                let data = (finished.standardError as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
                continuation.resume(returning: (finished.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: (-1, error.localizedDescription))
            }
        }
    }

    private static func reportURL(pid: pid_t, name: String) -> URL {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let safeName = name.replacingOccurrences(of: "/", with: "-")
        return FileManager.default.temporaryDirectory.appendingPathComponent("Sample of \(safeName) (\(pid)) \(stamp).txt")
    }

    private static func sampleFailure(name: String, output: String) -> String {
        if output.contains("privileges") || output.contains("not permitted") {
            return "macOS doesn't let Herd sample \(name). Apps with the hardened runtime and processes owned by the system can only be sampled with sudo in Terminal."
        }
        if output.contains("does not exist") || output.contains("No such process") {
            return "\(name) exited before Herd could sample it."
        }
        return "Herd couldn't sample \(name). Apps with the hardened runtime block sampling unless you run sample with sudo in Terminal."
    }

    // PRIO_DARWIN_BG puts the whole task in the background band: efficiency cores on Apple silicon and throttled disk I/O.
    // Unlike nice, an unprivileged user can take it back off again.
    static func setEfficiencyMode(_ isOn: Bool, pid: pid_t, name: String) -> String {
        if setpriority(PRIO_DARWIN_PROCESS, id_t(pid), isOn ? PRIO_DARWIN_BG : 0) == 0 {
            return isOn
                ? "Herd moved \(name) to the efficiency cores. It keeps running, just slower and cooler."
                : "\(name) is back to normal priority."
        }
        let failure = errno
        if failure == ESRCH { return "\(name) has already exited." }
        if failure == EPERM { return "macOS doesn't let Herd change the priority of \(name), because it belongs to another user or the system." }
        guard isOn, setpriority(PRIO_PROCESS, id_t(pid), lowerNice) == 0 else {
            return "Herd couldn't change the priority of \(name)."
        }
        return "Herd lowered the priority of \(name). macOS only lets an administrator raise it again, so it stays lower until \(name) restarts."
    }
}
