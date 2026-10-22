import SwiftUI

// One of the user's other Macs, as shared by the Herd running there.
struct RemoteMacView: View {
    let host: String

    @Environment(RemoteMonitor.self) private var remote

    private static let tick: TimeInterval = 5

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.tick)) { timeline in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.groupSpacing) {
                    content(mac: remote.macs[host], now: timeline.date)
                }
                .padding(Theme.groupSpacing)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") { remote.refreshNow() }
            }
        }
    }

    @ViewBuilder
    private func content(mac: RemoteMac?, now: Date) -> some View {
        if let stats = mac?.stats {
            header(stats, mac: mac, now: now)
            PerformanceCard(title: "System") {
                StatGrid(stats: RemoteSummary.systemStats(stats))
            }
            if stats.batteryPercent != nil {
                PerformanceCard(title: "Battery") {
                    StatGrid(stats: RemoteSummary.batteryStats(stats))
                }
            }
        } else {
            SectionMessage(title: host, symbol: "laptopcomputer", message: RemoteSummary.waiting(mac))
        }
    }

    private func header(_ stats: RemoteStats, mac: RemoteMac?, now: Date) -> some View {
        let isOnline = mac?.isOnline(at: now) ?? false
        return PerformanceHeader(
            title: stats.name,
            value: stats.batteryPercent.map(Format.percent) ?? stats.cpuCelsius.map(PerformanceFormat.celsius) ?? PerformanceFormat.missing,
            symbol: stats.batteryPercent.map { BatteryGlyph.symbol(percent: $0, isPowered: stats.isCharging == true || stats.isOnAC == true) },
            symbolTint: stats.batteryPercent.map {
                BatteryGlyph.tint(percent: $0, isCharging: stats.isCharging == true, isOnAC: stats.isOnAC == true)
            } ?? .secondary,
            symbolLabel: RemoteSummary.powerState(stats),
            caption: Text(RemoteSummary.freshness(mac, now: now)).foregroundStyle(isOnline ? Color.secondary : Theme.warning),
            stats: RemoteSummary.headlineStats(stats)
        ) {
            EmptyView()
        }
    }
}

enum RemoteSummary {
    private static let hotCelsius = 90.0
    private static let warmCelsius = 75.0

    static func sidebar(_ mac: RemoteMac?, now: Date) -> String {
        guard let mac, let stats = mac.stats else { return mac?.failure == nil ? PerformanceFormat.missing : "Offline" }
        guard mac.isOnline(at: now) else { return "Offline" }
        let parts = [stats.batteryPercent.map(Format.percent), stats.cpuCelsius.map(PerformanceFormat.celsius)].compactMap(\.self)
        return parts.isEmpty ? Format.percent(stats.cpuPercent) : parts.joined(separator: " · ")
    }

    static func waiting(_ mac: RemoteMac?) -> String {
        guard let failure = mac?.failure else { return "Connecting…" }
        return "\(failure). Herd must be running there with “Share this Mac's stats” on in Settings, and both Macs on Tailscale."
    }

    static func freshness(_ mac: RemoteMac?, now: Date) -> String {
        guard let lastSeen = mac?.lastSeen else { return "Not seen yet" }
        let age = max(now.timeIntervalSince(lastSeen), 0)
        let ago = age < 60 ? "just now" : "\(Format.duration(age)) ago"
        return mac?.isOnline(at: now) == true ? "Updated \(ago)" : "Offline · last seen \(ago)"
    }

    static func powerState(_ stats: RemoteStats) -> String {
        if stats.isCharging == true { return "Charging" }
        if stats.isOnAC == true { return "On power adapter" }
        return "On battery"
    }

    static func headlineStats(_ stats: RemoteStats) -> [PerformanceStat] {
        var result: [PerformanceStat] = []
        if stats.batteryPercent != nil { result.append(PerformanceStat(label: "Power", value: powerState(stats))) }
        if let cpu = stats.cpuCelsius {
            result.append(PerformanceStat(label: "CPU temperature", value: PerformanceFormat.celsius(cpu), tint: temperatureTint(cpu)))
        }
        if let gpu = stats.gpuCelsius { result.append(PerformanceStat(label: "GPU temperature", value: PerformanceFormat.celsius(gpu))) }
        if let rpm = stats.fanRPM { result.append(PerformanceStat(label: "Fan", value: rpm > 0 ? PerformanceFormat.rpm(rpm) : "Off")) }
        result.append(PerformanceStat(label: "Thermal state", value: thermalTitle(stats.thermalState)))
        return result
    }

    static func systemStats(_ stats: RemoteStats) -> [PerformanceStat] {
        var result = [
            PerformanceStat(label: "CPU", value: Format.percent(stats.cpuPercent)),
            PerformanceStat(label: "Load", value: PerformanceFormat.load(stats.loadAverage), help: "Load average over 1, 5 and 15 minutes"),
            PerformanceStat(
                label: "Memory",
                value: "\(PerformanceFormat.gigabytes(stats.memoryUsed)) of \(PerformanceFormat.gigabytes(stats.memoryTotal, decimals: 0)) GB",
                tint: Theme.pressureColor(MemoryPressure(rawValue: stats.memoryPressure) ?? .normal)
            ),
        ]
        if let free = stats.diskFree, let total = stats.diskTotal {
            result.append(PerformanceStat(
                label: "Disk free",
                value: "\(PerformanceFormat.gigabytes(free, decimals: 0)) of \(PerformanceFormat.gigabytes(total, decimals: 0)) GB"
            ))
        }
        if let watts = stats.systemWatts { result.append(PerformanceStat(label: "Power draw", value: Format.watts(watts))) }
        result.append(PerformanceStat(label: "Uptime", value: Format.duration(stats.uptime)))
        return result
    }

    static func batteryStats(_ stats: RemoteStats) -> [PerformanceStat] {
        var result: [PerformanceStat] = []
        if let percent = stats.batteryPercent { result.append(PerformanceStat(label: "Charge", value: Format.percent(percent))) }
        if let health = stats.batteryHealthPercent { result.append(PerformanceStat(label: "Health", value: Format.percent(health))) }
        if let cycles = stats.batteryCycles { result.append(PerformanceStat(label: "Cycles", value: "\(cycles)")) }
        return result
    }

    private static func temperatureTint(_ celsius: Double) -> Color? {
        if celsius >= hotCelsius { return Theme.critical }
        if celsius >= warmCelsius { return Theme.warning }
        return nil
    }

    private static func thermalTitle(_ rawValue: Int) -> String {
        switch ProcessInfo.ThermalState(rawValue: rawValue) {
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        default: "Nominal"
        }
    }
}
