// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import Foundation
import Network

/// A loopback-only HTTP server for the scripted checks: serves fixed pages by path on 127.0.0.1 (an ephemeral port),
/// never on the network. One request per connection.
final class LocalPageServer {
    /// A fixed response.
    struct Page {
        var status = "200 OK"
        var headers: [String: String] = [:]
        var body: String
        /// Seconds before the answer goes out (a slow server).
        var delay: TimeInterval = 0
    }

    /// Asked first for every request, on the server's queue: a page that changes from one request to the next (a
    /// favicon that fails once). Set it before `start`.
    var handler: ((String) -> Page?)?

    private let listener: NWListener
    private let pages: [String: Page]
    private let queue = DispatchQueue(label: "airc.test.page-server")

    convenience init?(pages: [String: String]) {
        self.init(responses: pages.mapValues { Page(body: $0) })
    }

    init?(responses: [String: Page]) {
        pages = responses
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        params.acceptLocalOnly = true
        guard let l = try? NWListener(using: params) else { return nil }
        listener = l
    }

    /// Calls `ready` on the main queue with the port, or nil if the server couldn't listen.
    func start(_ ready: @escaping (UInt16?) -> Void) {
        var answered = false
        listener.stateUpdateHandler = { [listener] state in
            let port: UInt16?
            switch state {
            case .ready: port = listener.port?.rawValue
            case .failed, .cancelled: port = nil
            default: return
            }
            DispatchQueue.main.async {
                guard !answered else { return }
                answered = true
                ready(port)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, Data())
    }

    private func receive(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                // A form's POST body is read before the answer (closing with it unread would reset the connection).
                let length = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
                if buffer.count - end.upperBound < length, !complete, error == nil { return self.receive(connection, buffer) }
                let target = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                self.respond(connection, path: String(target.split(separator: "?").first ?? "/"))
            } else if complete || error != nil || buffer.count > 65536 {
                connection.cancel()
            } else {
                self.receive(connection, buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, path: String) {
        let page = handler?(path) ?? pages[path] ?? Page(status: "404 Not Found", body: "not found")
        guard page.delay <= 0 else {
            var now = page
            now.delay = 0
            return queue.asyncAfter(deadline: .now() + page.delay) { self.send(now, on: connection) }
        }
        send(page, on: connection)
    }

    private func send(_ page: Page, on connection: NWConnection) {
        let bytes = Data(page.body.utf8)
        let extra = page.headers.map { "\($0.key): \($0.value)\r\n" }.sorted().joined()
        let head = "HTTP/1.1 \(page.status)\r\nContent-Type: text/html; charset=utf-8\r\n\(extra)"
            + "Content-Length: \(bytes.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in connection.cancel() })
    }
}
#endif
