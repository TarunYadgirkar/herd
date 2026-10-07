import SwiftUI

struct PerformanceContext {
    let system: SystemSnapshot
    let points: [SystemPoint]
    let dates: [Date]
    let range: Binding<HistoryRange>
    let selection: Binding<Date?>

    init(system: SystemSnapshot, points: [SystemPoint], range: Binding<HistoryRange>, selection: Binding<Date?>) {
        self.system = system
        self.points = points
        self.dates = points.map(\.date)
        self.range = range
        self.selection = selection
    }

    var historyRange: HistoryRange { range.wrappedValue }
    var anchor: Date { dates.last ?? .now }
    var xDomain: ClosedRange<Date> { anchor.addingTimeInterval(-historyRange.seconds)...anchor }
    var isCollecting: Bool { points.count < 2 }
    var gapLimit: TimeInterval { TimeAxis.gapLimit(for: historyRange) }

    var selectedIndex: Int? {
        guard let date = selection.wrappedValue else { return nil }
        return SeriesMath.nearestIndex(in: dates, to: date, tolerance: gapLimit)
    }

    func values(_ transform: (SystemPoint) -> Double?) -> [Double?] {
        points.map(transform)
    }

    func total(_ value: (SystemPoint) -> Double?) -> Double {
        SeriesMath.integrate(points, gapLimit: gapLimit, value: value)
    }

    func peak(_ value: (SystemPoint) -> Double?) -> Double? {
        points.compactMap(value).max()
    }
}

enum PerformanceCopy {
    static let collecting = "Collecting data. Graphs fill in as Herd runs."
    static let unavailable = "Not available on this Mac"
}
