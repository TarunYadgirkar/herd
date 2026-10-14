import Testing
@testable import Herd

@Suite struct PowerModeTests {
    @Test func automaticFollowsThePowerSource() {
        #expect(PowerMode.automatic.effort(onBattery: false, lowPowerMode: false) == .precise)
        #expect(PowerMode.automatic.effort(onBattery: true, lowPowerMode: false) == .efficient)
        #expect(PowerMode.automatic.effort(onBattery: false, lowPowerMode: true) == .efficient)
    }

    @Test func fixedModesIgnoreThePowerSource() {
        #expect(PowerMode.precise.effort(onBattery: true, lowPowerMode: true) == .precise)
        #expect(PowerMode.efficient.effort(onBattery: false, lowPowerMode: false) == .efficient)
    }

    @Test func efficientSamplesLessAndDropsHiddenNetworkTracking() {
        #expect(SamplingEffort.efficient.interval.rawValue > SamplingEffort.precise.interval.rawValue)
        #expect(SamplingEffort.precise.tracksNetworkWhileHidden)
        #expect(!SamplingEffort.efficient.tracksNetworkWhileHidden)
    }
}
