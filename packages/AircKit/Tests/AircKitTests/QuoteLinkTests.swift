// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

/// C06: the text fragment a quote link carries (long, multi-line, punctuated and non-Latin selections), the pages that
/// get a plain link instead, and Arc's labels.
final class QuoteLinkTests: XCTestCase {
    private func fragment(_ selection: String) -> String? {
        LinkCopyPolicy.textFragmentURL("https://example.com/a", selection: selection)?
            .components(separatedBy: "#:~:text=").last
    }

    // MARK: Long selections

    func testUpToEightWordsGoWhole() {
        XCTAssertEqual(fragment("one two three four five six seven eight"), "one%20two%20three%20four%20five%20six%20seven%20eight")
        XCTAssertEqual(fragment("one two three four five six seven eight nine"), "one%20two%20three%20four,six%20seven%20eight%20nine")
    }

    func testAVeryLongPassageIsARangeOfItsFirstAndLastWords() {
        let words = (1...400).map { "w\($0)" }.joined(separator: " ")
        XCTAssertEqual(fragment(words), "w1%20w2%20w3%20w4,w397%20w398%20w399%20w400")
        XCTAssertLessThan(LinkCopyPolicy.textFragmentURL("https://example.com/a", selection: words)!.count, 80, "the link stays short")
    }

    func testFewButLongWordsAreCappedByCharacters() {
        // Eight words of 20 letters: 167 characters, too long to go whole; each end keeps whole words within 48.
        let w = (1...8).map { i in String(repeating: Character(UnicodeScalar(UInt8(96 + i))), count: 20) }
        XCTAssertEqual(fragment(w.joined(separator: " ")), "\(w[0])%20\(w[1]),\(w[6])%20\(w[7])")
    }

    func testOneHugeTokenIsCutByCharacters() {
        let token = String(repeating: "x", count: 100) + String(repeating: "y", count: 100)
        XCTAssertEqual(fragment(token), String(repeating: "x", count: 24) + "," + String(repeating: "y", count: 24))
    }

    // MARK: Punctuation

    func testPunctuationIsKeptAndTheDirectiveCharactersAreEscaped() {
        // Eight words: whole.
        XCTAssertEqual(fragment("“Hello,” she said: 5-10 p.m. & #1 (50%)!"),
                       "%E2%80%9CHello%2C%E2%80%9D%20she%20said:%205%2D10%20p.m.%20%26%20%231%20(50%25)!")
        // Every term decodes back to the selected words.
        let link = LinkCopyPolicy.textFragmentURL("https://example.com/", selection: "a-b, c&d #e %f")!
        let terms = link.components(separatedBy: "#:~:text=")[1].split(separator: ",").map { $0.removingPercentEncoding ?? "" }
        XCTAssertEqual(terms, ["a-b, c&d #e %f"])
    }

    func testTheResultIsAValidURL() {
        for s in ["a?b=c d", "x/y\\z", "<tag> \"quoted\"", "tab\there", "emoji 👩‍👩‍👧 family", "a\u{00A0}b"] {
            let link = LinkCopyPolicy.textFragmentURL("https://example.com/", selection: s)
            XCTAssertNotNil(link.flatMap(URL.init(string:)), s)
        }
        XCTAssertEqual(fragment("a\u{00A0}b"), "a%20b", "a no-break space is a space")
    }

    // MARK: Multi-line

    func testSeveralLinesAreARangeFromTheFirstToTheLast() {
        // A term only matches inside one block: two short paragraphs can't go as one term.
        XCTAssertEqual(fragment("First paragraph here.\n\nSecond one."), "First%20paragraph%20here.,Second%20one.")
        XCTAssertEqual(fragment("Title\nA much longer second line with many words in it\n\nEnd line words here now"),
                       "Title,line%20words%20here%20now")
        XCTAssertEqual(fragment("\n  only line  \n\n"), "only%20line", "blank lines don't count")
        XCTAssertEqual(fragment("cr\r\nlf"), "cr,lf")
    }

    // MARK: Non-Latin

    func testNonLatinScripts() {
        XCTAssertEqual(fragment("Привет мир"), "%D0%9F%D1%80%D0%B8%D0%B2%D0%B5%D1%82%20%D0%BC%D0%B8%D1%80")
        XCTAssertEqual(fragment("مرحبا بالعالم"), "%D9%85%D8%B1%D8%AD%D8%A8%D8%A7%20%D8%A8%D8%A7%D9%84%D8%B9%D8%A7%D9%84%D9%85")
        // A short Japanese sentence (no spaces) goes whole.
        let ja = "吾輩は猫である。名前はまだ無い。"
        XCTAssertEqual(fragment(ja), ja.addingPercentEncoding(withAllowedCharacters: CharacterSet()))
        // A long one is cut by characters: 24 from each end, whole characters (a surrogate pair or a combining mark
        // never splits).
        let long = String(repeating: "漢字かな交じり文", count: 20) + "😀"
        let terms = fragment(long)!.split(separator: ",").map { $0.removingPercentEncoding ?? "" }
        XCTAssertEqual(terms.count, 2)
        XCTAssertEqual(terms[0], String(long.prefix(24)))
        XCTAssertEqual(terms[1], String(long.suffix(24)))
        XCTAssertTrue(terms[1].hasSuffix("😀"))
        let accents = String(repeating: "e\u{0301}", count: 130)
        let cut = fragment(accents)!.split(separator: ",").map { $0.removingPercentEncoding ?? "" }
        XCTAssertEqual(cut.first?.count, 24)
        XCTAssertTrue(cut.first?.unicodeScalars.last == "\u{0301}", "the accent stays with its letter")
    }

    // MARK: Opt-outs

    func testPagesThatGetAPlainLink() {
        typealias P = QuoteLink.Page
        XCTAssertNil(QuoteLink.optOut(P(url: "https://example.com/a")))
        XCTAssertNil(QuoteLink.optOut(P(url: "https://example.com/a", contentType: "text/html", documentPolicy: "")))
        for u in ["about:blank", "chrome://settings", "file:///tmp/a.html", "data:text/html,hi", "blob:https://example.com/x",
                  "airc://newtab", "https:///nohost", "not a url"] {
            XCTAssertEqual(QuoteLink.optOut(P(url: u)), .notWebsite, u)
        }
        XCTAssertEqual(QuoteLink.optOut(P(url: "https://example.com/paper.PDF")), .pdf)
        XCTAssertEqual(QuoteLink.optOut(P(url: "https://example.com/paper", contentType: "application/pdf")), .pdf)
        XCTAssertNil(QuoteLink.optOut(P(url: "https://example.com/about.pdf", contentType: "text/html")),
                     "a page's real type wins over its name")
        XCTAssertEqual(QuoteLink.optOut(P(url: "https://example.com/a", isPrivate: true)), .privateWindow)
        XCTAssertEqual(QuoteLink.optOut(P(url: "https://example.com/a", documentPolicy: "force-load-at-top")), .forceLoadAtTop)
        XCTAssertEqual(QuoteLink.optOut(P(url: "https://example.com/a", unreadable: true)), .unreadable)
        XCTAssertEqual(QuoteLink.optOut(P(url: "https://example.com/a", contentType: "application/pdf", unreadable: true)), .pdf)
    }

    func testDocumentPolicyParsing() {
        for on in ["force-load-at-top", "force-load-at-top=?1", " oversized-images=2.0, force-load-at-top ;report-to=x",
                   "FORCE-LOAD-AT-TOP"] {
            XCTAssertTrue(QuoteLink.forcesLoadAtTop(on), on)
        }
        for off in ["", "force-load-at-top=?0", "oversized-images=2.0", "no-force-load-at-top", "force-load-at-topx"] {
            XCTAssertFalse(QuoteLink.forcesLoadAtTop(off), off)
        }
    }

    func testWhatACopyWrites() {
        let quote = QuoteLink.copy(.init(url: "https://example.com/a?utm_source=x"), selection: "the quick brown fox")
        XCTAssertEqual(quote?.link, "https://example.com/a#:~:text=the%20quick%20brown%20fox")
        XCTAssertEqual(quote?.withQuote, true)
        let policy = QuoteLink.copy(.init(url: "https://example.com/a?utm_source=x#top", documentPolicy: "force-load-at-top"),
                                    selection: "the quick brown fox")
        XCTAssertEqual(policy?.link, "https://example.com/a#top", "a plain clean link, its own fragment kept")
        XCTAssertEqual(policy?.withQuote, false)
        XCTAssertEqual(QuoteLink.copy(.init(url: "https://example.com/doc.pdf"), selection: "words here too")?.withQuote, false)
        XCTAssertEqual(QuoteLink.copy(.init(url: "https://example.com/a"), selection: "  \n ")?.link, "https://example.com/a",
                       "no words: the page's link")
        XCTAssertNil(QuoteLink.copy(.init(url: ""), selection: "words"))
    }

    func testArcsLabels() {
        XCTAssertEqual(QuoteLink.copyTitle, "Copy Quote Link")
        XCTAssertEqual(QuoteLink.copiedToast, "Copied Link")
        XCTAssertEqual(QuoteLink.withQuote, "With Quote")
        XCTAssertEqual(QuoteLink.symbol, "quote.bubble.fill")
    }
}
