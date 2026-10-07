import Observation
import SwiftUI

struct PendingAction: Identifiable {
    let action: ProcessAction
    let group: AppGroup

    var id: String { "\(action.rawValue):\(group.id)" }

    var title: String {
        let count = group.processes.count
        let suffix = count > 1 ? " and its \(count) processes" : ""
        return "\(action.title) \(group.name)\(suffix)?"
    }

    var message: String {
        switch action {
        case .forceQuit: "Unsaved changes in \(group.name) will be lost."
        case .quit: "\(group.name) will close the way it does when you quit it normally."
        case .suspend: "\(group.name) will freeze and stop using CPU until you resume it. Its windows won't respond while paused."
        case .resume: "\(group.name) will continue where it left off."
        }
    }
}

@MainActor
@Observable
final class ActionController {
    var pending: PendingAction?
    private(set) var toast: String?

    @ObservationIgnored private var toastTask: Task<Void, Never>?
    private static let toastDuration = Duration.seconds(4)

    func request(_ action: ProcessAction, on group: AppGroup) {
        guard ProcessActions.canAct(on: group) else {
            show("\(group.name) is part of macOS and can't be stopped safely.")
            return
        }
        if action == .resume {
            run(action, on: group)
            return
        }
        pending = PendingAction(action: action, group: group)
    }

    func confirm() {
        guard let pending else { return }
        self.pending = nil
        run(pending.action, on: pending.group)
    }

    func perform(_ action: ProcessAction, on sample: ProcessSample) {
        let outcome = ProcessActions.perform(action, on: sample)
        show(outcome.message ?? "\(action.pastTense) \(sample.name)")
    }

    private func run(_ action: ProcessAction, on group: AppGroup) {
        let outcome = ProcessActions.perform(action, on: group)
        show(outcome.message ?? "\(action.pastTense) \(group.name)")
    }

    func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: Self.toastDuration)
            guard !Task.isCancelled else { return }
            self?.toast = nil
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
            Button(pending.action.title, role: pending.action == .forceQuit ? .destructive : nil) {
                controller.confirm()
            }
            .keyboardShortcut(.defaultAction)
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
