import Darwin
import Foundation
import IOKit.ps

final class DeviceBatterySampler {
    private static let refreshNanoseconds: UInt64 = 30_000_000_000

    private let phones = PhoneBatteryReader()
    private var accessories: [DeviceBattery] = []
    private var readAt: UInt64?

    func sample() -> [DeviceBattery] {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if readAt.map({ now - $0 >= Self.refreshNanoseconds }) ?? true {
            readAt = now
            accessories = AccessoryBatteries.read()
            phones.refresh()
        }
        return phones.latest + accessories
    }
}

enum AccessoryBatteries {
    private typealias CopyByType = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?

    private static let allSources: Int32 = 0
    private static let accessoryType = "Accessory Source"
    private static let caseCategory = "Audio Battery Case"
    private static let caseLabel = "Case"
    private static let categoryKey = "Accessory Category"
    private static let groupKey = "Group Identifier"
    private static let accessoryKey = "Accessory Identifier"
    private static let partsKey = "Combined Parts"
    private static let partKey = "Part Identifier"

    // IOPSCopyPowerSourcesList leaves accessories out. This is the call `pmset -g accps` makes; IOKit exports it without a header.
    private static let copyByType: CopyByType? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOPSCopyPowerSourcesByType")
        .map { unsafeBitCast($0, to: CopyByType.self) }

    static func read() -> [DeviceBattery] {
        guard let info = copyByType?(allSources)?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
        return parse(list.compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] })
    }

    static func parse(_ sources: [[String: Any]]) -> [DeviceBattery] {
        let accessories = sources.filter {
            $0[kIOPSTypeKey] as? String == accessoryType && $0[kIOPSIsPresentKey] as? Bool != false
        }
        // A charging case is its own power source that shares a group with the earbuds it holds.
        return Dictionary(grouping: accessories, by: groupID)
            .compactMap { id, members in device(id: id, members: members) }
            .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    private static func groupID(_ source: [String: Any]) -> String {
        source[groupKey] as? String
            ?? source[accessoryKey] as? String
            ?? (source[kIOPSPowerSourceIDKey] as? Int).map(String.init)
            ?? source[kIOPSNameKey] as? String
            ?? ""
    }

    private static func device(id: String, members: [[String: Any]]) -> DeviceBattery? {
        let bodies = members.filter { !isCase($0) }
        let cells = (bodies + members.filter(isCase)).flatMap(cells)
        guard let main = bodies.first ?? members.first, !cells.isEmpty else { return nil }
        return DeviceBattery(
            id: id,
            name: main[kIOPSNameKey] as? String ?? "Accessory",
            kind: kind(main[categoryKey] as? String ?? ""),
            cells: cells
        )
    }

    private static func isCase(_ source: [String: Any]) -> Bool {
        source[categoryKey] as? String == caseCategory
    }

    private static func cells(of source: [String: Any]) -> [DeviceBattery.Cell] {
        if isCase(source) { return [cell(source, label: caseLabel)].compactMap(\.self) }
        if let parts = source[partsKey] as? [[String: Any]], !parts.isEmpty {
            return parts.compactMap { cell($0, label: $0[partKey] as? String) }
        }
        return [cell(source, label: nil)].compactMap(\.self)
    }

    private static func cell(_ source: [String: Any], label: String?) -> DeviceBattery.Cell? {
        guard let current = source[kIOPSCurrentCapacityKey] as? Int,
              let maximum = source[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { return nil }
        return DeviceBattery.Cell(
            label: label,
            percent: min(Double(current) / Double(maximum) * 100, 100),
            isCharging: source[kIOPSIsChargingKey] as? Bool ?? false
        )
    }

    private static func kind(_ category: String) -> DeviceBattery.Kind {
        let category = category.lowercased()
        let kinds: [(String, DeviceBattery.Kind)] = [
            ("head", .audio), ("audio", .audio), ("speaker", .audio), ("keyboard", .keyboard),
            ("mouse", .mouse), ("trackpad", .trackpad), ("game", .controller),
        ]
        return kinds.first { category.contains($0.0) }?.1 ?? .other
    }
}
