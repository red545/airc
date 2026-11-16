// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

final class AgentConversationTests: XCTestCase {
    private let tools = [AgentToolSpec(name: "navigate", description: "Loads an address.",
                                       schema: ["type": "object", "properties": ["url": ["type": "string"]], "required": ["url"]])]

    private func json(_ s: String) -> Data { Data(s.utf8) }

    func testStrippingWindow() {
        let s = AgentToolSpec.strippingWindow(["type": "object", "properties": ["url": ["type": "string"], "window": ["type": "integer"]],
                                               "required": ["url", "window"]])
        XCTAssertNil((s["properties"] as? [String: Any])?["window"])
        XCTAssertEqual(s["required"] as? [String], ["url"])
    }

    func testAnthropicRequestAndLoop() throws {
        let c = AgentConversation(provider: .anthropic)
        c.addUser("Read example.com")
        let model = AgentModel.find("claude-opus-5-5")!
        let body = c.requestBody(model: model, system: "sys", tools: tools, effort: "medium")
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "medium")
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        XCTAssertNil(body["thinking"])
        XCTAssertNil(body["temperature"])
        XCTAssertEqual(((body["tools"] as? [[String: Any]])?.first?["input_schema"] as? [String: Any])?["type"] as? String, "object")
        XCTAssertEqual(c.headers(model: model)["anthropic-version"], "2026-10-21")
        XCTAssertEqual(c.headers(model: model)["anthropic-beta"], "server-side-fallback-2026-07-01")
        XCTAssertNil(c.headers(model: AgentModel.find("claude-haiku-5-5")!)["anthropic-beta"])

        let turn = try c.absorb(json("""
            {"content":[{"type":"thinking","thinking":"","signature":"sig"},{"type":"text","text":"Opening it."},
             {"type":"tool_use","id":"toolu_1","name":"navigate","input":{"url":"https://example.com"}}],
             "stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":7}}
            """))
        XCTAssertEqual(turn.stop, .toolUse)
        XCTAssertEqual(turn.text, "Opening it.")
        XCTAssertEqual(turn.calls.first?.name, "navigate")
        XCTAssertEqual(turn.calls.first?.input["url"] as? String, "https://example.com")
        XCTAssertEqual(turn.usage, AgentUsage(input: 10, output: 5, cacheRead: 100, cacheWrite: 7))
        // The thinking block goes back verbatim.
        let assistant = c.items[1]["content"] as? [[String: Any]]
        XCTAssertEqual(assistant?.first?["signature"] as? String, "sig")

        c.addToolResults([AgentToolOutput(callID: "toolu_1", texts: ["loaded"], images: ["AAAA"])], note: "Warning")
        let results = c.items[2]["content"] as? [[String: Any]]
        XCTAssertEqual(results?.first?["tool_use_id"] as? String, "toolu_1")
        XCTAssertEqual((results?.first?["content"] as? [[String: Any]])?.last?["type"] as? String, "image")
        XCTAssertEqual(results?.last?["text"] as? String, "Warning")

        let done = try c.absorb(json(#"{"content":[{"type":"text","text":"Done."}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}"#))
        XCTAssertEqual(done.stop, .done)
        let refusal = try c.absorb(json(#"{"content":[],"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber","explanation":"no"}}"#))
        XCTAssertEqual(refusal.stop, .refusal("no"))
        XCTAssertThrowsError(try c.absorb(json("nope")))
    }

    func testOpenAIRequestAndLoop() throws {
        let c = AgentConversation(provider: .openai)
        c.addUser("Read example.com")
        let model = AgentModel.find("gpt-6-astra")!
        let body = c.requestBody(model: model, system: "sys", tools: tools, effort: "high")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["instructions"] as? String, "sys")
        XCTAssertEqual(((body["tools"] as? [[String: Any]])?.first?["type"] as? String), "function")
        XCTAssertEqual(c.path, "/v1/responses")

        let turn = try c.absorb(json("""
            {"status":"completed","output":[{"type":"reasoning","id":"rs_1","encrypted_content":"enc","summary":[]},
             {"type":"function_call","id":"fc_1","call_id":"call_1","name":"navigate","arguments":"{\\"url\\":\\"https://example.com\\"}"}],
             "usage":{"input_tokens":50,"output_tokens":5,"input_tokens_details":{"cached_tokens":40}}}
            """))
        XCTAssertEqual(turn.stop, .toolUse)
        XCTAssertEqual(turn.calls.first?.id, "call_1")
        XCTAssertEqual(turn.usage, AgentUsage(input: 10, output: 5, cacheRead: 40))
        XCTAssertEqual(c.items.count, 3)
        XCTAssertEqual(c.items[1]["encrypted_content"] as? String, "enc")

        c.addToolResults([AgentToolOutput(callID: "call_1", texts: ["shot"], images: ["AAAA"]),
                          AgentToolOutput(callID: "call_2", texts: ["nope"], isError: true)])
        XCTAssertEqual(c.items[3]["type"] as? String, "function_call_output")
        XCTAssertEqual(((c.items[3]["output"] as? [[String: Any]])?.last?["image_url"] as? String), "data:image/png;base64,AAAA")
        XCTAssertEqual(c.items[4]["output"] as? String, "Error: nope")

        let bad = try c.absorb(json(#"{"status":"completed","output":[{"type":"function_call","call_id":"c","name":"navigate","arguments":"{oops"}]}"#))
        XCTAssertNotNil(bad.calls.first?.inputError)
        let done = try c.absorb(json(#"{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done."}]}]}"#))
        XCTAssertEqual(done.stop, .done)
        XCTAssertEqual(done.text, "Done.")
    }

    func testBudgets() {
        let q = AgentLevel.quick.budget
        XCTAssertNil(q.exceeded(steps: 3, elapsed: 10, usage: AgentUsage(input: 100)))
        XCTAssertEqual(q.exceeded(steps: 25, elapsed: 10, usage: AgentUsage()), "step limit (25 steps)")
        XCTAssertEqual(q.exceeded(steps: 1, elapsed: 181, usage: AgentUsage()), "time limit (3 min)")
        XCTAssertEqual(q.exceeded(steps: 1, elapsed: 1, usage: AgentUsage(input: 300_000)), "token limit (300k)")
        XCTAssertGreaterThan(AgentLevel.long.budget.steps, q.steps)
        XCTAssertEqual(AgentProvider.anthropic.defaultModel.id, "claude-opus-5-5")
        XCTAssertEqual(AgentModel.find("claude-opus-5-5")!.cost(AgentUsage(input: 1_000_000, output: 100_000)), 6, accuracy: 0.0001)
    }

    func testErrorMessageNeverEchoesHeaders() {
        XCTAssertEqual(AgentConversation.errorMessage(status: 401, body: Data()), "The key was refused (401). Check it in Settings › AI › Agent.")
        XCTAssertEqual(AgentConversation.errorMessage(status: 500, body: json(#"{"error":{"message":"boom"}}"#)), "The model answered 500: boom")
    }
}
