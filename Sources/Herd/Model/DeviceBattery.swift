import Foundation

struct DeviceBattery: Sendable, Equatable, Identifiable {
    enum Kind: Sendable, Equatable {
        case audio, keyboard, mouse, trackpad, controller, phone, tablet, other
    }

    // Earbuds report one battery per bud and another for the case, so one device can carry several.
    struct Cell: Sendable, Equatable, Identifiable {
        let label: String?
        let percent: Double
        let isCharging: Bool

        var id: String { label ?? "" }
        var isCase: Bool { label == DeviceBattery.caseLabel }
    }

    struct Detail: Sendable, Equatable, Identifiable {
        let label: String
        let value: String

        var id: String { label }
    }

    static let caseLabel = "Case"

    let id: String
    let name: String
    let kind: Kind
    let cells: [Cell]
    var details: [Detail] = []

    // A full case says nothing about how long the earbuds will last, so the headline is the lowest battery in use.
    var percent: Double? {
        let worn = cells.filter { !$0.isCase }
        return (worn.isEmpty ? cells : worn).map(\.percent).min()
    }

    var isCharging: Bool {
        cells.contains { $0.isCharging && !$0.isCase }
    }
}
