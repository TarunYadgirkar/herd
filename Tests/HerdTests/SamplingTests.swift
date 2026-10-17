import Foundation
import Testing
@testable import Herd

@Suite struct SeriesTests {
    @Test func keepsTheNewestValuesInOrderOnceFull() {
        var series = Series(capacity: 3)
        for value in 1...5 { series.append(Double(value)) }
        #expect(series.values == [3, 4, 5])
        #expect(series.latest == 5)
        #expect(series.peak == 5)
    }

    @Test func resizingKeepsTheNewestValues() {
        var series = Series(capacity: 4)
        for value in 1...6 { series.append(Double(value)) }
        series.resize(to: 2)
        #expect(series.values == [5, 6])
        series.resize(to: 5)
        series.append(7)
        #expect(series.values == [5, 6, 7])
        #expect(series.capacity == 5)
    }

    @Test func emptySeriesReadsZero() {
        let series = Series(capacity: 10)
        #expect(series.values.isEmpty)
        #expect(series.latest == 0)
        #expect(series.peak == 0)
    }
}

@Suite(.serialized) struct FirstSampleTests {
    @Test func countsCPUOfAProcessOnTheFirstTickItIsSeen() async throws {
        let sampler = ProcessSampler()
        _ = sampler.sample()
        let busy = Process()
        busy.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        busy.standardOutput = FileHandle.nullDevice
        try busy.run()
        defer { busy.terminate() }
        try await Task.sleep(for: .milliseconds(400))
        let seen = try #require(sampler.sample().first { $0.pid == busy.processIdentifier })
        #expect(seen.cpuPercent > 5)
    }
}
