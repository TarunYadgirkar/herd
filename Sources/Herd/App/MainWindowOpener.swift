import AppKit
import SwiftUI

// A notification click lands in the app delegate, which has no scene to ask for a window. Every scene hands over its
// openWindow action as it draws, so the main window can be reopened by whichever of them the app still has: the menu
// bar item, Settings, the floating window or a Process Info window.
@MainActor
enum MainWindowOpener {
    private static var action: OpenWindowAction?
    private static var isOpenPending = false

    static func capture(_ action: OpenWindowAction) {
        self.action = action
        guard isOpenPending else { return }
        isOpenPending = false
        // Capture can run while a view is drawing, and opening a window from there changes state mid-update.
        DispatchQueue.main.async { open() }
    }

    // A click that launches Herd arrives before any scene has drawn, so the request waits for the first one.
    static func open() {
        guard let action else {
            isOpenPending = true
            return
        }
        action(id: "main")
        NSApp.activate()
    }
}

private struct MainWindowOpenerCapture: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear { MainWindowOpener.capture(openWindow) }
    }
}

extension View {
    func capturesMainWindowOpener() -> some View {
        modifier(MainWindowOpenerCapture())
    }
}
