import Darwin
import Foundation
import Security

struct ProcessDetails: Sendable {
    struct Ancestor: Sendable, Identifiable, Hashable {
        let pid: pid_t
        let name: String

        var id: pid_t { pid }
    }

    struct Connection: Sendable, Identifiable, Hashable {
        let id: String
        let proto: String
        let local: String
        let remote: String?
        let state: String?

        var isListening: Bool { state == TCPState.listen }
    }

    struct OpenFile: Sendable, Identifiable, Hashable {
        let id: Int32
        let path: String
    }

    let pid: pid_t
    let parentChain: [Ancestor]
    let started: Date?
    let cpuTime: TimeInterval?
    let nice: Int32?
    let threads: Int?
    let isEfficiencyMode: Bool?
    let workingDirectory: String?
    let arguments: [String]
    let environment: [String]?
    let connections: [Connection]
    let files: [OpenFile]
    let openFileCount: Int
    let signature: Signature?
    let bundlePath: String?
    let bundleIdentifier: String?
    let bundleVersion: String?

    static let maxFiles = 500
    static let maxConnections = 300

    // The signature and bundle never change while the process runs, and checking a large app's seal can take seconds, so refreshes reuse them.
    static func load(pid: pid_t, path: String, reusing previous: ProcessDetails? = nil) -> ProcessDetails {
        let kernel = KernelInfo.read(pid)
        let task = TaskInfo.read(pid)
        let descriptors = Descriptors.read(pid)
        let procArgs = ProcArgs.read(pid)
        let bundlePath = previous?.bundlePath ?? Self.bundlePath(for: path)
        let bundle = bundlePath.flatMap(Bundle.init(path:))
        return ProcessDetails(
            pid: pid,
            parentChain: Ancestry.chain(from: pid),
            started: kernel?.started,
            cpuTime: task?.cpuTime,
            nice: kernel?.nice,
            threads: task?.threads,
            isEfficiencyMode: task?.isBackground,
            workingDirectory: ProcessResources.workingDirectory(pid),
            arguments: procArgs?.arguments ?? [],
            environment: procArgs?.environment,
            connections: descriptors.connections,
            files: descriptors.files,
            openFileCount: descriptors.fileCount,
            signature: previous?.signature ?? Signature.read(path: bundlePath ?? path),
            bundlePath: bundlePath,
            bundleIdentifier: previous?.bundleIdentifier ?? bundle?.bundleIdentifier,
            bundleVersion: previous?.bundleVersion ?? bundle.flatMap(version)
        )
    }

    static func bundlePath(for executable: String) -> String? {
        guard let range = executable.range(of: ".app/") else { return nil }
        return String(executable[..<range.lowerBound]) + ".app"
    }

    private static func version(_ bundle: Bundle) -> String? {
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard let short else { return build }
        guard let build, build != short else { return short }
        return "\(short) (\(build))"
    }
}

private struct KernelInfo {
    let ppid: pid_t
    let name: String
    let started: Date
    let nice: Int32

    static func read(_ pid: pid_t) -> KernelInfo? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let comm = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        let path = ProcessIntrospection.executablePath(pid)
        return KernelInfo(
            ppid: info.kp_eproc.e_ppid,
            name: path.isEmpty ? comm : (path as NSString).lastPathComponent,
            started: Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000),
            nice: Int32(info.kp_proc.p_nice)
        )
    }
}

private enum Ancestry {
    private static let maxDepth = 20

    static func chain(from pid: pid_t) -> [ProcessDetails.Ancestor] {
        var chain: [ProcessDetails.Ancestor] = []
        var current = pid
        while chain.count < maxDepth, let info = KernelInfo.read(current) {
            chain.append(ProcessDetails.Ancestor(pid: current, name: current == 0 ? "kernel_task" : info.name))
            guard current > 1, info.ppid != current else { break }
            current = info.ppid
        }
        return chain.reversed()
    }
}

private struct TaskInfo {
    let cpuTime: TimeInterval
    let threads: Int
    let isBackground: Bool

    // A task in the Darwin background band runs at base priority 4 (MAXPRI_THROTTLE); regular tasks sit at 31.
    private static let backgroundBasePriority: Int32 = 4

    private static let ticksToSeconds: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }()

    static func read(_ pid: pid_t) -> TaskInfo? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        let ticks = info.pti_total_user &+ info.pti_total_system
        return TaskInfo(
            cpuTime: Double(ticks) * ticksToSeconds,
            threads: Int(info.pti_threadnum),
            isBackground: info.pti_priority <= backgroundBasePriority
        )
    }
}

private struct ProcArgs {
    let arguments: [String]
    let environment: [String]

    static func read(_ pid: pid_t) -> ProcArgs? {
        var buffer = [UInt8](repeating: 0, count: ProcessIntrospection.argumentBufferSize())
        var length = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard length > 0, sysctl(&mib, 3, &buffer, &length, nil, 0) == 0, length > MemoryLayout<Int32>.size else { return nil }
        let raw = buffer.prefix(length)
        let argc = raw.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        skip(raw, &index, while: { $0 != 0 })
        skip(raw, &index, while: { $0 == 0 })
        var arguments: [String] = []
        while arguments.count < argc, let string = nextString(raw, &index) { arguments.append(string) }
        var environment: [String] = []
        while let string = nextString(raw, &index), !string.isEmpty { environment.append(string) }
        return ProcArgs(arguments: arguments, environment: environment)
    }

    private static func skip(_ raw: ArraySlice<UInt8>, _ index: inout Int, while predicate: (UInt8) -> Bool) {
        while index < raw.endIndex && predicate(raw[index]) { index += 1 }
    }

    private static func nextString(_ raw: ArraySlice<UInt8>, _ index: inout Int) -> String? {
        guard index < raw.endIndex else { return nil }
        let start = index
        skip(raw, &index, while: { $0 != 0 })
        defer { index += 1 }
        return String(decoding: raw[start..<index], as: UTF8.self)
    }
}

private enum TCPState {
    static let listen = "Listen"
    static let names = [
        "Closed", listen, "SYN Sent", "SYN Received", "Established", "Close Wait",
        "FIN Wait 1", "Closing", "Last ACK", "FIN Wait 2", "Time Wait",
    ]

    static func name(_ state: Int32) -> String? {
        names.indices.contains(Int(state)) ? names[Int(state)] : nil
    }
}

private struct Descriptors {
    let connections: [ProcessDetails.Connection]
    let files: [ProcessDetails.OpenFile]
    let fileCount: Int

    private static let maxDescriptors = 16_384
    private static let empty = Descriptors(connections: [], files: [], fileCount: 0)

    static func read(_ pid: pid_t) -> Descriptors {
        let fdSize = MemoryLayout<proc_fdinfo>.stride
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return empty }
        let capacity = min(Int(bytes) / fdSize + 16, maxDescriptors)
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return empty }
        var connections: [ProcessDetails.Connection] = []
        var files: [ProcessDetails.OpenFile] = []
        var fileCount = 0
        for fd in fds.prefix(Int(filled) / fdSize) {
            switch Int32(fd.proc_fdtype) {
            case PROX_FDTYPE_SOCKET:
                guard connections.count < ProcessDetails.maxConnections, let connection = socket(pid: pid, fd: fd.proc_fd) else { continue }
                connections.append(connection)
            case PROX_FDTYPE_VNODE:
                fileCount += 1
                guard files.count < ProcessDetails.maxFiles, let path = vnodePath(pid: pid, fd: fd.proc_fd) else { continue }
                files.append(ProcessDetails.OpenFile(id: fd.proc_fd, path: path))
            default:
                continue
            }
        }
        return Descriptors(connections: connections, files: files, fileCount: fileCount)
    }

    private static func vnodePath(pid: pid_t, fd: Int32) -> String? {
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvip.vip_path) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        return path.isEmpty ? nil : path
    }

    private static func socket(pid: pid_t, fd: Int32) -> ProcessDetails.Connection? {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { return nil }
        switch info.psi.soi_kind {
        case Int32(SOCKINFO_TCP):
            let tcp = info.psi.soi_proto.pri_tcp
            return connection(fd: fd, proto: "TCP", tcp.tcpsi_ini, state: TCPState.name(tcp.tcpsi_state))
        case Int32(SOCKINFO_IN) where info.psi.soi_protocol == IPPROTO_UDP:
            return connection(fd: fd, proto: "UDP", info.psi.soi_proto.pri_in, state: nil)
        default:
            return nil
        }
    }

    private static func connection(fd: Int32, proto: String, _ socket: in_sockinfo, state: String?) -> ProcessDetails.Connection? {
        let isV6 = socket.insi_vflag & UInt8(INI_IPV6) != 0
        guard isV6 || socket.insi_vflag & UInt8(INI_IPV4) != 0 else { return nil }
        let localPort = port(socket.insi_lport)
        let remotePort = port(socket.insi_fport)
        let local = endpoint(address(socket.insi_laddr, isV6: isV6), port: localPort, isV6: isV6)
        let remote = remotePort == 0 ? nil : endpoint(address(socket.insi_faddr, isV6: isV6), port: remotePort, isV6: isV6)
        let suffix = proto + (isV6 ? "6" : "4")
        return ProcessDetails.Connection(id: "\(fd)-\(suffix)", proto: isV6 ? "\(proto)6" : proto, local: local, remote: remote, state: state)
    }

    private static func port(_ raw: Int32) -> UInt16 {
        UInt16(bigEndian: UInt16(truncatingIfNeeded: raw))
    }

    private static func endpoint(_ address: String?, port: UInt16, isV6: Bool) -> String {
        guard let address else { return "*:\(port)" }
        return isV6 ? "[\(address)]:\(port)" : "\(address):\(port)"
    }

    private static func address(_ storage: in_sockinfo.__Unnamed_union_insi_laddr, isV6: Bool) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let text: String? = if isV6 {
            withUnsafePointer(to: storage.ina_6) { ntop(AF_INET6, $0, &buffer) }
        } else {
            withUnsafePointer(to: storage.ina_46.i46a_addr4) { ntop(AF_INET, $0, &buffer) }
        }
        guard let text, text != "0.0.0.0", text != "::" else { return nil }
        return text
    }

    private static func address(_ storage: in_sockinfo.__Unnamed_union_insi_faddr, isV6: Bool) -> String? {
        let bytes = withUnsafeBytes(of: storage) { Array($0) }
        let local = bytes.withUnsafeBytes { $0.loadUnaligned(as: in_sockinfo.__Unnamed_union_insi_laddr.self) }
        return address(local, isV6: isV6)
    }

    private static func ntop(_ family: Int32, _ pointer: UnsafeRawPointer, _ buffer: inout [CChar]) -> String? {
        guard inet_ntop(family, pointer, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

extension ProcessDetails {
    struct Signature: Sendable, Hashable {
        let isSigned: Bool
        let identifier: String?
        let teamID: String?
        let authority: [String]
        let isApple: Bool
        let isValid: Bool
        let isAdHoc: Bool
        let isNotarizedHint: Bool?

        // Leaf certificates read "Developer ID Application: Google LLC (EQHXZ8M8AV)", and people know the company, not the team ID.
        var signerName: String? {
            guard let leaf = authority.first else { return teamID }
            let afterRole = leaf.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? leaf
            guard let paren = afterRole.range(of: " (", options: .backwards) else { return afterRole }
            return String(afterRole[..<paren.lowerBound])
        }

        private static let adHocFlag: UInt32 = 0x0002
        private static let quickFlags = SecCSFlags(rawValue: kSecCSDoNotValidateResources | kSecCSDoNotValidateExecutable)

        static func read(path: String) -> Signature? {
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
            var staticCode: SecStaticCode?
            guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess, let code = staticCode else { return nil }
            let validity = SecStaticCodeCheckValidity(code, [], nil)
            guard validity != errSecCSUnsigned else { return unsigned }
            let info = signingInformation(code)
            let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
            let isAdHoc = flags & adHocFlag != 0
            let isApple = satisfies(code, "anchor apple")
            let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
            return Signature(
                isSigned: true,
                identifier: info[kSecCodeInfoIdentifier as String] as? String,
                teamID: teamID,
                authority: authorityNames(info),
                isApple: isApple,
                isValid: validity == errSecSuccess,
                isAdHoc: isAdHoc,
                isNotarizedHint: isApple || isAdHoc || teamID == nil ? nil : satisfies(code, "notarized")
            )
        }

        private static let unsigned = Signature(
            isSigned: false, identifier: nil, teamID: nil, authority: [], isApple: false, isValid: false, isAdHoc: false, isNotarizedHint: nil
        )

        private static func signingInformation(_ code: SecStaticCode) -> [String: Any] {
            var info: CFDictionary?
            guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return [:] }
            return info as? [String: Any] ?? [:]
        }

        private static func authorityNames(_ info: [String: Any]) -> [String] {
            guard let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate] else { return [] }
            return certificates.compactMap { SecCertificateCopySubjectSummary($0) as String? }
        }

        private static func requirement(_ text: String) -> SecRequirement? {
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
            return requirement
        }

        private static func satisfies(_ code: SecStaticCode, _ text: String) -> Bool {
            guard let requirement = requirement(text) else { return false }
            return SecStaticCodeCheckValidity(code, quickFlags, requirement) == errSecSuccess
        }
    }
}
