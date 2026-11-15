// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// `--script paritytodayfolders` (audit row A06, docs/user/sidebar.md "Folders in Today"): folders in the Today list,
/// as Arc has them, on both engines, with real pointer events where a person would use the pointer.
///
/// - Space menu › New Folder in Today: a folder at the top of Today, drawn as a folder row below the divider, its name
///   ready to type (Esc keeps "New Folder").
/// - Dragging a Today tab onto the folder's row puts it inside; its row is drawn under the folder, indented one level.
/// - Pressing the folder's row closes it (its tabs' rows go) and opens it again; the folder menu's Rename… is there.
/// - Dragging the folder above the divider makes it a pinned folder (its tabs pinned tabs); dragging it back below the
///   divider makes it a Today folder again (its tabs Today tabs).
/// - Dragging a tab out of the folder to Today's top level; ⌘W on the folder's last tab archives it and the folder goes;
///   one ⌘Z brings back both.
/// - Clear archives the folder's tabs too, closed folder or not, and the emptied folder goes; one ⌘Z brings them back.
/// - Auto-archive takes a tab in a Today folder by its own age (the store's clock moved on), and the folder with it.
/// - Today folders never reach the sync payload, and the store's schema mark is 3.
///
/// `paritytodayfolders-write` then `-read` (one data folder, not ephemeral): a Today folder with a closed folder inside
/// survives a relaunch with its tabs, order and closed state.
extension SnapshotRunner {
    @MainActor private func tfTitles(_ space: String) -> [String] {
        c.store.todayRows(ofSpace: space).map { e in
            switch e {
            case .folder(let f, let d): String(repeating: "  ", count: d) + "[\(f.displayTitle)]"
            case .today(let t): String(repeating: "  ", count: c.store.todayDepth(ofTab: t.id)) + t.title
            case .split(_, let tabs): tabs.map(\.title).joined(separator: "|")
            default: "?"
            }
        }
    }

    @MainActor private func tfFolderRow(_ id: String, in space: String) -> FolderRowView? {
        guard let p = c.pageView(for: space) else { return nil }
        p.layoutSubtreeIfNeeded()
        return p.rows[id] as? FolderRowView
    }

    /// A point in a row, in window coordinates: `y` 0.5 is its middle, 0.9 its lower part (the list is flipped: y grows
    /// downwards).
    @MainActor private func tfPoint(_ row: NSView, x: CGFloat = 90, y: CGFloat = 0.5) -> NSPoint {
        guard let list = row.superview else { return .zero }
        return list.convert(NSPoint(x: row.frame.minX + x, y: row.frame.minY + row.frame.height * y), to: nil)
    }

    @MainActor func parityTodayFoldersScenario() {
        switch script {
        case "paritytodayfolders-write": return tfRelaunch(write: true)
        case "paritytodayfolders-read": return tfRelaunch(write: false)
        default: break
        }
        let tag = app?.engine is WebKitEngine ? "paritytodayfolders (WebKit)" : "paritytodayfolders (Chromium)"
        var space = "", folder = ""
        var ids: [String] = []   // Lisbon flights, Alfama hotels, Trams, Weather (shown)
        var pinnedTab = ""

        run { [self] in
            do {
                let s = c.store
                let sp = try s.createSpace(name: "Today Folders", profileID: s.selectedSpace.profileID)
                space = sp.id
                let docs = try s.openTab(url: "about:blank#docs", inSpace: sp.id, activate: false, title: "Docs")
                try s.move(.tab(docs.id), to: .pinned(spaceID: sp.id, parentID: nil, index: 0))
                pinnedTab = docs.id
                for t in [("about:blank#weather", "Weather"), ("about:blank#trams", "Trams"), ("about:blank#alfama", "Alfama hotels"),
                          ("about:blank#flights", "Lisbon flights")] {
                    ids.insert(try s.openTab(url: t.0, inSpace: sp.id, activate: false, title: t.1).id, at: 0)
                }
                c.switchToSpace(sp.id, animated: false)
                c.show(ids[3], focus: false)
                c.reloadAll(animated: false)
            } catch {
                check(false, "\(tag): the test Space is made (\(error))")
            }
        }
        wait(0.6)

        // 1. Space menu › New Folder in Today.
        run { [self] in
            let item = c.spaceMenu(spaceID: space).items.first { $0.title == "New Folder in Today" } as? ClosureMenuItem
            item?.fire()
            folder = c.store.todayFolders(ofSpace: space).first?.id ?? ""
        }
        wait(0.4)
        run { [self] in
            let row = tfFolderRow(folder, in: space)
            let divider = c.pageView(for: space)?.rows["divider"]
            let editing = (c.window.firstResponder as? NSTextView)?.string == "New Folder"
            check(!folder.isEmpty && c.store.todayRootRows(ofSpace: space).first?.id == folder && row != nil
                    && (row?.frame.minY ?? 0) > (divider?.frame.maxY ?? .greatestFiniteMagnitude) && editing,
                  "\(tag): Space menu › New Folder in Today makes a folder at the top of Today, drawn below the divider, its name "
                    + "ready to type (\(tfTitles(space)), editing \(editing))")
        }
        key("\u{1b}", 53)
        wait(0.2)

        // 2. Drag two tabs onto the folder's row.
        for (n, i) in [0, 1].enumerated() {
            step { [self] done in
                guard let page = c.pageView(for: space), let row = todayRow(ids[i], in: page), let f = tfFolderRow(folder, in: space) else {
                    check(false, "\(tag): the rows to drag are drawn"); return done()
                }
                drag(from: tfPoint(row), to: tfPoint(f, x: 110)) {
                    let inside = self.c.store.todayFolderTabs(folder).map(\.id)
                    self.check(inside == Array(ids[0...n]),
                               "\(tag): a Today tab dragged onto the folder's row goes inside, at its end (\(self.tfTitles(space)))")
                    done()
                }
            }
            wait(0.3)
        }
        run { [self] in
            guard let page = c.pageView(for: space) else { return }
            let row = todayRow(ids[0], in: page), f = tfFolderRow(folder, in: space)
            check(row?.depth == 1 && (row?.frame.minY ?? 0) > (f?.frame.minY ?? .greatestFiniteMagnitude),
                  "\(tag): the tabs in the folder are drawn under it, one level in (depth \(row?.depth ?? -1))")
            let titles = c.menu(for: .folder(c.store.item(folder)!, depth: 0)).items.map(\.title)
            check(["Rename…", "Change Icon…", "Copy All Links", "Ungroup", "Delete Folder"].allSatisfy(titles.contains),
                  "\(tag): the folder's menu has Rename…, Change Icon…, Copy All Links, Ungroup and Delete Folder (\(titles))")
            try? c.store.renameItem(folder, to: "Lisbon")
        }
        wait(0.2)

        // 3. Pressing the folder's row closes and opens it.
        for closed in [true, false] {
            step { [self] done in
                guard let f = tfFolderRow(folder, in: space) else { check(false, "\(tag): the folder row is drawn"); return done() }
                let p = tfPoint(f)
                drag(from: p, to: p, hold: 0) {
                    let page = self.c.pageView(for: space)
                    let shown = page.map { self.todayRow(ids[0], in: $0) != nil } ?? false
                    self.check(self.c.store.item(folder)?.isCollapsed == closed && shown != closed
                                && self.tfFolderRow(folder, in: space)?.titleField.stringValue == "Lisbon",
                               "\(tag): pressing the folder's row \(closed ? "closes" : "opens") it (\(self.tfTitles(space)))")
                    done()
                }
            }
            wait(0.4)
        }

        // 4. The folder dragged into Pinned, then back into Today.
        step { [self] done in
            guard let page = c.pageView(for: space), let f = tfFolderRow(folder, in: space),
                  let docs = page.rows[c.store.tab(pinnedTab)?.itemID ?? ""] else { check(false, "\(tag): rows for the pinned drag"); return done() }
            drag(from: tfPoint(f), to: tfPoint(docs, x: 110, y: 0.9)) {
                let item = self.c.store.item(folder)
                let pinnedTabs = self.c.store.children(of: .pinned(spaceID: space), parent: folder).compactMap { self.c.store.liveTab(forItem: $0.id)?.id }
                self.check(item?.container == .pinned(spaceID: space) && pinnedTabs == [ids[0], ids[1]]
                            && self.c.store.todayFolders(ofSpace: space).isEmpty,
                           "\(tag): the Today folder dragged above the divider is a pinned folder, its tabs its pinned tabs (\(pinnedTabs.count))")
                done()
            }
        }
        wait(0.4)
        step { [self] done in
            guard let page = c.pageView(for: space), let f = tfFolderRow(folder, in: space), let last = todayRow(ids[3], in: page) else {
                check(false, "\(tag): rows for the drag back"); return done()
            }
            drag(from: tfPoint(f), to: tfPoint(last, x: 110, y: 0.9)) {
                let item = self.c.store.item(folder)
                let inside = self.c.store.todayFolderTabs(folder)
                self.check(item?.container == .today(spaceID: space) && inside.map(\.id) == [ids[0], ids[1]] && inside.allSatisfy(\.isToday),
                           "\(tag): dragged back below the divider it's a Today folder again, its tabs Today tabs (\(self.tfTitles(space)))")
                done()
            }
        }
        wait(0.4)

        // 5. A tab dragged out to Today's top level; ⌘W on the last one; one ⌘Z.
        step { [self] done in
            guard let page = c.pageView(for: space), let row = todayRow(ids[1], in: page), let top = todayRow(ids[2], in: page) else {
                check(false, "\(tag): rows for the drag out"); return done()
            }
            drag(from: tfPoint(row), to: tfPoint(top, x: 110, y: 0.1)) {
                self.check(self.c.store.tab(ids[1])?.folderID == nil && self.c.store.todayFolderTabs(folder).map(\.id) == [ids[0]],
                           "\(tag): a tab dragged out of the folder is loose in Today (\(self.tfTitles(space)))")
                done()
            }
        }
        // (Pressing a row to drag it shows its page: closing waits for the page to close.)
        run { [self] in c.closeTab(ids[0]) }
        step { [self] done in waitUntil({ self.c.store.tab(ids[0]) == nil }, timeout: 6) { done() } }
        run { [self] in
            let gone = c.store.item(folder) == nil && c.store.tab(ids[0]) == nil
            c.undo()
            check(gone && c.store.todayFolderTabs(folder).map(\.id) == [ids[0]],
                  "\(tag): ⌘W on the folder's last tab archives it and the folder goes; one ⌘Z brings back both (\(tfTitles(space)))")
        }
        wait(0.3)

        // 6. Clear: the folder's tabs (closed folder) go to the Archive and the folder with them; one ⌘Z.
        run { [self] in
            try? c.store.move(.tab(ids[1]), to: .todayFolder(folderID: folder, index: 1))
            if c.store.item(folder)?.isCollapsed == false { try? c.store.toggleFolder(folder) }
            c.show(ids[3], focus: false)
            c.clearToday()
        }
        step { [self] done in waitUntil({ self.c.store.item(folder) == nil }, timeout: 6) { done() } }
        run { [self] in
            let left = c.store.todayRowTabs(ofSpace: space).map(\.id)
            check(c.store.item(folder) == nil && left == [ids[3]] && c.store.undoLabel == "Clear Today",
                  "\(tag): Clear archives the tabs in the closed folder too, and the emptied folder goes (left \(left.count))")
            c.undo()
            check(c.store.todayFolderTabs(folder).map(\.id) == [ids[0], ids[1]] && c.store.todayRowTabs(ofSpace: space).count == 4,
                  "\(tag): one ⌘Z brings back the folder and its tabs (\(tfTitles(space)))")
            if c.store.item(folder)?.isCollapsed == true { try? c.store.toggleFolder(folder) }
        }

        // 7. Auto-archive by the tabs' own age: one tab viewed now, the other not.
        run { [self] in
            let realNow = c.store.now
            c.store.now = { realNow().addingTimeInterval(8 * 3600) }
            try? c.store.activate(ids[1], inSpace: space)
            try? c.store.activate(ids[3], inSpace: space)   // the tab on screen stays fresh
            c.store.now = { realNow().addingTimeInterval(13 * 3600) }
            let due = c.store.dueForAutoArchive()
            _ = try? c.store.autoArchive([ids[0], ids[1]], protected: c.visibleTabIDs)
            let first = c.store.todayFolderTabs(folder).map(\.id)
            c.store.now = { realNow().addingTimeInterval(20 * 3600) }
            _ = try? c.store.autoArchive([ids[1]], protected: c.visibleTabIDs)
            let folderGone = c.store.item(folder) == nil
            c.store.now = realNow
            check(due.contains(ids[0]) && !due.contains(ids[1]) && first == [ids[1]] && folderGone,
                  "\(tag): auto-archive takes a tab in a Today folder by its own age, and the folder with its last tab "
                    + "(first pass left \(first.count), folder gone \(folderGone))")
        }

        // 8. Sync and schema.
        run { [self] in
            guard let f = try? c.store.createTodayFolder(named: "Never Synced Folder", inSpace: space, containing: [.tab(ids[2])]) else {
                check(false, "\(tag): a Today folder for the sync check"); return
            }
            var adapter = SyncStoreAdapter(), replica = SyncReplica()
            let ops = (try? adapter.capture(c.store.state, into: &replica, now: 1)) ?? []
            let sent = String(decoding: (try? JSONEncoder().encode(ops)) ?? Data(), as: UTF8.self)
            check(!sent.isEmpty && !sent.contains("Never Synced Folder") && !sent.contains(f.id) && c.store.schemaMark == 3,
                  "\(tag): a Today folder never reaches the sync payload (\(ops.count) operations), and the store is schema 3")
        }
        run { [self] in finish() }
    }

    /// A Today folder with a closed folder inside, before (write) and after (read) a relaunch.
    @MainActor private func tfRelaunch(write: Bool) {
        let tag = (app?.engine is WebKitEngine ? "paritytodayfolders (WebKit)" : "paritytodayfolders (Chromium)") + (write ? " write" : " read")
        let file = AppPaths.dataDirectory.appendingPathComponent("todayfolders-before.txt")
        if write {
            run { [self] in
                do {
                    let s = c.store
                    let sp = try s.createSpace(name: "Today Folders", profileID: s.selectedSpace.profileID)
                    var tabs: [String] = []
                    for n in ["Flights", "Hotels", "Trams", "Weather"] {
                        tabs.append(try s.openTab(url: "about:blank#\(n)", inSpace: sp.id, activate: false, title: n).id)
                    }
                    let trip = try s.createTodayFolder(named: "Lisbon", inSpace: sp.id, containing: [.tab(tabs[3]), .tab(tabs[2])])
                    let inner = try s.createTodayFolder(named: "Stay", inSpace: sp.id, parentID: trip.id, index: 2, containing: [.tab(tabs[1])])
                    try s.toggleFolder(inner.id)
                    try s.flush()
                    c.switchToSpace(sp.id, animated: false)
                    let before = tfTitles(sp.id).joined(separator: "\n")
                    try (sp.id + "\n" + before).write(to: file, atomically: true, encoding: .utf8)
                    check(s.schemaMark == 3, "\(tag): a Today folder with a closed folder inside (\(tfTitles(sp.id)))")
                } catch {
                    check(false, "\(tag): made (\(error))")
                }
                finish()
            }
        } else {
            run { [self] in
                guard let saved = try? String(contentsOf: file, encoding: .utf8), let nl = saved.firstIndex(of: "\n") else {
                    check(false, "\(tag): the write run's layout is there")
                    return finish()
                }
                let space = String(saved[..<nl]), before = String(saved[saved.index(after: nl)...])
                c.switchToSpace(space, animated: false)
                c.reloadAll(animated: false)
                let folders = c.store.todayFolders(ofSpace: space)
                let drawn = folders.allSatisfy { tfFolderRow($0.id, in: space) != nil || c.store.item($0.parentID)?.isCollapsed == true }
                check(tfTitles(space).joined(separator: "\n") == before && folders.count == 2 && drawn && c.store.schemaMark == 3
                        && c.store.unreadableRows.isEmpty,
                      "\(tag): after a relaunch the Today folders, their tabs, order and closed state are as they were (\(tfTitles(space)))")
                finish()
            }
        }
    }
}
#endif
