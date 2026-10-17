import SwiftUI

enum Scope: String, CaseIterable, Identifiable {
    case all, apps, background, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .apps: GroupKind.apps.title
        case .background: GroupKind.background.title
        case .system: GroupKind.system.title
        }
    }

    func includes(_ kind: GroupKind) -> Bool {
        switch self {
        case .all: true
        case .apps: kind == .apps
        case .background: kind == .background
        case .system: kind == .system
        }
    }
}

struct ContentView: View {
    @Environment(MonitorStore.self) private var store
    @Environment(ActionController.self) private var actions

    @State private var selection: TableRowItem.ID?
    @State private var inspectedGroupID: String?
    @State private var sortOrder = [KeyPathComparator(\TableRowItem.cpu, order: .reverse)]
    @State private var query = ""
    @State private var hold = OrderHold()
    @State private var cache = RowCache()
    @State private var showInspector = false
    @AppStorage("scope") private var scope: Scope = .all
    @AppStorage("treeView") private var isTree = false

    var body: some View {
        let rows = visibleRows
        VStack(spacing: 0) {
            PulseHeader()
            Divider()
            ProcessTableView(
                rows: rows,
                rowsVersion: cache.version,
                selection: $selection,
                sortOrder: tableSortOrder,
                selected: selection,
                sorting: sortOrder,
                onPointerMove: holdOrder,
                history: cache.history(for:),
                trendColumn: trendColumn,
                actions: actions,
                onOpen: { showInspector = true },
                isSearching: !query.trimmingCharacters(in: .whitespaces).isEmpty,
                isTree: isTree
            )
            .equatable()
        }
        .inspector(isPresented: $showInspector) {
            InspectorView(groupID: inspectedGroupID, processID: selectedProcessID)
                .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .searchable(text: $query, placement: .toolbar)
        .toolbar { toolbar }
        .navigationTitle("Processes")
        .navigationSubtitle(countSummary)
        .onChange(of: store.requestedSelection, initial: true) { _, requested in
            guard let requested else { return }
            scope = .all
            query = ""
            selection = requested
            showInspector = true
            store.requestedSelection = nil
        }
        .onChange(of: selection) { _, newValue in
            inspectedGroupID = groupID(containing: newValue)
            if newValue != nil && !showInspector && UserDefaults.standard.bool(forKey: "autoOpenInspector") { showInspector = true }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Show", selection: $scope) {
                ForEach(Scope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $isTree) {
                Label("Show as Tree", systemImage: "list.bullet.indent")
            }
            .keyboardShortcut("t", modifiers: .command)
            .help("Show processes as a parent and child tree (⌘T)")

            Button {
                store.isPaused.toggle()
            } label: {
                Label(store.isPaused ? "Resume Updates" : "Pause Updates", systemImage: store.isPaused ? "play.fill" : "pause.fill")
            }
            .help(store.isPaused ? "Resume live updates" : "Freeze the numbers so you can read them")

            Button {
                showInspector.toggle()
            } label: {
                Label("Show Details", systemImage: "sidebar.right")
            }
            .help("Show details for the selected row")
        }
    }

    private var countSummary: String {
        let groups = store.groups.filter { scope.includes($0.kind) }
        let processes = groups.reduce(0) { $0 + $1.processes.count }
        return "\(processes) processes in \(groups.count) groups"
    }

    // Reading groups on every pass keeps this view subscribed to new frames even when the cached rows are reused.
    private var visibleRows: [TableRowItem] {
        let groups = store.groups
        let inputs = RowInputs(scope: scope, isTree: isTree, query: query, sortOrder: sortOrder)
        return cache.rows(for: inputs, histories: store.groupHistory) { inputsChanged in buildRows(groups, inputsChanged: inputsChanged) }
    }

    // A sort click, search or scope change is the user asking for a new order, so it overrides the pointer hold in this same pass.
    private func buildRows(_ groups: [AppGroup], inputsChanged: Bool) -> [TableRowItem] {
        let visible = groups.filter { scope.includes($0.kind) }
        let rows = isTree ? TreeRowBuilder.rows(for: visible, query: query) : TableRowBuilder.rows(for: visible, query: query)
        let sorted = TableRowBuilder.sorted(rows, using: sortOrder)
        if inputsChanged { hold.release() }
        guard let order = hold.activeOrder else { return sorted }
        return TableRowBuilder.holding(sorted, order: order)
    }

    private var tableSortOrder: Binding<[KeyPathComparator<TableRowItem>]> {
        Binding(
            get: { sortOrder },
            set: { sortOrder = TableRowBuilder.largestFirstOnNewColumn($0, previous: sortOrder) }
        )
    }

    private func holdOrder() {
        hold.extend { TableRowBuilder.flattenOrder(cache.currentRows) }
    }

    private var trendColumn: MetricColumn {
        guard let first = sortOrder.first else { return .cpu }
        switch first.keyPath {
        case \TableRowItem.memory: return .memory
        case \TableRowItem.impact: return .impact
        case \TableRowItem.energy: return .energy
        case \TableRowItem.gpu: return .gpu
        case \TableRowItem.network: return .network
        case \TableRowItem.disk: return .disk
        default: return .cpu
        }
    }

    private func groupID(containing id: String?) -> String? {
        guard let id else { return nil }
        if store.group(id: id) != nil { return id }
        if let row = Self.findRow(id, in: cache.currentRows) { return row.group.id }
        return store.groups
            .filter { group in group.processes.contains { $0.id == id } || id.hasPrefix(group.id + "/") }
            .max { $0.id.count < $1.id.count }?.id
    }

    private static func findRow(_ id: String, in rows: [TableRowItem]) -> TableRowItem? {
        for row in rows {
            if row.id == id { return row }
            if let children = row.children, let match = findRow(id, in: children) { return match }
        }
        return nil
    }

    private var selectedProcessID: String? {
        guard let id = selection, store.group(id: id) == nil, !id.contains("/") else { return nil }
        return id
    }
}

// Rows stay put while the pointer is moving across the table, so the row being aimed at doesn't jump away.
// It's a plain class so pointer movement doesn't invalidate the view on every mouse event.
@MainActor
private final class OrderHold {
    private static let duration: TimeInterval = 2.5

    private var order: [String: Int]?
    private var until = Date.distantPast

    var activeOrder: [String: Int]? {
        Date() < until ? order : nil
    }

    func extend(snapshot: () -> [String: Int]) {
        if activeOrder == nil { order = snapshot() }
        until = Date().addingTimeInterval(Self.duration)
    }

    func release() {
        order = nil
        until = .distantPast
    }
}

private struct RowInputs: Equatable {
    let scope: Scope
    let isTree: Bool
    let query: String
    let sortOrder: [KeyPathComparator<TableRowItem>]
}

// The table is the most expensive thing Herd draws, so it takes new rows at most this often while the header keeps ticking.
// A change to scope, search, tree mode or sort rebuilds immediately.
@MainActor
private final class RowCache {
    private static let minimumInterval: TimeInterval = 3

    private var inputs: RowInputs?
    private var committedAt = Date.distantPast
    private var histories: [String: GroupHistory] = [:]
    private(set) var currentRows: [TableRowItem] = []
    private(set) var version = 0

    func rows(for inputs: RowInputs, histories latest: [String: GroupHistory], build: (_ inputsChanged: Bool) -> [TableRowItem]) -> [TableRowItem] {
        let now = Date()
        let isStale = now.timeIntervalSince(committedAt) >= Self.minimumInterval
        let inputsChanged = inputs != self.inputs
        guard inputsChanged || currentRows.isEmpty || isStale else { return currentRows }
        self.inputs = inputs
        committedAt = now
        histories = latest
        currentRows = build(inputsChanged)
        version += 1
        return currentRows
    }

    func history(for id: String) -> GroupHistory {
        histories[id] ?? GroupHistory()
    }
}
