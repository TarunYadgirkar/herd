import Foundation
import Network
import os

// Answers GET /stats with this Mac's RemoteStats as JSON, for Herd on the user's other Macs,
// and takes battery reports from the user's phone and watch on /battery.
// Only Tailscale peers get an answer; everyone else is disconnected before anything is read.
// A peer also has to send this Mac's key, and one that doesn't is dropped without a reply, whatever it asked for.
final class RemoteStatsServer: @unchecked Sendable {
    nonisolated private static let log = Logger(subsystem: "com.tarunyadgirkar.herd", category: "remote")
    private static let maxRequestBytes = 4096
    private static let requestTimeout: DispatchTimeInterval = .seconds(5)

    private let queue = DispatchQueue(label: "com.tarunyadgirkar.herd.remote-server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var sharesStats = false
    private var acceptsReports = false
    private var key: String?
    private let provider: @Sendable () async -> RemoteStats?

    init(provider: @escaping @Sendable () async -> RemoteStats?) {
        self.provider = provider
    }

    func configure(sharesStats: Bool, acceptsReports: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.sharesStats = sharesStats
        self.acceptsReports = acceptsReports
        let isEnabled = sharesStats || acceptsReports
        key = isEnabled ? RemoteKey.own() : nil
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
        listener.newConnectionHandler = { [weak self, queue] connection in
            guard RemoteNetwork.isTrusted(connection.endpoint) else {
                connection.cancel()
                return
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + Self.requestTimeout) { connection.cancel() }
            connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequestBytes) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                // Other networks hand out 100.64.x.x addresses too, so the request must also have arrived on this Mac's Tailscale address.
                let isAuthorized = self?.isAuthorized(request) ?? false
                guard isAuthorized, RemoteNetwork.isOwnAddress(connection.currentPath?.localEndpoint), !RemoteHTTP.isFromBrowser(request) else {
                    connection.cancel()
                    return
                }
                Task { [weak self] in
                    let response = await self?.response(to: request) ?? RemoteHTTP.response(nil)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
        listener.start(queue: queue)
        return listener
    }

    private func isAuthorized(_ request: String) -> Bool {
        RemoteKey.isAuthorized(request, key: lock.withLock { key })
    }

    private func response(to request: String) async -> Data {
        let (sharesStats, acceptsReports) = lock.withLock { (self.sharesStats, self.acceptsReports) }
        if acceptsReports, BatteryReport.isReport(request) {
            guard let report = BatteryReport.parse(request: request) else {
                return RemoteHTTP.response(status: "400 Bad Request", message: "Send a name and a level from 0 to 100.")
            }
            guard ReportedBatteries.shared.record(report) else {
                return RemoteHTTP.response(status: "429 Too Many Requests", message: "Herd already tracks \(ReportedBatteries.maxDevices) reporting devices.")
            }
            return RemoteHTTP.response(status: "200 OK", message: "Saved \(report.name) at \(Int(report.percent))%.")
        }
        let isStatsRequest = request.hasPrefix("GET \(RemoteNetwork.path) ") || request.hasPrefix("GET \(RemoteNetwork.path)?")
        guard sharesStats, isStatsRequest else { return RemoteHTTP.response(nil) }
        return RemoteHTTP.response(await provider().flatMap { try? RemoteStats.encoder.encode($0) })
    }
}

enum RemoteHTTP {
    static func response(_ body: Data?) -> Data {
        let status = body == nil ? "404 Not Found" : "200 OK"
        let payload = body ?? Data()
        let head = "HTTP/1.0 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + payload
    }

    // A web page can make the browser send requests from this Mac's own trusted address. Herd and Shortcuts never send these headers.
    static func isFromBrowser(_ request: String) -> Bool {
        request.split(separator: "\r\n").dropFirst().contains { line in
            let header = line.lowercased()
            return header.hasPrefix("origin:") || header.hasPrefix("referer:") || header.hasPrefix("sec-fetch-")
        }
    }

    static func response(status: String, message: String) -> Data {
        let payload = Data(message.utf8)
        let head = "HTTP/1.0 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nX-Content-Type-Options: nosniff\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
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
