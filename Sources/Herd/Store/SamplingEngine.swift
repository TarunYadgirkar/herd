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
    private var isStarted = false
    private var isDetailVisible = false
    private var effort: SamplingEffort = .precise
    // Sleep assertions change rarely and IOPMCopyAssertionsByProcess is the costliest per-tick call, so it refreshes every few ticks.
    private static let assertionRefreshTicks = 5

    func start(effort: SamplingEffort) {
        isStarted = true
        self.effort = effort
        updateNetworkTracking()
    }

    func stop() {
        isStarted = false
        networkSampler.stop()
        processSampler.setDetailVisible(false)
    }

    func setDetailVisible(_ isVisible: Bool) {
        isDetailVisible = isVisible
        processSampler.setDetailVisible(isVisible)
        updateNetworkTracking()
    }

    func setEffort(_ effort: SamplingEffort) {
        self.effort = effort
        updateNetworkTracking()
    }

    private func updateNetworkTracking() {
        networkSampler.setInterval(effort.networkInterval)
        if isStarted && (effort.tracksNetworkWhileHidden || isDetailVisible) {
            networkSampler.start()
        } else {
            networkSampler.stop()
        }
    }

    func tick(regularAppPids: Set<pid_t>) -> Frame {
        var system = systemSampler.sample()
        system.sensors = sensorSampler.sample()
        system.batteryDetails = batterySampler.sample()
        let chipPower = powerSampler.isAvailable ? powerSampler.sample() : system.sensors.flatMap(PowerReading.init(smc:))
        system.power = chipPower.map { reading in
            var merged = reading
            merged.systemWatts = system.sensors?.systemWatts
            return merged
        }
        let gpu = gpuSampler.sample()
        let network = networkSampler.rates()
        if tickCount % Self.assertionRefreshTicks == 0 { awake = ProcessResources.sleepAssertions() }
        tickCount += 1
        var samples = processSampler.sample(extras: ProcessExtras(gpu: gpu, network: network, sleepAssertions: awake))
        if !powerSampler.isAvailable, let cpuWatts = system.power?.cpuWatts {
            ProcessEnergy.apportion(cpuWatts: cpuWatts, across: &samples)
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
