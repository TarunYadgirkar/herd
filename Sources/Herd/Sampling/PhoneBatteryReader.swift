import Foundation
import os

// Reads the charge of iPhones and iPads paired with this Mac. Talking to a device can stall for seconds,
// so it runs off the sampling path and the sampler only ever sees the last finished read.
final class PhoneBatteryReader: Sendable {
    private struct State {
        var latest: [DeviceBattery] = []
        var isReading = false
    }

    private static let queue = DispatchQueue(label: "com.tarunyadgirkar.herd.phone-battery", qos: .utility)
    private let state = OSAllocatedUnfairLock(initialState: State())

    var latest: [DeviceBattery] {
        state.withLock { $0.latest }
    }

    func refresh() {
        let canStart = state.withLock { state in
            guard !state.isReading else { return false }
            state.isReading = true
            return true
        }
        guard canStart else { return }
        Self.queue.async { [state] in
            let devices = MobileDevice.shared?.batteries() ?? []
            state.withLock {
                $0.latest = devices
                $0.isReading = false
            }
        }
    }
}

// The framework Finder uses to talk to iOS devices. It is private, so every symbol is looked up at run time and a missing one turns the feature off.
struct MobileDevice: Sendable {
    private typealias Device = UnsafeRawPointer
    private typealias Status = @convention(c) (Device) -> Int32
    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias CopyValue = @convention(c) (Device, CFString?, CFString?) -> Unmanaged<CFTypeRef>?

    private static let path = "/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice"
    private static let batteryDomain = "com.apple.mobile.battery"

    static let shared = MobileDevice()

    private let createList: CreateList
    private let connect: Status
    private let disconnect: Status
    private let isPaired: Status
    private let validatePairing: Status
    private let startSession: Status
    private let stopSession: Status
    private let copyValue: CopyValue

    private init?() {
        guard let handle = dlopen(Self.path, RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let createList = symbol("AMDCreateDeviceList", as: CreateList.self),
              let connect = symbol("AMDeviceConnect", as: Status.self),
              let disconnect = symbol("AMDeviceDisconnect", as: Status.self),
              let isPaired = symbol("AMDeviceIsPaired", as: Status.self),
              let validatePairing = symbol("AMDeviceValidatePairing", as: Status.self),
              let startSession = symbol("AMDeviceStartSession", as: Status.self),
              let stopSession = symbol("AMDeviceStopSession", as: Status.self),
              let copyValue = symbol("AMDeviceCopyValue", as: CopyValue.self) else { return nil }
        self.createList = createList
        self.connect = connect
        self.disconnect = disconnect
        self.isPaired = isPaired
        self.validatePairing = validatePairing
        self.startSession = startSession
        self.stopSession = stopSession
        self.copyValue = copyValue
    }

    func batteries() -> [DeviceBattery] {
        guard let devices = createList()?.takeRetainedValue() as? [AnyObject] else { return [] }
        let found = devices.compactMap { battery(of: Device(Unmanaged.passUnretained($0).toOpaque())) }
        // A device on both a cable and Wi-Fi is listed once per connection.
        return Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            .values
            .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    private func battery(of device: Device) -> DeviceBattery? {
        guard connect(device) == 0 else { return nil }
        defer { _ = disconnect(device) }
        guard isPaired(device) == 1, validatePairing(device) == 0, startSession(device) == 0 else { return nil }
        defer { _ = stopSession(device) }
        guard let id = value(device, nil, "UniqueDeviceID") as? String,
              let percent = value(device, Self.batteryDomain, "BatteryCurrentCapacity") as? Int else { return nil }
        let deviceClass = value(device, nil, "DeviceClass") as? String
        return DeviceBattery(
            id: id,
            name: value(device, nil, "DeviceName") as? String ?? deviceClass ?? "iPhone",
            kind: Self.kind(deviceClass),
            cells: [DeviceBattery.Cell(
                label: nil,
                percent: Double(min(max(percent, 0), 100)),
                isCharging: value(device, Self.batteryDomain, "BatteryIsCharging") as? Bool ?? false
            )],
            details: details(device, deviceClass: deviceClass)
        )
    }

    private func details(_ device: Device, deviceClass: String?) -> [DeviceBattery.Detail] {
        let entries: [(String, String?)] = [
            ("Type", deviceClass),
            ("Model", value(device, nil, "ProductType") as? String),
            ("Software", value(device, nil, "ProductVersion") as? String),
            ("Fully charged", (value(device, Self.batteryDomain, "FullyCharged") as? Bool).map { $0 ? "Yes" : "No" }),
        ]
        return entries.compactMap { label, value in value.map { DeviceBattery.Detail(label: label, value: $0) } }
    }

    private func value(_ device: Device, _ domain: String?, _ key: String) -> Any? {
        copyValue(device, domain as CFString?, key as CFString)?.takeRetainedValue()
    }

    private static func kind(_ deviceClass: String?) -> DeviceBattery.Kind {
        switch deviceClass {
        case "iPhone", "iPod": .phone
        case "iPad": .tablet
        default: .other
        }
    }
}
