import Observation
import SwiftUI

struct PendingAction: Identifiable {
    enum Target {
        case group(AppGroup)
        case process(ProcessSample, groupName: String)
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

    var id: String {
        switch target {
        case .group(let group): "\(action.rawValue):\(group.id)"
        case .process(let sample, _): "\(action.rawValue):\(sample.id)"
        }
    }

    var name: String {
        switch target {
        case .group(let group): group.name
        case .process(let sample, _): sample.name
        }
    }

    var title: String {
        switch target {
        case .group(let group):
            let count = group.processes.count
            return "\(action.title) \(group.name)\(count > 1 ? " and its \(count) processes" : "")?"
        case .process(let sample, let groupName):
            return "\(action.title) \(sample.name) (\(sample.pid)) from \(groupName)?"
        }
    }

    var message: String {
        switch action {
        case .forceQuit: "Unsaved changes in \(name) will be lost."
        case .quit: "\(name) will close the way it does when you quit it normally."
        case .suspend: "\(name) will freeze and stop using CPU until you resume it. Its windows won't respond while paused."
        case .resume: "\(name) will continue where it left off."
        }
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
            show("\(group.name) keeps macOS running, so Herd won't \(action.title.lowercased()) it.")
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

    func confirm() {
        guard let pending else { return }
        self.pending = nil
        run(pending)
    }

    // The menu bar asks through its own alert, so it calls this directly once the user has agreed.
    func runConfirmed(_ action: ProcessAction, on group: AppGroup) {
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

    private func ask(_ pending: PendingAction) {
        if pending.action == .resume {
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
            show(ProcessActions.perform(pending.action, on: current).message(for: pending.action, name: current.name))
        case .process(let snapshot, _):
            guard let current = store.liveProcess(id: snapshot.id) else {
                show("\(snapshot.name) has already exited.")
                return
            }
            show(ProcessActions.perform(pending.action, on: current).message(for: pending.action, name: current.name))
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
