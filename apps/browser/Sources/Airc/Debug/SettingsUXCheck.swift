// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AppKit

/// `--script settingsux` (both engines, a fresh data folder): the Settings window's layout never moves between panes,
/// and Settings search finds panes, sections and rows and opens them.
///
/// Input is **real** with the UI driver (AIRC_REAL_KEYS=1: pane clicks, ⌘F, typing, ↓ Return Esc, PID-targeted to the
/// foreground app); without it the same steps are set in code and the log says "posted".
///   layout    the window at its default size and at its minimum: a click on each pane; the pane's column (and its
///             title) keeps the same x and width on every pane, Appearance included (the report: it moved left);
///   find      ⌘F focuses the field; "dark", "password", "boost", "shortcut" each list the pane they mean, with
///             pane › section paths; a query that matches nothing says so;
///   open      "back up now", ↓ Return: General opens scrolled to that row, which is on screen and highlighted, and the
///             column hasn't moved; "dark", ↓ Return lands on the selected result;
///   esc       Esc clears the search (the pane list is back); a second Esc leaves the field.
extension SnapshotRunner {
    func settingsUXScenario() {
        let engine = app?.engine is WebKitEngine ? "WebKit" : "Chromium"
        let tag = "settingsux (\(engine))"
        let real = UIDriverClient.available
        var columnX: CGFloat?
        var columnW: CGFloat?

        func window() -> NSWindow? { app?.settingsWindow?.window }
        func model() -> SettingsModel? { app?.settingsWindow?.model }
        func host() -> NSView? { window()?.contentView }
        func frame(_ anchor: String) -> CGRect? {
            guard let v = host() else { return nil }
            v.layoutSubtreeIfNeeded()
            return TestAnchors.frame(anchor, in: v)
        }
        func fieldFocused() -> Bool {
            guard let w = window(), let editor = w.firstResponder as? NSTextView else { return false }
            return (editor.delegate as? NSView)?.accessibilityLabel() == "Search Settings"
        }
        func captureSettings(_ name: String) {
            run { [self] in
                guard let v = host() else { return note("\(tag): no Settings window for \(name)") }
                v.layoutSubtreeIfNeeded()
                guard let img = render(v), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { return note("\(tag): could not render \(name)") }
                try? png.write(to: dir.appendingPathComponent(name))
                note("wrote \(name)")
            }
        }
        /// Settings key and in front, the app active (real keys go to the foreground app, PID-targeted).
        func front(_ done: @escaping (Bool) -> Void) {
            guard let w = window() else { return done(false) }
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            waitUntil({ NSApp.isActive && w.isKeyWindow && w.isOnActiveSpace }, timeout: 3) {
                let ok = NSApp.isActive && w.isKeyWindow && w.isOnActiveSpace
                if !ok { self.note("FAIL-ENV \(tag): Settings not key/active (active=\(NSApp.isActive), key=\(w.isKeyWindow), space=\(w.isOnActiveSpace))") }
                done(ok)
            }
        }
        /// Real key combos to Airc (or `fallback` in code).
        func keys(_ combos: @escaping () -> [String], _ what: String, fallback: @escaping () -> Void) {
            step { [self] done in
                guard real else {
                    fallback()
                    return DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: done)
                }
                front { ok in
                    guard ok else { return done() }
                    UIDriverClient.press(combos(), pid: getpid()) { ok, out in
                        if !ok { self.note("FAIL-ENV \(tag): the driver refused \(what): \(out)") }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: done)
                    }
                }
            }
        }
        func typeText(_ text: String) {
            keys({ UIDriverClient.keys(typing: text) ?? [] }, "typing “\(text)”", fallback: { model()?.query = text })
            run { [self] in check(model()?.query == text, "\(tag): typed “\(text)” (field has “\(model()?.query ?? "-")”)") }
        }
        func commandF() {
            keys({ ["cmd+f"] }, "⌘F", fallback: { model()?.focusSearch() })
            wait(0.3)
            run { [self] in check(fieldFocused(), "\(tag): ⌘F focuses the search field (first responder \(window()?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"))") }
        }
        /// A real click on an anchor in Settings (or `fallback`).
        func click(_ anchor: String, _ what: String, fallback: @escaping () -> Void) {
            step { [self] done in
                guard real else {
                    fallback()
                    return DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: done)
                }
                front { ok in
                    guard ok, let w = window(), let v = host() else { return done() }
                    v.layoutSubtreeIfNeeded()
                    guard let a = TestAnchors.view(anchor, in: v) else { self.check(false, "\(tag): \(anchor) in Settings"); return done() }
                    let r = a.convert(a.bounds, to: nil)
                    let g = w.convertPoint(toScreen: NSPoint(x: r.midX, y: r.midY)), top = NSScreen.screens.first?.frame.maxY ?? 0
                    UIDriverClient.run(["--click", String(Double(g.x)), String(Double(top - g.y))]) { ok, out in
                        if !ok { self.note("FAIL-ENV \(tag): the driver refused the click on \(what): \(out)") }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: done)
                    }
                }
            }
        }
        /// The pane's column: same x and width as the first pane measured, and its title too.
        func expectColumn(_ when: String) {
            run { [self] in
                guard let col = frame("settings.column") else { return check(false, "\(tag): \(when): the pane's column is laid out") }
                if columnX == nil { columnX = col.minX; columnW = col.width }
                let same = abs(col.minX - (columnX ?? 0)) < 0.5 && abs(col.width - (columnW ?? 0)) < 0.5
                check(same && abs(col.width - SettingsLayout.columnWidth) < 0.5,
                      "\(tag): \(when): the column stays at x \(Int(col.minX)), \(Int(col.width)) wide (first pane: x \(Int(columnX ?? -1)), \(Int(columnW ?? -1)))")
            }
        }

        // Settings at its default size, on screen and in front.
        run { [self] in
            app?.showSettings(page: .general)
            if let w = window(), let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
                w.setFrame(NSRect(x: screen.minX + 60, y: screen.minY + 40, width: SettingsLayout.windowWidth,
                                  height: min(760, screen.height - 80)), display: true)
                note("\(tag): Settings \(Int(w.frame.width))×\(Int(w.frame.height)), minimum width \(Int(w.minSize.width)), scroller style \(NSScroller.preferredScrollerStyle == .legacy ? "legacy" : "overlay")")
                check(w.minSize.width >= SettingsLayout.windowWidth, "\(tag): the window can't get narrower than the column needs")
            }
        }
        wait(0.8)

        // layout: every pane, by a click on its row.
        for page in SettingsPage.allCases {
            click("settings.pane." + page.rawValue, page.title, fallback: { model()?.page = page })
            wait(0.3)
            run { [self] in check(model()?.page == page, "\(tag): a click on \(page.title) opens it") }
            expectColumn(page.title)
            if page == .appearance { captureSettings("settingsux-appearance.png") }
        }
        // And scrolled to the bottom of Appearance (its widest rows: App Icon) at the minimum width.
        run { [self] in
            if let w = window() { w.setContentSize(NSSize(width: w.minSize.width, height: w.frame.height)) }
            model()?.page = .appearance
            model()?.reveal("App Icon")
        }
        wait(0.6)
        expectColumn("Appearance at the minimum width, scrolled to App Icon")

        // find
        commandF()
        let finds: [(String, SettingsPage)] = [("dark", .appearance), ("password", .passwords), ("boost", .boosts), ("shortcut", .shortcuts)]
        for (q, page) in finds {
            commandF()
            typeText(q)
            run { [self] in
                let r = model()?.results ?? []
                let shown = r.prefix(5).map { "\($0.title) [\($0.path)]" }.joined(separator: "; ")
                check(!r.isEmpty && r.prefix(3).contains { $0.page == page },
                      "\(tag): “\(q)” lists \(page.title) among the first results (\(r.count): \(shown))")
                check(frame("settings.search.result.0") != nil && frame("settings.pane.general") == nil,
                      "\(tag): “\(q)”: results replace the pane list")
            }
            if q == "dark" { captureSettings("settingsux-search-dark.png") }
        }
        commandF()
        typeText("qqzxv")
        run { [self] in
            check(model()?.results.isEmpty == true && frame("settings.search.none") != nil,
                  "\(tag): a query that matches nothing says so (\(model()?.results.count ?? -1) results)")
        }

        // open: ↓ Return on a row far down General.
        commandF()
        typeText("back up now")
        keys({ ["down", "return"] }, "↓ Return", fallback: { model()?.moveSelection(1); model()?.openSelection() })
        wait(0.7)
        run { [self] in
            guard let m = model() else { return check(false, "\(tag): Settings model") }
            let sel = m.selection.flatMap { m.results.indices.contains($0) ? m.results[$0] : nil }
            check(sel != nil && m.opened == sel, "\(tag): ↓ Return opens the selected result (\(sel?.title ?? "none"), opened \(m.opened?.title ?? "none"))")
            check(m.page == .general && m.opened?.title == "Back up now", "\(tag): “back up now” opens General › Backups (\(m.page.title))")
            check(m.highlight.contains(SettingsSearch.rowAnchor("Back up now")), "\(tag): the found row is highlighted (\(m.highlight.sorted()))")
            // On screen: inside the scroll view's visible part.
            if let row = TestAnchors.view("settings.row.Back up now", in: host()!), let clip = row.enclosingScrollView?.contentView {
                let r = row.convert(row.bounds, to: clip)
                check(clip.bounds.contains(CGPoint(x: r.midX, y: r.midY)) && clip.bounds.minY > 50,
                      "\(tag): the page scrolled to the row (row \(Int(r.minY))–\(Int(r.maxY)) in visible \(Int(clip.bounds.minY))–\(Int(clip.bounds.maxY)))")
            } else {
                check(false, "\(tag): the found row is in the page")
            }
        }
        captureSettings("settingsux-found-row.png")
        expectColumn("after opening a result")
        wait(1.8)
        run { [self] in check(model()?.highlight.isEmpty == true, "\(tag): the highlight fades after a moment") }

        // ↓ Return on "dark": the selected result, highlighted.
        commandF()
        typeText("dark")
        keys({ ["down", "down", "return"] }, "↓↓ Return", fallback: { model()?.moveSelection(1); model()?.moveSelection(1); model()?.openSelection() })
        wait(0.5)
        run { [self] in
            guard let m = model(), let i = m.selection, m.results.indices.contains(i) else { return check(false, "\(tag): “dark” ↓↓: a selection") }
            let e = m.results[i]
            check(i == 1 && m.opened == e && m.page == e.page && (e.kind == .page || m.highlight == Set(e.anchors)),
                  "\(tag): “dark” ↓↓ Return opens the second result, \(e.title) [\(e.path)], highlighted (selection \(i), page \(m.page.title))")
        }

        // esc
        keys({ ["escape"] }, "Esc", fallback: { model()?.query = "" })
        wait(0.3)
        run { [self] in
            check(model()?.query == "" && frame("settings.pane.general") != nil && frame("settings.search.result.0") == nil,
                  "\(tag): Esc clears the search; the pane list is back (query “\(model()?.query ?? "-")”)")
        }
        if real {
            keys({ ["escape"] }, "Esc", fallback: {})
            run { [self] in check(!fieldFocused(), "\(tag): a second Esc leaves the field") }
        }
        // The pane list that came back takes clicks (a list swapped out under a click once left a container over it).
        click("settings.pane.privacy", "Privacy after the search", fallback: { model()?.page = .privacy })
        wait(0.3)
        run { [self] in check(model()?.page == .privacy, "\(tag): after the search, a click on a pane opens it (\(model()?.page.title ?? "-"))") }
        expectColumn("Privacy after the search")

        run { [self] in
            window()?.close()
            note("\(tag): input \(real ? "real clicks and keys (UI driver, PID-targeted)" : "posted (no driver)")")
        }
        wait(0.3)
    }
}
#endif
