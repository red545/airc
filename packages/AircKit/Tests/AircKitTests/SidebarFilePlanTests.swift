// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// P04 (S14, L07): dropped files, folders, links and text planned and made into sidebar rows in one undo step; the
/// portable Markdown and bookmarks-HTML export. Folder trees are synthetic, in a temporary folder of the test's own.
final class SidebarFilePlanTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("airc-p04-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    @discardableResult
    private func file(_ path: String, _ text: String = "x") throws -> URL {
        let u = root.appendingPathComponent(path)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    private func dir(_ path: String) throws -> URL {
        let u = root.appendingPathComponent(path)
        try fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func titles(_ nodes: [SidebarFilePlan.Node]) -> [String] {
        nodes.map { n in
            switch n {
            case .tab(let t, _): t
            case .folder(let t, let kids): t + "/" + "[" + titles(kids).joined(separator: ",") + "]"
            case .search(let q): "?" + q
            case .note(let t): "note:" + t.prefix(12)
            }
        }
    }

    // MARK: Text and the pasteboard's things

    func testTextIsALinkASearchOrANote() {
        XCTAssertEqual(SidebarFilePlanner.textNodes("https://example.com/a"), [.tab(title: "", url: "https://example.com/a")])
        XCTAssertEqual(SidebarFilePlanner.textNodes("  example.org  "), [.tab(title: "", url: "https://example.org")])
        XCTAssertEqual(SidebarFilePlanner.textNodes("https://a.example\n\nhttps://b.example/x\n"),
                       [.tab(title: "", url: "https://a.example"), .tab(title: "", url: "https://b.example/x")], "lines that are all links: a tab each")
        XCTAssertEqual(SidebarFilePlanner.textNodes("pastel de nata recipe"), [.search(query: "pastel de nata recipe")])
        XCTAssertEqual(SidebarFilePlanner.textNodes("see https://a.example"), [.search(query: "see https://a.example")])
        let long = String(repeating: "word ", count: 50)
        XCTAssertEqual(SidebarFilePlanner.textNodes(long), [.note(text: long.trimmingCharacters(in: .whitespaces))])
        XCTAssertEqual(SidebarFilePlanner.textNodes("Groceries\nmilk\neggs"), [.note(text: "Groceries\nmilk\neggs")])
        XCTAssertEqual(SidebarFilePlanner.textNodes(" \n\t "), [])
    }

    func testPasteboardThingsInOrderWithoutDuplicates() throws {
        let a = try file("a.txt")
        let items = SidebarFilePlanner.items(files: [a, a, URL(string: "https://example.com")!],
                                             links: ["https://example.com", "https://example.com", a.absoluteString, "https://b.example"],
                                             titles: ["Example", "Again"], text: "https://example.com")
        XCTAssertEqual(items, [.file(a.standardizedFileURL), .link("https://example.com", title: "Example"), .link("https://b.example", title: nil)],
                       "files first, then links (a file's own link once, as the file), text left out when there's more")
        XCTAssertEqual(SidebarFilePlanner.items(files: [], links: [], text: "just words"), [.text("just words")])
    }

    // MARK: Folders

    func testFolderBecomesAFolderInFinderOrderWithoutHiddenFiles() throws {
        let photos = try dir("Trip Photos")
        try file("Trip Photos/file 10.txt")
        try file("Trip Photos/file 2.txt")
        try file("Trip Photos/.DS_Store")
        try file("Trip Photos/Day 1/beach.jpg")
        _ = try dir("Trip Photos/Empty")
        let plan = SidebarFilePlanner.plan([.file(photos)])
        XCTAssertEqual(titles(plan.nodes), ["Trip Photos/[Day 1/[beach.jpg],Empty/[],file 2.txt,file 10.txt]"])
        XCTAssertEqual(plan.skipped.hidden, 1)
        XCTAssertEqual(plan.tabCount, 3)
        XCTAssertEqual(plan.folderCount, 3)
        guard case .folder(_, let kids) = plan.nodes[0], case .tab(_, let url) = kids[2] else { return XCTFail("tree") }
        XCTAssertTrue(url.hasPrefix("file://") && url.hasSuffix("Trip%20Photos/file%202.txt"), url)
        XCTAssertFalse(plan.truncated)
    }

    func testLinksAreFollowedOnceCyclesSkippedBrokenLinksCounted() throws {
        let top = try dir("Top")
        let outside = try file("Elsewhere/readme.md")
        try fm.createSymbolicLink(at: top.appendingPathComponent("loop"), withDestinationURL: top)
        try fm.createSymbolicLink(at: try dir("Top/Sub").appendingPathComponent("up"), withDestinationURL: top)
        try fm.createSymbolicLink(at: top.appendingPathComponent("broken"), withDestinationURL: root.appendingPathComponent("nothing-here"))
        try fm.createSymbolicLink(at: top.appendingPathComponent("readme link.md"), withDestinationURL: outside)
        let plan = SidebarFilePlanner.plan([.file(top)])
        XCTAssertEqual(titles(plan.nodes), ["Top/[readme link.md,Sub/[]]"], "the file link stays, the two loops and the broken link go")
        XCTAssertEqual(plan.skipped.cycles, 2)
        XCTAssertEqual(plan.skipped.unreadable, 1)
        guard case .folder(_, let kids) = plan.nodes[0], case .tab(_, let url) = kids[0] else { return XCTFail("tree") }
        XCTAssertTrue(url.hasSuffix("Elsewhere/readme.md"), "a file link opens the file it leads to: \(url)")
    }

    func testBigAndDeepTreesStopAtTheLimits() throws {
        let big = try dir("Big")
        for i in 0..<120 { try file("Big/f\(i).txt") }
        let plan = SidebarFilePlanner.plan([.file(big)], limits: .init(maxTabs: 50))
        XCTAssertEqual(plan.tabCount, 50)
        XCTAssertTrue(plan.truncated)
        var path = "Deep"
        for i in 0..<6 { path += "/d\(i)" }
        try file(path + "/bottom.txt")
        let deep = SidebarFilePlanner.plan([.file(root.appendingPathComponent("Deep"))], limits: .init(maxDepth: 3))
        XCTAssertEqual(titles(deep.nodes), ["Deep/[d0/[d1/[d2/[]]]]"])
        XCTAssertEqual(deep.skipped.tooDeep, 1)
        let few = SidebarFilePlanner.plan([.file(big)], limits: .init(maxEntries: 10))
        XCTAssertTrue(few.truncated)
        XCTAssertLessThanOrEqual(few.tabCount, 10)
    }

    func testCancelledPlanMakesNothing() throws {
        let big = try dir("Big")
        for i in 0..<40 { try file("Big/f\(i).txt") }
        var asked = 0
        let plan = SidebarFilePlanner.plan([.file(big)]) { asked += 1; return asked > 10 }
        XCTAssertTrue(plan.cancelled)
        let s = try makeStore()
        let before = (s.state.tabs.count, s.state.items.count)
        let r = try s.applySidebarFilePlan(plan, to: SidebarFileDestination(spaceID: s.selectedSpace.id), engine: .google)
        XCTAssertEqual(r, SidebarFileResult())
        XCTAssertEqual(before.0, s.state.tabs.count)
        XCTAssertEqual(before.1, s.state.items.count)
    }

    // MARK: Making the rows

    func testMixedDropIntoTodayIsOneUndoStep() throws {
        let s = try makeStore()
        let sid = s.selectedSpace.id
        let existing = try s.openTab(url: "https://old.example", inSpace: sid)
        try file("Recipes/nata.txt")
        let plan = SidebarFilePlanner.plan([.file(try file("menu.pdf")), .file(root.appendingPathComponent("Recipes")),
                                            .link("https://example.com", title: "Example"), .text("lisbon trams"),
                                            .text("Shopping\nflour\nmilk")])
        let before = (s.state.tabs.count, s.state.items.count, s.state.notes.count)
        let r = try s.applySidebarFilePlan(plan, to: SidebarFileDestination(spaceID: sid), engine: .duckDuckGo)
        XCTAssertEqual(r.tabs, 5)
        XCTAssertEqual(r.folders, 1)
        let today = s.todayTabs(ofSpace: sid)
        XCTAssertEqual(today.map(\.title), ["menu.pdf", "Example", "lisbon trams", "Shopping", existing.title],
                       "in the drop's order, at the top of Today, above what was there")
        XCTAssertTrue(today[0].url.hasPrefix("file://"))
        XCTAssertEqual(today[2].url, SearchEngine.duckDuckGo.searchURL(for: "lisbon trams").absoluteString)
        XCTAssertTrue(NoteURL.isNote(today[3].url))
        XCTAssertEqual(s.lastActiveTab(ofSpace: sid)?.id, r.todayTabIDs.first, "the first dropped tab is the one shown")
        let folder = s.pinnedRoots(ofSpace: sid).last
        XCTAssertEqual(folder?.kind, .folder)
        XCTAssertEqual(folder?.title, "Recipes", "a folder goes to the pinned section, as Arc's folders live there")
        XCTAssertEqual(s.children(of: .pinned(spaceID: sid), parent: folder?.id).map(\.pageTitle), ["nata.txt"])
        // One ⌘Z takes all of it back.
        let undone = try s.undo()
        XCTAssertEqual(undone?.label, "Add Files")
        XCTAssertEqual(s.state.tabs.count, before.0)
        XCTAssertEqual(s.state.items.count, before.1)
        XCTAssertEqual(s.state.notes.count, before.2)
    }

    func testDropIntoAPinnedFolderAtAPlace() throws {
        let s = try makeStore()
        let sid = s.selectedSpace.id
        let f = try s.createFolder(named: "Work", inSpace: sid)
        let first = try s.applySidebarFilePlan(SidebarFilePlan(nodes: [.tab(title: "A", url: "https://a.example"), .tab(title: "C", url: "https://c.example")]),
                                               to: SidebarFileDestination(spaceID: sid, section: .pinned(parentID: f.id, index: nil)), engine: .google)
        XCTAssertEqual(first.pinnedItemIDs.count, 2)
        try s.applySidebarFilePlan(SidebarFilePlan(nodes: [.tab(title: "B", url: "https://b.example"),
                                                           .folder(title: "Inner", children: [.search(query: "q")])]),
                                   to: SidebarFileDestination(spaceID: sid, section: .pinned(parentID: f.id, index: 1)), engine: .google)
        let rows = s.children(of: .pinned(spaceID: sid), parent: f.id)
        XCTAssertEqual(rows.map(\.displayTitle), ["A", "B", "Inner", "C"])
        XCTAssertEqual(s.children(of: .pinned(spaceID: sid), parent: rows[2].id).map(\.savedURL),
                       [SearchEngine.google.searchURL(for: "q").absoluteString])
        XCTAssertTrue(s.todayTabs(ofSpace: sid).isEmpty, "a pinned drop makes no Today tabs")
        // Not a folder of this Space: refused, nothing made.
        let count = s.state.items.count
        XCTAssertThrowsError(try s.applySidebarFilePlan(SidebarFilePlan(nodes: [.tab(title: "X", url: "https://x.example")]),
                                                        to: SidebarFileDestination(spaceID: sid, section: .pinned(parentID: rows[0].id, index: nil)),
                                                        engine: .google))
        XCTAssertEqual(s.state.items.count, count)
    }

    // MARK: Export

    func testExportKeepsNamesTreeAndLinksWithoutCredentials() throws {
        let s = try makeStore()
        let sid = s.selectedSpace.id
        try s.updateSpace(sid) { $0.name = "Home"; $0.icon = .emoji("🏡") }
        try s.applySidebarFilePlan(SidebarFilePlan(nodes: [
            .folder(title: "Recipes [weekend]", children: [.tab(title: "Nata & tea", url: "https://user:secret@food.example/nata?x=1"),
                                                           .folder(title: "Inner", children: [.tab(title: "", url: "https://inner.example")])]),
            .tab(title: "Data", url: "data:text/html,hi"),
        ]), to: SidebarFileDestination(spaceID: sid, section: .pinned(parentID: nil, index: nil)), engine: .google)
        let a = try s.openTab(url: "https://a.example/(1)", inSpace: sid, title: "A <b>")
        let b = try s.openTab(url: "https://b.example", inSpace: sid, title: "B")
        _ = try s.createSplit([a.id, b.id], inSpace: sid)
        _ = try s.createNote(inSpace: sid, pinned: false, document: NoteDocument(lines: ["Secret plans", "do not export"]))
        _ = try s.createBlankWindowSpace(from: sid)
        let fav = Item(kind: .tab, container: .favorites(profileID: s.defaultProfile.id), order: 0, savedURL: "https://mail.example", title: "Mail")
        try s.perform(nil) { s.put(fav) }

        let spaces = s.exportAllSpaces()
        XCTAssertEqual(spaces.map(\.name), ["Home"], "a blank window's Space isn't exported")
        let md = SidebarExport.markdown(spaces: spaces, favorites: s.exportFavorites())
        XCTAssertTrue(md.contains("# Favorites (\(s.defaultProfile.name))\n\n- [Mail](https://mail.example)"), md)
        XCTAssertTrue(md.contains("# 🏡 Home\n\n## Pinned\n\n- Recipes \\[weekend\\]\n  - [Nata & tea](https://food.example/nata?x=1)\n  - Inner\n    - ["), md)
        XCTAssertFalse(md.contains("secret") || md.contains("user:"), "no user name or password leaves")
        XCTAssertFalse(md.contains("data:"), "a data: link is left out")
        XCTAssertTrue(md.contains("## Today\n\n- Secret plans (note)\n- [A <b>](https://a.example/%281%29)\n- [B](https://b.example)"), md)
        XCTAssertFalse(md.contains("do not export"), "a note's text stays in the app")

        let html = SidebarExport.html(spaces: spaces, favorites: s.exportFavorites(), title: "Airc")
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE NETSCAPE-Bookmark-file-1>"))
        XCTAssertTrue(html.contains("<DT><H3>Recipes [weekend]</H3>"))
        XCTAssertTrue(html.contains("<DT><A HREF=\"https://food.example/nata?x=1\">Nata &amp; tea</A>"))
        XCTAssertTrue(html.contains("<DT><A HREF=\"https://a.example/(1)\">A &lt;b&gt;</A>"))
        XCTAssertFalse(html.contains("secret") || html.contains("data:") || html.contains("do not export"))
        XCTAssertEqual(html.components(separatedBy: "<DL><p>").count, html.components(separatedBy: "</DL><p>").count, "balanced folders")
        XCTAssertEqual(SidebarExport.exportedURL("javascript:alert(1)"), nil)
        XCTAssertEqual(SidebarExport.exportedURL("https://u@h.example/p"), "https://h.example/p")
        XCTAssertEqual(SidebarExport.exportedURL("https://h.example/p"), "https://h.example/p")
    }
}
