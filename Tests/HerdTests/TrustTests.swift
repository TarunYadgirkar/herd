import Darwin
import Foundation
import Testing
@testable import Herd

private func sample(pid: pid_t, name: String, path: String, arguments: [String], cwd: String?, startTime: Date? = Date(timeIntervalSince1970: 1)) -> ProcessSample {
    ProcessSample(
        id: "\(pid)", pid: pid, ppid: 1, responsiblePid: pid, uid: getuid(), name: name, path: path, arguments: arguments,
        startTime: startTime, cpuPercent: 50, memoryBytes: 1_000_000, energyWatts: 2, diskReadBps: 0, diskWriteBps: 0,
        netInBps: 1_000, netOutBps: 0, gpuPercent: 0, threads: 1, isApproximate: false, isSuspended: false, workingDirectory: cwd
    )
}

private func makeProject(_ root: URL, marker: String) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: root.appending(path: marker).path, contents: Data())
}

@Suite struct ProjectOwnershipTests {
    private let home = FileManager.default.temporaryDirectory.appending(path: "herd-home-\(UUID().uuidString)")

    @Test func splitsUnrelatedNodeJobsByProject() throws {
        let web = home.appending(path: "code/web")
        let api = home.appending(path: "code/api")
        try makeProject(web, marker: "package.json")
        try makeProject(api, marker: "package.json")
        let grouper = AppGrouper(projects: ProjectResolver(home: home.path))
        let groups = grouper.group([
            sample(pid: 10, name: "node", path: "/usr/local/bin/node", arguments: ["node", "server.js"], cwd: web.path),
            sample(pid: 11, name: "node", path: "/usr/local/bin/node", arguments: ["node", "\(api.path)/src/index.js"], cwd: "/"),
            sample(pid: 12, name: "node", path: "/usr/local/bin/node", arguments: ["node", "worker.js"], cwd: web.appending(path: "jobs").path),
        ], regularAppPids: [])
        let byProject = Dictionary(uniqueKeysWithValues: groups.compactMap { group in group.project.map { ($0, group) } })
        #expect(byProject[web.path]?.pids.sorted() == [10, 12])
        #expect(byProject[api.path]?.pids == [11])
        #expect(groups.allSatisfy { $0.isSafeQuitTarget })
    }

    @Test func leavesProcessesWithoutAProjectInACatchAllThatCantBeQuitAsAGroup() throws {
        let grouper = AppGrouper(projects: ProjectResolver(home: home.path))
        let groups = grouper.group([
            sample(pid: 20, name: "python3", path: "/usr/bin/python3", arguments: ["python3", "-c", "pass"], cwd: "/"),
            sample(pid: 21, name: "python3", path: "/usr/bin/python3", arguments: ["python3"], cwd: "/tmp"),
        ], regularAppPids: [])
        let catchAll = try #require(groups.first { $0.id == "runtime:Python" })
        #expect(catchAll.project == nil)
        #expect(!catchAll.isSafeQuitTarget)
        #expect(!ProcessActions.canAct(on: catchAll, action: .quit))
        #expect(ProcessActions.canAct(on: catchAll, action: .resume))
    }

    @Test func ignoresInstalledToolingWhenFindingTheProject() throws {
        let app = home.appending(path: "code/app")
        try makeProject(app, marker: "pyproject.toml")
        let resolver = ProjectResolver(home: home.path)
        let tool = sample(pid: 30, name: "node", path: "/usr/local/bin/node", arguments: ["node", "\(home.path)/.npm/_npx/abc/node_modules/.bin/mcp"], cwd: app.path)
        #expect(resolver.project(for: tool) == app.path)
    }
}

@Suite struct MeasuredTimeTests {
    @MainActor @Test func dailyTotalsUseElapsedTimeAndCapRatesAcrossGaps() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "herd-archive-\(UUID().uuidString)")
        let archive = HistoryArchive(directory: directory)
        let grouper = AppGrouper(projects: ProjectResolver(home: "/nonexistent"))
        let groups = grouper.group([sample(pid: 40, name: "tool", path: "/Users/x/bin/tool", arguments: ["tool"], cwd: nil)], regularAppPids: [])
        archive.record(SystemSnapshot(), groups: groups, elapsed: 30, rateWindow: 6, at: Date())
        let usage = try #require(archive.appUsageToday.first)
        #expect(abs(usage.cpuSeconds - 15) < 0.001)
        #expect(abs(usage.energyWattHours - 2.0 * 30 / 3_600) < 0.000_001)
        #expect(abs(usage.networkBytes - 6_000) < 0.001)
    }
}

@Suite(.serialized) struct PauseRecoveryTests {
    @Test func resumesProcessesHerdPausedWhenAskedToRecover() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate() }
        let pid = child.processIdentifier
        let kernel = try #require(KernelProcessList.process(pid))
        let target = sample(pid: pid, name: "sleep", path: "/bin/sleep", arguments: ["sleep", "30"], cwd: nil, startTime: kernel.startTime)
        #expect(ProcessActions.perform(.suspend, on: target).succeeded == 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(KernelProcessList.process(pid)?.isStopped == true)
        #expect(PauseLedger.resumeAll() == 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(KernelProcessList.process(pid)?.isStopped == false)
    }
}
