import AppKit
import SwiftUI

struct ProcessTableView: View {
    let rows: [TableRowItem]
    @Binding var selection: TableRowItem.ID?
    @Binding var sortOrder: [KeyPathComparator<TableRowItem>]
    let onPointerMove: () -> Void
    let history: (String) -> GroupHistory
    let trendColumn: MetricColumn
    let actions: ActionController
    let onOpen: () -> Void

    let isSearching: Bool
    var isTree = false

    @AppStorage("processTableColumns") private var columnStorage = Data()
    @State private var columnCustomization = TableColumnCustomization<TableRowItem>()
    @State private var expanded: Set<String> = []

    var body: some View {
        table
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .onContinuousHover { phase in
                if case .active = phase { onPointerMove() }
            }
            .contextMenu(forSelectionType: TableRowItem.ID.self) { ids in
                RowMenu(rows: resolve(ids), actions: actions)
            } primaryAction: { ids in
                guard !ids.isEmpty else { return }
                onOpen()
            }
            .onAppear(perform: restoreColumns)
            .onChange(of: columnCustomization) { _, customization in
                columnStorage = (try? JSONEncoder().encode(customization)) ?? Data()
            }
    }

    @ViewBuilder
    private var table: some View {
        if isTree {
            Table(rows, children: \.children, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columnCustomization) {
                columns
            }
        } else {
            Table(of: TableRowItem.self, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columnCustomization) {
                columns
            } rows: {
                ForEach(rows) { row in
                    if let children = row.children {
                        DisclosureTableRow(row, isExpanded: expansion(row.id)) {
                            if isOpen(row.id) {
                                ForEach(children) { child in
                                    if let grandchildren = child.children {
                                        DisclosureTableRow(child, isExpanded: expansion(child.id)) {
                                            if isOpen(child.id) {
                                                ForEach(grandchildren) { TableRow($0) }
                                            }
                                        }
                                    } else {
                                        TableRow(child)
                                    }
                                }
                            }
                        }
                    } else {
                        TableRow(row)
                    }
                }
            }
        }
    }

    @TableColumnBuilder<TableRowItem, KeyPathComparator<TableRowItem>>
    private var columns: some TableColumnContent<TableRowItem, KeyPathComparator<TableRowItem>> {
        TableColumn("Name", value: \.sortTitle) { row in
            NameCell(row: row)
        }
        .width(min: 220, ideal: 300)
        .customizationID("name")
        .disabledCustomizationBehavior(.visibility)

        metricColumn(.cpu, value: \.cpu)
        metricColumn(.memory, value: \.memory)
        metricColumn(.energy, value: \.energy)
        metricColumn(.gpu, value: \.gpu)
        metricColumn(.network, value: \.network)
        metricColumn(.disk, value: \.disk)

        TableColumn("Threads", value: \.threads) { row in
            Text(row.threads > 0 ? "\(row.threads)" : "–")
                .font(.metric)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel(row.threads > 0 ? "\(row.threads) threads" : "Not available")
        }
        .width(min: 56, ideal: 64)
        .customizationID("threads")
        .defaultVisibility(.hidden)

        TableColumn("PID") { row in
            Text(row.pid.map(String.init) ?? "")
                .font(.metric)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .width(min: 52, ideal: 60)
        .customizationID("pid")
        .defaultVisibility(.hidden)

        TableColumn("Last 5 min") { row in
            TrendCell(row: row, history: history, column: trendColumn)
        }
        .width(min: 80, ideal: 110)
        .customizationID("trend")
    }

    // SceneStorage only survives with window restoration on, which macOS turns off by default, so column choices live in user defaults.
    private func restoreColumns() {
        guard let saved = try? JSONDecoder().decode(TableColumnCustomization<TableRowItem>.self, from: columnStorage) else { return }
        columnCustomization = saved
    }

    private func isOpen(_ id: String) -> Bool {
        isSearching || expanded.contains(id)
    }

    // Collapsed groups hand no children to the table, so SwiftUI only diffs the rows people can actually see.
    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(
            get: { isOpen(id) },
            set: { isOpen in
                if isOpen { expanded.insert(id) } else { expanded.remove(id) }
            }
        )
    }

    private func metricColumn(_ column: MetricColumn, value: KeyPath<TableRowItem, Double>) -> some TableColumnContent<TableRowItem, KeyPathComparator<TableRowItem>> {
        TableColumn(column.title, value: value) { row in
            if isUnavailable(row, column) {
                Text("–")
                    .font(.metric)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 6)
                    .help("macOS doesn't share this for system processes")
                    .accessibilityLabel("Not available")
            } else {
                HeatValue(column: column, value: row[keyPath: value], isApproximate: row.isApproximate && column == .memory)
            }
        }
        .width(min: 64, ideal: column == .network || column == .disk ? 84 : 72)
        .customizationID(column.rawValue)
        .defaultVisibility(column == .disk ? .hidden : .automatic)
    }

    private func isUnavailable(_ row: TableRowItem, _ column: MetricColumn) -> Bool {
        row.isUnavailable || (row.isApproximate && (column == .energy || column == .disk))
    }

    private func resolve(_ ids: Set<TableRowItem.ID>) -> [TableRowItem] {
        var found: [TableRowItem] = []
        func visit(_ items: [TableRowItem]) {
            for item in items {
                if ids.contains(item.id) { found.append(item) }
                if let children = item.children { visit(children) }
            }
        }
        visit(rows)
        return found
    }
}

private struct NameCell: View {
    let row: TableRowItem

    var body: some View {
        HStack(spacing: Theme.itemSpacing) {
            leading
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(row.title)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            ForEach(ports, id: \.self) { port in
                Text(":" + String(port))
                    .font(.metricSmall)
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 5)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
                    .help("Listening on port " + String(port))
            }
            if !sleepReasons.isEmpty {
                Image(systemName: "moon.zzz.fill")
                    .foregroundStyle(Theme.warning)
                    .help("Keeping your Mac awake: \(sleepReasons.joined(separator: ", "))")
                    .accessibilityLabel("Keeping your Mac awake")
            }
            if row.isSuspended {
                StatePill(text: "Paused", color: Theme.warning)
            }
            if row.role != .process && row.count > 1 {
                Text("\(row.count)")
                    .font(.metricSmall)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .help("\(row.count) processes")
                    .accessibilityLabel("\(row.count) processes")
            }
        }
        .help(row.process?.sample.path ?? row.group.bundlePath ?? row.title)
    }

    private static let maxPorts = 3

    private var members: [ProcessSample] {
        if let process = row.process { return [process.sample] }
        return (row.children ?? []).flatMap { $0.process.map { [$0.sample] } ?? ($0.children ?? []).compactMap { $0.process?.sample } }
    }

    private var ports: [UInt16] {
        Array(Set(members.flatMap(\.listeningPorts))).sorted().prefix(Self.maxPorts).map { $0 }
    }

    private var sleepReasons: [String] {
        Array(Set(members.flatMap(\.sleepAssertions))).sorted()
    }

    @ViewBuilder
    private var leading: some View {
        switch row.role {
        case .group:
            GroupIcon(group: row.group, size: 18)
        case .cluster:
            Image(systemName: "square.stack")
                .foregroundStyle(.secondary)
                .frame(width: 18)
        case .process:
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
                .foregroundStyle(.tertiary)
                .frame(width: 18)
        }
    }
}

private struct TrendCell: View {
    let row: TableRowItem
    let history: (String) -> GroupHistory
    let column: MetricColumn

    var body: some View {
        if row.role == .group {
            let series = history(row.id).series(for: column)
            Sparkline(values: series.values, color: color(series.latest), ceiling: column.heatRange.lowerBound * 2)
                .frame(height: 18)
                .padding(.vertical, 2)
        }
    }

    private func color(_ latest: Double) -> Color {
        let heat = column.heat(latest)
        return heat > 0.5 ? Theme.heatColor(heat) : Theme.accent
    }
}

private struct RowMenu: View {
    let rows: [TableRowItem]
    let actions: ActionController

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let row = rows.first {
            let group = row.group
            Section(group.name) {
                groupButton(.quit, title: "Quit \(group.name)", group)
                groupButton(.forceQuit, title: "Force Quit \(group.name)", group)
                if group.isSuspended {
                    groupButton(.resume, title: "Resume", group)
                } else {
                    groupButton(.suspend, title: "Pause", group)
                }
            }
            if row.role == .process, let process = row.process, row.group.processes.count > 1 {
                Section("This process (\(process.sample.pid))") {
                    processButton(.quit, title: "Quit Process", process.sample, group: group)
                    processButton(.forceQuit, title: "Force Quit Process", process.sample, group: group)
                    if process.sample.isSuspended {
                        processButton(.resume, title: "Resume Process", process.sample, group: group)
                    } else {
                        processButton(.suspend, title: "Pause Process", process.sample, group: group)
                    }
                }
            }
            Divider()
            if let target = infoTarget(row) {
                Button("Get Info", systemImage: "info.circle") { openWindow(id: "process-info", value: target.id) }
            }
            Button("Show in Finder", systemImage: "folder") { ProcessActions.revealInFinder(group) }
            Button("Copy Details", systemImage: "doc.on.doc") { copy(row) }
            Button("Search the Web for \(row.title)", systemImage: "magnifyingglass") { searchOnline(row.title) }
        }
    }

    private func infoTarget(_ row: TableRowItem) -> ProcessSample? {
        if let process = row.process { return process.sample }
        let members = row.group.processes
        return (members.first { $0.sample.pid == row.group.mainPid } ?? members.first)?.sample
    }

    private func groupButton(_ action: ProcessAction, title: String, _ group: AppGroup) -> some View {
        Button(title, systemImage: action.symbol) { actions.request(action, on: group) }
            .disabled(!ProcessActions.canAct(on: group, action: action))
    }

    private func processButton(_ action: ProcessAction, title: String, _ sample: ProcessSample, group: AppGroup) -> some View {
        Button(title) { actions.request(action, on: sample, groupName: group.name) }
            .disabled(ProcessActions.isProtected(sample, for: action))
    }

    private func searchOnline(_ term: String) {
        var components = URLComponents(string: "https://duckduckgo.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: "\(term) macOS process")]
        if let url = components?.url { NSWorkspace.shared.open(url) }
    }

    private func copy(_ row: TableRowItem) {
        let lines = (row.process.map { [$0] } ?? row.group.processes).map { member in
            "\(member.sample.pid)\t\(member.sample.path)\t\(member.sample.arguments.dropFirst().joined(separator: " "))"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
