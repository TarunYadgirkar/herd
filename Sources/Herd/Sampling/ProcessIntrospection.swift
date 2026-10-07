import Darwin
import Foundation

enum ProcessIntrospection {
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t

    private static let responsibleFn: ResponsibleFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFn.self)
    }()

    private static let pathBufferSize = 4 * Int(MAXPATHLEN)
    private static let maxArguments = 64

    static func executablePath(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: pathBufferSize)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func responsiblePid(_ pid: pid_t) -> pid_t {
        guard let responsibleFn, pid > 0 else { return pid }
        let responsible = responsibleFn(pid)
        return responsible > 0 ? responsible : pid
    }

    static func argumentBufferSize() -> Int {
        var argMax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &argMax, &size, nil, 0) == 0, argMax > 0 else { return 0 }
        return Int(argMax)
    }

    static func arguments(_ pid: pid_t, buffer: inout [UInt8]) -> [String] {
        guard pid > 0, let raw = procArgs(pid, buffer: &buffer), raw.count > MemoryLayout<Int32>.size else { return [] }
        let argc = raw.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        while index < raw.count && raw[index] != 0 { index += 1 }
        while index < raw.count && raw[index] == 0 { index += 1 }
        var result: [String] = []
        let limit = min(argc, maxArguments)
        while index < raw.count && result.count < limit {
            let start = index
            while index < raw.count && raw[index] != 0 { index += 1 }
            result.append(String(decoding: raw[start..<index], as: UTF8.self))
            index += 1
        }
        return result
    }

    private static func procArgs(_ pid: pid_t, buffer: inout [UInt8]) -> ArraySlice<UInt8>? {
        guard !buffer.isEmpty else { return nil }
        var length = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &length, nil, 0) == 0 else { return nil }
        return buffer.prefix(length)
    }
}
