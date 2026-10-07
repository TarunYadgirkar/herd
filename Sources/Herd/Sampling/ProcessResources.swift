import Darwin
import Foundation
import IOKit.pwr_mgt

enum ProcessResources {
    private static let maxFileDescriptors = 4096

    static func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    static func listeningPorts(_ pid: pid_t) -> [UInt16] {
        let fdSize = MemoryLayout<proc_fdinfo>.stride
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let capacity = min(Int(bytes) / fdSize + 16, maxFileDescriptors)
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }
        let ports = fds.prefix(Int(filled) / fdSize)
            .filter { $0.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) }
            .compactMap { listeningPort(pid: pid, fd: $0.proc_fd) }
        return Array(Set(ports)).sorted()
    }

    private static func listeningPort(pid: pid_t, fd: Int32) -> UInt16? {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
              info.psi.soi_kind == Int32(SOCKINFO_TCP) else { return nil }
        let tcp = info.psi.soi_proto.pri_tcp
        guard tcp.tcpsi_state == TSI_S_LISTEN else { return nil }
        return UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
    }

    static func sleepAssertions() -> [pid_t: [String]] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let dictionary = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [:] }
        var result: [pid_t: [String]] = [:]
        for (pid, assertions) in dictionary {
            let names = assertions.compactMap(preventsSleep)
            if !names.isEmpty { result[pid.int32Value] = names }
        }
        return result
    }

    private static let sleepPreventingTypes: Set<String> = [
        "PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep", "PreventSystemSleep", "NoIdleSleepAssertion", "NoDisplaySleepAssertion",
    ]

    private static func preventsSleep(_ assertion: [String: Any]) -> String? {
        guard let type = assertion["AssertType"] as? String, sleepPreventingTypes.contains(type) else { return nil }
        return (assertion["AssertName"] as? String) ?? type
    }
}
