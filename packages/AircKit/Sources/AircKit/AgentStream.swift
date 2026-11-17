// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

// Streaming for the Airc Agent (docs/design/agent.md, "Streaming"): Server-Sent Events from Anthropic's Messages API
// (`stream: true`) and OpenAI's Responses API (`stream: true`), turned into (1) live events for the panel (text as it
// arrives, each tool call as soon as its block is complete) and (2) the same full response object the non-streaming
// API returns, which `AgentConversation.absorb(object:)` appends to the history verbatim. No networking here.

/// Splits a byte stream into SSE events. Feed it chunks in order; it keeps a partial line between chunks.
public final class AgentSSEParser {
    public struct Event: Equatable {
        public var name: String?
        public var data: String
    }

    private var buffer = Data()
    private var name: String?
    private var data: [String] = []

    public init() {}

    public func feed(_ chunk: Data) -> [Event] {
        buffer.append(chunk)
        var out: [Event] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<nl]
            if line.last == 0x0D { line = line.dropLast() }
            buffer.removeSubrange(buffer.startIndex...nl)
            let s = String(decoding: line, as: UTF8.self)
            if s.isEmpty {
                if !data.isEmpty || name != nil { out.append(Event(name: name, data: data.joined(separator: "\n"))) }
                name = nil
                data = []
            } else if s.hasPrefix(":") {
                continue
            } else if s.hasPrefix("event:") {
                name = s.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if s.hasPrefix("data:") {
                var v = s.dropFirst(5)
                if v.first == " " { v = v.dropFirst() }
                data.append(String(v))
            }
        }
        return out
    }
}

/// What the panel sees while a turn streams.
public enum AgentStreamUpdate {
    /// More of the model's visible answer.
    case text(String)
    /// A tool call whose arguments are complete (its block ended). The turn may still end in a refusal or a cut-off,
    /// so only side-effect-free tools may run before the turn ends.
    case call(AgentToolCall)
}

/// Rebuilds one streamed turn. `feed` every SSE event; once `finished`, `response` is the full answer object.
public final class AgentStreamAssembler {
    public let provider: AgentProvider
    public private(set) var finished = false
    /// The provider sent an error event, or a `response.failed`: the turn can't be used.
    public private(set) var failure: String?
    /// The full non-streaming-shaped answer, once finished.
    public private(set) var response: [String: Any]?
    /// Tool calls whose streamed arguments weren't valid JSON (tool_use id → the raw text): never run, answered with
    /// an INVALID_JSON error.
    public private(set) var invalidInputs: [String: String] = [:]
    /// Any event arrived (the provider was reached).
    public private(set) var started = false

    // Anthropic
    private var message: [String: Any] = [:]
    private var blocks: [Int: [String: Any]] = [:]
    private var partialJSON: [Int: String] = [:]
    private var usage: [String: Any] = [:]
    // OpenAI
    private var items: [Int: [String: Any]] = [:]

    public init(provider: AgentProvider) { self.provider = provider }

    public func feed(_ e: AgentSSEParser.Event) -> [AgentStreamUpdate] {
        guard !finished, e.data != "[DONE]" else { return [] }
        guard let o = (try? JSONSerialization.jsonObject(with: Data(e.data.utf8))) as? [String: Any] else { return [] }
        started = true
        let type = (o["type"] as? String) ?? e.name ?? ""
        switch provider {
        case .anthropic: return anthropic(type, o)
        case .openai: return openai(type, o)
        }
    }

    // MARK: Anthropic Messages API

    private func anthropic(_ type: String, _ o: [String: Any]) -> [AgentStreamUpdate] {
        switch type {
        case "message_start":
            message = o["message"] as? [String: Any] ?? [:]
            usage = message["usage"] as? [String: Any] ?? [:]
        case "content_block_start":
            guard let i = o["index"] as? Int, var b = o["content_block"] as? [String: Any] else { break }
            if b["type"] as? String == "tool_use" || b["type"] as? String == "server_tool_use" { partialJSON[i] = "" }
            if b["type"] as? String == "tool_use" { b["input"] = [String: Any]() }
            blocks[i] = b
        case "content_block_delta":
            guard let i = o["index"] as? Int, var b = blocks[i], let d = o["delta"] as? [String: Any] else { break }
            switch d["type"] as? String {
            case "text_delta":
                let t = d["text"] as? String ?? ""
                b["text"] = (b["text"] as? String ?? "") + t
                blocks[i] = b
                return t.isEmpty ? [] : [.text(t)]
            case "thinking_delta": b["thinking"] = (b["thinking"] as? String ?? "") + (d["thinking"] as? String ?? "")
            case "signature_delta": b["signature"] = (b["signature"] as? String ?? "") + (d["signature"] as? String ?? "")
            case "input_json_delta": partialJSON[i, default: ""] += d["partial_json"] as? String ?? ""
            case "citations_delta":
                if let c = d["citation"] { b["citations"] = (b["citations"] as? [Any] ?? []) + [c] }
            default: break
            }
            blocks[i] = b
        case "content_block_stop":
            guard let i = o["index"] as? Int, var b = blocks[i] else { break }
            guard let raw = partialJSON.removeValue(forKey: i) else { break }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Strict parse (eager input streaming means the API didn't validate it).
            let parsed = trimmed.isEmpty ? [String: Any]() : (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any]
            b["input"] = parsed ?? [String: Any]()
            blocks[i] = b
            guard b["type"] as? String == "tool_use" else { break }
            let id = b["id"] as? String ?? ""
            if parsed == nil { invalidInputs[id] = raw }
            return [.call(AgentToolCall(id: id, name: b["name"] as? String ?? "", input: parsed ?? [:],
                                        inputError: parsed == nil ? Self.invalidJSON(raw) : nil))]
        case "message_delta":
            if let d = o["delta"] as? [String: Any] {
                for (k, v) in d { message[k] = v }
            }
            if let u = o["usage"] as? [String: Any] { for (k, v) in u where !(v is NSNull) { usage[k] = v } }
        case "message_stop":
            message["content"] = blocks.keys.sorted().compactMap { blocks[$0] }
            message["usage"] = usage
            response = message
            finished = true
        case "error":
            let err = o["error"] as? [String: Any]
            failure = (err?["message"] as? String) ?? (err?["type"] as? String) ?? "stream error"
            finished = true
        default: break   // ping, unknown events
        }
        return []
    }

    // MARK: OpenAI Responses API

    private func openai(_ type: String, _ o: [String: Any]) -> [AgentStreamUpdate] {
        switch type {
        case "response.output_item.added":
            if let i = o["output_index"] as? Int, let item = o["item"] as? [String: Any] { items[i] = item }
        case "response.output_text.delta":
            let t = o["delta"] as? String ?? ""
            return t.isEmpty ? [] : [.text(t)]
        case "response.output_item.done":
            guard let i = o["output_index"] as? Int, let item = o["item"] as? [String: Any] else { break }
            items[i] = item
            guard item["type"] as? String == "function_call" else { break }
            let raw = item["arguments"] as? String ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let parsed = trimmed.isEmpty ? [String: Any]() : (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any]
            let id = item["call_id"] as? String ?? ""
            if parsed == nil { invalidInputs[id] = raw }
            return [.call(AgentToolCall(id: id, name: item["name"] as? String ?? "", input: parsed ?? [:],
                                        inputError: parsed == nil ? Self.invalidJSON(raw) : nil))]
        case "response.completed", "response.incomplete":
            var r = o["response"] as? [String: Any] ?? [:]
            // Some servers send the final object without its output; the items we collected are the same.
            if (r["output"] as? [Any] ?? []).isEmpty { r["output"] = items.keys.sorted().compactMap { items[$0] } }
            if r["status"] == nil { r["status"] = type == "response.completed" ? "completed" : "incomplete" }
            response = r
            finished = true
        case "response.failed":
            let r = o["response"] as? [String: Any]
            let err = r?["error"] as? [String: Any]
            failure = (err?["message"] as? String) ?? "the response failed"
            finished = true
        case "error":
            failure = (o["message"] as? String) ?? ((o["error"] as? [String: Any])?["message"] as? String) ?? "stream error"
            finished = true
        default: break
        }
        return []
    }

    /// The tool error for arguments that weren't JSON (the skill's INVALID_JSON shape), kept short.
    public static func invalidJSON(_ raw: String) -> String {
        let o = ["INVALID_JSON": String(raw.prefix(2000))]
        let d = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
        return String(decoding: d, as: UTF8.self)
    }
}

extension AgentToolSpec {
    /// Why `input` doesn't fit this tool's schema (a required argument missing, or a top-level type wrong), or nil.
    /// Streamed arguments aren't validated by the provider, so every call is checked before it runs.
    public func problem(with input: [String: Any]) -> String? {
        for r in schema["required"] as? [String] ?? [] where input[r] == nil {
            return "Missing required argument “\(r)” for \(name)."
        }
        let props = schema["properties"] as? [String: Any] ?? [:]
        for (k, v) in input {
            guard let p = props[k] as? [String: Any] else { continue }
            let types: [String]
            if let t = p["type"] as? String { types = [t] } else if let t = p["type"] as? [String] { types = t } else { continue }
            if !types.contains(where: { Self.matches(v, $0) }) {
                return "Argument “\(k)” of \(name) should be \(types.joined(separator: " or "))."
            }
        }
        return nil
    }

    private static func matches(_ v: Any, _ type: String) -> Bool {
        let n = v as? NSNumber
        let isBool = n.map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? (v is Bool)
        switch type {
        case "string": return v is String
        case "boolean": return isBool
        case "integer":
            guard let n, !isBool else { return false }
            return n.doubleValue.rounded() == n.doubleValue
        case "number": return n != nil && !isBool
        case "array": return v is [Any]
        case "object": return v is [String: Any]
        case "null": return v is NSNull
        default: return true
        }
    }
}
