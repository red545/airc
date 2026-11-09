// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script parityp01c` (both engines), P01c's menus on loopback pages:
///   - the Space header: the only Space, unnamed and without an icon, hides its name row (and isn't a keyboard stop);
///     its menu offers Show Space Header and then Hide Space Header; an icon, or a folded pinned section, brings the
///     row back; an empty rename is allowed;
///   - a Favorite's Move to › lists the other profiles with a Space, by avatar and name, and moves it to that profile's
///     Favorites; ⌘Z brings it back;
///   - a folder's menu: Reset all tabs in this Folder (off with nothing to reset; resets only the folder's tabs, nested
///     ones too; ⌘Z), Move to › another Space (with everything inside; ⌘Z), and Turn into Space (a new Space after this
///     one, named after the folder with its emoji, same profile and theme, the folder's rows as its pinned section in
///     order; the folder goes; shown; ⌘Z undoes it all);
///   - Shared Quotes: the Command Bar's Disable / Enable Shared Quotes and the offer's own right-click Disable turn the
///     offer after ⌘C off and on.
extension SnapshotRunner {
    func parityP01cScenario() {
        var server: LocalPageServer?
        var base = ""
        var home = ""
        var same = ""
        var second = ""
        let board = NSPasteboard.withUniqueName()
        func page(_ path: String) -> String { base + path }
        func titles(_ m: NSMenu) -> [String] { m.items.filter { !$0.isSeparatorItem }.map(\.title) }
        func item(_ m: NSMenu, _ title: String) -> NSMenuItem? { m.items.first { $0.title == title } }
        func fire(_ i: NSMenuItem?) { guard let i, let menu = i.menu, let k = menu.items.firstIndex(of: i) else { return }; menu.performActionForItem(at: k) }
        func open(_ path: String, _ title: String, in sid: String) -> String {
            (try? c.store.openTab(url: page(path), inSpace: sid, activate: false, title: title))?.id ?? ""
        }
        func settle(_ s: Double = 0.4) { wait(s) }
        /// The Space whose pinned section holds item `id`.
        func spaceOf(_ id: String?) -> String? {
            if case .pinned(let s)? = id.flatMap({ c.store.item($0) })?.container { return s }
            return nil
        }

        step { [self] done in
            var pages: [String: String] = [:]
            for (path, title) in [("/a", "Alpha"), ("/b", "Bravo"), ("/c", "Charlie"), ("/d", "Delta"), ("/fav", "Fav"), ("/elsewhere", "Elsewhere")] {
                pages[path] = "<!doctype html><title>\(title)</title><p id=q>\(title) words to quote here</p>"
            }
            server = LocalPageServer(pages: pages)
            server?.start { port in
                if let port { base = "http://127.0.0.1:\(port)" } else { self.check(false, "parityp01c: a loopback page server") }
                done()
            }
        }

        // The Space header, while this is the only Space.
        run { [self] in
            home = c.currentSpaceID
            guard c.store.orderedSpaces.count == 1, let s = c.store.space(home), let p = c.pageView(for: home) else {
                return note("SKIP parityp01c: the Space header needs the run to start with one Space (\(c.store.orderedSpaces.count))")
            }
            let name = s.name, icon = s.icon
            app?.settings.values.showsSpaceHeaderOnSingleUnnamed = false
            check(!p.header.isHidden && !c.store.offersHeaderToggle(ofSpace: home),
                  "parityp01c: a named Space shows its name row and offers no header switch (“\(name)”)")
            try? c.store.updateSpace(home) { $0.icon = nil }
            c.renameSpace(home, to: "")
            c.reloadAll(animated: false)
            p.layoutSubtreeIfNeeded()
            let hidden = p.header.isHidden && !p.navItems.contains { $0.id == SpacePageView.headerNavID }
            let menu = c.spaceMenu(spaceID: home)
            check(c.store.space(home)?.name == "" && hidden && item(menu, "Show Space Header") != nil,
                  "parityp01c: renamed to nothing, the only Space without an icon hides its name row, which isn't a keyboard stop, "
                  + "and its menu offers Show Space Header (name “\(c.store.space(home)?.name ?? "?")”, hidden \(hidden), menu \(titles(menu).prefix(5)))")
            fire(item(menu, "Show Space Header"))
            p.layoutSubtreeIfNeeded()
            let shown = !p.header.isHidden && app?.settings.values.showsSpaceHeaderOnSingleUnnamed == true
            let menu2 = c.spaceMenu(spaceID: home)
            fire(item(menu2, "Hide Space Header"))
            p.layoutSubtreeIfNeeded()
            check(shown && p.header.isHidden && app?.settings.values.showsSpaceHeaderOnSingleUnnamed == false,
                  "parityp01c: Show Space Header brings the row back and the menu then offers Hide Space Header, which hides it "
                  + "(shown \(shown), then hidden \(p.header.isHidden))")
            try? c.store.updateSpace(home) { $0.pinnedCollapsed = true }
            c.reloadAll(animated: false)
            let foldedShows = !p.header.isHidden
            try? c.store.updateSpace(home) { $0.pinnedCollapsed = false; $0.icon = .emoji("🌿") }
            c.reloadAll(animated: false)
            let iconShows = !p.header.isHidden && !c.store.offersHeaderToggle(ofSpace: home)
            check(foldedShows && iconShows,
                  "parityp01c: a folded pinned section keeps the row (so it can unfold: \(foldedShows)), and so does an icon (\(iconShows))")
            try? c.store.updateSpace(home) { $0.name = name; $0.icon = icon }
            c.reloadAll(animated: false)
        }

        // A second Space in this profile, and a second profile with a Space.
        step { [self] done in
            home = c.currentSpaceID
            let pid = c.store.profile(ofSpace: home).id
            same = (try? c.store.createSpace(name: "Same", profileID: pid, after: home))?.id ?? ""
            do {
                let p = try c.profiles.createProfile(name: "Second", emoji: "", color: nil)
                second = (try? c.store.createSpace(name: "Elsewhere", profileID: p.id))?.id ?? ""
                c.reloadAll(animated: false)
                c.profiles.whenLoaded(p.id, { _ in done() }, failed: { done() })
            } catch {
                check(false, "parityp01c: a second profile (\(error))")
                done()
            }
        }

        // A Favorite's Move to ›.
        run { [self] in
            let pid = c.store.profile(ofSpace: home).id
            guard let otherPID = c.store.space(second)?.profileID else { return check(false, "parityp01c: the second profile's Space") }
            let t = open("/fav", "Fav", in: home)
            c.performDrop(.tab(t), to: .favorites(profileID: pid, index: 0))
            guard let fav = c.store.favorites(ofProfile: pid).first(where: { $0.savedURL?.hasSuffix("/fav") == true }) else {
                return check(false, "parityp01c: a Favorite to move")
            }
            let m = c.menu(for: .favorite(fav, c.store.liveTab(forItem: fav.id)))
            let move = item(m, "Move to")
            let rows = move?.submenu.map(titles) ?? []
            let avatar = move?.submenu?.items.first?.image != nil
            fire(move?.submenu?.items.first { $0.title == "Second" })
            let moved = c.store.favorites(ofProfile: otherPID).contains { $0.id == fav.id } && !c.store.favorites(ofProfile: pid).contains { $0.id == fav.id }
            c.undo()
            let back = c.store.favorites(ofProfile: pid).contains { $0.id == fav.id }
            check(rows == ["Second"] && avatar && moved && back,
                  "parityp01c: a Favorite's Move to › lists the other profiles with a Space (\(rows), avatar \(avatar)) and moves it to that "
                  + "profile's Favorites (\(moved)); ⌘Z brings it back (\(back))")
        }

        // A folder: Reset all tabs in this Folder, Move to ›, Turn into Space.
        var folder = "", a = "", b = "", d = "", nested = ""
        run { [self] in
            c.switchToSpace(home, animated: false)
            let ta = open("/a", "Alpha", in: home), tb = open("/b", "Bravo", in: home), td = open("/d", "Delta", in: home)
            c.performDrop(.tab(ta), to: .pinned(spaceID: home, parentID: nil, index: 0))
            c.performDrop(.tab(tb), to: .pinned(spaceID: home, parentID: nil, index: 1))
            c.performDrop(.tab(td), to: .pinned(spaceID: home, parentID: nil, index: 2))
            guard let ia = c.store.tab(ta)?.itemID, let ib = c.store.tab(tb)?.itemID, c.store.tab(td)?.itemID != nil,
                  let n = try? c.store.createFolder(named: "Tickets", inSpace: home, containing: [.item(ib)]),
                  let f = try? c.store.createFolder(named: "Trip", inSpace: home, index: 0, containing: [.item(ia), .item(n.id)]) else {
                return check(false, "parityp01c: a folder with a tab and a nested folder")
            }
            try? c.store.setItemIcon(f.id, to: "🧳")
            folder = f.id; nested = n.id; a = ta; b = tb; d = td
            c.reloadAll(animated: false)
            let m = c.menu(for: .folder(c.store.item(f.id)!, depth: 0))
            let reset = item(m, "Reset all tabs in this Folder")
            check(reset?.isEnabled == false && item(m, "Move to") != nil && item(m, "Turn into Space") != nil,
                  "parityp01c: a folder's menu has Reset all tabs in this Folder (off: nothing to reset), Move to › and Turn into Space (\(titles(m)))")
        }
        // Drift the folder's nested tab and the tab outside it: each page goes elsewhere.
        let drifts: [(() -> String, String)] = [({ b }, "/c?b"), ({ d }, "/c?d")]
        for (tab, path) in drifts {
            step { [self] done in
                c.show(tab(), focus: false)
                waitUntil({ self.c.engineTab(for: tab())?.isLoading == false && self.c.engineTab(for: tab())?.url != nil }, timeout: 8) {
                    self.c.engineTab(for: tab())?.load(URL(string: page(path))!)
                    self.waitUntil({ self.c.store.isDrifted(tab()) }, timeout: 8) { done() }
                }
            }
        }
        step { [self] done in
            c.show(a, focus: false)
            let m = c.menu(for: .folder(c.store.item(folder)!, depth: 0))
            let on = item(m, "Reset all tabs in this Folder")?.isEnabled == true
            fire(item(m, "Reset all tabs in this Folder"))
            waitUntil({ !self.c.store.isDrifted(b) }, timeout: 5) {
                let reset = !self.c.store.isDrifted(b), outside = self.c.store.isDrifted(d)
                self.c.undo()
                self.waitUntil({ self.c.store.isDrifted(b) }, timeout: 5) {
                    self.check(on && reset && outside && self.c.store.isDrifted(b),
                               "parityp01c: Reset all tabs in this Folder takes the folder's tabs back, nested ones too (\(reset)), not one outside it "
                               + "(\(outside)); ⌘Z puts it back (\(self.c.store.isDrifted(b)))")
                    done()
                }
            }
        }
        run { [self] in
            c.moveItem(folder, toSpace: same)
            let moved = spaceOf(folder) == same && spaceOf(nested) == same && spaceOf(c.store.tab(a)?.itemID) == same
            c.undo()
            let back = spaceOf(folder) == home && spaceOf(nested) == home
            check(moved && back, "parityp01c: a folder's Move to › another Space takes everything inside with it (\(moved)); ⌘Z brings it back (\(back))")
        }
        settle()
        run { [self] in
            let before = c.store.orderedSpaces.map(\.id)
            let theme = c.store.space(home)?.theme
            c.turnFolderIntoSpace(folder)
            let after = c.store.orderedSpaces
            guard let made = after.first(where: { !before.contains($0.id) }) else { return check(false, "parityp01c: Turn into Space makes a Space") }
            let roots = c.store.pinnedRoots(ofSpace: made.id)
            let order = roots.map { $0.title ?? c.store.liveTab(forItem: $0.id).map(\.displayTitle) ?? "?" }
            let nestedKept = spaceOf(nested) == made.id && c.store.children(of: .pinned(spaceID: made.id), parent: nested).count == 1
            let placed = after.firstIndex { $0.id == made.id } == (after.firstIndex { $0.id == home } ?? -9) + 1
            let ok = made.name == "Trip" && made.icon == .emoji("🧳") && made.profileID == c.store.space(home)?.profileID && made.theme == theme
                && roots.count == 2 && roots.last?.id == nested && nestedKept && c.store.item(folder) == nil && placed
                && c.currentSpaceID == made.id
            check(ok, "parityp01c: Turn into Space makes “\(made.name)” \(made.icon.map { "\($0)" } ?? "-") right after this Space, same profile and theme, "
                  + "with the folder's rows as its pinned section in order (\(order)), the nested folder inside (\(nestedKept)), the folder gone "
                  + "(\(c.store.item(folder) == nil)), shown (\(c.currentSpaceID == made.id))")
            c.undo()
            let undone = c.store.space(made.id) == nil && c.store.item(folder) != nil
                && c.store.item(nested).map { $0.parentID == folder } == true
            check(undone, "parityp01c: ⌘Z undoes it in one step: no new Space, the folder back with its rows (\(undone))")
            c.switchToSpace(home, animated: false)
        }

        // Shared Quotes.
        step { [self] done in
            WindowController.copyWatchPasteboard = board
            WindowController.linkPasteboard = board
            c.show(a, focus: false)
            waitUntil({ self.c.engineTab(for: a)?.isLoading == false }, timeout: 8) {
                self.c.engineTab(for: a)?.evaluate("var r=document.createRange();r.selectNodeContents(document.getElementById('q'));"
                                                   + "getSelection().removeAllRanges();getSelection().addRange(r);true") { _ in done() }
            }
        }
        func offer(_ then: @escaping (Bool) -> Void) {
            step { [self] done in
                // hide() fades out before it hides: wait for that, so an offer seen next is this copy's.
                c.quoteLinkOffer?.hide()
                waitUntil({ self.c.quoteLinkOffer?.isHidden != false }, timeout: 2) {
                    let before = board.changeCount
                    board.clearContents()
                    board.setString("Alpha words to quote here", forType: .string)
                    self.c.offerQuoteLink(after: before, on: board)
                    self.waitUntil({ self.c.quoteLinkOffer?.isHidden == false }, timeout: 1.5) {
                        then(self.c.quoteLinkOffer?.isHidden == false)
                        done()
                    }
                }
            }
        }
        var offered = false, offeredOff = true, lines: [String] = []
        run { [self] in app?.settings.values.sharedQuotes = true }
        offer { offered = $0 }
        run { [self] in
            lines = c.contextCommandActions().map(\.title).filter { $0.hasSuffix("Shared Quotes") }
            c.contextCommandActions().first { $0.title == "Disable Shared Quotes" }?.run()
        }
        offer { offeredOff = $0 }
        run { [self] in
            let off = app?.settings.values.sharedQuotes == false
            let toast = c.toast.shownText
            let enable = c.contextCommandActions().map(\.title).filter { $0.hasSuffix("Shared Quotes") }
            c.contextCommandActions().first { $0.title == "Enable Shared Quotes" }?.run()
            check(offered && lines == ["Disable Shared Quotes"] && off && !offeredOff && enable == ["Enable Shared Quotes"]
                  && app?.settings.values.sharedQuotes == true,
                  "parityp01c: Shared Quotes (on by default) offer a link after ⌘C on the selection (\(offered)); the Command Bar's "
                  + "Disable Shared Quotes turns it off (\(off), “\(toast ?? "-")”, no offer \(!offeredOff)) and Enable Shared Quotes back on (\(lines) → \(enable))")
        }
        offer { _ in }
        run { [self] in
            guard let o = c.quoteLinkOffer, !o.isHidden else { return check(false, "parityp01c: the offer to right-click") }
            let e = NSEvent.mouseEvent(with: .rightMouseDown, location: o.convert(NSPoint(x: 10, y: 10), to: nil), modifierFlags: [], timestamp: 0,
                                       windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            let m = e.flatMap { o.menu(for: $0) }
            let names = m.map(titles) ?? []
            fire(m?.items.first { $0.title == "Disable Shared Quotes" })
            check(names == ["Disable Shared Quotes"] && app?.settings.values.sharedQuotes == false,
                  "parityp01c: the offer's right-click menu has Arc's Disable Shared Quotes, which turns them off (\(names))")
            app?.settings.values.sharedQuotes = true
            WindowController.copyWatchPasteboard = .general
            WindowController.linkPasteboard = .general
            board.releaseGlobally()
            server?.stop()
        }
    }
}
#endif
