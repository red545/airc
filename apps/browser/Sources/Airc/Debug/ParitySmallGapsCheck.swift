// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// `--script paritysmallgaps` (C06, K03), with real input from the stable UI driver only:
/// - Arc's Share Quote under the URL field: a real drag selects page text, and the pill shows only after the mouse-up
///   (sampled all through the drag); a real click on it copies the page's whole-word `#:~:text=` link; a real click on
///   the page clears the selection and the pill goes; with Shared Quotes off a drag shows nothing.
/// - Settings › Shortcuts lists the Edit menu's own submenus and Help: Make Upper Case remapped there runs on a real
///   key press, Help › Essential Keyboard Shortcuts too; a key another command has asks first (the conflict bar).
/// - ⌘[ ⌘] on a layout without brackets (Austrian on the build Mac): the key a person there presses, sent by key code.
/// Needs AIRC_UI_DEDICATED_SESSION=1, AIRC_REAL_KEYS=1 and AIRC_LA_AS_OWNER=1; otherwise FAIL-ENV.
extension SnapshotRunner {
    private var smallGapsReal: Bool {
        let env = ProcessInfo.processInfo.environment
        return UIDriverClient.available && env["AIRC_UI_DEDICATED_SESSION"] == "1" && env["AIRC_LA_AS_OWNER"] == "1"
    }

    /// `w` key, in front, on the active Space, Airc active; false with a FAIL-ENV line when it can't be.
    private func smallGapsFront(_ w: NSWindow, _ label: String, _ done: @escaping (Bool) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        waitUntil({ NSApp.isActive && w.isKeyWindow && w.isOnActiveSpace }, timeout: 6) {
            let ok = NSApp.isActive && w.isKeyWindow && w.isOnActiveSpace
            if !ok {
                self.note("FAIL-ENV \(label): window not key/active (active=\(NSApp.isActive), key=\(w.isKeyWindow), space=\(w.isOnActiveSpace), "
                          + "front app \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-"))")
            }
            done(ok)
        }
    }

    /// A window point in Quartz global display points (the driver's).
    private func quartz(_ p: NSPoint, in w: NSWindow) -> [String] {
        let s = w.convertPoint(toScreen: p)
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return [String(Double(s.x)), String(Double(top - s.y))]
    }

    func paritySmallGapsScenario() {
        let tag = "paritysmallgaps"
        let engine = app?.engine is WebKitEngine ? "WebKit" : "Chromium"
        func label(_ s: String) -> String { "\(tag) \(engine): " + s }
        var server: LocalPageServer?
        var base = "", tab = ""
        let board = NSPasteboard(name: NSPasteboard.Name("airc.smallgaps.\(getpid())"))
        let oldLinkBoard = WindowController.linkPasteboard
        let sharedBefore = app?.settings.values.sharedQuotes
        let sentence = "Quiet harbours keep their lanterns lit long after the ferries stop"
        let pid = ProcessInfo.processInfo.processIdentifier
        func page() -> EngineTab? { c.engineTab(for: tab) }
        func pill() -> QuotePillView? { c.quotePill }

        step { [self] done in
            let quote = "<!doctype html><title>quote</title><style>body{margin:0;font:22px -apple-system,sans-serif}</style>"
                + "<div style='height:300px'></div><p id=q style='margin:0 80px;line-height:40px'>\(sentence).</p>"
                + "<div style='height:1600px'></div>"
            let plain = { (t: String) in "<!doctype html><title>\(t)</title><p style='font:20px sans-serif;margin:80px'>\(t)</p>" }
            server = LocalPageServer(pages: ["/quote": quote, "/one": plain("one"), "/two": plain("two")])
            server?.start { port in
                guard let port else { self.check(false, label("a loopback page server")); return done() }
                base = "http://127.0.0.1:\(port)"
                tab = (try? self.c.store.openTab(url: base + "/quote", inSpace: self.c.currentSpaceID, title: "quote").id) ?? ""
                WindowController.linkPasteboard = board
                self.app?.settings.values.sharedQuotes = true
                if self.c.sidebarHidden { self.c.toggleSidebar() }
                self.c.show(tab, focus: true)
                self.waitUntil({ page()?.isLoading == false && page()?.title == "quote" }, timeout: 10) { done() }
            }
        }
        guard smallGapsReal else {
            run { [self] in
                note("FAIL-ENV \(label("real input needs AIRC_UI_DEDICATED_SESSION=1, AIRC_REAL_KEYS=1, AIRC_LA_AS_OWNER=1 and the stable UI driver"))")
                WindowController.linkPasteboard = oldLinkBoard
                server?.stop()
            }
            return
        }

        // MARK: C06, Share Quote

        var start = NSPoint.zero, end = NSPoint.zero, blank = NSPoint.zero
        var want = ""
        /// The sentence on screen, in window points (its first and last line's ends at mid-line), and a blank spot below.
        func locate() {
            step { [self] done in
                c.root.layoutSubtreeIfNeeded()
                guard let view = page()?.view else { check(false, label("the page's view")); return done() }
                let js = "(function(){scrollTo(0,0);getSelection().removeAllRanges();var p=document.getElementById('q');"
                    + "var r=document.createRange();r.selectNodeContents(p.firstChild);var b=r.getClientRects();var f=b[0],l=b[b.length-1];"
                    + "return [f.left+3,(f.top+f.bottom)/2,l.right-14,(l.top+l.bottom)/2,f.left+40,l.bottom+120]})()"
                page()?.evaluate(js) { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        page()?.evaluate(js) { v in
                            let xy = (v as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
                            guard xy.count == 6 else { self.check(false, label("the sentence is on screen (\(String(describing: v)))")); return done() }
                            func pt(_ x: Double, _ y: Double) -> NSPoint {
                                view.convert(NSPoint(x: x, y: view.isFlipped ? y : Double(view.bounds.height) - y), to: nil)
                            }
                            start = pt(xy[0], xy[1]); end = pt(xy[2], xy[3]); blank = pt(xy[4], xy[5])
                            done()
                        }
                    }
                }
            }
        }
        /// A real drag across the sentence. `during`: whether the pill showed at any moment before the mouse-up
        /// (sampled every frame while the driver drags).
        func drag(_ after: @escaping (_ during: Bool, _ selection: String) -> Void) {
            step { [self] done in
                smallGapsFront(c.window, tag) { ok in
                    guard ok, start != .zero else { return done() }
                    var during = false, sampling = true
                    func sample() {
                        guard sampling else { return }
                        if pill()?.isHidden == false { during = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60, execute: sample)
                    }
                    sample()
                    UIDriverClient.run(["--drag"] + self.quartz(start, in: self.c.window) + self.quartz(end, in: self.c.window)) { ok, out in
                        sampling = false
                        if !ok { self.note("FAIL-ENV \(label("driver drag: \(out)"))") }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            page()?.evaluate("String(getSelection())") { v in
                                after(during, (v as? String) ?? "")
                                done()
                            }
                        }
                    }
                }
            }
            wait(0.8)   // past the double-click interval
        }
        func realClick(_ p: @escaping () -> NSPoint?, _ what: String, _ after: @escaping () -> Void = {}) {
            step { [self] done in
                smallGapsFront(c.window, tag) { ok in
                    guard ok, let point = p() else { return done() }
                    // A plain click: the driver refuses an empty --mods.
                    UIDriverClient.run(["--click"] + self.quartz(point, in: self.c.window)) { ok, out in
                        if !ok { self.note("FAIL-ENV \(label("driver click on \(what): \(out)"))") }
                        after()
                        done()
                    }
                }
            }
            wait(0.8)
        }
        /// The link the pill should copy: the selection out to whole words.
        func expected(_ selection: String) -> String {
            let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let r = sentence.range(of: trimmed) else { return "-" }
            var lo = r.lowerBound, hi = r.upperBound
            while lo > sentence.startIndex, sentence[sentence.index(before: lo)] != " " { lo = sentence.index(before: lo) }
            while hi < sentence.endIndex, sentence[hi] != " " { hi = sentence.index(after: hi) }
            return LinkCopyPolicy.textFragmentURL(base + "/quote", selection: String(sentence[lo..<hi])) ?? "-"
        }

        // 1. A real drag: no pill while dragging, Share Quote after the mouse-up, under the URL field.
        var showsBefore = 0
        locate()
        var layoutBefore: [(String, NSRect)] = []
        quoteChipFixtureRows()
        run { showsBefore = pill()?.shows ?? -1; pill()?.hide() }
        wait(0.3)
        run { [self] in layoutBefore = quoteChipLayout() }
        drag { [self] during, selection in
            let p = pill()
            want = expected(selection)
            check(selection.split(separator: " ").count >= 4, label("a real drag selects the sentence's words (\"\(selection)\")"))
            check(!during, label("the pill doesn't show while the drag is still selecting"))
            check(p?.isHidden == false && p?.label.stringValue == QuotePillView.title && (p?.shows ?? 0) == showsBefore + 1,
                  label("after the mouse-up, \"\(QuotePillView.title)\" shows once (shown \((p?.shows ?? 0) - showsBefore)×)"))
            let fragment = (p?.link ?? "").components(separatedBy: "#:~:text=").last?.removingPercentEncoding ?? ""
            let words = Set(sentence.split(separator: " ").map(String.init))
            check(p?.link == want && want.contains("#:~:text=") && fragment.split(whereSeparator: { $0 == " " || $0 == "," }).allSatisfy { words.contains(String($0)) },
                  label("its link is the page's whole-word link to the text (\(p?.link ?? "-"))"))
            if let p {
                // sidebarchrome (owner 2026-11-20): inside the address pill, at its right end; nothing below it moved.
                let place = quoteChipPlacement(p)
                check(place.ok, label("it sits inside the address pill, at its right end (\(place.why))"))
                let shift = quoteChipShift(layoutBefore, quoteChipLayout())
                check(shift.isEmpty, label("and nothing below the pill moved, to the pixel (\(shift.isEmpty ? "first Favorite, first pinned row, Space name, list: unchanged" : shift))"))
            }
        }
        wait(0.3)
        capture("paritysmallgaps-\(engine.lowercased())-pill")

        // 2. A real click on it copies the link.
        var linkBefore = 0
        run { linkBefore = board.changeCount }
        realClick({ pill().flatMap { $0.isHidden ? nil : $0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: nil) } }, "Share Quote")
        step { [self] done in
            waitUntil({ board.changeCount != linkBefore }, timeout: 3) {
                self.check(board.string(forType: .string) == want && self.c.toast.shownText == QuoteLink.copiedToast && self.c.toast.shownDetail == QuoteLink.withQuote,
                           label("a real click on Share Quote copies that link (\(board.string(forType: .string) ?? "-")) and says so"))
                self.check(pill()?.isHidden == true, label("and the pill goes"))
                done()
            }
        }
        wait(0.6)
        capture("paritysmallgaps-\(engine.lowercased())-copied")

        // 3. A real click elsewhere on the page clears the selection: the pill goes.
        locate()
        drag { [self] _, _ in check(pill()?.isHidden == false, label("a second drag shows the pill again")) }
        realClick({ blank }, "the page")
        step { [self] done in
            waitUntil({ pill()?.isHidden == true }, timeout: 2) {
                page()?.evaluate("String(getSelection())") { v in
                    self.check((v as? String ?? "x").isEmpty && pill()?.isHidden == true,
                               label("a real click on the page clears the selection and the pill goes (selection \"\(v ?? "-")\")"))
                    done()
                }
            }
        }

        // 4. Shared Quotes off: no pill.
        run { [self] in app?.settings.values.sharedQuotes = false; showsBefore = pill()?.shows ?? -1 }
        locate()
        drag { _, _ in }
        wait(0.8)
        run { [self] in
            check(pill()?.isHidden == true && pill()?.shows == showsBefore,
                  label("with Enable Shared Quotes off, a real drag shows no pill (shown \((pill()?.shows ?? 0) - showsBefore)×)"))
            app?.settings.values.sharedQuotes = true
        }

        // MARK: K03, Settings › Shortcuts

        let center = ShortcutCenter.shared, editor = ShortcutsEditor.shared
        let upper = "edit.native.uppercaseWord", help = "help.shortcuts"
        let upperKey = KeyCombo("u", [.control, .option, .command]), helpKey = KeyCombo("k", [.control, .option, .command])
        func menuItem(_ path: [String]) -> NSMenuItem? {
            var menu = NSApp.mainMenu
            var item: NSMenuItem?
            for t in path { item = menu?.items.first { $0.title == t }; menu = item?.submenu }
            return item
        }
        func menuKey(_ path: [String]) -> String {
            guard let i = menuItem(path), !i.keyEquivalent.isEmpty else { return "none" }
            return ShortcutCenter.combo(i.keyEquivalent, i.keyEquivalentModifierMask)?.display ?? "?"
        }
        run { [self] in
            editor.resetAll()
            let groups = Dictionary(ShortcutCenter.groups.map { ($0.title, $0.commands.map(\.id)) }, uniquingKeysWith: { a, _ in a })
            let native = NativeEditingMenus.submenus.flatMap { $0.actions.compactMap { $0?.id } }
            check(native.allSatisfy { groups["Edit"]?.contains($0) == true && center.map.isRemappable($0) }
                  && ["help.gettingStarted", "help.shortcuts", "help.releaseNotes", "help.feedback", "help.privacy", "help.taskManager"]
                    .allSatisfy { groups["Help"]?.contains($0) == true && center.map.isRemappable($0) },
                  label("Settings › Shortcuts lists the Edit submenus' \(native.count) actions and Help's items, each remappable"))
            // The map's keys (AppKit localizes how a menu shows ⌘: on layouts that type : with ⇧: ⇧⌘Ü on Austrian).
            let spell = center.map.key("edit.native.showGuessPanel")?.display ?? "none", check1 = center.map.key("edit.native.checkSpelling")?.display ?? "none"
            check(spell == "⌘:" && check1 == "⌘;",
                  label("their usual keys stay (Show Spelling and Grammar \(spell), Check Document Now \(check1); "
                        + "the menu shows \(menuKey(["Edit", "Spelling and Grammar", "Show Spelling and Grammar"])) and \(menuKey(["Edit", "Spelling and Grammar", "Check Document Now"])) on \(UIDriverClient.layoutName))"))
            app?.showSettings(page: .shortcuts)
        }
        wait(0.8)
        run { [self] in
            editor.assign(upperKey, to: upper)
            editor.assign(helpKey, to: help)
            let stored = app?.settings.values.shortcuts ?? [:]
            let again = ShortcutMap(commands: center.map.commands, stored: stored)
            check(center.map.key(upper) == upperKey && menuKey(["Edit", "Transformations", "Make Upper Case"]) == upperKey.display
                  && stored[upper] != nil && again.key(upper) == upperKey,
                  label("Make Upper Case remapped to \(upperKey.display): menu \(menuKey(["Edit", "Transformations", "Make Upper Case"])), settings.json \(stored[upper] ?? "-")"))
            check(center.map.key(help) == helpKey && menuKey(["Help", "Essential Keyboard Shortcuts"]) == helpKey.display && again.key(help) == helpKey,
                  label("Essential Keyboard Shortcuts remapped to \(helpKey.display): menu \(menuKey(["Help", "Essential Keyboard Shortcuts"])), settings.json \(stored[help] ?? "-")"))
            app?.settingsWindow?.window.orderOut(nil)
        }
        wait(0.4)
        // A real ⌃⌥⌘U in a text field (the find bar's): the Edit menu's Make Upper Case runs.
        run { [self] in
            c.showFind()
            if let f = c.findBar?.field { f.stringValue = "quiet harbours"; c.window.makeFirstResponder(f); f.currentEditor()?.selectAll(nil) }
        }
        wait(0.4)
        step { [self] done in
            smallGapsFront(c.window, tag) { ok in
                guard ok else { return done() }
                if let f = self.c.findBar?.field, f.currentEditor() == nil { self.c.window.makeFirstResponder(f); f.currentEditor()?.selectAll(nil) }
                UIDriverClient.press(["ctrl+opt+cmd+u"], pid: pid) { ok, out in
                    if !ok { self.note("FAIL-ENV \(label("driver ⌃⌥⌘U: \(out)"))") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        let text = self.c.findBar?.field.currentEditor()?.string ?? self.c.findBar?.field.stringValue ?? "-"
                        self.check(text == "QUIET HARBOURS", label("a real \(upperKey.display) runs Edit › Transformations › Make Upper Case in a field (\"\(text)\")"))
                        done()
                    }
                }
            }
        }
        run { [self] in c.closeFind(refocusPage: true) }
        wait(0.4)
        // A real ⌃⌥⌘K with the page focused: Help › Essential Keyboard Shortcuts.
        step { [self] done in
            smallGapsFront(c.window, tag) { ok in
                guard ok else { return done() }
                page()?.focus()
                UIDriverClient.press(["ctrl+opt+cmd+k"], pid: pid) { ok, out in
                    if !ok { self.note("FAIL-ENV \(label("driver ⌃⌥⌘K: \(out)"))") }
                    let shortcuts = { NSApp.windows.first { $0.title == "Essential Keyboard Shortcuts" && $0.isVisible } }
                    self.waitUntil({ shortcuts() != nil }, timeout: KeyMonitor.pageAnswerTimeout + 2) {
                        self.check(shortcuts() != nil, label("a real \(helpKey.display) opens Help › Essential Keyboard Shortcuts"))
                        shortcuts()?.close()
                        done()
                    }
                }
            }
        }
        // A key another command has: Settings asks first, in the row (the conflict bar), and nothing changes.
        run { [self] in
            app?.showSettings(page: .shortcuts)
            editor.assign(KeyCombo("j", .command), to: upper)
            let c1 = editor.conflict
            check(c1?.id == upper && c1?.other == "edit.jumpToSelection" && center.map.key(upper) == upperKey && center.map.key("edit.jumpToSelection")?.display == "⌘J",
                  label("⌘J for Make Upper Case warns first: it's Jump to Selection's (conflict \(c1.map { "\($0.id) vs \($0.other)" } ?? "none"))"))
        }
        wait(0.8)
        run { [self] in
            smallGapsScrollSettings(toRow: upper)
            smallGapsCaptureSettings("paritysmallgaps-\(engine.lowercased())-conflict.png")
            editor.resolve(.refuse)
            editor.assign(KeyCombo(";", .command), to: "help.releaseNotes")
            let c2 = editor.conflict
            check(c2?.other == "edit.native.checkSpelling" && center.map.key("help.releaseNotes") == nil,
                  label("⌘; for Release Notes warns first: it's Check Document Now's (conflict \(c2.map { $0.other } ?? "none"))"))
            editor.resolve(.refuse)
            app?.settingsWindow?.window.orderOut(nil)
        }

        // MARK: K03, ⌘[ ⌘] on this layout, by key code

        run { [self] in page()?.load(URL(string: base + "/one")!) }
        step { [self] done in waitUntil({ page()?.title == "one" && page()?.isLoading == false }, timeout: 10, then: done) }
        run { [self] in page()?.load(URL(string: base + "/two")!) }
        step { [self] done in waitUntil({ page()?.title == "two" && page()?.isLoading == false }, timeout: 10, then: done) }
        for (id, bracket, goal) in [("tabs.back", "[", "one"), ("tabs.forward", "]", "two")] {
            step { [self] done in
                smallGapsFront(c.window, tag) { ok in
                    guard ok else { return done() }
                    page()?.focus()
                    let typeable = UIDriverClient.keys(typing: bracket) != nil
                    // The layout's own key for the command (ShortcutCenter.layoutAliases), pressed by its key code.
                    var press: [String] = ["--key", "cmd+" + bracket], shown = "⌘" + bracket
                    if !typeable, let a = center.layoutAliases.first(where: { $0.id == id && $0.key.count == 1 }),
                       let hit = SnapshotRunner.Layout.code(typing: a.key, near: bracket == "[" ? 33 : 30) {
                        var mods = a.modifiers.subtracting(.shift)
                        if hit.shift { mods.insert(.shift) }
                        let names = [(NSEvent.ModifierFlags.control, "ctrl"), (.option, "opt"), (.shift, "shift"), (.command, "cmd")].filter { mods.contains($0.0) }.map(\.1)
                        press = ["--keycode", (names + [String(hit.code)]).joined(separator: "+")]
                        shown = (ShortcutCenter.combo(a.key, mods)?.display ?? a.key) + " (key code \(hit.code))"
                    } else if !typeable {
                        self.check(false, label("an extra key for ⌘\(bracket) on \(UIDriverClient.layoutName)"))
                        return done()
                    }
                    UIDriverClient.run(press + ["--pid", String(pid)]) { ok, out in
                        if !ok { self.note("FAIL-ENV \(label("driver \(press.joined(separator: " ")): \(out)"))") }
                        self.waitUntil({ page()?.title == goal && page()?.isLoading == false }, timeout: KeyMonitor.pageAnswerTimeout + 4) {
                            self.check(page()?.title == goal, label("a real \(shown) on \(UIDriverClient.layoutName) goes \(id == "tabs.back" ? "back" : "forward") (at \(page()?.title ?? "-"))"))
                            done()
                        }
                    }
                }
            }
            wait(0.4)
        }

        run { [self] in
            editor.resetAll()
            app?.settingsWindow?.window.orderOut(nil)
            WindowController.linkPasteboard = oldLinkBoard
            if let sharedBefore { app?.settings.values.sharedQuotes = sharedBefore }
            board.releaseGlobally()
            server?.stop()
            note("\(tag): done")
        }
    }

    /// Scrolls Settings near the row for `id`, by its place in the list (rows are about the same height).
    private func smallGapsScrollSettings(toRow id: String) {
        guard let w = app?.settingsWindow?.window, let content = w.contentView else { return }
        let ids = ShortcutCenter.groups.flatMap { g in g.commands.map(\.id) }
        guard let index = ids.firstIndex(of: id) else { return }
        let headers = ShortcutCenter.groups.prefix { !$0.commands.contains { $0.id == id } }.count + 1
        func scrollViews(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? v.subviews.flatMap(scrollViews) }
        guard let s = scrollViews(content).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
              let doc = s.documentView else { return }
        let fraction = CGFloat(index + headers * 2) / CGFloat(ids.count + ShortcutCenter.groups.count * 2 + 6)
        let visible = s.contentView.bounds.height
        var y = max(0, min(doc.frame.height - visible, doc.frame.height * fraction - visible / 2))
        if !doc.isFlipped { y = doc.frame.height - visible - y }
        s.contentView.scroll(to: NSPoint(x: 0, y: y))
        s.reflectScrolledClipView(s.contentView)
    }

    private func smallGapsCaptureSettings(_ name: String) {
        guard let w = app?.settingsWindow?.window, let v = w.contentView else { return }
        v.layoutSubtreeIfNeeded()
        guard let img = render(v), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: dir.appendingPathComponent(name))
        note("wrote \(name)")
    }
}
#endif
