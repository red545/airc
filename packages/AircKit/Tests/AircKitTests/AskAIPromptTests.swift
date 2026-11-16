// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// askai: the Command Bar's "Ask Claude/ChatGPT" row for what reads as a prompt, its addresses, and Settings → AI's
/// Automatic choice.
final class AskAIPromptTests: XCTestCase {
    func testQuestionsArePrompts() {
        for t in ["why is the sky blue", "monads?", "what's a monad", "how do I undo a git rebase",
                  "is example.com down for everyone?", "Can you explain closures", "  why  ", "two words?"] where t != "  why  " {
            XCTAssertTrue(AskAIProvider.looksLikePrompt(t), t)
        }
        XCTAssertFalse(AskAIProvider.looksLikePrompt("  why  "), "one word, no question mark")
    }

    func testInstructionsAndLongPhrasesArePrompts() {
        XCTAssertTrue(AskAIProvider.looksLikePrompt("explain monads"))
        XCTAssertTrue(AskAIProvider.looksLikePrompt("Write a haiku about Lisbon trams"))
        XCTAssertTrue(AskAIProvider.looksLikePrompt("summarize the plot of dune part two"))
        XCTAssertTrue(AskAIProvider.looksLikePrompt("a short poem for my sister's birthday please"))
        XCTAssertTrue(AskAIProvider.looksLikePrompt("translate good morning\ninto German"))
    }

    func testSearchesAreNotPrompts() {
        for t in ["weather", "lisbon", "new york weather", "swift concurrency", "best pizza nearby", "", "   ", "\n"] {
            XCTAssertFalse(AskAIProvider.looksLikePrompt(t), t)
        }
    }

    func testAddressesAndHostsWithWordsAreNotPrompts() {
        for t in ["github.com/apple/swift", "https://example.com/a b", "example.com docs", "example.com docs and more words here",
                  "localhost:3000 test page", "example.com?", "http://example.com/?q=why is it"] {
            XCTAssertFalse(AskAIProvider.looksLikePrompt(t), t)
        }
        // A dotted word that isn't an address doesn't stop a prompt.
        XCTAssertTrue(AskAIProvider.looksLikePrompt("what does e.g. mean"))
    }

    func testCommandsAndBangsAreNotPrompts() {
        for t in ["/new split view", "/", "!yt cats and dogs playing", "why do cats purr !yt", "!g how do magnets work?"] {
            XCTAssertFalse(AskAIProvider.looksLikePrompt(t), t)
        }
        // A "!" that isn't a bang is just punctuation.
        XCTAssertTrue(AskAIProvider.looksLikePrompt("how do I type ! on a German keyboard"))
        XCTAssertTrue(AskAIProvider.looksLikePrompt("why is this so slow !!"))
    }

    func testNonEnglishText() {
        XCTAssertTrue(AskAIProvider.looksLikePrompt("Wie funktioniert ein Kühlschrank"))
        XCTAssertTrue(AskAIProvider.looksLikePrompt("erkläre mir Monaden"))
        XCTAssertTrue(AskAIProvider.looksLikePrompt("pourquoi le ciel est bleu"))
        XCTAssertTrue(AskAIProvider.looksLikePrompt("¿qué hora es en Lisboa"))
        XCTAssertTrue(AskAIProvider.looksLikePrompt("東京の天気は？"))
        XCTAssertTrue(AskAIProvider.looksLikePrompt("東京の天気を教えてください"))
        XCTAssertTrue(AskAIProvider.looksLikePrompt("Как работает холодильник ночью зимой"))
        XCTAssertFalse(AskAIProvider.looksLikePrompt("東京"))
        XCTAssertFalse(AskAIProvider.looksLikePrompt("Wetter Wien"))
        XCTAssertFalse(AskAIProvider.looksLikePrompt("Kühlschrank"))
    }

    func testSuggestsAskingFollowsTheClassifier() {
        for t in ["why is the sky blue", "weather", "github.com/apple/swift", "/new split view", "!yt cats"] {
            XCTAssertEqual(AskAIProvider.suggestsAsking(t), AskAIProvider.looksLikePrompt(t), t)
        }
    }

    func testNewChatAddressesCarryThePrompt() {
        XCTAssertEqual(AskAIProvider.claude.url(for: "why is the sky blue?")?.absoluteString,
                       "https://claude.ai/new?q=why%20is%20the%20sky%20blue%3F")
        XCTAssertEqual(AskAIProvider.chatGPT.url(for: "line one\nline two")?.absoluteString, "https://chatgpt.com/?q=line%20one%20line%20two")
        // Decodes back to the prompt.
        let prompt = "what's 1+1 & why? 50% off / a=b #2 東京 ¿qué?"
        for p in [AskAIProvider.chatGPT, .claude] {
            let url = p.url(for: prompt)
            XCTAssertEqual(url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == "q" }?.value,
                           prompt, p.name)
        }
    }

    func testOwnsHosts() {
        XCTAssertTrue(AskAIProvider.claude.owns("https://claude.ai/new"))
        XCTAssertTrue(AskAIProvider.claude.owns("https://Claude.AI/chat/1"))
        XCTAssertTrue(AskAIProvider.chatGPT.owns("https://chatgpt.com/"))
        XCTAssertTrue(AskAIProvider.chatGPT.owns("https://chat.openai.com/c/1"))
        XCTAssertTrue(AskAIProvider.perplexity.owns("https://www.perplexity.ai/search?q=x"))
        XCTAssertFalse(AskAIProvider.claude.owns("https://notclaude.ai/"))
        XCTAssertFalse(AskAIProvider.claude.owns("https://example.com/?u=https://claude.ai/"))
        XCTAssertFalse(AskAIProvider.chatGPT.owns("chatgpt.com"))
    }

    private func visit(_ url: String, daysAgo: Double, now: Date) -> HistoryEntry {
        HistoryEntry(profileID: "p", url: url, title: "", visitCount: 1, typedCount: 0, lastVisit: now.addingTimeInterval(-daysAgo * 86_400))
    }

    func testAutomaticChoice() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        // Nothing: off.
        XCTAssertNil(AskAIProvider.automatic(pinned: [], history: [visit("https://example.com/", daysAgo: 1, now: now)], now: now))
        // Recent history: the latest.
        XCTAssertEqual(AskAIProvider.automatic(pinned: [], history: [visit("https://chatgpt.com/c/1", daysAgo: 3, now: now),
                                                                    visit("https://claude.ai/chat/2", daysAgo: 1, now: now)], now: now), .claude)
        // Too old doesn't count.
        XCTAssertNil(AskAIProvider.automatic(pinned: [], history: [visit("https://claude.ai/", daysAgo: 120, now: now)], now: now))
        // A pinned tab or Favorite beats newer history elsewhere.
        XCTAssertEqual(AskAIProvider.automatic(pinned: ["https://example.com/", "https://chatgpt.com/"],
                                               history: [visit("https://claude.ai/new", daysAgo: 0, now: now)], now: now), .chatGPT)
        // Both pinned: the one visited last; neither visited: ChatGPT first.
        XCTAssertEqual(AskAIProvider.automatic(pinned: ["https://chatgpt.com/", "https://claude.ai/"],
                                               history: [visit("https://claude.ai/new", daysAgo: 2, now: now)], now: now), .claude)
        XCTAssertEqual(AskAIProvider.automatic(pinned: ["https://claude.ai/", "https://chatgpt.com/"], history: [HistoryEntry](), now: now), .chatGPT)
    }

    func testSettingsChoices() throws {
        var s = AskAISettings()
        XCTAssertEqual(s.choice(for: "p"), .automatic)
        XCTAssertEqual(s.resolved(for: "p") { .claude }, .claude)
        s.set(.off, for: "p")
        XCTAssertEqual(s.choice(for: "p"), .off)
        XCTAssertNil(s.resolved(for: "p") { XCTFail("Automatic isn't asked when off"); return .claude })
        s.set(.chatGPT, for: "p")
        XCTAssertEqual(s.choice(for: "p"), .provider(.chatGPT))
        XCTAssertEqual(s.resolved(for: "p") { .claude }, .chatGPT)
        s.set(nil, for: "q")
        XCTAssertEqual(s.choice(for: "q"), .off)
        s.set(.automatic, for: "q")
        XCTAssertEqual(s.choice(for: "q"), .automatic)
        s.set(.off, for: "gone")
        s.prune(keeping: ["p", "q"])
        XCTAssertEqual(s.choice(for: "gone"), .automatic)

        // Kept across a save; off survives; a provider from a newer build reads as off.
        s.set(.off, for: "q")
        let back = try JSONDecoder().decode(AskAISettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        let newer = try JSONDecoder().decode(AskAISettings.self, from: Data(#"{"profiles":{"a":"claude","b":"gemini"}}"#.utf8))
        XCTAssertEqual(newer.choice(for: "a"), .provider(.claude))
        XCTAssertEqual(newer.choice(for: "b"), .off)
        XCTAssertEqual(newer.choice(for: "c"), .automatic)
    }
}
