// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit

/// `--script parityp03`, then `parityp03-relaunch` and `parityp03-relaunch2` in fresh processes on the same data dir
/// (both engines): the sidebar without a mouse and with VoiceOver (P03; docs/user/shortcuts.md, "The sidebar from the
/// keyboard").
///   - from the page's keyboard, ⌃Space (Arc's Reveal Current Tab) opens the folded pinned section and the two closed
///     folders above the tab on screen and puts the keyboard on its row;
///   - the arrows walk every section (the Favorites grid, the Space header, folders, the pinned row, New Tab, Today), Tab
///     and ⇧Tab jump by section, Home and End to the ends; ← and → close and open folders and the pinned section in
///     place, with nothing loaded; type-to-select takes an "ä" as this Mac's layout types it; Space shows a tab and keeps
///     the keyboard, Return shows one and gives the page the keyboard, Esc gives it back to the page;
///   - VoiceOver's view through the NSAccessibility API: one outline of rows with names, role descriptions, the shown
///     tab selected, folders' expanded state and disclosure triangles, press and disclosure actions;
///   - Arc's numeric choices: ⌘1 with and without Favorites, ⌘9 the ninth or the last, both kept across two relaunches;
///   - ⌥ alone with the sidebar hidden: it slides out after the hold and back on release; ⌥ typing a character (⌥L, "@"
///     on this Mac's Austrian layout), ⌥⌘ and a click cancel it; the pointer in it keeps it; the setting turns it off;
///   - the three key priorities through KeyMonitor's arbitration: a page that used a key gets it again with Prefer
///     Websites, and a second press within a second runs the command with Use Both.
/// Keys go through the app's own event path (NSApp.sendEvent: the app's key monitor and OptionReveal's), then to the
/// first responder as AppKit does in a key window (a scripted window is never key); no HID posting.
extension SnapshotRunner {
    func parityP03Scenario() {
        switch script {
        case "parityp03-relaunch": parityP03Relaunch(expect: Self.p03ModeX, then: Self.p03ModeY, last: false)
        case "parityp03-relaunch2": parityP03Relaunch(expect: Self.p03ModeY, then: SidebarNavigationPreferences(), last: true)
        default: parityP03Main()
        }
    }

    /// The choices the first run leaves, and the ones the second run leaves.
    static let p03ModeX = SidebarNavigationPreferences(includeFavoritesInOrdering: false, switchToNinthItem: true, optionRevealsSidebar: true)
    static let p03ModeY = SidebarNavigationPreferences(includeFavoritesInOrdering: true, switchToNinthItem: false, optionRevealsSidebar: false)

    // MARK: Keys

    private static func arrow(_ k: Int) -> String { String(Character(UnicodeScalar(k)!)) }

    /// A key as AppKit makes it: through the app's event path, with OptionReveal's monitor after the app's key monitor.
    func p03Send(_ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags = [], ignoring: String? = nil, type: NSEvent.EventType = .keyDown) {
        guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: c.window.windowNumber, context: nil, characters: chars,
                                       charactersIgnoringModifiers: ignoring ?? chars, isARepeat: false, keyCode: code) else { return }
        NSApp.sendEvent(e)
    }

    func p03Key(_ name: String) {
        switch name {
        case "up": p03Send(Self.arrow(NSUpArrowFunctionKey), 126, [.function, .numericPad])
        case "down": p03Send(Self.arrow(NSDownArrowFunctionKey), 125, [.function, .numericPad])
        case "left": p03Send(Self.arrow(NSLeftArrowFunctionKey), 123, [.function, .numericPad])
        case "right": p03Send(Self.arrow(NSRightArrowFunctionKey), 124, [.function, .numericPad])
        case "home": p03Send(Self.arrow(NSHomeFunctionKey), 115, [.function])
        case "end": p03Send(Self.arrow(NSEndFunctionKey), 119, [.function])
        case "tab": p03Send("\t", 48)
        case "backtab": p03Send("\u{19}", 48, [.shift])
        case "return": p03Send("\r", 36)
        case "space": p03Send(" ", 49)
        case "escape": p03Send("\u{1b}", 53)
        case "ctrl-space": p03Send(" ", 49, [.control])
        default: break
        }
    }

    /// ⌥ alone down (left Option, code 58), or every modifier up.
    func p03Flags(_ mods: NSEvent.ModifierFlags) {
        p03Send("", 58, mods, ignoring: "", type: .flagsChanged)
    }

    /// A picture of the sidebar (our views draw themselves, so it works with the screen locked).
    func p03Shot(_ name: String, _ view: NSView? = nil) {
        guard let v = view ?? c.sidebar.superview.map({ _ in c.sidebar }), let img = render(v) else { return note("parityp03: no picture of \(name)") }
        try? img.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .png, properties: [:])?
            .write(to: dir.appendingPathComponent(name + ".png"))
        note("wrote \(name).png")
    }

    /// AppKit's dispatch for a key window, after the app's key monitor: the first responder's keyDown; ⌘ keys to the
    /// views and the main menu.
    func p03InstallKeyWindowDispatch() {
        KeyMonitor.testKeyWindowDispatch = { [weak self] event in
            guard let w = self?.c.window, event.window === w else { return false }
            if event.modifierFlags.contains(.command) {
                return w.performKeyEquivalent(with: event) || NSApp.mainMenu?.performKeyEquivalent(with: event) == true
            }
            w.sendEvent(event)
            return true
        }
    }

    // MARK: The main run

    private func parityP03Main() {
        let store = c.store
        var server: LocalPageServer?
        var base = ""
        var sid = "", profile = ""
        var ids: [String: String] = [:]   // name → item, tab or row ID
        var loadedBefore = 0
        func page() -> SpacePageView? { c.pageView(for: sid) }
        func focused() -> SidebarRowView? { c.window.firstResponder as? SidebarRowView }
        func focusedID() -> String { focused()?.navID ?? "none (\(String(describing: c.window.firstResponder.map { type(of: $0) })))" }
        func pageHasKeyboard() -> Bool {
            guard let id = c.shownTabID, let v = c.engineTab(for: id)?.view, let r = c.window.firstResponder as? NSView else { return false }
            return r === v || r.isDescendant(of: v)
        }
        func liveTabs() -> Int { store.state.tabs.count }
        func row(_ name: String) -> SidebarRowView? { page()?.navRow(ids[name]) }

        step { [self] done in
            server = LocalPageServer(responses: [:])
            server?.handler = { path in
                let file = path.dropFirst().replacingOccurrences(of: ".html", with: "")
                let titles = ["fav-Alpha": "Fav Alpha", "fav-Beta": "Fav Beta", "Aerzte": "Ärzte Wien"]
                let name = titles[file] ?? file
                return .init(body: "<!doctype html><meta charset=utf-8><title>\(name)</title><h1>\(name)</h1><input id=f>")
            }
            server?.start { port in
                if let port { base = "http://127.0.0.1:\(port)" } else { self.check(false, "parityp03: a loopback server") }
                done()
            }
        }
        run { [self] in
            guard !base.isEmpty else { return }
            p03InstallKeyWindowDispatch()
            ShortcutCenter.shared.setNavigation { $0 = SidebarNavigationPreferences() }
            profile = store.defaultProfile.id
            do {
                let s = try store.createSpace(name: "Keys", profileID: profile, after: c.currentSpaceID)
                sid = s.id
                // Two Favorites (the profile's), not loaded.
                for (i, n) in ["Alpha", "Beta"].enumerated() {
                    let t = try store.openTab(url: "\(base)/fav-\(n).html", inSpace: sid, activate: false, title: "Fav \(n)")
                    try store.move(.tab(t.id), to: .favorites(profileID: profile, index: i))
                    ids["fav\(n)"] = store.tab(t.id)?.itemID ?? ""
                    _ = try store.closeTab(t.id)
                }
                // A pinned tab (not loaded), and Docs › Inner › Deep, the tab on screen.
                let mail = try store.openTab(url: "\(base)/Mail.html", inSpace: sid, activate: false, title: "Mail")
                try store.togglePin(mail.id, inSpace: sid)
                ids["mail"] = store.tab(mail.id)?.itemID ?? ""
                _ = try store.closeTab(mail.id)
                let docs = try store.createFolder(named: "Docs", inSpace: sid)
                let sibling = try store.openTab(url: "\(base)/Sibling.html", inSpace: sid, activate: false, title: "Sibling")
                _ = try store.move([.tab(sibling.id)], intoFolder: docs.id)
                ids["sibling"] = store.tab(sibling.id)?.itemID ?? ""
                _ = try store.closeTab(sibling.id)
                let inner = try store.createFolder(named: "Inner", inSpace: sid, parentID: docs.id)
                ids["docs"] = docs.id
                ids["inner"] = inner.id
                // Today (newest first): Maps, then Ärzte.
                let aerzte = try store.openTab(url: "\(base)/Aerzte.html", inSpace: sid, title: "Ärzte Wien")
                let maps = try store.openTab(url: "\(base)/Maps.html", inSpace: sid, title: "Maps")
                ids["aerzte"] = aerzte.id
                ids["maps"] = maps.id
                let deep = try store.openTab(url: "\(base)/Deep.html", inSpace: sid, title: "Deep")
                _ = try store.move([.tab(deep.id)], intoFolder: inner.id)
                ids["deepTab"] = deep.id
                ids["deep"] = store.tab(deep.id)?.itemID ?? ""
            } catch { return check(false, "parityp03: the sidebar for the checks (\(error))") }
            c.switchToSpace(sid, animated: false)
            c.show(ids["deepTab"]!)
        }
        step { [self] done in waitUntil({ self.c.engineTab(for: ids["deepTab"] ?? "")?.isLoading == false }, timeout: 8) { done() } }
        run { [self] in
            // Fold everything above the tab on screen, and give the page the keyboard.
            try? store.toggleFolder(ids["inner"]!)
            try? store.toggleFolder(ids["docs"]!)
            try? store.updateSpace(sid) { $0.pinnedCollapsed = true }
            c.reloadAll(animated: false)
            loadedBefore = liveTabs()
        }
        // The store's own reload of those changes comes a turn later: the page takes the keyboard after it.
        wait(0.5)
        run { [self] in c.focusShownPage() }
        step { [self] done in waitUntil({ pageHasKeyboard() }, timeout: 2) { done() } }
        run { [self] in
            note("parityp03: layout \(ShortcutCenter.shiftedDigitSymbols()["\""] == "2" ? "German-style" : "other") digit row; "
                 + "window key \(c.window.isKeyWindow), on the active Space \(c.window.isOnActiveSpace), locked \(Self.screenLocked)")
        }
        wait(0.3)
        run { [self] in
            check(pageHasKeyboard(), "parityp03 focus: the page has the keyboard to start (\(focusedID()))")
            check(page()?.header.isEmphasized == true && page()?.navItem(SpacePageView.headerNavID)?.isExpanded == false,
                  "parityp03 header: folded over the tab on screen, the Space header is bold (P02)")
            check(ShortcutCenter.shared.map.command(for: KeyCombo("space", .control)) == "tabs.revealCurrent",
                  "parityp03 focus: ⌃Space is Reveal Current Tab (Arc's key; \(ShortcutCenter.shared.map.command(for: KeyCombo("space", .control)) ?? "no command"))")
            p03Key("ctrl-space")
            if focused() == nil { c.revealCurrentTab() }   // until the key is registered, the rest still runs
        }
        wait(0.3)
        run { [self] in
            let s = store.space(sid)
            check(s?.pinnedCollapsed == false && store.item(ids["docs"])?.isCollapsed == false && store.item(ids["inner"])?.isCollapsed == false,
                  "parityp03 reveal: the pinned section and both folders above the tab opened")
            check(focused()?.navID == ids["deep"] && focused()?.isKeyboardFocused == true,
                  "parityp03 reveal: the keyboard is on the tab's row (\(focusedID()))")
            check(focused()?.isAccessibilitySelected() == true && focused()?.isAccessibilityFocused() == true
                  && focused()?.accessibilityLabel() == "Deep" && focused()?.accessibilityRoleDescription() == "pinned tab",
                  "parityp03 VoiceOver: the focused row says Deep, pinned tab, selected (\(focused()?.accessibilityLabel() ?? "-"), "
                  + "\(focused()?.accessibilityRoleDescription() ?? "-"), selected \(focused()?.isAccessibilitySelected() ?? false))")
            check(page()?.header.isEmphasized == false, "parityp03 header: open again, the header isn't bold")
            p03Key("up")
        }
        // Up to Inner, close it in place, open it again, into it.
        run { [self] in
            check(focused()?.navID == ids["inner"], "parityp03 arrows: ↑ goes to the folder Inner (\(focusedID()))")
            p03Shot("parityp03-keyboard-focus")
            check(row("inner")?.isAccessibilityExpanded() == true && row("inner")?.accessibilityValue() as? String == "expanded",
                  "parityp03 VoiceOver: Inner reads as expanded")
            p03Key("left")
        }
        run { [self] in
            check(store.item(ids["inner"])?.isCollapsed == true && focused()?.navID == ids["inner"],
                  "parityp03 folders: ← closes Inner in place, the keyboard stays on it (\(focusedID()))")
            check(row("inner")?.isAccessibilityExpanded() == false
                  && (row("inner")?.accessibilityChildren()?.first as? NSAccessibilityElement)?.accessibilityValue() as? Int == 0,
                  "parityp03 VoiceOver: Inner reads as collapsed, its disclosure triangle 0")
            p03Key("right")
        }
        run { [self] in
            check(store.item(ids["inner"])?.isCollapsed == false, "parityp03 folders: → opens Inner again")
            p03Key("up"); p03Key("up")
        }
        run { [self] in
            check(focused()?.navID == ids["docs"], "parityp03 arrows: ↑ past Sibling to Docs (\(focusedID()))")
            p03Key("left")   // close Docs: Sibling, Inner and Deep go
            p03Key("down")
        }
        run { [self] in
            check(store.item(ids["docs"])?.isCollapsed == true && focused()?.navID == SpacePageView.newTabNavID,
                  "parityp03 folders: Docs closed, ↓ skips its rows to New Tab (\(focusedID()))")
            check(liveTabs() == loadedBefore && store.liveTab(forItem: ids["sibling"] ?? "") == nil && store.liveTab(forItem: ids["mail"] ?? "") == nil,
                  "parityp03 folders: opening and closing loaded nothing (\(liveTabs()) live tabs, \(loadedBefore) before)")
            p03Key("up"); p03Key("right")   // Docs, then open it with →
        }
        run { [self] in
            check(focused()?.navID == ids["docs"] && store.item(ids["docs"])?.isCollapsed == false,
                  "parityp03 folders: → on a closed Docs opens it (\(focusedID()))")
            p03Key("up"); p03Key("up")
        }
        run { [self] in
            check(focused()?.navID == SpacePageView.headerNavID, "parityp03 arrows: ↑ to the Space header (\(focusedID()))")
            check(focused()?.accessibilityRoleDescription() == "Space" && focused()?.accessibilityLabel() == "Keys"
                  && focused()?.accessibilityValue() as? String == "expanded",
                  "parityp03 VoiceOver: the header says Keys, Space, expanded (\(String(describing: focused()?.accessibilityValue())))")
            p03Key("left")
        }
        run { [self] in
            check(store.space(sid)?.pinnedCollapsed == true && focused()?.navID == SpacePageView.headerNavID,
                  "parityp03 header: ← folds the pinned section, the keyboard stays on the header")
            check(page()?.header.isEmphasized == true
                  && focused()?.accessibilityValue() as? String == "collapsed, contains the current tab",
                  "parityp03 header: folded over Deep, bold, and VoiceOver says it holds the current tab")
            p03Shot("parityp03-folded-header")
            p03Key("down")
        }
        run { [self] in
            check(focused()?.navID == SpacePageView.newTabNavID, "parityp03 arrows: folded, ↓ skips the pinned rows (\(focusedID()))")
            p03Key("up"); p03Key("right"); p03Key("up")
        }
        run { [self] in
            check(store.space(sid)?.pinnedCollapsed == false, "parityp03 header: → opens the pinned section")
            check(focused()?.navID == ids["favAlpha"], "parityp03 arrows: ↑ from the header to the Favorites (\(focusedID()))")
            check(focused()?.accessibilityRoleDescription() == "Favorite" && focused()?.accessibilityLabel() == "Fav Alpha"
                  && focused()?.accessibilityValue() as? String == "not loaded",
                  "parityp03 VoiceOver: Fav Alpha, Favorite, not loaded")
            p03Key("right")
        }
        run { [self] in
            check(focused()?.navID == ids["favBeta"], "parityp03 arrows: → along the Favorites grid (\(focusedID()))")
            p03Key("end")
        }
        run { [self] in
            let last = page()?.navItems.last?.id
            check(focused()?.navID == last && last == ids["aerzte"], "parityp03 arrows: End to the last Today row (\(focusedID()))")
            p03Key("backtab")
        }
        run { [self] in
            check(focused()?.navID == SpacePageView.newTabNavID, "parityp03 sections: ⇧Tab to the start of Today (\(focusedID()))")
            p03Key("backtab")
        }
        run { [self] in
            check(focused()?.navID == SpacePageView.headerNavID, "parityp03 sections: ⇧Tab to the pinned section (\(focusedID()))")
            p03Key("tab")
        }
        run { [self] in
            check(focused()?.navID == SpacePageView.newTabNavID, "parityp03 sections: Tab to Today (\(focusedID()))")
            p03Key("home")
        }
        run { [self] in
            check(focused()?.navID == ids["favAlpha"], "parityp03 arrows: Home to the first Favorite (\(focusedID()))")
            // Type-to-select with the letter as this Mac's layout types it.
            if let hit = Layout.code(typing: "ä", near: 39) {
                p03Send("ä", hit.code, hit.shift ? [.shift] : [], ignoring: "ä")
                check(focused()?.navID == ids["aerzte"], "parityp03 typeahead: ä (key \(hit.code) here) selects Ärzte Wien (\(focusedID()))")
            } else {
                p03Send("ä", 39, [], ignoring: "ä")
                check(focused()?.navID == ids["aerzte"], "parityp03 typeahead: ä selects Ärzte Wien (this layout has no ä key: the event as sent)")
            }
        }
        // Within a second of typing, Space is part of the name (as in Finder); after the pause it opens the row.
        wait(SpacePageView.typeaheadPause + 0.1)
        run { [self] in p03Key("space") }
        wait(0.4)
        run { [self] in
            check(c.shownTabID == ids["aerzte"] && focused()?.navID == ids["aerzte"],
                  "parityp03 open: Space shows Ärzte Wien and the sidebar keeps the keyboard (\(focusedID()))")
            check(focused()?.isAccessibilitySelected() == true
                  && page()?.outline.accessibilitySelectedRows()?.count == 1,
                  "parityp03 VoiceOver: Ärzte Wien is the one selected row")
            p03Key("up")
        }
        run { [self] in
            check(focused()?.navID == ids["maps"], "parityp03 arrows: ↑ to Maps (\(focusedID()))")
            p03Key("return")
        }
        wait(0.5)
        run { [self] in
            check(c.shownTabID == ids["maps"] && pageHasKeyboard(), "parityp03 open: Return shows Maps and the page gets the keyboard (\(focusedID()))")
            c.revealCurrentTab()
        }
        wait(0.2)
        run { [self] in
            check(focused()?.navID == ids["maps"], "parityp03 focus: Reveal Current Tab again lands on Maps (\(focusedID()))")
            p03Key("escape")
        }
        wait(0.4)
        run { [self] in
            check(pageHasKeyboard() && page()?.keyboardActive == false && page()?.navRowViews.allSatisfy { !$0.isKeyboardFocused } == true,
                  "parityp03 focus: Esc gives the keyboard back to the page (\(focusedID()))")
        }

        // VoiceOver's tree, through the NSAccessibility API.
        run { [self] in
            guard let p = page() else { return check(false, "parityp03 VoiceOver: the page") }
            func find(_ e: Any, _ depth: Int = 0) -> SidebarOutlineElement? {
                if let o = e as? SidebarOutlineElement { return o }
                guard depth < 30 else { return nil }
                let kids: [Any] = (e as? NSView)?.accessibilityChildren() ?? (e as? NSAccessibilityElement)?.accessibilityChildren() ?? []
                for k in kids { if let o = find(k, depth + 1) { return o } }
                return nil
            }
            let outline = c.window.contentView.flatMap { find($0) }
            check(outline === p.outline && outline?.accessibilityRole() == .outline && outline?.accessibilityLabel() == "Sidebar, Keys",
                  "parityp03 VoiceOver: the window's tree has one sidebar outline (\(outline?.accessibilityLabel() ?? "none"))")
            let rows = (outline?.accessibilityRows() ?? []).compactMap { $0 as? SidebarRowView }
            let names = rows.map { $0.accessibilityLabel() ?? "?" }
            let expected = ["Fav Alpha", "Fav Beta", "Keys", "Mail", "Docs", "Sibling", "Inner", "Deep", "New Tab", "Maps", "Ärzte Wien"]
            check(names == expected, "parityp03 VoiceOver: the rows in order (\(names.joined(separator: ", ")))")
            check(rows.allSatisfy { $0.accessibilityRole() == .row && $0.accessibilitySubrole() == .outlineRow && ($0.accessibilityParent() as AnyObject?) === p.outline },
                  "parityp03 VoiceOver: every row is an outline row of the sidebar")
            let roles = rows.map { $0.accessibilityRoleDescription() ?? "?" }
            check(roles == ["Favorite", "Favorite", "Space", "pinned tab", "folder", "pinned tab", "folder", "pinned tab", "button", "tab", "tab"],
                  "parityp03 VoiceOver: role descriptions (\(roles.joined(separator: ", ")))")
            let levels = rows.map { $0.accessibilityDisclosureLevel() }
            check(levels == [0, 0, 0, 1, 1, 2, 2, 3, 0, 0, 0], "parityp03 VoiceOver: levels (\(levels.map(String.init).joined(separator: " ")))")
            let selected = rows.filter { $0.isAccessibilitySelected() }.map { $0.accessibilityLabel() ?? "?" }
            check(selected == ["Maps"], "parityp03 VoiceOver: the shown tab is selected (\(selected))")
            check(rows.first { $0.accessibilityLabel() == "Docs" }?.isAccessibilityDisclosed() == true,
                  "parityp03 VoiceOver: Docs is disclosed")
            // VoiceOver's press: a folder closes in place (nothing loads), a tab shows.
            let before = liveTabs()
            _ = rows.first { $0.accessibilityLabel() == "Inner" }?.accessibilityPerformPress()
            check(store.item(ids["inner"])?.isCollapsed == true && liveTabs() == before,
                  "parityp03 VoiceOver: pressing Inner closes it, nothing loads")
            let triangle = page()?.navRow(ids["inner"])?.accessibilityChildren()?.first as? NSAccessibilityElement
            _ = triangle?.accessibilityPerformPress()
            check(store.item(ids["inner"])?.isCollapsed == false && triangle?.accessibilityRole() == .disclosureTriangle,
                  "parityp03 VoiceOver: its disclosure triangle opens it again")
            _ = page()?.navRow(ids["aerzte"])?.accessibilityPerformPress()
            check(c.shownTabID == ids["aerzte"], "parityp03 VoiceOver: pressing Ärzte Wien shows it")
            let w = c.window
            if let r = page()?.navRow(ids["mail"]),
               let e = NSEvent.mouseEvent(with: .rightMouseDown, location: r.convert(NSPoint(x: r.bounds.midX, y: r.bounds.midY), to: nil),
                                          modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                check(r.menu(for: e)?.items.isEmpty == false, "parityp03 VoiceOver: a row has the context menu Show Menu opens")
            }
        }

        // Arc's numeric choices, through ⌘1 and ⌘9.
        run { [self] in
            c.focusShownPage()
            check(store.commandNumberTarget(1, inSpace: sid)?.item?.id == ids["favAlpha"]
                  && store.commandNumberTarget(9, inSpace: sid)?.liveTab?.id == ids["aerzte"],
                  "parityp03 numbers: by default ⌘1 is the first Favorite and ⌘9 the last item")
            ShortcutCenter.shared.setNavigation { $0 = Self.p03ModeX }
            p03Send("1", 18, [.command])
        }
        step { [self] done in waitUntil({ self.c.shownTabID == self.c.store.liveTab(forItem: ids["mail"] ?? "")?.id }, timeout: 3) { done() } }
        run { [self] in
            check(store.liveTab(forItem: ids["mail"] ?? "")?.id == c.shownTabID && c.shownTabID != nil,
                  "parityp03 numbers: Favorites left out, ⌘1 opens the first pinned tab (Mail)")
            check(store.commandNumberTarget(9, inSpace: sid) == nil, "parityp03 numbers: ⌘9 as the ninth item: there are fewer, so nothing")
            let url = AppPaths.dataDirectory.appendingPathComponent("settings.json")
            let disk = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let saved = disk?["sidebarNavigation"] as? [String: Any]
            check(saved?["includeFavoritesInOrdering"] as? Bool == false && saved?["switchToNinthItem"] as? Bool == true,
                  "parityp03 numbers: both choices are in settings.json (\(saved.map { "\($0)" } ?? "none"))")
        }

        // Reduce Motion (P05's AircMotion switch, the path the system's setting takes): hiding and showing the sidebar
        // doesn't slide; the layout changes at once and the window cross-fades. Without it, the same toggle slides.
        run { [self] in if c.sidebarHidden { c.toggleSidebar() } }
        step { [self] done in waitUntil({ self.c.sidebarFraction >= 0.999 && !self.c.animator.isRunning("sidebar") }, timeout: 2) { done() } }
        var dockedCardX: CGFloat = 0
        for hide in [true, false] {
            let what = hide ? "hides" : "shows"
            run { [self] in
                if hide { dockedCardX = c.card.frame.minX }
                onMain { AircMotion.reduceMotionOverride = true }
                c.toggleSidebar()
                let fade = c.root.layer?.animation(forKey: kCATransition) as? CATransition
                check(c.sidebarHidden == hide && c.sidebarFraction == (hide ? 0 : 1) && !c.animator.isRunning("sidebar")
                        && fade?.type == .fade && fade?.duration == AircMotion.reducedDuration,
                      "parityp03 reduce motion: the toggle \(what) the sidebar at once, cross-faded (fraction \(c.sidebarFraction), sliding \(c.animator.isRunning("sidebar")), fade \(fade.map { "\($0.duration) s" } ?? "none"))")
                let cardX = c.card.frame.minX
                check(hide ? cardX < dockedCardX - 100 : abs(cardX - dockedCardX) < 0.5,
                      "parityp03 reduce motion: the page takes its \(hide ? "full" : "docked") width in the same frame (card at x \(cardX), docked \(dockedCardX))")
            }
            wait(0.06)
            run { [self] in
                check(c.sidebarFraction == (hide ? 0 : 1), "parityp03 reduce motion: nothing slides afterwards (fraction \(c.sidebarFraction) a few frames on)")
                onMain { AircMotion.reduceMotionOverride = nil }
            }
            wait(0.2)
        }
        run { [self] in
            onMain { AircMotion.reduceMotionOverride = false }
            c.toggleSidebar()
            check(c.animator.isRunning("sidebar") && c.sidebarFraction > 0, "parityp03 reduce motion: without it the same toggle slides (fraction \(c.sidebarFraction))")
            onMain { AircMotion.reduceMotionOverride = nil }
        }
        step { [self] done in waitUntil({ !self.c.animator.isRunning("sidebar") }, timeout: 2) { done() } }
        run { [self] in if c.sidebarHidden { c.toggleSidebar() } }
        step { [self] done in waitUntil({ !self.c.animator.isRunning("sidebar") }, timeout: 2) { done() } }

        // ⌥ alone.
        run { [self] in
            c.focusShownPage()
            if !c.sidebarHidden { c.toggleSidebar() }
            OptionReveal.shared.testWindowController = c
            OptionReveal.shared.testPointerInPanel = false
            OptionReveal.shared.clearLog()
        }
        step { [self] done in waitUntil({ self.c.sidebarFraction <= 0.001 }, timeout: 2) { done() } }
        run { [self] in p03Flags(.option) }
        wait(OptionReveal.holdDelay + 0.15)
        run { [self] in
            check(c.revealController?.isRevealed == true && OptionReveal.shared.log == ["reveal"],
                  "parityp03 option: held alone, ⌥ slides the hidden sidebar out (\(OptionReveal.shared.log))")
            p03Shot("parityp03-option-reveal", c.root)
            p03Flags([])
        }
        step { [self] done in waitUntil({ self.c.revealController?.isRevealed == false }, timeout: 2) { done() } }
        run { [self] in
            let gone = c.revealController?.isRevealed == false
            if !gone, let why = inputBlocked { note("FAIL-ENV parityp03 option: the slide back didn't finish (\(why))") }
            check(OptionReveal.shared.log == ["reveal", "hide"] && (gone || inputBlocked != nil),
                  "parityp03 option: released, it slides back (\(OptionReveal.shared.log), revealed \(c.revealController?.isRevealed ?? false))")
            OptionReveal.shared.clearLog()
            // ⌥ typing a character: ⌥L is "@" on this Mac's Austrian layout.
            p03Flags(.option)
            KeyMonitor.testKeyWindowDispatch = nil   // so OptionReveal's monitor sees the key, as it does in a key window
            let code = Layout.code(typing: "l", near: 37)?.code ?? 37
            p03Send(Layout.typed(code, shift: false, option: true) ?? "@", code, [.option], ignoring: "l")
            p03InstallKeyWindowDispatch()
        }
        wait(OptionReveal.holdDelay + 0.15)
        run { [self] in
            check(c.revealController?.isRevealed != true && OptionReveal.shared.log == ["cancel"],
                  "parityp03 option: ⌥ typing a character (⌥L) never shows it (\(OptionReveal.shared.log))")
            p03Flags([])
            OptionReveal.shared.clearLog()
            p03Flags(.option)
        }
        wait(OptionReveal.holdDelay + 0.15)
        run { [self] in
            p03Flags([.option, .command])   // ⌥⌘: a shortcut
            check(OptionReveal.shared.log == ["reveal", "hide", "cancel"], "parityp03 option: ⌥ then ⌘ cancels it (\(OptionReveal.shared.log))")
            p03Flags([])
        }
        step { [self] done in waitUntil({ self.c.revealController?.isRevealed == false }, timeout: 2) { done() } }
        run { [self] in
            OptionReveal.shared.clearLog()
            p03Flags(.option)
        }
        wait(OptionReveal.holdDelay + 0.15)
        run { [self] in
            // A click outside it while ⌥ is down (an ⌥-click on the page) ends it.
            if let e = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: c.window.frame.width - 40, y: 40), modifierFlags: [.option],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: c.window.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                OptionReveal.shared.handle(e)
            }
            check(OptionReveal.shared.log == ["reveal", "hide", "cancel"], "parityp03 option: an ⌥-click elsewhere cancels it (\(OptionReveal.shared.log))")
            p03Flags([])
        }
        step { [self] done in waitUntil({ self.c.revealController?.isRevealed == false }, timeout: 2) { done() } }
        run { [self] in
            OptionReveal.shared.clearLog()
            p03Flags(.option)
        }
        wait(OptionReveal.holdDelay + 0.15)
        run { [self] in
            OptionReveal.shared.testPointerInPanel = true
            p03Flags([])
            check(c.revealController?.isRevealed == true && OptionReveal.shared.log == ["reveal", "keep"],
                  "parityp03 option: the pointer in it, release keeps it out (\(OptionReveal.shared.log))")
            OptionReveal.shared.testPointerInPanel = false
            c.revealController?.hide()
        }
        step { [self] done in waitUntil({ self.c.revealController?.isRevealed == false }, timeout: 2) { done() } }
        run { [self] in
            ShortcutCenter.shared.setNavigation { $0.optionRevealsSidebar = false }
            OptionReveal.shared.clearLog()
            p03Flags(.option)
        }
        wait(OptionReveal.holdDelay + 0.15)
        run { [self] in
            check(c.revealController?.isRevealed != true && OptionReveal.shared.log.isEmpty,
                  "parityp03 option: turned off in Settings, ⌥ does nothing (\(OptionReveal.shared.log))")
            p03Flags([])
            ShortcutCenter.shared.setNavigation { $0.optionRevealsSidebar = true }
            // A field being edited keeps ⌥ for the text (⌥← ⌥→ by word).
            let field = NSTextField(frame: NSRect(x: -400, y: 10, width: 200, height: 22))
            c.root.addSubview(field)
            c.window.makeFirstResponder(field)
            OptionReveal.shared.clearLog()
            p03Flags(.option)
            DispatchQueue.main.asyncAfter(deadline: .now() + OptionReveal.holdDelay + 0.15) { [self] in
                check(c.revealController?.isRevealed != true && OptionReveal.shared.log.isEmpty && c.window.firstResponder is NSTextView,
                      "parityp03 option: while a field is being edited, ⌥ is the text's (\(OptionReveal.shared.log))")
                p03Flags([])
                field.removeFromSuperview()
            }
        }
        wait(OptionReveal.holdDelay + 0.3)
        run { [self] in
            // The keyboard with the sidebar hidden: Reveal Current Tab slides it out and focuses the row.
            c.revealCurrentTab()
            check(c.revealController?.isRevealed == true && focused()?.navID == ids["mail"],
                  "parityp03 focus: with the sidebar hidden, Reveal Current Tab slides it out on the tab's row (\(focusedID()))")
            p03Key("escape")
            c.revealController?.hide()
            OptionReveal.shared.testWindowController = nil
        }
        step { [self] done in waitUntil({ self.c.revealController?.isRevealed == false }, timeout: 2) { done() } }
        run { [self] in if c.sidebarHidden { c.toggleSidebar() } }

        // K06: Arc's tab switcher. Recent tabs in this order: Mail, Deep, Ärzte, Maps (newest first).
        for name in ["maps", "aerzte", "deep", "mail"] {
            run { [self] in
                let id = name == "deep" ? ids["deepTab"] : name == "mail" ? store.liveTab(forItem: ids["mail"] ?? "")?.id : ids[name]
                if let id { c.show(id) }
            }
            wait(0.15)
        }
        run { [self] in
            let mail = store.liveTab(forItem: ids["mail"] ?? "")?.id
            let names: [String: String] = [ids["maps"]!: "Maps", ids["aerzte"]!: "Ärzte", ids["deepTab"]!: "Deep", mail ?? "-": "Mail"]
            func name(_ id: String?) -> String { id.flatMap { names[$0] } ?? "other" }
            let recent = store.recentTabs(inSpace: sid).prefix(4).map { name($0) }
            check(recent == ["Mail", "Deep", "Ärzte", "Maps"], "parityp03 recent tabs: the order of use (\(recent))")
            // ⌃ held: each press goes one further back, ⇧ one forward; letting go ends the walk.
            p03Flags(.control)
            c.cycleRecentTab(1)
            let first = name(c.shownTabID)
            c.cycleRecentTab(1)
            let second = name(c.shownTabID)
            c.cycleRecentTab(-1)
            let back = name(c.shownTabID)
            p03Flags([])
            c.cycleRecentTab(1)
            let again = name(c.shownTabID)
            check([first, second, back, again] == ["Deep", "Ärzte", "Deep", "Mail"],
                  "parityp03 recent tabs: ⌃Tab, Tab, ⇧Tab with ⌃ held, then ⌃Tab again (\([first, second, back, again]))")
            // The same through the keys.
            if let m = mail { c.show(m) }
        }
        wait(0.2)
        run { [self] in
            let mail = store.liveTab(forItem: ids["mail"] ?? "")?.id
            let names: [String: String] = [ids["maps"]!: "Maps", ids["aerzte"]!: "Ärzte", ids["deepTab"]!: "Deep", mail ?? "-": "Mail"]
            func name(_ id: String?) -> String { id.flatMap { names[$0] } ?? "other" }
            c.focusShownPage()
            p03Flags(.control)
            p03Send("\t", 48, [.control])
            let first = name(c.shownTabID)
            p03Send("\t", 48, [.control])
            let second = name(c.shownTabID)
            p03Send("\u{19}", 48, [.control, .shift])
            let back = name(c.shownTabID)
            p03Flags([])
            check([first, second, back] == ["Deep", "Ärzte", "Deep"],
                  "parityp03 recent tabs: ⌃Tab ⌃Tab ⌃⇧Tab through the keys walk the recent tabs (\([first, second, back]))")
        }

        // ⇧↑ ⇧↓: rows picked from the keyboard, for the selection's keys (SB-36).
        run { [self] in
            c.show(ids["maps"]!)
            c.revealCurrentTab()
            p03Send(Self.arrow(NSDownArrowFunctionKey), 125, [.shift, .function, .numericPad])
            let sel = page()?.selection ?? []
            check(sel == [ids["maps"]!, ids["aerzte"]!] && c.window.firstResponder === page() && c.sidebarSelection?.ids == sel,
                  "parityp03 selection: ⇧↓ from Maps picks Maps and Ärzte, and the selection has the keyboard (\(sel.count) rows)")
            p03Send(Self.arrow(NSUpArrowFunctionKey), 126, [.shift, .function, .numericPad])
            check(page()?.selection == [ids["maps"]!], "parityp03 selection: ⇧↑ takes Ärzte back off")
            p03Key("down")
            check(page()?.selection.isEmpty == true && focused()?.navID == ids["aerzte"],
                  "parityp03 selection: ↓ leaves the selection with the keyboard on the next row (\(focusedID()))")
            p03Send(Self.arrow(NSDownArrowFunctionKey), 125, [.shift, .function, .numericPad])
            p03Key("escape")
        }
        wait(0.3)
        run { [self] in
            check(page()?.selection.isEmpty == true && pageHasKeyboard(),
                  "parityp03 selection: Esc clears it and the page has the keyboard again (\(focusedID()))")
        }

        // P04's seam: a link dragged in from another app lands where the page's drop line is.
        run { [self] in
            guard let p = page(), let docs = p.navRow(ids["docs"]), let maps = p.navRow(ids["maps"]) else {
                return check(false, "parityp03 drop: the rows")
            }
            if store.item(ids["docs"])?.isCollapsed == true { try? store.toggleFolder(ids["docs"]!) }
            let pb = NSPasteboard(name: NSPasteboard.Name("org.airc.check.p03.\(UUID().uuidString)"))
            pb.clearContents()
            let item = NSPasteboardItem()
            item.setString("\(base)/Dropped.html", forType: .URL)
            item.setString("Dropped", forType: SidebarFileImport.urlNameType)
            pb.writeObjects([item])
            let mid = docs.convert(NSPoint(x: docs.bounds.midX, y: docs.bounds.midY), to: nil)
            let over = P03Drag(pb, at: mid, in: c.window)
            let op = p.draggingUpdated(over)
            check(op == .copy && docs.isHovered, "parityp03 drop: over the middle of Docs, the folder lights up for a copy")
            let before = store.children(of: .pinned(spaceID: sid), parent: ids["docs"]).count
            check(p.performDragOperation(over), "parityp03 drop: the page takes the link")
            ids["dropBefore"] = String(before)
            // Between Maps and the row above it, in Today.
            let top = maps.convert(NSPoint(x: maps.bounds.midX, y: maps.bounds.minY + 2), to: nil)
            let pb2 = NSPasteboard(name: NSPasteboard.Name("org.airc.check.p03.\(UUID().uuidString)"))
            pb2.clearContents()
            pb2.setString("\(base)/Second.html", forType: .URL)
            let d2 = P03Drag(pb2, at: top, in: c.window)
            _ = p.draggingUpdated(d2)
            check(p.fileDestination(at: p.convert(top, from: nil)) == SidebarFileDestination(spaceID: sid, section: .today(index: 0)),
                  "parityp03 drop: just above the first Today row, it goes first in Today")
            p.draggingExited(d2)
            pb.releaseGlobally()
            pb2.releaseGlobally()
        }
        step { [self] done in
            waitUntil({ store.children(of: .pinned(spaceID: sid), parent: ids["docs"]).contains { $0.savedURL?.hasSuffix("/Dropped.html") == true } }, timeout: 5) { done() }
        }
        run { [self] in
            let kids = store.children(of: .pinned(spaceID: sid), parent: ids["docs"])
            check(kids.count == (Int(ids["dropBefore"] ?? "") ?? 0) + 1 && kids.last?.savedURL?.hasSuffix("/Dropped.html") == true,
                  "parityp03 drop: the link is a pinned tab at the end of Docs (\(kids.map(\.displayTitle)))")
        }

        // Key priority: KeyMonitor's arbitration with the page on screen (Use Both, Prefer Websites, Prefer Airc).
        run { [self] in
            guard let tab = c.shownTabID.flatMap({ c.engineTab(for: $0) }) else { return check(false, "parityp03 priority: a page") }
            let cmd = BrowserCommand("Open Location", "l", .command, id: "file.openLocation") { _ in }
            var ran = 0
            func offer() -> Bool { KeyMonitor.offerToPage(cmd, page: tab, engine: c.app?.engine, window: c.window) { ran += 1 } }
            let combo = KeyMonitor.combo(cmd)
            let center = ShortcutCenter.shared
            var results: [String] = []
            for p in KeyPriority.allCases {
                center.update { $0.setPriority(p, for: "file.openLocation") }
                ran = 0
                let first = offer()
                if first { KeyMonitor.pageReported(combo, pageUsedIt: true, window: c.window) }
                let second = offer()
                if second { KeyMonitor.pageReported(combo, pageUsedIt: true, window: c.window) }
                results.append("\(p.title): first \(first ? "page" : "Airc"), again \(second ? "page" : "Airc")")
                let want: (Bool, Bool) = p == .websites ? (true, false) : p == .websitesOnly ? (true, true) : (false, false)
                check(first == want.0 && second == want.1 && ran == 0,
                      "parityp03 priority: \(p.title): the page \(want.0 ? "gets the key first" : "never gets it")"
                      + (p == .websites ? ", a second press within a second runs Airc's command" : p == .websitesOnly ? ", and keeps it on a second press" : "")
                      + " (\(results.last!))")
            }
            center.update { $0.reset("file.openLocation") }
        }
        // Settings → Shortcuts: the priority picker on Open Location and the Sidebar section at the end of the page.
        run { [self] in
            ShortcutCenter.shared.update { $0.setPriority(.websitesOnly, for: "file.openLocation") }
            c.app?.showSettings(page: .shortcuts)
            if let w = c.app?.settingsWindow?.window { w.setFrameOrigin(NSPoint(x: -6000, y: 200)) }
        }
        wait(0.8)
        run { [self] in
            guard let w = c.app?.settingsWindow?.window, let view = w.contentView else { return note("parityp03: no Settings window") }
            func scrollViews(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? v.subviews.flatMap(scrollViews) }
            let scroll = scrollViews(view).max { $0.frame.height < $1.frame.height }
            p03Shot("parityp03-settings-top", view)
            if let scroll, let doc = scroll.documentView {
                doc.scroll(NSPoint(x: 0, y: doc.isFlipped ? max(0, doc.bounds.height - scroll.contentSize.height) : 0))
            }
        }
        wait(0.4)
        run { [self] in
            if let view = c.app?.settingsWindow?.window.contentView { p03Shot("parityp03-settings-sidebar", view) }
            ShortcutCenter.shared.update { $0.reset("file.openLocation") }
            c.app?.settingsWindow?.window.orderOut(nil)
        }
        run { [self] in
            // The relaunches check the choices that the first run leaves.
            ShortcutCenter.shared.setNavigation { $0 = Self.p03ModeX }
            KeyMonitor.testKeyWindowDispatch = nil
            server?.stop()
        }
    }

    // MARK: Relaunches

    /// A fresh process on the same data: the choices the last run left are read back and work; then the next ones.
    private func parityP03Relaunch(expect: SidebarNavigationPreferences, then next: SidebarNavigationPreferences, last: Bool) {
        let tag = script
        run { [self] in
            let center = ShortcutCenter.shared
            check(center.navigation == expect && SidebarNavigation.preferences == expect,
                  "\(tag): the sidebar choices survived the relaunch (\(center.navigation))")
            let store = c.store
            guard let s = store.state.spaces.values.first(where: { $0.name == "Keys" }) else {
                return check(false, "\(tag): the Keys Space from the first run")
            }
            c.switchToSpace(s.id, animated: false)
            let first = store.commandNumberTarget(1, inSpace: s.id)
            let favs = store.favorites(ofProfile: s.profileID)
            let firstIsFavorite = first?.item.map { i in favs.contains { $0.id == i.id } } ?? false
            check(firstIsFavorite == expect.includeFavoritesInOrdering,
                  "\(tag): ⌘1 is \(expect.includeFavoritesInOrdering ? "the first Favorite" : "the first item after the Favorites") (\(first?.item?.displayTitle ?? first?.liveTab?.displayTitle ?? "none"))")
            let ninth = store.commandNumberTarget(9, inSpace: s.id)
            check(expect.switchToNinthItem ? ninth == nil : ninth?.id == store.sidebarEntries(ofSpace: s.id).filter { if case .folder = $0 { return false }; return true }.last?.id,
                  "\(tag): ⌘9 is \(expect.switchToNinthItem ? "the ninth item (none here)" : "the last item")")
            // Through the key itself.
            p03InstallKeyWindowDispatch()
            c.focusShownPage()
            p03Send("1", 18, [.command])
        }
        step { [self] done in
            waitUntil({ self.c.shownTabID != nil && self.c.store.commandNumberTarget(1, inSpace: self.c.currentSpaceID)?.liveTab?.id == self.c.shownTabID }, timeout: 3) { done() }
        }
        run { [self] in
            check(c.store.commandNumberTarget(1, inSpace: c.currentSpaceID)?.liveTab?.id == c.shownTabID,
                  "\(tag): ⌘1 opened that item")
            check(OptionReveal.shared.phase == .idle && SidebarNavigation.preferences.optionRevealsSidebar == expect.optionRevealsSidebar,
                  "\(tag): the ⌥ switch survived too (\(expect.optionRevealsSidebar ? "on" : "off"))")
            ShortcutCenter.shared.setNavigation { $0 = next }
            KeyMonitor.testKeyWindowDispatch = nil
            if last { note("\(tag): back to Arc's defaults") }
        }
    }
}

/// A drag from another app, as AppKit hands it to a drop target (the check can't start a real one).
final class P03Drag: NSObject, NSDraggingInfo {
    private let pb: NSPasteboard
    private let point: NSPoint
    private weak var window: NSWindow?
    init(_ pb: NSPasteboard, at point: NSPoint, in window: NSWindow) {
        self.pb = pb
        self.point = point
        self.window = window
    }
    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .link, .generic] }
    var draggingLocation: NSPoint { point }
    var draggedImageLocation: NSPoint { point }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pb }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
#endif
