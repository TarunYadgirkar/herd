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
    static let intervalKey = "updateInterval"
    private static let warmUpDelay = Duration.milliseconds(700)
    private static let historySaveInterval: TimeInterval = 300

    struct Headline: Equatable {
        var cpu: Double = 0
        var memoryUsed: UInt64 = 0
    }

    private(set) var headline = Headline()
    private(set) var groups: [AppGroup] = []
    private(set) var system = SystemSnapshot()
    private(set) var systemHistory = SystemHistory()
    private(set) var groupHistory: [String: GroupHistory] = [:]
    private(set) var processCount = 0
    private(set) var hasFirstFrame = false
    let archive = HistoryArchive()
    @ObservationIgnored let alerts = AlertMonitor()
    @ObservationIgnored let dockGraph = DockTileGraph()

    var isPaused = false
    var requestedSelection: String?
    var interval: UpdateInterval {
        didSet { UserDefaults.standard.set(interval.rawValue, forKey: Self.intervalKey) }
    }

    @ObservationIgnored private let engine = SamplingEngine()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var regularAppPids: Set<pid_t>?
    @ObservationIgnored private var visibleSurfaces: Set<String> = []
    @ObservationIgnored private var latestFrame: Frame?
    @ObservationIgnored private var latestGroupHistory: [String: GroupHistory] = [:]
    @ObservationIgnored private var latestSystemHistory = SystemHistory()
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var lastHistorySave = Date()

    init() {
        let saved = UserDefaults.standard.double(forKey: Self.intervalKey)
        interval = UpdateInterval(rawValue: saved) ?? .normal
    }

    func start() {
        guard loop == nil else { return }
        observeWorkspace()
        loop = Task { [weak self] in
            await self?.engine.start()
            await self?.refresh(force: true)
            try? await Task.sleep(for: Self.warmUpDelay)
            while !Task.isCancelled, let self {
                await self.refresh()
                try? await Task.sleep(for: .seconds(self.interval.rawValue))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        Task { await engine.stop() }
    }

    func saveHistory() {
        archive.save(waitUntilWritten: true)
    }

    func refreshNow() {
        Task { await refresh(force: true) }
    }

    var ownCPU: Double {
        let pid = getpid()
        return groups.first { $0.pids.contains(pid) }?.processes.first { $0.sample.pid == pid }?.sample.cpuPercent ?? 0
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

    func history(for id: String) -> GroupHistory {
        groupHistory[id] ?? GroupHistory()
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
        let wasVisible = !visibleSurfaces.isEmpty
        if visible {
            visibleSurfaces.insert(name)
            publishDetail()
        } else {
            visibleSurfaces.remove(name)
        }
        let isVisible = !visibleSurfaces.isEmpty
        guard isVisible != wasVisible else { return }
        Task { await engine.setDetailVisible(isVisible) }
    }

    // Forced frames cover a shorter window than the update interval, so they'd skew the evenly spaced history.
    private func apply(_ frame: Frame, recordsHistory: Bool) {
        if hasFirstFrame && recordsHistory {
            recordHistory(frame)
            archive.record(frame.system, groups: frame.groups, interval: interval.rawValue, at: frame.date)
            saveHistoryIfDue(at: frame.date)
            alerts.evaluate(frame)
        }
        latestFrame = frame
        dockGraph.update(cpu: frame.system.cpuTotal)
        let nextHeadline = Headline(cpu: frame.system.cpuTotal, memoryUsed: frame.system.memoryUsed)
        if nextHeadline != headline { headline = nextHeadline }
        if !visibleSurfaces.isEmpty { publishDetail() }
        hasFirstFrame = true
    }

    private func saveHistoryIfDue(at date: Date) {
        guard date.timeIntervalSince(lastHistorySave) >= Self.historySaveInterval else { return }
        lastHistorySave = date
        archive.save()
    }

    private func publishDetail() {
        guard let latestFrame else { return }
        system = latestFrame.system
        systemHistory = latestSystemHistory
        groups = latestFrame.groups
        processCount = latestFrame.processCount
        groupHistory = latestGroupHistory
    }

    // The first frame has no previous counters, so its rates are all zero and would drag every sparkline down.
    private func recordHistory(_ frame: Frame) {
        var nextHistory: [String: GroupHistory] = [:]
        for group in frame.groups {
            nextHistory[group.id] = (latestGroupHistory[group.id] ?? GroupHistory()).appending(group.metrics)
        }
        latestGroupHistory = nextHistory
        latestSystemHistory = latestSystemHistory.appending(frame.system)
    }
}
