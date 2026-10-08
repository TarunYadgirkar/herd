import SwiftUI

struct SettingsView: View {
    @Environment(MonitorStore.self) private var store
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @AppStorage("autoOpenInspector") private var autoOpenInspector = false
    @AppStorage("menuBarLabelStyle") private var menuBarLabelStyle: MenuBarLabelStyle = .cpuAndMemory
    @AppStorage(AlertSettings.enabledKey) private var alertsEnabled = true
    @AppStorage(DockGraphSettings.enabledKey) private var dockGraph = false
    @AppStorage(AlertSettings.cpuThresholdKey) private var cpuThreshold = AlertSettings.defaultCPUThreshold
    @AppStorage(AlertSettings.cpuMinutesKey) private var cpuMinutes = AlertSettings.defaultCPUMinutes

    private static let thresholds: [Double] = [50, 80, 90, 150, 200, 400]
    private static let durations: [Double] = [1, 3, 5, 10]

    var body: some View {
        @Bindable var store = store
        Form {
            Section("General") {
                Picker("Update every", selection: $store.interval) {
                    ForEach(UpdateInterval.allCases) { Text($0.title).tag($0) }
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
            Section("Alerts") {
                Toggle("Runaway app alerts", isOn: $alertsEnabled)
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
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
