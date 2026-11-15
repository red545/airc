// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script parityS09S11` (both engines), the S09/S11 menu items on loopback pages (Browser/MenuMoveAndBulk.swift):
///   - a Today tab's, a pinned tab's, a pinned folder's and a Today folder's menu: titles, order and enabled states; each
///     Move to › lists the other Spaces, then this Space's folders in their section (nested ones indented, never the row
///     itself or what's inside it), then New Space…; moving into a folder works and ⌘Z puts the row back where it was;
///   - a multi-selection's menu ends with Archive Tabs Below and Archive Other Tabs; each archives the right tabs (never
///     the one on screen) and ⌘Z brings them back;
///   - the Command Bar: Rename Current Tab (as Rename…), Pin to “Folder” (⌘Z), Unmute All Tabs after Mute All Tabs, and
///     Expand / Collapse All Folders found by Arc's other words for them ("close all folders").
extension SnapshotRunner {
    func parityS09S11Scenario() {
        var server: LocalPageServer?
        var base = ""
        var home = "", office = ""
        var tab: [String: String] = [:]      // Today tabs by name
        var work = "", deep = "", later = "", stack = "", pinnedTab = "", pinnedTabID = ""
        let watchdog = DispatchWorkItem { [weak self] in
            self?.note("FAIL parityS09S11: still running after 200 s (off-main watchdog)")
            exit(70)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 200, execute: watchdog)

        func titles(_ m: NSMenu?) -> [String] {
            guard let m else { return [] }
            m.update()
            return m.items.filter { !$0.isAlternate }.map { $0.isSeparatorItem ? "—" : $0.title }
        }
        func item(_ m: NSMenu?, _ title: String) -> NSMenuItem? { m?.items.first { $0.title == title } }
        func fire(_ i: NSMenuItem?) -> Bool {
            guard let i, i.isEnabled, let menu = i.menu, let k = menu.items.firstIndex(of: i) else { return false }
            menu.performActionForItem(at: k)
            return true
        }
        func label(_ s: String) -> String { c.store.space(s).map { $0.iconLabel + "  " + $0.name } ?? "?" }
        func todayNames() -> String {
            c.store.todayRowTabs(ofSpace: home).map { t in tab.first { $0.value == t.id }?.key ?? "?" }.joined(separator: " ")
        }
        func parentOf(_ itemID: String?) -> String? { c.store.item(itemID)?.parentID }
        func settle(_ s: Double) { wait(s) }
        /// `want` appears in `got` in this order (other rows may sit between).
        func inOrder(_ got: [String], _ want: [String]) -> Bool {
            var i = got.startIndex
            for w in want {
                guard let j = got[i...].firstIndex(of: w) else { return false }
                i = got.index(after: j)
            }
            return true
        }

        step { [self] done in
            var pages: [String: String] = [:]
            for n in ["A", "B", "C", "D", "E", "P"] { pages["/\(n)"] = "<!doctype html><title>\(n)</title><p>\(n)</p>" }
            server = LocalPageServer(pages: pages)
            server?.start { port in
                if let port { base = "http://127.0.0.1:\(port)" } else { self.check(false, "parityS09S11: a loopback page server") }
                done()
            }
        }

        // Two Spaces; in Home: pinned folders Work (› Deep) and Later, a pinned tab P, a Today folder Stack, Today A–E.
        run { [self] in
            home = c.currentSpaceID
            let pid = c.store.profile(ofSpace: home).id
            office = (try? c.store.createSpace(name: "Office", profileID: pid, after: home))?.id ?? ""
            for n in ["E", "D", "C", "B", "A"] {
                tab[n] = (try? c.store.openTab(url: base + "/\(n)", inSpace: home, activate: false, title: n))?.id ?? ""
            }
            let p = (try? c.store.openTab(url: base + "/P", inSpace: home, activate: false, title: "P"))?.id ?? ""
            c.performDrop(.tab(p), to: .pinned(spaceID: home, parentID: nil, index: 0))
            pinnedTab = p
            pinnedTabID = c.store.tab(p)?.itemID ?? ""
            work = (try? c.store.createFolder(named: "Work", inSpace: home, index: 0, containing: []))?.id ?? ""
            deep = (try? c.store.createFolder(named: "Deep", inSpace: home, parentID: work))?.id ?? ""
            later = (try? c.store.createFolder(named: "Later", inSpace: home, containing: []))?.id ?? ""
            stack = (try? c.store.createTodayFolder(named: "Stack", inSpace: home, index: 0))?.id ?? ""
            c.reloadAll(animated: false)
            check(!office.isEmpty && !work.isEmpty && !deep.isEmpty && !later.isEmpty && !stack.isEmpty && !pinnedTabID.isEmpty
                  && todayNames() == "A B C D E",
                  "parityS09S11: setup: two Spaces, folders Work › Deep, Later, Today folder Stack, pinned P, Today \(todayNames())")
        }
        // Show C, so Today's menus have a tab on screen.
        step { [self] done in
            c.show(tab["C"]!, focus: false)
            waitUntil({ self.c.engineTab(for: tab["C"]!)?.isLoading == false }, timeout: 8) { done() }
        }

        // A Today tab's menu (A).
        run { [self] in
            guard let a = c.store.tab(tab["A"]) else { return check(false, "parityS09S11: tab A") }
            let m = c.menu(for: .today(a))
            let t = titles(m)
            check(t == ["Copy Link", "Share", "Change Icon…", "Rename…", "Mute", "Customize Page…", "Add Split View", "Duplicate", "Move to",
                        "Move to New Window", "—", "Pin Tab", "Add to Favorites", "—", "Archive Tab", "Archive Tabs Below"]
                  && item(m, "Archive Tabs Below")?.isEnabled == true && item(m, "Move to")?.isEnabled == true,
                  "parityS09S11: a Today tab's menu, in Arc's order (\(t.joined(separator: ", ")))")
            let move = item(m, "Move to")?.submenu
            let rows = titles(move)
            let indent = move?.items.first { $0.title == "Deep" }?.indentationLevel ?? -1
            check(rows == [label(office), "—", "Work", "Deep", "Later", "Stack", "—", "New Space…"] && indent == 1,
                  "parityS09S11: a Today tab's Move to › lists the other Space, then this Space's pinned folders (Deep indented: \(indent)) and "
                  + "Today folders, then New Space… (\(rows.joined(separator: ", ")))")
            let fired = fire(move?.items.first { $0.title == "Work" })
            let pinnedIn = c.store.tab(tab["A"])?.itemID.flatMap(parentOf) == work
            c.undo()
            let back = c.store.tab(tab["A"])?.isToday == true && todayNames() == "A B C D E"
            check(fired && pinnedIn && back,
                  "parityS09S11: Move to › Work pins A in Work (\(pinnedIn)); ⌘Z puts it back at the top of Today (\(back): \(todayNames()))")
            let m2 = c.menu(for: .today(c.store.tab(tab["A"])!))
            let fired2 = fire(item(m2, "Move to")?.submenu?.items.first { $0.title == "Stack" })
            let inStack = c.store.tab(tab["A"]).flatMap(c.store.shownTodayFolderID) == stack
            c.undo()
            let back2 = c.store.tab(tab["A"]).flatMap(c.store.shownTodayFolderID) == nil && todayNames() == "A B C D E"
            check(fired2 && inStack && back2, "parityS09S11: Move to › Stack puts A in the Today folder (\(inStack)); ⌘Z takes it out (\(back2))")
        }

        // A pinned tab's menu (P, unloaded): Move to › pinned folders only.
        run { [self] in
            guard let it = c.store.item(pinnedTabID) else { return check(false, "parityS09S11: pinned P") }
            let m = c.menu(for: .pinned(it, depth: 0, c.store.liveTab(forItem: pinnedTabID)))
            let t = titles(m)
            check(inOrder(t, ["Copy Link", "Share", "Change Icon…", "Rename…", "Edit Pinned Page", "Duplicate", "Move to", "—", "Unpin", "Add to Favorites",
                              "Remove Pin"]) && t.last == "Remove Pin" && !t.contains("Mute"),
                  "parityS09S11: an unloaded pinned tab's menu (\(t.joined(separator: ", ")))")
            let move = item(m, "Move to")?.submenu
            let rows = titles(move)
            check(rows == [label(office), "—", "Work", "Deep", "Later", "—", "New Space…"],
                  "parityS09S11: a pinned tab's Move to › lists the other Space, then the pinned folders, no Today folders (\(rows.joined(separator: ", ")))")
            let fired = fire(move?.items.first { $0.title == "Deep" })
            let moved = parentOf(pinnedTabID) == deep
            c.undo()
            let back = parentOf(pinnedTabID) == nil && c.store.item(pinnedTabID)?.container == .pinned(spaceID: home)
            check(fired && moved && back, "parityS09S11: Move to › Deep puts P in the nested folder (\(moved)); ⌘Z puts it back (\(back))")
        }

        // A pinned folder's menu (Work): never itself or Deep.
        run { [self] in
            guard let f = c.store.item(work) else { return check(false, "parityS09S11: folder Work") }
            let m = c.menu(for: .folder(f, depth: 0))
            let t = titles(m)
            check(t == ["Share Folder…", "—", "New Nested Folder…", "Turn “Work” into Space", "Copy All Links", "Copy All Links as Markdown", "—",
                        "Change Icon…", "Rename…", "—", "Duplicate", "Move to", "Reset Folder", "—", "Delete Folder"]
                  && item(m, "Copy All Links")?.isEnabled == false && item(m, "Reset Folder")?.isEnabled == false,
                  "parityS09S11: a folder's menu, empty folder's copy and reset off (\(t.joined(separator: ", ")))")
            let move = item(m, "Move to")?.submenu
            let rows = titles(move)
            check(rows == [label(office), "—", "Later", "—", "New Space…"],
                  "parityS09S11: a folder's Move to › leaves out itself and its nested folder (\(rows.joined(separator: ", ")))")
            let fired = fire(move?.items.first { $0.title == "Later" })
            let moved = parentOf(work) == later && parentOf(deep) == work
            c.undo()
            let back = parentOf(work) == nil
            check(fired && moved && back, "parityS09S11: Move to › Later nests Work, Deep inside it (\(moved)); ⌘Z takes it out (\(back))")
            // A Today folder: Today folders only (none other here). Stack went when ⌘Z took A out of it and left it empty
            // (Arc's Today folders go with their last tab), so a fresh one.
            stack = (try? c.store.createTodayFolder(named: "Stack", inSpace: home, index: 0))?.id ?? ""
            guard let s = c.store.item(stack) else { return check(false, "parityS09S11: Today folder Stack") }
            let sm = c.menu(for: .folder(s, depth: 0))
            let srows = titles(item(sm, "Move to")?.submenu)
            check(srows == [label(office), "—", "New Space…"],
                  "parityS09S11: a Today folder's Move to › offers no pinned folders and not itself (\(srows.joined(separator: ", ")))")
        }

        // A multi-selection (A, B): Archive Tabs Below and Archive Other Tabs.
        run { [self] in
            let ids = [tab["A"]!, tab["B"]!]
            let m = c.selectionMenu(ids: ids, spaceID: home)
            let t = titles(m)
            check(t.suffix(5) == ["—", "Close 2 Tabs", "Archive 2 Tabs", "Archive Tabs Below", "Archive Other Tabs"]
                  && item(m, "Archive Tabs Below")?.isEnabled == true && item(m, "Archive Other Tabs")?.isEnabled == true,
                  "parityS09S11: a selection's menu ends with Archive Tabs Below and Archive Other Tabs, both on (\(t.joined(separator: ", ")))")
            check(c.selectionTabsBelow(ids, spaceID: home) == [tab["D"]!, tab["E"]!],
                  "parityS09S11: below A and B: D and E, not C on screen")
            _ = fire(item(m, "Archive Tabs Below"))
        }
        settle(0.6)
        run { [self] in
            let after = todayNames()
            c.undo()
            check(after == "A B C" && todayNames() == "A B C D E",
                  "parityS09S11: Archive Tabs Below archives D and E (\(after)); ⌘Z brings them back (\(todayNames()))")
            let ids = [tab["B"]!]
            let m = c.selectionMenu(ids: ids, spaceID: home)
            _ = fire(item(m, "Archive Other Tabs"))
        }
        settle(0.6)
        run { [self] in
            let after = todayNames()
            c.undo()
            check(after == "B C" && todayNames() == "A B C D E",
                  "parityS09S11: Archive Other Tabs keeps B and C on screen (\(after)); ⌘Z brings the others back (\(todayNames()))")
            // E selected, nothing below: Archive Tabs Below off.
            let m = c.selectionMenu(ids: [tab["D"]!, tab["E"]!], spaceID: home)
            check(item(m, "Archive Tabs Below")?.isEnabled == false && item(m, "Archive Other Tabs")?.isEnabled == true,
                  "parityS09S11: with the last tabs selected Archive Tabs Below is off, Archive Other Tabs on")
            // Pinned rows only: neither.
            let pm = c.selectionMenu(ids: [pinnedTabID, work], spaceID: home)
            check(item(pm, "Archive Tabs Below") == nil && item(pm, "Archive Other Tabs") == nil,
                  "parityS09S11: a selection of pinned rows has no Today archive rows (\(titles(pm).suffix(3)))")
        }

        // The Command Bar, with C on screen.
        run { [self] in
            let all = c.commandActions().map(\.title)
            let want = ["Rename Current Tab", "Pin to “Work”", "Pin to “Deep”", "Pin to “Later”"]
            check(want.allSatisfy(all.contains) && !all.contains("Pin to “Stack”") && !all.contains("Unmute All Tabs"),
                  "parityS09S11: Command Bar has Rename Current Tab and Pin to each pinned folder (\(all.filter { $0.hasPrefix("Pin to") || $0.hasPrefix("Rename") }))")
            c.commandActions().first { $0.title == "Pin to “Later”" }?.run()
            let pinned = c.store.tab(tab["C"])?.itemID.flatMap(parentOf) == later
            c.undo()
            let back = c.store.tab(tab["C"])?.isToday == true && todayNames() == "A B C D E"
            check(pinned && back, "parityS09S11: Pin to “Later” pins C there (\(pinned)); ⌘Z puts it back in Today (\(back): \(todayNames()))")
            // Mute All Tabs (offered while a tab plays; loopback pages are silent, so the action runs directly).
            c.setAllTabsMuted(true)
            let muted = c.engineTab(for: tab["C"]!)?.isMuted == true && c.store.tab(tab["C"])?.isMuted == true
            let unmute = c.commandActions().first { $0.title == "Unmute All Tabs" }
            unmute?.run()
            check(muted && unmute != nil && c.engineTab(for: tab["C"]!)?.isMuted == false && c.store.tab(tab["C"])?.isMuted == false,
                  "parityS09S11: Mute All Tabs mutes the loaded tabs (\(muted)); Command Bar's Unmute All Tabs is then offered and unmutes them")
            // Arc's other words for Expand / Collapse All Folders.
            let words = c.contextCommandActions().first { $0.title == "Collapse All Folders" }?.keywords ?? []
            check(words.contains("close all folders"), "parityS09S11: Collapse All Folders answers to “close all folders” (\(words))")
        }
        run { [self] in
            c.commandActions().first { $0.title == "Rename Current Tab" }?.run()
        }
        settle(0.5)
        run { [self] in
            let editing = c.window.firstResponder is NSTextView
            let pinned = c.store.tab(tab["C"])?.isToday == false
            c.window.makeFirstResponder(nil)
            // As Rename… on a Today tab: the pin is ⌘D's, which has no undo step of its own, so unpin it back.
            if c.store.tab(tab["C"])?.isToday == false { try? c.store.togglePin(tab["C"]!, inSpace: home) }
            check(editing && pinned && c.store.tab(tab["C"])?.isToday == true,
                  "parityS09S11: Rename Current Tab pins C (\(pinned)) and opens its name for typing (\(editing)), as Rename… does")
            watchdog.cancel()
            server?.stop()
        }
    }
}
#endif
