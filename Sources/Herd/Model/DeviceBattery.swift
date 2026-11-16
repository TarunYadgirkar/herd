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
    }

    let id: String
    let name: String
    let kind: Kind
    let cells: [Cell]
}
