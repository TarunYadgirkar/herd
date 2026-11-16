import Testing
@testable import Herd

@Suite struct DeviceBatteryTests {
    private static func source(_ name: String, category: String, percent: Int, group: String? = nil, extra: [String: Any] = [:]) -> [String: Any] {
        var source: [String: Any] = [
            "Type": "Accessory Source", "Name": name, "Accessory Category": category,
            "Current Capacity": percent, "Max Capacity": 100, "Is Present": true, "Is Charging": false,
        ]
        if let group { source["Group Identifier"] = group }
        return source.merging(extra) { _, new in new }
    }

    private static var earbuds: [String: Any] {
        source("Pods", category: "Headset", percent: 88, group: "g1", extra: [
        "Combined Parts": [
            source("Pods", category: "Headset", percent: 90, extra: ["Part Identifier": "Left"]),
            source("Pods", category: "Headset", percent: 88, extra: ["Part Identifier": "Right", "Is Charging": true]),
        ],
    ])
    }

    private static var chargingCase: [String: Any] {
        source("Pods Case", category: "Audio Battery Case", percent: 99, group: "g1")
    }

    @Test func earbudsAndTheirCaseBecomeOneDevice() {
        let devices = AccessoryBatteries.parse([Self.chargingCase, Self.earbuds])
        #expect(devices.count == 1)
        #expect(devices.first?.name == "Pods")
        #expect(devices.first?.kind == .audio)
        #expect(devices.first?.cells.map(\.label) == ["Left", "Right", "Case"])
        #expect(devices.first?.cells.map(\.percent) == [90, 88, 99])
        #expect(devices.first?.cells.map(\.isCharging) == [false, true, false])
    }

    @Test func aSingleBatteryAccessoryHasOneUnlabeledCell() {
        let devices = AccessoryBatteries.parse([Self.source("Magic Mouse", category: "Mouse", percent: 41, extra: ["Accessory Identifier": "m1"])])
        #expect(devices == [DeviceBattery(id: "m1", name: "Magic Mouse", kind: .mouse, cells: [.init(label: nil, percent: 41, isCharging: false)])])
    }

    @Test func theMacsOwnBatteryAndAbsentAccessoriesAreLeftOut() {
        let internalBattery: [String: Any] = ["Type": "InternalBattery", "Name": "InternalBattery-0", "Current Capacity": 76, "Max Capacity": 100]
        let away = Self.source("Keyboard", category: "Keyboard", percent: 50, extra: ["Is Present": false])
        #expect(AccessoryBatteries.parse([internalBattery, away]).isEmpty)
    }
}
