// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
import AircKit

/// One model turn over HTTPS with the person's own key (docs/design/agent.md, "Bring your own model"). The key goes
/// only into this request's header: never into a log, an error message, the transcript or a tool result.
final class AgentModelClient {
    private let session: URLSession
    private var task: URLSessionDataTask?

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300
        config.httpCookieStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    /// Sends the conversation's next request; `done` on the main thread with the parsed turn or a message for the panel.
    func send(_ conversation: AgentConversation, model: AgentModel, key: String, base: URL, system: String, tools: [AgentToolSpec],
              effort: String, _ done: @escaping (Result<AgentTurn, AgentModelError>) -> Void) {
        let body = conversation.requestBody(model: model, system: system, tools: tools, effort: effort)
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let url = URL(string: conversation.path, relativeTo: base) else { return done(.failure(AgentModelError("Couldn't build the request."))) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        for (k, v) in conversation.headers(model: model) { request.setValue(v, forHTTPHeaderField: k) }
        switch model.provider {
        case .anthropic: request.setValue(key, forHTTPHeaderField: "x-api-key")
        case .openai: request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        }
        let t = session.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let e = error as NSError? {
                    if e.code == NSURLErrorCancelled { return done(.failure(AgentModelError("Stopped.", cancelled: true))) }
                    return done(.failure(AgentModelError("Couldn't reach \(model.provider.name): \(e.localizedDescription)")))
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard let data, (200..<300).contains(status) else {
                    return done(.failure(AgentModelError(AgentConversation.errorMessage(status: status, body: data ?? Data()))))
                }
                do { done(.success(try conversation.absorb(data))) }
                catch { done(.failure(AgentModelError("\(model.provider.name) answered something Airc couldn't read."))) }
            }
        }
        task = t
        t.resume()
    }

    func cancel() { task?.cancel() }
}

struct AgentModelError: Error {
    let message: String
    var cancelled = false
    init(_ message: String, cancelled: Bool = false) { self.message = message; self.cancelled = cancelled }
}
