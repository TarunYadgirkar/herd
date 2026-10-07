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
                selection: $selection,
                sortOrder: $sortOrder,
                onPointerMove: holdOrder,
                history: store.history(for:),
                trendColumn: trendColumn,
                actions: actions,
                onOpen: { showInspector = true },
                isSearching: !query.trimmingCharacters(in: .whitespaces).isEmpty,
                isTree: isTree
            )
        }
        .inspector(isPresented: $showInspector) {
            InspectorView(groupID: inspectedGroupID, processID: selectedProcessID)
                .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search apps, processes, PIDs")
        .toolbar { toolbar }
        .navigationTitle("Herd")
        .navigationSubtitle(subtitle)
        .onChange(of: sortOrder) { _, _ in hold.release() }
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
            .help("Filter by kind of process")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $isTree) {
                Label("Show as Tree", systemImage: "list.bullet.indent")
            }
            .keyboardShortcut("t", modifiers: .command)
            .help(isTree ? "Group processes by app (⌘T)" : "Show which process started which (⌘T)")

            Button {
                store.isPaused.toggle()
            } label: {
                Label(store.isPaused ? "Resume Updates" : "Pause Updates", systemImage: store.isPaused ? "play.fill" : "pause.fill")
            }
            .help(store.isPaused ? "Resume live updates" : "Freeze the numbers so you can read them")

            Button {
                showInspector.toggle()
            } label: {
                Label("Details", systemImage: "sidebar.right")
            }
            .help(showInspector ? "Hide the details panel" : "Show details for the selected app")
        }
    }

    private var visibleRows: [TableRowItem] {
        let groups = store.groups.filter { scope.includes($0.kind) }
        let rows = isTree ? TreeRowBuilder.rows(for: groups, query: query) : TableRowBuilder.rows(for: groups, query: query)
        let sorted = TableRowBuilder.sorted(rows, using: sortOrder, smoothed: smoothedValue)
        guard let order = hold.activeOrder else { return sorted }
        return TableRowBuilder.holding(sorted, order: order)
    }

    private static let smoothingSamples = 3

    private var smoothedValue: ((TableRowItem) -> Double?)? {
        guard let keyPath = sortOrder.first?.keyPath, let column = TableRowBuilder.metric(for: keyPath) else { return nil }
        let history = store.groupHistory
        return { row in
            guard row.role == .group else { return nil }
            return history[row.id]?.series(for: column).recentAverage(Self.smoothingSamples)
        }
    }

    private func holdOrder() {
        hold.extend { TableRowBuilder.flattenOrder(visibleRows) }
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
        return store.groups.first { group in
            group.processes.contains { $0.id == id } || id.hasPrefix(group.id + "/")
        }?.id
    }

    private var selectedProcessID: String? {
        guard let id = selection, store.group(id: id) == nil, !id.contains("/") else { return nil }
        return id
    }

    private var subtitle: String {
        guard store.hasFirstFrame else { return "Counting the herd…" }
        guard !store.isPaused else { return "Updates paused" }
        let apps = store.groups.filter { $0.kind == .apps }.count
        return "\(store.processCount) processes in \(apps) apps"
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
