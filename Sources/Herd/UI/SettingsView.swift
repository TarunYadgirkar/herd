import SwiftUI
import UserNotifications

struct SettingsView: View {
    private static let width: CGFloat = 480

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Alerts", systemImage: "bell.badge") { AlertSettingsPane() }
            Tab("Other devices", systemImage: "laptopcomputer.and.iphone") { RemoteSettings() }
        }
        .formStyle(.grouped)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SettingsFooter: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.captionText)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GeneralSettings: View {
    @Environment(MonitorStore.self) private var store
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @AppStorage("autoOpenInspector") private var autoOpenInspector = false
    @AppStorage("menuBarLabelStyle") private var menuBarLabelStyle: MenuBarLabelStyle = .cpuAndMemory
    @AppStorage(DockGraphSettings.enabledKey) private var dockGraph = false

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Picker(selection: $store.powerMode) {
                    ForEach(PowerMode.allCases) { Text($0.title).tag($0) }
                } label: {
                    PowerModeLabel(effort: store.effort, mode: store.powerMode)
                }
            } footer: {
                SettingsFooter(Self.modeHelp)
            }
            Section {
                Toggle("Open details when a row is selected", isOn: $autoOpenInspector)
                Toggle("CPU graph in Dock", isOn: $dockGraph)
            }
            Section("Menu bar") {
                Toggle("Show in menu bar", isOn: $showMenuBarExtra)
                Picker("Display", selection: $menuBarLabelStyle) {
                    ForEach(MenuBarLabelStyle.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!showMenuBarExtra)
            }
            Section {
                RootHelperRow()
            } header: {
                Text("System processes")
            } footer: {
                SettingsFooter(
                    "A small helper that runs as root reads exact numbers for system processes. "
                        + "Without it they update every 10 seconds, with no power or disk figures."
                )
            }
        }
    }

    private static var modeHelp: String {
        let light = Int(SamplingEffort.efficient.interval.rawValue)
        let full = Int(SamplingEffort.precise.interval.rawValue)
        return "Light updates every \(light) seconds and uses the least power. Full updates every \(full == 1 ? "second" : "\(full) seconds") "
            + "to catch short spikes. Automatic uses Full on the power adapter and Light on battery."
    }
}

private struct AlertSettingsPane: View {
    @AppStorage(AlertSettings.enabledKey) private var alertsEnabled = true
    @AppStorage(AlertSettings.cpuThresholdKey) private var cpuThreshold = AlertSettings.defaultCPUThreshold
    @AppStorage(AlertSettings.cpuMinutesKey) private var cpuMinutes = AlertSettings.defaultCPUMinutes

    @State private var notificationStatus: UNAuthorizationStatus?
    @State private var ignoredCount = AlertSettings.ignoredGroups.count

    private static let thresholds: [Double] = [50, 80, 90, 150, 200, 400]
    private static let durations: [Double] = [1, 3, 5, 10]

    var body: some View {
        Form {
            Section {
                Toggle("Runaway app alerts", isOn: $alertsEnabled)
                NotificationStatusRow(status: notificationStatus)
            }
            Section {
                Picker("CPU above", selection: $cpuThreshold) {
                    ForEach(Self.thresholds, id: \.self) { Text("\(Int($0))%").tag($0) }
                }
                Picker("For", selection: $cpuMinutes) {
                    ForEach(Self.durations, id: \.self) { Text("\(Int($0)) min").tag($0) }
                }
            } footer: {
                SettingsFooter("100% is one full core, so 200% means two cores busy the whole time.")
            }
            .disabled(!alertsEnabled)
            Section {
                LabeledContent(ignoredTitle) {
                    Button("Reset") {
                        UserDefaults.standard.removeObject(forKey: AlertSettings.ignoredKey)
                        ignoredCount = 0
                    }
                    .disabled(ignoredCount == 0)
                }
            } footer: {
                SettingsFooter("Apps you silenced from an alert stay quiet until you reset them.")
            }
        }
        .task { await refreshNotificationStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            ignoredCount = AlertSettings.ignoredGroups.count
            Task { await refreshNotificationStatus() }
        }
    }

    private var ignoredTitle: String {
        switch ignoredCount {
        case 0: "No ignored apps"
        case 1: "1 ignored app"
        default: "\(ignoredCount) ignored apps"
        }
    }

    private func refreshNotificationStatus() async {
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

private struct RemoteSettings: View {
    @AppStorage(RemoteMonitor.shareKey) private var shareStats = false
    @AppStorage(RemoteMonitor.hostsKey) private var remoteHosts = ""
    @AppStorage(ReportedBatteries.enabledKey) private var acceptReports = false

    @State private var isConfirmingReset = false

    private var reportHost: String? { RemoteNetwork.tailscaleAddress() }

    private func configureServer() {
        AppDelegate.remoteServer.configure(sharesStats: shareStats, acceptsReports: acceptReports)
    }

    private func copy(_ text: String?) {
        guard let text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func copyReportAddress() {
        guard let reportHost, let key = RemoteKey.own() else { return }
        copy(BatteryReport.address(host: reportHost, key: key))
    }

    private func resetKey() {
        RemoteKey.reset()
        configureServer()
    }

    var body: some View {
        Form {
            Section {
                Toggle("Share this Mac's stats", isOn: $shareStats)
                    .onChange(of: shareStats) { configureServer() }
            } footer: {
                SettingsFooter("Uses Tailscale. Only devices on your tailnet that have this Mac's key can read the shared stats (port \(String(RemoteNetwork.port))).")
            }
            Section {
                LabeledContent("This Mac's key") {
                    HStack(spacing: Theme.itemSpacing) {
                        Button("Copy key") { copy(RemoteKey.own()) }
                        Button("Reset key", role: .destructive) { isConfirmingReset = true }
                    }
                }
                .confirmationDialog("Reset this Mac's key?", isPresented: $isConfirmingReset) {
                    Button("Reset key", role: .destructive) { resetKey() }
                } message: {
                    Text("Your other Macs and your Shortcuts stop working until you give them the new key.")
                }
            } footer: {
                SettingsFooter("Paste this key into Herd on each Mac that watches this one. The key stays in your Keychain.")
            }
            Section {
                TextField("Watch Macs", text: $remoteHosts, prompt: Text("old-macbook, mac-mini"))
                    .onSubmit { AppDelegate.remote.refreshNow() }
                ForEach(RemoteNetwork.hosts(from: remoteHosts), id: \.self) { RemoteKeyRow(host: $0) }
            } footer: {
                SettingsFooter("Tailscale names separated by commas. Each Mac needs Herd running with sharing turned on, and its key pasted here.")
            }
            Section {
                Toggle("Show battery reports from my iPhone and Watch", isOn: $acceptReports)
                    .onChange(of: acceptReports) { configureServer() }
                if acceptReports, let reportHost {
                    LabeledContent("Report address") {
                        Text("\(reportHost):\(String(RemoteNetwork.port))")
                            .font(.metricSmall)
                    }
                    Button("Copy address with key") { copyReportAddress() }
                }
            } footer: {
                SettingsFooter(acceptReports && reportHost == nil
                    ? "Tailscale isn't connected on this Mac, so there is no address to report to yet."
                    : "In Shortcuts on the device, add Get Battery Level, then Get Contents of URL with this address and the battery level on the end. "
                        + "Run it from an automation so it stays current. Add &kind=watch for a Watch. The address includes this Mac's key, so only your devices can report.")
            }
        }
    }
}

// The key of one watched Mac. It goes straight to the Keychain and is never shown again, so the row only says whether one is saved.
private struct RemoteKeyRow: View {
    let host: String

    @State private var draft = ""
    @State private var hasKey = false

    var body: some View {
        LabeledContent("Key for \(host)") {
            HStack(spacing: Theme.itemSpacing) {
                Image(systemName: hasKey ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(hasKey ? Theme.good : Theme.warning)
                    .accessibilityLabel(hasKey ? "Key saved" : RemoteSummary.needsKey)
                SecureField("Key for \(host)", text: $draft, prompt: Text(hasKey ? "Saved. Paste to replace" : "Paste that Mac's key"))
                    .labelsHidden()
                    .onChange(of: draft) { save() }
            }
        }
        .task(id: host) { hasKey = AppDelegate.remote.hasKey(for: host) }
    }

    private func save() {
        guard let key = RemoteKey.cleaned(draft) else { return }
        AppDelegate.remote.setKey(key, for: host)
        hasKey = AppDelegate.remote.hasKey(for: host)
        draft = ""
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
