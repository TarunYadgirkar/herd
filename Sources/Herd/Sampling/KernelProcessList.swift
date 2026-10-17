import Darwin
import Foundation

struct KernelProcess {
    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t
    let comm: String
    let startTime: Date
    let isStopped: Bool
}

enum KernelProcessList {
    private static let fetchAttempts = 4

    static func process(_ pid: pid_t) -> KernelProcess? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return makeProcess(info)
    }

    // The caller keeps the buffer between ticks, so a tick reuses about 800 KB instead of allocating and zeroing it again.
    static func all(reusing buffer: inout [kinfo_proc]) -> [KernelProcess] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        for _ in 0..<fetchAttempts {
            var size = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return [] }
            let capacity = size / MemoryLayout<kinfo_proc>.stride + 32
            if buffer.count < capacity { buffer = [kinfo_proc](repeating: kinfo_proc(), count: capacity + capacity / 8) }
            size = buffer.count * MemoryLayout<kinfo_proc>.stride
            let result = buffer.withUnsafeMutableBufferPointer {
                sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0)
            }
            if result != 0 && errno == ENOMEM {
                buffer = []
                continue
            }
            guard result == 0 else { return [] }
            let count = size / MemoryLayout<kinfo_proc>.stride
            return buffer.prefix(count).compactMap(makeProcess)
        }
        return []
    }

    private static func makeProcess(_ info: kinfo_proc) -> KernelProcess? {
        let pid = info.kp_proc.p_pid
        guard pid >= 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let comm = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let startTime = Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
        return KernelProcess(
            pid: pid,
            ppid: info.kp_eproc.e_ppid,
            uid: info.kp_eproc.e_ucred.cr_uid,
            comm: comm,
            startTime: startTime,
            isStopped: info.kp_proc.p_stat == SSTOP
        )
    }
}
