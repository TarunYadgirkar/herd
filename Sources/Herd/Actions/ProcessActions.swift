import AppKit
import Darwin

enum ProcessAction: String, Identifiable {
    case quit, forceQuit, suspend, resume

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quit: "Quit"
        case .forceQuit: "Force Quit"
        case .suspend: "Pause"
        case .resume: "Resume"
        }
    }

    var pastTense: String {
        switch self {
        case .quit: "Quit"
        case .forceQuit: "Force quit"
        case .suspend: "Paused"
        case .resume: "Resumed"
        }
    }

    var symbol: String {
        switch self {
        case .quit: "xmark.circle"
        case .forceQuit: "xmark.octagon"
        case .suspend: "pause.circle"
        case .resume: "play.circle"
        }
    }

    var signal: Int32 {
        switch self {
        case .quit: SIGTERM
        case .forceQuit: SIGKILL
        case .suspend: SIGSTOP
        case .resume: SIGCONT
        }
    }
}

struct ActionOutcome {
    let succeeded: Int
    let deniedNames: [String]
    let failedNames: [String]

    var message: String? {
        if !deniedNames.isEmpty {
            let names = deniedNames.prefix(3).joined(separator: ", ")
            return "macOS didn't allow Herd to touch \(names). These belong to the system, so only an administrator can stop them."
        }
        if !failedNames.isEmpty {
            return "\(failedNames.prefix(3).joined(separator: ", ")) had already exited."
        }
        return nil
    }
}

enum ProcessActions {
    // Signalling these logs you out, hangs the Mac, or kills Herd itself.
    private static let protectedNames: Set<String> = ["WindowServer", "loginwindow", "launchd", "kernel_task"]

    static func isProtected(_ sample: ProcessSample) -> Bool {
        sample.pid <= 1 || sample.pid == getpid() || protectedNames.contains(sample.name)
    }

    static func canAct(on group: AppGroup) -> Bool {
        group.processes.contains { !isProtected($0.sample) }
    }

    @MainActor
    static func perform(_ action: ProcessAction, on group: AppGroup) -> ActionOutcome {
        if action == .quit || action == .forceQuit, let app = runningApp(for: group) {
            _ = action == .quit ? app.terminate() : app.forceTerminate()
            if action == .quit { return ActionOutcome(succeeded: 1, deniedNames: [], failedNames: []) }
        }
        return send(action, to: group.processes.map(\.sample))
    }

    static func perform(_ action: ProcessAction, on sample: ProcessSample) -> ActionOutcome {
        send(action, to: [sample])
    }

    private static func send(_ action: ProcessAction, to samples: [ProcessSample]) -> ActionOutcome {
        var succeeded = 0
        var denied: [String] = []
        var failed: [String] = []
        for sample in samples where !isProtected(sample) {
            if kill(sample.pid, action.signal) == 0 {
                succeeded += 1
            } else if errno == EPERM {
                denied.append(sample.name)
            } else {
                failed.append(sample.name)
            }
        }
        return ActionOutcome(succeeded: succeeded, deniedNames: Array(Set(denied)).sorted(), failedNames: Array(Set(failed)).sorted())
    }

    @MainActor
    private static func runningApp(for group: AppGroup) -> NSRunningApplication? {
        guard let pid = group.mainPid else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    @MainActor
    static func revealInFinder(_ group: AppGroup) {
        guard let path = group.bundlePath ?? group.executablePath, !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
