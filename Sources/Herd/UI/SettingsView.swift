import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(MonitorStore.self) private var store
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @AppStorage("autoOpenInspector") private var autoOpenInspector = false
    @AppStorage("menuBarLabelStyle") private var menuBarLabelStyle: MenuBarLabelStyle = .cpuAndMemory
    @AppStorage(AlertSettings.enabledKey) private var alertsEnabled = true
    @AppStorage(DockGraphSettings.enabledKey) private var dockGraph = false
    @AppStorage(AlertSettings.cpuThresholdKey) private var cpuThreshold = AlertSettings.defaultCPUThreshold
    @AppStorage(AlertSettings.cpuMinutesKey) private var cpuMinutes = AlertSettings.defaultCPUMinutes

    @State private var notificationStatus: UNAuthorizationStatus?

    private static let thresholds: [Double] = [50, 80, 90, 150, 200, 400]
    private static let durations: [Double] = [1, 3, 5, 10]

    var body: some View {
        @Bindable var store = store
        Form {
            Section("General") {
                Picker(selection: $store.powerMode) {
                    ForEach(PowerMode.allCases) { Text($0.title).tag($0) }
                } label: {
                    PowerModeLabel(effort: store.effort, mode: store.powerMode)
                }
                Toggle("Open details on select", isOn: $autoOpenInspector)
                Toggle("CPU graph in Dock", isOn: $dockGraph)
            }
            Section("Menu bar") {
                Toggle("Show in menu bar", isOn: $showMenuBarExtra)
                Picker("Display", selection: $menuBarLabelStyle) {
                    ForEach(MenuBarLabelStyle.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!showMenuBarExtra)
            }
            Section("System processes") {
                RootHelperRow()
            }
            Section("Alerts") {
                Toggle("Runaway app alerts", isOn: $alertsEnabled)
                NotificationStatusRow(status: notificationStatus)
                Picker("CPU above", selection: $cpuThreshold) {
                    ForEach(Self.thresholds, id: \.self) { Text("\(Int($0))%").tag($0) }
                }
                .help("100% = one core")
                .disabled(!alertsEnabled)
                Picker("For", selection: $cpuMinutes) {
                    ForEach(Self.durations, id: \.self) { Text("\(Int($0)) min").tag($0) }
                }
                .disabled(!alertsEnabled)
                Button("Reset Ignored Apps") { UserDefaults.standard.removeObject(forKey: AlertSettings.ignoredKey) }
                    .disabled(AlertSettings.ignoredGroups.isEmpty)
            }
        }
        .formStyle(.grouped)
        .task { notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// Alerts only reach the user if macOS allows Herd's notifications, so the state is shown where alerts are configured.
private struct NotificationStatusRow: View {
    let status: UNAuthorizationStatus?

    private static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.tarunyadgirkar.herd")

    var body: some View {
        LabeledContent("Notifications") {
            HStack(spacing: Theme.itemSpacing) {
                Image(systemName: isAllowed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(isAllowed ? Theme.good : Theme.warning)
                Text(title)
                if !isAllowed, let url = Self.settingsURL {
                    Button("Open Settings") { NSWorkspace.shared.open(url) }
                }
            }
        }
    }

    private var isAllowed: Bool { status == .authorized || status == .provisional }

    private var title: String {
        switch status {
        case .authorized, .provisional: "Allowed"
        case .denied: "Off in System Settings"
        default: "Not set up"
        }
    }
}

// Without the helper, root and system processes come from top every 10 seconds, with no power or disk numbers.
// macOS asks for approval in Login Items before a root helper can run, so the row walks through that step.
private struct RootHelperRow: View {
    @State private var state: RootHelperState = .off
    @State private var failure: String?

    private static let approvalPoll: Duration = .seconds(2)

    var body: some View {
        LabeledContent("Exact stats") {
            HStack(spacing: Theme.itemSpacing) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                Text(failure ?? title)
                action
            }
        }
        .task(id: state) {
            state = RootHelper.shared.state
            while state == .needsApproval, !Task.isCancelled {
                try? await Task.sleep(for: Self.approvalPoll)
                state = RootHelper.shared.state
            }
        }
    }

    @ViewBuilder
    private var action: some View {
        switch state {
        case .off:
            Button("Turn On") { turnOn() }
        case .needsApproval:
            Button("Open Login Items") { RootHelper.shared.openApprovalSettings() }
        case .on:
            Button("Turn Off") { Task { await turnOff() } }
        case .unavailable:
            EmptyView()
        }
    }

    private var title: String {
        switch state {
        case .on: "On"
        case .needsApproval: "Allow in Login Items"
        case .off: "Off"
        case .unavailable: "Needs a signed build"
        }
    }

    private var symbol: String {
        switch state {
        case .on: "checkmark.circle.fill"
        case .needsApproval: "exclamationmark.triangle.fill"
        case .off, .unavailable: "circle.dashed"
        }
    }

    private var color: Color {
        switch state {
        case .on: Theme.good
        case .needsApproval: Theme.warning
        case .off, .unavailable: Theme.neutral
        }
    }

    // register() throws "Operation not permitted" when macOS still needs the user's approval, which the row already shows.
    private func turnOn() {
        var message: String?
        do {
            try RootHelper.shared.register()
        } catch {
            message = "Couldn't turn on: \(error.localizedDescription)"
        }
        state = RootHelper.shared.state
        failure = state == .needsApproval ? nil : message
        if state == .needsApproval { RootHelper.shared.openApprovalSettings() }
    }

    private func turnOff() async {
        do {
            try await RootHelper.shared.unregister()
            failure = nil
        } catch {
            failure = "Couldn't turn off: \(error.localizedDescription)"
        }
        state = RootHelper.shared.state
    }
}

// Automatic hides which mode is running, so the label carries the live one: a scope for Full, a leaf for Light.
private struct PowerModeLabel: View {
    let effort: SamplingEffort
    let mode: PowerMode

    var body: some View {
        HStack(spacing: Theme.itemSpacing) {
            Text("Mode")
            if mode == .automatic {
                Label(effort.title, systemImage: effort.symbol)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(effort == .efficient ? Theme.good : Theme.accent)
                    .help("\(effort.title) now: every \(Int(effort.interval.rawValue)) s")
            }
        }
    }
}
