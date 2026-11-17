// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
import AircKit

/// One model turn over HTTPS with the person's own key (docs/design/agent.md, "Bring your own model", "Streaming"). The
/// key goes only into this request's header: never into a log, an error message, the transcript or a tool result.
/// Turns stream (Server-Sent Events): text reaches the panel as it arrives, each tool call as soon as its block is
/// complete, and `cancel()` closes the connection at once.
final class AgentModelClient: NSObject, URLSessionDataDelegate {
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var current: Stream?

    /// One request's state, on the main queue (the session's delegate queue).
    private final class Stream {
        let conversation: AgentConversation
        let provider: AgentProvider
        let parser = AgentSSEParser()
        let assembler: AgentStreamAssembler
        var status = 0
        var errorBody = Data()
        let onText: (String) -> Void
        let onCall: (AgentToolCall) -> Void
        let done: (Result<AgentTurn, AgentModelError>) -> Void
        var answered = false
        init(_ c: AgentConversation, onText: @escaping (String) -> Void, onCall: @escaping (AgentToolCall) -> Void,
             done: @escaping (Result<AgentTurn, AgentModelError>) -> Void) {
            conversation = c
            provider = c.provider
            assembler = AgentStreamAssembler(provider: c.provider)
            self.onText = onText
            self.onCall = onCall
            self.done = done
        }
        func finish(_ r: Result<AgentTurn, AgentModelError>) {
            guard !answered else { return }
            answered = true
            done(r)
        }
    }

    override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        // Idle time between bytes; streams send pings, so a silent connection for this long is dead.
        config.timeoutIntervalForRequest = 300
        config.httpCookieStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    /// Streams the conversation's next turn. `onText`/`onCall` and then `done` (once) on the main thread; a turn that
    /// ends early (the connection dropped, an error event) is `.failure` with `dropped` and is NOT in the history.
    func send(_ conversation: AgentConversation, model: AgentModel, key: String, base: URL, system: String, tools: [AgentToolSpec],
              effort: String, onText: @escaping (String) -> Void = { _ in }, onCall: @escaping (AgentToolCall) -> Void = { _ in },
              _ done: @escaping (Result<AgentTurn, AgentModelError>) -> Void) {
        let body = conversation.requestBody(model: model, system: system, tools: tools, effort: effort, stream: true)
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let url = URL(string: conversation.path, relativeTo: base) else { return done(.failure(AgentModelError("Couldn't build the request."))) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        for (k, v) in conversation.headers(model: model) { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        switch model.provider {
        case .anthropic: request.setValue(key, forHTTPHeaderField: "x-api-key")
        case .openai: request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        }
        cancel()
        let s = Stream(conversation, onText: onText, onCall: onCall, done: done)
        current = s
        let t = session.dataTask(with: request)
        task = t
        t.resume()
    }

    /// Stop: the connection closes now; the turn's `done` says cancelled.
    func cancel() {
        guard let s = current else { return }
        current = nil
        task?.cancel()
        task = nil
        s.finish(.failure(AgentModelError("Stopped.", cancelled: true)))
    }

    // MARK: URLSessionDataDelegate (main queue)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard dataTask === task, let s = current else { return completionHandler(.cancel) }
        s.status = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === task, let s = current else { return }
        guard (200..<300).contains(s.status) else {
            if s.errorBody.count < 64 << 10 { s.errorBody.append(data) }
            return
        }
        for e in s.parser.feed(data) {
            for u in s.assembler.feed(e) {
                guard current === s else { return }   // stopped from a callback
                switch u {
                case .text(let t): s.onText(t)
                case .call(let c): s.onCall(c)
                }
            }
            if s.assembler.finished { return complete(s) }
        }
    }

    func urlSession(_ session: URLSession, task t: URLSessionTask, didCompleteWithError error: Error?) {
        guard t === task, let s = current else { return }
        let name = s.provider.name
        if !(200..<300).contains(s.status) && s.status != 0 {
            current = nil
            task = nil
            return s.finish(.failure(AgentModelError(AgentConversation.errorMessage(status: s.status, body: s.errorBody))))
        }
        if s.assembler.finished { return complete(s) }
        current = nil
        task = nil
        if let e = error as NSError? {
            if e.code == NSURLErrorCancelled { return s.finish(.failure(AgentModelError("Stopped.", cancelled: true))) }
            if !s.assembler.started { return s.finish(.failure(AgentModelError("Couldn't reach \(name): \(e.localizedDescription)", dropped: true))) }
        }
        // The stream ended before the turn did (a dropped connection, a proxy cutting it).
        s.finish(.failure(AgentModelError("The connection to \(name) dropped mid-answer.", dropped: true)))
    }

    private func complete(_ s: Stream) {
        guard current === s else { return }
        current = nil
        task?.cancel()
        task = nil
        if let f = s.assembler.failure {
            return s.finish(.failure(AgentModelError("\(s.provider.name) stopped the answer: \(f)", dropped: true)))
        }
        guard let r = s.assembler.response else { return s.finish(.failure(AgentModelError("\(s.provider.name) answered something Airc couldn't read."))) }
        s.finish(.success(s.conversation.absorb(object: r, invalidInputs: s.assembler.invalidInputs)))
    }
}

struct AgentModelError: Error {
    let message: String
    var cancelled = false
    /// The turn didn't arrive whole (a dropped stream, a stream error event): nothing was added to the history, so
    /// sending the same request again is safe.
    var dropped = false
    init(_ message: String, cancelled: Bool = false, dropped: Bool = false) {
        self.message = message
        self.cancelled = cancelled
        self.dropped = dropped
    }
}
