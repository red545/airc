// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// `--script shortcutremap`: Settings → Shortcuts (CB-4) end to end, with real key events (NSApp.postEvent) on a
/// loopback page. Keys are recorded in the Settings window's recorder (its row's click is the one stand-in: posted
/// clicks on SwiftUI buttons miss in a window that isn't key); the page side uses the shortcuts check's key-window
/// stand-in (ShortcutsCheck.swift). It remaps ⌘L to ⌥⌘L (⌘L then reaches the page and the browser does nothing, ⌥⌘L
/// opens the address editor), swaps Pin with Library's key, refuses ⌘H, warns about ⌘B, clears with Delete, resets
/// one row into a conflict and everything at once, and checks the menus, settings.json, a private window and Little
/// Arc after each change. Last, Airc first (Arc's "Prefer Arc") on ⌘L: a page that uses ⌘L no longer gets it, in the
/// main window and a private window, and Websites first gives it back.
extension SnapshotRunner {
    private static let remapPage = """
        <!doctype html><meta charset=utf-8><title>Remap</title>
        <input id=in value="one two" autocomplete=off style="position:absolute;left:40px;top:40px;width:300px">
        <script>
        var inp=document.getElementById('in'),log=[],prevent={},loadID=Math.random().toString(36).slice(2);
        function combo(e){return (e.metaKey?'cmd+':'')+(e.ctrlKey?'ctrl+':'')+(e.altKey?'alt+':'')+(e.shiftKey?'shift+':'')+e.code}
        addEventListener('keydown',function(e){var c=combo(e);if(prevent[c])e.preventDefault();log.push('kd '+c)},true);
        function reset(){prevent={};log=[]}
        function state(){var l=log;log=[];return JSON.stringify({log:l,href:location.href,loadID:loadID})}
        </script>
        """

    func shortcutRemapScenario() {
        run { [self] in
            let symbols = ShortcutCenter.shiftedDigitSymbols()
            _ = ShortcutCenter.shared.update { $0.assign(KeyCombo("l", .command), to: "view.capture", resolving: .clearOther) }
            check(ShortcutCenter.hint("file.openLocation", "⌘L").isEmpty, "shortcutremap: displaced default does not advertise a shortcut")
            _ = ShortcutCenter.shared.update { $0.resetAll(); return .done }
            check(!symbols.isEmpty && symbols.values.contains("2"), "shortcutremap: active keyboard layout supplies digit migration")
        }
        Key.strict = app?.engine.name.hasPrefix("Chromium") == true
        let center = ShortcutCenter.shared, editor = ShortcutsEditor.shared
        var server: LocalPageServer?
        var tabID = ""
        var port: UInt16 = 0
        let page = { self.c.engineTab(for: tabID) }
        let cmdL = Key.cmd("⌘L", 37, "l"), optCmdL = Key("⌥⌘L", 37, "¬", "l", [.command, .option])
        let shiftCmdL = Key.cmdShift("⇧⌘L", 37, "L"), cmdD = Key.cmd("⌘D", 2, "d")
        let settingsWindow = { self.app?.settingsWindow?.window }

        /// A key into the Settings window, where the recorder listens.
        func record(_ id: String, _ k: Key) {
            run { editor.start(id) }
            step { [self] done in
                guard let w = settingsWindow() else { check(false, "shortcutremap: the Settings window is open"); return done() }
                post(k, to: w)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: done)
            }
        }
        func key(_ id: String) -> String { center.map.key(id)?.display ?? "none" }
        func menuKey(_ title: String) -> String {
            guard let item = Self.commandItem(title) else { return "no item" }
            let (k, m) = (item.keyEquivalent, item.keyEquivalentModifierMask)
            return ShortcutCenter.combo(k, m)?.display ?? "none"
        }
        func storedOnDisk() -> [String: String]? {
            let url = AppPaths.dataDirectory.appendingPathComponent("settings.json")
            guard let data = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return json["shortcuts"] as? [String: String] ?? [:]
        }

        run { [self] in
            note("shortcutremap: window key \(c.window.isKeyWindow), app active \(NSApp.isActive), on the active Space \(c.window.isOnActiveSpace), "
                 + "screen locked \(Self.screenLocked), keyboard layout \(Self.layoutName)")
            Self.emulateKeyWindow(c) { [weak self] in self?.note($0) }
            check(center.map.stored.isEmpty && key("file.openLocation") == "⌘L" && menuKey("Open Location…") == "⌘L"
                  && menuKey("Library") == "⇧⌘L" && menuKey("Pin / Unpin Tab") == "⌘D",
                  "shortcutremap: the defaults are today's table (Open Location \(menuKey("Open Location…")), Library \(menuKey("Library")), "
                  + "Pin \(menuKey("Pin / Unpin Tab")), stored \(center.map.stored))")
        }
        step { [self] done in
            guard let s = LocalPageServer(pages: ["/remap": Self.remapPage]) else { check(false, "shortcutremap: the loopback server starts"); return done() }
            server = s
            s.start { p in
                guard let p, let t = try? self.c.store.openTab(url: "http://127.0.0.1:\(p)/remap", inSpace: self.c.currentSpaceID, title: "Remap") else {
                    self.check(false, "shortcutremap: the loopback server starts"); return done()
                }
                port = p
                tabID = t.id
                self.c.reloadAll(animated: false)
                self.c.show(t.id, focus: true)
                done()
            }
        }
        waitForPage()
        step { [self] done in clickIntoPage(done) }
        run { [self] in app?.showSettings(page: .shortcuts) }
        wait(0.8)

        // MARK: ⌘L → ⌥⌘L
        record("file.openLocation", optCmdL)
        run { [self] in
            let disk = storedOnDisk()
            check(editor.recording == nil && key("file.openLocation") == "⌥⌘L" && menuKey("Open Location…") == "⌥⌘L"
                  && disk == ["file.openLocation": "alt+cmd+l"],
                  "shortcutremap: recording ⌥⌘L gives Open Location ⌥⌘L (map \(key("file.openLocation")), menu \(menuKey("Open Location…")), "
                  + "settings.json \(disk.map { "\($0)" } ?? "unreadable"))")
            // A fresh read of the file, as the next launch does.
            let again = ShortcutMap(commands: center.map.commands, stored: disk ?? [:])
            check(again == center.map, "shortcutremap: settings.json reads back as the same map")
            captureSettings("settings-shortcuts.png")
        }
        step { [self] done in refocus(page, done) }
        run { [self] in
            // AppKit's own matcher, which a key nobody handled reaches last: a freed ⌘L must match no item (it once
            // matched Library's "l" + ⇧; menus now spell ⇧ letters "L", ShortcutCenter.menuEquivalent).
            guard let menu = NSApp.mainMenu, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: cmdL.mods, timestamp: 0,
                                                                     windowNumber: c.window.windowNumber, context: nil, characters: cmdL.chars,
                                                                     charactersIgnoringModifiers: cmdL.ignoring, isARepeat: false, keyCode: cmdL.code) else { return }
            let took = menu.performKeyEquivalent(with: e)
            check(!took && c.library == nil && c.commandBar == nil,
                  "shortcutremap: AppKit's main menu takes no freed ⌘L (took \(took), library \(c.library != nil), command bar \(c.commandBar != nil))")
            if c.library != nil { c.toggleLibrary() }
            c.closeCommandBar()
        }
        keyCase(cmdL, page: page, setup: "reset();inp.focus()", settle: 0.4) { [self] _, log in
            check(log.contains("kd \(cmdL.page)") && c.commandBar == nil && c.library == nil,
                  "shortcutremap: ⌘L goes to the page and opens nothing (command bar \(c.commandBar.map { "\($0.mode)" } ?? "none"), library \(c.library != nil), log \(log.joined(separator: ", ")))")
        }
        step { [self] done in refocus(page, done) }
        keyCase(optCmdL, page: page, setup: "reset();inp.focus()", settle: 0.4) { [self] _, log in
            let mode = c.commandBar.map { "\($0.mode)" } ?? "none"
            check(mode == "\(CommandBarMode.editURL)", "shortcutremap: ⌥⌘L opens the address editor (command bar \(mode), log \(log.joined(separator: ", ")))")
            c.closeCommandBar()
        }
        wait(0.3)

        // MARK: Swap Pin and Library
        record("tabs.pin", shiftCmdL)
        run { [self] in
            let conflict = editor.conflict
            check(conflict?.other == "tabs.library" && key("tabs.pin") == "⌘D",
                  "shortcutremap: ⇧⌘L for Pin asks first: it's Library's (conflict \(conflict.map { "\($0.other)" } ?? "none"), Pin still \(key("tabs.pin")))")
            editor.resolve(.swap)
            check(key("tabs.pin") == "⇧⌘L" && key("tabs.library") == "⌘D" && menuKey("Pin / Unpin Tab") == "⇧⌘L" && menuKey("Library") == "⌘D",
                  "shortcutremap: Swap gives Pin ⇧⌘L and Library ⌘D (map \(key("tabs.pin")) / \(key("tabs.library")), "
                  + "menus \(menuKey("Pin / Unpin Tab")) / \(menuKey("Library")))")
        }
        var pinnedBefore = false
        run { [self] in
            pinnedBefore = c.store.tab(c.shownTabID ?? "")?.itemID != nil
        }
        keyCase(shiftCmdL, page: page, setup: "reset();inp.focus()", settle: 0.4) { [self] _, log in
            let pinned = c.store.tab(c.shownTabID ?? "")?.itemID != nil
            check(pinned != pinnedBefore && c.library == nil,
                  "shortcutremap: ⇧⌘L a page doesn't use pins the tab, not the Library (pinned \(pinnedBefore) → \(pinned), "
                  + "library \(c.library != nil), log \(log.joined(separator: ", ")))")
            if pinned != pinnedBefore { c.togglePin() }
        }
        wait(0.3)
        step { [self] done in refocus(page, done) }
        keyCase(cmdD, page: page, setup: "reset();inp.focus()", settle: 0.6) { [self] _, log in
            check(c.library != nil, "shortcutremap: ⌘D a page doesn't use opens the Library (log \(log.joined(separator: ", ")))")
            if c.library != nil { c.toggleLibrary() }
        }
        wait(0.6)

        // MARK: Refused, warned, cleared
        record("tabs.pin", Key.cmd("⌘H", 4, "h"))
        run { [self] in
            let n = editor.notices["tabs.pin"]
            check(n?.kind == .refused && editor.recording == "tabs.pin" && key("tabs.pin") == "⇧⌘L",
                  "shortcutremap: ⌘H is refused and the recorder waits for another key (\(n?.text ?? "no note"), Pin \(key("tabs.pin")))")
        }
        step { [self] done in
            if let w = settingsWindow() { post(Key("Esc", 53, "\u{1b}", nil, []), to: w) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: done)
        }
        run { [self] in
            check(editor.recording == nil && key("tabs.pin") == "⇧⌘L", "shortcutremap: Esc stops recording and keeps the key (Pin \(key("tabs.pin")))")
        }
        record("tabs.favorite", Key.cmd("⌘B", 11, "b"))
        run { [self] in
            let n = editor.notices["tabs.favorite"]
            check(key("tabs.favorite") == "⌘B" && n?.kind == .warning && n?.text.contains("again within a second") == true,
                  "shortcutremap: ⌘B for Add to Favorites is allowed with the page-first note (\(key("tabs.favorite")), \(n?.text ?? "no note"))")
        }
        record("tabs.favorite", Key("⌫", 51, "\u{7f}", nil, []))
        run { [self] in
            check(key("tabs.favorite") == "none" && center.map.stored["tabs.favorite"] == nil,
                  "shortcutremap: Delete removes the shortcut (\(key("tabs.favorite")), stored \(center.map.stored))")
        }

        // MARK: Every window: a private window and Little Arc
        var privateWindow: PrivateWindowController?
        step { [self] done in
            guard let app else { return done() }
            PrivateBrowsing.shared.open(app: app) { p in privateWindow = p; DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: done) }
        }
        step { [self] done in
            guard let p = privateWindow else { check(false, "shortcutremap: a private window opens"); return done() }
            Self.emulateKeyWindow(p.window) { [weak self] in self?.note($0) }
            p.closeCommandBar()   // a new private window opens with its Command Bar
            post(cmdL, to: p.window)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let before = p.commandBar != nil
                self.post(optCmdL, to: p.window)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.check(!before && p.commandBar != nil,
                               "shortcutremap: in a private window ⌘L opens nothing (\(before)) and ⌥⌘L its address editor (\(p.commandBar != nil))")
                    p.closeWindow()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: done)
                }
            }
        }
        var little: LittleArcController?
        step { [self] done in
            little = app?.openLittleArc(url: URL(string: "data:text/html,%3Ctitle%3ELittle%3C/title%3Elittle"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: done)
        }
        step { [self] done in
            guard let l = little else { skip("shortcutremap: Little Arc (no window)"); return done() }
            Self.emulateKeyWindow(l.window) { [weak self] in self?.note($0) }
            l.window.makeFirstResponder(nil)
            post(cmdL, to: l.window)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let editing = { (l.window.firstResponder as? NSTextView)?.delegate === l.addressField }
                let before = editing()
                self.post(optCmdL, to: l.window)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self.check(!before && editing(), "shortcutremap: in Little Arc ⌘L leaves the address field alone (\(before)) and ⌥⌘L focuses it (\(editing()))")
                    l.closeWindow()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: done)
                }
            }
        }
        run { [self] in Self.emulateKeyWindow(c) { [weak self] in self?.note($0) } }

        // MARK: Reset one, reset all
        run { [self] in
            editor.reset("tabs.pin")
            let conflict = editor.conflict
            check(conflict?.other == "tabs.library", "shortcutremap: resetting Pin asks first: ⌘D is Library's now (\(conflict.map { $0.other } ?? "no question"))")
            editor.resolve(.swap)
            check(key("tabs.pin") == "⌘D" && key("tabs.library") == "⇧⌘L" && center.map.stored == ["file.openLocation": "alt+cmd+l"]
                  && menuKey("Pin / Unpin Tab") == "⌘D" && menuKey("Library") == "⇧⌘L",
                  "shortcutremap: Pin's reset with Swap puts both back (Pin \(key("tabs.pin")), Library \(key("tabs.library")), stored \(center.map.stored))")
            editor.resetAll()
            let disk = storedOnDisk()
            check(center.map.stored.isEmpty && disk == [:] && menuKey("Open Location…") == "⌘L",
                  "shortcutremap: Reset All brings today's table back (menu \(menuKey("Open Location…")), settings.json \(disk.map { "\($0)" } ?? "unreadable"))")
        }
        keyCase(cmdL, page: page, setup: "reset();inp.focus()", settle: 0.4) { [self] _, log in
            let mode = c.commandBar.map { "\($0.mode)" } ?? "none"
            check(mode == "\(CommandBarMode.editURL)", "shortcutremap: after Reset All ⌘L opens the address editor again (\(mode), log \(log.joined(separator: ", ")))")
            c.closeCommandBar()
        }
        wait(0.3)

        // MARK: Airc first (Arc's "Prefer Arc")
        let usesCmdL = "reset();prevent['\(cmdL.page)']=1;inp.focus()"
        run { [self] in
            let offered = ["file.openLocation", "tabs.pin", "edit.copyURL", "edit.pasteURL", "tabs.back", "file.reopenOnUndo"].filter(center.offersPriority)
            let notOffered = ["spaces.next", "tabs.next.brace", "tabs.back.arrow", "file.newTab", "app.settings", "spaces.1"].filter(center.offersPriority)
            check(offered.count == 6 && notOffered.isEmpty,
                  "shortcutremap: ⌘ keys a page can have offer Websites first / Airc first, ⌥ ⌃ and reserved keys don't "
                  + "(offered \(offered), wrongly offered \(notOffered))")
            check(center.map.priority("file.openLocation") == .websites, "shortcutremap: Open Location starts at Websites first")
        }
        keyCase(cmdL, page: page, setup: usesCmdL, settle: 0.5) { [self] _, log in
            check(log.contains("kd \(cmdL.page)") && c.commandBar == nil,
                  "shortcutremap: Websites first: a page that uses ⌘L keeps it (command bar \(c.commandBar.map { "\($0.mode)" } ?? "none"), "
                  + "log \(log.joined(separator: ", ")))")
            c.closeCommandBar()
        }
        wait(1.2)   // past the second-press window: the next ⌘L is a first press again
        run { [self] in
            editor.setPriority(.airc, for: "file.openLocation")
            let disk = storedOnDisk()
            check(center.map.priority("file.openLocation") == .airc && disk == ["file.openLocation:first": "airc"],
                  "shortcutremap: Airc first on Open Location is stored (\(center.map.priority("file.openLocation")), "
                  + "settings.json \(disk.map { "\($0)" } ?? "unreadable"))")
            let again = ShortcutMap(commands: center.map.commands, stored: disk ?? [:])
            check(again == center.map && again.priority("file.openLocation") == .airc, "shortcutremap: the priority reads back from settings.json")
            captureSettings("settings-shortcuts-priority.png")
        }
        keyCase(cmdL, page: page, setup: usesCmdL, settle: 0.5) { [self] _, log in
            let mode = c.commandBar.map { "\($0.mode)" } ?? "none"
            check(mode == "\(CommandBarMode.editURL)" && !log.contains("kd \(cmdL.page)"),
                  "shortcutremap: Airc first: a page that uses ⌘L doesn't get it, the address editor opens (command bar \(mode), "
                  + "log \(log.joined(separator: ", ")))")
            c.closeCommandBar()
        }
        wait(0.3)

        // The same in a private window, on the same page.
        var privatePage: EngineTab?
        step { [self] done in
            guard let app else { return done() }
            PrivateBrowsing.shared.open(app: app) { p in
                privateWindow = p
                p?.closeCommandBar()
                privatePage = p?.openPage(URL(string: "http://127.0.0.1:\(port)/remap"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: done)
            }
        }
        /// ⌘L into the private window's page (which uses it); `verdict` gets whether the page saw it.
        func privateCmdL(_ what: String, _ verdict: @escaping (PrivateWindowController, Bool) -> Void) {
            step { [self] done in
                guard let p = privateWindow, let tab = privatePage else { check(false, "shortcutremap: \(what): a private window with the page"); return done() }
                Self.emulateKeyWindow(p.window) { [weak self] in self?.note($0) }
                p.closeCommandBar()
                tab.focus()
                tab.evaluate("(function(){\(usesCmdL);return 1})()") { _ in
                    self.post(cmdL, to: p.window)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        tab.evaluate("state()") { v in
                            let log = (v as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }?["log"] as? [String] ?? []
                            verdict(p, log.contains("kd \(cmdL.page)"))
                            done()
                        }
                    }
                }
            }
        }
        privateCmdL("Airc first") { [self] p, pageSawIt in
            check(!pageSawIt && p.commandBar != nil,
                  "shortcutremap: Airc first in a private window: the page doesn't get ⌘L (\(pageSawIt)), its address editor opens (\(p.commandBar != nil))")
        }
        run { [self] in
            editor.setPriority(.websites, for: "file.openLocation")
            check(center.map.stored.isEmpty && storedOnDisk() == [:], "shortcutremap: Websites first again stores nothing (\(center.map.stored))")
        }
        privateCmdL("Websites first") { [self] p, pageSawIt in
            check(pageSawIt && p.commandBar == nil,
                  "shortcutremap: Websites first in a private window: the page keeps ⌘L (\(pageSawIt)), no address editor (\(p.commandBar != nil))")
        }
        step { [self] done in
            privateWindow?.closeWindow()
            privateWindow = nil
            Self.emulateKeyWindow(c) { [weak self] in self?.note($0) }
            // Past the second-press window of the private page's ⌘L.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: done)
        }
        keyCase(cmdL, page: page, setup: usesCmdL, settle: 0.5) { [self] _, log in
            check(log.contains("kd \(cmdL.page)") && c.commandBar == nil,
                  "shortcutremap: Websites first again: the page keeps ⌘L in the main window (log \(log.joined(separator: ", ")))")
            c.closeCommandBar()
        }

        run { [self] in
            settingsWindow()?.orderOut(nil)
            server?.stop()
            KeyMonitor.testKeyWindowDispatch = nil
            note("shortcutremap: done")
        }
    }

    /// The Settings window, rendered as the shortcuts check's evidence.
    private func captureSettings(_ name: String) {
        guard let w = app?.settingsWindow?.window, let v = w.contentView else { return }
        v.layoutSubtreeIfNeeded()
        guard let img = render(v), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: dir.appendingPathComponent(name))
        note("wrote \(name)")
    }

    /// A key down and up for `window` (the Settings window, a private window, Little Arc).
    private func post(_ k: Key, to window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: k.mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: k.chars,
                                           charactersIgnoringModifiers: k.ignoring, isARepeat: false, keyCode: k.code) else { continue }
            NSApp.postEvent(e, atStart: false)
        }
    }

    /// The main menu's item for a browser command, by title.
    static func commandItem(_ title: String, in menu: NSMenu? = NSApp.mainMenu) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if let hit = commandItem(title, in: item.submenu) { return hit }
            if item is CommandMenuItem, item.title == title { return item }
        }
        return nil
    }
}
#endif
