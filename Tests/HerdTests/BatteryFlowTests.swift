import Testing
@testable import Herd

@Suite struct BatteryFlowTests {
    @Test func measuredDrainWinsOverACharger() {
        let flow = BatteryFlow(isCharging: true, isOnAC: true, watts: -19.4)
        #expect(flow == .pluggedInDraining(watts: 19.4))
        #expect(!flow.isCharging)
        #expect(flow.summary(minutesRemaining: 469) == "Plugged in, but using more power than the charger gives")
    }

    @Test func tinyFlowsReadAsIdle() {
        #expect(BatteryFlow(isCharging: false, isOnAC: true, watts: 0.2) == .pluggedInIdle)
        #expect(BatteryFlow(isCharging: false, isOnAC: false, watts: -8) == .draining(watts: 8))
        #expect(BatteryFlow(isCharging: false, isOnAC: true, watts: 12) == .charging(watts: 12))
    }

    @Test func summariesSayWhatTheTimeMeans() {
        #expect(BatteryFlow.draining(watts: 8).summary(minutesRemaining: 469) == "On battery, 7h 49m left")
        #expect(BatteryFlow.charging(watts: 12).summary(minutesRemaining: 30) == "Charging, full in 30m")
    }

    @Test func powerSeriesPlotBothDirectionsUpward() {
        let watts: [Double?] = [5, 6, 0.1, -20, -22, nil]
        #expect(BatteryPowerSeries.values(watts, sign: 1) == [5, 6, 0, nil, nil, nil])
        #expect(BatteryPowerSeries.values(watts, sign: -1) == [nil, nil, 0, 20, 22, nil])
    }

    @Test func emptyChartSaysWhyItIsEmpty() {
        #expect(BatteryPowerSeries.emptyMessage([0.1, 0.2]) == "Not charging or draining")
        #expect(BatteryPowerSeries.emptyMessage([nil]) == PerformanceCopy.unavailable)
    }
}
