import Foundation
import os

// A phone or watch can't be asked for its charge over the network, so it tells Herd instead:
// a Shortcuts automation opens /battery?name=iPhone&level=83 on this Mac over Tailscale.
struct BatteryReport: Sendable, Equatable {
    static let path = "/battery"
    private static let maxNameLength = 40
    private static let methods: Set<Substring> = ["GET", "POST"]
    private static let truthy: Set<String> = ["1", "true", "yes"]
    // Shortcuts sends the device's model name ("iPhone", "Apple Watch", "iPad"), so kinds match on a word inside it.
    private static let kinds: [(String, DeviceBattery.Kind)] = [("watch", .watch), ("ipad", .tablet), ("tablet", .tablet), ("mac", .other)]

    let name: String
    let percent: Double
    let isCharging: Bool
    let kind: DeviceBattery.Kind

    static func isReport(_ request: String) -> Bool {
        methods.contains { request.hasPrefix("\($0) \(path)?") || request.hasPrefix("\($0) \(path) ") }
    }

    static func parse(request: String) -> BatteryReport? {
        guard let line = request.split(separator: "\r\n", omittingEmptySubsequences: false).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count == 3, methods.contains(parts[0]),
              let components = URLComponents(string: String(parts[1])), components.path == path else { return nil }
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        let name = String(String.UnicodeScalarView((query["name"] ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= maxNameLength,
              let level = query["level"].flatMap(Double.init), (0...100).contains(level) else { return nil }
        return BatteryReport(
            name: name,
            percent: level,
            isCharging: truthy.contains((query["charging"] ?? "").lowercased()),
            kind: kinds.first { (query["kind"] ?? "").lowercased().contains($0.0) }?.1 ?? .phone
        )
    }
}

final class ReportedBatteries: Sendable {
    static let shared = ReportedBatteries()
    static let enabledKey = "acceptBatteryReports"
    static let maxDevices = 12
    // A device that stops reporting is probably off or out of reach, and a day-old charge would mislead.
    static let expiry: TimeInterval = 86_400

    private struct Entry {
        let report: BatteryReport
        let date: Date
    }

    private let state = OSAllocatedUnfairLock(initialState: [String: Entry]())

    func record(_ report: BatteryReport, at date: Date = Date()) -> Bool {
        state.withLock { entries in
            entries = entries.filter { date.timeIntervalSince($0.value.date) < Self.expiry }
            let key = report.name.lowercased()
            guard entries[key] != nil || entries.count < Self.maxDevices else { return false }
            entries[key] = Entry(report: report, date: date)
            return true
        }
    }

    func devices(at now: Date = Date()) -> [DeviceBattery] {
        let entries = state.withLock { $0 }
        return entries
            .filter { now.timeIntervalSince($0.value.date) < Self.expiry }
            .map { key, entry in
                DeviceBattery(
                    id: "reported.\(key)",
                    name: entry.report.name,
                    kind: entry.report.kind,
                    cells: [DeviceBattery.Cell(label: nil, percent: entry.report.percent, isCharging: entry.report.isCharging)],
                    details: [DeviceBattery.Detail(label: "Connection", value: "Reported over Tailscale")],
                    reportedAt: entry.date
                )
            }
            .sorted { $0.id < $1.id }
    }
}
