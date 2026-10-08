import Darwin
import Foundation

enum IdleLevel: Sendable {
    case active, quiet, idle

    static let activeWindow: TimeInterval = 60
    static let idleThreshold: TimeInterval = 30 * 60

    init(_ idle: TimeInterval?) {
        guard let idle else { self = .quiet; return }
        if idle < Self.activeWindow { self = .active; return }
        self = idle >= Self.idleThreshold ? .idle : .quiet
    }
}

struct Launcher: Hashable, Sendable {
    let name: String
    let bundlePath: String?
}

struct LabeledProcess: Sendable {
    let sample: ProcessSample
    let label: String
}

// A copy is one running instance of a tool: the process a session started plus the runtime children it spawned
// (npx's "npm exec" wrapper and the server it launches are one copy, not two).
struct ProcessCopy: Identifiable, Sendable {
    let title: String
    let key: String
    let members: [LabeledProcess]
    let groupID: String
    let projectName: String?
    let launcher: Launcher?
    let idle: TimeInterval?
    let isOrphan: Bool
    let isProtected: Bool
    var isSessionKeeper = false

    var root: ProcessSample { members[0].sample }
    var id: String { root.id }
    var memory: UInt64 { members.reduce(0) { $0 + $1.sample.memoryBytes } }
    var session: pid_t { root.responsiblePid != root.pid ? root.responsiblePid : root.ppid }
    // A quiet server can still belong to a live session that will call it again, so the newest copy per session
    // is never offered; only copies whose session is gone, or idle extras inside one session, are.
    var isSafeToStop: Bool {
        guard !isProtected else { return false }
        return isOrphan || (!isSessionKeeper && (idle ?? 0) >= IdleLevel.idleThreshold)
    }
}

struct DuplicateSet: Identifiable, Sendable {
    let key: String
    let title: String
    let copies: [ProcessCopy]

    var id: String { key }
    var totalMemory: UInt64 { copies.reduce(0) { $0 + $1.memory } }
}

struct ProjectSummary: Identifiable, Sendable {
    let group: AppGroup
    let name: String
    let root: String?
    let runtimes: [Runtime]
    let ports: [UInt16]
    let oldestStart: Date?
    let idle: TimeInterval?
    let launchers: [Launcher]

    var id: String { group.id }
    var isUnowned: Bool { group.project == nil }
    var isSafeQuitTarget: Bool { group.isSafeQuitTarget }
    var metrics: Metrics { group.metrics }
}

struct ProjectReport: Sendable {
    let projects: [ProjectSummary]
    let unowned: [ProjectSummary]
    let duplicates: [DuplicateSet]
    let orphans: [ProcessCopy]

    var isEmpty: Bool { projects.isEmpty && unowned.isEmpty }
    var totalMemory: UInt64 { (projects + unowned).reduce(0) { $0 + $1.metrics.memory } }
    var loneOrphans: [ProcessCopy] {
        let duplicated = Set(duplicates.flatMap(\.copies).map(\.id))
        return orphans.filter { !duplicated.contains($0.id) }
    }
    var leftovers: [ProcessCopy] {
        var seen: Set<String> = []
        return (duplicates.flatMap(\.copies) + orphans).filter { $0.isSafeToStop && seen.insert($0.id).inserted }
    }
    var reclaimableMemory: UInt64 { leftovers.reduce(0) { $0 + $1.memory } }
}

enum ProjectInsights {
    private static let runtimeGroupPrefix = "runtime:"
    private static let wrapperPrefixes = ["npm exec ", "npx "]

    static func isRuntimeGroup(_ group: AppGroup) -> Bool {
        group.project != nil || group.id.hasPrefix(runtimeGroupPrefix)
    }

    static func report(groups: [AppGroup], ledger: ActivityLedger, selfPid: pid_t = getpid()) -> ProjectReport {
        let context = Context(groups: groups, ledger: ledger, selfPid: selfPid)
        let runtimeGroups = groups.filter(isRuntimeGroup)
        let summaries = runtimeGroups.map(context.summary).sorted { $0.metrics.memory > $1.metrics.memory }
        let copies = context.copies(in: runtimeGroups)
        return ProjectReport(
            projects: summaries.filter { !$0.isUnowned },
            unowned: summaries.filter(\.isUnowned),
            duplicates: duplicates(in: copies),
            orphans: copies.filter(\.isOrphan)
        )
    }

    static func duplicates(in copies: [ProcessCopy]) -> [DuplicateSet] {
        Dictionary(grouping: copies, by: \.key)
            .filter { $0.value.count >= 2 }
            .map { key, members in
                let ordered = markSessionKeepers(members.sorted { ($0.root.startTime ?? .distantPast) < ($1.root.startTime ?? .distantPast) })
                return DuplicateSet(key: key, title: ordered[0].title, copies: ordered)
            }
            .sorted { $0.totalMemory == $1.totalMemory ? $0.key < $1.key : $0.totalMemory > $1.totalMemory }
    }

    // Copies arrive oldest first, so the last one seen per session is that session's newest.
    private static func markSessionKeepers(_ copies: [ProcessCopy]) -> [ProcessCopy] {
        let newestPerSession = Dictionary(copies.enumerated().map { ($0.element.session, $0.offset) }, uniquingKeysWith: { _, later in later })
        let keepers = Set(newestPerSession.values)
        return copies.enumerated().map { index, copy in
            var marked = copy
            marked.isSessionKeeper = keepers.contains(index)
            return marked
        }
    }

    static func normalizedName(_ title: String) -> String {
        var name = title.lowercased().trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("@"), let slash = name.firstIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        if let at = name.lastIndex(of: "@"), at != name.startIndex {
            name = String(name[..<at])
        }
        return name
    }

    // A launcher that died leaves its children running with a responsible pid that no longer exists. Parent pid 1 alone
    // proves nothing: every launchd agent has it.
    static func isOrphan(_ sample: ProcessSample, livePids: Set<pid_t>) -> Bool {
        sample.responsiblePid != sample.pid && sample.responsiblePid > 0 && !livePids.contains(sample.responsiblePid)
    }

    static func isWrapper(_ sample: ProcessSample) -> Bool {
        guard let first = sample.arguments.first else { return false }
        return wrapperPrefixes.contains { first.hasPrefix($0) }
    }

    static func compactDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(seconds, 0) / 60)
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        return hours < 24 ? "\(hours)h" : "\(hours / 24)d"
    }
}

private struct Context {
    let byPid: [pid_t: ProcessSample]
    let groupByPid: [pid_t: AppGroup]
    let livePids: Set<pid_t>
    let ledger: ActivityLedger
    let selfPid: pid_t

    init(groups: [AppGroup], ledger: ActivityLedger, selfPid: pid_t) {
        var byPid: [pid_t: ProcessSample] = [:]
        var groupByPid: [pid_t: AppGroup] = [:]
        for group in groups {
            for member in group.processes {
                byPid[member.sample.pid] = member.sample
                groupByPid[member.sample.pid] = group
            }
        }
        self.byPid = byPid
        self.groupByPid = groupByPid
        livePids = Set(byPid.keys)
        self.ledger = ledger
        self.selfPid = selfPid
    }

    func summary(_ group: AppGroup) -> ProjectSummary {
        let samples = group.processes.map(\.sample)
        return ProjectSummary(
            group: group,
            name: group.project.map { ($0 as NSString).lastPathComponent } ?? group.name,
            root: group.project,
            runtimes: Array(Set(samples.compactMap { Runtime.detect(executableName: $0.name) })).sorted { $0.rawValue < $1.rawValue },
            ports: Array(Set(samples.flatMap(\.listeningPorts))).sorted(),
            oldestStart: samples.compactMap(\.startTime).min(),
            idle: idle(samples),
            launchers: uniqueLaunchers(samples)
        )
    }

    func copies(in runtimeGroups: [AppGroup]) -> [ProcessCopy] {
        let members = runtimeGroups.flatMap { group in group.processes.map { (group, $0) } }
        let memberPids = Set(members.map(\.1.sample.pid))
        let children = Dictionary(grouping: members.filter { memberPids.contains($0.1.sample.ppid) }, by: \.1.sample.ppid)
        return members
            .filter { !memberPids.contains($0.1.sample.ppid) }
            .map { group, root in makeCopy(root: root, group: group, children: children) }
    }

    private func makeCopy(root: GroupedProcess, group: AppGroup, children: [pid_t: [(AppGroup, GroupedProcess)]]) -> ProcessCopy {
        let tree = [root] + descendants(of: root.sample.pid, children: children)
        let directChild = children[root.sample.pid]?.map(\.1).min { $0.sample.pid < $1.sample.pid }
        let title = ProjectInsights.isWrapper(root.sample) ? directChild?.title ?? root.title : root.title
        let samples = tree.map(\.sample)
        return ProcessCopy(
            title: title,
            key: ProjectInsights.normalizedName(title),
            members: tree.map { LabeledProcess(sample: $0.sample, label: $0.title) },
            groupID: group.id,
            projectName: group.project.map { ($0 as NSString).lastPathComponent },
            launcher: launcher(for: root.sample),
            idle: idle(samples),
            isOrphan: ProjectInsights.isOrphan(root.sample, livePids: livePids),
            isProtected: samples.contains(where: isProtected)
        )
    }

    private func descendants(of pid: pid_t, children: [pid_t: [(AppGroup, GroupedProcess)]]) -> [GroupedProcess] {
        let direct = (children[pid] ?? []).map(\.1).sorted { $0.sample.pid < $1.sample.pid }
        return direct.flatMap { [$0] + descendants(of: $0.sample.pid, children: children) }
    }

    private func idle(_ samples: [ProcessSample]) -> TimeInterval? {
        samples.compactMap { ledger.idle($0.id) }.min()
    }

    private func isProtected(_ sample: ProcessSample) -> Bool {
        ProcessActions.isProtected(sample) || [sample.pid, sample.ppid, sample.responsiblePid].contains(selfPid)
    }

    // Some launchers (Claude's disclaimer helper) make the servers they start responsible for themselves,
    // so the parent names the launcher when responsibility doesn't.
    func launcher(for sample: ProcessSample) -> Launcher? {
        let owner = sample.responsiblePid != sample.pid ? sample.responsiblePid : sample.ppid
        guard owner > 1, let group = groupByPid[owner], !ProjectInsights.isRuntimeGroup(group) else { return nil }
        return Launcher(name: group.name, bundlePath: group.bundlePath)
    }

    private func uniqueLaunchers(_ samples: [ProcessSample]) -> [Launcher] {
        var seen: Set<Launcher> = []
        return samples.compactMap(launcher(for:)).filter { seen.insert($0).inserted }
    }
}
