import Darwin
import IOKit

struct SMCKey: Hashable {
    let code: UInt32

    init(_ name: String) {
        code = name.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    init(code: UInt32) {
        self.code = code
    }

    var name: String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> UInt32($0)) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

struct SMCKeyInfo {
    let size: UInt32
    let type: SMCKey
}

// Mirrors the C SMCKeyData_t (80 bytes). Swift does not guarantee C layout for nested
// structs (tail padding is reused), so fields are addressed by their C offsets instead.
private enum SMCLayout {
    static let size = 80
    static let key = 0
    static let keyInfoSize = 28
    static let keyInfoType = 32
    static let result = 40
    static let command = 42
    static let index = 44
    static let bytes = 48
    static let bytesCount = 32
}

private enum SMCCommand: UInt8 {
    case readBytes = 5
    case readIndex = 8
    case readKeyInfo = 9
}

final class SMC {
    private static let serviceClasses = ["AppleSMCKeysEndpoint", "AppleSMC"]
    private static let structMethodSelector: UInt32 = 2
    private static let keyCountKey = SMCKey("#KEY")

    private static let float32 = SMCKey("flt ")
    private static let sp78 = SMCKey("sp78")
    private static let fpe2 = SMCKey("fpe2")
    private static let ui8 = SMCKey("ui8 ")
    private static let ui16 = SMCKey("ui16")
    private static let ui32 = SMCKey("ui32")

    private let connection: io_connect_t
    private let input: UnsafeMutableRawPointer
    private let output: UnsafeMutableRawPointer

    init?() {
        guard let connection = Self.open() else { return nil }
        self.connection = connection
        input = .allocate(byteCount: SMCLayout.size, alignment: MemoryLayout<UInt32>.alignment)
        output = .allocate(byteCount: SMCLayout.size, alignment: MemoryLayout<UInt32>.alignment)
    }

    deinit {
        IOServiceClose(connection)
        input.deallocate()
        output.deallocate()
    }

    func keyCount() -> Int {
        guard let info = info(for: Self.keyCountKey), let count = read(Self.keyCountKey, info: info) else { return 0 }
        return Int(count)
    }

    func key(at index: Int) -> SMCKey? {
        prepare(command: .readIndex)
        input.storeBytes(of: UInt32(truncatingIfNeeded: index), toByteOffset: SMCLayout.index, as: UInt32.self)
        guard call() else { return nil }
        return SMCKey(code: output.load(fromByteOffset: SMCLayout.key, as: UInt32.self))
    }

    func info(for key: SMCKey) -> SMCKeyInfo? {
        prepare(command: .readKeyInfo, key: key)
        guard call() else { return nil }
        let size = output.load(fromByteOffset: SMCLayout.keyInfoSize, as: UInt32.self)
        let type = output.load(fromByteOffset: SMCLayout.keyInfoType, as: UInt32.self)
        guard size > 0, size <= SMCLayout.bytesCount else { return nil }
        return SMCKeyInfo(size: size, type: SMCKey(code: type))
    }

    func read(_ key: SMCKey, info: SMCKeyInfo) -> Double? {
        prepare(command: .readBytes, key: key)
        input.storeBytes(of: info.size, toByteOffset: SMCLayout.keyInfoSize, as: UInt32.self)
        guard call() else { return nil }
        return decode(type: info.type, size: Int(info.size))
    }

    private static func open() -> io_connect_t? {
        for name in serviceClasses {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(name))
            guard service != 0 else { continue }
            defer { IOObjectRelease(service) }
            var connection: io_connect_t = 0
            if IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS { return connection }
        }
        return nil
    }

    private func prepare(command: SMCCommand, key: SMCKey? = nil) {
        input.initializeMemory(as: UInt8.self, repeating: 0, count: SMCLayout.size)
        input.storeBytes(of: key?.code ?? 0, toByteOffset: SMCLayout.key, as: UInt32.self)
        input.storeBytes(of: command.rawValue, toByteOffset: SMCLayout.command, as: UInt8.self)
    }

    private func call() -> Bool {
        var outputSize = SMCLayout.size
        let status = IOConnectCallStructMethod(connection, Self.structMethodSelector, input, SMCLayout.size, output, &outputSize)
        return status == KERN_SUCCESS && output.load(fromByteOffset: SMCLayout.result, as: UInt8.self) == 0
    }

    private func byte(_ offset: Int) -> UInt8 {
        output.load(fromByteOffset: SMCLayout.bytes + offset, as: UInt8.self)
    }

    private func bigEndian(_ count: Int) -> UInt32 {
        (0..<count).reduce(0) { $0 << 8 | UInt32(byte($1)) }
    }

    private func decode(type: SMCKey, size: Int) -> Double? {
        switch type {
        case Self.float32 where size == 4:
            return Double(Float(bitPattern: output.load(fromByteOffset: SMCLayout.bytes, as: UInt32.self)))
        case Self.sp78 where size == 2:
            return Double(Int16(bitPattern: UInt16(bigEndian(2)))) / 256
        case Self.fpe2 where size == 2:
            return Double(bigEndian(2)) / 4
        case Self.ui8, Self.ui16, Self.ui32:
            return Double(bigEndian(min(size, 4)))
        default:
            return nil
        }
    }
}
