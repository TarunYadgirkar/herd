import Foundation
import Testing
@testable import Herd

@Suite struct ProcessIdentityTests {
    private static let started = Date(timeIntervalSince1970: 1_000_000)

    private static func sample(startTime: Date?) -> ProcessSample {
        ProcessSample(
            id: "500", pid: 500, ppid: 1, responsiblePid: 500, uid: getuid(), name: "node", path: "/usr/local/bin/node",
            arguments: [], startTime: startTime, cpuPercent: 0, memoryBytes: 0, energyWatts: 0, diskReadBps: 0,
            diskWriteBps: 0, netInBps: 0, netOutBps: 0, gpuPercent: 0, threads: 1, isApproximate: false, isSuspended: false
        )
    }

    private static func kernel(pid: pid_t = 500, startTime: Date) -> KernelProcess {
        KernelProcess(pid: pid, ppid: 1, uid: getuid(), comm: "other", startTime: startTime, isStopped: false)
    }

    @Test func theSameProcessIsStillRunning() {
        #expect(ProcessActions.isStillRunning(Self.sample(startTime: Self.started), kernel: Self.kernel(startTime: Self.started + 0.4)))
    }

    @Test func aReusedPidIsNotTheSameProcess() {
        #expect(!ProcessActions.isStillRunning(Self.sample(startTime: Self.started), kernel: Self.kernel(startTime: Self.started + 90)))
    }

    @Test func anExitedProcessIsNotRunning() {
        #expect(!ProcessActions.isStillRunning(Self.sample(startTime: Self.started), kernel: nil))
    }
}
