import Foundation

enum PerformanceFormat {
    private static let byteUnits = ["B", "KB", "MB", "GB", "TB"]
    private static let gigabyte = 1_073_741_824.0

    static let missing = "–"

    static func bytes(_ value: Double) -> String {
        Format.bytes(UInt64(max(value, 0)))
    }

    static func compactBytes(_ value: Double, suffix: String = "") -> String {
        var scaled = abs(value)
        var unit = 0
        while scaled >= 1024 && unit < byteUnits.count - 1 {
            scaled /= 1024
            unit += 1
        }
        let pattern = scaled < 10 && scaled != scaled.rounded() ? "%.1f" : "%.0f"
        return String(format: pattern, scaled) + " " + byteUnits[unit] + suffix
    }

    static func gigabytes(_ bytes: UInt64, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f", Double(bytes) / gigabyte)
    }

    static func celsius(_ value: Double) -> String {
        String(format: "%.0f °C", value)
    }

    static func gigahertz(_ megahertz: Double) -> String {
        String(format: "%.2f GHz", megahertz / 1000)
    }

    static func megahertz(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0))) + " MHz"
    }

    static func rpm(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0))) + " rpm"
    }

    static func wattHours(_ value: Double) -> String {
        if value <= 0 { return "0 Wh" }
        if value < 0.01 { return "< 0.01 Wh" }
        return String(format: value < 10 ? "%.2f Wh" : "%.1f Wh", value)
    }

    static func cpuTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(secs)s" }
        return "\(secs)s"
    }

    static func load(_ values: [Double]) -> String {
        values.map { String(format: "%.2f", $0) }.joined(separator: "  ")
    }
}

enum ChartUnit {
    case fraction
    case percent
    case bytes
    case rate
    case watts
    case celsius
    case rpm

    func value(_ raw: Double) -> String {
        switch self {
        case .fraction: Format.percent(raw * 100)
        case .percent: Format.percent(raw)
        case .bytes: PerformanceFormat.bytes(raw)
        case .rate: Format.rate(abs(raw))
        case .watts: Format.watts(abs(raw))
        case .celsius: PerformanceFormat.celsius(raw)
        case .rpm: PerformanceFormat.rpm(raw)
        }
    }

    func axis(_ raw: Double) -> String {
        switch self {
        case .fraction: String(format: "%.0f%%", raw * 100)
        case .percent: String(format: "%.0f%%", raw)
        case .bytes: PerformanceFormat.compactBytes(raw)
        case .rate: PerformanceFormat.compactBytes(raw, suffix: "/s")
        case .watts: String(format: abs(raw) < 10 && raw != raw.rounded() ? "%.1f W" : "%.0f W", abs(raw))
        case .celsius: String(format: "%.0f°", raw)
        case .rpm: String(format: "%.0f rpm", raw)
        }
    }
}

enum TimeAxis {
    private struct Spec {
        let step: TimeInterval
        let unit: TimeInterval
        let suffix: String
    }

    private static let clockStep: TimeInterval = 4 * 3_600
    private static let nowTolerance: TimeInterval = 1

    static func ticks(anchor: Date, range: HistoryRange) -> [Date] {
        guard let spec = spec(for: range) else { return clockTicks(anchor: anchor) }
        let count = Int(range.seconds / spec.step)
        return (0...count).map { anchor.addingTimeInterval(-Double($0) * spec.step) }
    }

    static func label(for date: Date, anchor: Date, range: HistoryRange) -> String {
        guard let spec = spec(for: range) else { return date.formatted(.dateTime.hour()) }
        let offset = anchor.timeIntervalSince(date)
        if offset < nowTolerance { return "now" }
        return "-\(Int((offset / spec.unit).rounded()))\(spec.suffix)"
    }

    static func calloutLabel(for date: Date, anchor: Date, range: HistoryRange) -> String {
        if range == .day { return date.formatted(.dateTime.hour().minute()) }
        let offset = Int(anchor.timeIntervalSince(date).rounded())
        if offset < 1 { return "Now" }
        if offset < 60 { return "\(offset)s ago" }
        return "\(offset / 60)m \(offset % 60)s ago"
    }

    // Gaps longer than this mean Herd wasn't running, so rates aren't carried across them.
    private static func spec(for range: HistoryRange) -> Spec? {
        switch range {
        case .minute: Spec(step: 15, unit: 1, suffix: "s")
        case .fiveMinutes: Spec(step: 60, unit: 60, suffix: "m")
        case .hour: Spec(step: 900, unit: 60, suffix: "m")
        case .day: nil
        }
    }

    private static func clockTicks(anchor: Date) -> [Date] {
        let start = anchor.addingTimeInterval(-HistoryRange.day.seconds)
        let offset = TimeInterval(TimeZone.current.secondsFromGMT(for: anchor))
        let first = ((start.timeIntervalSinceReferenceDate + offset) / clockStep).rounded(.up) * clockStep - offset
        return stride(from: first, through: anchor.timeIntervalSinceReferenceDate, by: clockStep)
            .map { Date(timeIntervalSinceReferenceDate: $0) }
    }
}
