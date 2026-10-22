import Foundation
import Testing
@testable import Herd

private func sample(pid: pid_t, cpu: Double, energy: Double = 0) -> ProcessSample {
    ProcessSample(
        id: "\(pid)", pid: pid, ppid: 1, responsiblePid: pid, uid: getuid(), name: "p\(pid)", path: "/usr/bin/p\(pid)", arguments: [],
        startTime: nil, cpuPercent: cpu, memoryBytes: 0, energyWatts: energy, diskReadBps: 0, diskWriteBps: 0,
        netInBps: 0, netOutBps: 0, gpuPercent: 0, threads: 1, isApproximate: false, isSuspended: false
    )
}

@Suite struct SMCFixedPointTests {
    @Test func signedTemperaturesKeepEightFractionBits() {
        #expect(SMC.fixedPoint(type: SMCKey("sp78"), raw: 0x2D80) == 45.5)
        #expect(SMC.fixedPoint(type: SMCKey("sp78"), raw: 0xFF00) == -1)
    }

    @Test func fanSpeedsAreUnsignedWithTwoFractionBits() {
        #expect(SMC.fixedPoint(type: SMCKey("fpe2"), raw: 0x1F40) == 2000)
    }

    @Test func powerTypesReadTheFractionWidthFromTheName() {
        #expect(SMC.fixedPoint(type: SMCKey("sp96"), raw: 0x0280) == 10)
        #expect(SMC.fixedPoint(type: SMCKey("sp5a"), raw: 0x0400) == 1)
    }

    @Test func otherTypesAreNotFixedPoint() {
        #expect(SMC.fixedPoint(type: SMCKey("ui16"), raw: 1) == nil)
        #expect(SMC.fixedPoint(type: SMCKey("ch8*"), raw: 1) == nil)
    }
}

@Suite struct IntelPowerTests {
    @Test func smcPowerStandsInWithoutANeuralEngine() throws {
        let reading = try #require(PowerReading(smc: SensorReading(cpuWatts: 12, gpuWatts: 3)))
        #expect(reading.cpuWatts == 12)
        #expect(reading.gpuWatts == 3)
        #expect(reading.aneWatts == 0)
        #expect(!reading.hasNeuralEngine)
    }

    @Test func noCPUPowerMeansNoReading() {
        #expect(PowerReading(smc: SensorReading(gpuWatts: 3)) == nil)
    }

    @Test func packagePowerIsSplitByCPUTime() {
        var samples = [sample(pid: 1, cpu: 75), sample(pid: 2, cpu: 25), sample(pid: 3, cpu: 0)]
        ProcessEnergy.apportion(cpuWatts: 8, across: &samples)
        #expect(samples.map(\.energyWatts) == [6, 2, 0])
    }

    @Test func measuredEnergyIsLeftAlone() {
        var samples = [sample(pid: 1, cpu: 50, energy: 1.5), sample(pid: 2, cpu: 50)]
        ProcessEnergy.apportion(cpuWatts: 8, across: &samples)
        #expect(samples.map(\.energyWatts) == [1.5, 0])
    }
}
