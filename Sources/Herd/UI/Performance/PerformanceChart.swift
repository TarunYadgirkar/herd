import Charts
import SwiftUI

struct PerformanceChart: View {
    let title: String
    let series: [ChartSeries]
    let unit: ChartUnit
    let context: PerformanceContext
    var yDomain: ClosedRange<Double>?
    var includesZero = true
    var height: CGFloat = 200

    var body: some View {
        ChartCard(title: title, legend: series.count > 1 ? series.map(LegendItem.init) : []) {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if context.isCollecting {
            ChartMessage(text: PerformanceCopy.collecting, height: height)
        } else if !series.contains(where: \.hasData) {
            ChartMessage(text: PerformanceCopy.unavailable, height: height)
        } else {
            PlotView(
                plots: series.map { SeriesPlot(series: $0, points: $0.plotPoints(dates: context.dates)) },
                unit: unit, context: context, yDomain: yDomain, includesZero: includesZero
            )
            .frame(height: height)
            .accessibilityLabel(title)
            .accessibilityValue(accessibilitySummary)
        }
    }

    private var accessibilitySummary: String {
        series.compactMap { item in
            guard let latest = item.latest else { return nil }
            let peak = item.peak.map { ", peak \(unit.value($0))" } ?? ""
            return "\(item.name) \(unit.value(latest))\(peak)"
        }
        .joined(separator: ". ") + " over the last \(context.historyRange.title)"
    }
}

struct SeriesPlot: Identifiable {
    let series: ChartSeries
    let points: [PlotPoint]

    var id: String { series.id }

    var fillStyle: AnyShapeStyle? {
        switch series.fill {
        case .none:
            return nil
        case .solid(let opacity):
            return AnyShapeStyle(series.color.opacity(opacity))
        case .gradient:
            let isBelow = series.direction < 0
            return AnyShapeStyle(LinearGradient(
                colors: [series.color.opacity(ChartPalette.gradientTopOpacity), series.color.opacity(0)],
                startPoint: isBelow ? .bottom : .top,
                endPoint: isBelow ? .top : .bottom
            ))
        }
    }
}

private struct PlotView: View {
    let plots: [SeriesPlot]
    let unit: ChartUnit
    let context: PerformanceContext
    let yDomain: ClosedRange<Double>?
    let includesZero: Bool

    private static let calloutGap: CGFloat = 8

    var body: some View {
        let ticks = yTicks
        let selected = context.selectedIndex
        Chart {
            ForEach(plots) { SeriesMarks(plot: $0) }
            if let selected {
                RuleMark(x: .value("Time", context.dates[selected]))
                    .foregroundStyle(ChartPalette.rule)
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXScale(domain: context.xDomain)
        .chartYScale(domain: yDomain ?? ((ticks.first ?? 0)...(ticks.last ?? 1)))
        .chartXAxis { xAxis }
        .chartYAxis { yAxis(ticks) }
        .chartLegend(.hidden)
        .chartOverlay { proxy in overlay(proxy, selected: selected) }
    }

    private var yTicks: [Double] {
        if let yDomain {
            return AxisTicks.values(lower: yDomain.lowerBound, upper: yDomain.upperBound, isBinary: isBinary).filter(yDomain.contains)
        }
        let values = plots.flatMap { plot in plot.points.flatMap { plot.fillStyle == nil ? [$0.high] : [$0.low, $0.high] } }
        let lower = includesZero ? min(values.min() ?? 0, 0) : (values.min() ?? 0)
        let upper = includesZero ? max(values.max() ?? 0, 0) : (values.max() ?? 0)
        return AxisTicks.values(lower: lower, upper: upper, isBinary: isBinary)
    }

    private var isBinary: Bool {
        switch unit {
        case .bytes, .rate: true
        default: false
        }
    }

    private var xAxis: some AxisContent {
        let anchor = context.anchor
        let range = context.historyRange
        return AxisMarks(values: TimeAxis.ticks(anchor: anchor, range: range)) { value in
            AxisGridLine().foregroundStyle(ChartPalette.grid)
            AxisValueLabel(anchor: labelAnchor(for: value), collisionResolution: .greedy) {
                if let date = value.as(Date.self) {
                    Text(TimeAxis.label(for: date, anchor: anchor, range: range)).font(.metricSmall)
                }
            }
        }
    }

    // Ticks on the plot edges would be clipped with a centered label, so they hang inward instead.
    private func labelAnchor(for value: AxisValue) -> UnitPoint {
        guard let date = value.as(Date.self) else { return .top }
        let domain = context.xDomain
        if abs(date.timeIntervalSince(domain.upperBound)) < 1 { return .topTrailing }
        if abs(date.timeIntervalSince(domain.lowerBound)) < 1 { return .topLeading }
        return .top
    }

    private func yAxis(_ ticks: [Double]) -> some AxisContent {
        AxisMarks(position: .leading, values: ticks) { value in
            AxisGridLine().foregroundStyle(ChartPalette.grid)
            AxisValueLabel {
                if let number = value.as(Double.self) {
                    Text(unit.axis(number)).font(.metricSmall)
                }
            }
        }
    }

    private func overlay(_ proxy: ChartProxy, selected: Int?) -> some View {
        GeometryReader { geometry in
            let plotFrame = proxy.plotFrame.map { geometry[$0] } ?? CGRect(origin: .zero, size: geometry.size)
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in hover(phase, proxy: proxy, plotFrame: plotFrame) }
                if let selected, let x = proxy.position(forX: context.dates[selected]) {
                    callout(at: selected)
                        .modifier(CalloutPlacement(x: plotFrame.minX + x, width: geometry.size.width, top: plotFrame.minY, gap: Self.calloutGap))
                }
            }
        }
    }

    // Only write when the nearest sample changes, so moving the pointer within one sample doesn't redraw every chart.
    private func hover(_ phase: HoverPhase, proxy: ChartProxy, plotFrame: CGRect) {
        guard case .active(let location) = phase else {
            context.selection.wrappedValue = nil
            return
        }
        guard let date: Date = proxy.value(atX: location.x - plotFrame.minX),
              let index = SeriesMath.nearestIndex(in: context.dates, to: date, tolerance: context.gapLimit) else {
            if context.selection.wrappedValue != nil { context.selection.wrappedValue = nil }
            return
        }
        let snapped = context.dates[index]
        if context.selection.wrappedValue != snapped { context.selection.wrappedValue = snapped }
    }

    private func callout(at index: Int) -> some View {
        ChartCallout(
            time: TimeAxis.calloutLabel(for: context.dates[index], anchor: context.anchor, range: context.historyRange),
            rows: plots.compactMap { plot in
                plot.series.calloutValue(at: index).map { CalloutRow(name: plot.series.name, color: plot.series.color, value: unit.value($0)) }
            }
        )
    }
}

private struct SeriesMarks: ChartContent {
    let plot: SeriesPlot

    var body: some ChartContent {
        if let fill = plot.fillStyle {
            AreaPlot(
                plot.points,
                x: .value("Time", \.date),
                yStart: .value("Low", \.low),
                yEnd: .value("High", \.high),
                series: .value("Series", \.series)
            )
            .foregroundStyle(fill)
            .interpolationMethod(.monotone)
        }
        if plot.series.lineWidth > 0 {
            LinePlot(plot.points, x: .value("Time", \.date), y: .value("Value", \.high), series: .value("Series", \.series))
                .foregroundStyle(plot.series.color)
                .lineStyle(StrokeStyle(lineWidth: plot.series.lineWidth, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
        }
    }
}

private struct CalloutPlacement: ViewModifier {
    let x: CGFloat
    let width: CGFloat
    let top: CGFloat
    let gap: CGFloat

    func body(content: Content) -> some View {
        let isLeading = x < width / 2
        content
            .fixedSize()
            .padding(.leading, isLeading ? x + gap : 0)
            .padding(.trailing, isLeading ? 0 : max(width - x + gap, 0))
            .frame(width: width, alignment: isLeading ? .leading : .trailing)
            .padding(.top, top + 4)
            .allowsHitTesting(false)
    }
}
