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

    func doneMessage(_ name: String) -> String {
        switch self {
        case .quit: "Asked \(name) to quit"
        case .forceQuit: "Force quit \(name)"
        case .suspend: "Paused \(name)"
        case .resume: "Resumed \(name)"
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

    var isDestructive: Bool { self == .forceQuit }

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
    let protectedNames: [String]
    let deniedNames: [String]
    let goneNames: [String]

    func message(for action: ProcessAction, name: String) -> String {
        if succeeded > 0 && !deniedNames.isEmpty {
            return "\(action.doneMessage(name)). macOS kept \(list(deniedNames)) running because it belongs to the system."
        }
        if succeeded > 0 { return action.doneMessage(name) }
        if !deniedNames.isEmpty {
            return "macOS didn't let Herd \(action.title.lowercased()) \(list(deniedNames)). Only an administrator can stop system processes."
        }
        if !protectedNames.isEmpty { return "\(list(protectedNames)) keeps macOS running, so Herd won't touch it." }
        if !goneNames.isEmpty { return "\(name) had already exited." }
        return "Nothing to \(action.title.lowercased()) in \(name)."
    }

    private func list(_ names: [String]) -> String {
        names.prefix(3).joined(separator: ", ")
    }
}

enum ProcessActions {
    // Signalling these logs you out, hangs the Mac, or kills Herd itself.
    private static let protectedNames: Set<String> = ["WindowServer", "loginwindow", "launchd", "kernel_task"]
    // Pausing these freezes the desktop or every app that talks to them, with no way back to Herd to resume them.
    private static let unpausableNames: Set<String> = [
        "Dock", "Finder", "SystemUIServer", "ControlCenter", "NotificationCenter", "WindowManager", "coreaudiod", "hidd",
        "cfprefsd", "lsd", "distnoted", "pboard", "TextInputMenuAgent", "universalaccessd",
    ]
    private static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]
    private static let currentUid = getuid()

    static func isProtected(_ sample: ProcessSample, for action: ProcessAction = .quit) -> Bool {
        if sample.pid <= 1 || sample.pid == getpid() || protectedNames.contains(sample.name) { return true }
        guard action == .suspend else { return false }
        return unpausableNames.contains(sample.name) || sample.uid != currentUid || systemPrefixes.contains { sample.path.hasPrefix($0) }
    }

    static func canAct(on group: AppGroup, action: ProcessAction = .quit) -> Bool {
        if action == .suspend && group.kind == .system { return false }
        if action != .resume && !group.isSafeQuitTarget { return false }
        return group.processes.contains { !isProtected($0.sample, for: action) }
    }

    @MainActor
    static func perform(_ action: ProcessAction, on group: AppGroup) -> ActionOutcome {
        if action == .quit, let app = runningApp(for: group), app.terminate() {
            return ActionOutcome(succeeded: 1, protectedNames: [], deniedNames: [], goneNames: [])
        }
        if action == .forceQuit, let app = runningApp(for: group) {
            app.forceTerminate()
        }
        return send(action, to: group.processes.map(\.sample))
    }

    static func perform(_ action: ProcessAction, on sample: ProcessSample) -> ActionOutcome {
        send(action, to: [sample])
    }

    static func perform(_ action: ProcessAction, on samples: [ProcessSample]) -> ActionOutcome {
        send(action, to: samples)
    }

    private static func send(_ action: ProcessAction, to samples: [ProcessSample]) -> ActionOutcome {
        var succeeded = 0
        var protected: Set<String> = []
        var denied: Set<String> = []
        var gone: Set<String> = []
        for sample in samples {
            if isProtected(sample, for: action) {
                protected.insert(sample.name)
            } else if kill(sample.pid, action.signal) == 0 {
                succeeded += 1
                action == .suspend ? PauseLedger.record(sample) : PauseLedger.forget(sample)
            } else if errno == EPERM {
                denied.insert(sample.name)
            } else {
                gone.insert(sample.name)
            }
        }
        return ActionOutcome(succeeded: succeeded, protectedNames: protected.sorted(), deniedNames: denied.sorted(), goneNames: gone.sorted())
    }

    @MainActor
    private static func runningApp(for group: AppGroup) -> NSRunningApplication? {
        guard let pid = group.mainPid, let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy != .prohibited else { return nil }
        return app
    }

    @MainActor
    static func hasRunningApp(_ group: AppGroup) -> Bool {
        runningApp(for: group) != nil
    }

    @MainActor
    static func revealInFinder(_ group: AppGroup) {
        guard let path = group.bundlePath ?? group.executablePath, !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
