import Darwin
import Foundation
import HerdHelperKit

// Runs as root under launchd, registered by Herd through SMAppService. It only reads process counters and returns them;
// it takes no paths, commands or signals, so the most a caller can learn is what Activity Monitor already shows.
final class HelperService: NSObject, HerdHelperProtocol {
    func usage(for pids: [NSNumber], reply: @escaping @Sendable (Data) -> Void) {
        guard pids.count <= HelperIdentity.maxPidsPerRequest else { return reply(Data()) }
        let usages = pids.compactMap { Self.read(pid_t($0.int32Value)) }
        reply(RawUsage.encode(usages))
    }

    private static func read(_ pid: pid_t) -> RawUsage? {
        guard pid >= 0 else { return nil }
        var usage = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        guard status == 0 else { return nil }
        return RawUsage(
            pid: pid,
            cpuTicks: usage.ri_user_time &+ usage.ri_system_time,
            energyNanojoules: usage.ri_energy_nj,
            idleWakeups: usage.ri_pkg_idle_wkups,
            diskRead: usage.ri_diskio_bytesread,
            diskWrite: usage.ri_diskio_byteswritten,
            footprint: usage.ri_phys_footprint,
            threads: threadCount(pid)
        )
    }

    private static func threadCount(_ pid: pid_t) -> Int32 {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return 0 }
        return info.pti_threadnum
    }
}

private let clientRequirement = HelperIdentity.requirement(identifier: HelperIdentity.appBundleID)

// launchd starts the helper on Herd's first request, so it exits once Herd has been gone for a while instead of idling as root.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private static let idleExit: TimeInterval = 60
    private let service = HelperService()
    private let lock = NSLock()
    private var connections = 0
    private var generation = 0

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: HerdHelperProtocol.self)
        connection.exportedObject = service
        connection.invalidationHandler = { [weak self] in self?.connectionEnded() }
        lock.withLock {
            connections += 1
            generation += 1
        }
        connection.resume()
        return true
    }

    private func connectionEnded() {
        let pending: Int? = lock.withLock {
            connections = max(connections - 1, 0)
            return connections == 0 ? generation : nil
        }
        guard let pending else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleExit) { [weak self] in
            guard let self, self.lock.withLock({ self.connections == 0 && self.generation == pending }) else { return }
            exit(0)
        }
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperIdentity.machService)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
