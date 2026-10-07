import SwiftUI

struct SettingsView: View {
    @Environment(MonitorStore.self) private var store
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @AppStorage("autoOpenInspector") private var autoOpenInspector = false
    @AppStorage("menuBarLabelStyle") private var menuBarLabelStyle: MenuBarLabelStyle = .cpuAndMemory

    var body: some View {
        @Bindable var store = store
        Form {
            Picker("Update numbers", selection: $store.interval) {
                ForEach(UpdateInterval.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Show Herd in the menu bar", isOn: $showMenuBarExtra)
            Picker("Menu bar shows", selection: $menuBarLabelStyle) {
                ForEach(MenuBarLabelStyle.allCases) { Text($0.title).tag($0) }
            }
            .disabled(!showMenuBarExtra)
            Toggle("Open details when you select an app", isOn: $autoOpenInspector)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
