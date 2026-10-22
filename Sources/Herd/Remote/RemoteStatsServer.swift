import Foundation
import Network
import os

// Answers GET /stats with this Mac's RemoteStats as JSON, for Herd on the user's other Macs.
// Only Tailscale peers get an answer; everyone else is disconnected before anything is read.
final class RemoteStatsServer: @unchecked Sendable {
    nonisolated private static let log = Logger(subsystem: "com.tarunyadgirkar.herd", category: "remote")
    private static let maxRequestBytes = 4096

    private let queue = DispatchQueue(label: "com.tarunyadgirkar.herd.remote-server")
    private let lock = NSLock()
    private var listener: NWListener?
    private let provider: @Sendable () async -> RemoteStats?

    init(provider: @escaping @Sendable () async -> RemoteStats?) {
        self.provider = provider
    }

    func setEnabled(_ isEnabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isEnabled, listener == nil {
            listener = makeListener()
        } else if !isEnabled {
            listener?.cancel()
            listener = nil
        }
    }

    private func makeListener() -> NWListener? {
        guard let port = NWEndpoint.Port(rawValue: RemoteNetwork.port) else { return nil }
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: port)
        } catch {
            Self.log.error("Could not listen on port \(RemoteNetwork.port): \(error.localizedDescription)")
            return nil
        }
        listener.stateUpdateHandler = { state in
            if case let .failed(error) = state {
                Self.log.error("Stats sharing stopped: \(error.localizedDescription)")
            }
        }
        listener.newConnectionHandler = { [provider, queue] connection in
            guard RemoteNetwork.isTrusted(connection.endpoint) else {
                connection.cancel()
                return
            }
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequestBytes) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let isStatsRequest = request.hasPrefix("GET \(RemoteNetwork.path) ") || request.hasPrefix("GET \(RemoteNetwork.path)?")
                Task {
                    let body = isStatsRequest ? await provider().flatMap { try? RemoteStats.encoder.encode($0) } : nil
                    connection.send(content: RemoteHTTP.response(body), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
        listener.start(queue: queue)
        return listener
    }
}

enum RemoteHTTP {
    static func response(_ body: Data?) -> Data {
        let status = body == nil ? "404 Not Found" : "200 OK"
        let payload = body ?? Data()
        let head = "HTTP/1.0 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + payload
    }

    // Splits a raw HTTP/1.0 response into its status code and body.
    static func parse(_ data: Data) -> (status: Int, body: Data)? {
        guard let split = data.firstRange(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<split.lowerBound], encoding: .utf8),
              let statusLine = head.split(separator: "\r\n").first else { return nil }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        return (status, Data(data[split.upperBound...]))
    }
}
