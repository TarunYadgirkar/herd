import Foundation
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
        #expect(devices.first?.percent == 88)
    }

    @Test func aSingleBatteryAccessoryHasOneUnlabeledCell() {
        let devices = AccessoryBatteries.parse([Self.source("Magic Mouse", category: "Mouse", percent: 41, extra: ["Accessory Identifier": "m1"])])
        #expect(devices.map(\.id) == ["m1"])
        #expect(devices.first?.kind == .mouse)
        #expect(devices.first?.cells == [.init(label: nil, percent: 41, isCharging: false)])
        #expect(devices.first?.details.first == .init(label: "Type", value: "Mouse"))
    }

    @Test func theMacsOwnBatteryAndAbsentAccessoriesAreLeftOut() {
        let internalBattery: [String: Any] = ["Type": "InternalBattery", "Name": "InternalBattery-0", "Current Capacity": 76, "Max Capacity": 100]
        let away = Self.source("Keyboard", category: "Keyboard", percent: 50, extra: ["Is Present": false])
        #expect(AccessoryBatteries.parse([internalBattery, away]).isEmpty)
    }
}

@Suite struct BatteryReportTests {
    @Test func readsADeviceReportFromTheRequestLine() {
        let report = BatteryReport.parse(request: "GET /battery?name=Tarun%27s%20iPhone&level=83&charging=Yes&kind=Apple%20Watch HTTP/1.1\r\nHost: mac\r\n\r\n")
        #expect(report == BatteryReport(name: "Tarun's iPhone", percent: 83, isCharging: true, kind: .watch))
    }

    @Test func aNameWithoutWordsFallsBackToTheModel() {
        let report = BatteryReport.parse(request: "GET /battery?name=...&kind=iPhone&level=52 HTTP/1.1\r\n\r\n")
        #expect(report?.name == "iPhone")
        #expect(report?.kind == .phone)
    }

    @Test func rejectsReportsWithoutAUsableNameOrLevel() {
        #expect(BatteryReport.parse(request: "GET /battery?level=83 HTTP/1.1\r\n\r\n") == nil)
        #expect(BatteryReport.parse(request: "GET /battery?name=iPhone&level=140 HTTP/1.1\r\n\r\n") == nil)
        #expect(BatteryReport.parse(request: "GET /battery?name=iPhone&level=nan HTTP/1.1\r\n\r\n") == nil)
        #expect(BatteryReport.parse(request: "GET /battery?name=\(String(repeating: "a", count: 41))&level=5 HTTP/1.1\r\n\r\n") == nil)
        #expect(BatteryReport.parse(request: "GET /stats?name=iPhone&level=5 HTTP/1.1\r\n\r\n") == nil)
        #expect(BatteryReport.parse(request: "DELETE /battery?name=iPhone&level=5 HTTP/1.1\r\n\r\n") == nil)
        #expect(BatteryReport.parse(request: "POST /battery?name=iPhone&level=5 HTTP/1.1\r\n\r\n") == nil)
        #expect(!BatteryReport.isReport("POST /battery?name=iPhone&level=5 HTTP/1.1\r\n\r\n"))
    }

    @Test func aNewReportReplacesTheLastAndOldOnesExpire() {
        let store = ReportedBatteries()
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(store.record(BatteryReport(name: "iPhone", percent: 80, isCharging: false, kind: .phone), at: start))
        #expect(store.record(BatteryReport(name: "iphone", percent: 60, isCharging: false, kind: .phone), at: start + 60))
        #expect(store.devices(at: start + 120).map(\.percent) == [60])
        #expect(store.devices(at: start + 60 + ReportedBatteries.expiry).isEmpty)
    }

    @Test func refusesMoreDevicesThanTheLimit() {
        let store = ReportedBatteries()
        let now = Date(timeIntervalSince1970: 1_000)
        for index in 0..<ReportedBatteries.maxDevices {
            #expect(store.record(BatteryReport(name: "d\(index)", percent: 50, isCharging: false, kind: .phone), at: now))
        }
        #expect(!store.record(BatteryReport(name: "extra", percent: 50, isCharging: false, kind: .phone), at: now))
    }
}

@Suite struct BrowserRequestTests {
    @Test func requestsCarryingBrowserHeadersAreRecognised() {
        #expect(RemoteHTTP.isFromBrowser("GET /battery?name=a&level=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nSec-Fetch-Site: cross-site\r\n\r\n"))
        #expect(RemoteHTTP.isFromBrowser("GET /stats HTTP/1.1\r\nReferer: http://example.com/\r\n\r\n"))
        #expect(!RemoteHTTP.isFromBrowser("GET /stats HTTP/1.0\r\nHost: old-macbook\r\n\r\n"))
        #expect(!RemoteHTTP.isFromBrowser("GET /battery?name=origin:&level=1 HTTP/1.1\r\nHost: 100.64.0.1\r\n\r\n"))
    }
}
