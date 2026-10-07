import SwiftUI

struct PlotPoint: Identifiable {
    let date: Date
    let low: Double
    let high: Double
    let series: String

    var id: Date { date }
}

struct ChartSeries: Identifiable {
    enum Fill {
        case none
        case gradient
        case solid(opacity: Double)
    }

    let name: String
    let color: Color
    let values: [Double?]
    var baseline: [Double]?
    var fill: Fill = .gradient
    var lineWidth: CGFloat = 1.5
    var direction: Double = 1
    var hidesZeroInCallout = false

    var id: String { name }

    var hasData: Bool { values.lazy.compactMap { $0 }.prefix(2).count == 2 }
    var latest: Double? { values.last { $0 != nil } ?? nil }
    var peak: Double? { values.compactMap { $0 }.max() }

    func plotPoints(dates: [Date]) -> [PlotPoint] {
        zip(dates, values).enumerated().compactMap { index, pair in
            guard let value = pair.1 else { return nil }
            let low = baseline?[index] ?? 0
            return PlotPoint(date: pair.0, low: low * direction, high: (low + value) * direction, series: name)
        }
    }

    func calloutValue(at index: Int) -> Double? {
        guard values.indices.contains(index), let value = values[index] else { return nil }
        if hidesZeroInCallout && value == 0 { return nil }
        return value
    }
}

struct ChartLayer {
    let name: String
    let color: Color
    let values: [Double]
}

extension ChartSeries {
    static func stacked(_ layers: [ChartLayer], opacity: Double = ChartPalette.stackedOpacity) -> [ChartSeries] {
        var running = Array(repeating: 0.0, count: layers.first?.values.count ?? 0)
        return layers.map { layer in
            let base = running
            running = zip(running, layer.values).map(+)
            return ChartSeries(
                name: layer.name, color: layer.color, values: layer.values.map { $0 },
                baseline: base, fill: .solid(opacity: opacity), lineWidth: 0
            )
        }
    }
}

enum SeriesMath {
    static func integrate(_ points: [SystemPoint], gapLimit: TimeInterval, value: (SystemPoint) -> Double?) -> Double {
        zip(points, points.dropFirst()).reduce(0) { total, pair in
            let elapsed = pair.1.date.timeIntervalSince(pair.0.date)
            guard elapsed > 0, elapsed <= gapLimit, let start = value(pair.0), let end = value(pair.1) else { return total }
            return total + (start + end) / 2 * elapsed
        }
    }

    static func nearestIndex(in dates: [Date], to target: Date, tolerance: TimeInterval) -> Int? {
        guard let first = dates.first, let last = dates.last else { return nil }
        guard target >= first.addingTimeInterval(-tolerance), target <= last.addingTimeInterval(tolerance) else { return nil }
        var low = 0
        var high = dates.count - 1
        while low < high {
            let mid = (low + high) / 2
            if dates[mid] < target { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return low }
        let before = target.timeIntervalSince(dates[low - 1])
        let after = dates[low].timeIntervalSince(target)
        return before < after ? low - 1 : low
    }
}
