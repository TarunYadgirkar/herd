import AppKit
import SwiftUI
import UserNotifications

@main
struct HerdApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppDelegate.store
    @State private var actions = ActionController(store: AppDelegate.store)
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    var body: some Scene {
        Window("Herd", id: "main") {
            RootView()
                .environment(store)
                .environment(actions)
                .environment(\.historySamples, store.historySamples)
                .frame(minWidth: 960, minHeight: 540)
                .task { store.start() }
        }
        .defaultSize(width: 1280, height: 780)
        .commands { HerdCommands(store: store) }

        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarView()
                .environment(store)
                .environment(actions)
                .environment(\.historySamples, store.historySamples)
                .task { store.start() }
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        WindowGroup("Process Info", id: "process-info", for: String.self) { $processID in
            ProcessInfoView(processID: processID)
                .environment(store)
                .environment(actions)
                .environment(\.historySamples, store.historySamples)
        }
        .defaultSize(width: 560, height: 640)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        Window("Herd Mini", id: "mini") {
            MiniMonitorView()
                .environment(store)
                .environment(\.historySamples, store.historySamples)
        }
        .windowLevel(.floating)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.topTrailing)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static let store = MonitorStore()

    // Sampling has to start even when no window opens at launch, because the menu bar label needs live numbers.
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        PauseLedger.resumeAll()
        MainActor.assumeIsolated {
            Self.store.start()
            Self.store.alerts.requestAuthorization()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let groupID = response.notification.request.content.userInfo[AlertAction.groupKey] as? String
        await MainActor.run {
            guard let groupID else {
                NSApp.activate()
                return
            }
            switch action {
            case AlertAction.quit:
                guard let group = Self.store.liveGroup(id: groupID), group.isSafeQuitTarget else { return }
                _ = ProcessActions.perform(.quit, on: group)
            case AlertAction.ignore:
                AlertSettings.ignore(groupID)
            default:
                Self.store.requestedSelection = groupID
                NSApp.activate()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        PauseLedger.resumeAll()
        MainActor.assumeIsolated {
            Self.store.stop()
            Self.store.saveHistory()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: "showMenuBarExtra") && UserDefaults.standard.object(forKey: "showMenuBarExtra") != nil
    }
}

struct HerdCommands: Commands {
    let store: MonitorStore
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Show Floating Window") { openWindow(id: "mini") }
                .keyboardShortcut("f", modifiers: [.command, .option])
            Button(store.isPaused ? "Resume Updates" : "Pause Updates") { store.isPaused.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Refresh Now") { store.refreshNow() }
                .keyboardShortcut("r")
        }
    }
}
