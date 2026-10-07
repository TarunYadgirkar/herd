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
    private let grouper = AppGrouper()

    func start() {
        networkSampler.start()
    }

    func stop() {
        networkSampler.stop()
    }

    func tick(regularAppPids: Set<pid_t>) -> Frame {
        let system = systemSampler.sample()
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
