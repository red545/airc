// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

/// P01a: clean links (C06), the late-answer gate of Copy URL as Quote (C05), a folder's links as Markdown with titles,
/// order and nesting (S11), Expand/Collapse All Folders and the tabs "Reset all tabs in this Space" takes back (P08).
final class ParityP01Tests: XCTestCase {
    // MARK: Clean links

    func testTrackersGoAndEverythingElseStaysInOrder() {
        let r = LinkCopyPolicy.cleaned("https://example.com/a?id=7&utm_source=news&utm_medium=email&q=caf%C3%A9&fbclid=XYZ&page=2#part")
        XCTAssertEqual(r.url, "https://example.com/a?id=7&q=caf%C3%A9&page=2#part")
        XCTAssertTrue(r.removedTrackers)
        XCTAssertEqual(LinkCopyPolicy.clean("https://example.com/?gclid=1&UTM_Campaign=x"), "https://example.com/",
                       "names match without case; no empty ? left behind")
        XCTAssertEqual(LinkCopyPolicy.clean("https://example.com/p?_hsenc=a&mc_eid=b#top"), "https://example.com/p#top")
    }

    func testLinksWithoutTrackersComeBackUnchanged() {
        for u in ["https://example.com/search?q=a+b&sort=new", "https://example.com/a%20b?x=%2F&y", "http://localhost:3000/?debug=1",
                  "https://example.com/", "about:blank", "file:///tmp/a.html?utm_source=x", "not a url"] {
            let r = LinkCopyPolicy.cleaned(u)
            XCTAssertEqual(r.url, u, u)
            XCTAssertFalse(r.removedTrackers, u)
        }
    }

    func testSiteShareParametersOnlyOnTheirOwnSite() {
        XCTAssertEqual(LinkCopyPolicy.clean("https://www.youtube.com/watch?v=abc&si=share1&t=42"), "https://www.youtube.com/watch?v=abc&t=42",
                       "YouTube's start time stays; its share id goes")
        XCTAssertEqual(LinkCopyPolicy.clean("https://youtu.be/abc?si=x"), "https://youtu.be/abc")
        XCTAssertEqual(LinkCopyPolicy.clean("https://x.com/user/status/1?s=20&t=AbC"), "https://x.com/user/status/1")
        XCTAssertEqual(LinkCopyPolicy.clean("https://example.com/video?si=1&s=2&t=3"), "https://example.com/video?si=1&s=2&t=3",
                       "another site's si, s and t are its own")
        XCTAssertEqual(LinkCopyPolicy.clean("https://www.amazon.co.uk/dp/B0?psc=1&pd_rd_w=a&pf_rd_p=b&ref_=c"),
                       "https://www.amazon.co.uk/dp/B0?psc=1", "every country's Amazon; the variant (psc) stays")
        XCTAssertEqual(LinkCopyPolicy.clean("https://www.google.com/search?q=airc&ei=1&ved=2&sxsrf=3"), "https://www.google.com/search?q=airc")
        XCTAssertEqual(LinkCopyPolicy.clean("https://www.google.com/maps?ei=1"), "https://www.google.com/maps?ei=1", "only search results")
    }

    func testToastsUseArcsWording() {
        XCTAssertEqual(LinkCopyPolicy.toast(count: 1, removedTrackers: true, single: "Copied Current URL"), "Copied a clean link without trackers")
        XCTAssertEqual(LinkCopyPolicy.toast(count: 3, removedTrackers: true, single: "Copied Link"), "Copied clean links without trackers")
        XCTAssertEqual(LinkCopyPolicy.toast(count: 1, removedTrackers: false, single: "Copied Current URL"), "Copied Current URL")
        XCTAssertEqual(LinkCopyPolicy.toast(count: 2, removedTrackers: false, single: "Copied Link"), "Copied 2 Links")
    }

    func testResettingTabsIsOneUndoStep() throws {
        let (s, sid, work, _) = try workFolder()
        let docs = try XCTUnwrap(s.liveTab(forItem: try XCTUnwrap(s.children(of: .pinned(spaceID: sid), parent: work).first).id))
        let split = try XCTUnwrap(s.children(of: .pinned(spaceID: sid), parent: work).first { $0.kind == .split })
        let right = try XCTUnwrap(s.paneTabs(ofSplitItem: split.id).last)
        s.updateTab(docs.id, url: "https://elsewhere.example/a")
        s.updateTab(right.id, url: "https://elsewhere.example/b")
        let before = try s.resetToSavedURLs(s.driftedPinnedTabs(inSpace: sid).map(\.id))
        XCTAssertEqual(before, [docs.id: "https://elsewhere.example/a", right.id: "https://elsewhere.example/b"])
        XCTAssertTrue(s.driftedPinnedTabs(inSpace: sid).isEmpty)
        XCTAssertEqual(s.undoLabel, SpacesStore.resetTabsLabel)
        _ = try s.undo()
        XCTAssertEqual(s.tab(docs.id)?.url, "https://elsewhere.example/a", "⌘Z: the addresses from before")
        XCTAssertEqual(s.tab(right.id)?.url, "https://elsewhere.example/b")
        XCTAssertEqual(try s.resetToSavedURLs([docs.id]).count, 1)
        XCTAssertEqual(s.undoLabel, SpacesStore.resetTabLabel)
        XCTAssertTrue(try s.resetToSavedURLs([docs.id]).isEmpty, "nothing away from its URL: no step")
    }

    // MARK: Per-row switches

    func testUnreadBadgeIsOnUntilTurnedOffAndForgetsDeletedRows() throws {
        var p = SidebarItemPreferences()
        XCTAssertTrue(p.showsUnreadBadge("mail"))
        p.setUnreadBadge(false, for: "mail", existing: ["mail", "chat"])
        p.setUnreadBadge(false, for: "chat", existing: ["mail", "chat"])
        XCTAssertFalse(p.showsUnreadBadge("mail"))
        p.setUnreadBadge(true, for: "chat", existing: ["chat"])
        XCTAssertEqual(p.noUnreadBadge, [], "mail's row is gone, chat's back on")
        p.setUnreadBadge(false, for: "mail", existing: ["mail"])
        let round = try JSONDecoder().decode(SidebarItemPreferences.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(round, p)
        XCTAssertEqual(try JSONDecoder().decode(SidebarItemPreferences.self, from: Data("{}".utf8)), SidebarItemPreferences(),
                       "older settings files load")
    }

    func testATodayTabsIconGoesWithItWhenPinnedAndComesBack() throws {
        let s = try makeStore()
        let sid = s.selectedSpace.id
        let t = try s.openTab(url: "https://today.example/", inSpace: sid, title: "Today")
        try s.setTabIcon(t.id, to: "🍋")
        XCTAssertEqual(s.tab(t.id)?.icon, "🍋")
        try s.togglePin(t.id, inSpace: sid)
        let item = try XCTUnwrap(s.item(s.tab(t.id)?.itemID))
        XCTAssertEqual(item.icon, "🍋", "pinned: the item has it")
        XCTAssertNil(s.tab(t.id)?.icon, "and the tab no longer keeps a copy")
        try s.setTabIcon(t.id, to: "🍊")
        XCTAssertEqual(s.item(item.id)?.icon, "🍊", "a pinned tab's Change Icon is its item's")
        try s.move(.item(item.id), to: .today(spaceID: sid, index: 0))
        let back = try XCTUnwrap(s.todayTabs(ofSpace: sid).first { $0.url == "https://today.example/" })
        XCTAssertEqual(back.icon, "🍊", "unpinned: back on the Today tab")
        try s.setTabIcon(back.id, to: "")
        XCTAssertNil(s.tab(back.id)?.icon, "\"\" gives the favicon back")
    }

    func testATabsIconSurvivesRelaunchAndOlderFilesStillRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("airc-p01-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("spaces.sqlite").path
        var id = ""
        do {
            let s = try SpacesStore(path: path)
            let t = try s.openTab(url: "https://icon.example/", inSpace: s.selectedSpace.id)
            try s.setTabIcon(t.id, to: "🧭")
            try s.flush()
            id = t.id
        }
        XCTAssertEqual(try SpacesStore(path: path).tab(id)?.icon, "🧭")
        // A tab without an icon encodes exactly as 0.1.2's did (no key), and 0.1.2's rows read with none.
        let plain = LiveTab(profileID: "p", spaceID: "s", url: "https://x.example/")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        XCTAssertNil(json["icon"])
        let older = try JSONDecoder().decode(LiveTab.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(older.icon)
        var withIcon = plain
        withIcon.icon = "🧭"
        XCTAssertEqual(try JSONDecoder().decode(LiveTab.self, from: JSONEncoder().encode(withIcon)).icon, "🧭")
    }

    func testALinkStraightToTheSelectedText() {
        XCTAssertEqual(LinkCopyPolicy.textFragmentURL("https://example.com/a?utm_source=x#top", selection: "  Hello   world\n"),
                       "https://example.com/a#:~:text=Hello%20world", "the page's fragment and trackers give way")
        XCTAssertEqual(LinkCopyPolicy.textFragmentURL("https://example.com/", selection: "one two three four five six seven eight nine ten"),
                       "https://example.com/#:~:text=one%20two%20three%20four,seven%20eight%20nine%20ten", "a long passage: first and last words")
        XCTAssertEqual(LinkCopyPolicy.textFragmentURL("https://example.com/", selection: "well-known, salt & pepper"),
                       "https://example.com/#:~:text=well%2Dknown%2C%20salt%20%26%20pepper", "the directive's own characters are escaped")
        XCTAssertEqual(LinkCopyPolicy.textFragmentURL("https://example.com/", selection: "café"), "https://example.com/#:~:text=caf%C3%A9")
        XCTAssertNil(LinkCopyPolicy.textFragmentURL("https://example.com/", selection: " \n "))
        XCTAssertNil(LinkCopyPolicy.textFragmentURL("about:blank", selection: "words"))
    }

    // MARK: The late-answer gate

    func testOnlyTheLatestRequestWritesOnceWhileItsContextHolds() {
        let gate = LatestAnswerGate<String>()
        let first = gate.begin("tab A", changeCount: 10)
        let second = gate.begin("tab A", changeCount: 10)
        XCTAssertFalse(gate.finish(first, now: "tab A", changeCount: 10), "a later request replaces an earlier one")
        XCTAssertTrue(gate.finish(second, now: "tab A", changeCount: 10))
        XCTAssertFalse(gate.finish(second, now: "tab A", changeCount: 10), "an answer writes once")

        let moved = gate.begin("tab A", changeCount: 11)
        XCTAssertFalse(gate.finish(moved, now: "tab B", changeCount: 11), "another tab, Peek or page: the answer comes to nothing")
        let copiedElsewhere = gate.begin("tab A", changeCount: 12)
        XCTAssertFalse(gate.finish(copiedElsewhere, now: "tab A", changeCount: 13), "something else was copied meanwhile")
        let cancelled = gate.begin("tab A", changeCount: 14)
        gate.cancel()
        XCTAssertFalse(gate.finish(cancelled, now: "tab A", changeCount: 14))
    }

    // MARK: Folders

    /// Folder "Work": Docs, a nested folder "Specs" (Spec 1, a note, Spec 2), a pinned split (Left, Right), then
    /// "Calendar [team]".
    private func workFolder() throws -> (s: SpacesStore, sid: String, folder: String, nested: String) {
        let s = try makeStore()
        let sid = s.selectedSpace.id
        let work = try s.createFolder(named: "Work", inSpace: sid)
        func pin(_ title: String, _ url: String, in parent: String) throws {
            let t = try s.openTab(url: url, inSpace: sid, title: title)
            let n = s.children(of: .pinned(spaceID: sid), parent: parent).count
            try s.move(.tab(t.id), to: .pinned(spaceID: sid, parentID: parent, index: n))
            if let i = s.tab(t.id)?.itemID { try s.renameItem(i, to: title) }
        }
        try pin("Docs", "https://docs.example/?utm_source=x", in: work.id)
        let specs = try s.createFolder(named: "Specs", inSpace: sid, parentID: work.id, index: 1)
        try pin("Spec 1", "https://specs.example/1", in: specs.id)
        try pin("A note", NoteURL.make("n1"), in: specs.id)
        try pin("Spec 2", "https://specs.example/2", in: specs.id)
        let a = try s.openTab(url: "https://left.example/", inSpace: sid, title: "Left")
        let b = try s.openTab(url: "https://right.example/", inSpace: sid, title: "Right")
        let x = try s.createSplit([a.id, b.id], inSpace: sid, axis: .horizontal, focused: a.id)
        try s.move(.split(x.id), to: .pinned(spaceID: sid, parentID: work.id, index: 2))
        try pin("Calendar [team]", "https://cal.example/(week)", in: work.id)
        return (s, sid, work.id, specs.id)
    }

    func testFolderMarkdownKeepsTitlesOrderAndNesting() throws {
        let (s, _, work, _) = try workFolder()
        XCTAssertEqual(s.folderLinks(work).map(\.title), ["Docs", "Specs", "Spec 1", "Spec 2", "Left", "Right", "Calendar [team]"],
                       "sidebar order; the note has no link; the split's panes in pane order")
        XCTAssertEqual(s.folderLinksMarkdown(work, clean: LinkCopyPolicy.clean), """
        - [Docs](https://docs.example/)
        - Specs
          - [Spec 1](https://specs.example/1)
          - [Spec 2](https://specs.example/2)
        - [Left](https://left.example/)
        - [Right](https://right.example/)
        - [Calendar \\[team\\]](https://cal.example/%28week%29)
        """)
        XCTAssertEqual(s.folderLinksText(work), "https://docs.example/?utm_source=x\nhttps://specs.example/1\nhttps://specs.example/2\n"
                       + "https://left.example/\nhttps://right.example/\nhttps://cal.example/(week)")
    }

    func testSelectionMarkdownKeepsOrderAndCountsAFoldersRowsOnce() throws {
        let (s, sid, work, specs) = try workFolder()
        let spec1 = try XCTUnwrap(s.children(of: .pinned(spaceID: sid), parent: specs).first)
        let today = try s.openTab(url: "https://today.example/?fbclid=1", inSpace: sid, title: "Today page")
        let md = s.linksMarkdown(of: [.tab(today.id), .item(specs), .item(spec1.id)], current: { t in
            t.id == today.id ? ("https://today.example/live?fbclid=2", "Live title") : nil
        }, clean: LinkCopyPolicy.clean)
        XCTAssertEqual(md, """
        - [Live title](https://today.example/live)
        - Specs
          - [Spec 1](https://specs.example/1)
          - [Spec 2](https://specs.example/2)
        """, "the page's own title and address; Spec 1 is inside the selected folder, so once")
        XCTAssertFalse(s.linksMarkdown(of: [.item(work)]).isEmpty)
    }

    func testExpandAndCollapseAllFoldersReachNestedOnes() throws {
        let (s, sid, work, specs) = try workFolder()
        XCTAssertEqual(try s.setAllFolders(collapsed: true, inSpace: sid), 2)
        XCTAssertEqual([s.item(work)?.isCollapsed, s.item(specs)?.isCollapsed], [true, true])
        XCTAssertEqual(try s.setAllFolders(collapsed: true, inSpace: sid), 0, "nothing left to change")
        try s.toggleFolder(specs)
        XCTAssertEqual(try s.setAllFolders(collapsed: false, inSpace: sid), 1)
        XCTAssertEqual([s.item(work)?.isCollapsed, s.item(specs)?.isCollapsed], [false, false])
        let other = try s.createSpace(name: "Other", profileID: s.selectedSpace.profileID)
        XCTAssertEqual(try s.setAllFolders(collapsed: true, inSpace: other.id), 0, "only the Space's own folders")
    }

    func testResetAllTabsTakesOnlyThisSpacesDriftedPinnedTabs() throws {
        let (s, sid, work, _) = try workFolder()
        let docs = try XCTUnwrap(s.children(of: .pinned(spaceID: sid), parent: work).first)
        let docsTab = try XCTUnwrap(s.liveTab(forItem: docs.id))
        XCTAssertTrue(s.driftedPinnedTabs(inSpace: sid).isEmpty)
        s.updateTab(docsTab.id, url: "https://elsewhere.example/page")
        let split = try XCTUnwrap(s.children(of: .pinned(spaceID: sid), parent: work).first { $0.kind == .split })
        let right = try XCTUnwrap(s.paneTabs(ofSplitItem: split.id).last)
        s.updateTab(right.id, url: "https://right.example/other")
        let today = try s.openTab(url: "https://today.example/", inSpace: sid)
        s.updateTab(today.id, url: "https://today.example/moved")
        XCTAssertEqual(s.driftedPinnedTabs(inSpace: sid).map(\.id), [docsTab.id, right.id], "in folders and splits, in order; never Today")
        _ = try s.resetToSavedURL(docsTab.id)
        XCTAssertEqual(s.driftedPinnedTabs(inSpace: sid).map(\.id), [right.id])
    }
}
