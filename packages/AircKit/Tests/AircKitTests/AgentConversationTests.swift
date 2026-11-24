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

    func testImagePruningKeepsTheNewest() {
        for provider in AgentProvider.allCases {
            let c = AgentConversation(provider: provider)
            c.addUser("Find a flat")
            var pruned = 0
            for n in 0..<40 {
                let call: [String: Any] = provider == .anthropic
                    ? ["type": "tool_use", "id": "t\(n)", "name": "screenshot", "input": [String: Any]()]
                    : ["type": "function_call", "call_id": "t\(n)", "name": "screenshot", "arguments": "{}"]
                let answer: [String: Any] = provider == .anthropic ? ["content": [call], "stop_reason": "tool_use"] : ["status": "completed", "output": [call]]
                _ = c.absorb(object: answer)
                c.addToolResults([AgentToolOutput(callID: "t\(n)", texts: ["shot \(n)"], images: ["IMG\(n)"])])
                pruned += c.pruneImages(keep: 8)
                let body = String(describing: c.items)
                let left = body.components(separatedBy: "IMG").count - 1
                XCTAssertLessThanOrEqual(left, 16, "\(provider) at \(n): at most 2×keep screenshots")
                XCTAssertGreaterThanOrEqual(left, min(n + 1, 8), "\(provider) at \(n): the newest 8 stay")
                XCTAssertTrue(body.contains("IMG\(n)\""), "\(provider): the newest screenshot stays")
            }
            XCTAssertGreaterThan(pruned, 0, "\(provider): older screenshots go")
            XCTAssertTrue(String(describing: c.items).contains(AgentConversation.prunedImage))
            // Every tool result stays paired with its call (only the image parts change).
            XCTAssertTrue(String(describing: c.items).contains("shot 0"))
        }
    }

    func testOldLongResultsAreShortened() {
        let page = String(repeating: "Room: bright, quiet, wooden floors. ", count: 400)   // ~14k characters
        for provider in AgentProvider.allCases {
            let c = AgentConversation(provider: provider)
            c.addUser("Read the listings")
            for n in 0..<60 {
                let call: [String: Any] = provider == .anthropic
                    ? ["type": "tool_use", "id": "r\(n)", "name": "read_page", "input": [String: Any]()]
                    : ["type": "function_call", "call_id": "r\(n)", "name": "read_page", "arguments": "{}"]
                let answer: [String: Any] = provider == .anthropic ? ["content": [call], "stop_reason": "tool_use"] : ["status": "completed", "output": [call]]
                _ = c.absorb(object: answer)
                c.addToolResults([AgentToolOutput(callID: "r\(n)", texts: ["#\(n) " + page])])
                c.shortenOldResults()
            }
            let body = String(describing: c.items)
            let whole = body.components(separatedBy: page).count - 1
            XCTAssertGreaterThanOrEqual(whole, 12, "\(provider): the newest answers stay whole")
            XCTAssertLessThanOrEqual(whole, 24, "\(provider): at most 2×keep stay whole")
            XCTAssertTrue(body.contains("#0 Room"), "\(provider): an old answer keeps its start")
            XCTAssertTrue(body.contains("#59 " + page), "\(provider): the newest is whole")
            XCTAssertLessThan(body.count, 60 * page.count / 2, "\(provider): the history stays small")
        }
    }

    func testBudgets() {
        // No step limit by default, at either level (owner, 2026-11-23): only the person's own cap stops a task.
        for level in AgentLevel.allCases {
            let b = AgentBudget(level: level, stepCap: nil)
            XCTAssertNil(b.steps)
            XCTAssertNil(b.exceeded(steps: 25))
            XCTAssertNil(b.exceeded(steps: 100_000))
        }
        XCTAssertNil(AgentBudget(level: .quick, stepCap: 0).steps, "0 or less is off")
        XCTAssertEqual(AgentBudget(level: .quick, stepCap: nil).effort, "medium")
        XCTAssertEqual(AgentBudget(level: .long, stepCap: nil).effort, "high")
        let capped = AgentBudget(level: .quick, stepCap: 50)
        XCTAssertNil(capped.exceeded(steps: 49))
        XCTAssertEqual(capped.exceeded(steps: 50), "Stopped after 50 steps, the limit you set in Settings › AI › Agent. Continue gives it 50 more.")
        XCTAssertEqual(AgentBudget.capChoices.first!, nil, "Off is the first choice")
        XCTAssertEqual(AgentProvider.anthropic.defaultModel.id, "claude-opus-5-5")
        XCTAssertEqual(AgentModel.find("claude-opus-5-5")!.cost(AgentUsage(input: 1_000_000, output: 100_000)), 6, accuracy: 0.0001)
    }

    func testErrorMessageNeverEchoesHeaders() {
        XCTAssertEqual(AgentConversation.errorMessage(status: 401, body: Data()), "The key was refused (401). Check it in Settings › AI › Agent.")
        XCTAssertEqual(AgentConversation.errorMessage(status: 500, body: json(#"{"error":{"message":"boom"}}"#)), "The model answered 500: boom")
    }
}
