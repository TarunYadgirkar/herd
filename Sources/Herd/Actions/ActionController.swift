import Observation
import SwiftUI

struct PendingAction: Identifiable {
    enum Target {
        case group(AppGroup)
        case process(ProcessSample, groupName: String)
        case processes([LabeledProcess], title: String)
    }

    let action: ProcessAction
    let target: Target

    init(action: ProcessAction, group: AppGroup) {
        self.action = action
        target = .group(group)
    }

    init(action: ProcessAction, process: ProcessSample, groupName: String) {
        self.action = action
        target = .process(process, groupName: groupName)
    }

    init(action: ProcessAction, processes: [LabeledProcess], title: String) {
        self.action = action
        target = .processes(processes, title: title)
    }

    var id: String {
        switch target {
        case .group(let group): "\(action.rawValue):\(group.id)"
        case .process(let sample, _): "\(action.rawValue):\(sample.id)"
        case .processes(let items, _): "\(action.rawValue):" + items.map(\.sample.id).joined(separator: ",")
        }
    }

    var name: String {
        switch target {
        case .group(let group): group.name
        case .process(let sample, _): sample.name
        case .processes(_, let title): title
        }
    }

    var title: String {
        switch target {
        case .group(let group):
            let count = group.processes.count
            return "\(action.title) \(group.name)\(count > 1 ? " and its \(count) processes" : "")?"
        case .process(let sample, let groupName):
            return "\(action.title) \(sample.name) (\(sample.pid)) from \(groupName)?"
        case .processes(_, let title):
            return "\(action.title) \(title)?"
        }
    }

    // Only regular apps receive a real Quit command; everything else gets SIGTERM, which programs may handle or not.
    private var quitsLikeAnApp: Bool {
        guard case .group(let group) = target else { return false }
        return group.kind == .apps
    }

    var message: String {
        if case .processes(let items, _) = target { return Self.listing(items, action: action) }
        return standardMessage
    }

    private var standardMessage: String {
        switch action {
        case .forceQuit: "Unsaved changes in \(name) will be lost."
        case .quit: quitsLikeAnApp
            ? "\(name) will quit the way it does from its own Quit command."
            : "Herd will ask \(name) to exit. Programs that ignore the request keep running; ones that don't handle it stop without saving."
        case .suspend: "\(name) will freeze until you resume it. Herd resumes it automatically if Herd quits."
        case .resume: "\(name) will continue where it left off."
        }
    }

    private static func listing(_ items: [LabeledProcess], action: ProcessAction) -> String {
        let lines = items.map { "\($0.label) (\($0.sample.pid))" }.joined(separator: "\n")
        return "Herd will send \(action.title) to:\n\(lines)"
    }
}

@MainActor
@Observable
final class ActionController {
    var pending: PendingAction?
    private(set) var toast: String?

    @ObservationIgnored private let store: MonitorStore
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    private static let toastDuration = Duration.seconds(4)

    init(store: MonitorStore) {
        self.store = store
    }

    func request(_ action: ProcessAction, on group: AppGroup) {
        guard ProcessActions.canAct(on: group, action: action) else {
            show(Self.refusal(action, group))
            return
        }
        ask(PendingAction(action: action, group: group))
    }

    func request(_ action: ProcessAction, on sample: ProcessSample, groupName: String) {
        guard !ProcessActions.isProtected(sample, for: action) else {
            show("\(sample.name) keeps macOS running, so Herd won't \(action.title.lowercased()) it.")
            return
        }
        ask(PendingAction(action: action, process: sample, groupName: groupName))
    }

    func request(_ action: ProcessAction, on items: [LabeledProcess], title: String) {
        let allowed = items.filter { !ProcessActions.isProtected($0.sample, for: action) }
        guard !allowed.isEmpty else {
            show("\(title) keeps macOS running, so Herd won't \(action.title.lowercased()) it.")
            return
        }
        ask(PendingAction(action: action, processes: allowed, title: title))
    }

    func confirm() {
        guard let pending else { return }
        self.pending = nil
        run(pending)
    }

    static func refusal(_ action: ProcessAction, _ group: AppGroup) -> String {
        guard group.isSafeQuitTarget else {
            return "\(group.name) holds \(group.processes.count) separate processes. Expand it and choose the one to \(action.title.lowercased())."
        }
        return "\(group.name) keeps macOS running, so Herd won't \(action.title.lowercased()) it."
    }

    // The menu bar asks through its own alert, so it calls this directly once the user has agreed.
    func runConfirmed(_ action: ProcessAction, on group: AppGroup) {
        guard ProcessActions.canAct(on: group, action: action) else {
            show(Self.refusal(action, group))
            return
        }
        run(PendingAction(action: action, group: group))
    }

    func show(_ message: String) {
        toast = message
        AccessibilityNotification.Announcement(message).post()
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: Self.toastDuration)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // Quit only asks a program to exit and apps still prompt to save, so it runs at once.
    // Force Quit and Suspend can lose work, so they still confirm.
    private func ask(_ pending: PendingAction) {
        if pending.action == .resume || pending.action == .quit {
            run(pending)
        } else {
            self.pending = pending
        }
    }

    // The confirmation may have sat open for a while, so act on what is running now rather than the snapshot shown in the dialog.
    private func run(_ pending: PendingAction) {
        switch pending.target {
        case .group(let snapshot):
            guard let current = store.liveGroup(id: snapshot.id) else {
                show("\(snapshot.name) has already quit.")
                return
            }
            guard ProcessActions.canAct(on: current, action: pending.action) else {
                show(Self.refusal(pending.action, current))
                return
            }
            show(ProcessActions.perform(pending.action, on: current).message(for: pending.action, name: current.name))
        case .process(let snapshot, _):
            guard let current = store.liveProcess(id: snapshot.id) else {
                show("\(snapshot.name) has already exited.")
                return
            }
            show(ProcessActions.perform(pending.action, on: current).message(for: pending.action, name: current.name))
        case .processes(let items, let title):
            let current = items.compactMap { store.liveProcess(id: $0.sample.id) }
            guard !current.isEmpty else {
                show("\(title) had already exited.")
                return
            }
            show(ProcessActions.perform(pending.action, on: current).message(for: pending.action, name: title))
        }
    }
}

struct ActionConfirmation: ViewModifier {
    @Bindable var controller: ActionController

    func body(content: Content) -> some View {
        content.confirmationDialog(
            controller.pending?.title ?? "",
            isPresented: Binding(get: { controller.pending != nil }, set: { if !$0 { controller.pending = nil } }),
            presenting: controller.pending
        ) { pending in
            if pending.action.isDestructive {
                Button(pending.action.title, role: .destructive) { controller.confirm() }
            } else {
                Button(pending.action.title) { controller.confirm() }
                    .keyboardShortcut(.defaultAction)
            }
            Button("Cancel", role: .cancel) { controller.pending = nil }
        } message: { pending in
            Text(pending.message)
        }
    }
}

extension View {
    func actionConfirmation(_ controller: ActionController) -> some View {
        modifier(ActionConfirmation(controller: controller))
    }
}
