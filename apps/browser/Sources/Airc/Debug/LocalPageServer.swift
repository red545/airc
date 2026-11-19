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
        /// Bytes to send instead of `body` (an image, a video).
        var data: Data?
        /// Seconds before the answer goes out (a slow server).
        var delay: TimeInterval = 0
        /// A streamed answer (Server-Sent Events): chunked transfer, each chunk after its own delay instead of `body`.
        var chunks: [(data: Data, after: TimeInterval)]?
        /// With `chunks`: close the connection after the last one without ending the body (a dropped stream).
        var dropAtEnd = false
        /// With `chunks`, on the server queue: "complete", "dropped" or "client closed" (a send failed: the client went away).
        var onStreamEnd: ((String) -> Void)?
    }

    /// Asked first for every request, on the server's queue: a page that changes from one request to the next (a
    /// favicon that fails once). Set it before `start`.
    var handler: ((String) -> Page?)?

    /// Redirect checks also need the request method and query, before the path-only fallback.
    struct Request {
        var method: String
        var target: String
        var headers: [String: String] = [:]
        /// The request's body (a POST's), as received.
        var body = Data()
        var path: String { String(target.split(separator: "?").first ?? "/") }
    }
    var requestHandler: ((Request) -> Page?)?

    private let listener: NWListener
    private let pages: [String: Page]
    private let queue = DispatchQueue(label: "airc.test.page-server")

    convenience init?(pages: [String: String]) {
        self.init(responses: pages.mapValues { Page(body: $0) })
    }

    /// `port`: a fixed loopback port (an origin that must stay the same across a relaunch), or 0 for any free one.
    init?(responses: [String: Page], port: UInt16 = 0) {
        pages = responses
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port == 0 ? .any : NWEndpoint.Port(rawValue: port) ?? .any)
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
                let method = head.split(separator: " ").first.map(String.init) ?? "GET"
                var headers: [String: String] = [:]
                for line in head.components(separatedBy: "\r\n").dropFirst() {
                    let pair = line.split(separator: ":", maxSplits: 1)
                    if pair.count == 2 { headers[pair[0].lowercased()] = pair[1].trimmingCharacters(in: .whitespaces) }
                }
                self.respond(connection, request: Request(method: method, target: target, headers: headers,
                                                          body: Data(buffer[end.upperBound...])))
            } else if complete || error != nil || buffer.count > 65536 {
                connection.cancel()
            } else {
                self.receive(connection, buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, request: Request) {
        let page = requestHandler?(request) ?? handler?(request.path) ?? pages[request.path] ?? Page(status: "404 Not Found", body: "not found")
        guard page.delay <= 0 else {
            var now = page
            now.delay = 0
            return queue.asyncAfter(deadline: .now() + page.delay) { self.send(now, on: connection) }
        }
        send(page, on: connection)
    }

    private func send(_ page: Page, on connection: NWConnection) {
        if let chunks = page.chunks { return stream(page, chunks, on: connection) }
        let bytes = page.data ?? Data(page.body.utf8)
        var headers = page.headers
        if !headers.keys.contains(where: { $0.lowercased() == "cache-control" }) { headers["Cache-Control"] = "no-store" }
        if !headers.keys.contains(where: { $0.lowercased() == "content-type" }) { headers["Content-Type"] = "text/html; charset=utf-8" }
        let extra = headers.map { "\($0.key): \($0.value)\r\n" }.sorted().joined()
        let head = "HTTP/1.1 \(page.status)\r\n\(extra)"
            + "Content-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func stream(_ page: Page, _ chunks: [(data: Data, after: TimeInterval)], on connection: NWConnection) {
        var headers = page.headers
        headers["Cache-Control"] = "no-store"
        if !headers.keys.contains(where: { $0.lowercased() == "content-type" }) { headers["Content-Type"] = "text/event-stream" }
        let extra = headers.map { "\($0.key): \($0.value)\r\n" }.sorted().joined()
        let head = "HTTP/1.1 \(page.status)\r\n\(extra)Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        var rest = chunks[...]
        var ended = false
        func end(_ how: String) {
            guard !ended else { return }
            ended = true
            page.onStreamEnd?(how)
        }
        func next() {
            guard let c = rest.popFirst() else {
                if page.dropAtEnd { end("dropped"); return connection.forceCancel() }
                return connection.send(content: Data("0\r\n\r\n".utf8), completion: .contentProcessed { _ in end("complete"); connection.cancel() })
            }
            queue.asyncAfter(deadline: .now() + c.after) {
                let framed = Data(String(c.data.count, radix: 16).utf8) + Data("\r\n".utf8) + c.data + Data("\r\n".utf8)
                connection.send(content: framed, completion: .contentProcessed { error in
                    if error != nil { end("client closed"); return connection.cancel() }
                    next()
                })
            }
        }
        // A client that goes away mid-stream is seen at once, not only at the next send.
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: if !rest.isEmpty || !ended { end("client closed") }
            default: break
            }
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, complete, error in
            if complete || error != nil { end("client closed"); connection.cancel() }
        }
        connection.send(content: Data(head.utf8), completion: .contentProcessed { error in
            if error != nil { end("client closed"); return connection.cancel() }
            next()
        })
    }
}
#endif
