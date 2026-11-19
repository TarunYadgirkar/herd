import Foundation
import Testing
@testable import Herd

private let key = "k3yForTests_-0123456789abcdefghijklmnopqrst"

private func request(_ target: String, headers: [String] = []) -> String {
    (["GET \(target) HTTP/1.1", "Host: 100.64.0.1"] + headers).joined(separator: "\r\n") + "\r\n\r\n"
}

@Suite struct RemoteKeyTests {
    @Test func generatedKeysAre256BitsOfURLSafeText() {
        let first = RemoteKey.generate()
        #expect(first.count == RemoteKey.length)
        #expect(first.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        #expect(first != RemoteKey.generate())
    }

    @Test func matchesOnlyTheExactKey() {
        #expect(RemoteKey.matches(key, key))
        #expect(!RemoteKey.matches("", key))
        #expect(!RemoteKey.matches(String(key.dropLast()), key))
        #expect(!RemoteKey.matches(key + "x", key))
        #expect(!RemoteKey.matches(key.uppercased(), key))
    }

    @Test func requestsWithoutTheKeyAreRefused() {
        #expect(!RemoteKey.isAuthorized(request("/stats"), key: key))
        #expect(!RemoteKey.isAuthorized(request("/battery?name=iPhone&level=83"), key: key))
        #expect(!RemoteKey.isAuthorized("", key: key))
    }

    @Test func requestsWithTheWrongKeyAreRefused() {
        #expect(!RemoteKey.isAuthorized(request("/stats", headers: ["Authorization: Bearer nope"]), key: key))
        #expect(!RemoteKey.isAuthorized(request("/stats", headers: ["Authorization: Basic \(key)"]), key: key))
        #expect(!RemoteKey.isAuthorized(request("/battery?key=nope&name=iPhone&level=83"), key: key))
        #expect(!RemoteKey.isAuthorized(request("/stats?key="), key: key))
    }

    @Test func theKeyIsAcceptedInTheHeader() {
        #expect(RemoteKey.isAuthorized(request("/stats", headers: ["Authorization: Bearer \(key)"]), key: key))
        #expect(RemoteKey.isAuthorized(request("/stats", headers: ["authorization:  bearer \(key) "]), key: key))
        #expect(RemoteKey.isAuthorized(String(decoding: RemoteClient.message(host: "old-macbook", key: key), as: UTF8.self), key: key))
    }

    @Test func theKeyIsAcceptedInTheAddress() {
        #expect(RemoteKey.isAuthorized(request("/battery?key=\(key)&name=iPhone&level=83"), key: key))
        #expect(RemoteKey.isAuthorized(request("/stats?key=\(key)"), key: key))
    }

    @Test func aBodyCannotSmuggleTheHeader() {
        #expect(!RemoteKey.isAuthorized(request("/stats") + "Authorization: Bearer \(key)\r\n", key: key))
    }

    @Test func nothingIsAcceptedWithoutAStoredKey() {
        #expect(!RemoteKey.isAuthorized(request("/stats"), key: nil))
        #expect(!RemoteKey.isAuthorized(request("/stats?key="), key: ""))
    }

    @Test func pastedKeysLoseTheirWhitespace() {
        #expect(RemoteKey.cleaned("  \(key)\r\n") == key)
        #expect(RemoteKey.cleaned("ab\ncd") == nil)
        #expect(RemoteKey.cleaned(RemoteKey.generate()) != nil)
    }

    @Test func reportAddressCarriesTheKeyAndEndsAtTheLevel() throws {
        let address = try #require(BatteryReport.address(host: "100.64.0.1", key: key))
        #expect(address == "http://100.64.0.1:47787/battery?key=\(key)&name=iPhone&level=")
        let sent = request(String(address.dropFirst("http://100.64.0.1:47787".count)) + "83")
        #expect(RemoteKey.isAuthorized(sent, key: key))
        #expect(BatteryReport.parse(request: sent) == BatteryReport(name: "iPhone", percent: 83, isCharging: false, kind: .phone))
    }

    @Test func aMacWithoutAKeySaysSo() {
        let mac = RemoteMac(stats: nil, lastSeen: nil, failure: nil, needsKey: true)
        #expect(RemoteSummary.sidebar(mac, now: Date()) == "Needs key")
        #expect(RemoteSummary.waiting(mac).hasPrefix("Needs key."))
    }
}
