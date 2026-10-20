import Foundation

// macOS keeps reporting "charging" while a weak charger loses to a heavy load, so measured power decides the state.
enum BatteryFlow: Equatable {
    case charging(watts: Double?)
    case draining(watts: Double?)
    case pluggedInDraining(watts: Double)
    case pluggedInIdle

    static let idleWatts = 0.5

    init(isCharging: Bool, isOnAC: Bool, watts: Double?) {
        if let watts, watts <= -Self.idleWatts {
            self = isOnAC ? .pluggedInDraining(watts: -watts) : .draining(watts: -watts)
        } else if let watts, watts >= Self.idleWatts {
            self = .charging(watts: watts)
        } else if isCharging {
            self = .charging(watts: nil)
        } else {
            self = isOnAC ? .pluggedInIdle : .draining(watts: nil)
        }
    }

    init(_ details: BatteryDetails) {
        self.init(isCharging: details.isCharging, isOnAC: details.isOnAC, watts: details.watts)
    }

    var isCharging: Bool {
        if case .charging = self { return true }
        return false
    }

    var isDraining: Bool {
        switch self {
        case .draining, .pluggedInDraining: true
        default: false
        }
    }

    var watts: Double? {
        switch self {
        case .charging(let watts), .draining(let watts): watts
        case .pluggedInDraining(let watts): watts
        case .pluggedInIdle: nil
        }
    }

    var powerLabel: String {
        switch self {
        case .charging: "Charging"
        case .draining, .pluggedInDraining: "Draining"
        case .pluggedInIdle: "Power"
        }
    }

    // Time to full is meaningless while the battery is losing charge, so only the matching estimate is shown.
    func summary(minutesRemaining: Int?) -> String {
        let time = minutesRemaining.map { Format.duration(TimeInterval($0 * 60)) }
        switch self {
        case .charging: return time.map { "Charging, full in \($0)" } ?? "Charging"
        case .draining: return time.map { "On battery, \($0) left" } ?? "On battery"
        case .pluggedInDraining: return "Plugged in, but using more power than the charger gives"
        case .pluggedInIdle: return "Plugged in, not charging"
        }
    }
}
