import SwiftUI

struct PerformanceContext {
    let system: SystemSnapshot
    let points: [SystemPoint]
    let dates: [Date]
    let maxGap: TimeInterval
    let segments: [Int]
    let range: Binding<HistoryRange>
    let selection: Binding<Date?>

    init(system: SystemSnapshot, window: HistoryWindow, range: Binding<HistoryRange>, selection: Binding<Date?>) {
        self.system = system
        self.points = window.points
        self.dates = window.points.map(\.date)
        self.maxGap = window.maxGap
        self.segments = HistoryGaps.segmentIndices(dates, maxGap: window.maxGap)
        self.range = range
        self.selection = selection
    }

    var historyRange: HistoryRange { range.wrappedValue }
    var anchor: Date { dates.last ?? .now }
    var xDomain: ClosedRange<Date> { anchor.addingTimeInterval(-historyRange.seconds)...anchor }
    var isCollecting: Bool { points.count < 2 }

    var selectedIndex: Int? {
        guard let date = selection.wrappedValue else { return nil }
        return SeriesMath.nearestIndex(in: dates, to: date, tolerance: maxGap)
    }

    func values(_ transform: (SystemPoint) -> Double?) -> [Double?] {
        points.map(transform)
    }

    func total(_ value: (SystemPoint) -> Double?) -> Double {
        SeriesMath.integrate(points, gapLimit: maxGap, value: value)
    }

    func peak(_ value: (SystemPoint) -> Double?) -> Double? {
        points.compactMap(value).max()
    }
}

enum PerformanceCopy {
    static let collecting = "Collecting…"
    static let unavailable = "Unavailable"
}
