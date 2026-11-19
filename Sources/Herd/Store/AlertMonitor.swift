import AppKit
import OSLog
import UserNotifications

enum AlertSettings {
    static let enabledKey = "alertsEnabled"
    static let cpuThresholdKey = "alertCPUThreshold"
    static let cpuMinutesKey = "alertCPUMinutes"
    static let ignoredKey = "alertIgnoredGroups"

    static let defaultCPUThreshold = 90.0
    static let defaultCPUMinutes = 3.0

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static var cpuThreshold: Double { UserDefaults.standard.object(forKey: cpuThresholdKey) as? Double ?? defaultCPUThreshold }
    static var cpuMinutes: Double { UserDefaults.standard.object(forKey: cpuMinutesKey) as? Double ?? defaultCPUMinutes }

    static var ignoredGroups: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: ignoredKey) ?? [])
    }

    static func ignore(_ groupID: String) {
        UserDefaults.standard.set(Array(ignoredGroups.union([groupID])), forKey: ignoredKey)
    }
}

enum AlertAction {
    static let category = "herd.app-alert"
    static let quit = "herd.quit"
    static let ignore = "herd.ignore"
    static let groupKey = "groupID"
}

// Alerts fire only on sustained conditions, never on momentary spikes, and each app gets a cooldown so Herd doesn't nag.
@MainActor
final class AlertMonitor {
    nonisolated private static let log = Logger(subsystem: "com.tarunyadgirkar.herd", category: "alerts")

    // Memory is compared with the lowest reading of the last one to two half-windows, so growth that straddles
    // a window boundary still counts and a drop in use lowers the baseline at once.
    private struct MemoryBaseline {
        let firstSeen: Date
        var bucketStart: Date
        var previousLow: UInt64
        var currentLow: UInt64

        var low: UInt64 { min(previousLow, currentLow) }
    }

    private static let cooldown: TimeInterval = 30 * 60
    private static let criticalHold: TimeInterval = 30
    private static let strainHold: TimeInterval = 2 * 60
    private static let memoryGrowthWindow: TimeInterval = 10 * 60
    private static let memoryGrowthBytes: UInt64 = 3 * 1_073_741_824
    // An app that is still launching, or a virtual machine that is booting, takes gigabytes in its first minutes by design.
    private static let launchGrace: TimeInterval = 2 * 60
    private static let hotHold: TimeInterval = 60

    private var cpuStreaks: [String: Date] = [:]
    private var memoryBaselines: [String: MemoryBaseline] = [:]
    private var lastAlert: [String: Date] = [:]
    private var strainedSince: Date?
    private var hotSince: Date?
    private var lastFrameDate: Date?
    // Set once the app has a notification center. Permission is not cached here: macOS drops posts while it is off,
    // and turning it on later in System Settings takes effect at once.
    private var canPost = false

    func requestAuthorization() {
        canPost = true
        let center = UNUserNotificationCenter.current()
        let quit = UNNotificationAction(identifier: AlertAction.quit, title: "Quit App", options: [.destructive])
        let ignore = UNNotificationAction(identifier: AlertAction.ignore, title: "Don't Alert for This App")
        center.setNotificationCategories([UNNotificationCategory(identifier: AlertAction.category, actions: [quit, ignore], intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            Self.log.notice("notification authorization granted=\(granted, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    private var firedThisFrame: [String] = []

    // Returns the alerts this frame triggered, whether or not macOS lets Herd show notifications, so the decisions are testable.
    @discardableResult
    func evaluate(_ frame: Frame, maxGap: TimeInterval) -> [String] {
        resetIfGap(before: frame.date, maxGap: maxGap)
        firedThisFrame = []
        guard AlertSettings.isEnabled else { return [] }
        let candidates = frame.groups.filter { $0.kind != .system && !$0.pids.contains(getpid()) }
        let ignored = AlertSettings.ignoredGroups
        checkRunawayCPU(candidates.filter { !ignored.contains($0.id) }, at: frame.date)
        checkMemoryGrowth(candidates.filter { !ignored.contains($0.id) }, at: frame.date)
        checkPressure(frame, at: frame.date)
        checkHeat(frame.system, at: frame.date)
        return firedThisFrame
    }

    // Two high readings with a pause or sleep between them say nothing about the time in between, so streaks restart.
    private func resetIfGap(before date: Date, maxGap: TimeInterval) {
        defer { lastFrameDate = date }
        guard let lastFrameDate, date.timeIntervalSince(lastFrameDate) > maxGap else { return }
        cpuStreaks = [:]
        memoryBaselines = [:]
        strainedSince = nil
        hotSince = nil
    }

    private func checkRunawayCPU(_ groups: [AppGroup], at now: Date) {
        let threshold = AlertSettings.cpuThreshold
        let hold = AlertSettings.cpuMinutes * 60
        // The app in front is the one being used, so its work is expected; a runaway is something busy in the background.
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var next: [String: Date] = [:]
        for group in groups where group.metrics.cpu >= threshold && !(frontPid.map(group.pids.contains) ?? false) {
            let since = cpuStreaks[group.id] ?? now
            next[group.id] = since
            guard now.timeIntervalSince(since) >= hold else { continue }
            notify(
                key: "cpu:\(group.id)", group: group, at: now,
                title: "\(group.name) is working hard",
                body: "It has used over \(Int(threshold))% CPU for \(Self.minutes(AlertSettings.cpuMinutes))."
            )
        }
        cpuStreaks = next
    }

    static func minutes(_ count: Double) -> String {
        let whole = Int(count)
        return whole == 1 ? "a minute" : "\(whole) minutes"
    }

    private func checkMemoryGrowth(_ groups: [AppGroup], at now: Date) {
        var next: [String: MemoryBaseline] = [:]
        for group in groups {
            let memory = group.metrics.memory
            let fresh = MemoryBaseline(firstSeen: now, bucketStart: now, previousLow: memory, currentLow: memory)
            var baseline = memoryBaselines[group.id] ?? fresh
            if now.timeIntervalSince(baseline.firstSeen) < Self.launchGrace {
                next[group.id] = MemoryBaseline(firstSeen: baseline.firstSeen, bucketStart: now, previousLow: memory, currentLow: memory)
                continue
            }
            if now.timeIntervalSince(baseline.bucketStart) > Self.memoryGrowthWindow / 2 {
                baseline.bucketStart = now
                baseline.previousLow = baseline.currentLow
                baseline.currentLow = memory
            }
            baseline.currentLow = min(baseline.currentLow, memory)
            next[group.id] = baseline
            let growth = memory > baseline.low ? memory - baseline.low : 0
            guard growth >= Self.memoryGrowthBytes else { continue }
            notify(
                key: "memory:\(group.id)", group: group, at: now,
                title: "\(group.name) is using a lot more memory",
                body: "It grew by \(Format.bytes(growth)) in the last few minutes and now uses \(Format.bytes(group.metrics.memory))."
            )
        }
        memoryBaselines = next
    }

    // macOS can sit at "warning" for days while swapping heavily, and that is when the Mac feels slow, so warning plus
    // heavy swap counts as strain too, only after a longer hold.
    private static func strainHold(_ system: SystemSnapshot) -> TimeInterval? {
        switch system.pressure {
        case .critical: criticalHold
        case .warning where system.isSwapHeavy: strainHold
        default: nil
        }
    }

    private func checkPressure(_ frame: Frame, at now: Date) {
        guard let hold = Self.strainHold(frame.system) else {
            strainedSince = nil
            return
        }
        let since = strainedSince ?? now
        strainedSince = since
        let candidates = frame.groups.filter { $0.kind != .system && !$0.pids.contains(getpid()) }
        guard now.timeIntervalSince(since) >= hold, let top = candidates.max(by: { $0.metrics.memory < $1.metrics.memory }) else { return }
        notify(
            key: "pressure", group: top, at: now,
            title: "Your Mac is short on memory",
            body: "It has moved \(Format.bytes(frame.system.swapUsed)) to disk, which slows everything down. \(top.name) uses the most, \(Format.bytes(top.metrics.memory))."
        )
    }

    private func checkHeat(_ system: SystemSnapshot, at now: Date) {
        // One core touching 100 °C is normal under load. macOS's own thermal state says when heat is actually costing speed.
        guard system.thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue else {
            hotSince = nil
            return
        }
        let since = hotSince ?? now
        hotSince = since
        guard now.timeIntervalSince(since) >= Self.hotHold else { return }
        notify(
            key: "heat", group: nil, at: now,
            title: "Your Mac is running hot",
            body: "macOS is slowing the Mac down to cool it off."
        )
    }

    private func notify(key: String, group: AppGroup?, at now: Date, title: String, body: String) {
        if let last = lastAlert[key], now.timeIntervalSince(last) < Self.cooldown { return }
        lastAlert[key] = now
        firedThisFrame.append(key)
        guard canPost else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let group, ProcessActions.canAct(on: group), group.isSafeQuitTarget {
            content.categoryIdentifier = AlertAction.category
            content.userInfo = [AlertAction.groupKey: group.id]
        }
        Self.log.notice("posting alert \(key, privacy: .public): \(title, privacy: .public)")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil)) { error in
            guard let error else { return }
            Self.log.error("alert \(key, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
