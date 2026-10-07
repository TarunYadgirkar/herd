import Darwin
import Foundation

struct Frame: Sendable {
    let date: Date
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
        let awake = ProcessResources.sleepAssertions()
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
        return Frame(date: Date(), system: system, groups: groups, processCount: samples.count)
    }
}
