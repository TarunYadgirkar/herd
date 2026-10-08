import AppKit
import SwiftUI

struct ProcessInfoView: View {
    let processID: String?

    @Environment(MonitorStore.self) private var store
    @State private var snapshot: ProcessSample?

    var body: some View {
        if let sample = snapshot ?? processID.flatMap(store.liveProcess(id:)) {
            ProcessInfoContent(sample: sample)
                .onAppear { snapshot = sample }
        } else {
            ContentUnavailableView("Exited", systemImage: "xmark.circle")
            .navigationTitle("Process Info")
        }
    }
}

extension MonitorStore {
    // liveProcess reads the unpublished frame, so touching groups is what makes a view redraw on every update.
    func observedProcess(id: String) -> ProcessSample? {
        _ = groups
        return liveProcess(id: id)
    }

    func groupName(containing id: String) -> String? {
        groups.first { $0.processes.contains { $0.id == id } }?.name
    }
}

private struct ProcessInfoContent: View {
    let sample: ProcessSample

    @Environment(MonitorStore.self) private var store
    @State private var details: ProcessDetails?
    @State private var groupName: String?
    @State private var refreshToken = 0
    @State private var isSampling = false
    @State private var pendingAction: PendingAction?
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    private static let refreshInterval = Duration.seconds(5)
    private static let toastDuration = Duration.seconds(5)

    private struct LoadKey: Equatable {
        let id: String
        let token: Int
    }

    var body: some View {
        Form {
            Section {
                InfoHeader(sample: sample, groupName: groupName)
                InfoActions(
                    sample: sample,
                    isSampling: isSampling,
                    isEfficiencyMode: details?.isEfficiencyMode,
                    onSample: runSample,
                    onEfficiency: setEfficiency,
                    onAction: request
                )
                LiveStats(processID: sample.id)
            }
            if let details {
                DetailSections(sample: sample, details: details, groupName: groupName)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Reading process details")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("\(sample.name) (\(String(sample.pid)))")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { refreshToken += 1 }
        }
        .task(id: LoadKey(id: sample.id, token: refreshToken)) { await loadLoop() }
        .background(WindowVisibilityReader { store.setSurface("process-info:\(sample.id)", visible: $0) })
        .overlay(alignment: .bottom) { InfoToast(message: toast) }
        .animation(.easeOut(duration: 0.2), value: toast)
        .confirmationDialog(
            pendingAction?.title ?? "",
            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
            presenting: pendingAction
        ) { pending in
            if pending.action.isDestructive {
                Button(pending.action.title, role: .destructive) { perform(pending) }
            } else {
                Button(pending.action.title) { perform(pending) }
                    .keyboardShortcut(.defaultAction)
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: { pending in
            Text(pending.message)
        }
    }

    // Only the live stats and actions read the store directly, so the long file and connection lists don't redraw on every update.
    private func loadLoop() async {
        while !Task.isCancelled, store.liveProcess(id: sample.id) != nil {
            let pid = sample.pid
            let path = sample.path
            let prior = details
            let loaded = await Task.detached(priority: .userInitiated) {
                ProcessDetails.load(pid: pid, path: path, reusing: prior)
            }.value
            guard !Task.isCancelled else { return }
            details = loaded
            groupName = store.groupName(containing: sample.id) ?? groupName
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }

    private func runSample() {
        isSampling = true
        Task {
            let result = await ProcessTools.sample(pid: sample.pid, name: sample.name)
            isSampling = false
            switch result {
            case .report(let url):
                NSWorkspace.shared.open(url)
                show("Opened sample report")
            case .failed(let message):
                show(message)
            }
        }
    }

    private func setEfficiency(_ isOn: Bool) {
        show(ProcessTools.setEfficiencyMode(isOn, pid: sample.pid, name: sample.name))
        refreshToken += 1
    }

    // The main window owns ActionController's dialog, so this window confirms on its own and then acts on what is running now.
    private func request(_ action: ProcessAction) {
        guard let current = store.liveProcess(id: sample.id) else {
            show("\(sample.name) exited")
            return
        }
        guard !ProcessActions.isProtected(current, for: action) else {
            show("\(sample.name) is protected by macOS")
            return
        }
        let groupName = store.groupName(containing: sample.id) ?? sample.name
        pendingAction = PendingAction(action: action, process: current, groupName: groupName)
    }

    private func perform(_ pending: PendingAction) {
        pendingAction = nil
        guard let current = store.liveProcess(id: sample.id) else {
            show("\(sample.name) exited")
            return
        }
        show(ProcessActions.perform(pending.action, on: current).message(for: pending.action, name: current.name))
    }

    private func show(_ message: String) {
        toast = message
        AccessibilityNotification.Announcement(message).post()
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: Self.toastDuration)
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }
}

private struct InfoHeader: View {
    let sample: ProcessSample
    let groupName: String?

    private static let iconSize: CGFloat = 48

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemSpacing) {
            HStack(spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(sample.name)
                        .font(.sectionTitle)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    subtitle
                        .font(.subheadText.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if !sample.path.isEmpty { pathRow }
        }
    }

    private var subtitle: some View {
        HStack(spacing: Theme.itemSpacing) {
            Text("PID \(String(sample.pid))")
            if let groupName, groupName != sample.name {
                Label(groupName, systemImage: "square.stack")
                    .lineLimit(1)
                    .accessibilityLabel("Part of \(groupName)")
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let bundle = ProcessDetails.bundlePath(for: sample.path) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: bundle))
                .resizable()
                .frame(width: Self.iconSize, height: Self.iconSize)
                .accessibilityHidden(true)
        } else {
            FallbackIcon(symbol: "terminal", size: Self.iconSize)
        }
    }

    private var pathRow: some View {
        HStack(spacing: Theme.itemSpacing) {
            Text(ScriptLabel.abbreviate(sample.path))
                .font(.captionText)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(sample.path)
            Spacer(minLength: 0)
            Button("Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: sample.path)])
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }
}

private struct InfoActions: View {
    let sample: ProcessSample
    let isSampling: Bool
    let isEfficiencyMode: Bool?
    let onSample: @MainActor () -> Void
    let onEfficiency: @MainActor (Bool) -> Void
    let onAction: @MainActor (ProcessAction) -> Void

    @Environment(MonitorStore.self) private var store

    var body: some View {
        let isRunning = store.observedProcess(id: sample.id) != nil
        HStack(spacing: Theme.itemSpacing) {
            sampleButton.disabled(!isRunning || isSampling)
            efficiencyToggle.disabled(!isRunning || !canChangePriority)
            Spacer(minLength: 0)
            Button(ProcessAction.quit.title) { onAction(.quit) }
                .disabled(!isRunning || ProcessActions.isProtected(sample, for: .quit))
            Button(ProcessAction.forceQuit.title) { onAction(.forceQuit) }
                .tint(Theme.critical)
                .disabled(!isRunning || ProcessActions.isProtected(sample, for: .forceQuit))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder
    private var sampleButton: some View {
        if isSampling {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Image(systemName: "waveform.path.ecg").foregroundStyle(Theme.accent)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sampling")
        } else {
            Button("Sample", systemImage: "waveform.path.ecg", action: onSample)
                .help("3-second thread sample")
        }
    }

    // Pausing these freezes the desktop, and slowing them down does the same more gently, so they share the pause rules.
    private var canChangePriority: Bool {
        isEfficiencyMode != nil && !ProcessActions.isProtected(sample, for: .suspend)
    }

    private var efficiencyToggle: some View {
        Toggle(isOn: Binding(get: { isEfficiencyMode ?? false }, set: { onEfficiency($0) })) {
            Label("Efficiency", systemImage: "leaf")
        }
        .toggleStyle(.button)
        .tint(Theme.accent)
        .help(canChangePriority ? "Efficiency cores, low disk priority" : "Your own processes only")
    }
}

private struct LiveStats: View {
    let processID: String

    @Environment(MonitorStore.self) private var store

    var body: some View {
        if let live = store.observedProcess(id: processID) {
            VStack(alignment: .leading, spacing: Theme.itemSpacing) {
                if live.isSuspended {
                    Image(systemName: "pause.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.warning)
                        .accessibilityLabel("Paused")
                }
                HStack(spacing: Theme.itemSpacing) {
                    StatTile(title: "CPU", value: live.isUnavailable ? nil : prefix(live) + Format.percent(live.cpuPercent))
                    StatTile(title: "Memory", value: live.isUnavailable ? nil : prefix(live) + Format.bytes(live.memoryBytes))
                    StatTile(title: "CPU Power", value: live.isApproximate ? nil : Format.watts(live.energyWatts))
                    StatTile(title: "Threads", value: live.threads > 0 ? String(live.threads) : nil)
                }
            }
        } else {
            Label("Exited", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    private func prefix(_ live: ProcessSample) -> String {
        live.isApproximate ? "≈ " : ""
    }
}

private struct StatTile: View {
    let title: String
    let value: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.captionText)
                .foregroundStyle(.secondary)
            Text(value ?? "–")
                .font(.displaySmall)
                .foregroundStyle(value == nil ? .tertiary : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, Theme.itemSpacing)
        .surface()
        .accessibilityElement(children: .combine)
        .accessibilityValue(value ?? "Not available")
    }
}

private struct InfoToast: View {
    let message: String?

    var body: some View {
        if let message {
            Text(message)
                .font(.calloutText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                .shadow(color: Theme.shadow, radius: 8, y: 2)
                .padding(Theme.groupSpacing)
                .transition(.opacity.combined(with: .offset(y: 6)))
        }
    }
}
