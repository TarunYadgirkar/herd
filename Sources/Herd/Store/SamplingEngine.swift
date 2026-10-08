import Darwin
import Foundation

struct Frame: Sendable {
    let date: Date
    let elapsed: TimeInterval?
    let system: SystemSnapshot
    let groups: [AppGroup]
    let processCount: Int
}

actor SamplingEngine {
    private let processSampler = ProcessSampler()
    private let systemSampler = SystemSampler()
    private let gpuSampler = GPUSampler()
    private let networkSampler = NetworkSampler()
    private let sensorSampler = SensorSampler()
    private let batterySampler = BatterySampler()
    private let powerSampler = PowerSampler()
    private let grouper = AppGrouper()
    private var lastTickUptime: UInt64?
    private var tickCount = 0
    private var awake: [pid_t: [String]] = [:]
    // Sleep assertions change rarely and IOPMCopyAssertionsByProcess is the costliest per-tick call, so it refreshes every few ticks.
    private static let assertionRefreshTicks = 5

    func start() {
        networkSampler.start()
    }

    func stop() {
        networkSampler.stop()
        processSampler.setDetailVisible(false)
    }

    func setDetailVisible(_ isVisible: Bool) {
        processSampler.setDetailVisible(isVisible)
    }

    func tick(regularAppPids: Set<pid_t>) -> Frame {
        var system = systemSampler.sample()
        system.sensors = sensorSampler.sample()
        system.batteryDetails = batterySampler.sample()
        system.power = powerSampler.sample().map { reading in
            var merged = reading
            merged.systemWatts = system.sensors?.systemWatts
            return merged
        }
        let gpu = gpuSampler.sample()
        let network = networkSampler.rates()
        if tickCount % Self.assertionRefreshTicks == 0 { awake = ProcessResources.sleepAssertions() }
        tickCount += 1
        let samples = processSampler.sample().map { sample in
            var enriched = sample
            enriched.gpuPercent = gpu[sample.pid] ?? 0
            enriched.sleepAssertions = awake[sample.pid] ?? []
            if let rate = network[sample.pid] {
                enriched.netInBps = rate.inBps
                enriched.netOutBps = rate.outBps
            }
            return enriched
        }
        let groups = grouper.group(samples, regularAppPids: regularAppPids)
        return Frame(date: Date(), elapsed: elapsedSinceLastTick(), system: system, groups: groups, processCount: samples.count)
    }

    // Uptime pauses during sleep, the same clock the per-process counters use, so totals stay consistent across sleep.
    private func elapsedSinceLastTick() -> TimeInterval? {
        let now = DispatchTime.now().uptimeNanoseconds
        defer { lastTickUptime = now }
        guard let lastTickUptime, now > lastTickUptime else { return nil }
        return Double(now - lastTickUptime) / 1_000_000_000
    }
}
