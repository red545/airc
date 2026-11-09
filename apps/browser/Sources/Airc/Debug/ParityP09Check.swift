// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit
#if canImport(AircCore)
import AircCore
#endif

/// `--script parityp09` (P09, docs/user/extensions.md): pinned extensions in the toolbar, as Arc moves them top right
/// when its Toolbar is on (⇧⌘D).
///
/// - Two synthetic unpacked extensions with popups (written into the run's folder; never the owner's extensions or
///   profile), pinned A then B. Toolbar off: the URL field has [A, B]. Toolbar on: the toolbar has [A, B] at its
///   trailing end and the URL field none; off again: back, same order; the toolbar's buttons are the same objects across
///   refreshes; unpinning keeps the others' order and pinning appends.
/// - Popups: opened through each button's own click handler, the popup's content sits right under its button, trailing
///   edges together in the toolbar (sidebar left, sidebar right, full-screen layout) and with the sidebar on the right,
///   leading edges with the sidebar on the left; on the window's screen.
/// - ⌘E's list anchors on the toolbar's puzzle while the toolbar shows; another profile's Space shows its own (none).
///
/// Needs the engine's test gate for the unpacked extensions (`--airc-data-dir`, `--airc-test=unpackedExtension`, as
/// followups3); without it (the WebKit build) the extension parts SKIP and the toolbar's puzzle and empty state are
/// checked. Full screen is the toolbar's full-screen layout (`isFullscreen`): a background test app can't enter
/// native full screen.
extension SnapshotRunner {
    func parityP09Scenario() {
        var server: LocalPageServer?
        var url = ""
        var ids: [String] = []
        let gate = Self.engineTestGateOpens
        func field() -> URLFieldView? { c.pageView(for: c.currentSpaceID)?.urlField }
        func shown(_ buttons: [ExtensionButton]) -> [String] {
            buttons.filter { !$0.isHidden && $0.superview != nil }.sorted { $0.frame.minX < $1.frame.minX }.map(\.id)
        }
        /// The URL field's pins in their order (subview order is pin order; at the sidebar's width only the last ones
        /// show: the field keeps 72 pt of the host readable, the rest are in ⌘E's list).
        func fieldButtons() -> [ExtensionButton] {
            guard let f = field() else { return [] }
            f.sidebarHovered = true
            f.layoutSubtreeIfNeeded()
            return f.subviews.compactMap { $0 as? ExtensionButton }
        }
        func fieldIDs() -> [String] { fieldButtons().map(\.id) }
        /// The pins that show in the field: always the last of them, right to left from the puzzle.
        func fieldShown() -> [String] { shown(fieldButtons()) }
        func toolbarIDs() -> [String] {
            c.pageToolbar?.layoutSubtreeIfNeeded()
            return shown(c.pageToolbar?.extensionButtons ?? [])
        }
        func name(_ list: [String]) -> String { list.map { $0 == ids.first ? "A" : $0 == ids.last ? "B" : "?" }.joined(separator: ",") }

        step { done in
            server = LocalPageServer(pages: ["/p09": "<title>P09 page</title><body style=\"background:#f3ece0;font:15px -apple-system\"><h1>A page</h1></body>"])
            server?.start { port in url = "http://127.0.0.1:\(port ?? 0)/p09"; done() }
        }
        step { [self] done in
            if c.pageToolbar != nil { c.togglePageToolbar() }
            c.sidebarOnRight = false; c.isFullscreen = false
            guard let t = try? c.store.openTab(url: url, inSpace: c.currentSpaceID) else { check(false, "parityp09: test page"); return done() }
            c.reloadAll(animated: false)
            c.show(t.id, focus: false)
            waitUntil({ self.c.engineTab(for: t.id)?.title == "P09 page" }, timeout: 10) {
                self.note("parityp09: engine \(self.app?.engine.name ?? "?"), test gate \(gate), window on active Space \(self.c.window.isOnActiveSpace)")
                done()
            }
        }

        // The synthetic extensions, each with a popup and an icon.
        #if canImport(AircCore)
        for (n, (title, symbol)) in [("P09 Notes", "note.text"), ("P09 Timer", "timer")].enumerated() {
            step { [self] done in
                guard gate, let profile = c.engineTab(for: c.shownTabID ?? "")?.profile as? ChromiumProfile else { return done() }
                let folder = dir.appendingPathComponent("parityp09-extension-\(n)", isDirectory: true)
                Self.writeP09Extension(folder, title: title, symbol: symbol)
                profile.core.loadUnpackedExtension(forTesting: folder.path) { id, error in
                    DispatchQueue.main.async {
                        if let error { self.note("parityp09: \(title): \(error)") }
                        if let id { ids.append(id); self.c.setExtension(id, pinned: true) }
                        done()
                    }
                }
            }
        }
        #endif
        step { [self] done in
            guard ids.count == 2 else {
                skip("parityp09: pinned extensions (the synthetic extensions need the Chromium engine's test gate: --airc-data-dir, --airc-test=unpackedExtension)")
                return done()
            }
            waitUntil({ Set(self.c.extensionActions().map(\.id)).isSuperset(of: ids) }, timeout: 8) { done() }
        }

        // Toolbar on and off: the same buttons, the same order, in one place at a time.
        run { [self] in
            guard ids.count == 2 else {
                // The WebKit build (no extensions): the toolbar still has the puzzle, and ⌘E's list anchors on it.
                c.togglePageToolbar()
                let puzzle = c.pageToolbar?.puzzle
                c.pageToolbar?.layoutSubtreeIfNeeded()
                check(puzzle != nil && !(puzzle?.isHidden ?? true) && (c.pageToolbar?.bounds.contains(puzzle?.frame ?? .zero) ?? false)
                      && c.pageToolbar?.extensionButtons.isEmpty == true && c.extensionsListAnchor?.view === puzzle,
                      "parityp09: with no extensions the toolbar shows the puzzle at its end, and ⌘E opens there")
                c.togglePageToolbar()
                return
            }
            c.refreshExtensionButtons()
            check(c.pageToolbar == nil && fieldIDs() == ids && !fieldShown().isEmpty && ids.suffix(fieldShown().count).elementsEqual(fieldShown()),
                  "parityp09: toolbar off, the URL field has the pins in order (\(name(fieldIDs())); showing \(name(fieldShown())))")
            c.togglePageToolbar()
            let first = c.pageToolbar?.extensionButtons.map(ObjectIdentifier.init) ?? []
            check(toolbarIDs() == ids && fieldIDs().isEmpty,
                  "parityp09: toolbar on, they move to the toolbar in order, the URL field has none (toolbar \(name(toolbarIDs())), field \(name(fieldIDs())))")
            if let t = c.pageToolbar {
                let puzzle = t.puzzle.frame, last = t.extensionButtons.last?.frame ?? .zero
                check(last.maxX <= puzzle.minX && puzzle.maxX <= t.bounds.maxX && t.address.frame.maxX <= (t.extensionButtons.first?.frame.minX ?? puzzle.minX),
                      "parityp09: the address, then the pins, then the puzzle at the toolbar's end (address to \(t.address.frame.maxX), pins \(t.extensionButtons.map(\.frame.minX)), puzzle \(puzzle.minX) of \(t.bounds.width))")
            }
            c.refreshExtensionButtons()
            check(c.pageToolbar?.extensionButtons.map(ObjectIdentifier.init) == first, "parityp09: a refresh keeps the same buttons (none rebuilt)")
            c.togglePageToolbar()
            check(c.pageToolbar == nil && fieldIDs() == ids && ids.suffix(fieldShown().count).elementsEqual(fieldShown()),
                  "parityp09: toolbar off again, back in the URL field in order (\(name(fieldIDs())); showing \(name(fieldShown())))")
            c.togglePageToolbar()
            check(toolbarIDs() == ids, "parityp09: and on again (\(name(toolbarIDs())))")
            c.setExtension(ids[0], pinned: false)
            check(toolbarIDs() == [ids[1]], "parityp09: unpinning A leaves B (\(name(toolbarIDs())))")
            c.setExtension(ids[0], pinned: true)
            check(toolbarIDs() == [ids[1], ids[0]] && c.pinnedExtensionIDs == [ids[1], ids[0]], "parityp09: pinning A again puts it last (\(name(toolbarIDs())))")
            c.setExtension(ids[1], pinned: false); c.setExtension(ids[1], pinned: true)
            check(toolbarIDs() == ids, "parityp09: back to A, B")
        }

        // Popups under their buttons, through the buttons' own click handlers.
        let cases: [(String, Bool, Bool, Bool)] = [("toolbar, sidebar left", true, false, false), ("toolbar, sidebar right", true, true, false),
                                                  ("toolbar, full-screen layout", true, false, true), ("URL field, sidebar left", false, false, false),
                                                  ("URL field, sidebar right", false, true, false)]
        for (what, toolbar, right, full) in cases {
            var before = Set<ObjectIdentifier>()
            var anchor = NSRect.zero
            var ran = false
            step { [self] done in
                guard ids.count == 2 else { return done() }
                c.closeExtensionPopup()
                if (c.pageToolbar != nil) != toolbar { c.togglePageToolbar() }
                c.sidebarOnRight = right; c.isFullscreen = full
                c.layoutRoot()
                c.root.layoutSubtreeIfNeeded()
                // The toolbar's A; in the URL field whichever pin shows (the last).
                let b = toolbar ? c.pageToolbar?.extensionButtons.first { $0.id == ids[0] && !$0.isHidden }
                                : fieldButtons().last { !$0.isHidden }
                guard let b else { check(false, "parityp09 popup, \(what): a pinned button shows"); return done() }
                before = Set((c.window.childWindows ?? []).map(ObjectIdentifier.init))
                anchor = c.window.convertToScreen(b.convert(b.bounds, to: nil))
                ran = true
                b.action?(b)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: done)
            }
            run { [self] in
                guard ids.count == 2, ran else { return }
                guard let panel = (c.window.childWindows ?? []).last(where: { $0 is NSPanel && !before.contains(ObjectIdentifier($0)) }) else {
                    return check(false, "parityp09 popup, \(what): the popup opened")
                }
                let content = panel.contentRect(forFrameRect: panel.frame)
                let trailing = anchor.midX > c.window.frame.midX
                // The placement rule, kept on the screen as the app does.
                var expected = NSRect(x: trailing ? anchor.maxX - content.width : anchor.minX, y: anchor.minY - content.height,
                                      width: content.width, height: content.height)
                let screen = (c.window.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
                let frameExpected = panel.frameRect(forContentRect: expected)
                let dx = max(screen.minX - frameExpected.minX, min(0, screen.maxX - frameExpected.maxX))
                let dy = max(screen.minY - frameExpected.minY, min(0, screen.maxY - frameExpected.maxY))
                expected = expected.offsetBy(dx: dx, dy: dy)
                let close = abs(content.minX - expected.minX) <= 1 && abs(content.maxY - expected.maxY) <= 1
                check(trailing == (toolbar || right) && close,
                      "parityp09 popup, \(what): under its button, \(trailing ? "trailing" : "leading") edges together (button \(Self.p09(anchor)), popup content \(Self.p09(content))\(dx != 0 || dy != 0 ? ", kept on screen by \(Int(dx)),\(Int(dy))" : ""))")
                c.closeExtensionPopup()
            }
            wait(0.3)
        }
        run { [self] in
            c.sidebarOnRight = false; c.isFullscreen = false; c.layoutRoot()
            guard ids.count == 2 else { return }
            if c.pageToolbar == nil { c.togglePageToolbar() }
            check(c.extensionsListAnchor?.view === c.pageToolbar?.puzzle, "parityp09: ⌘E's list anchors on the toolbar's puzzle")
            // A transient popover shows only from the key window (a click on the puzzle makes it key; a background test
            // window never is): the shortcuts check's key-window stand-in, as its ⌘E case uses.
            Self.emulateKeyWindow(c) { [weak self] in self?.note($0) }
            c.showExtensions()
        }
        // The popover animates in (as --script extension waits for it): its window, then where it is.
        wait(0.6)
        run { [self] in
            guard ids.count == 2 else { return }
            let w = c.extensionsPopover?.contentViewController?.view.window
            if w == nil, let why = inputBlocked {
                note("FAIL-ENV parityp09: ⌘E's list opens there (no popover window: \(why))")
            } else if let w, let puzzle = c.pageToolbar?.puzzle {
                let p = c.window.convertToScreen(puzzle.convert(puzzle.bounds, to: nil))
                check(w.frame.maxY <= p.minY + 6 && w.frame.minX <= p.maxX && w.frame.maxX >= p.minX,
                      "parityp09: ⌘E's list opens under the toolbar's puzzle (puzzle \(Self.p09(p)), list \(Self.p09(w.frame)))")
            } else {
                check(false, "parityp09: ⌘E's list opens there (popover \(c.extensionsPopover == nil ? "none" : "made"), shown \(c.extensionsPopover?.isShown ?? false), puzzle \(Self.p09(c.pageToolbar?.puzzle.frame ?? .zero)))")
            }
            c.extensionsPopover?.close()
        }

        // Another profile's Space: its own pins (none), then this one's again.
        var home = ""
        step { [self] done in
            guard ids.count == 2, let p = try? c.profiles.createProfile(name: "P09 Work", emoji: "💼", color: RGBA(hex: "7EB6D5")),
                  let s = try? c.store.createSpace(name: "P09 Work", icon: .emoji("💼"), profileID: p.id, after: c.currentSpaceID) else { return done() }
            home = c.currentSpaceID
            c.switchToSpace(s.id, animated: false)
            c.refreshExtensionButtons()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.check(toolbarIDs().isEmpty && fieldIDs().isEmpty, "parityp09: another profile's Space shows its own pins (none)")
                self.c.switchToSpace(home, animated: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.c.refreshExtensionButtons()
                    self.check(toolbarIDs() == ids, "parityp09: back in this Space, A and B again (\(name(toolbarIDs())))")
                    done()
                }
            }
        }
        run { [self] in if ids.count == 2 { field()?.sidebarHovered = false } }
        wait(0.3)
        capture("parityp09-toolbar")
        run { [self] in
            if c.pageToolbar != nil { c.togglePageToolbar() }
            server?.stop()
        }
    }

    static func p09(_ r: NSRect) -> String { "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height))" }

    /// A synthetic MV3 extension: an action with a popup and a 32 px icon drawn from an SF Symbol.
    static func writeP09Extension(_ folder: URL, title: String, symbol: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = """
        {"manifest_version": 3, "name": "\(title)", "version": "1",
         "action": {"default_title": "\(title)", "default_popup": "popup.html", "default_icon": {"32": "icon.png"}},
         "icons": {"32": "icon.png"}}
        """
        try? manifest.write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let popup = "<!doctype html><meta charset=utf-8><body style=\"margin:0;width:280px;height:160px;font:14px -apple-system;"
            + "display:flex;align-items:center;justify-content:center;background:#fffaf2\">\(title)</body>"
        try? popup.write(to: folder.appendingPathComponent("popup.html"), atomically: true, encoding: .utf8)
        let size = 32
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor(srgbRed: symbol == "timer" ? 0.85 : 0.36, green: symbol == "timer" ? 0.45 : 0.52, blue: symbol == "timer" ? 0.30 : 0.80, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 30, height: 30), xRadius: 8, yRadius: 8).fill()
        if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .semibold).applying(.init(paletteColors: [.white]))) {
            let s = glyph.size
            glyph.draw(in: NSRect(x: (32 - s.width) / 2, y: (32 - s.height) / 2, width: s.width, height: s.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("icon.png"))
    }
}
#endif
