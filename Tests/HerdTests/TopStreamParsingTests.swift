import Testing
@testable import Herd

@Suite struct TopStreamParsingTests {
    @Test func parsesKernelRowWithThreadFractionAndTrendMarkers() {
        let row = TopStream.parseRow("0      15.3 1025/15 12:15:10 38M-   0.0   14084110+")
        #expect(row == TopStream.Row(pid: 0, cpuPercent: 15.3, threads: 1025, cpuSeconds: 12 * 3600 + 15 * 60 + 10,
                                     footprint: 38 << 20, power: 0, idleWakeups: 14_084_110))
    }

    @Test func parsesShortLivedProcess() {
        let row = TopStream.parseRow("91614  8.8  1/1     00:01.21 8304K+ 8.8   0")
        #expect(row?.pid == 91614)
        #expect(row?.threads == 1)
        #expect(row?.cpuSeconds == 1.21)
        #expect(row?.footprint == 8304 << 10)
        #expect(row?.idleWakeups == 0)
    }

    @Test func foldsHoursSuffixIntoClock() {
        let row = TopStream.parseRow("1116   3.5  8       25 hrs 162M-  3.5   201634+")
        #expect(row?.cpuSeconds == 90_000.0)
        #expect(row?.threads == 8)
    }

    @Test func rejectsHeaderAndMalformedLines() {
        #expect(TopStream.parseRow("PID    %CPU #TH     TIME     MEM    POWER IDLEW") == nil)
        #expect(TopStream.parseRow("614    12.2 26      12:09:42 917M+") == nil)
        #expect(TopStream.parseRow("abc    12.2 26      12:09:42 917M+  13.4  4403082+") == nil)
        #expect(TopStream.parseRow("") == nil)
    }

    @Test func parsesClockFormats() {
        #expect(TopStream.parseClock("00:01.21") == 1.21)
        #expect(TopStream.parseClock("24:26.97") == 1_466.97)
        #expect(TopStream.parseClock("03:23:17") == 12_197.0)
        #expect(TopStream.parseClock("garbage") == nil)
    }

    @Test func parsesByteUnits() {
        #expect(TopStream.parseRow("1 0.0 1 00:00.00 0B 0.0 0")?.footprint == 0)
        #expect(TopStream.parseRow("1 0.0 1 00:00.00 2G 0.0 0")?.footprint == 2 << 30)
        #expect(TopStream.parseRow("1 0.0 1 00:00.00 1.5T 0.0 0")?.footprint == UInt64(1.5 * Double(1 << 40)))
        #expect(TopStream.parseRow("1 0.0 1 00:00.00 12 0.0 0") == nil)
    }
}
