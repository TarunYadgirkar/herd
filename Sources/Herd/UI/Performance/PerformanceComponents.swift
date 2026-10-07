import SwiftUI

struct PerformanceCard<Accessory: View, Content: View>: View {
    let title: String
    var help: String?
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.itemSpacing) {
                Text(title)
                    .font(.headline)
                    .help(help ?? "")
                Spacer(minLength: Theme.groupSpacing)
                accessory
            }
            content
        }
        .padding(Theme.innerPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}

extension PerformanceCard where Accessory == EmptyView {
    init(title: String, help: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, help: help, accessory: { EmptyView() }, content: content)
    }
}

struct ChartCard<Content: View>: View {
    let title: String
    var help: String?
    let legend: [LegendItem]
    @ViewBuilder let content: Content

    var body: some View {
        PerformanceCard(title: title, help: help) {
            ChartLegend(items: legend)
        } content: {
            content
        }
    }
}

struct LegendItem: Identifiable {
    let name: String
    let color: Color

    var id: String { name }

    init(name: String, color: Color) {
        self.name = name
        self.color = color
    }

    init(_ series: ChartSeries) {
        self.init(name: series.name, color: series.color)
    }
}

struct ChartLegend: View {
    let items: [LegendItem]

    var body: some View {
        HStack(spacing: Theme.groupSpacing - 4) {
            ForEach(items) { item in
                HStack(spacing: 5) {
                    Swatch(color: item.color)
                    Text(item.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct Swatch: View {
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color)
            .frame(width: 8, height: 8)
    }
}

struct ChartMessage: View {
    let text: String
    let height: CGFloat

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }
}

struct CalloutRow: Identifiable {
    let name: String
    let color: Color
    let value: String

    var id: String { name }
}

struct ChartCallout: View {
    let time: String
    let rows: [CalloutRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(time)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: Theme.itemSpacing, verticalSpacing: 2) {
                ForEach(rows) { row in
                    GridRow {
                        HStack(spacing: 5) {
                            Swatch(color: row.color)
                            Text(row.name).font(.caption).fixedSize()
                        }
                        Text(row.value)
                            .font(.metricSmall)
                            .fixedSize()
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
        }
        .padding(Theme.itemSpacing)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: Theme.shadow, radius: 6, y: 2)
    }
}

struct PerformanceStat: Identifiable {
    let label: String
    let value: String
    var help: String?

    var id: String { label }
}

struct StatGrid: View {
    let stats: [PerformanceStat]

    private static let columnWidth: CGFloat = 120

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: Self.columnWidth), spacing: Theme.groupSpacing, alignment: .topLeading)],
            alignment: .leading,
            spacing: Theme.itemSpacing
        ) {
            ForEach(stats) { stat in
                VStack(alignment: .leading, spacing: 2) {
                    Text(stat.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(stat.value)
                        .font(.metric)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .help(stat.help ?? "")
                .accessibilityElement(children: .combine)
            }
        }
    }
}

struct PerformanceHeader<Badge: View>: View {
    let title: String
    let value: String
    let caption: String
    let stats: [PerformanceStat]
    let range: Binding<HistoryRange>
    @ViewBuilder let badge: Badge

    private static var headlineWidth: CGFloat { 180 }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.itemSpacing) {
                Text(title)
                    .font(.title2.weight(.semibold))
                badge
                Spacer(minLength: Theme.groupSpacing)
                RangePicker(range: range)
            }
            HStack(alignment: .top, spacing: Theme.groupSpacing) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(value)
                        .font(.display)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(caption)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minWidth: Self.headlineWidth, alignment: .leading)
                .accessibilityElement(children: .combine)
                StatGrid(stats: stats)
            }
        }
    }
}

extension PerformanceHeader where Badge == EmptyView {
    init(title: String, value: String, caption: String, stats: [PerformanceStat], range: Binding<HistoryRange>) {
        self.init(title: title, value: value, caption: caption, stats: stats, range: range, badge: { EmptyView() })
    }
}

struct RangePicker: View {
    let range: Binding<HistoryRange>

    var body: some View {
        Picker("Time range", selection: range) {
            ForEach(HistoryRange.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Choose how much history the graphs show")
    }
}

struct SectionMessage: View {
    let title: String
    let symbol: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}
