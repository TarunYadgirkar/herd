import AppKit
import SwiftUI

struct DetailSections: View {
    let sample: ProcessSample
    let details: ProcessDetails
    let groupName: String?

    // proc_pidinfo fails for processes owned by root or another user, so a missing thread count means macOS hid the rest too.
    private var isPrivate: Bool { details.threads == nil }

    var body: some View {
        GeneralSection(sample: sample, details: details, groupName: groupName, isPrivate: isPrivate)
        SignatureSection(signature: details.signature, bundleIdentifier: details.bundleIdentifier, bundleVersion: details.bundleVersion)
        NetworkSection(connections: details.connections, isPrivate: isPrivate)
        OpenFilesSection(files: details.files, total: details.openFileCount, isPrivate: isPrivate)
        EnvironmentSection(environment: details.environment)
        CommandLineSection(arguments: details.arguments.isEmpty ? sample.arguments : details.arguments, fallback: sample.path)
    }
}

private struct SectionHeader: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            if let detail {
                Text(detail).font(.metricSmall).foregroundStyle(.secondary)
            }
        }
    }
}

private struct PlainNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSection: View {
    let sample: ProcessSample
    let details: ProcessDetails
    let groupName: String?
    let isPrivate: Bool

    @Environment(MonitorStore.self) private var store

    var body: some View {
        Section {
            LabeledContent("Launched by") {
                Text(details.parentChain.map { "\($0.name) (\($0.pid))" }.joined(separator: " › "))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            if let responsible { LabeledContent("Responsible process", value: responsible) }
            if let started = details.started {
                LabeledContent("Started") {
                    Text("\(started.formatted(date: .abbreviated, time: .shortened)), running for \(Format.duration(Date().timeIntervalSince(started)))")
                        .monospacedDigit()
                }
            }
            if let cpuTime = details.cpuTime {
                LabeledContent("CPU time") { Text(Self.cpuTimeText(cpuTime)).monospacedDigit() }
            }
            LabeledContent("Priority", value: priorityText)
            if let directory = details.workingDirectory {
                LabeledContent("Working folder") {
                    Text(ScriptLabel.abbreviate(directory)).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(directory)
                }
            }
        } header: {
            SectionHeader(title: "General")
        } footer: {
            if isPrivate {
                PlainNote(text: "macOS keeps CPU time, open files, and the environment of processes owned by the system or another user private.")
            }
        }
    }

    private var responsible: String? {
        guard sample.responsiblePid != sample.pid else { return nil }
        let name = store.groups.lazy.flatMap(\.processes).first { $0.sample.pid == sample.responsiblePid }?.sample.name ?? groupName
        return name.map { "\($0) (\(sample.responsiblePid))" }
    }

    private var priorityText: String {
        if details.isEfficiencyMode == true { return "Efficiency mode" }
        guard let nice = details.nice else { return "Normal" }
        if nice > 0 { return "Low (nice \(nice))" }
        if nice < 0 { return "High (nice \(nice))" }
        return "Normal"
    }

    private static let secondsPerMinute: TimeInterval = 60

    static func cpuTimeText(_ seconds: TimeInterval) -> String {
        guard seconds >= secondsPerMinute else { return String(format: "%.2f s", seconds) }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? ""
    }
}

private struct SignatureSection: View {
    let signature: ProcessDetails.Signature?
    let bundleIdentifier: String?
    let bundleVersion: String?

    var body: some View {
        Section {
            if let signature {
                LabeledContent("Status") { pill(signature) }
                if signature.isSigned { signedRows(signature) }
            } else {
                PlainNote(text: "Herd couldn't read the signature because the executable is missing or unreadable.")
            }
            if let bundleIdentifier { LabeledContent("Bundle ID") { Text(bundleIdentifier).textSelection(.enabled) } }
            if let bundleVersion { LabeledContent("Version") { Text(bundleVersion).monospacedDigit().textSelection(.enabled) } }
        } header: {
            SectionHeader(title: "Signature")
        }
    }

    @ViewBuilder
    private func signedRows(_ signature: ProcessDetails.Signature) -> some View {
        LabeledContent("Seal", value: signature.isValid ? "Intact" : "Broken. The code changed after it was signed.")
        if let identifier = signature.identifier {
            LabeledContent("Identifier") { Text(identifier).textSelection(.enabled) }
        }
        if let teamID = signature.teamID {
            LabeledContent("Team ID") { Text(teamID).font(.metric).textSelection(.enabled) }
        }
        if let notarized = signature.isNotarizedHint {
            LabeledContent("Notarized", value: notarized ? "Yes, Apple checked it for malware" : "No ticket found")
        }
        if !signature.authority.isEmpty {
            LabeledContent("Certificate chain") {
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(signature.authority, id: \.self) { Text($0) }
                }
                .textSelection(.enabled)
            }
        }
    }

    private func pill(_ signature: ProcessDetails.Signature) -> StatePill {
        if !signature.isSigned { return StatePill(text: "Not signed", color: Theme.warning) }
        if !signature.isValid { return StatePill(text: "Signature broken", color: Theme.critical) }
        if signature.isApple { return StatePill(text: "Signed by Apple", color: Theme.good) }
        if signature.isAdHoc { return StatePill(text: "Ad-hoc signed", color: Theme.neutral) }
        return StatePill(text: "Signed by \(signature.signerName ?? "a developer")", color: Theme.accent)
    }
}

private struct NetworkSection: View {
    let connections: [ProcessDetails.Connection]
    let isPrivate: Bool

    var body: some View {
        Section {
            if !listening.isEmpty {
                LabeledContent("Listening on") {
                    HStack(spacing: 4) {
                        ForEach(listening, id: \.self) { endpoint in
                            Text(endpoint)
                                .font(.metricSmall)
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Theme.accent.opacity(0.12), in: Capsule())
                        }
                    }
                }
            }
            if connections.isEmpty {
                PlainNote(text: isPrivate ? "macOS doesn't share the connections of system processes." : "No open network connections.")
            } else {
                connectionGrid
            }
        } header: {
            SectionHeader(title: "Network", detail: connections.isEmpty ? nil : countText)
        }
    }

    private var countText: String {
        let count = connections.count
        let text = "\(count) \(count == 1 ? "connection" : "connections")"
        return count >= ProcessDetails.maxConnections ? "First \(text)" : text
    }

    private var listening: [String] {
        Array(Set(connections.filter(\.isListening).map(\.local))).sorted()
    }

    private var sorted: [ProcessDetails.Connection] {
        connections.sorted { ($0.isListening ? 0 : 1, $0.proto, $0.local) < ($1.isListening ? 0 : 1, $1.proto, $1.local) }
    }

    private var connectionGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            GridRow {
                Text("Protocol")
                Text("Local")
                Text("Remote")
                Text("State")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            ForEach(sorted) { connection in
                GridRow {
                    Text(connection.proto).foregroundStyle(.secondary)
                    endpoint(connection.local)
                    endpoint(connection.remote ?? "–")
                    Text(connection.state ?? "–").foregroundStyle(.secondary)
                }
                .font(.metricSmall)
            }
        }
        .textSelection(.enabled)
    }

    private func endpoint(_ text: String) -> some View {
        Text(text).lineLimit(1).truncationMode(.middle).help(text)
    }
}

private struct OpenFilesSection: View {
    let files: [ProcessDetails.OpenFile]
    let total: Int
    let isPrivate: Bool

    @State private var query = ""

    var body: some View {
        Section {
            if files.isEmpty {
                PlainNote(text: isPrivate ? "macOS doesn't share the open files of system processes." : "No open files.")
            } else {
                TextField("Filter by path", text: $query, prompt: Text("Filter by path"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                fileList
            }
        } header: {
            SectionHeader(title: "Open files", detail: files.isEmpty ? nil : countText)
        }
    }

    private var countText: String {
        total > files.count ? "First \(files.count) of \(total)" : "\(total)"
    }

    private var filtered: [ProcessDetails.OpenFile] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return files }
        return files.filter { $0.path.localizedCaseInsensitiveContains(trimmed) }
    }

    @ViewBuilder
    private var fileList: some View {
        let matches = filtered
        if matches.isEmpty {
            HStack {
                PlainNote(text: "No open files match “\(query)”.")
                Spacer()
                Button("Clear Filter") { query = "" }.controlSize(.small)
            }
        } else {
            ForEach(matches) { file in
                HStack(alignment: .firstTextBaseline, spacing: Theme.itemSpacing) {
                    Text(String(file.id))
                        .font(.metricSmall)
                        .foregroundStyle(.tertiary)
                        .frame(minWidth: 28, alignment: .trailing)
                        .help("File descriptor \(file.id)")
                    Text(ScriptLabel.abbreviate(file.path))
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(file.path)
                }
            }
        }
    }
}

private struct EnvironmentSection: View {
    let environment: [String]?

    @State private var isExpanded = false

    var body: some View {
        Section {
            if let environment, !environment.isEmpty {
                DisclosureGroup(isExpanded: $isExpanded) {
                    MonospacedBlock(text: environment.joined(separator: "\n"), copyTitle: "Copy Environment")
                } label: {
                    Text("Show \(environment.count) variables").monospacedDigit()
                }
            } else if environment != nil {
                PlainNote(text: "macOS keeps this process's environment private. Apps with the hardened runtime and built-in macOS tools hide it.")
            } else {
                PlainNote(text: "Only available for your own processes.")
            }
        } header: {
            SectionHeader(title: "Environment")
        }
    }
}

private struct CommandLineSection: View {
    let arguments: [String]
    let fallback: String

    var body: some View {
        Section {
            MonospacedBlock(text: commandLine, copyTitle: "Copy Command Line")
        } header: {
            SectionHeader(title: "Command line", detail: arguments.count > 1 ? "\(arguments.count) arguments" : nil)
        }
    }

    private var commandLine: String {
        guard !arguments.isEmpty else { return fallback }
        return arguments.map(Self.quoted).joined(separator: " ")
    }

    private static func quoted(_ argument: String) -> String {
        guard argument.contains(where: { $0 == " " || $0 == "\"" || $0 == "'" }) else { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private struct MonospacedBlock: View {
    let text: String
    let copyTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemSpacing) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copyTitle, systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .controlSize(.small)
        }
    }
}
