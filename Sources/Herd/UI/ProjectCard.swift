import AppKit
import SwiftUI

struct ProjectCard: View {
    let summary: ProjectSummary
    let ledger: ActivityLedger

    @Environment(ActionController.self) private var actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    private static let iconSize: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemSpacing) {
            header
            tags
            if isExpanded {
                Divider()
                ProjectProcessList(group: summary.group, ledger: ledger)
            }
        }
        .padding(Theme.innerPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: Theme.itemSpacing) {
            disclosureButton
            GroupIcon(group: summary.group, size: Self.iconSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.name)
                    .font(.headline)
                    .lineLimit(1)
                if let root = summary.root {
                    Text(ScriptLabel.abbreviate(root))
                        .font(.metricSmall)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(root)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: Theme.groupSpacing)
            metrics
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }

    private var disclosureButton: some View {
        Button(action: toggle) {
            Image(systemName: "chevron.right")
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 14)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(isExpanded ? "Hide processes" : "Show processes")
    }

    private var metrics: some View {
        HStack(spacing: Theme.groupSpacing) {
            MetricCell(symbol: "cpu", value: Format.percent(summary.metrics.cpu), label: "CPU")
            MetricCell(symbol: "memorychip", value: Format.bytes(summary.metrics.memory), label: "Memory")
            if let start = summary.oldestStart {
                MetricCell(symbol: "clock", value: ProjectInsights.compactDuration(ledger.date.timeIntervalSince(start)), label: "Running for")
            }
            HStack(spacing: 4) {
                ActivityGlyph(idle: summary.idle)
                Text(summary.idle.map(ProjectInsights.compactDuration) ?? "–")
                    .font(.metric)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: MetricCell.width, alignment: .trailing)
        }
    }

    private var tags: some View {
        HStack(spacing: Theme.itemSpacing) {
            Text(summary.runtimes.map(\.rawValue).joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(summary.launchers, id: \.self) { launcher in
                LauncherLabel(launcher: launcher)
                    .font(.caption)
            }
            ForEach(summary.ports, id: \.self) { port in
                StatePill(text: ":\(port)", color: Theme.accent)
                    .monospacedDigit()
            }
            Spacer(minLength: Theme.groupSpacing)
            buttons
        }
        .padding(.leading, Self.iconSize + 14 + Theme.itemSpacing * 2)
    }

    @ViewBuilder
    private var buttons: some View {
        if let root = summary.root {
            Button("Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root)])
            }
            .controlSize(.small)
        }
        if summary.isSafeQuitTarget {
            Button("Stop Project", systemImage: "xmark.circle") {
                actions.request(.quit, on: summary.group)
            }
            .controlSize(.small)
        }
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { isExpanded.toggle() }
    }
}

private struct MetricCell: View {
    let symbol: String
    let value: String
    let label: String

    static let width: CGFloat = 72

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.metric)
        }
        .frame(minWidth: Self.width, alignment: .trailing)
        .help(label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value)")
    }
}

private struct ProjectProcessList: View {
    let group: AppGroup
    let ledger: ActivityLedger

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.groupSpacing, verticalSpacing: 4) {
            ForEach(group.processes.sorted { $0.sample.memoryBytes > $1.sample.memoryBytes }) { process in
                row(process)
            }
        }
    }

    private func row(_ process: GroupedProcess) -> some View {
        let sample = process.sample
        let idle = ledger.idle(sample.id)
        return GridRow {
            ActivityGlyph(idle: idle)
            VStack(alignment: .leading, spacing: 1) {
                Text(process.title).lineLimit(1)
                if let subtitle = process.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(sample.listeningPorts.map { ":\($0)" }.joined(separator: " "))
                .font(.metricSmall)
                .foregroundStyle(Theme.accent)
            Text("\(sample.pid)")
                .font(.metricSmall)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(Format.percent(sample.cpuPercent))
                .font(.metric)
                .gridColumnAlignment(.trailing)
            Text(Format.bytes(sample.memoryBytes))
                .font(.metric)
                .gridColumnAlignment(.trailing)
            Text(idle.map(ProjectInsights.compactDuration) ?? "–")
                .font(.metric)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
        }
    }
}
