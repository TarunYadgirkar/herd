import CryptoKit
import Foundation
import Security

public enum HelperIdentity {
    public static let teamID = "5AKJYZ7USP"
    public static let appBundleID = "com.tarunyadgirkar.herd"
    public static let helperLabel = "com.tarunyadgirkar.herd.helper"
    public static let machService = helperLabel
    public static let daemonPlist = "\(helperLabel).plist"
    public static let maxPidsPerRequest = 16_384
    public static let maxReplyBytes = 4 * 1024 * 1024

    // Each side only talks to code with the other's identifier, signed by the very certificate that signed itself, and not
    // debuggable. A team match alone would let any development certificate on the team sign an impostor that borrows root access.
    public static func requirement(identifier: String) -> String {
        let signer = ownLeafCertificateHash().map { "certificate leaf = H\"\($0)\"" } ?? "certificate leaf[subject.OU] = \"\(teamID)\""
        return "identifier \"\(identifier)\" and anchor apple generic and \(signer) and !(entitlement[\"com.apple.security.get-task-allow\"] exists)"
    }

    public static func ownLeafCertificateHash() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data)
        return digest.map { String(format: "%02X", $0) }.joined()
    }
}

// Raw kernel counters for one process, read as root. Herd turns them into rates exactly as it does for its own user's processes.
public struct RawUsage: Codable, Sendable, Equatable {
    public let pid: Int32
    public let cpuTicks: UInt64
    public let energyNanojoules: UInt64
    public let idleWakeups: UInt64
    public let diskRead: UInt64
    public let diskWrite: UInt64
    public let footprint: UInt64
    public let threads: Int32

    public init(pid: Int32, cpuTicks: UInt64, energyNanojoules: UInt64, idleWakeups: UInt64, diskRead: UInt64, diskWrite: UInt64, footprint: UInt64, threads: Int32) {
        self.pid = pid
        self.cpuTicks = cpuTicks
        self.energyNanojoules = energyNanojoules
        self.idleWakeups = idleWakeups
        self.diskRead = diskRead
        self.diskWrite = diskWrite
        self.footprint = footprint
        self.threads = threads
    }

    public static func encode(_ usages: [RawUsage]) -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return (try? encoder.encode(usages)) ?? Data()
    }

    public static func decode(_ data: Data) -> [RawUsage]? {
        try? PropertyListDecoder().decode([RawUsage].self, from: data)
    }
}

@objc public protocol HerdHelperProtocol {
    func usage(for pids: [NSNumber], reply: @escaping @Sendable (Data) -> Void)
}
