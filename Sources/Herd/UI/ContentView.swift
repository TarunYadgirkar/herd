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

    @State private var selection: Set<TableRowItem.ID> = []
    @State private var sortOrder = [KeyPathComparator(\TableRowItem.cpu, order: .reverse)]
    @State private var query = ""
    @State private var heldOrder: [String: Int]?
    @State private var holdUntil = Date.distantPast
    @State private var showInspector = false
    @AppStorage("scope") private var scope: Scope = .all

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
                onOpen: { showInspector = true }
            )
        }
        .overlay(alignment: .bottom) { ToastView(message: actions.toast) }
        .background(WindowVisibilityReader { store.setSurface("main", visible: $0) })
        .inspector(isPresented: $showInspector) {
            InspectorView(groupID: selectedGroupID, processID: selectedProcessID)
                .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search apps, processes, PIDs")
        .toolbar { toolbar }
        .actionConfirmation(actions)
        .navigationTitle("Herd")
        .navigationSubtitle(subtitle)
        .onChange(of: sortOrder) { _, _ in
            heldOrder = nil
            holdUntil = .distantPast
        }
        .onChange(of: store.requestedSelection, initial: true) { _, requested in
            guard let requested else { return }
            scope = .all
            query = ""
            selection = [requested]
            showInspector = true
            store.requestedSelection = nil
        }
        .onChange(of: selection) { _, newValue in
            if !newValue.isEmpty && !showInspector && UserDefaults.standard.bool(forKey: "autoOpenInspector") { showInspector = true }
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
            .help("Show details for the selected app")
        }
    }

    private var visibleRows: [TableRowItem] {
        let groups = store.groups.filter { scope.includes($0.kind) }
        let rows = TableRowBuilder.rows(for: groups, query: query)
        let sorted = TableRowBuilder.sorted(rows, using: sortOrder)
        guard let heldOrder, Date() < holdUntil else { return sorted }
        return TableRowBuilder.holding(sorted, order: heldOrder)
    }

    private static let holdDuration: TimeInterval = 2.5

    // Rows stay put while the pointer is moving across the table, so the row being aimed at doesn't jump away.
    private func holdOrder() {
        if heldOrder == nil || Date() >= holdUntil {
            heldOrder = TableRowBuilder.flattenOrder(visibleRows)
        }
        holdUntil = Date().addingTimeInterval(Self.holdDuration)
    }

    private var trendColumn: MetricColumn {
        guard let first = sortOrder.first else { return .cpu }
        switch first.keyPath {
        case \TableRowItem.memory: return .memory
        case \TableRowItem.energy: return .energy
        case \TableRowItem.gpu: return .gpu
        case \TableRowItem.network: return .network
        case \TableRowItem.disk: return .disk
        default: return .cpu
        }
    }

    private var selectedGroupID: String? {
        guard let id = selection.first else { return nil }
        if store.group(id: id) != nil { return id }
        return store.groups.first { group in
            group.processes.contains { $0.id == id } || id.hasPrefix(group.id + "/")
        }?.id
    }

    private var selectedProcessID: String? {
        guard let id = selection.first, store.group(id: id) == nil, !id.contains("/") else { return nil }
        return id
    }

    private var subtitle: String {
        let apps = store.groups.filter { $0.kind == .apps }.count
        let paused = store.isPaused ? " · Paused" : ""
        return "\(apps) apps · \(store.processCount) processes · Herd uses \(Format.percent(store.ownCPU)) CPU\(paused)"
    }
}

private struct ToastView: View {
    let message: String?

    var body: some View {
        if let message {
            Text(message)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                .padding(.bottom, Theme.groupSpacing)
                .transition(.opacity.combined(with: .offset(y: 6)))
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}
