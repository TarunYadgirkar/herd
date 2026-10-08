import Foundation

// Idle time is measured from when Herd first saw a process, so a process that was already quiet before Herd launched
// reads as idle for at most as long as Herd has been watching.
struct ActivityLedger: Sendable {
    struct Entry: Sendable, Equatable {
        let firstSeen: Date
        let lastActive: Date?
    }

    static let cpuThreshold = 0.5
    static let networkThreshold = 1024.0

    let date: Date
    let entries: [String: Entry]

    init(date: Date = .distantPast, entries: [String: Entry] = [:]) {
        self.date = date
        self.entries = entries
    }

    func recording(_ samples: [ProcessSample], at date: Date) -> ActivityLedger {
        var next: [String: Entry] = [:]
        next.reserveCapacity(samples.count)
        for sample in samples {
            let previous = entries[sample.id]
            let lastActive = Self.isActive(sample) ? date : previous?.lastActive
            next[sample.id] = Entry(firstSeen: previous?.firstSeen ?? date, lastActive: lastActive)
        }
        return ActivityLedger(date: date, entries: next)
    }

    func idle(_ id: String) -> TimeInterval? {
        entries[id].map { max(date.timeIntervalSince($0.lastActive ?? $0.firstSeen), 0) }
    }

    static func isActive(_ sample: ProcessSample) -> Bool {
        sample.cpuPercent >= cpuThreshold || sample.netInBps + sample.netOutBps >= networkThreshold
    }
}

@MainActor
final class ProjectTracker {
    private(set) var ledger = ActivityLedger()

    func record(_ groups: [AppGroup], at date: Date) {
        let samples = groups.filter(ProjectInsights.isRuntimeGroup).flatMap { $0.processes.map(\.sample) }
        ledger = ledger.recording(samples, at: date)
    }
}
