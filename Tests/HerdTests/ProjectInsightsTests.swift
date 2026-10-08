import Darwin
import Foundation
import Testing
@testable import Herd

private let claudePid: pid_t = 50
private let herdPid: pid_t = 7

private func proc(
    _ pid: pid_t, ppid: pid_t = claudePid, responsible: pid_t = claudePid, name: String = "node", arguments: [String] = ["node"],
    cpu: Double = 0, memory: UInt64 = 10_000_000, net: Double = 0, ports: [UInt16] = [], start: Date = Date(timeIntervalSince1970: 1)
) -> ProcessSample {
    var sample = ProcessSample(
        id: "\(pid)@1", pid: pid, ppid: ppid, responsiblePid: responsible, uid: getuid(), name: name, path: "/usr/local/bin/\(name)",
        arguments: arguments, startTime: start, cpuPercent: cpu, memoryBytes: memory, energyWatts: 0, diskReadBps: 0, diskWriteBps: 0,
        netInBps: net, netOutBps: 0, gpuPercent: 0, threads: 1, isApproximate: false, isSuspended: false
    )
    sample.listeningPorts = ports
    return sample
}

private func group(_ id: String, project: String? = nil, bundle: String? = nil, name: String? = nil, _ members: [(ProcessSample, String)]) -> AppGroup {
    let processes = members.map { GroupedProcess(sample: $0.0, title: $0.1, subtitle: nil) }
    return AppGroup(
        id: id, name: name ?? id, kind: bundle == nil ? .background : .apps, bundlePath: bundle, runtime: bundle == nil ? .node : nil,
        mainPid: nil, processes: processes, metrics: processes.reduce(Metrics()) { $0 + Metrics($1.sample) }, project: project
    )
}

private let claude = group("bundle:claude", bundle: "/Applications/Claude.app", name: "Claude", [(proc(claudePid, ppid: 1, responsible: claudePid, name: "Claude"), "Claude")])

private func report(_ groups: [AppGroup], ledger: ActivityLedger = ActivityLedger()) -> ProjectReport {
    ProjectInsights.report(groups: [claude] + groups, ledger: ledger, selfPid: herdPid)
}

private func ledger(idle: [pid_t: TimeInterval], now: Date = Date(timeIntervalSince1970: 100_000)) -> ActivityLedger {
    let entries = Dictionary(uniqueKeysWithValues: idle.map { pid, seconds in
        ("\(pid)@1", ActivityLedger.Entry(firstSeen: now.addingTimeInterval(-seconds - 1), lastActive: now.addingTimeInterval(-seconds)))
    })
    return ActivityLedger(date: now, entries: entries)
}

@Suite struct DuplicateDetectionTests {
    @Test func normalizesScopeVersionAndCase() {
        #expect(ProjectInsights.normalizedName("@Playwright/MCP@1.2.3") == "mcp")
        #expect(ProjectInsights.normalizedName("playwright-mcp@latest") == "playwright-mcp")
        #expect(ProjectInsights.normalizedName("Context7-MCP") == "context7-mcp")
    }

    @Test func groupsCopiesAcrossRuntimeGroupsAndNeedsTwo() throws {
        let result = report([
            group("runtime:Node.js|claude", [(proc(100), "context7-mcp"), (proc(102), "desktop-commander")]),
            group("project:/Users/x/app", project: "/Users/x/app", [(proc(101, memory: 20_000_000), "Context7-MCP@1.0")]),
        ])
        let set = try #require(result.duplicates.first)
        #expect(result.duplicates.count == 1)
        #expect(set.key == "context7-mcp")
        #expect(set.copies.map(\.root.pid).sorted() == [100, 101])
        #expect(set.totalMemory == 30_000_000)
        #expect(set.copies.allSatisfy { $0.launcher?.name == "Claude" })
        #expect(set.copies.first { $0.root.pid == 101 }?.projectName == "app")
    }

    @Test func foldsAnNpxWrapperAndItsServerIntoOneCopy() throws {
        let result = report([
            group("runtime:Node.js|claude", [
                (proc(200, arguments: ["npm exec @playwright/mcp@latest", "", ""]), "@playwright/mcp"),
                (proc(201, ppid: 200), "playwright-mcp"),
                (proc(300), "playwright-mcp"),
            ]),
        ])
        let set = try #require(result.duplicates.first)
        #expect(set.copies.count == 2)
        let wrapped = try #require(set.copies.first { $0.root.pid == 200 })
        #expect(wrapped.title == "playwright-mcp")
        #expect(wrapped.members.map(\.sample.pid) == [200, 201])
        #expect(wrapped.memory == 20_000_000)
    }
}

@Suite struct OrphanDetectionTests {
    @Test func requiresADeadResponsibleProcess() {
        let result = report([
            group("runtime:Python", [
                (proc(400, ppid: 1, responsible: 999, name: "python3"), "notebooklm-mcp"),
                (proc(401, ppid: 1, responsible: 401, name: "python3"), "agent"),
                (proc(402, ppid: 1, responsible: claudePid, name: "python3"), "helper"),
            ]),
        ])
        #expect(result.orphans.map(\.root.pid) == [400])
        #expect(result.orphans.first?.launcher == nil)
    }

    @Test func launchdAgentsWithLiveOrSelfResponsibleAreNotOrphans() {
        let live: Set<pid_t> = [claudePid, 500]
        #expect(!ProjectInsights.isOrphan(proc(500, ppid: 1, responsible: 500), livePids: live))
        #expect(!ProjectInsights.isOrphan(proc(501, ppid: 1, responsible: claudePid), livePids: live))
        #expect(ProjectInsights.isOrphan(proc(502, ppid: 1, responsible: 998), livePids: live))
        #expect(ProjectInsights.isOrphan(proc(503, ppid: 40, responsible: 998), livePids: live))
    }
}

@Suite struct IdleTrackingTests {
    @Test func measuresQuietTimeSinceLastActivityAndDropsExitedProcesses() {
        let start = Date(timeIntervalSince1970: 1_000)
        let first = ActivityLedger().recording([proc(1, cpu: 5), proc(2), proc(3, net: 4_096)], at: start)
        let later = first.recording([proc(1), proc(2), proc(3)], at: start.addingTimeInterval(600))
        #expect(later.idle("1@1") == 600)
        #expect(later.idle("2@1") == 600)
        #expect(later.idle("3@1") == 600)
        let latest = later.recording([proc(1, cpu: 0.6), proc(4)], at: start.addingTimeInterval(900))
        #expect(latest.idle("1@1") == 0)
        #expect(latest.idle("4@1") == 0)
        #expect(latest.idle("2@1") == nil)
        #expect(latest.entries["4@1"]?.firstSeen == start.addingTimeInterval(900))
    }

    @Test func belowThresholdActivityStaysIdle() {
        #expect(!ActivityLedger.isActive(proc(1, cpu: 0.4, net: 1_000)))
        #expect(ActivityLedger.isActive(proc(1, cpu: 0.5)))
        #expect(ActivityLedger.isActive(proc(1, net: 1_024)))
    }

    @Test func projectIdleIsTheQuietestTimeAcrossItsProcesses() throws {
        let project = group("project:/Users/x/web", project: "/Users/x/web", [
            (proc(10, ports: [3000], start: Date(timeIntervalSince1970: 50)), "vite"),
            (proc(11, name: "python3", ports: [8000, 3000], start: Date(timeIntervalSince1970: 20)), "api.py"),
        ])
        let summary = try #require(report([project], ledger: ledger(idle: [10: 4_000, 11: 120])).projects.first)
        #expect(summary.idle == 120)
        #expect(summary.ports == [3000, 8000])
        #expect(summary.runtimes == [.node, .python])
        #expect(summary.oldestStart == Date(timeIntervalSince1970: 20))
        #expect(summary.name == "web")
        #expect(summary.launchers.map(\.name) == ["Claude"])
        #expect(!summary.isUnowned)
    }

    @Test func formatsCompactDurations() {
        #expect(ProjectInsights.compactDuration(30) == "<1m")
        #expect(ProjectInsights.compactDuration(12 * 60) == "12m")
        #expect(ProjectInsights.compactDuration(3 * 3_600 + 1_200) == "3h")
        #expect(ProjectInsights.compactDuration(50 * 3_600) == "2d")
    }
}

@Suite struct SafeToStopTests {
    private let copies = group("runtime:Node.js|claude", [
        (proc(600), "context7-mcp"),
        (proc(601), "context7-mcp"),
        (proc(602, ppid: 1, responsible: 999), "context7-mcp"),
        (proc(603, ppid: herdPid, responsible: 999), "context7-mcp"),
        (proc(604, ppid: 1, responsible: 999, name: "launchd"), "context7-mcp"),
    ])

    @Test func stopsOrphansAndLongIdleCopiesOnly() throws {
        let result = report([copies], ledger: ledger(idle: [600: 31 * 60, 601: 10 * 60, 602: 0, 603: 0, 604: 0]))
        let set = try #require(result.duplicates.first)
        let safe = Set(set.copies.filter(\.isSafeToStop).map(\.root.pid))
        #expect(safe == [600, 602])
        #expect(result.leftovers.map(\.root.pid).sorted() == [600, 602])
        #expect(result.reclaimableMemory == 20_000_000)
    }

    @Test func neverOffersHerdsOwnOrProtectedProcesses() throws {
        let result = report([copies], ledger: ledger(idle: [603: 7_200, 604: 7_200]))
        let byPid = Dictionary(uniqueKeysWithValues: try #require(result.duplicates.first).copies.map { ($0.root.pid, $0) })
        #expect(byPid[603]?.isProtected == true)
        #expect(byPid[604]?.isProtected == true)
        #expect(byPid[603]?.isSafeToStop == false)
        #expect(byPid[604]?.isSafeToStop == false)
    }

    @Test func catchAllsAreUnownedAndCantBeStoppedAsAGroup() throws {
        let unowned = try #require(report([copies]).unowned.first)
        #expect(unowned.isUnowned)
        #expect(!unowned.isSafeQuitTarget)
    }
}
