// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

final class PageMailTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func answer(_ o: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!
    }

    private let feed = """
        <?xml version="1.0" encoding="UTF-8"?><feed version="0.3" xmlns="http://purl.org/atom/ns#">
        <title>Gmail - Inbox for someone@example.com</title><fullcount>2</fullcount>
        <entry><title>Older &amp; wiser</title><summary>The older one.</summary>
        <link rel="alternate" href="http://mail.google.com/mail?account_id=a&amp;message_id=18c1&amp;view=conv&amp;extsrc=atom" type="text/html" />
        <modified>2027-01-15T07:00:00Z</modified><issued>2027-01-15T07:00:00Z</issued><id>tag:gmail.google.com,2004:1789</id>
        <author><name>Grace Hopper</name><email>grace@example.com</email></author></entry>
        <entry><title>Newer</title><summary>The newer one.</summary><link href="http://mail.google.com/mail?message_id=18c2" />
        <issued>2027-01-15T07:30:00Z</issued><id>tag:gmail.google.com,2004:1790</id>
        <author><name>Ada Lovelace</name><email>ada@example.com</email></author></entry>
        </feed>
        """

    func testGmailFeedNewestFirstWithSenderSubjectSnippetAndHTTPSLinks() throws {
        let s = PageMail.state(from: answer(["feed": feed, "rowsFound": false]), service: .gmail, now: now)
        guard case .ready(.mail(let m))? = s else { return XCTFail("\(String(describing: s))") }
        XCTAssertEqual(m.map(\.id), ["1790", "1789"])
        XCTAssertEqual(m[1].sender, "Grace Hopper")
        XCTAssertEqual(m[1].senderAddress, "grace@example.com")
        XCTAssertEqual(m[1].subject, "Older & wiser")
        XCTAssertEqual(m[1].snippet, "The older one.")
        XCTAssertEqual(m[1].url, "https://mail.google.com/mail?account_id=a&message_id=18c1&view=conv&extsrc=atom")
    }

    func testAnEmptyFeedIsAnEmptyInbox() {
        let empty = #"<?xml version="1.0"?><feed xmlns="http://purl.org/atom/ns#"><fullcount>0</fullcount></feed>"#
        XCTAssertEqual(PageMail.state(from: answer(["feed": empty]), service: .gmail, now: now), .ready(.mail([])))
    }

    func testSignedOutWins() {
        XCTAssertEqual(PageMail.state(from: answer(["signedOut": true, "feed": feed]), service: .gmail, now: now), .signedOut)
    }

    func testNotAFeedFallsBackToTheListAndNothingIsNil() {
        let rows: [[String: Any]] = [
            ["id": "b", "sender": " Grace  Hopper ", "subject": "Two", "snippet": "second", "ms": 1_799_999_000_000.0, "url": "x/b"],
            ["id": "a", "sender": "Ada", "subject": "One", "snippet": "first", "ms": 1_799_999_900_000.0],
            ["id": "a", "sender": "Ada", "subject": "Dup", "snippet": "dup", "ms": 1_799_999_900_000.0],
        ]
        let s = PageMail.state(from: answer(["feed": "<html>Not a feed</html>", "rowsFound": true, "rows": rows]), service: .gmail, now: now)
        guard case .ready(.mail(let m))? = s else { return XCTFail("\(String(describing: s))") }
        XCTAssertEqual(m.map(\.id), ["a", "b"])
        XCTAssertEqual(m[1].sender, "Grace Hopper")
        XCTAssertEqual(m[1].url, "x/b")
        // No list in the page and no feed: nothing usable (the card keeps what it had).
        XCTAssertNil(PageMail.state(from: answer(["rowsFound": false]), service: .gmail, now: now))
        XCTAssertNil(PageMail.state(from: "not json", service: .gmail, now: now))
    }

    func testOutlookIgnoresAFeedAndKeepsPageOrderWithoutTimes() {
        let rows: [[String: Any]] = [["id": "1", "sender": "A", "subject": "s1", "snippet": "x"],
                                     ["id": "2", "sender": "B", "subject": "s2", "snippet": "y"]]
        let s = PageMail.state(from: answer(["feed": feed, "rowsFound": true, "rows": rows]), service: .outlookMail, now: now)
        guard case .ready(.mail(let m))? = s else { return XCTFail("\(String(describing: s))") }
        XCTAssertEqual(m.map(\.id), ["1", "2"])
    }

    func testScriptsOnlyForMailAndReadOnly() throws {
        XCTAssertNotNil(PageMail.script(for: .gmail))
        XCTAssertNotNil(PageMail.script(for: .outlookMail))
        XCTAssertNil(PageMail.script(for: .notion))
        for s in [PageMail.script(for: .gmail)!, PageMail.script(for: .outlookMail)!] {
            // Nothing that writes: no clicks, storage, navigation or posts.
            for bad in [".click(", "localStorage", "sessionStorage", "location.href=", "location.assign", "method:'POST'", "XMLHttpRequest", "postMessage"] {
                XCTAssertFalse(s.contains(bad), bad)
            }
        }
        // Gmail asks only its own origin's feed.
        XCTAssertTrue(PageMail.script(for: .gmail)!.contains("fetch(location.origin+'/mail/u/'+n+'/feed/atom'"))
        XCTAssertFalse(PageMail.script(for: .outlookMail)!.contains("fetch("))
    }

    func testEachReadIsNamedAndCanBeStopped() throws {
        let g = try XCTUnwrap(PageMail.script(for: .gmail, token: 42))
        XCTAssertTrue(g.contains("var T=42,"))
        XCTAssertFalse(g.contains("__AIRC_TOKEN__"))
        // A read cancelled before it ran never fetches; the feed request carries the abort signal; a read cancelled
        // while waiting stops before reading the list.
        let start = try XCTUnwrap(g.range(of: "if(st.dead[T])return"))
        let fetch = try XCTUnwrap(g.range(of: "await fetch("))
        XCTAssertLessThan(start.lowerBound, fetch.lowerBound)
        XCTAssertTrue(g.contains("signal:st.ctl?st.ctl.signal:undefined"))
        XCTAssertEqual(g.components(separatedBy: "if(st.dead[T])return").count - 1, 2)
        XCTAssertTrue(try XCTUnwrap(PageMail.script(for: .outlookMail, token: 7)).contains("var T=7,"))
        let cancel = PageMail.cancelScript(token: 42)
        XCTAssertTrue(cancel.contains("st.dead[42]=1") && cancel.contains("st.ctl.abort()"))
        XCTAssertTrue(PageMail.wasCancelled(#"{"cancelled":true}"#))
        XCTAssertFalse(PageMail.wasCancelled(#"{"v":1}"#))
        XCTAssertNil(PageMail.state(from: #"{"cancelled":true,"feed":"x"}"#, service: .gmail, now: now))
    }

    func testLoopbackFixturesAreLoopbackOnly() {
        defer { PreviewService.loopbackFixtures = [:] }
        XCTAssertNil(PreviewService.detect("http://127.0.0.1:8080/mail/u/0/"))
        PreviewService.loopbackFixtures = ["127.0.0.1": .gmail, "example.com": .gmail]
        XCTAssertEqual(PreviewService.detect("http://127.0.0.1:8080/mail/u/0/"), .gmail)
        XCTAssertEqual(PreviewService.accountKey("http://127.0.0.1:8080/mail/u/1/#inbox"), "u/1")
        XCTAssertNil(PreviewService.detect("http://127.0.0.1:8080/other"))
        XCTAssertNil(PreviewService.detect("https://example.com/mail/u/0/"))
    }

    func testNeedsPageDropsContentLikeSignedOut() {
        var cache = PreviewCache()
        let a = PreviewAccount(service: .gmail, profileID: "p", key: "u/0")
        cache.store(.ready(.mail([])), for: a, at: now)
        cache.store(.needsPage, for: a, at: now)
        XCTAssertEqual(cache.entry(a)?.state, .needsPage)
        XCTAssertNil(cache.entry(a)?.state.content)
    }
}
