import SwiftUI

private enum LeftoverGrid {
    static let columns = 6
}

struct LeftoversSection: View {
    let report: ProjectReport

    @Environment(ActionController.self) private var actions

    var body: some View {
        PerformanceCard(title: "Leftovers") {
            stopButton
        } content: {
            if report.duplicates.isEmpty && report.orphans.isEmpty {
                Label {
                    Text("No leftovers").foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "checkmark.circle").foregroundStyle(Theme.good)
                }
            } else {
                grid
            }
        }
    }

    private var stopButton: some View {
        let leftovers = report.leftovers
        let title = leftovers.count == 1 ? "1 leftover" : "\(leftovers.count) leftovers"
        return Button("Stop Leftovers", systemImage: "xmark.circle") {
            actions.request(.quit, on: leftovers.flatMap(\.members), title: title)
        }
        .controlSize(.small)
        .disabled(leftovers.isEmpty)
        .help("Quit every copy marked idle or orphaned")
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.groupSpacing, verticalSpacing: 6) {
            ForEach(report.duplicates) { set in
                SetHeader(symbol: "square.on.square", title: set.title, count: set.copies.count, memory: set.totalMemory)
                ForEach(set.copies) { CopyRow(copy: $0) }
            }
            let orphans = report.loneOrphans
            if !orphans.isEmpty {
                SetHeader(symbol: "app.dashed", title: "Orphans", count: orphans.count, memory: orphans.reduce(0) { $0 + $1.memory })
                ForEach(orphans) { CopyRow(copy: $0, showsTitle: true) }
            }
        }
    }
}

private struct SetHeader: View {
    let symbol: String
    let title: String
    let count: Int
    let memory: UInt64

    var body: some View {
        GridRow {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.headlineText)
                Text("×\(count)")
                    .font(.metric)
                    .foregroundStyle(.secondary)
                Spacer(minLength: Theme.itemSpacing)
                Text(Format.bytes(memory))
                    .font(.metric)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, Theme.itemSpacing)
            .gridCellColumns(LeftoverGrid.columns)
            .accessibilityElement(children: .combine)
        }
    }
}

private struct CopyRow: View {
    let copy: ProcessCopy
    var showsTitle = false

    private static let keptOpacity = 0.6

    @Environment(ActionController.self) private var actions

    var body: some View {
        GridRow {
            ActivityGlyph(idle: copy.idle, isOrphan: copy.isOrphan, isProtected: copy.isProtected)
            if showsTitle {
                Text(copy.title)
                    .lineLimit(1)
            } else {
                LauncherLabel(launcher: copy.launcher)
            }
            Text(copy.projectName ?? "–")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(Format.bytes(copy.memory))
                .font(.metric)
                .gridColumnAlignment(.trailing)
            Text(copy.idle.map(ProjectInsights.compactDuration) ?? "–")
                .font(.metric)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            quitButton
        }
        .opacity(copy.isSafeToStop ? 1 : Self.keptOpacity)
    }

    private var quitButton: some View {
        let name = "\(copy.title) (\(copy.root.pid))"
        return Button {
            actions.request(.quit, on: copy.members, title: name)
        } label: {
            Image(systemName: "xmark.circle")
        }
        .buttonStyle(.borderless)
        .disabled(copy.isProtected)
        .help("Quit \(name)")
        .accessibilityLabel("Quit \(name)")
    }
}
