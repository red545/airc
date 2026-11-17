// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

final class AgentStreamTests: XCTestCase {
    private let navigate = AgentToolSpec(name: "navigate", description: "Loads an address.",
                                         schema: ["type": "object", "properties": ["url": ["type": "string"]], "required": ["url"]])
    private let click = AgentToolSpec(name: "left_click", description: "Clicks.",
                                      schema: ["type": "object", "properties": ["coordinate": ["type": "array"], "count": ["type": "integer"]],
                                               "required": ["coordinate"]])

    private func sse(_ events: [(String, String)]) -> Data {
        Data(events.map { "event: \($0.0)\ndata: \($0.1)\n\n" }.joined().utf8)
    }

    /// Feeds `data` in chunks of `size` bytes (events split mid-line, as the network does).
    private func run(_ a: AgentStreamAssembler, _ data: Data, chunk size: Int) -> [AgentStreamUpdate] {
        let p = AgentSSEParser()
        var out: [AgentStreamUpdate] = []
        var i = 0
        while i < data.count {
            let c = data.subdata(in: i..<min(data.count, i + size))
            for e in p.feed(c) { out += a.feed(e) }
            i += size
        }
        return out
    }

    func testParserJoinsDataLinesAndSkipsComments() {
        let p = AgentSSEParser()
        var e = p.feed(Data(": keepalive\r\nevent: a\r\ndata: one\r\ndata:two\r\n\r\nda".utf8))
        XCTAssertEqual(e, [AgentSSEParser.Event(name: "a", data: "one\ntwo")])
        e = p.feed(Data("ta: {}\n\n".utf8))
        XCTAssertEqual(e, [AgentSSEParser.Event(name: nil, data: "{}")])
    }

    private var anthropicToolTurn: Data {
        sse([
            ("message_start", #"{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5-5","content":[],"stop_reason":null,"usage":{"input_tokens":50,"cache_read_input_tokens":900,"output_tokens":1}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("ping", #"{"type":"ping"}"#),
            ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Opening "}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"it."}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
            ("content_block_start", #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"navigate","input":{}}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"url\": \"https://exa"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"mple.com/a\"}"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":2}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":42}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ])
    }

    func testAnthropicStreamRebuildsTheMessage() throws {
        for size in [1, 7, 64, 100_000] {
            let a = AgentStreamAssembler(provider: .anthropic)
            let updates = run(a, anthropicToolTurn, chunk: size)
            var text = ""
            var calls: [AgentToolCall] = []
            for u in updates {
                switch u {
                case .text(let t): text += t
                case .call(let c): calls.append(c)
                }
            }
            XCTAssertEqual(text, "Opening it.", "chunk \(size)")
            XCTAssertEqual(calls.map(\.name), ["navigate"])
            XCTAssertEqual(calls.first?.input["url"] as? String, "https://example.com/a")
            XCTAssertTrue(a.finished)
            let c = AgentConversation(provider: .anthropic)
            c.addUser("go")
            let turn = c.absorb(object: try XCTUnwrap(a.response), invalidInputs: a.invalidInputs)
            XCTAssertEqual(turn.stop, .toolUse)
            XCTAssertEqual(turn.text, "Opening it.")
            XCTAssertEqual(turn.usage.input, 50)
            XCTAssertEqual(turn.usage.output, 42)
            XCTAssertEqual(turn.usage.cacheRead, 900)
            // The history gets the blocks verbatim: thinking with its whole signature, in order.
            let content = try XCTUnwrap(c.items.last?["content"] as? [[String: Any]])
            XCTAssertEqual(content.map { $0["type"] as? String }, ["thinking", "text", "tool_use"])
            XCTAssertEqual(content[0]["signature"] as? String, "sig-abc")
            XCTAssertEqual((content[2]["input"] as? [String: Any])?["url"] as? String, "https://example.com/a")
        }
    }

    func testAnthropicDroppedStreamNeverFinishes() {
        let full = anthropicToolTurn
        // Cut inside the tool_use block's arguments.
        let cut = String(decoding: full, as: UTF8.self).range(of: "mple.com")!.lowerBound
        let a = AgentStreamAssembler(provider: .anthropic)
        let updates = run(a, Data(String(decoding: full, as: UTF8.self)[..<cut].utf8), chunk: 13)
        XCTAssertFalse(a.finished)
        XCTAssertNil(a.response)
        XCTAssertTrue(a.started)
        XCTAssertFalse(updates.contains { if case .call = $0 { return true } else { return false } }, "no call from a cut block")
    }

    func testAnthropicInvalidStreamedJSONIsAnErrorNotACall() throws {
        let data = sse([
            ("message_start", #"{"type":"message_start","message":{"id":"m","role":"assistant","content":[],"usage":{"input_tokens":1}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_9","name":"navigate","input":{}}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"url\": \"a\"b\"}"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":3}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ])
        let a = AgentStreamAssembler(provider: .anthropic)
        _ = run(a, data, chunk: 50)
        let c = AgentConversation(provider: .anthropic)
        c.addUser("go")
        let turn = c.absorb(object: try XCTUnwrap(a.response), invalidInputs: a.invalidInputs)
        XCTAssertEqual(turn.calls.count, 1)
        XCTAssertTrue(turn.calls[0].inputError?.contains("INVALID_JSON") == true)
        // The history still holds a valid object for the block.
        let content = try XCTUnwrap(c.items.last?["content"] as? [[String: Any]])
        XCTAssertNotNil(content[0]["input"] as? [String: Any])
    }

    func testAnthropicErrorEventFails() {
        let a = AgentStreamAssembler(provider: .anthropic)
        _ = run(a, sse([("error", #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)]), chunk: 9)
        XCTAssertTrue(a.finished)
        XCTAssertEqual(a.failure, "Overloaded")
        XCTAssertNil(a.response)
    }

    func testFallbackEchoDropsThinkingAndToolUseBeforeTheBoundary() {
        let content: [[String: Any]] = [
            ["type": "thinking", "thinking": "", "signature": "s1"], ["type": "text", "text": "Part"],
            ["type": "tool_use", "id": "t0", "name": "navigate", "input": [:]],
            ["type": "fallback", "model": "claude-opus-4-8"],
            ["type": "thinking", "thinking": "", "signature": "s2"], ["type": "tool_use", "id": "t1", "name": "navigate", "input": ["url": "x"]],
        ]
        let echo = AgentConversation.echoContent(content)
        XCTAssertEqual(echo.map { $0["type"] as? String }, ["text", "fallback", "thinking", "tool_use"])
        let c = AgentConversation(provider: .anthropic)
        c.addUser("go")
        let turn = c.absorb(object: ["content": content, "stop_reason": "tool_use"])
        XCTAssertEqual(turn.calls.map(\.id), ["t1"], "only calls after the fallback boundary run")
    }

    func testUserTurnAfterAStoppedStreamMerges() {
        let c = AgentConversation(provider: .anthropic)
        c.addUser("one")
        c.addUser("two")
        XCTAssertEqual(c.items.count, 1)
        XCTAssertEqual((c.items[0]["content"] as? [[String: Any]])?.count, 2)
    }

    func testStreamingRequestBody() {
        let c = AgentConversation(provider: .anthropic)
        c.addUser("go")
        let model = AgentModel.find("claude-opus-5-5")!
        let body = c.requestBody(model: model, system: "s", tools: [navigate], effort: "medium", stream: true)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["max_tokens"] as? Int, 64000)
        XCTAssertEqual((body["tools"] as? [[String: Any]])?.first?["eager_input_streaming"] as? Bool, true)
        let plain = c.requestBody(model: model, system: "s", tools: [navigate], effort: "medium")
        XCTAssertNil(plain["stream"])
        XCTAssertNil((plain["tools"] as? [[String: Any]])?.first?["eager_input_streaming"])
        XCTAssertEqual(plain["max_tokens"] as? Int, 16000)
        let o = AgentConversation(provider: .openai)
        o.addUser("go")
        let ob = o.requestBody(model: AgentModel.find("gpt-6-astra")!, system: "s", tools: [navigate], effort: "medium", stream: true)
        XCTAssertEqual(ob["stream"] as? Bool, true)
        XCTAssertEqual(ob["store"] as? Bool, false)
    }

    func testOpenAIStream() throws {
        let data = sse([
            ("response.created", #"{"type":"response.created","response":{"id":"resp_1","status":"in_progress","output":[]}}"#),
            ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning","id":"rs_1","summary":[]}}"#),
            ("response.output_item.done", #"{"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs_1","encrypted_content":"enc","summary":[]}}"#),
            ("response.output_item.added", #"{"type":"response.output_item.added","output_index":1,"item":{"type":"message","id":"m1","role":"assistant","content":[]}}"#),
            ("response.output_text.delta", #"{"type":"response.output_text.delta","item_id":"m1","output_index":1,"content_index":0,"delta":"Look"}"#),
            ("response.output_text.delta", #"{"type":"response.output_text.delta","item_id":"m1","output_index":1,"content_index":0,"delta":"ing."}"#),
            ("response.output_item.done", #"{"type":"response.output_item.done","output_index":1,"item":{"type":"message","id":"m1","role":"assistant","content":[{"type":"output_text","text":"Looking."}]}}"#),
            ("response.output_item.added", #"{"type":"response.output_item.added","output_index":2,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"left_click","arguments":""}}"#),
            ("response.function_call_arguments.delta", #"{"type":"response.function_call_arguments.delta","output_index":2,"delta":"{\"coordinate\":[1,"}"#),
            ("response.output_item.done", #"{"type":"response.output_item.done","output_index":2,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"left_click","arguments":"{\"coordinate\":[1,2]}"}}"#),
            ("response.completed", #"{"type":"response.completed","response":{"id":"resp_1","status":"completed","output":[],"usage":{"input_tokens":100,"output_tokens":9,"input_tokens_details":{"cached_tokens":60}}}}"#),
        ])
        let a = AgentStreamAssembler(provider: .openai)
        let updates = run(a, data, chunk: 17)
        let text = updates.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
        XCTAssertEqual(text, "Looking.")
        let calls = updates.compactMap { if case .call(let c) = $0 { return c } else { return nil } }
        XCTAssertEqual(calls.map(\.id), ["call_1"])
        let c = AgentConversation(provider: .openai)
        c.addUser("go")
        let turn = c.absorb(object: try XCTUnwrap(a.response))
        XCTAssertEqual(turn.stop, .toolUse)
        XCTAssertEqual(turn.usage.input, 40)
        XCTAssertEqual(turn.usage.cacheRead, 60)
        // The output items (reasoning included) go back verbatim, from the collected items.
        XCTAssertEqual(c.items.dropFirst().map { $0["type"] as? String }, ["reasoning", "message", "function_call"])
        XCTAssertEqual(c.items[1]["encrypted_content"] as? String, "enc")
    }

    func testOpenAIFailedResponse() {
        let a = AgentStreamAssembler(provider: .openai)
        _ = run(a, sse([("response.failed", #"{"type":"response.failed","response":{"status":"failed","error":{"code":"server_error","message":"Boom"}}}"#)]), chunk: 30)
        XCTAssertEqual(a.failure, "Boom")
    }

    func testSchemaProblems() {
        XCTAssertNil(navigate.problem(with: ["url": "https://example.com"]))
        XCTAssertNotNil(navigate.problem(with: [:]))
        XCTAssertNotNil(navigate.problem(with: ["url": 3]))
        XCTAssertNil(click.problem(with: ["coordinate": [1, 2], "count": 2]))
        XCTAssertNotNil(click.problem(with: ["coordinate": "1,2"]))
        XCTAssertNotNil(click.problem(with: ["coordinate": [1, 2], "count": 1.5]))
        XCTAssertNotNil(click.problem(with: ["coordinate": [1, 2], "count": true]))
    }
}
