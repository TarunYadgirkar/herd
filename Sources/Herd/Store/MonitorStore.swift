import AppKit
import Observation

enum UpdateInterval: Double, CaseIterable, Identifiable {
    case fast = 1
    case normal = 2
    case relaxed = 5

    var id: Double { rawValue }

    var title: String {
        switch self {
        case .fast: "Every second"
        case .normal: "Every 2 seconds"
        case .relaxed: "Every 5 seconds"
        }
    }
}

@MainActor
@Observable
final class MonitorStore {
    private static let warmUpDelay = Duration.milliseconds(700)
    private static let historySaveInterval: TimeInterval = 300
    private static let timerTolerance = 0.1
    // A frame arriving more than this many intervals late means sampling paused or the Mac slept.
    static let gapIntervals = 3.0
    static let alertGapFloor: TimeInterval = 30

    struct Headline: Equatable {
        var cpu: Double = 0
        var memoryUsed: UInt64 = 0
    }

    private(set) var headline = Headline()
    private(set) var groups: [AppGroup] = []
    private(set) var system = SystemSnapshot()
    // Histories are kept once and mutated in place; this revision is what tells views they changed.
    private(set) var historyRevision = 0
    private(set) var processCount = 0
    private(set) var hasFirstFrame = false
    private(set) var projectActivity = ActivityLedger()
    let archive = HistoryArchive()
    @ObservationIgnored let alerts = AlertMonitor()
    @ObservationIgnored let dockGraph = DockTileGraph()
    @ObservationIgnored private let projectTracker = ProjectTracker()

    var isPaused = false
    var requestedSelection: String?
    var powerMode: PowerMode {
        didSet {
            UserDefaults.standard.set(powerMode.rawValue, forKey: PowerMode.key)
            updateEffort()
        }
    }
    private(set) var effort: SamplingEffort
    var interval: UpdateInterval { effort.interval }

    @ObservationIgnored private let engine = SamplingEngine()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var regularAppPids: Set<pid_t>?
    @ObservationIgnored private var visibleSurfaces: Set<String> = []
    // Windows keep reporting themselves visible behind the lock screen, so a locked or sleeping display counts as nobody looking.
    @ObservationIgnored private var isScreenAway = false
    @ObservationIgnored private var screenObservers: [NSObjectProtocol] = []
    private var isDetailVisible: Bool { !visibleSurfaces.isEmpty && !isScreenAway }
    @ObservationIgnored private var latestFrame: Frame?
    @ObservationIgnored private var groupHistories: [String: GroupHistory] = [:]
    @ObservationIgnored private var liveSystemHistory = SystemHistory()
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var lastHistorySave = Date()

    init() {
        let mode = UserDefaults.standard.string(forKey: PowerMode.key).flatMap(PowerMode.init) ?? PowerMode.standard
        powerMode = mode
        effort = mode.effort(onBattery: PowerSource.isOnBattery, lowPowerMode: PowerSource.isLowPowerMode)
        liveSystemHistory = SystemHistory(capacity: historySamples)
    }

    func start() {
        guard loop == nil else { return }
        observeWorkspace()
        observeScreen()
        // Utility priority steers sampling off the fastest cores; the tolerance lets macOS coalesce
        // Herd's wakeups with other timers, which Apple's energy guide asks for (at least 10%).
        loop = Task(priority: .utility) { [weak self] in
            guard let effort = self?.effort else { return }
            await self?.engine.start(effort: effort)
            await self?.refresh(force: true)
            try? await Task.sleep(for: Self.warmUpDelay)
            while !Task.isCancelled, let self {
                await self.refresh()
                self.updateEffort()
                let interval = Duration.seconds(self.interval.rawValue)
                try? await Task.sleep(for: interval, tolerance: interval * Self.timerTolerance)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        Task { await engine.stop() }
    }

    // Checked once per tick: unplugging or turning on Low Power Mode switches Automatic to Light by the next sample.
    private func updateEffort() {
        let next = powerMode.effort(onBattery: PowerSource.isOnBattery, lowPowerMode: PowerSource.isLowPowerMode)
        guard next != effort else { return }
        effort = next
        resizeHistory()
        Task { await engine.setEffort(next) }
    }

    func saveHistory() {
        archive.save(waitUntilWritten: true)
    }

    func refreshNow() {
        Task { await refresh(force: true) }
    }

    var historySamples: Int {
        min(Int(Series.window / interval.rawValue), Series.capacity)
    }

    // Actions must target what is running now, even while per-app publishing is paused because no window is visible.
    func liveGroup(id: String) -> AppGroup? {
        (latestFrame?.groups ?? groups).first { $0.id == id }
    }

    func liveProcess(id: String) -> ProcessSample? {
        for group in latestFrame?.groups ?? groups {
            if let match = group.processes.first(where: { $0.id == id }) { return match.sample }
        }
        return nil
    }

    func group(id: String?) -> AppGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    var systemHistory: SystemHistory {
        _ = historyRevision
        return liveSystemHistory
    }

    func history(for id: String) -> GroupHistory {
        _ = historyRevision
        return currentHistory(for: id)
    }

    // Doesn't subscribe the caller, so the table's trend cells redraw only when its rows do.
    func currentHistory(for id: String) -> GroupHistory {
        groupHistories[id] ?? GroupHistory(capacity: historySamples)
    }

    private func refresh(force: Bool = false) async {
        guard force || !isPaused else { return }
        let frame = await engine.tick(regularAppPids: currentRegularAppPids())
        apply(frame, recordsHistory: !force)
    }

    // Listing running apps is expensive, so the set is rebuilt only when an app launches or quits.
    private func currentRegularAppPids() -> Set<pid_t> {
        if let regularAppPids { return regularAppPids }
        let pids = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier))
        regularAppPids = pids
        return pids
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let names = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification]
        workspaceObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.regularAppPids = nil }
            }
        }
    }

    // Re-rendering the app table is the most expensive thing Herd does, so per-app data is only published while someone can see it.
    func setSurface(_ name: String, visible: Bool) {
        updateVisibility {
            if visible {
                visibleSurfaces.insert(name)
                // A missed unlock notification would otherwise leave every window frozen until the next lock cycle.
                isScreenAway = Self.isScreenLocked
            } else {
                visibleSurfaces.remove(name)
            }
        }
    }

    private func updateVisibility(_ change: () -> Void) {
        let wasVisible = isDetailVisible
        change()
        let isVisible = isDetailVisible
        guard isVisible != wasVisible else { return }
        if isVisible { publishDetail() }
        Task { await engine.setDetailVisible(isVisible) }
    }

    private static var isScreenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private func observeScreen() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let away: [(NotificationCenter, Notification.Name, Bool)] = [
            (workspace, NSWorkspace.screensDidSleepNotification, true),
            (workspace, NSWorkspace.screensDidWakeNotification, false),
            (distributed, Notification.Name("com.apple.screenIsLocked"), true),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), false),
        ]
        isScreenAway = Self.isScreenLocked
        screenObservers = away.map { center, name, isAway in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateVisibility { self?.isScreenAway = isAway } }
            }
        }
    }

    // Forced frames cover a shorter window than the update interval, so they'd skew the evenly spaced history.
    private func apply(_ frame: Frame, recordsHistory: Bool) {
        if hasFirstFrame {
            let elapsed = frame.elapsed ?? interval.rawValue
            let rateWindow = min(elapsed, interval.rawValue * Self.gapIntervals)
            if recordsHistory {
                recordHistory(frame)
                archive.record(frame.system, groups: frame.groups, elapsed: elapsed, rateWindow: rateWindow, at: frame.date)
                saveHistoryIfDue(at: frame.date)
                alerts.evaluate(frame, maxGap: max(interval.rawValue * Self.gapIntervals, Self.alertGapFloor))
            } else {
                archive.recordUsage(groups: frame.groups, elapsed: elapsed, rateWindow: rateWindow, at: frame.date)
            }
        }
        latestFrame = frame
        // System readings are cheap to publish and the charts beside them redraw from the archive every tick,
        // so they're always published; otherwise a page's current value freezes while its graph keeps moving.
        system = frame.system
        projectTracker.record(frame.groups, at: frame.date)
        dockGraph.update(cpu: frame.system.cpuTotal)
        let nextHeadline = Headline(cpu: frame.system.cpuTotal, memoryUsed: frame.system.memoryUsed)
        if nextHeadline != headline { headline = nextHeadline }
        if isDetailVisible { publishDetail() }
        hasFirstFrame = true
    }

    private func saveHistoryIfDue(at date: Date) {
        guard date.timeIntervalSince(lastHistorySave) >= Self.historySaveInterval else { return }
        lastHistorySave = date
        archive.save()
    }

    // The newest sample even while no window shows it, for sharing with the user's other Macs.
    var latestSystem: SystemSnapshot? { latestFrame?.system }

    private func publishDetail() {
        guard let latestFrame else { return }
        groups = latestFrame.groups
        processCount = latestFrame.processCount
        historyRevision += 1
        projectActivity = projectTracker.ledger
    }

    // The first frame has no previous counters, so its rates are all zero and would drag every sparkline down.
    private func recordHistory(_ frame: Frame) {
        let capacity = historySamples
        let live = Set(frame.groups.map(\.id))
        for id in groupHistories.keys.filter({ !live.contains($0) }) { groupHistories.removeValue(forKey: id) }
        for group in frame.groups {
            groupHistories[group.id, default: GroupHistory(capacity: capacity)].append(group.metrics)
        }
        liveSystemHistory.append(frame.system)
    }

    private func resizeHistory() {
        let capacity = historySamples
        liveSystemHistory.resize(to: capacity)
        for id in groupHistories.keys { groupHistories[id]?.resize(to: capacity) }
        historyRevision += 1
    }
}
