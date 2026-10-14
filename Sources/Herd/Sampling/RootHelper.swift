import Foundation
import HerdHelperKit
import ServiceManagement

enum RootHelperState: Equatable {
    case off
    case needsApproval
    case on
    case unavailable
}

// The root helper reads exact counters for system and other-user processes, the ones Herd can't read itself.
// While it answers, top isn't needed at all; if it's off or stops answering, sampling falls back to top.
final class RootHelper: @unchecked Sendable {
    static let shared = RootHelper()

    private static let replyTimeout: DispatchTimeInterval = .milliseconds(500)
    private static let retryAfterFailure: TimeInterval = 30
    private static let stateRefresh: TimeInterval = 30

    private let lock = NSLock()
    private let helperRequirement = HelperIdentity.requirement(identifier: HelperIdentity.helperLabel)
    private var connection: NSXPCConnection?
    private var failedAt: Date = .distantPast
    private var cachedState: (state: RootHelperState, at: Date)?

    private var service: SMAppService { SMAppService.daemon(plistName: HelperIdentity.daemonPlist) }

    var state: RootHelperState {
        switch service.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        // A daemon that was never registered reports notFound rather than notRegistered, so both read as off;
        // a bundle that truly lacks the helper fails at register() and shows that error instead.
        case .notRegistered, .notFound: .off
        @unknown default: .unavailable
        }
    }

    func register() throws {
        defer { lock.withLock { cachedState = nil } }
        try service.register()
    }

    func unregister() async throws {
        lock.withLock {
            tearDownLocked()
            cachedState = nil
        }
        try await service.unregister()
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // Returns nil when the helper can't answer, so the caller knows to use top instead of treating every process as idle.
    func usage(for pids: [pid_t]) -> [pid_t: RawUsage]? {
        guard !pids.isEmpty, recentState() == .on, let proxy = proxy() else { return nil }
        let box = ReplyBox()
        proxy.usage(for: pids.map { NSNumber(value: $0) }) { data in box.fill(data) }
        guard let data = box.wait(Self.replyTimeout), data.count <= HelperIdentity.maxReplyBytes, let usages = RawUsage.decode(data) else {
            lock.withLock {
                failedAt = Date()
                tearDownLocked()
            }
            return nil
        }
        return Dictionary(usages.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // Asking Background Task Management for the status is an IPC round trip, so sampling rechecks it only now and then.
    private func recentState() -> RootHelperState {
        if let cached = lock.withLock({ cachedState }), Date().timeIntervalSince(cached.at) < Self.stateRefresh { return cached.state }
        let current = state
        lock.withLock { cachedState = (current, Date()) }
        return current
    }

    private func proxy() -> HerdHelperProtocol? {
        lock.withLock {
            guard Date().timeIntervalSince(failedAt) >= Self.retryAfterFailure else { return nil }
            let connection = connection ?? makeConnectionLocked()
            return connection.remoteObjectProxyWithErrorHandler { [weak self] _ in self?.connectionFailed() } as? HerdHelperProtocol
        }
    }

    private func makeConnectionLocked() -> NSXPCConnection {
        let next = NSXPCConnection(machServiceName: HelperIdentity.machService, options: .privileged)
        next.remoteObjectInterface = NSXPCInterface(with: HerdHelperProtocol.self)
        next.setCodeSigningRequirement(helperRequirement)
        next.invalidationHandler = { [weak self] in self?.connectionFailed() }
        next.resume()
        connection = next
        return next
    }

    private func connectionFailed() {
        lock.withLock { connection = nil }
    }

    private func tearDownLocked() {
        connection?.invalidate()
        connection = nil
    }
}

private final class ReplyBox: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var data: Data?

    func fill(_ value: Data) {
        lock.withLock { data = value }
        semaphore.signal()
    }

    func wait(_ timeout: DispatchTimeInterval) -> Data? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return lock.withLock { data }
    }
}
