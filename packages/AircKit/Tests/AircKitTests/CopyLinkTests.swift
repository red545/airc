// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

final class CopyLinkTests: XCTestCase {
    func testMarkdownEscapesTitleAndDestination() {
        XCTAssertEqual(URLRules.markdownLink(title: "A [b] (c)\nnext", url: "https://example.com/a(b)"),
                       "[A \\[b\\] (c) next](https://example.com/a%28b%29)")
        XCTAssertEqual(URLRules.markdownLink(title: "Notes 3.5 - draft!", url: "https://example.com"),
                       "[Notes 3.5 - draft!](https://example.com)", "Plain punctuation stays readable")
    }
    func testQuotePreservesLinesAsLiteralText() {
        XCTAssertEqual(URLRules.markdownQuote(title: "[Title]", url: "https://example.com/(x)", selection: "[one] (two)\r\n\nlast"),
                       "> \\[one\\] (two)\n> \n> last\n\n[\\[Title\\]](https://example.com/%28x%29)")
        XCTAssertEqual(URLRules.markdownQuote(title: "T", url: "https://example.com", selection: "- item\n1. first\n# not a heading\nHello world. Fine."),
                       "> \\- item\n> 1\\. first\n> \\# not a heading\n> Hello world. Fine.\n\n[T](https://example.com)")
        XCTAssertEqual(URLRules.markdownQuote(title: "Title", url: "https://example.com", selection: " \n"),
                       "> Title\n\n[Title](https://example.com)")
    }
    func testHistoryRemovalIsProfileScopedAndPersistent() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("history.db").path
        let h = try HistoryStore(path: path)
        for p in ["one", "two"] { h.recordVisit(profileID: p, url: "https://example.com", title: "Example") }
        h.remove(profileID: "one", url: "https://example.com")
        XCTAssertNil(h.entry(profileID: "one", url: "https://example.com"))
        XCTAssertNotNil(h.entry(profileID: "two", url: "https://example.com"))
        XCTAssertTrue(h.search("Example", profileID: "one").isEmpty)
        XCTAssertNil(try HistoryStore(path: path).entry(profileID: "one", url: "https://example.com"))
    }
    func testCopyKeysAreNotReserved() {
        for mods: KeyCombo.Modifiers in [[.option, .shift, .command], [.control, .shift, .command]] {
            XCTAssertNil(KeyReservation.of(KeyCombo("c", mods)))
        }
    }
}
