import Foundation
import Testing
@testable import Herd

private func group(_ name: String, cpu: Double, memory: UInt64, energy: Double = 0, path: String? = nil) -> AppGroup {
    var metrics = Metrics()
    metrics.cpu = cpu
    metrics.memory = memory
    metrics.energy = energy
    return AppGroup(
        id: "bundle:\(name)", name: name, kind: .apps, bundlePath: path, runtime: nil, mainPid: nil,
        processes: [], metrics: metrics, project: nil
    )
}

private func contributor(_ name: String, cpu: Double, memory: UInt64, energy: Double = 0) -> Contributor {
    Contributor(id: name, name: name, bundlePath: nil, cpu: cpu, memory: memory, energy: energy)
}

private func point(at seconds: TimeInterval, contributors: [Contributor]?) -> SystemPoint {
    var point = SystemPoint.empty(at: Date(timeIntervalSinceReferenceDate: seconds))
    point.contributors = contributors
    return point
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "herd-history-\(UUID().uuidString)")
}

@Suite struct ContributorTests {
    @Test func keepsTopThreeByCPUAndTopThreeByMemory() {
        let candidates = [
            contributor("a", cpu: 90, memory: 1),
            contributor("b", cpu: 80, memory: 2),
            contributor("c", cpu: 70, memory: 900),
            contributor("d", cpu: 60, memory: 800),
            contributor("e", cpu: 50, memory: 700),
            contributor("f", cpu: 40, memory: 3),
        ]
        #expect(Contributor.leaders(candidates).map(\.id) == ["a", "b", "c", "d", "e"])
    }

    @MainActor @Test func recordsLeadersForEachRawSample() throws {
        let archive = HistoryArchive(directory: temporaryDirectory())
        let groups = [
            group("Safari", cpu: 120, memory: 2_000, path: "/Applications/Safari.app"),
            group("Xcode", cpu: 80, memory: 9_000),
            group("Slack", cpu: 5, memory: 8_000),
            group("Music", cpu: 40, memory: 100),
            group("Notes", cpu: 1, memory: 7_000),
            group("Idle", cpu: 0, memory: 10),
        ]
        archive.record(SystemSnapshot(), groups: groups, elapsed: 2, rateWindow: 2, at: Date())
        let recorded = try #require(archive.points(in: .minute).last?.contributors)
        #expect(recorded.map(\.name) == ["Safari", "Xcode", "Music", "Slack", "Notes"])
        #expect(recorded.first?.bundlePath == "/Applications/Safari.app")
        #expect(recorded.first?.cpu == 120)
    }

    @MainActor @Test func leavesContributorsUnknownWithoutGroups() {
        let archive = HistoryArchive(directory: temporaryDirectory())
        archive.record(SystemSnapshot(), groups: [], elapsed: 2, rateWindow: 2, at: Date())
        #expect(archive.points(in: .minute).last?.contributors == nil)
    }

    @Test func averagesCPUAndEnergyOverTheBucketAndKeepsPeakMemory() throws {
        var tier = HistoryTier(resolution: 10, retention: 3_600)
        tier.add(point(at: 0, contributors: [contributor("burst", cpu: 90, memory: 100, energy: 3), contributor("steady", cpu: 20, memory: 500, energy: 1)]))
        tier.add(point(at: 3, contributors: [contributor("steady", cpu: 40, memory: 300, energy: 2)]))
        tier.add(point(at: 6, contributors: [contributor("steady", cpu: 30, memory: 400, energy: 3)]))
        tier.add(point(at: 10, contributors: []))
        let merged = try #require(tier.persisted().first?.contributors)
        let byID = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0) })
        #expect(byID["burst"]?.cpu == 30)
        #expect(byID["burst"]?.energy == 1)
        #expect(byID["steady"]?.cpu == 30)
        #expect(byID["steady"]?.energy == 2)
        #expect(byID["steady"]?.memory == 500)
    }

    @Test func trimsMergedBucketsToLeaders() throws {
        var tier = HistoryTier(resolution: 10, retention: 3_600)
        tier.add(point(at: 0, contributors: (0..<6).map { contributor("early\($0)", cpu: Double(10 + $0), memory: UInt64(100 + $0)) }))
        tier.add(point(at: 5, contributors: (0..<6).map { contributor("late\($0)", cpu: Double(50 + $0), memory: UInt64(1_000 + $0)) }))
        let merged = try #require(tier.partial?.contributors)
        #expect(merged.count == 3)
        #expect(Set(merged.map(\.id)) == ["late5", "late4", "late3"])
    }

    @Test func samplesWithoutContributorDataDontDiluteTheAverage() throws {
        var accumulator = PointAccumulator()
        accumulator.add(point(at: 0, contributors: nil))
        accumulator.add(point(at: 1, contributors: [contributor("app", cpu: 50, memory: 1)]))
        let merged = try #require(accumulator.average()?.contributors)
        #expect(merged.first?.cpu == 50)
        #expect(PointAccumulator().average() == nil)
    }
}

@Suite struct HistoryFileTests {
    @Test func decodesPointsSavedBeforeContributorsExisted() throws {
        let json = """
        {"date":700000000,"cpuUser":0.2,"cpuSystem":0.1,"memoryUsed":1,"appMemory":1,"wiredMemory":1,"compressedMemory":0,
        "cachedFiles":0,"swapUsed":0,"pressure":1,"gpu":0,"netIn":0,"netOut":0,"diskRead":0,"diskWrite":0,"cpuWatts":1.5}
        """
        let point = try JSONDecoder().decode(SystemPoint.self, from: Data(json.utf8))
        #expect(point.contributors == nil)
        #expect(point.cpuWatts == 1.5)
    }

    @MainActor @Test func restoresAnOldArchiveFile() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date().timeIntervalSinceReferenceDate
        let points = (1...5).map { index in
            """
            {"date":\(now - Double(index) * 120),"cpuUser":0.25,"cpuSystem":0.1,"memoryUsed":1,"appMemory":1,"wiredMemory":1,
            "compressedMemory":0,"cachedFiles":0,"swapUsed":0,"pressure":1,"gpu":0,"netIn":0,"netOut":0,"diskRead":0,"diskWrite":0}
            """
        }
        let file = """
        {"version":1,"minute":[],"hour":[\(points.joined(separator: ","))],"ledgerDay":\(now),"ledger":[]}
        """
        try Data(file.utf8).write(to: directory.appending(path: "history.json"))
        let restored = HistoryArchive(directory: directory).points(in: .day)
        #expect(restored.count == 5)
        #expect(restored.allSatisfy { $0.contributors == nil && $0.cpuUser == 0.25 })
    }

    @MainActor @Test func dayOfHistoryWithContributorsStaysSmall() throws {
        let directory = temporaryDirectory()
        let archive = HistoryArchive(directory: directory)
        let names = ["Google Chrome", "Xcode", "Slack", "Spotify", "WindowServer", "kernel_task", "node (web, Node)",
                     "Visual Studio Code", "Docker Desktop", "Microsoft Teams", "Finder", "Mail"]
        let groups = names.map { name in
            group(name, cpu: 0, memory: 0, path: "/Applications/Utilities/Long Folder Name/\(name).app")
        }
        let start = Date().addingTimeInterval(-86_400)
        let step: TimeInterval = 2
        for tick in 0..<Int(86_400 / step) {
            let varied = groups.enumerated().map { index, base in
                group(base.name, cpu: Double((tick * (index + 3)) % 397) / 3.7, memory: UInt64(((tick + index * 977) % 8_191) * 1_048_576),
                      energy: Double((tick * (index + 1)) % 113) / 17.3, path: base.bundlePath)
            }
            archive.record(SystemSnapshot(), groups: varied, elapsed: step, rateWindow: step, at: start.addingTimeInterval(Double(tick) * step))
        }
        archive.save(waitUntilWritten: true)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: directory.appending(path: "history.json").path)[.size] as? Int)
        print("24h history with contributors: \(size) bytes")
        #expect(size < 4_000_000)
    }
}

@Suite struct HistoryGapTests {
    private func dates(_ seconds: [TimeInterval]) -> [Date] {
        seconds.map { Date(timeIntervalSinceReferenceDate: $0) }
    }

    @Test func splitsWhereSpacingExceedsTheLimit() {
        let indices = HistoryGaps.segmentIndices(dates([0, 10, 20, 100, 110, 500, 501]), maxGap: 30)
        #expect(indices == [0, 0, 0, 1, 1, 2, 2])
    }

    @Test func keepsContiguousRunsIntact() {
        let even = dates(Array(stride(from: 0, to: 3_600, by: 10)))
        #expect(Set(HistoryGaps.segmentIndices(even, maxGap: 30)) == [0])
        #expect(HistoryGaps.segmentIndices(dates([0, 30, 60]), maxGap: 30) == [0, 0, 0])
        #expect(HistoryGaps.segmentIndices([], maxGap: 30).isEmpty)
    }

    @Test func limitIsThreeTimesTheTierSpacing() {
        #expect(HistoryGaps.limit(spacing: 10) == 30)
        #expect(HistoryGaps.limit(spacing: 120) == 360)
        #expect(HistoryGaps.limit(spacing: 120, stretch: 2) == 720)
        #expect(HistoryGaps.medianSpacing(dates([0, 5, 10, 15, 400, 405])) == 5)
        #expect(HistoryGaps.medianSpacing(dates([0])) == nil)
    }

    @MainActor @Test func rawWindowBreaksAcrossSleep() {
        let archive = HistoryArchive(directory: temporaryDirectory())
        let start = Date()
        let seconds: [TimeInterval] = [0, 5, 10, 15, 20, 120, 125, 130]
        for offset in seconds {
            archive.record(SystemSnapshot(), groups: [], elapsed: 5, rateWindow: 5, at: start.addingTimeInterval(offset))
        }
        let window = archive.window(in: .fiveMinutes)
        #expect(window.maxGap == 15)
        #expect(HistoryGaps.segmentIndices(window.points.map(\.date), maxGap: window.maxGap) == [0, 0, 0, 0, 0, 1, 1, 1])
    }
}

@Suite struct ChartHoverTests {
    @Test func hoverInsideAGapFindsNoSample() {
        let dates = [0.0, 10, 20, 400, 410].map { Date(timeIntervalSinceReferenceDate: $0) }
        let at = { (seconds: TimeInterval) in SeriesMath.nearestIndex(in: dates, to: Date(timeIntervalSinceReferenceDate: seconds), tolerance: 30) }
        #expect(at(12) == 1)
        #expect(at(45) == 2)
        #expect(at(200) == nil)
        #expect(at(395) == 3)
        #expect(at(-31) == nil)
        #expect(at(440) == 4)
        #expect(at(441) == nil)
    }
}
