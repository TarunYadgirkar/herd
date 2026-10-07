import AppKit
import SwiftUI

struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: VisibilityView, context: Context) {
        nsView.onChange = onChange
    }

    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else {
                onChange?(false)
                return
            }
            let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification]
            observers = names.map { name in
                let isClosing = name == NSWindow.willCloseNotification
                return NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.onChange?(!isClosing && window.occlusionState.contains(.visible))
                    }
                }
            }
            onChange?(window.occlusionState.contains(.visible))
        }
    }
}
