import AppKit
import Charts
import SwiftUI

struct InspectorView: View {
    let groupID: String?
    let processID: String?

    @Environment(MonitorStore.self) private var store

    var body: some View {
        if let group = store.group(id: groupID) {
            InspectorContent(
                group: group,
                history: store.history(for: group.id),
                interval: store.interval.rawValue,
                highlightedID: processID
            )
        } else {
            InspectorEmptyState(hasQuit: groupID != nil)
        }
    }
}

private struct InspectorContent: View {
    let group: AppGroup
    let history: GroupHistory
    let interval: Double
    let highlightedID: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.groupSpacing) {
                    InspectorHeader(group: group)
                    if let explanation { ExplanationSection(text: explanation) }
                    LiveNumbersSection(group: group)
                    HistorySection(history: history, interval: interval)
                    ActionsRow(group: group)
                    ProcessListSection(group: group, highlightedID: highlightedID)
                }
                .padding(Theme.groupSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .task(id: highlightedID) { await reveal(highlightedID, with: proxy) }
        }
    }

    private var explanation: String? {
        if let byGroup = ProcessExplanations.explanation(for: group.name) { return byGroup }
        let main = group.processes.first { $0.sample.pid == group.mainPid } ?? group.processes.first
        return main.flatMap { ProcessExplanations.explanation(for: $0.sample.name) }
    }

    private func reveal(_ id: String?, with proxy: ScrollViewProxy) async {
        guard let id else { return }
        await Task.yield()
        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                if let detail { Text(detail).monospacedDigit() }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            content
        }
    }
}

private struct InspectorHeader: View {
    let group: AppGroup

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemSpacing) {
            HStack(alignment: .center, spacing: 12) {
                GroupIcon(group: group, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.title2.weight(.semibold))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        Text(summary).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        if group.isSuspended { StatePill(text: "Paused", color: Theme.warning) }
                    }
                }
            }
            if let path { PathRow(group: group, path: path) }
        }
    }

    private var summary: String {
        let count = group.processes.count
        return "\(kindTitle) · \(count) \(count == 1 ? "process" : "processes")"
    }

    private var kindTitle: String {
        switch group.kind {
        case .apps: "App"
        case .background: "Background"
        case .system: "macOS"
        }
    }

    private var path: String? {
        guard let path = group.bundlePath ?? group.executablePath, !path.isEmpty else { return nil }
        return path
    }
}

private struct PathRow: View {
    let group: AppGroup
    let path: String

    var body: some View {
        HStack(spacing: Theme.itemSpacing) {
            Text(ScriptLabel.abbreviate(path))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(path)
            Spacer(minLength: 0)
            Button("Show in Finder", systemImage: "folder") { ProcessActions.revealInFinder(group) }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Reveal this app's file in Finder")
        }
    }
}

private struct ExplanationSection: View {
    let text: String

    var body: some View {
        InspectorSection(title: "What is this?") {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

private struct LiveNumbersSection: View {
    let group: AppGroup

    private static let rows: [[MetricColumn]] = [[.cpu, .memory], [.energy, .gpu], [.network, .disk]]

    var body: some View {
        InspectorSection(title: "Right now", detail: "\(group.metrics.threads) threads") {
            Grid(horizontalSpacing: Theme.itemSpacing, verticalSpacing: Theme.itemSpacing) {
                ForEach(Self.rows, id: \.self) { row in
                    GridRow {
                        ForEach(row) { column in
                            MetricTile(column: column, value: column.value(group.metrics), isApproximate: isApproximate(column))
                        }
                    }
                }
            }
        }
    }

    private func isApproximate(_ column: MetricColumn) -> Bool {
        group.hasApproximateData && (column == .cpu || column == .memory)
    }
}

private struct MetricTile: View {
    let column: MetricColumn
    let value: Double
    let isApproximate: Bool

    var body: some View {
        let heat = column.heat(value)
        VStack(alignment: .leading, spacing: 2) {
            Label(column.title, systemImage: column.symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text((isApproximate ? "≈ " : "") + column.format(value))
                .font(.displaySmall)
                .foregroundStyle(heat > 0.85 ? Theme.hot : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, Theme.itemSpacing)
        .background(fill(heat), in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func fill(_ heat: Double) -> AnyShapeStyle {
        heat > 0 ? AnyShapeStyle(Theme.heatColor(heat).opacity(0.10 + heat * 0.22)) : AnyShapeStyle(.quaternary.opacity(0.6))
    }
}

private struct HistorySection: View {
    let history: GroupHistory
    let interval: Double

    var body: some View {
        InspectorSection(title: "Last 5 minutes") {
            VStack(alignment: .leading, spacing: Theme.groupSpacing) {
                HistoryChart(title: "CPU", values: history.cpu.values, interval: interval, minimumCeiling: 10, format: Format.percent)
                HistoryChart(title: "Memory", values: history.memory.values, interval: interval, minimumCeiling: 64_000_000) {
                    Format.bytes(UInt64(max($0, 0)))
                }
            }
        }
    }
}

private struct ChartPoint: Identifiable {
    let secondsAgo: Double
    let value: Double

    var id: Double { secondsAgo }
}

private struct HistoryChart: View {
    let title: String
    let values: [Double]
    let interval: Double
    let minimumCeiling: Double
    let format: (Double) -> String

    private static let window: Double = 300
    private static let height: CGFloat = 90
    private static let axisMarks: [Double] = [-300, -200, -100, 0]

    var body: some View {
        let points = self.points
        let peak = points.map(\.value).max() ?? 0
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Text("Peak \(format(peak))").font(.metricSmall).foregroundStyle(.secondary)
            }
            if points.count > 1 {
                chart(points, ceiling: max(peak * 1.15, minimumCeiling))
            } else {
                placeholder
            }
        }
    }

    private func chart(_ points: [ChartPoint], ceiling: Double) -> some View {
        Chart(points) { point in
            AreaMark(x: .value("Seconds ago", -point.secondsAgo), y: .value(title, point.value))
                .foregroundStyle(Theme.accent.opacity(0.18))
            LineMark(x: .value("Seconds ago", -point.secondsAgo), y: .value(title, point.value))
                .foregroundStyle(Theme.accent)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
        .chartXScale(domain: -Self.window...0)
        .chartYScale(domain: 0...ceiling)
        .chartXAxis { xAxis }
        .chartYAxis { yAxis }
        .frame(height: Self.height)
        .accessibilityLabel("\(title) over the last 5 minutes")
    }

    private var xAxis: some AxisContent {
        AxisMarks(values: Self.axisMarks) { value in
            AxisGridLine()
            AxisValueLabel {
                if let seconds = value.as(Double.self) {
                    Text(seconds == 0 ? "now" : "\(Int(-seconds))s").font(.caption2.monospacedDigit())
                }
            }
        }
    }

    private var yAxis: some AxisContent {
        AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
            AxisGridLine()
            AxisValueLabel {
                if let amount = value.as(Double.self) {
                    Text(format(amount)).font(.caption2.monospacedDigit())
                }
            }
        }
    }

    private var placeholder: some View {
        Text("Collecting samples")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, minHeight: Self.height)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    private var points: [ChartPoint] {
        guard interval > 0 else { return [] }
        let count = min(values.count, Int((Self.window / interval).rounded(.up)) + 1)
        let recent = values.suffix(count)
        return recent.enumerated().map { index, value in
            ChartPoint(secondsAgo: Double(count - 1 - index) * interval, value: value)
        }
    }
}

private struct ActionsRow: View {
    let group: AppGroup

    @Environment(ActionController.self) private var actions

    var body: some View {
        let canAct = ProcessActions.canAct(on: group, action: .quit)
        HStack(spacing: Theme.itemSpacing) {
            button(.quit, help: "Ask \(group.name) to quit normally")
                .buttonStyle(.bordered)
            button(.forceQuit, help: "Stop \(group.name) right away. Unsaved work is lost.")
                .buttonStyle(.bordered)
                .tint(Theme.critical)
            pauseButton
        }
        .disabled(!canAct)
        .help(canAct ? "" : "\(group.name) is part of macOS, so Herd won't stop it")
    }

    @ViewBuilder
    private var pauseButton: some View {
        if group.isSuspended {
            button(.resume, help: "Let \(group.name) run again")
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        } else {
            button(.suspend, help: "Freeze \(group.name) so it stops using CPU")
                .buttonStyle(.bordered)
        }
    }

    private func button(_ action: ProcessAction, help: String) -> some View {
        Button(action.title, systemImage: action.symbol) { actions.request(action, on: group) }
            .help(help)
    }
}

private struct ProcessListSection: View {
    let group: AppGroup
    let highlightedID: String?

    var body: some View {
        InspectorSection(title: "Processes", detail: "\(group.processes.count)") {
            VStack(spacing: 2) {
                ForEach(sorted) { process in
                    ProcessRow(
                        process: process,
                        groupName: group.name,
                        isHighlighted: process.id == highlightedID,
                        showsCommandLine: group.runtime != nil
                    )
                    .id(process.id)
                }
            }
        }
    }

    private var sorted: [GroupedProcess] {
        group.processes.sorted { $0.sample.cpuPercent > $1.sample.cpuPercent }
    }
}

private struct ProcessRow: View {
    let process: GroupedProcess
    let groupName: String
    let isHighlighted: Bool
    let showsCommandLine: Bool

    @Environment(ActionController.self) private var actions

    private static let cpuWidth: CGFloat = 48
    private static let memoryWidth: CGFloat = 64

    private var sample: ProcessSample { process.sample }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            titleLine
            detailLine
            if showsCommandLine { commandLine }
        }
        .padding(.horizontal, Theme.itemSpacing)
        .padding(.vertical, 6)
        .background(
            isHighlighted ? Theme.accent.opacity(0.14) : .clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .contentShape(Rectangle())
        .contextMenu { ProcessContextMenu(sample: sample, groupName: groupName, actions: actions) }
    }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(process.title)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            if sample.isApproximate {
                Text("≈")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help("Read from ps because macOS hides this process's details from regular apps")
            }
            if sample.isSuspended { StatePill(text: "Paused", color: Theme.warning) }
            Spacer(minLength: Theme.itemSpacing)
            Text(Format.percent(sample.cpuPercent))
                .frame(width: Self.cpuWidth, alignment: .trailing)
            Text(Format.bytes(sample.memoryBytes))
                .frame(width: Self.memoryWidth, alignment: .trailing)
        }
        .font(.metricSmall)
    }

    private var detailLine: some View {
        HStack(spacing: 6) {
            Text("PID \(String(sample.pid))").monospacedDigit()
            if let subtitle = process.subtitle {
                Text(subtitle).lineLimit(1).truncationMode(.middle)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var commandLine: some View {
        Text(sample.commandLine)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ProcessContextMenu: View {
    let sample: ProcessSample
    let groupName: String
    let actions: ActionController

    var body: some View {
        Group {
            item(.quit, title: "Quit Process")
            item(.forceQuit, title: "Force Quit Process")
            if sample.isSuspended {
                item(.resume, title: "Resume Process")
            } else {
                item(.suspend, title: "Pause Process")
            }
        }
        Divider()
        Button("Copy PID", systemImage: "number") { copy(String(sample.pid)) }
        Button("Copy Command Line", systemImage: "terminal") { copy(sample.commandLine) }
    }

    private func item(_ action: ProcessAction, title: String) -> some View {
        Button(title, systemImage: action.symbol) { actions.request(action, on: sample, groupName: groupName) }
            .disabled(ProcessActions.isProtected(sample, for: action))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct InspectorEmptyState: View {
    let hasQuit: Bool

    var body: some View {
        VStack(spacing: Theme.itemSpacing) {
            Image(systemName: hasQuit ? "xmark.app" : "sidebar.right")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(hasQuit ? "This app has quit." : "Select an app to see its history and processes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.groupSpacing)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension ProcessSample {
    var commandLine: String {
        guard !arguments.isEmpty else { return path.isEmpty ? name : path }
        return arguments.map(Self.quoted).joined(separator: " ")
    }

    static func quoted(_ argument: String) -> String {
        guard argument.contains(where: { $0 == " " || $0 == "\"" || $0 == "'" }) else { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
