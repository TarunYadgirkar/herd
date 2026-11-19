import CryptoKit
import Foundation
import os
import Security

// A Tailscale address only proves a device is on the tailnet. The key proves it is one the owner set up:
// every request to the stats server has to carry this Mac's key, and this Mac keeps the key of each Mac it watches.
enum RemoteKey {
    static let queryName = "key"
    private static let byteCount = 32
    static let length = 43
    private static let ownAccount = "sharing-key"
    private static let headerName = "authorization:"
    private static let scheme = "bearer "
    private static let lock = NSLock()

    static func own() -> String? {
        lock.withLock {
            if let key = Keychain.read(ownAccount) { return key }
            let key = generate()
            return Keychain.save(key, account: ownAccount) ? key : nil
        }
    }

    static func reset() {
        lock.withLock { Keychain.delete(ownAccount) }
    }

    static func remote(host: String) -> String? {
        Keychain.read(remoteAccount(host))
    }

    static func saveRemote(_ key: String, host: String) -> Bool {
        Keychain.save(key, account: remoteAccount(host))
    }

    // Keys are pasted by hand: a stray line break would end the Authorization header early, and a stray keystroke must not replace a saved key.
    static func cleaned(_ text: String) -> String? {
        let key = String(text.filter { !$0.isWhitespace })
        return key.count == length ? key : nil
    }

    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        precondition(SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // Comparing digests keeps the work the same whatever was sent, so timing gives away neither the key's length nor how much of a guess was right.
    static func matches(_ candidate: String, _ expected: String) -> Bool {
        let difference = zip(SHA256.hash(data: Data(candidate.utf8)), SHA256.hash(data: Data(expected.utf8)))
            .reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) }
        return difference == 0
    }

    // Herd sends the key as "Authorization: Bearer <key>". Shortcuts can't set headers easily, so it sends key=<key> in the address.
    static func presented(in request: String) -> String? {
        let lines = request.split(separator: "\r\n", omittingEmptySubsequences: false)
        if let header = lines.dropFirst().prefix(while: { !$0.isEmpty }).first(where: { $0.lowercased().hasPrefix(headerName) }) {
            let value = header.dropFirst(headerName.count).trimmingCharacters(in: .whitespaces)
            guard value.lowercased().hasPrefix(scheme) else { return nil }
            return value.dropFirst(scheme.count).trimmingCharacters(in: .whitespaces)
        }
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count == 3 else { return nil }
        return URLComponents(string: String(parts[1]))?.queryItems?.first { $0.name == queryName }?.value
    }

    static func isAuthorized(_ request: String, key: String?) -> Bool {
        guard let key, !key.isEmpty else { return false }
        return matches(presented(in: request) ?? "", key)
    }

    private static func remoteAccount(_ host: String) -> String { "remote.\(host)" }
}

private enum Keychain {
    private static let service = "com.tarunyadgirkar.herd"
    private static let log = Logger(subsystem: service, category: "keychain")

    private static func query(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    static func read(_ account: String) -> String? {
        var item: CFTypeRef?
        let query = query(account).merging([kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]) { $1 }
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, account: String) -> Bool {
        delete(account)
        let attributes = query(account).merging([
            kSecValueData: Data(value.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { $1 }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess { log.error("Saving a key to the Keychain failed: \(status)") }
        return status == errSecSuccess
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
