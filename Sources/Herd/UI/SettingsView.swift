import SwiftUI

struct SettingsView: View {
    @Environment(MonitorStore.self) private var store
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @AppStorage("autoOpenInspector") private var autoOpenInspector = false
    @AppStorage("menuBarLabelStyle") private var menuBarLabelStyle: MenuBarLabelStyle = .cpuAndMemory
    @AppStorage(AlertSettings.enabledKey) private var alertsEnabled = true
    @AppStorage(AlertSettings.cpuThresholdKey) private var cpuThreshold = AlertSettings.defaultCPUThreshold
    @AppStorage(AlertSettings.cpuMinutesKey) private var cpuMinutes = AlertSettings.defaultCPUMinutes

    private static let thresholds: [Double] = [50, 80, 90, 150, 200, 400]
    private static let durations: [Double] = [1, 3, 5, 10]

    var body: some View {
        @Bindable var store = store
        Form {
            Section("General") {
                Picker("Update numbers", selection: $store.interval) {
                    ForEach(UpdateInterval.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Open details when you select an app", isOn: $autoOpenInspector)
            }
            Section("Menu bar") {
                Toggle("Show Herd in the menu bar", isOn: $showMenuBarExtra)
                Picker("Menu bar shows", selection: $menuBarLabelStyle) {
                    ForEach(MenuBarLabelStyle.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!showMenuBarExtra)
            }
            Section {
                Toggle("Notify me about runaway apps", isOn: $alertsEnabled)
                Picker("When an app uses more than", selection: $cpuThreshold) {
                    ForEach(Self.thresholds, id: \.self) { Text("\(Int($0))% CPU").tag($0) }
                }
                .disabled(!alertsEnabled)
                Picker("For at least", selection: $cpuMinutes) {
                    ForEach(Self.durations, id: \.self) { Text($0 == 1 ? "1 minute" : "\(Int($0)) minutes").tag($0) }
                }
                .disabled(!alertsEnabled)
                Button("Alert Me About Every App Again") { UserDefaults.standard.removeObject(forKey: AlertSettings.ignoredKey) }
                    .disabled(AlertSettings.ignoredGroups.isEmpty)
            } header: {
                Text("Alerts")
            } footer: {
                Text("Herd also tells you when memory runs out, when an app's memory grows by more than 3 GB in a few minutes, and when your Mac stays very hot. 100% CPU is one full core.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
