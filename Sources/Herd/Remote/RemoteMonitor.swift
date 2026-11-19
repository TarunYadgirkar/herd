import Foundation
import Network
import Observation

struct RemoteMac: Equatable {
    static let offlineAfter: TimeInterval = 25

    var stats: RemoteStats?
    var lastSeen: Date?
    var failure: String?
    var needsKey = false

    // Missing two polls in a row means the Mac is asleep, off, or off the tailnet.
    func isOnline(at now: Date) -> Bool {
        guard let lastSeen else { return false }
        return now.timeIntervalSince(lastSeen) < Self.offlineAfter
    }
}

// Polls the Macs listed in Settings for their shared stats.
@MainActor
@Observable
final class RemoteMonitor {
    static let hostsKey = "remoteMacs"
    static let shareKey = "shareStatsOverTailscale"
    static let pollInterval = Duration.seconds(10)

    private(set) var macs: [String: RemoteMac] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var keys: [String: String] = [:]

    var hosts: [String] { RemoteNetwork.hosts(from: UserDefaults.standard.string(forKey: Self.hostsKey) ?? "") }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled, let self {
                await self.pollAll()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func refreshNow() {
        Task { await pollAll() }
    }

    func hasKey(for host: String) -> Bool { key(for: host) != nil }

    func setKey(_ key: String, for host: String) {
        guard RemoteKey.saveRemote(key, host: host) else { return }
        keys[host] = key
        refreshNow()
    }

    private func key(for host: String) -> String? {
        if let key = keys[host] { return key }
        let key = RemoteKey.remote(host: host)
        keys[host] = key
        return key
    }

    private func pollAll() async {
        let hosts = hosts
        for host in macs.keys where !hosts.contains(host) { macs.removeValue(forKey: host) }
        await withTaskGroup(of: (String, Result<RemoteStats, Error>).self) { group in
            for host in hosts {
                guard let key = key(for: host) else {
                    macs[host, default: RemoteMac()].needsKey = true
                    continue
                }
                group.addTask { (host, await Result { try await RemoteClient.fetch(host: host, key: key) }) }
            }
            for await (host, result) in group {
                var mac = macs[host] ?? RemoteMac()
                mac.needsKey = false
                switch result {
                case let .success(stats):
                    mac.stats = stats
                    mac.lastSeen = Date()
                    mac.failure = nil
                case let .failure(error):
                    mac.failure = error.localizedDescription
                }
                macs[host] = mac
            }
        }
    }
}

extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}

enum RemoteClientError: LocalizedError {
    case timedOut, badResponse, notSharing, keyRejected

    var errorDescription: String? {
        switch self {
        case .timedOut: "Not reachable"
        case .badResponse: "Unexpected reply"
        case .notSharing: "Sharing is off on that Mac"
        case .keyRejected: "That Mac didn't accept the key"
        }
    }
}

// A plain TCP request instead of URLSession: App Transport Security refuses HTTP to tailnet names, and this needs no exception.
enum RemoteClient {
    private static let timeout = Duration.seconds(5)
    private static let maxResponseBytes = 64 * 1024

    static func fetch(host: String, key: String) async throws -> RemoteStats {
        let data = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await request(host: host, key: key) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RemoteClientError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next() ?? Data()
        }
        // A Mac that doesn't recognise the key hangs up without a reply.
        guard !data.isEmpty else { throw RemoteClientError.keyRejected }
        guard let response = RemoteHTTP.parse(data) else { throw RemoteClientError.badResponse }
        guard response.status == 200 else { throw RemoteClientError.notSharing }
        return try RemoteStats.decoder.decode(RemoteStats.self, from: response.body)
    }

    private static func request(host: String, key: String) async throws -> Data {
        guard let port = NWEndpoint.Port(rawValue: RemoteNetwork.port) else { throw RemoteClientError.badResponse }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let reader = ResponseReader(connection: connection, limit: maxResponseBytes)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reader.run(request: message(host: host, key: key), continuation: continuation)
            }
        } onCancel: {
            connection.cancel()
        }
    }
}

extension RemoteClient {
    static func message(host: String, key: String) -> Data {
        Data("GET \(RemoteNetwork.path) HTTP/1.0\r\nHost: \(host)\r\nAuthorization: Bearer \(key)\r\n\r\n".utf8)
    }
}

// Reads until the server closes the connection, resuming the continuation exactly once.
private final class ResponseReader: @unchecked Sendable {
    private let connection: NWConnection
    private let limit: Int
    private let lock = NSLock()
    private var buffer = Data()
    private var continuation: CheckedContinuation<Data, Error>?

    init(connection: NWConnection, limit: Int) {
        self.connection = connection
        self.limit = limit
    }

    func run(request: Data, continuation: CheckedContinuation<Data, Error>) {
        lock.withLock { self.continuation = continuation }
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                connection.send(content: request, completion: .contentProcessed { [self] error in
                    if let error { finish(.failure(error)) } else { receive() }
                })
            case let .failed(error), let .waiting(error):
                finish(.failure(error))
            case .cancelled:
                finish(.failure(CancellationError()))
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .utility))
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: limit) { [self] data, _, isComplete, error in
            let isFull = lock.withLock {
                if let data { buffer.append(data) }
                return buffer.count >= limit
            }
            if let error {
                finish(.failure(error))
            } else if isComplete || isFull {
                finish(.success(lock.withLock { buffer }))
            } else {
                receive()
            }
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        let pending = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        guard let pending else { return }
        connection.cancel()
        pending.resume(with: result)
    }
}
