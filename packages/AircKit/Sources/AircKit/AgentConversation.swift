// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

// The Airc Agent's conversation in each provider's wire format (docs/design/agent.md, "Bring your own model"):
// Anthropic's Messages API and OpenAI's Responses API. No networking here: the app sends `requestBody` and hands the
// answer to `absorb`. History is append-only and the model's own output goes back verbatim (Anthropic thinking blocks,
// OpenAI reasoning items), as both providers require for tool loops.

/// A tool as the model sees it.
public struct AgentToolSpec {
    public let name: String
    public let description: String
    public let schema: [String: Any]
    public init(name: String, description: String, schema: [String: Any]) {
        self.name = name
        self.description = description
        self.schema = schema
    }

    /// An MCP tool's schema without the `window` argument (a panel run has one window).
    public static func strippingWindow(_ schema: [String: Any]) -> [String: Any] {
        var s = schema
        if var props = s["properties"] as? [String: Any] {
            props["window"] = nil
            s["properties"] = props
        }
        if let req = s["required"] as? [String] { s["required"] = req.filter { $0 != "window" } }
        return s
    }
}

/// One tool call the model asked for.
public struct AgentToolCall {
    public let id: String
    public let name: String
    public let input: [String: Any]
    /// The arguments weren't a JSON object: don't run it, answer with this error.
    public let inputError: String?
}

/// A tool's answer for the model.
public struct AgentToolOutput {
    public let callID: String
    public var texts: [String]
    /// Base64 PNGs.
    public var images: [String]
    public var isError: Bool
    public init(callID: String, texts: [String], images: [String] = [], isError: Bool = false) {
        self.callID = callID
        self.texts = texts
        self.images = images
        self.isError = isError
    }
}

/// One model turn, parsed.
public struct AgentTurn {
    public enum Stop: Equatable { case done, toolUse, refusal(String), truncated, other(String) }
    public var text: String
    public var calls: [AgentToolCall]
    public var stop: Stop
    public var usage: AgentUsage
}

public enum AgentWireError: Error, Equatable {
    case notJSON
    case api(status: Int, message: String)
}

public final class AgentConversation {
    public let provider: AgentProvider
    /// Anthropic `messages` or OpenAI `input` items, in order.
    public private(set) var items: [[String: Any]] = []

    public init(provider: AgentProvider) { self.provider = provider }

    public func addUser(_ text: String) {
        switch provider {
        case .anthropic:
            // A stopped or dropped stream appends nothing, so the history can end in a user turn: add to it.
            if var last = items.last, last["role"] as? String == "user", var content = last["content"] as? [[String: Any]] {
                content.append(["type": "text", "text": text])
                last["content"] = content
                items[items.count - 1] = last
            } else {
                items.append(["role": "user", "content": [["type": "text", "text": text]]])
            }
        case .openai: items.append(["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]])
        }
    }

    /// The request body. `fallback`: Anthropic's server-side refusal fallback (needs the beta header from `headers`).
    /// `stream`: Server-Sent Events (AgentStream); Anthropic tools then stream their arguments eagerly (validated by
    /// Airc before a call runs) and the turn gets the streaming output cap.
    public func requestBody(model: AgentModel, system: String, tools: [AgentToolSpec], effort: String, maxTokens: Int? = nil,
                            stream: Bool = false) -> [String: Any] {
        switch provider {
        case .anthropic:
            var body: [String: Any] = [
                "model": model.id, "max_tokens": maxTokens ?? (stream ? 64000 : 16000),
                "system": [["type": "text", "text": system]],
                "tools": tools.map { t -> [String: Any] in
                    var d: [String: Any] = ["name": t.name, "description": t.description, "input_schema": t.schema]
                    if stream { d["eager_input_streaming"] = true }
                    return d
                },
                "messages": items,
                "output_config": ["effort": effort],
                // Stable tools + system first, so every turn reads the cache.
                "cache_control": ["type": "ephemeral"],
            ]
            if model.refusalFallback { body["fallbacks"] = "default" }
            if stream { body["stream"] = true }
            return body
        case .openai:
            var body: [String: Any] = [
                "model": model.id, "instructions": system, "input": items, "store": false,
                "include": ["reasoning.encrypted_content"], "reasoning": ["effort": effort], "max_output_tokens": maxTokens ?? 16000,
                "tools": tools.map { ["type": "function", "name": $0.name, "description": $0.description, "parameters": $0.schema, "strict": false] as [String: Any] },
            ]
            if stream { body["stream"] = true }
            return body
        }
    }

    /// HTTP headers besides the key's (the app adds that one).
    public func headers(model: AgentModel) -> [String: String] {
        switch provider {
        case .anthropic:
            var h = ["anthropic-version": "2026-10-21", "content-type": "application/json"]
            if model.refusalFallback { h["anthropic-beta"] = "server-side-fallback-2026-07-01" }
            return h
        case .openai:
            return ["content-type": "application/json"]
        }
    }

    public var path: String { provider == .anthropic ? "/v1/messages" : "/v1/responses" }

    /// An error answer's message, for the panel (never includes request headers).
    public static func errorMessage(status: Int, body: Data) -> String {
        let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let e = o?["error"] as? [String: Any]
        let m = (e?["message"] as? String) ?? String(decoding: body.prefix(300), as: UTF8.self)
        switch status {
        case 401: return "The key was refused (401). Check it in Settings › AI › Agent."
        case 403: return "Not allowed (403): \(m)"
        case 429: return "Rate limited (429): \(m)"
        default: return "The model answered \(status): \(m)"
        }
    }

    /// Parses a successful answer and appends the model's output to the history, verbatim.
    public func absorb(_ data: Data) throws -> AgentTurn {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw AgentWireError.notJSON }
        return absorb(object: o)
    }

    /// A parsed answer (a streamed turn's rebuilt response, AgentStreamAssembler). `invalidInputs`: tool calls whose
    /// streamed arguments weren't JSON; they are answered with an error instead of running.
    public func absorb(object o: [String: Any], invalidInputs: [String: String] = [:]) -> AgentTurn {
        switch provider {
        case .anthropic: return absorbAnthropic(o, invalidInputs)
        case .openai: return absorbOpenAI(o, invalidInputs)
        }
    }

    /// The content to echo back. After a mid-output refusal fallback, the thinking and tool_use blocks before the last
    /// `fallback` block are left out (the fallback block itself stays where it was), as the Messages API requires.
    public static func echoContent(_ content: [[String: Any]]) -> [[String: Any]] {
        guard let f = content.lastIndex(where: { $0["type"] as? String == "fallback" }) else { return content }
        let dropped: Set<String> = ["thinking", "redacted_thinking", "tool_use", "server_tool_use"]
        return content.enumerated().filter { i, b in i >= f || !dropped.contains(b["type"] as? String ?? "") }.map(\.element)
    }

    private func absorbAnthropic(_ o: [String: Any], _ invalid: [String: String]) -> AgentTurn {
        let content = Self.echoContent(o["content"] as? [[String: Any]] ?? [])
        items.append(["role": "assistant", "content": content])
        var text: [String] = []
        var calls: [AgentToolCall] = []
        for b in content {
            switch b["type"] as? String {
            case "text": if let t = b["text"] as? String { text.append(t) }
            case "tool_use":
                let input = b["input"] as? [String: Any]
                let id = b["id"] as? String ?? ""
                let error = invalid[id].map(AgentStreamAssembler.invalidJSON) ?? (input == nil ? "The arguments weren't a JSON object." : nil)
                calls.append(AgentToolCall(id: id, name: b["name"] as? String ?? "", input: input ?? [:], inputError: error))
            default: break
            }
        }
        let u = o["usage"] as? [String: Any] ?? [:]
        let usage = AgentUsage(input: u["input_tokens"] as? Int ?? 0, output: u["output_tokens"] as? Int ?? 0,
                               cacheRead: u["cache_read_input_tokens"] as? Int ?? 0, cacheWrite: u["cache_creation_input_tokens"] as? Int ?? 0)
        let stop: AgentTurn.Stop
        switch o["stop_reason"] as? String {
        case "tool_use": stop = calls.isEmpty ? .other("tool_use") : .toolUse
        case "end_turn", "stop_sequence": stop = .done
        case "max_tokens", "model_context_window_exceeded": stop = .truncated
        case "refusal":
            let d = o["stop_details"] as? [String: Any]
            stop = .refusal((d?["explanation"] as? String) ?? (d?["category"] as? String) ?? "")
        case let s?: stop = calls.isEmpty ? .other(s) : .toolUse
        case nil: stop = .other("none")
        }
        return AgentTurn(text: text.joined(separator: "\n"), calls: calls, stop: stop, usage: usage)
    }

    private func absorbOpenAI(_ o: [String: Any], _ invalid: [String: String]) -> AgentTurn {
        let output = o["output"] as? [[String: Any]] ?? []
        items += output
        var text: [String] = []
        var calls: [AgentToolCall] = []
        var refusal: String?
        for item in output {
            switch item["type"] as? String {
            case "message":
                for part in item["content"] as? [[String: Any]] ?? [] {
                    if part["type"] as? String == "output_text", let t = part["text"] as? String { text.append(t) }
                    if part["type"] as? String == "refusal" { refusal = part["refusal"] as? String ?? "" }
                }
            case "function_call":
                let raw = item["arguments"] as? String ?? ""
                let input = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
                calls.append(AgentToolCall(id: item["call_id"] as? String ?? "", name: item["name"] as? String ?? "", input: input ?? [:],
                                           inputError: input == nil ? "The arguments weren't a JSON object: \(raw.prefix(200))" : nil))
            default: break
            }
        }
        let u = o["usage"] as? [String: Any] ?? [:]
        let cached = (u["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
        let usage = AgentUsage(input: (u["input_tokens"] as? Int ?? 0) - cached, output: u["output_tokens"] as? Int ?? 0, cacheRead: cached)
        let stop: AgentTurn.Stop
        if let refusal { stop = .refusal(refusal) }
        else if o["status"] as? String == "incomplete" { stop = .truncated }
        else if !calls.isEmpty { stop = .toolUse }
        else if o["status"] as? String == "completed" || o["status"] == nil { stop = .done }
        else { stop = .other(o["status"] as? String ?? "?") }
        return AgentTurn(text: text.joined(separator: "\n"), calls: calls, stop: stop, usage: usage)
    }

    /// The answers to one turn's calls, all in one message (Anthropic) or one item each (OpenAI). `note`: Airc's own
    /// words to the model after them (a prompt-injection warning, a budget note).
    public func addToolResults(_ outputs: [AgentToolOutput], note: String? = nil) {
        switch provider {
        case .anthropic:
            var content: [[String: Any]] = outputs.map { out in
                var parts: [[String: Any]] = out.texts.map { ["type": "text", "text": $0] }
                parts += out.images.map { ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": $0]] }
                if parts.isEmpty { parts = [["type": "text", "text": "OK"]] }
                var r: [String: Any] = ["type": "tool_result", "tool_use_id": out.callID, "content": parts]
                if out.isError { r["is_error"] = true }
                return r
            }
            if let note { content.append(["type": "text", "text": note]) }
            items.append(["role": "user", "content": content])
        case .openai:
            for out in outputs {
                let text = out.texts.joined(separator: "\n")
                let body = out.isError ? "Error: " + text : (text.isEmpty ? "OK" : text)
                if out.images.isEmpty {
                    items.append(["type": "function_call_output", "call_id": out.callID, "output": body])
                } else {
                    var parts: [[String: Any]] = [["type": "input_text", "text": body]]
                    parts += out.images.map { ["type": "input_image", "image_url": "data:image/png;base64," + $0] }
                    items.append(["type": "function_call_output", "call_id": out.callID, "output": parts])
                }
            }
            if let note { items.append(["type": "message", "role": "user", "content": [["type": "input_text", "text": note]]]) }
        }
    }
}
