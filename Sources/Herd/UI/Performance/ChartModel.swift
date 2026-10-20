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
    var breaksAtMissingValues = false

    var id: String { name }

    var hasData: Bool { values.lazy.compactMap { $0 }.prefix(2).count == 2 }
    var latest: Double? { values.last { $0 != nil } ?? nil }
    var peak: Double? { values.compactMap { $0 }.max() }

    // Each contiguous run gets its own series key, so Swift Charts breaks the line across gaps instead of bridging them.
    func plotPoints(dates: [Date], segments: [Int]) -> [PlotPoint] {
        var run = 0
        return zip(dates, values).enumerated().compactMap { index, pair in
            guard let value = pair.1 else {
                if breaksAtMissingValues { run += 1 }
                return nil
            }
            let low = baseline?[index] ?? 0
            return PlotPoint(date: pair.0, low: low * direction, high: (low + value) * direction, series: "\(name)#\(segments[index]).\(run)")
        }
    }

    func calloutValue(at index: Int) -> Double? {
        guard values.indices.contains(index), let value = values[index] else { return nil }
        if hidesZeroInCallout && value == 0 { return nil }
        return value
    }
}

enum ContributorMetric {
    case cpu
    case memory
    case energy

    private static let calloutLimit = 3

    func value(_ contributor: Contributor) -> Double {
        switch self {
        case .cpu: contributor.cpu
        case .memory: Double(contributor.memory)
        case .energy: contributor.energy
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .cpu: Format.percent(value)
        case .memory: PerformanceFormat.bytes(value)
        case .energy: Format.watts(value)
        }
    }

    func leaders(_ contributors: [Contributor]) -> [CalloutApp] {
        contributors
            .filter { value($0) > 0 }
            .sorted { value($0) > value($1) }
            .prefix(Self.calloutLimit)
            .map { CalloutApp(id: $0.id, name: $0.name, bundlePath: $0.bundlePath, value: format(value($0))) }
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

    // Beyond the tolerance the pointer is past the data or inside a gap, where no sample describes that moment.
    static func nearestIndex(in dates: [Date], to target: Date, tolerance: TimeInterval) -> Int? {
        guard !dates.isEmpty else { return nil }
        var low = 0
        var high = dates.count - 1
        while low < high {
            let mid = (low + high) / 2
            if dates[mid] < target { low = mid + 1 } else { high = mid }
        }
        let nearest = low > 0 && target.timeIntervalSince(dates[low - 1]) < dates[low].timeIntervalSince(target) ? low - 1 : low
        return abs(dates[nearest].timeIntervalSince(target)) <= tolerance ? nearest : nil
    }
}
