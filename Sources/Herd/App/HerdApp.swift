import AppKit
import SwiftUI

@main
struct HerdApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppDelegate.store
    @State private var actions = ActionController()
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    var body: some Scene {
        Window("Herd", id: "main") {
            ContentView()
                .environment(store)
                .environment(actions)
                .frame(minWidth: 760, minHeight: 480)
                .task { store.start() }
        }
        .defaultSize(width: 1080, height: 720)
        .commands { HerdCommands(store: store) }

        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarView()
                .environment(store)
                .environment(actions)
                .task { store.start() }
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static let store = MonitorStore()

    // Sampling has to start even when no window opens at launch, because the menu bar label needs live numbers.
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { Self.store.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Self.store.stop() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: "showMenuBarExtra") && UserDefaults.standard.object(forKey: "showMenuBarExtra") != nil
    }
}

struct HerdCommands: Commands {
    let store: MonitorStore

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button(store.isPaused ? "Resume Updates" : "Pause Updates") { store.isPaused.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Refresh Now") { store.refreshNow() }
                .keyboardShortcut("r")
        }
    }
}
