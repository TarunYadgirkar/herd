import AppKit
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
    private struct Streak {
        var since: Date
        var startMemory: UInt64
    }

    private static let cooldown: TimeInterval = 30 * 60
    private static let pressureHold: TimeInterval = 30
    private static let memoryGrowthWindow: TimeInterval = 10 * 60
    private static let memoryGrowthBytes: UInt64 = 3 * 1_073_741_824
    private static let hotCelsius = 100.0
    private static let hotHold: TimeInterval = 60

    private var cpuStreaks: [String: Date] = [:]
    private var memoryBaselines: [String: Streak] = [:]
    private var lastAlert: [String: Date] = [:]
    private var criticalSince: Date?
    private var hotSince: Date?
    private var isAuthorized = false

    func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        let quit = UNNotificationAction(identifier: AlertAction.quit, title: "Quit App", options: [.destructive])
        let ignore = UNNotificationAction(identifier: AlertAction.ignore, title: "Don't Alert for This App")
        center.setNotificationCategories([UNNotificationCategory(identifier: AlertAction.category, actions: [quit, ignore], intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.isAuthorized = granted }
        }
    }

    func evaluate(_ frame: Frame) {
        guard AlertSettings.isEnabled, isAuthorized else { return }
        let candidates = frame.groups.filter { $0.kind != .system && !$0.pids.contains(getpid()) }
        let ignored = AlertSettings.ignoredGroups
        checkRunawayCPU(candidates.filter { !ignored.contains($0.id) }, at: frame.date)
        checkMemoryGrowth(candidates.filter { !ignored.contains($0.id) }, at: frame.date)
        checkPressure(frame, at: frame.date)
        checkHeat(frame.system, at: frame.date)
    }

    private func checkRunawayCPU(_ groups: [AppGroup], at now: Date) {
        let threshold = AlertSettings.cpuThreshold
        let hold = AlertSettings.cpuMinutes * 60
        var next: [String: Date] = [:]
        for group in groups where group.metrics.cpu >= threshold {
            let since = cpuStreaks[group.id] ?? now
            next[group.id] = since
            guard now.timeIntervalSince(since) >= hold else { continue }
            notify(
                key: "cpu:\(group.id)", group: group, at: now,
                title: "\(group.name) is working hard",
                body: "It has used over \(Int(threshold))% CPU for \(Int(AlertSettings.cpuMinutes)) minutes. Quit it if you're not expecting this."
            )
        }
        cpuStreaks = next
    }

    private func checkMemoryGrowth(_ groups: [AppGroup], at now: Date) {
        var next: [String: Streak] = [:]
        for group in groups {
            var baseline = memoryBaselines[group.id] ?? Streak(since: now, startMemory: group.metrics.memory)
            if group.metrics.memory < baseline.startMemory || now.timeIntervalSince(baseline.since) > Self.memoryGrowthWindow {
                baseline = Streak(since: now, startMemory: group.metrics.memory)
            }
            next[group.id] = baseline
            let growth = group.metrics.memory > baseline.startMemory ? group.metrics.memory - baseline.startMemory : 0
            guard growth >= Self.memoryGrowthBytes else { continue }
            notify(
                key: "memory:\(group.id)", group: group, at: now,
                title: "\(group.name) is using a lot more memory",
                body: "It grew by \(Format.bytes(growth)) in the last few minutes and now uses \(Format.bytes(group.metrics.memory))."
            )
        }
        memoryBaselines = next
    }

    private func checkPressure(_ frame: Frame, at now: Date) {
        guard frame.system.pressure == .critical else {
            criticalSince = nil
            return
        }
        let since = criticalSince ?? now
        criticalSince = since
        guard now.timeIntervalSince(since) >= Self.pressureHold, let top = frame.groups.max(by: { $0.metrics.memory < $1.metrics.memory }) else { return }
        notify(
            key: "pressure", group: top, at: now,
            title: "Your Mac is running out of memory",
            body: "\(top.name) is using the most, \(Format.bytes(top.metrics.memory)). Quitting it will free memory fastest."
        )
    }

    private func checkHeat(_ system: SystemSnapshot, at now: Date) {
        guard let celsius = system.sensors?.cpuMaxCelsius, celsius >= Self.hotCelsius else {
            hotSince = nil
            return
        }
        let since = hotSince ?? now
        hotSince = since
        guard now.timeIntervalSince(since) >= Self.hotHold else { return }
        notify(
            key: "heat", group: nil, at: now,
            title: "Your Mac is running hot",
            body: "The CPU has stayed above \(Int(Self.hotCelsius)) °C for a minute. macOS may slow it down to cool off."
        )
    }

    private func notify(key: String, group: AppGroup?, at now: Date, title: String, body: String) {
        if let last = lastAlert[key], now.timeIntervalSince(last) < Self.cooldown { return }
        lastAlert[key] = now
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let group, ProcessActions.canAct(on: group) {
            content.categoryIdentifier = AlertAction.category
            content.userInfo = [AlertAction.groupKey: group.id]
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
    }
}
