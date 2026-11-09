// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script parityp01` (P01a, docs/qa/parity-audit.md row 1), both engines, loopback pages only and the run's own
/// pasteboard (never the person's clipboard). Home has Today A over a split of B and C, pinned P and Draft, folder Work
/// (Doc 1, a nested Specs with Spec 1 and Spec 2, Doc 2), Favorite F; a second Space, Office.
///   1. Each context's menu as the row builds it, after the menu's own validation: titles, ⌥ alternates, enabled
///      states and submenus (Today, pinned away from its URL, pinned unloaded, Favorite, folder, a split pane, a
///      multi-selection), written to parityp01-menus.json, and the main menu's new items.
///   2. Copy: a row's Copy Link drops trackers ("Copied a clean link without trackers"); with a Peek open, Copy URL,
///      Markdown and Quote take the Peek's page; in a split, the focused pane. A Quote whose selection arrives late
///      writes nothing after another copy, a tab switch or the Peek closing, and writes when nothing changed.
///   3. Share: the menus' Share › carry exactly the chosen links (one row, the selection in order, without trackers);
///      the system's sharing path is run with a service of the check's own, which opens nothing.
///   4. Folder: Copy All Links as Markdown keeps titles, order and nesting; Expand/Collapse All Folders.
///   5. Reset: a page with unsaved input asks "Leave site?" first; Cancel keeps the page and its input, Leave goes back
///      to the saved URL with no second question from the engine. "Reset all tabs in this Space" from the main menu:
///      one question for the page that would ask; Reset Others, then Reset All.
///   6. Command Bar: every new action is offered where it applies, and one runs from there.
extension SnapshotRunner {
    private final class P01 {
        var base = ""
        var server: LocalPageServer?
        var home = "", office = ""
        /// Name → tab ID (Today, or the live page of a pinned row / Favorite) and name → item ID.
        var tab: [String: String] = [:], item: [String: String] = [:]
        let board = NSPasteboard.withUniqueName()
        var oldBoard: NSPasteboard = .general
        var menus: [String: Any] = [:]
        var shared: [[URL]] = []
        func url(_ path: String) -> String { base + path }
    }

    func parityP01Scenario() {
        let k = P01()
        p01SetUp(k)
        p01Menus(k)
        p01Copy(k)
        p01Share(k)
        p01Folders(k)
        p01Reset(k)
        p01CommandBar(k)
        p01QuoteLink(k)
        p01TodayIcon(k)
        run { [self] in
            WindowController.copyWatchPasteboard = .general
            WindowController.linkPasteboard = k.oldBoard
            WindowController.quoteAnswerDelay = 0
            SelectionShare.testService = nil
            SelectionShare.testShared = nil
            k.board.releaseGlobally()
            k.server?.stop()
            if let data = try? JSONSerialization.data(withJSONObject: k.menus, options: [.prettyPrinted, .sortedKeys]) {
                let engine = app?.engine.name.split(separator: " ").first.map { $0.lowercased() } ?? "engine"
                try? data.write(to: dir.appendingPathComponent("parityp01-menus-\(engine).json"))
            }
            note("parityp01: done on \(app?.engine.name ?? "?") (window key \(c.window.isKeyWindow), active Space \(c.window.isOnActiveSpace))")
        }
    }

    // MARK: Fixture

    private func p01SetUp(_ k: P01) {
        step { [self] done in
            func page(_ title: String, _ body: String = "") -> String {
                "<!doctype html><title>\(title)</title><body style='font:28px -apple-system;padding:40px'><p id=q>\(title) words</p>\(body)"
            }
            var pages: [String: String] = [:]
            for (path, title) in [("/a.html", "Alpha"), ("/b.html", "Bravo"), ("/c.html", "Charlie"), ("/p.html", "Pinned P"),
                                  ("/p2.html", "P elsewhere"), ("/f.html", "Fav F"), ("/d1.html", "Doc 1"), ("/d2.html", "Doc 2"),
                                  ("/s1.html", "Spec 1"), ("/s1b.html", "Spec 1 moved"), ("/s2.html", "Spec 2"),
                                  ("/peek.html", "Peek page"), ("/draft.html", "Draft home")] {
                pages[path] = page(title)
            }
            // Unsaved input asks before the page is left (only once the person used the page, as browsers do).
            pages["/dirty.html"] = page("Dirty", "<input id=f><script>onbeforeunload=function(e){if(document.getElementById('f').value)"
                                        + "{e.preventDefault();e.returnValue=''}}</script>")
            k.server = LocalPageServer(pages: pages)
            k.server?.start { port in
                guard let port else { self.check(false, "parityp01: the loopback page server starts"); return self.finish() }
                k.base = "http://127.0.0.1:\(port)"
                let s = self.c.store
                k.home = s.selectedSpace.id
                try? s.updateSpace(k.home) { $0.name = "Home" }
                k.office = (try? s.createSpace(name: "Office", icon: .emoji("🏢"), profileID: s.selectedSpace.profileID, after: k.home).id) ?? ""
                func pin(_ name: String, _ path: String, parent: String? = nil, loaded: Bool) {
                    guard let t = try? s.openTab(url: k.url(path), inSpace: k.home, title: name) else { return }
                    let at = s.children(of: .pinned(spaceID: k.home), parent: parent).count
                    try? s.move(.tab(t.id), to: .pinned(spaceID: k.home, parentID: parent, index: at))
                    guard let iid = s.tab(t.id)?.itemID else { return }
                    try? s.renameItem(iid, to: name)
                    k.item[name] = iid
                    if loaded { k.tab[name] = t.id } else { _ = try? s.closeTab(t.id) }
                }
                pin("P", "/p.html", loaded: true)
                pin("Draft", "/draft.html", loaded: true)
                if let f = try? s.createFolder(named: "Work", inSpace: k.home) { k.item["Work"] = f.id }
                pin("Doc 1", "/d1.html", parent: k.item["Work"], loaded: false)
                if let f = try? s.createFolder(named: "Specs", inSpace: k.home, parentID: k.item["Work"], index: 1) { k.item["Specs"] = f.id }
                pin("Spec 1", "/s1.html", parent: k.item["Specs"], loaded: true)
                pin("Spec 2", "/s2.html", parent: k.item["Specs"], loaded: false)
                pin("Doc 2", "/d2.html", parent: k.item["Work"], loaded: false)
                if let t = try? s.openTab(url: k.url("/f.html"), inSpace: k.home, title: "Fav F") {
                    try? s.move(.tab(t.id), to: .favorites(profileID: s.selectedSpace.profileID, index: 0))
                    k.tab["F"] = t.id
                    k.item["F"] = s.tab(t.id)?.itemID
                }
                for n in ["Charlie", "Bravo", "Alpha"] {
                    k.tab[n] = try? s.openTab(url: k.url("/\(n.lowercased().prefix(1)).html"), inSpace: k.home, title: n).id
                }
                _ = try? s.createSplit([k.tab["Bravo"] ?? "", k.tab["Charlie"] ?? ""], inSpace: k.home, axis: .horizontal,
                                       focused: k.tab["Charlie"])
                k.oldBoard = WindowController.linkPasteboard
                WindowController.linkPasteboard = k.board
                self.c.switchToSpace(k.home, animated: false)
                self.c.reloadAll(animated: false)
                for n in ["P", "Draft", "Spec 1", "F", "Bravo", "Charlie"] { self.c.loadPageInBackground(k.tab[n] ?? "") }
                self.c.show(k.tab["Alpha"] ?? "", focus: false)
                done()
            }
        }
        step { [self] done in
            waitUntil({ ["Alpha": "Alpha", "P": "Pinned P", "F": "Fav F", "Spec 1": "Spec 1", "Draft": "Draft home"]
                .allSatisfy { self.c.engineTab(for: k.tab[$0.key] ?? "")?.title == $0.value } }, timeout: 12) {
                let missing = ["Alpha", "P", "F", "Spec 1", "Draft"].filter { self.c.engineTab(for: k.tab[$0] ?? "")?.isLoading != false }
                self.note("parityp01: fixture pages loaded on \(self.app?.engine.name ?? "?")" + (missing.isEmpty ? "" : " (still loading: \(missing))"))
                done()
            }
        }
        // P moves away from its saved URL, to an address with trackers.
        step { [self] done in
            guard let p = c.engineTab(for: k.tab["P"] ?? ""), let u = URL(string: k.url("/p2.html?id=7&utm_source=check&fbclid=x")) else { return done() }
            c.engineWindow.load(u, in: p)
            waitUntil({ p.title == "P elsewhere" && self.c.store.isDrifted(k.tab["P"] ?? "") }, timeout: 8) { done() }
        }
    }

    // MARK: Menus

    /// A menu as the person sees it: after its own validation, each item's title, ⌥ alternate, state, enabled and
    /// submenu.
    private func p01Model(_ m: NSMenu?) -> [[String: Any]] {
        guard let m else { return [] }
        m.update()
        return m.items.map { i in
            if i.isSeparatorItem { return ["title": "—"] }
            var d: [String: Any] = ["title": i.title, "enabled": i.isEnabled]
            if i.isAlternate { d["alternate"] = true }
            if i.state == .on { d["on"] = true }
            if !i.toolTip.isNilOrEmpty { d["hint"] = i.toolTip! }
            if let sub = i.submenu, SelectionShare.of(i) == nil { d["submenu"] = p01Model(sub) }
            if let share = SelectionShare.of(i) { d["share"] = share.urls.map(\.absoluteString) }
            return d
        }
    }

    private func p01Titles(_ model: [[String: Any]], alternates: Bool = false) -> [String] {
        model.filter { alternates || $0["alternate"] == nil }.compactMap { $0["title"] as? String }
    }

    private func p01Enabled(_ model: [[String: Any]], _ title: String) -> Bool? {
        model.first { $0["title"] as? String == title }?["enabled"] as? Bool
    }

    private func p01Entry(_ k: P01, _ name: String) -> SidebarEntry? {
        let s = c.store
        if name == "Work", let f = s.item(k.item["Work"]) { return .folder(f, depth: 0) }
        if let t = s.tab(k.tab[name] ?? ""), t.isToday { return .today(t) }
        guard let i = s.item(k.item[name]) else { return nil }
        return i.isFavorite ? .favorite(i, s.liveTab(forItem: i.id)) : .pinned(i, depth: 0, s.liveTab(forItem: i.id))
    }

    private func p01Menus(_ k: P01) {
        run { [self] in
            let boosts = c.boostsAvailable
            func model(_ name: String) -> [[String: Any]] {
                let m = p01Model(p01Entry(k, name).map { c.menu(for: $0) })
                k.menus[name] = m
                return m
            }
            // Today (Arc 1.170's Today tab menu, plus Pin and Favorites as Airc's rows offer them).
            let today = model("Alpha")
            check(p01Titles(today) == ["Copy Link", "Share", "Change Icon…", "Rename…", "Mute", "Customize Page…", "Add Split View", "Duplicate", "Move to",
                                       "Move to New Window", "—", "Pin Tab", "Add to Favorites", "—", "Archive Tab", "Archive Tabs Below"]
                  && p01Titles(today, alternates: true).contains("Copy Link as Markdown"),
                  "parityp01: Today tab menu: Arc's actions in Arc's order (\(p01Titles(today, alternates: true).joined(separator: ", ")))")
            check(p01Enabled(today, "Customize Page…") == boosts && p01Enabled(today, "Archive Tabs Below") == true
                  && p01Enabled(today, "Copy Link") == true,
                  "parityp01: Today tab menu: Customize Page… only where Boosts run (\(p01Enabled(today, "Customize Page…") ?? false)), "
                  + "Archive Tabs Below with tabs below (\(p01Enabled(today, "Archive Tabs Below") ?? false))")
            // Pinned, away from its saved URL, loaded.
            let pinned = model("P")
            let edit = pinned.first { $0["title"] as? String == "Edit Pinned Page" }?["submenu"] as? [[String: Any]] ?? []
            check(p01Titles(pinned) == ["Copy Link", "Share", "Change Icon…", "Rename…", "Edit Pinned Page", "Back to Pinned URL", "Mute", "Customize Page…",
                                        "Open in Split View", "Duplicate", "Move to", "—", "Unpin", "Add to Favorites", "Close and Keep Pinned", "Delete"]
                  && p01Titles(edit) == ["Replace Pinned URL with Current", "Edit…"] && p01Enabled(edit, "Replace Pinned URL with Current") == true,
                  "parityp01: pinned tab away from its URL: Back to Pinned URL, Edit Pinned Page › Replace (enabled), Mute, Move to "
                  + "(\(p01Titles(pinned).joined(separator: ", ")); › \(p01Titles(edit).joined(separator: ", ")))")
            let moveTo = pinned.first { $0["title"] as? String == "Move to" }?["submenu"] as? [[String: Any]] ?? []
            check(p01Titles(moveTo).first?.hasSuffix("Office") == true && !p01Titles(moveTo).contains { $0.hasSuffix("Home") },
                  "parityp01: pinned tab: Move to › lists the other Spaces (\(p01Titles(moveTo).joined(separator: ", ")))")
            // Pinned, at its URL, unloaded.
            let unloaded = model("Doc 2")
            let edit2 = unloaded.first { $0["title"] as? String == "Edit Pinned Page" }?["submenu"] as? [[String: Any]] ?? []
            check(!p01Titles(unloaded).contains("Back to Pinned URL") && !p01Titles(unloaded).contains("Mute")
                  && !p01Titles(unloaded).contains("Close and Keep Pinned") && p01Enabled(edit2, "Replace Pinned URL with Current") == false
                  && p01Titles(unloaded).contains("Share"),
                  "parityp01: unloaded pinned tab at its URL: no Back, Mute or Close; Replace disabled; Share its saved URL "
                  + "(\(p01Titles(unloaded).joined(separator: ", ")))")
            // Favorite.
            let fav = model("F")
            check(p01Titles(fav) == ["Copy Link", "Share", "Change Icon…", "Edit Pinned Page", "Mute", "Customize Page…", "Open in Split View", "—", "Remove from Favorites",
                                     "Close and Keep in Favorites", "Delete Favorite"],
                  "parityp01: Favorite menu (\(p01Titles(fav).joined(separator: ", ")))")
            // A Favorite on a site that counts unread items (built in memory: nothing loads): Arc's "Show Unread Badge",
            // on until turned off, kept in the settings.
            let gmail = Item(kind: .tab, container: .favorites(profileID: c.store.selectedSpace.profileID), savedURL: "https://mail.google.com/mail/u/0/",
                             title: "Mail")
            let badge = { self.p01Model(self.c.menu(for: .favorite(gmail, nil))).first { $0["title"] as? String == "Show Unread Badge" } }
            let wasOn = badge()?["on"] as? Bool == true
            _ = p01Fire(c.menu(for: .favorite(gmail, nil)), ["Show Unread Badge"])
            let off = !c.showsUnreadBadge(gmail) && badge()?["on"] == nil && app?.settings.values.sidebarItems.noUnreadBadge.contains(gmail.id) == true
            _ = p01Fire(c.menu(for: .favorite(gmail, nil)), ["Show Unread Badge"])
            check(wasOn && off && c.showsUnreadBadge(gmail) && p01Enabled(fav, "Show Unread Badge") == nil,
                  "parityp01: Show Unread Badge on a badging Favorite: on, off (saved), on again; not offered for other sites")
            // Folder.
            let folder = model("Work")
            // P01c (55939bc) added Reset all tabs in this Folder, Move to › and Turn into Space (ParityP01cCheck covers them).
            check(p01Titles(folder) == ["Rename…", "Change Icon…", "—", "Copy All Links", "Copy All Links as Markdown", "—", "Duplicate",
                                        "New Nested Folder", "Reset all tabs in this Folder", "Move to", "Turn into Space", "—",
                                        "Delete Folder"] && p01Enabled(folder, "Copy All Links as Markdown") == true,
                  "parityp01: folder menu (\(p01Titles(folder).joined(separator: ", ")))")
            // A split pane (the split row's menu opened over Charlie's segment).
            if let x = c.store.split(containing: k.tab["Charlie"]) {
                let tabs = x.tabIDs.compactMap { c.store.tab($0) }
                let pane = p01Model(c.menu(for: .split(x, tabs), pane: k.tab["Charlie"]))
                k.menus["split pane"] = pane
                let share = pane.first { $0["title"] as? String == "Share" }?["share"] as? [String]
                check(p01Titles(pane, alternates: true).starts(with: ["Copy Link", "Copy Link as Markdown", "Share"]) && share == [k.url("/c.html")],
                      "parityp01: split pane menu: Copy Link, ⌥ as Markdown, Share › with the pane's page (\(share ?? []))")
            } else {
                check(false, "parityp01: the fixture's Today split exists")
            }
            // Multi-selection: Alpha and pinned P.
            let ids = [k.item["P"], k.tab["Alpha"]].compactMap { $0 }
            let sel = p01Model(c.selectionMenu(ids: ids, spaceID: k.home))
            k.menus["selection"] = sel
            let share = sel.first { $0["title"] as? String == "Share" }?["share"] as? [String]
            check(p01Titles(sel, alternates: true).starts(with: ["Copy 2 Links", "Copy 2 Links as Markdown", "Share"])
                  && share == [k.url("/p2.html?id=7"), k.url("/a.html")],
                  "parityp01: selection menu: ⌥ Markdown and Share › with exactly the selected pages, in order, without trackers (\(share ?? []))")
            // P04's registrations (the panels themselves are P04's check): + › Add Files…, the Space menu's Export Space…,
            // File › Export All Spaces…, and the same three in the Command Bar.
            let plus = p01Model(c.plusMenu()), space = p01Model(c.spaceMenu(spaceID: k.home))
            let file = NSApp.mainMenu?.items.first { $0.submenu?.title == "File" }?.submenu
            let cb = c.commandActions().map(\.title)
            check(p01Enabled(plus, "Add Files…") == true && p01Enabled(space, "Export Space…") == true
                  && file?.items.contains { $0.title == "Export All Spaces…" } == true
                  && ["Add Files…", "Export Space…", "Export All Spaces…"].allSatisfy(cb.contains),
                  "parityp01: Add Files… (+ menu), Export Space… (Space menu), File › Export All Spaces…, and all three in the Command Bar")
            // The main menu's new items.
            let all = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items) ?? []
            let found = ["Share", "Reset all tabs in this Space", "Expand All Folders", "Collapse All Folders"].filter { t in all.contains { $0.title == t } }
            check(found.count == 4, "parityp01: main menu has File › Share and Tabs › Reset all tabs in this Space, Expand/Collapse All Folders (\(found))")
        }
    }

    // MARK: Copy

    private func p01Fire(_ menu: NSMenu?, _ path: [String]) -> Bool {
        var m = menu
        for (i, title) in path.enumerated() {
            m?.update()
            guard let idx = m?.items.firstIndex(where: { $0.title == title }), let item = m?.items[idx] else { return false }
            if i == path.count - 1 {
                guard item.isEnabled else { return false }
                m?.performActionForItem(at: idx)
                return true
            }
            m = item.submenu
        }
        return false
    }

    private func p01Copy(_ k: P01) {
        run { [self] in
            k.board.clearContents()
            let fired = p01Fire(p01Entry(k, "P").map { c.menu(for: $0) }, ["Copy Link"])
            check(fired && k.board.string(forType: .string) == k.url("/p2.html?id=7") && c.toast.shownText == "Copied a clean link without trackers",
                  "parityp01: pinned Copy Link copies its page without trackers, Arc's toast (\(k.board.string(forType: .string) ?? "-"), \(c.toast.shownText ?? "-"))")
            _ = p01Fire(p01Entry(k, "Alpha").map { c.menu(for: $0) }, ["Copy Link as Markdown"])
            check(k.board.string(forType: .string) == "[Alpha](\(k.url("/a.html")))", "parityp01: Today ⌥ Copy Link as Markdown (\(k.board.string(forType: .string) ?? "-"))")
        }
        // Peek over Favorite F: the copies take the Peek's page.
        step { [self] done in
            guard let f = k.tab["F"], let opener = c.engineTab(for: f), let u = URL(string: k.url("/peek.html")) else { return done() }
            c.show(f, focus: false)
            c.openPeek(u, from: opener)
            waitUntil({ self.c.peek?.page.title == "Peek page" && self.c.peek?.page.isLoading == false }, timeout: 8) { done() }
        }
        run { [self] in
            guard c.peek != nil else { return check(false, "parityp01: a Peek opens over Favorite F") }
            let edit = NSApp.mainMenu?.items.first { $0.submenu?.title == "Edit" }?.submenu
            let viaMenu = p01Fire(edit, ["Copy URL"])
            check(viaMenu && k.board.string(forType: .string) == k.url("/peek.html"),
                  "parityp01: Edit › Copy URL with a Peek open copies the Peek's page (\(k.board.string(forType: .string) ?? "-"))")
            c.copyURLMarkdown()
            check(k.board.string(forType: .string) == "[Peek page](\(k.url("/peek.html")))", "parityp01: Copy URL as Markdown in a Peek (\(k.board.string(forType: .string) ?? "-"))")
            check(c.shareLinks == [k.url("/peek.html")], "parityp01: Share takes the Peek's page (\(c.shareLinks))")
        }
        step { [self] done in
            c.peek?.page.evaluate("var r=document.createRange();r.selectNodeContents(document.getElementById('q'));getSelection().removeAllRanges();getSelection().addRange(r);true") { _ in done() }
        }
        step { [self] done in
            c.copyURLQuote()
            let want = URLRules.markdownQuote(title: "Peek page", url: k.url("/peek.html"), selection: "Peek page words")
            waitUntil({ k.board.string(forType: .string) == want }, timeout: 3) {
                self.check(k.board.string(forType: .string) == want, "parityp01: Copy URL as Quote in a Peek quotes the Peek's selection")
                done()
            }
        }
        // A late Quote: the Peek closes first.
        p01LateQuote(k, "the Peek closed") { self.c.closePeek() }
        step { [self] done in waitUntil({ self.c.peek == nil }, timeout: 4) { done() } }
        // A late Quote: another tab came to the front.
        run { [self] in c.show(k.tab["Alpha"] ?? "", focus: false) }
        wait(0.3)
        p01LateQuote(k, "another tab came to the front") { self.c.show(k.tab["F"] ?? "", focus: false) }
        // A late Quote: a later copy is the one that stays.
        p01LateQuote(k, "a later Copy URL", later: true) { self.c.copyURL() }
        // Nothing changed: the late answer is written.
        step { [self] done in
            WindowController.quoteAnswerDelay = 0.6
            k.board.clearContents()
            c.copyURLQuote()
            waitUntil({ k.board.string(forType: .string)?.hasPrefix("> ") == true }, timeout: 3) {
                WindowController.quoteAnswerDelay = 0
                self.check(k.board.string(forType: .string)?.hasSuffix("(\(k.url("/f.html")))") == true,
                           "parityp01: a late Quote with nothing changed is written (\(k.board.string(forType: .string)?.suffix(60) ?? "-"))")
                done()
            }
        }
        // In a split, the focused pane.
        step { [self] done in
            c.show(k.tab["Charlie"] ?? "", focus: false)
            waitUntil({ self.c.shownSplitID != nil && self.c.engineTab(for: k.tab["Charlie"] ?? "")?.title == "Charlie" }, timeout: 6) { done() }
        }
        run { [self] in
            c.copyURL()
            check(c.shownSplitID != nil && k.board.string(forType: .string) == k.url("/c.html"),
                  "parityp01: Copy URL in a split copies the focused pane (\(k.board.string(forType: .string) ?? "-"))")
            c.show(k.tab["Alpha"] ?? "", focus: false)
        }
    }

    /// Copy URL as Quote whose selection arrives 0.8 s late, `change` right after asking: nothing is written over what
    /// the clipboard has then.
    private func p01LateQuote(_ k: P01, _ what: String, later: Bool = false, change: @escaping () -> Void) {
        var before = 0, text: String?
        step { [self] done in
            WindowController.quoteAnswerDelay = 0.8
            c.copyURLQuote()
            change()
            before = k.board.changeCount
            text = k.board.string(forType: .string)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { done() }
        }
        run { [self] in
            WindowController.quoteAnswerDelay = 0
            let kept = k.board.changeCount == before && k.board.string(forType: .string) == text
            check(kept && (!later || text?.hasPrefix("> ") == false),
                  "parityp01: a late Quote writes nothing after \(what) (clipboard \(kept ? "unchanged" : "overwritten"): \(k.board.string(forType: .string)?.prefix(50) ?? "-"))")
        }
    }

    // MARK: Share

    private func p01Share(_ k: P01) {
        run { [self] in
            let service = NSSharingService(title: "Airc Check Share", image: NSImage(size: NSSize(width: 16, height: 16)), alternateImage: nil) {}
            SelectionShare.testService = service
            SelectionShare.testShared = { title, items in if title == "Airc Check Share" { k.shared.append(items.compactMap { $0 as? URL }) } }
            func share(_ menu: NSMenu?) -> (SelectionShare?, Bool) {
                guard let item = menu?.items.first(where: { SelectionShare.of($0) != nil }), let s = SelectionShare.of(item) else { return (nil, false) }
                // The system's own submenu, when it lists the services already; else the share runs the service directly.
                if let sub = item.submenu {
                    sub.delegate?.menuNeedsUpdate?(sub)
                    sub.update()
                    if let i = sub.items.firstIndex(where: { $0.title == "Airc Check Share" }) { sub.performActionForItem(at: i); return (s, true) }
                }
                s.perform(service)
                return (s, false)
            }
            k.shared = []
            let (one, viaMenu1) = share(p01Entry(k, "P").map { c.menu(for: $0) })
            let (sel, viaMenu2) = share(c.selectionMenu(ids: [k.item["P"], k.item["Doc 1"], k.tab["Alpha"]].compactMap { $0 }, spaceID: k.home))
            note("parityp01: share runs through \(viaMenu1 || viaMenu2 ? "the system's Share submenu" : "the share's own picker items (the submenu fills only when shown)")")
            let want1 = [k.url("/p2.html?id=7")], want2 = [k.url("/p2.html?id=7"), k.url("/d1.html"), k.url("/a.html")]
            check(one?.urls.map(\.absoluteString) == want1 && k.shared.first?.map(\.absoluteString) == want1,
                  "parityp01: a row's Share › receives exactly its page, without trackers (\(k.shared.first ?? []))")
            check(sel?.urls.map(\.absoluteString) == want2 && k.shared.dropFirst().first?.map(\.absoluteString) == want2,
                  "parityp01: a selection's Share › receives exactly the selected rows' links, in order (\(k.shared.dropFirst().first ?? []))")
            let file = NSApp.mainMenu?.items.first { $0.submenu?.title == "File" }?.submenu
            file?.update()
            check(file?.items.first { $0.title == "Share" }?.isEnabled == true, "parityp01: File › Share is enabled with a page on screen")
        }
    }

    // MARK: Folders

    private func p01Folders(_ k: P01) {
        run { [self] in
            k.board.clearContents()
            _ = p01Fire(p01Entry(k, "Work").map { c.menu(for: $0) }, ["Copy All Links as Markdown"])
            let want = "- [Doc 1](\(k.url("/d1.html")))\n- Specs\n  - [Spec 1](\(k.url("/s1.html")))\n  - [Spec 2](\(k.url("/s2.html")))\n- [Doc 2](\(k.url("/d2.html")))"
            check(k.board.string(forType: .string) == want, "parityp01: Copy All Links as Markdown keeps titles, order and nesting (\(k.board.string(forType: .string) ?? "-"))")
            _ = p01Fire(p01Entry(k, "Work").map { c.menu(for: $0) }, ["Copy All Links"])
            check(k.board.string(forType: .string) == ["/d1.html", "/s1.html", "/s2.html", "/d2.html"].map(k.url).joined(separator: "\n"),
                  "parityp01: Copy All Links: one per line in sidebar order, nested folders too")
            let tabs = NSApp.mainMenu?.items.first { $0.submenu?.title == "Tabs" }?.submenu
            let collapsed = p01Fire(tabs, ["Collapse All Folders"])
            let both = [k.item["Work"], k.item["Specs"]].map { c.store.item($0)?.isCollapsed }
            tabs?.update()
            let collapseOff = tabs?.items.first { $0.title == "Collapse All Folders" }?.isEnabled
            let expanded = p01Fire(tabs, ["Expand All Folders"])
            let after = [k.item["Work"], k.item["Specs"]].map { c.store.item($0)?.isCollapsed }
            check(collapsed && both == [true, true] && collapseOff == false && expanded && after == [false, false],
                  "parityp01: Tabs › Collapse All Folders closes nested ones too, is then disabled; Expand All Folders opens them")
        }
    }

    // MARK: Reset

    /// The person uses the page (a click: browsers only ask "Leave site?" on a page that was used) and types into it.
    private func p01Dirty(_ k: P01, _ name: String, _ done: @escaping () -> Void) {
        guard let p = c.engineTab(for: k.tab[name] ?? "") else { return done() }
        func fill() {
            p.evaluate("document.getElementById('f').value='unsaved words';navigator.userActivation?navigator.userActivation.hasBeenActive:true") { v in
                self.note("parityp01: \(name) has unsaved input; used by the person: \((v as? Bool) == true)")
                done()
            }
        }
        #if canImport(AircCore)
        if let engine = app?.engine as? ChromiumEngine {
            engine.devToolsCall("Runtime.evaluate", params: ["expression": "1", "userGesture": true, "returnByValue": true], in: p) { _, _ in fill() }
            return
        }
        #endif
        let pt = c.card.convert(NSPoint(x: c.card.bounds.midX, y: c.card.bounds.midY), to: nil)
        click(at: pt, in: c.window) { fill() }
    }

    private func p01Reset(_ k: P01) {
        // Draft goes to the page with unsaved input.
        step { [self] done in
            guard let d = k.tab["Draft"], let p = c.engineTab(for: d), let u = URL(string: k.url("/dirty.html")) else { return done() }
            c.show(d, focus: false)
            c.engineWindow.load(u, in: p)
            waitUntil({ p.title == "Dirty" && p.isLoading == false && self.c.store.isDrifted(d) }, timeout: 8) { done() }
        }
        step { [self] done in p01Dirty(k, "Draft", done) }
        // Back to Pinned URL from the row's menu: the question first.
        step { [self] done in
            WindowController.lastResetAlert = nil
            _ = p01Fire(p01Entry(k, "Draft").map { c.menu(for: $0) }, ["Back to Pinned URL"])
            waitUntil({ WindowController.lastResetAlert != nil && self.c.window.attachedSheet != nil }, timeout: 3) {
                let a = WindowController.lastResetAlert
                let p = self.c.engineTab(for: k.tab["Draft"] ?? "")
                self.check(a?.messageText == "Leave site?" && a?.informativeText == "Changes you made may not be saved."
                           && a?.buttons.map(\.title) == ["Leave", "Cancel"] && p?.title == "Dirty",
                           "parityp01: reset of a page with unsaved input asks \"\(a?.messageText ?? "nothing")\" first (\(a?.buttons.map(\.title) ?? [])), page still \(p?.title ?? "-")")
                a?.buttons.dropFirst().first?.performClick(nil)
                done()
            }
        }
        wait(0.8)
        step { [self] done in
            let d = k.tab["Draft"] ?? ""
            c.engineTab(for: d)?.evaluate("document.getElementById('f').value") { v in
                self.check(self.c.engineTab(for: d)?.title == "Dirty" && (v as? String) == "unsaved words" && self.c.store.isDrifted(d)
                           && self.c.window.attachedSheet == nil && self.p01EngineDialogs(d) == 0,
                           "parityp01: Cancel keeps the page, its input and its \"/\" (\(self.c.engineTab(for: d)?.title ?? "-"), \(v as? String ?? "-"))")
                done()
            }
        }
        step { [self] done in
            WindowController.lastResetAlert = nil
            c.resetToSaved(k.tab["Draft"] ?? "", keepCurrent: false)
            waitUntil({ WindowController.lastResetAlert != nil }, timeout: 3) {
                WindowController.lastResetAlert?.buttons.first?.performClick(nil)
                let d = k.tab["Draft"] ?? ""
                self.waitUntil({ self.c.engineTab(for: d)?.title == "Draft home" }, timeout: 6) {
                    self.check(self.c.engineTab(for: d)?.title == "Draft home" && !self.c.store.isDrifted(d) && self.p01EngineDialogs(d) == 0,
                               "parityp01: Leave goes back to the saved URL, and the engine doesn't ask again (\(self.c.engineTab(for: d)?.title ?? "-"), dialogs \(self.p01EngineDialogs(d)))")
                    done()
                }
            }
        }
        // A page with nothing unsaved goes back at once.
        step { [self] done in
            let p = k.tab["P"] ?? ""
            _ = p01Fire(p01Entry(k, "P").map { c.menu(for: $0) }, ["Back to Pinned URL"])
            waitUntil({ self.c.engineTab(for: p)?.title == "Pinned P" }, timeout: 6) {
                self.check(self.c.engineTab(for: p)?.title == "Pinned P" && !self.c.store.isDrifted(p) && self.c.window.attachedSheet == nil,
                           "parityp01: Back to Pinned URL on a page with nothing unsaved goes back without asking")
                done()
            }
        }
        // Reset all tabs in this Space: P and Spec 1 away, Draft away with unsaved input.
        step { [self] done in
            let moves: [(String, String, String)] = [("P", "/p2.html", "P elsewhere"), ("Spec 1", "/s1b.html", "Spec 1 moved"), ("Draft", "/dirty.html", "Dirty")]
            for (n, path, _) in moves { if let p = c.engineTab(for: k.tab[n] ?? ""), let u = URL(string: k.url(path)) { c.engineWindow.load(u, in: p) } }
            c.show(k.tab["Alpha"] ?? "", focus: false)
            waitUntil({ moves.allSatisfy { m in self.c.engineTab(for: k.tab[m.0] ?? "")?.title == m.2 && self.c.store.isDrifted(k.tab[m.0] ?? "") } }, timeout: 8) { done() }
        }
        step { [self] done in
            c.show(k.tab["Draft"] ?? "", focus: false)
            p01Dirty(k, "Draft") { self.c.show(k.tab["Alpha"] ?? "", focus: false); done() }
        }
        step { [self] done in
            WindowController.lastResetAlert = nil
            let tabs = NSApp.mainMenu?.items.first { $0.submenu?.title == "Tabs" }?.submenu
            let fired = p01Fire(tabs, ["Reset all tabs in this Space"])
            waitUntil({ WindowController.lastResetAlert != nil }, timeout: 3) {
                let a = WindowController.lastResetAlert
                self.check(fired && a?.messageText == "Reset all tabs in this Space?" && a?.buttons.map(\.title) == ["Reset All", "Cancel", "Reset Others"],
                           "parityp01: Tabs › Reset all tabs in this Space asks once for the page with unsaved input (\(a?.informativeText ?? "no question"))")
                a?.buttons.last?.performClick(nil)
                self.waitUntil({ ["P": "Pinned P", "Spec 1": "Spec 1"].allSatisfy { self.c.engineTab(for: k.tab[$0.key] ?? "")?.title == $0.value } }, timeout: 6) {
                    let titles = ["P", "Spec 1", "Draft"].map { self.c.engineTab(for: k.tab[$0] ?? "")?.title ?? "-" }
                    self.check(titles == ["Pinned P", "Spec 1", "Dirty"] && self.c.shownTabID == k.tab["Alpha"],
                               "parityp01: Reset Others: the others go back, the page with unsaved input stays, the tab on screen stays (\(titles))")
                    done()
                }
            }
        }
        step { [self] done in
            WindowController.lastResetAlert = nil
            c.resetAllTabsInSpace()
            waitUntil({ WindowController.lastResetAlert != nil }, timeout: 3) {
                WindowController.lastResetAlert?.buttons.first?.performClick(nil)
                let d = k.tab["Draft"] ?? ""
                self.waitUntil({ self.c.engineTab(for: d)?.title == "Draft home" }, timeout: 6) {
                    self.check(self.c.store.driftedPinnedTabs(inSpace: k.home).isEmpty && self.p01EngineDialogs(d) == 0,
                               "parityp01: Reset All: every pinned tab of the Space is back at its saved URL, no engine question")
                    let tabs = NSApp.mainMenu?.items.first { $0.submenu?.title == "Tabs" }?.submenu
                    tabs?.update()
                    self.check(tabs?.items.first { $0.title == "Reset all tabs in this Space" }?.isEnabled == false,
                               "parityp01: with nothing away from its URL, Reset all tabs in this Space is disabled")
                    done()
                }
            }
        }
        // ⌘Z, step by step: Reset All's step had only Draft left to reset; the step before, Reset Others, P and Spec 1.
        func undoStep(_ want: [String: String], label wantLabel: String, _ what: String) {
            step { [self] done in
                let label = c.store.undoLabel
                c.undo()
                waitUntil({ want.allSatisfy { self.c.engineTab(for: k.tab[$0.key] ?? "")?.title == $0.value } }, timeout: 8) {
                    let titles = want.keys.sorted().map { "\($0): \(self.c.engineTab(for: k.tab[$0] ?? "")?.title ?? "-")" }
                    self.check(label == wantLabel && want.allSatisfy { self.c.engineTab(for: k.tab[$0.key] ?? "")?.title == $0.value },
                               "parityp01: ⌘Z (\(label ?? "-")) " + what + " (\(titles.joined(separator: ", ")))")
                    done()
                }
            }
        }
        undoStep(["Draft": "Dirty", "P": "Pinned P"], label: SpacesStore.resetTabLabel, "puts Draft back on its page, and only Draft")
        undoStep(["P": "P elsewhere", "Spec 1": "Spec 1 moved"], label: SpacesStore.resetTabsLabel, "puts P and Spec 1 back, in one step")
        // Back to the saved URLs for the Command Bar part (answering a question if one comes).
        step { [self] done in
            WindowController.lastResetAlert = nil
            c.resetAllTabsInSpace()
            waitUntil({ WindowController.lastResetAlert != nil }, timeout: 1.5) {
                WindowController.lastResetAlert?.buttons.first?.performClick(nil)
                // The store changes at once; the pages load after: wait for them, or the next navigation races the reset.
                let home = ["P": "Pinned P", "Spec 1": "Spec 1", "Draft": "Draft home"]
                self.waitUntil({ self.c.store.driftedPinnedTabs(inSpace: k.home).isEmpty && self.c.window.attachedSheet == nil
                                 && home.allSatisfy { self.c.engineTab(for: k.tab[$0.key] ?? "")?.title == $0.value
                                                      && self.c.engineTab(for: k.tab[$0.key] ?? "")?.isLoading == false } }, timeout: 8) { done() }
            }
        }
    }

    // MARK: A Today tab's own icon

    /// Change Icon on a Today tab: its row draws the emoji; pinned, the pinned row does; unpinned, the Today row again.
    private func p01TodayIcon(_ k: P01) {
        let tab = { k.tab["Alpha"] ?? "" }
        func row(_ id: String) -> TabRowView? {
            let page = c.pageView(for: k.home)
            page?.layoutSubtreeIfNeeded()
            return page?.rows[id] as? TabRowView
        }
        var steps: [String] = []
        step { [self] done in
            try? c.store.setTabIcon(tab(), to: "🍋")
            waitUntil({ row(tab())?.customIcon == "🍋" }, timeout: 3) {
                steps.append("Today \(row(tab())?.customIcon ?? "-")")
                try? self.c.store.togglePin(tab(), inSpace: k.home)
                let item = self.c.store.tab(tab())?.itemID ?? ""
                self.waitUntil({ row(item)?.customIcon == "🍋" }, timeout: 3) {
                    steps.append("pinned \(row(item)?.customIcon ?? "-")")
                    try? self.c.store.move(.item(item), to: .today(spaceID: k.home, index: 0))
                    self.waitUntil({ row(tab())?.customIcon == "🍋" }, timeout: 3) {
                        steps.append("unpinned \(row(tab())?.customIcon ?? "-")")
                        try? self.c.store.setTabIcon(tab(), to: nil)
                        self.waitUntil({ row(tab())?.customIcon == nil }, timeout: 3) {
                            steps.append("cleared \(row(tab())?.customIcon ?? "favicon")")
                            self.check(steps == ["Today 🍋", "pinned 🍋", "unpinned 🍋", "cleared favicon"],
                                       "parityp01: a Today tab's own icon is drawn on its row, pinned and unpinned, and goes when cleared (\(steps))")
                            done()
                        }
                    }
                }
            }
        }
    }

    // MARK: A link straight to the copied text

    /// After ⌘C copied the page's selection (here: the run's pasteboard gets the same words, as the page's copy writes
    /// them), Arc's offer; its button copies the link to that text. Other copied text: no offer.
    private func p01QuoteLink(_ k: P01) {
        step { [self] done in
            c.show(k.tab["Alpha"] ?? "", focus: false)
            c.engineTab(for: k.tab["Alpha"] ?? "")?.evaluate("var r=document.createRange();r.selectNodeContents(document.getElementById('q'));"
                                                            + "getSelection().removeAllRanges();getSelection().addRange(r);true") { _ in done() }
        }
        step { [self] done in
            WindowController.copyWatchPasteboard = k.board
            let before = k.board.changeCount
            k.board.clearContents()
            k.board.setString("Alpha words", forType: .string)
            c.offerQuoteLink(after: before, on: k.board)
            waitUntil({ self.c.quoteLinkOffer?.isHidden == false }, timeout: 3) {
                let offer = self.c.quoteLinkOffer
                let want = k.url("/a.html") + "#:~:text=Alpha%20words"
                self.check(offer?.label.stringValue == QuoteLinkOfferView.message && offer?.link == want,
                           "parityp01: ⌘C on the page's selection offers \"\(offer?.label.stringValue ?? "nothing")\" (\(offer?.link ?? "-"))")
                offer?.button.performClick(nil)
                self.check(k.board.string(forType: .string) == want && self.c.toast.shownText == "Copied a link to this text",
                           "parityp01: its Copy Link copies the link to the text (\(k.board.string(forType: .string) ?? "-"))")
                done()
            }
        }
        step { [self] done in
            c.quoteLinkOffer?.hide()
            let before = k.board.changeCount
            k.board.clearContents()
            k.board.setString("Something else entirely", forType: .string)
            c.offerQuoteLink(after: before, on: k.board)
            waitUntil({ false }, timeout: 0.8) {
                self.check(self.c.quoteLinkOffer?.isHidden != false, "parityp01: text that isn't the page's selection gets no offer")
                done()
            }
        }
    }

    /// The engine's own JavaScript dialogs on a tab's page (Chromium's "Leave site?"); 0 where it has none.
    private func p01EngineDialogs(_ tabID: String) -> Int {
        #if canImport(AircCore)
        if let engine = app?.engine as? ChromiumEngine, let p = c.engineTab(for: tabID) {
            return (engine.modalDialogState(for: p)["dialogs"] as? [[String: Any]])?.count ?? 0
        }
        #endif
        return 0
    }

    // MARK: Command Bar

    private func p01CommandBar(_ k: P01) {
        // P away again (Replace Pinned URL with Current, Reset all tabs), shown, inside no folder; then Spec 1 (in Work).
        step { [self] done in
            guard let p = c.engineTab(for: k.tab["P"] ?? ""), let u = URL(string: k.url("/p2.html")) else { return done() }
            c.show(k.tab["P"] ?? "", focus: false)
            c.engineWindow.load(u, in: p)
            waitUntil({ p.title == "P elsewhere" && self.c.store.isDrifted(k.tab["P"] ?? "") }, timeout: 8) { done() }
        }
        run { [self] in
            let pinned = c.commandActions().map(\.title)
            var want = ["Share", "Collapse All Folders", "Reset all tabs in this Space", "Mute Tab", "Replace Pinned URL with Current",
                        "Edit Pinned Page…", "Move to Pinned in Office"]
            if c.boostsAvailable { want.append("Customize Page…") }
            let missing = want.filter { !pinned.contains($0) }
            check(missing.isEmpty, "parityp01: Command Bar offers the pinned tab's actions" + (missing.isEmpty ? "" : " (missing \(missing))"))
            c.show(k.tab["Spec 1"] ?? "", focus: false)
            let inFolder = c.commandActions().map(\.title)
            check(inFolder.contains("Copy All Links in “Specs”") && inFolder.contains("Copy All Links in “Specs” as Markdown"),
                  "parityp01: Command Bar offers the folder's Copy All Links (plain and Markdown) for a tab in it")
            c.show(k.tab["Alpha"] ?? "", focus: false)
            let today = c.commandActions().map(\.title)
            check(today.contains("Archive Tabs Below") && today.contains("Share") && today.contains("Mute Tab") && today.contains("Change Icon…"),
                  "parityp01: Command Bar offers a Today tab's Archive Tabs Below, Share, Mute Tab and Change Icon…")
            // One runs from the Command Bar's own list.
            c.commandActions().first { $0.title == "Collapse All Folders" }?.run()
            check(c.store.item(k.item["Work"])?.isCollapsed == true && c.store.item(k.item["Specs"])?.isCollapsed == true,
                  "parityp01: Command Bar's Collapse All Folders runs")
            c.commandActions().first { $0.title == "Expand All Folders" }?.run()
            k.board.clearContents()
            c.commandActions().first { $0.title == "Reset all tabs in this Space" }?.run()
        }
        step { [self] done in
            waitUntil({ self.c.engineTab(for: k.tab["P"] ?? "")?.title == "Pinned P" }, timeout: 6) {
                self.check(!self.c.store.isDrifted(k.tab["P"] ?? ""), "parityp01: Command Bar's Reset all tabs in this Space runs")
                done()
            }
        }
        // Open in Split View: the unloaded pinned Doc 2 beside Alpha, from its menu; disabled on the row on screen.
        step { [self] done in
            c.show(k.tab["Alpha"] ?? "", focus: false)
            let own = p01Model(p01Entry(k, "P").map { c.menu(for: $0) })
            c.show(k.tab["P"] ?? "", focus: false)
            let shownRow = p01Model(p01Entry(k, "P").map { c.menu(for: $0) })
            c.show(k.tab["Alpha"] ?? "", focus: false)
            let fired = p01Fire(p01Entry(k, "Doc 2").map { c.menu(for: $0) }, ["Open in Split View"])
            waitUntil({ self.c.shownSplitID != nil }, timeout: 6) {
                let x = self.c.store.split(self.c.shownSplitID)
                let doc2 = self.c.store.liveTab(forItem: k.item["Doc 2"] ?? "")
                self.check(fired && self.p01Enabled(own, "Open in Split View") == true && self.p01Enabled(shownRow, "Open in Split View") == false
                           && x?.tabIDs.contains(k.tab["Alpha"] ?? "") == true && doc2.map { x?.tabIDs.contains($0.id) } == true,
                           "parityp01: Open in Split View puts an unloaded pinned tab beside the page on screen; disabled on the row on screen "
                           + "(panes \(x?.tabIDs.count ?? 0))")
                self.c.separateShownSplit()
                done()
            }
        }
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}
#endif
