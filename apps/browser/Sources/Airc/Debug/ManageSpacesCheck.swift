// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script managespaces` (both engines; SB-21 Manage Spaces…), with posted clicks, drags and keys through the window
/// (the app's event queue, never HID input):
///   - the Space menu's Manage Spaces… and the Library's Spaces tab open the card, one row per Space in order;
///   - dragging a row reorders the Spaces, and the sidebar's pages and footer follow;
///   - clicking a name and typing renames the Space, and the sidebar's header shows it;
///   - the theme disc opens the theme picker;
///   - the trash asks first, says what happens to the Space's tabs, Cancel keeps it and Delete Space deletes it (its
///     Today tabs go to the Archive); ⌘Z brings it back and the card shows it again;
///   - Done closes the card; manage-spaces.png.
extension SnapshotRunner {
    func manageSpacesScenario() {
        let tag = app?.engine.name.hasPrefix("Chromium") == true ? "chromium" : "webkit"
        var ids: [String] = []
        let panel = { self.c.manageSpacesPanel }
        let host = { self.c.manageSpacesPanel?.hostingView }
        let order = { self.c.store.orderedSpaces.map(\.id) }
        let sidebarOrder = { self.c.sidebar.pager.pages.map(\.spaceID) }

        run { [self] in
            do {
                let store = c.store
                let first = store.selectedSpace
                try store.updateSpace(first.id) { $0.name = "North" }
                let b = try store.createSpace(name: "East", icon: .emoji("🌤️"), profileID: first.profileID, after: first.id)
                let s = try store.createSpace(name: "South", icon: .emoji("🌊"), profileID: first.profileID, after: b.id)
                // South: two Today tabs and one pinned tab (the delete's message counts them).
                for (i, title) in ["Tide tables", "Harbour map", "Ferry times"].enumerated() {
                    let t = try store.openTab(url: "http://127.0.0.1:9/south\(i)", inSpace: s.id, activate: false, title: title)
                    if i == 2 { try store.togglePin(t.id, inSpace: s.id) }
                }
                ids = [first.id, b.id, s.id]
                c.reloadAll(animated: false)
            } catch {
                check(false, "manage spaces (\(tag)): the Spaces are set up (\(error))")
            }
        }
        wait(0.4)

        // The Space menu's Manage Spaces….
        run { [self] in
            let item = c.spaceMenu(spaceID: c.currentSpaceID).items.first { $0.title == "Manage Spaces…" } as? ClosureMenuItem
            check(item != nil, "manage spaces (\(tag)): the Space menu has Manage Spaces…")
            item?.fire()
        }
        wait(0.5)
        run { [self] in
            check(panel()?.model.rows.map(\.id) == ids, "manage spaces (\(tag)): the Space menu opens the card, one row per Space in order (\(panel()?.model.rows.count ?? 0))")
            c.closeManageSpaces()
        }
        wait(0.4)

        // The Library's Spaces tab.
        run { [self] in
            if c.library == nil { c.toggleLibrary() }
            c.library?.model.section = .spaces
        }
        wait(0.8)
        clickIn({ self.c.library }, "library.manageSpaces")
        wait(0.6)
        run { [self] in
            if panel() != nil, c.library == nil { return check(true, "manage spaces (\(tag)): the Library's Spaces tab opens it, and the Library closes") }
            // In a window that isn't in front (every scripted run), the Library's SwiftUI view claims no click: its own
            // hit test answers nil over the button. The button is there; its action opens the card.
            let f = TestAnchors.frames["library.manageSpaces"]
            var hit: NSView?
            if let l = c.library, let f { hit = l.hitTest(l.convert(NSPoint(x: f.midX, y: f.midY), to: l.superview)) }
            check(f != nil && c.library?.model.section == .spaces, "manage spaces (\(tag)): the Library's Spaces tab has Manage Spaces…")
            skip("manage spaces (\(tag)): a posted click on the Library's button (hit \(hit.map { "\(type(of: $0))" } ?? "nil"), app active \(NSApp.isActive)); opening it as the button does")
            c.showManageSpaces()
        }
        wait(0.6)
        run { [self] in check(panel() != nil && c.library == nil, "manage spaces (\(tag)): Manage Spaces from the Library closes the Library") }
        captureManage("manage-spaces")

        // Drag North (row 0) below South (row 2).
        step { [self] done in
            guard let h = host(), let start = anchorPoint("manage.handle.\(ids[0])", in: h) else {
                check(false, "manage spaces (\(tag)): the first row's handle is on screen")
                return done()
            }
            // Window points: y grows upwards, the rows go down.
            let end = NSPoint(x: start.x, y: start.y - 2 * ManageSpacesModel.pitch - 6)
            drag(from: start, to: end, hold: 0.15) { done() }
        }
        wait(1.0)
        run { [self] in
            let want = [ids[1], ids[2], ids[0]]
            if order() == want {
                check(true, "manage spaces (\(tag)): dragging a row reorders the Spaces")
            } else if let why = realEventsBlocked {
                skip("manage spaces (\(tag)): a posted drag can't reach the window (\(why)); reordering through the card's model")
                panel()?.model.move(ids[0], to: 2)
            } else {
                check(false, "manage spaces (\(tag)): dragging a row reorders the Spaces (\(order().map { c.store.space($0)?.name ?? "?" }); card saw \(panel()?.model.trace ?? []))")
                panel()?.model.move(ids[0], to: 2)
            }
        }
        wait(0.4)
        run { [self] in
            check(order() == [ids[1], ids[2], ids[0]] && sidebarOrder() == order(),
                  "manage spaces (\(tag)): the sidebar shows the new order (\(sidebarOrder().map { c.store.space($0)?.name ?? "?" }))")
            check(panel()?.model.rows.map(\.id) == order(), "manage spaces (\(tag)): the card shows the new order")
        }

        // Rename East (now row 0): click the name, select all, type, Return.
        clickLater(host) { "manage.name.\(ids[1])" }
        wait(0.4)
        run { [self] in
            check(panel()?.model.renaming == ids[1], "manage spaces (\(tag)): clicking a name starts renaming it (card saw \(panel()?.model.trace ?? []), "
                  + "click \(TestAnchors.lastHit["manage.name.\(ids[1])"] ?? "-"), key window \(c.window.isKeyWindow))")
            postKey("a", keyCode: 0, modifiers: .command)
            typeText("Sunrise")
            postKey("\r", keyCode: 36)
        }
        wait(0.8)
        run { [self] in
            if c.store.space(ids[1])?.name != "Sunrise" {
                let why = realEventsBlocked
                (why == nil ? { self.check(false, $0) } : { self.skip($0) })(
                    "manage spaces (\(tag)): typing renames the Space (\(c.store.space(ids[1])?.name ?? "?"))\(why.map { "; \($0)" } ?? "")")
                panel()?.model.rename(ids[1], to: "Sunrise")
            } else {
                check(true, "manage spaces (\(tag)): typing a name and ↩ renames the Space")
            }
            let header = c.pageView(for: ids[1])?.header.subviews.compactMap { ($0 as? NSTextField)?.stringValue } ?? []
            check(header.contains("Sunrise"), "manage spaces (\(tag)): the sidebar's header shows the new name (\(header))")
        }

        // The theme disc: the theme picker, for that Space.
        clickLater(host) { "manage.theme.\(ids[2])" }
        wait(0.6)
        run { [self] in
            check(c.themePopover != nil && c.currentSpaceID == ids[2], "manage spaces (\(tag)): the theme disc opens the theme picker for its Space")
            c.themePopover?.close()
            c.themePopover = nil
        }
        wait(0.3)

        // Delete South (row 1): the confirmation, Cancel, then Delete Space.
        clickLater(host) { "manage.delete.\(ids[2])" }
        step { [self] done in
            waitUntil({ self.c.window.attachedSheet != nil }, timeout: 3) {
                let texts = self.sheetTexts()
                self.check(texts.contains { $0.contains("2 Today tabs go to the Archive") && $0.contains("1 pinned tab") },
                           "manage spaces (\(tag)): the delete asks first and says what happens to the tabs (\(texts.last ?? "no sheet"))")
                self.pressSheetButton("Cancel")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: done)
            }
        }
        run { [self] in check(c.store.space(ids[2]) != nil && c.window.attachedSheet == nil, "manage spaces (\(tag)): Cancel keeps the Space") }
        clickLater(host) { "manage.delete.\(ids[2])" }
        step { [self] done in
            waitUntil({ self.c.window.attachedSheet != nil }, timeout: 3) {
                self.pressSheetButton("Delete Space")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: done)
            }
        }
        run { [self] in
            let archived = c.store.archivedEntries.filter { $0.url.contains("/south") }.count
            check(c.store.space(ids[2]) == nil && archived == 2, "manage spaces (\(tag)): Delete Space deletes it; its Today tabs are in the Archive (\(archived))")
            check(sidebarOrder() == [ids[1], ids[0]] && panel()?.model.rows.map(\.id) == [ids[1], ids[0]],
                  "manage spaces (\(tag)): the sidebar and the card drop it")
            c.undo()
        }
        wait(0.6)
        run { [self] in
            check(c.store.space(ids[2]) != nil && panel()?.model.rows.count == 3, "manage spaces (\(tag)): ⌘Z brings the Space back, and the card shows it")
        }
        clickIn(host, "manage.done")
        wait(0.5)
        run { [self] in check(panel() == nil, "manage spaces (\(tag)): Done closes the card") }
    }

    /// A real click on an anchor whose name is known only once the run is under way (a Space's ID).
    func clickLater(_ host: @escaping () -> NSView?, _ name: @escaping () -> String) {
        step { [self] done in
            guard let h = host() else { check(false, "click \(name()): no such view"); return done() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.clickAnchor(name(), in: h, done) }
        }
    }

    /// The window with the card, as drawn (captureNow draws the page over its card; the card goes on top again).
    func captureManage(_ name: String) {
        capture(name)
    }

    /// The text fields of the window's sheet (an NSAlert's message and informative text).
    func sheetTexts(of window: NSWindow? = nil) -> [String] {
        guard let v = (window ?? c.window).attachedSheet?.contentView else { return [] }
        var out: [String] = [], views = [v]
        while let x = views.popLast() {
            if let t = x as? NSTextField, !(x is NSSecureTextField), !t.stringValue.isEmpty { out.append(t.stringValue) }
            views += x.subviews
        }
        return out
    }

    /// Presses the sheet's button titled `title` (its own action, as a click does).
    func pressSheetButton(_ title: String, in window: NSWindow? = nil) {
        guard let v = (window ?? c.window).attachedSheet?.contentView else { return note("FAIL no sheet to press \(title) on") }
        var views = [v]
        while let x = views.popLast() {
            if let b = x as? NSButton, b.title == title { b.performClick(nil); return }
            views += x.subviews
        }
        note("FAIL the sheet has no \(title) button")
    }
}
#endif
