import Foundation
import Network
import Testing
@testable import Herd

private func endpoint(_ host: String) -> NWEndpoint {
    .hostPort(host: NWEndpoint.Host(host), port: 47787)
}

private func stats(battery: Double? = 80, cpuCelsius: Double? = 41) -> RemoteStats {
    var system = SystemSnapshot()
    system.cpuUser = 0.1
    system.memoryUsed = 4 << 30
    system.memoryTotal = 8 << 30
    system.battery = battery.map { BatteryInfo(percent: $0, isCharging: false, isOnAC: true) }
    if let cpuCelsius { system.sensors = SensorReading(cpuCelsius: cpuCelsius) }
    return RemoteStats(system: system, name: "Old Mac", disk: (100 << 30, 250 << 30), date: Date(timeIntervalSince1970: 1_000))
}

@Suite struct RemoteNetworkTests {
    @Test func onlyTailscaleAndLoopbackPeersAreTrusted() {
        #expect(RemoteNetwork.isTrusted(endpoint("100.113.62.12")))
        #expect(RemoteNetwork.isTrusted(endpoint("100.64.0.1")))
        #expect(RemoteNetwork.isTrusted(endpoint("127.0.0.1")))
        #expect(RemoteNetwork.isTrusted(endpoint("::ffff:100.85.65.104")))
        #expect(RemoteNetwork.isTrusted(endpoint("fd7a:115c:a1e0::1")))
        #expect(!RemoteNetwork.isTrusted(endpoint("100.128.0.1")))
        #expect(!RemoteNetwork.isTrusted(endpoint("192.168.1.20")))
        #expect(!RemoteNetwork.isTrusted(endpoint("::ffff:10.0.0.2")))
        #expect(!RemoteNetwork.isTrusted(endpoint("fe80::1")))
    }

    @Test func hostsAreSplitTrimmedAndDeduplicated() {
        #expect(RemoteNetwork.hosts(from: " Old-MacBook, studio  old-macbook\n") == ["old-macbook", "studio"])
        #expect(RemoteNetwork.hosts(from: " , ").isEmpty)
    }

    @Test func responsesRoundTrip() throws {
        let body = try RemoteStats.encoder.encode(stats())
        let parsed = try #require(RemoteHTTP.parse(RemoteHTTP.response(body)))
        #expect(parsed.status == 200)
        #expect(try RemoteStats.decoder.decode(RemoteStats.self, from: parsed.body) == stats())
        #expect(RemoteHTTP.parse(RemoteHTTP.response(nil))?.status == 404)
    }
}

@Suite struct RemoteSummaryTests {
    @Test func sidebarShowsBatteryAndTemperatureWhileOnline() {
        let now = Date()
        let mac = RemoteMac(stats: stats(), lastSeen: now)
        #expect(RemoteSummary.sidebar(mac, now: now) == "80% · 41 °C")
        #expect(RemoteSummary.sidebar(mac, now: now.addingTimeInterval(RemoteMac.offlineAfter + 1)) == "Offline")
    }

    @Test func desktopsFallBackToCPU() {
        let now = Date()
        #expect(RemoteSummary.sidebar(RemoteMac(stats: stats(battery: nil, cpuCelsius: nil), lastSeen: now), now: now) == "10%")
    }

    @Test func unreachableMacsSayOffline() {
        #expect(RemoteSummary.sidebar(RemoteMac(failure: "Not reachable"), now: Date()) == "Offline")
        #expect(RemoteSummary.sidebar(nil, now: Date()) == PerformanceFormat.missing)
    }
}
