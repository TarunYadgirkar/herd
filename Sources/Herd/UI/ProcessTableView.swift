import AppKit
import SwiftUI

struct ProcessTableView: View, Equatable {
    let rows: [TableRowItem]
    let rowsVersion: Int
    @Binding var selection: TableRowItem.ID?
    @Binding var sortOrder: [KeyPathComparator<TableRowItem>]
    let selected: TableRowItem.ID?
    let sorting: [KeyPathComparator<TableRowItem>]
    let onPointerMove: () -> Void
    let history: (String) -> GroupHistory
    let trendColumn: MetricColumn
    let actions: ActionController
    let onOpen: () -> Void

    let isSearching: Bool
    var isTree = false

    // Closures and bindings are rebuilt every pass, so the table is re-evaluated only when what it shows could differ.
    nonisolated static func == (lhs: ProcessTableView, rhs: ProcessTableView) -> Bool {
        lhs.rowsVersion == rhs.rowsVersion
            && lhs.selected == rhs.selected
            && lhs.sorting == rhs.sorting
            && lhs.trendColumn == rhs.trendColumn
            && lhs.isSearching == rhs.isSearching
            && lhs.isTree == rhs.isTree
    }

    // Automatic sizing is switched off below, so this has to fit one line of table text plus the heat cell's inset.
    private static let rowHeight: CGFloat = 26

    @AppStorage("processTableColumns") private var columnStorage = Data()
    @State private var columnCustomization = TableColumnCustomization<TableRowItem>()
    @State private var expanded: Set<String> = []

    var body: some View {
        table
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .environment(\.defaultMinListRowHeight, Self.rowHeight)
            .onContinuousHover { phase in
                if case .active = phase { onPointerMove() }
            }
            .contextMenu(forSelectionType: TableRowItem.ID.self) { ids in
                RowMenu(rows: resolve(ids), actions: actions)
            } primaryAction: { ids in
                guard !ids.isEmpty else { return }
                onOpen()
            }
            .background(FixedRowHeight(refresh: rowsVersion))
            .onDeleteCommand(perform: quitSelection)
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
            NameCell(row: row).equatable()
        }
        .width(min: 220, ideal: 300)
        .customizationID("name")
        .disabledCustomizationBehavior(.visibility)

        Group {
            metricColumn(.cpu, value: \.cpu)
            metricColumn(.memory, value: \.memory)
            metricColumn(.impact, value: \.impact)
            metricColumn(.energy, value: \.energy)
            metricColumn(.gpu, value: \.gpu)
            metricColumn(.network, value: \.network)
            metricColumn(.disk, value: \.disk)
        }

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

        TableColumn("Trend") { row in
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

    private func quitSelection() {
        guard let id = selection, let row = resolve([id]).first else { return }
        if row.quitsSingleProcess, let process = row.process {
            actions.request(.quit, on: process.sample, groupName: row.group.name)
        } else {
            actions.request(.quit, on: row.group)
        }
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
                    .accessibilityLabel("Not available")
            } else {
                HeatValue(column: column, value: row[keyPath: value]).equatable()
            }
        }
        .width(min: 64, ideal: column == .network || column == .disk || column == .impact || column == .energy ? 104 : 76)
        .customizationID(column.rawValue)
        .defaultVisibility(column == .disk ? .hidden : .automatic)
    }

    private func isUnavailable(_ row: TableRowItem, _ column: MetricColumn) -> Bool {
        row.isUnavailable || (row.lacksCounters && (column == .energy || column == .disk))
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

private struct NameCell: View, Equatable {
    let row: TableRowItem

    nonisolated static func == (lhs: NameCell, rhs: NameCell) -> Bool { lhs.row == rhs.row }

    var body: some View {
        HStack(spacing: Theme.itemSpacing) {
            leading
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(row.title)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(.captionText)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            ForEach(row.badges.ports, id: \.self) { port in
                Text(":" + String(port))
                    .font(.metricSmall)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Theme.surfaceRaised, in: Capsule())
                    .accessibilityLabel("Port " + String(port))
            }
            if !row.badges.sleepReasons.isEmpty {
                Image(systemName: "moon.zzz.fill")
                    .foregroundStyle(Theme.warning)
                    .help(row.badges.sleepReasons.joined(separator: ", "))
                    .accessibilityLabel("Keeping your Mac awake")
            }
            if row.isSuspended {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(Theme.warning)
                    .accessibilityLabel("Paused")
            }
            if row.role != .process && row.count > 1 {
                Text("\(row.count)")
                    .font(.metricSmall)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Theme.surfaceRaised, in: Capsule())
                    .accessibilityLabel("\(row.count) processes")
            }
        }
        .font(.calloutText)
        .help(row.process?.sample.path ?? row.group.bundlePath ?? row.title)
        .accessibilityElement(children: .combine)
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
                .accessibilityHidden(true)
        case .process:
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
                .foregroundStyle(.tertiary)
                .frame(width: 18)
                .accessibilityHidden(true)
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
            Sparkline(values: series.values, color: color(series.latest), ceiling: column.trendFloor)
                .frame(height: 20)
                .padding(.vertical, 2)
        }
    }

    private static let heatedTrend = 0.6

    private func color(_ latest: Double) -> Color {
        let heat = column.heat(latest)
        return heat > Self.heatedTrend ? Theme.heatColor(heat) : Theme.accent
    }
}

private struct RowMenu: View {
    let rows: [TableRowItem]
    let actions: ActionController

    @Environment(\.openWindow) private var openWindow

    private static let quitShortcut = KeyboardShortcut(.delete, modifiers: [])

    var body: some View {
        if let row = rows.first {
            let group = row.group
            Section(group.name) {
                groupButton(.quit, title: "Quit \(group.name)", group)
                    .keyboardShortcut(row.quitsSingleProcess ? nil : Self.quitShortcut)
                groupButton(.forceQuit, title: "Force Quit \(group.name)", group)
                if group.isSuspended {
                    groupButton(.resume, title: "Resume", group)
                } else {
                    groupButton(.suspend, title: "Pause", group)
                }
            }
            if row.quitsSingleProcess, let process = row.process {
                Section("This process (\(process.sample.pid))") {
                    processButton(.quit, title: "Quit Process", process.sample, group: group)
                        .keyboardShortcut(Self.quitShortcut)
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

// Automatic row heights make NSTableView re-measure every visible cell's hosting view after each update, which was half the cost of a refresh.
// Every row is one line, so a fixed height (taken from the environment) is equivalent. SwiftUI offers no switch for it, so the backing table is found and set directly.
private struct FixedRowHeight: NSViewRepresentable {
    let refresh: Int

    private static let minimumColumns = 3

    final class Coordinator {
        weak var table: NSTableView?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak view] in
            if coordinator.table?.window == nil { coordinator.table = view.flatMap(Self.findTable) }
            guard let table = coordinator.table, table.usesAutomaticRowHeights else { return }
            table.usesAutomaticRowHeights = false
        }
    }

    private static func findTable(from view: NSView) -> NSTableView? {
        var ancestor = view.superview
        while let current = ancestor {
            if let table = descendantTable(in: current) { return table }
            ancestor = current.superview
        }
        return nil
    }

    private static func descendantTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView, table.tableColumns.count > minimumColumns { return table }
        return view.subviews.lazy.compactMap(descendantTable).first
    }
}
