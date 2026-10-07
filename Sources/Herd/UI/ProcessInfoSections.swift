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
    var symbol: String?

    var body: some View {
        Group {
            if let symbol {
                Label(text, systemImage: symbol)
            } else {
                Text(text)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

private struct HiddenNote: View {
    var body: some View {
        PlainNote(text: "Hidden by macOS", symbol: "lock.fill")
    }
}

private struct StatusGlyph: View {
    let symbol: String
    let color: Color
    let label: String

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(color)
            .accessibilityLabel(label)
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
            LabeledContent("Parent") {
                Text(details.parentChain.map { "\($0.name) (\($0.pid))" }.joined(separator: " › "))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            if let responsible { LabeledContent("Responsible", value: responsible) }
            if let started = details.started {
                LabeledContent("Started") {
                    HStack(spacing: Theme.itemSpacing) {
                        Text(started.formatted(date: .abbreviated, time: .shortened))
                        Label(Format.duration(Date().timeIntervalSince(started)), systemImage: "timer")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("running for \(Format.duration(Date().timeIntervalSince(started)))")
                    }
                    .monospacedDigit()
                }
            }
            if let cpuTime = details.cpuTime {
                LabeledContent("CPU time") { Text(Self.cpuTimeText(cpuTime)).monospacedDigit() }
            }
            LabeledContent("Priority") { priority }
            if let directory = details.workingDirectory {
                LabeledContent("Folder") {
                    Text(ScriptLabel.abbreviate(directory)).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(directory)
                }
            }
        } footer: {
            if isPrivate { HiddenNote() }
        }
    }

    private var responsible: String? {
        guard sample.responsiblePid != sample.pid else { return nil }
        let name = store.groups.lazy.flatMap(\.processes).first { $0.sample.pid == sample.responsiblePid }?.sample.name ?? groupName
        return name.map { "\($0) (\(sample.responsiblePid))" }
    }

    @ViewBuilder
    private var priority: some View {
        if details.isEfficiencyMode == true {
            Label("Efficiency", systemImage: "leaf").foregroundStyle(Theme.accent)
        } else if let nice = details.nice, nice != 0 {
            Label("nice \(nice)", systemImage: nice > 0 ? "arrow.down" : "arrow.up")
                .monospacedDigit()
                .accessibilityLabel("\(nice > 0 ? "Low" : "High"), nice \(nice)")
        } else {
            Text("Normal")
        }
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
                LabeledContent("Signature") { status(signature) }
                if signature.isSigned { signedRows(signature) }
            } else {
                LabeledContent("Signature") {
                    StatusGlyph(symbol: "questionmark.circle", color: .secondary, label: "Unreadable")
                        .help("Executable missing or unreadable")
                }
            }
            if let bundleIdentifier { LabeledContent("Bundle ID") { Text(bundleIdentifier).textSelection(.enabled) } }
            if let bundleVersion { LabeledContent("Version") { Text(bundleVersion).monospacedDigit().textSelection(.enabled) } }
        }
    }

    @ViewBuilder
    private func signedRows(_ signature: ProcessDetails.Signature) -> some View {
        LabeledContent("Seal") {
            if signature.isValid {
                StatusGlyph(symbol: "checkmark.seal.fill", color: Theme.good, label: "Intact")
            } else {
                StatusGlyph(symbol: "xmark.seal.fill", color: Theme.critical, label: "Broken, code changed after signing")
                    .help("Code changed after signing")
            }
        }
        if let identifier = signature.identifier {
            LabeledContent("Identifier") { Text(identifier).textSelection(.enabled) }
        }
        if let teamID = signature.teamID {
            LabeledContent("Team ID") { Text(teamID).font(.metric).textSelection(.enabled) }
        }
        if let notarized = signature.isNotarizedHint {
            LabeledContent("Notarized") {
                notarized
                    ? StatusGlyph(symbol: "checkmark.circle.fill", color: Theme.good, label: "Yes")
                    : StatusGlyph(symbol: "xmark.circle", color: .secondary, label: "No ticket found")
            }
        }
        if !signature.authority.isEmpty {
            LabeledContent("Certificates") {
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(signature.authority, id: \.self) { Text($0) }
                }
                .textSelection(.enabled)
            }
        }
    }

    private func status(_ signature: ProcessDetails.Signature) -> some View {
        let (symbol, color, text, label) = statusParts(signature)
        return Label(text, systemImage: symbol)
            .foregroundStyle(color)
            .accessibilityLabel(label)
    }

    private func statusParts(_ signature: ProcessDetails.Signature) -> (String, Color, String, String) {
        if !signature.isSigned { return ("xmark.seal", Theme.warning, "None", "Not signed") }
        if !signature.isValid { return ("exclamationmark.triangle.fill", Theme.critical, "Broken", "Signature broken") }
        if signature.isApple { return ("apple.logo", Theme.good, "Apple", "Signed by Apple") }
        if signature.isAdHoc { return ("seal", Theme.neutral, "Ad hoc", "Ad-hoc signed") }
        let signer = signature.signerName ?? "Developer"
        return ("checkmark.seal.fill", Theme.accent, signer, "Signed by \(signer)")
    }
}

private struct NetworkSection: View {
    let connections: [ProcessDetails.Connection]
    let isPrivate: Bool

    var body: some View {
        Section {
            if !listening.isEmpty {
                LabeledContent("Listening") {
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
                if isPrivate { HiddenNote() } else { PlainNote(text: "None") }
            } else {
                connectionGrid
            }
        } header: {
            SectionHeader(title: "Network", detail: connections.isEmpty ? nil : countText)
        }
    }

    private var countText: String {
        let count = connections.count
        return count >= ProcessDetails.maxConnections ? "\(count)+" : "\(count)"
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
                if isPrivate { HiddenNote() } else { PlainNote(text: "None") }
            } else {
                TextField("Filter", text: $query, prompt: Text("Filter"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                fileList
            }
        } header: {
            SectionHeader(title: "Open files", detail: files.isEmpty ? nil : countText)
        }
    }

    private var countText: String {
        total > files.count ? "\(files.count) of \(total)" : "\(total)"
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
                PlainNote(text: "No matches", symbol: "magnifyingglass")
                Spacer()
                Button("Clear") { query = "" }.controlSize(.small)
            }
        } else {
            ForEach(matches) { file in
                HStack(alignment: .firstTextBaseline, spacing: Theme.itemSpacing) {
                    Text(String(file.id))
                        .font(.metricSmall)
                        .foregroundStyle(.tertiary)
                        .frame(minWidth: 28, alignment: .trailing)
                        .help("File descriptor")
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
                    MonospacedBlock(text: environment.joined(separator: "\n"))
                } label: {
                    Text("\(environment.count) variables").monospacedDigit()
                }
            } else {
                HiddenNote()
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
            MonospacedBlock(text: commandLine)
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

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemSpacing) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Copy", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .controlSize(.small)
        }
    }
}
