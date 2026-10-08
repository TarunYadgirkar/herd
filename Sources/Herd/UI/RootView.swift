import SwiftUI

enum SidebarItem: Hashable, Identifiable, RawRepresentable {
    case processes
    case projects
    case performance(PerformanceSection)
    case history

    init?(rawValue: String) {
        switch rawValue {
        case "processes": self = .processes
        case "projects": self = .projects
        case "history": self = .history
        default:
            guard rawValue.hasPrefix(Self.performancePrefix),
                  let section = PerformanceSection(rawValue: String(rawValue.dropFirst(Self.performancePrefix.count))) else { return nil }
            self = .performance(section)
        }
    }

    var rawValue: String {
        switch self {
        case .processes: "processes"
        case .projects: "projects"
        case .history: "history"
        case .performance(let section): Self.performancePrefix + section.rawValue
        }
    }

    var id: String { rawValue }

    private static let performancePrefix = "performance."
}

struct RootView: View {
    @Environment(MonitorStore.self) private var store
    @Environment(ActionController.self) private var actions
    @AppStorage("sidebarItem") private var storedItem = SidebarItem.processes.rawValue

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: selection)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            detail
        }
        .overlay(alignment: .bottom) { ToastView(message: actions.toast) }
        .actionConfirmation(actions)
        .background(WindowVisibilityReader { store.setSurface("main", visible: $0) })
        .onChange(of: store.requestedSelection) { _, requested in
            if requested != nil { storedItem = SidebarItem.processes.rawValue }
        }
    }

    private var selection: Binding<SidebarItem?> {
        Binding(
            get: { SidebarItem(rawValue: storedItem) ?? .processes },
            set: { storedItem = ($0 ?? .processes).rawValue }
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch SidebarItem(rawValue: storedItem) ?? .processes {
        case .processes:
            ContentView()
        case .projects:
            ProjectsView()
                .navigationTitle("Projects")
        case .performance(let section):
            PerformanceView(section: section)
                .navigationTitle(section.title)
        case .history:
            AppHistoryView()
                .navigationTitle("App History")
        }
    }
}

private struct Sidebar: View {
    @Binding var selection: SidebarItem?
    @Environment(MonitorStore.self) private var store

    var body: some View {
        List(selection: $selection) {
            Label("Processes", systemImage: "list.bullet.rectangle")
                .tag(SidebarItem.processes)
            Label("Projects", systemImage: "folder")
                .tag(SidebarItem.projects)
            Section {
                ForEach(PerformanceSection.allCases) { section in
                    SidebarRow(title: section.title, symbol: section.symbol, value: section.summary(store.system))
                        .tag(SidebarItem.performance(section))
                }
            }
            Section {
                Label("App History", systemImage: "clock.arrow.circlepath")
                    .tag(SidebarItem.history)
            }
        }
        .listStyle(.sidebar)
    }
}

private struct SidebarRow: View {
    let title: String
    let symbol: String
    let value: String

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(title)
                Spacer(minLength: 4)
                Text(value)
                    .font(.metricSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: symbol)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ToastView: View {
    let message: String?

    var body: some View {
        if let message {
            Text(message)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: Theme.shadow, radius: 8, y: 2)
                .padding(.bottom, Theme.groupSpacing)
                .transition(.opacity.combined(with: .offset(y: 6)))
        }
    }
}
