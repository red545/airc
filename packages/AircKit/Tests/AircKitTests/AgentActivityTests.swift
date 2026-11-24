// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

final class AgentActivityTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func row(_ window: Int, _ tab: Int, session: String = "session-1", profile: String = "P1", at: Date? = nil) -> AgentTabRow {
        AgentTabRow(id: AgentActivityModel.rowID(window: window, tab: tab), sessionKey: session, clientKey: "k", client: "Claude",
                    profileID: profile, window: window, tab: tab, title: "Inbox (3) - Gmail",
                    url: URL(string: "https://mail.google.com/mail/u/0/#inbox?q=secret"), started: at ?? t0)
    }

    // MARK: Session model

    func testRowsLabelAndFirstOfSession() {
        var m = AgentActivityModel()
        XCTAssertTrue(m.tabOpened(row(1, 1)), "the connection's first tab starts the banner")
        XCTAssertFalse(m.tabOpened(row(1, 2)), "a second tab of the same connection doesn't")
        XCTAssertTrue(m.tabOpened(row(2, 3, session: "session-2")))
        XCTAssertEqual(m.row("agent-1-1")?.label, "Claude · Gmail")
        XCTAssertEqual(m.row("agent-1-1")?.site, "mail.google.com", "host only: no path, query or fragment")
    }

    func testNeedsYouWaitsForTheAgentAndClears() {
        var m = AgentActivityModel()
        m.tabOpened(row(1, 1))
        let id = "agent-1-1"
        XCTAssertTrue(m.setNeedsYou(id, "Sign in"))
        XCTAssertFalse(m.setNeedsYou(id, "Sign in"), "no change, no update")
        XCTAssertEqual(m.row(id)?.shown, true, "a row that needs the person shows")
        XCTAssertEqual(m.needsYouCount, 1)
        XCTAssertEqual(m.state(m.row(id)!, now: t0), .needsYou("Sign in"))
        m.began(id, caption: "Typing", at: t0)
        XCTAssertEqual(m.state(m.row(id)!, now: t0), .acting("Typing"), "while the agent acts (a saved login), it reads as acting")
        m.finished(id, at: t0)
        XCTAssertEqual(m.state(m.row(id)!, now: t0.addingTimeInterval(5)), .needsYou("Sign in"))
        XCTAssertTrue(m.setNeedsYou(id, nil))
        XCTAssertEqual(m.needsYouCount, 0)
        m.sessionEnded("session-1", .done, at: t0.addingTimeInterval(6))
        XCTAssertFalse(m.setNeedsYou(id, "Captcha"), "an ended row never needs the person")
    }

    func testActingThenIdleThenDoneThenFadedThenGone() {
        var m = AgentActivityModel()
        m.tabOpened(row(1, 1))
        let id = "agent-1-1"
        XCTAssertEqual(m.state(m.row(id)!, now: t0), .idle)
        m.began(id, caption: "Clicking ‘Archive’", at: t0)
        XCTAssertEqual(m.state(m.row(id)!, now: t0.addingTimeInterval(10)), .acting("Clicking ‘Archive’"), "in flight: acting however long")
        XCTAssertNil(m.nextChange(after: t0), "nothing changes by itself while a call is in flight")
        m.finished(id, at: t0.addingTimeInterval(1))
        XCTAssertTrue(m.isActing(id, now: t0.addingTimeInterval(2)), "a short tail after each call")
        XCTAssertEqual(m.nextChange(after: t0.addingTimeInterval(1)), t0.addingTimeInterval(1 + AgentActivityModel.actingTail))
        XCTAssertEqual(m.state(m.row(id)!, now: t0.addingTimeInterval(3)), .idle)
        m.sessionEnded("session-1", .done, at: t0.addingTimeInterval(10))
        XCTAssertEqual(m.state(m.row(id)!, now: t0.addingTimeInterval(20)), .justEnded(.done))
        XCTAssertEqual(m.state(m.row(id)!, now: t0.addingTimeInterval(10 + 5 * 60)), .faded(.done, minutes: 5))
        m.began(id, caption: "late", at: t0.addingTimeInterval(11))
        XCTAssertFalse(m.isActing(id, now: t0.addingTimeInterval(11)), "an ended row never acts again")
        XCTAssertEqual(m.state(m.row(id)!, now: t0.addingTimeInterval(10 + 4 * 60)), .faded(.done, minutes: 4))
        XCTAssertFalse(m.prune(now: t0.addingTimeInterval(10 + 4 * 60)))
        XCTAssertTrue(m.prune(now: t0.addingTimeInterval(10 + 5 * 60)), "5 minutes after its end (the default), a row goes")
        XCTAssertTrue(m.rows.isEmpty)
    }

    // MARK: agentrows: no row for nothing, titles, auto-close

    func blank(_ window: Int, _ tab: Int, session: String = "session-1") -> AgentTabRow {
        AgentTabRow(id: AgentActivityModel.rowID(window: window, tab: tab), sessionKey: session, clientKey: "k",
                    client: "Claude Code on studio", profileID: "P1", window: window, tab: tab, started: t0)
    }

    func testABlankWindowGetsNoRowUntilRealWork() {
        var m = AgentActivityModel()
        XCTAssertFalse(m.tabOpened(blank(1, 1)), "a blank window is no row (no banner)")
        XCTAssertTrue(m.rows(profileID: "P1").isEmpty)
        XCTAssertFalse(m.update("agent-1-1", title: "", url: URL(string: "about:blank")))
        XCTAssertFalse(m.did("agent-1-1", AgentAction(kind: .look)), "a screenshot of a blank page isn't work")
        XCTAssertTrue(m.rows(profileID: "P1").isEmpty)
        m.sessionEnded("session-1", .done, at: t0)
        XCTAssertTrue(m.rows.isEmpty, "a session that never did anything leaves nothing behind")
        XCTAssertNil(m.nextChange(after: t0))

        XCTAssertFalse(m.tabOpened(blank(2, 2, session: "session-2")))
        XCTAssertTrue(m.update("agent-2-2", title: "Corner Shop", url: URL(string: "https://cornershop.example/cart?id=99")),
                      "its first page with a site shows the row, as the connection's first (banner)")
        XCTAssertEqual(m.rows(profileID: "P1").map(\.id), ["agent-2-2"])
        XCTAssertFalse(m.tabOpened(blank(2, 3, session: "session-2")))
        XCTAssertEqual(m.reveal("agent-2-3"), false, "an acting call shows a blank tab's row, not as the first")
        XCTAssertNil(m.reveal("agent-2-3"), "once")
    }

    func testTitlesSayWhatHappenedWithoutContent() {
        var m = AgentActivityModel()
        m.tabOpened(blank(1, 1))
        let id = "agent-1-1"
        m.update(id, title: "Inbox (3) - Gmail", url: URL(string: "https://mail.google.com/mail/u/0/#inbox"))
        XCTAssertEqual(m.row(id)?.rowTitle, "Gmail", "only a page so far: the site")
        m.did(id, AgentAction(kind: .read, host: "mail.google.com"))
        XCTAssertEqual(m.row(id)?.rowTitle, "Gmail · read a page")
        for path in ["a", "b"] {
            m.update(id, title: "Message - Gmail", url: URL(string: "https://mail.google.com/mail/u/0/\(path)?secret=1"))
            m.did(id, AgentAction(kind: .read))
        }
        XCTAssertEqual(m.row(id)?.rowTitle, "Gmail · read 3 pages")

        m.tabOpened(blank(2, 2, session: "s2"))
        let shop = "agent-2-2"
        m.update(shop, title: "Your order – Corner Shop", url: URL(string: "https://cornershop.example/checkout"))
        m.did(shop, AgentAction(kind: .click, label: "Pickup time"))
        m.did(shop, AgentAction(kind: .type, label: "Note"))
        m.did(shop, AgentAction(kind: .type, label: "Name"))
        m.approved(shop, .payment)
        let title = m.row(shop)!.rowTitle
        XCTAssertEqual(title, "Corner Shop · filled a form, paid (approved)")
        XCTAssertFalse(title.contains("Pickup") || title.contains("Note"), "never a label, typed text or a value")

        m.tabOpened(blank(3, 3, session: "s3"))
        m.update("agent-3-3", title: "Search", url: URL(string: "https://search.example/"))
        m.did("agent-3-3", AgentAction(kind: .type))
        m.did("agent-3-3", AgentAction(kind: .key, keyName: "Return"))
        m.update("agent-3-3", title: "results - Search", url: URL(string: "https://search.example/results?q=private+words"))
        m.update("agent-3-3", title: "Docs", url: URL(string: "https://docs.example/page"))
        m.did("agent-3-3", AgentAction(kind: .click))
        XCTAssertEqual(m.row("agent-3-3")?.rowTitle, "Search +1 · searched, browsed 3 pages")

        m.setTask("s4", "Order   my usual\ncoffee beans from the corner shop and pick the earliest pickup time")
        m.tabOpened(blank(4, 4, session: "s4"))
        m.update("agent-4-4", title: "Corner Shop", url: URL(string: "https://cornershop.example/"))
        XCTAssertEqual(m.row("agent-4-4")?.rowTitle, "Order my usual coffee beans from the corner…", "the Airc Agent: its task, one line")
    }

    func testFinishedRowsGoAfterTheKeepTimeUnlessHeld() {
        var m = AgentActivityModel()
        m.keepFinished = 60
        m.tabOpened(row(1, 1))
        m.tabOpened(row(1, 2))
        m.sessionEnded("session-1", .done, at: t0)
        XCTAssertEqual(m.state(m.row("agent-1-1")!, now: t0.addingTimeInterval(20)), .justEnded(.done))
        XCTAssertEqual(m.nextChange(after: t0.addingTimeInterval(31)), t0.addingTimeInterval(60))
        XCTAssertFalse(m.prune(now: t0.addingTimeInterval(59), held: ["agent-1-1"]))
        XCTAssertTrue(m.prune(now: t0.addingTimeInterval(60), held: ["agent-1-1"]), "a watched row stays, the other goes")
        XCTAssertEqual(m.rows.map(\.id), ["agent-1-1"])
        XCTAssertFalse(m.prune(now: t0.addingTimeInterval(90), held: ["agent-1-1"]))
        XCTAssertNotNil(m.nextChange(after: t0.addingTimeInterval(90)), "a held row is looked at again")
        XCTAssertFalse(m.prune(now: t0.addingTimeInterval(149)), "the keep time starts again once nobody holds it")
        XCTAssertTrue(m.prune(now: t0.addingTimeInterval(150)))

        m.keepFinished = nil
        m.tabOpened(row(2, 3, session: "s2"))
        m.sessionEnded("s2", .stopped, at: t0)
        XCTAssertFalse(m.prune(now: t0.addingTimeInterval(7 * 24 * 3600)), "Until I clear: it stays")
        m.clearEnded()
        XCTAssertTrue(m.rows.isEmpty)
    }

    func testEndsAreKeptApartAndClearRemovesOnlyEnded() {
        var m = AgentActivityModel()
        m.tabOpened(row(1, 1))
        m.tabOpened(row(1, 2))
        m.tabOpened(row(2, 3, session: "session-2"))
        m.ended("agent-1-1", .takenOver, at: t0)
        m.sessionEnded("session-2", .stopped, at: t0)
        XCTAssertEqual(m.state(m.row("agent-1-1")!, now: t0), .justEnded(.takenOver))
        XCTAssertEqual(m.state(m.row("agent-2-3")!, now: t0), .justEnded(.stopped))
        XCTAssertTrue(m.row("agent-1-2")!.isLive, "taking over one tab leaves the connection's others")
        m.clearEnded()
        XCTAssertEqual(m.rows.map(\.id), ["agent-1-2"])
    }

    func testRowsArePerProfileLiveFirst() {
        var m = AgentActivityModel()
        m.tabOpened(row(1, 1, at: t0))
        m.tabOpened(row(1, 2, at: t0.addingTimeInterval(1)))
        m.tabOpened(row(3, 4, session: "session-3", profile: "P2"))
        m.ended("agent-1-1", .done, at: t0.addingTimeInterval(2))
        XCTAssertEqual(m.rows(profileID: "P1").map(\.id), ["agent-1-2", "agent-1-1"])
        XCTAssertEqual(m.rows(profileID: "P2").map(\.id), ["agent-3-4"], "another profile's window never shows them")
        XCTAssertTrue(m.rows(profileID: "private").isEmpty)
    }

    func testOneFolderRowPerSessionAndNoneForTheAircAgentsOwnRun() {
        var m = AgentActivityModel()
        m.tabOpened(row(1, 1, at: t0))
        m.tabOpened(row(1, 2, at: t0.addingTimeInterval(1)))
        m.tabOpened(row(2, 3, session: "session-2", at: t0.addingTimeInterval(2)))
        var panel = row(5, 6, session: "panel-1", at: t0.addingTimeInterval(3))
        panel.clientKey = "airc-panel"
        panel.client = "Codex (in Airc)"
        m.tabOpened(panel)
        XCTAssertEqual(m.rows(profileID: "P1").count, 4, "the per-tab rows are still there (Watch, Take over, Activity)")
        XCTAssertEqual(m.sessionRows(profileID: "P1").map(\.sessionKey), ["session-1", "session-2", "panel-1"], "one per session")
        XCTAssertEqual(m.sessionRows(profileID: "P1", excluding: "airc-panel").map(\.id), ["agent-1-2", "agent-2-3"],
                       "the Airc Agent's run is its task's row, never a second one")
        XCTAssertTrue(m.setNeedsYou("agent-1-1", "Sign in"))
        XCTAssertEqual(m.sessionRows(profileID: "P1").first?.id, "agent-1-1", "the page that needs the person stands for the session")
        m.ended("agent-1-1", .takenOver, at: t0.addingTimeInterval(4))
        XCTAssertEqual(m.sessionRows(profileID: "P1").first?.id, "agent-1-2", "a live page over a taken-over one")
        m.ended("agent-1-2", .done, at: t0.addingTimeInterval(5))
        XCTAssertEqual(m.sessionRows(profileID: "P1").filter { $0.sessionKey == "session-1" }.map(\.id), ["agent-1-2"],
                       "once all end: the last to end, still one row")
    }

    // MARK: Redaction

    func testLabelsAreShortOneLineAndNeverLookLikeSecrets() {
        XCTAssertEqual(AgentRedaction.label("  Search\n  mail "), "Search mail")
        XCTAssertNil(AgentRedaction.label("   "))
        XCTAssertNil(AgentRedaction.label("Your code is 493 812"), "six digits: a code")
        XCTAssertNil(AgentRedaction.label("ada@example.com"), "an address")
        let long = AgentRedaction.label(String(repeating: "word ", count: 30))!
        XCTAssertLessThanOrEqual(long.count, AgentRedaction.maxLabel)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func testCaptionsNameLabelsButNeverTypedTextOrValues() {
        XCTAssertEqual(AgentRedaction.caption(AgentAction(kind: .click, label: "Archive")), "Clicking ‘Archive’")
        XCTAssertEqual(AgentRedaction.caption(AgentAction(kind: .click)), "Clicking")
        XCTAssertEqual(AgentRedaction.caption(AgentAction(kind: .type, label: "Search mail")), "Typing in ‘Search mail’")
        XCTAssertEqual(AgentRedaction.caption(AgentAction(kind: .type, label: "Password", isPasswordField: true)), "Typing in ‘Password’ (hidden)")
        XCTAssertEqual(AgentRedaction.caption(AgentAction(kind: .type, isPasswordField: true)), "Typing a password")
        XCTAssertEqual(AgentRedaction.caption(AgentAction(kind: .type)), "Typing…")
        XCTAssertEqual(AgentRedaction.caption(AgentAction(kind: .navigate, host: "mail.example")), "Opening mail.example")
        // A key call's text is a key name, or a character (typing): only names and shortcuts show.
        XCTAssertEqual(AgentRedaction.keyName("Return"), "Return")
        XCTAssertEqual(AgentRedaction.keyName("ctrl+a"), "⌃A")
        XCTAssertEqual(AgentRedaction.keyName("super+shift+z"), "⌘⇧Z")
        XCTAssertEqual(AgentRedaction.keyName("F5"), "F5")
        XCTAssertNil(AgentRedaction.keyName("h"), "a lone character is typing")
        XCTAssertNil(AgentRedaction.keyName("shift+h"), "a shifted character too")
        XCTAssertNil(AgentRedaction.keyName("bogus+x"))
        XCTAssertEqual(AgentRedaction.caption(AgentAction(kind: .key, keyName: AgentRedaction.keyName("x"))), "Typing…")
    }

    func testSiteNameUsesOnlyAShortTrailingTitlePart() {
        let u = URL(string: "https://www.example.com/a/b?c=d")
        XCTAssertEqual(AgentRedaction.site(u), "example.com")
        XCTAssertEqual(AgentRedaction.siteName(title: "Inbox (3) - Gmail", url: u), "Gmail")
        XCTAssertEqual(AgentRedaction.siteName(title: "Order 123456 | Shop 2024 777", url: u), "example.com", "digits: not a name")
        XCTAssertEqual(AgentRedaction.siteName(title: "A very private subject line without a separator", url: u), "example.com")
        XCTAssertEqual(AgentRedaction.siteName(title: "", url: URL(string: "about:blank")), "New page")
        XCTAssertEqual(AgentRedaction.siteName(title: "Pastelaria Aurora", url: u), "Pastelaria Aurora", "a short title that is only a name")
        XCTAssertEqual(AgentRedaction.siteName(title: "Your order · Pastelaria Aurora", url: u), "Pastelaria Aurora")
        XCTAssertEqual(AgentRedaction.siteName(title: "127.0.0.1:8080/login", url: u), "example.com", "an address isn't a name")
    }

    func testToolKinds() {
        XCTAssertEqual(AgentActionKind.of(tool: "left_click"), .click)
        XCTAssertEqual(AgentActionKind.of(tool: "computer", action: "type"), .type)
        XCTAssertEqual(AgentActionKind.of(tool: "navigate"), .navigate)
        XCTAssertEqual(AgentActionKind.of(tool: "list_profiles"), .other)
    }

    // MARK: History

    func testHistoryJoinsBurstsPerSiteAndHoldsNoSecrets() {
        var h = AgentHistory()
        let secret = "hunter2-agentview"
        h.record(client: "Claude", site: "mail.example", action: AgentAction(kind: .click, label: "Archive"), at: t0)
        h.record(client: "Claude", site: "mail.example", action: AgentAction(kind: .click, label: "Delete " + secret), at: t0.addingTimeInterval(10))
        h.record(client: "Claude", site: "mail.example", action: AgentAction(kind: .type, label: "Password", isPasswordField: true), at: t0.addingTimeInterval(20))
        h.record(client: "Claude", site: "mail.example", action: AgentAction(kind: .wait), at: t0.addingTimeInterval(25))
        h.record(client: "Claude", site: "shop.example", action: AgentAction(kind: .navigate, host: "shop.example"), at: t0.addingTimeInterval(30))
        h.record(client: "Claude", site: "shop.example", action: AgentAction(kind: .click), at: t0.addingTimeInterval(30 + 6 * 60))
        h.record(client: "Codex", site: "mail.example", action: AgentAction(kind: .read), at: t0.addingTimeInterval(40))
        XCTAssertEqual(h.entries.count, 4, "same app and site within 5 min join; a pause of 6 min starts a new entry")
        XCTAssertEqual(h.entries[0].line, "Clicked 2×, Typed in a password field")
        XCTAssertEqual(h.byClient().map(\.client), ["Codex", "Claude"])
        var copy = h
        let text = String(decoding: copy.encoded()!, as: UTF8.self)
        XCTAssertFalse(text.contains(secret), "no label, value or typed text in the file")
        XCTAssertFalse(text.contains("Archive"))
        XCTAssertFalse(text.contains("/mail"), "hosts only")
    }

    func testHistoryKeepsSevenDaysAndClears() throws {
        var h = AgentHistory()
        h.record(client: "Claude", site: "a.example", action: AgentAction(kind: .click), at: t0)
        h.record(client: "Claude", site: "b.example", action: AgentAction(kind: .click), at: t0.addingTimeInterval(6 * 86400))
        let data = h.encoded()
        XCTAssertFalse(h.dirty)
        let loaded = AgentHistory(data: data, now: t0.addingTimeInterval(7 * 86400 + 60))
        XCTAssertEqual(loaded.entries.map(\.site), ["b.example"], "older than 7 days: gone on load")
        XCTAssertTrue(loaded.dirty, "and saved again")
        var cleared = loaded
        cleared.clear()
        XCTAssertTrue(cleared.entries.isEmpty)
        XCTAssertEqual(AgentHistory(data: Data("not json".utf8), now: t0).entries.count, 0)
    }
}
