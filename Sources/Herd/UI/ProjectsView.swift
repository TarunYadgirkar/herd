import SwiftUI

struct ProjectsView: View {
    @Environment(MonitorStore.self) private var store

    var body: some View {
        if !store.hasFirstFrame {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let report = ProjectInsights.report(groups: store.groups, ledger: store.projectActivity)
            if report.isEmpty {
                SectionMessage(title: "No Projects Running", symbol: "folder")
            } else {
                content(report, ledger: store.projectActivity)
            }
        }
    }

    private func content(_ report: ProjectReport, ledger: ActivityLedger) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.groupSpacing) {
                ProjectSummaryBar(report: report)
                LeftoversSection(report: report)
                if !report.projects.isEmpty {
                    ProjectList(title: "Projects", summaries: report.projects, ledger: ledger)
                }
                if !report.unowned.isEmpty {
                    ProjectList(title: "No Project", summaries: report.unowned, ledger: ledger)
                }
            }
            .padding(Theme.groupSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ProjectSummaryBar: View {
    let report: ProjectReport

    var body: some View {
        HStack(spacing: Theme.groupSpacing * 1.5) {
            GlyphStat(symbol: "folder", value: "\(report.projects.count)", label: "\(report.projects.count) projects")
            GlyphStat(symbol: "memorychip", value: Format.bytes(report.totalMemory), label: "\(Format.bytes(report.totalMemory)) memory")
            leftoverStat
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var leftoverStat: some View {
        let count = report.leftovers.count
        if count == 0 {
            GlyphStat(symbol: "checkmark.circle", value: "0", label: "No leftovers", tint: Theme.good)
        } else {
            let reclaim = Format.bytes(report.reclaimableMemory)
            GlyphStat(symbol: "xmark.bin", value: "\(count)", detail: reclaim, label: "\(count) leftovers, \(reclaim) reclaimable", tint: Theme.warning)
        }
    }
}

private struct GlyphStat: View {
    let symbol: String
    let value: String
    var detail: String?
    let label: String
    var tint: Color = .secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(value)
                .font(.displaySmall)
            if let detail {
                Text(detail)
                    .font(.metric)
                    .foregroundStyle(.secondary)
            }
        }
        .help(label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

private struct ProjectList: View {
    let title: String
    let summaries: [ProjectSummary]
    let ledger: ActivityLedger

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemSpacing) {
            Text(title)
                .font(.headlineText)
            ForEach(summaries) { summary in
                ProjectCard(summary: summary, ledger: ledger)
            }
        }
    }
}

struct ActivityGlyph: View {
    let idle: TimeInterval?
    var isOrphan = false
    var isProtected = false

    var body: some View {
        let state = appearance
        Image(systemName: state.symbol)
            .font(.captionText)
            .foregroundStyle(state.tint)
            .frame(width: 16)
            .help(state.label)
            .accessibilityLabel(state.label)
    }

    private var appearance: (symbol: String, tint: Color, label: String) {
        if isProtected { return ("lock.fill", .secondary, "Protected") }
        if isOrphan { return ("app.dashed", Theme.critical, "Launcher quit") }
        let duration = idle.map(ProjectInsights.compactDuration) ?? ""
        switch IdleLevel(idle) {
        case .active: return ("circle.fill", Theme.good, "Active")
        case .quiet: return ("circle", Theme.neutral, "Quiet \(duration)")
        case .idle: return ("moon.zzz.fill", Theme.warning, "Idle \(duration)")
        }
    }
}

struct LauncherLabel: View {
    let launcher: Launcher?

    private static let iconSize: CGFloat = 14

    var body: some View {
        HStack(spacing: 5) {
            if let path = launcher?.bundlePath {
                Image(nsImage: IconProvider.icon(forPath: path, size: Self.iconSize))
                    .frame(width: Self.iconSize, height: Self.iconSize)
                    .accessibilityHidden(true)
            }
            Text(launcher?.name ?? "–")
                .foregroundStyle(launcher == nil ? .secondary : .primary)
                .lineLimit(1)
        }
    }
}
