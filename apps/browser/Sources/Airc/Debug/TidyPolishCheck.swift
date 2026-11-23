// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit

/// `--script tidypolish` (both engines; Sidebar/SidebarRows.swift DividerRowView, Sidebar/SpacePage.swift, AI/TidyHint.swift):
/// Clear's ↓ preview and the tidy card's same-render overflow rule, on a synthetic Space (made-up example.* sites: a
/// pinned tab, a Favorite, an open Today folder of 2, a closed one of 1, loose Today tabs), with real input
/// (AIRC_REAL_KEYS=1, the stable UI driver, AIRC_UI_DEDICATED_SESSION=1):
///   1. tabs added one at a time (in-app, as a link opening one would): the card is there in the very render the tab
///      that makes Today overflow causes (no reload, one render per tab), and not before; the rule's height matches the
///      rows as laid out;
///   2. a real hover on the divider (not on Clear): Clear shows, nothing lit; then a real hover on Clear: no ↓ (Arc shows
///      it only when the tab on screen is the only Today tab) and exactly Clear's tabs' rows light up (every Today tab but the one on screen, both Today
///      folders, which Clear leaves empty and removes); the pinned row, the shown row and the cards don't; nothing
///      moves (every row's and the header's frames as before);
///   3. hover-out (real moves): off Clear on the divider, then out of the sidebar: no ↓, nothing lit;
///   4. a real click on Clear archives exactly those tabs and leaves "Archived N tabs" with Undo; the toast's Undo (a
///      real click) restores Today exactly (Undo unchanged);
///   5. only the tab on screen left in Today (Arc): the ↓ shows before Clear on sidebar hover, inside the gap between
///      the line and Clear (nothing moves), and hides with Clear; a real click on Clear archives that tab too and the
///      window shows what closing it shows; the toast's Undo puts it back in place, on screen.
/// Shots (light, dark), many tabs and the lone shown tab: before (the preview switched off in this build, as main draws
/// it) and after; the header's line, Tidy and Clear frames must be the same in all four.
/// Zero-guard: the run fails if it made fewer assertions than expected.
extension SnapshotRunner {
    private static let tpPages: [(String, String)] = [
        ("https://news.example.com/briefing", "Morning briefing"), ("https://news.example.com/harbour", "Harbour bridge reopens"),
        ("https://recipes.example.org/risotto", "Lemon risotto"), ("https://recipes.example.org/curry", "Weeknight curry"),
        ("https://shop.example.net/shoes", "Trail running shoes"), ("https://shop.example.net/jacket", "Rain jacket"),
        ("https://docs.example.com/start", "Getting started"), ("https://docs.example.com/config", "Configuration"),
        ("https://maps.example.com/ferry", "Ferry timetable"), ("https://music.example.net/focus", "Focus playlist"),
        ("https://photos.example.org/coast", "Album: Coast walk"), ("https://forum.example.com/tents", "Thread: tent advice"),
        ("https://bank.example.net/statements", "Statements"), ("https://calendar.example.org/week", "Week view"),
    ]

    @MainActor private func tpLayout(_ space: String) -> String {
        let s = c.store
        let tabs = s.state.tabs.values.filter { $0.spaceID == space }
        let items = s.state.items.values.filter { $0.spaceID == space }
        return (tabs.sorted { $0.id < $1.id }.map { "tab \($0.id) item=\($0.itemID ?? "-") folder=\($0.folderID ?? "-") order=\($0.order) today=\($0.isToday)" }
            + items.sorted { $0.id < $1.id }.map { "item \($0.id) \($0.kind) parent=\($0.parentID ?? "-") order=\($0.order) collapsed=\($0.isCollapsed)" })
            .joined(separator: "\n")
    }

    @MainActor func tidyPolishScenario() {
        let engine = app?.engine is WebKitEngine ? "WebKit" : "Chromium"
        let tag = "tidypolish (\(engine))"
        guard UIDriverClient.available, ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1" else {
            run { [self] in note("FAIL-ENV \(tag): real input needs AIRC_REAL_KEYS=1, the stable UI driver and AIRC_UI_DEDICATED_SESSION=1") }
            return
        }
        var space = "", shownID = "", pinnedID = "", loose: [String] = [], openFolder = "", closedFolder = ""
        var next = 0, asserted = 0, cardAt = -1
        var framesBefore: [String: NSRect] = [:]
        var expected = Set<String>()
        var layoutBefore = "", targetsBefore: [String] = []
        func expect(_ ok: Bool, _ what: String) { asserted += 1; check(ok, "\(tag): \(what)") }
        func page() -> SpacePageView? { c.pageView(for: space) }
        func divider() -> DividerRowView? { page()?.rows["divider"] as? DividerRowView }
        func card() -> TidyHintCardView? { page()?.rows["tidyhint"] as? TidyHintCardView }
        func lit() -> Set<String> { Set((page()?.rows ?? [:]).filter { $0.value.isClearPreview }.map(\.key)) }
        func frames() -> [String: NSRect] {
            var f = (page()?.rows ?? [:]).mapValues { $0.frame }
            if let d = divider() {
                f["divider.clear"] = d.clearLabel.frame
                f["divider.tidy"] = d.tidy.frame
            }
            return f
        }
        func activate() {
            step { [self] done in
                NSApp.activate(ignoringOtherApps: true)
                c.window.makeKeyAndOrderFront(nil)
                waitUntil({ NSApp.isActive && self.c.window.isKeyWindow }, timeout: 3) { done() }
            }
        }
        /// A real pointer move to a point of a view (window coordinates), dwelling there.
        func hover(_ what: String, dwell: Int = 400, _ point: @escaping () -> NSPoint?) {
            step { [self] done in
                page()?.layoutSubtreeIfNeeded()
                guard let p = point() else {
                    expect(false, "[real hover] \(what): on screen")
                    return done()
                }
                UIDriverClient.hover(p, in: c.window, dwell: dwell) { ok, out in
                    if !ok { self.note("FAIL-ENV \(tag) [real hover] \(what): \(out)") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done)
                }
            }
        }
        func centre(_ v: NSView?) -> NSPoint? {
            guard let v, v.window != nil else { return nil }
            return v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
        }
        /// A real click at a view's centre (Quartz global coordinates, top-left origin; no --mods).
        func realClick(_ what: String, settle: Double = 0.6, _ view: @escaping () -> NSView?) {
            step { [self] done in
                page()?.layoutSubtreeIfNeeded()
                guard let v = view(), let w = v.window, let primary = NSScreen.screens.first, !v.isHidden, v.bounds.width > 4 else {
                    expect(false, "[real click] \(what): on screen")
                    return done()
                }
                let g = w.convertPoint(toScreen: v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil))
                UIDriverClient.run(["--click", String(Double(g.x.rounded())), String(Double((primary.frame.maxY - g.y).rounded()))]) { ok, out in
                    if !ok { self.note("FAIL-ENV \(tag) [real click] \(what): \(out)") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: done)
                }
            }
        }
        /// The list's height without the tidy card, from the rows as laid out: the last row's top plus a row pitch
        /// (render's y after it), less the card's block.
        func listY(_ p: SpacePageView) -> CGFloat {
            let lastID = p.orderedEntries.last?.id ?? ""
            let cardH = p.rowFrame("tidyhint").map { _ in TidyHintCardView.height(c, spaceID: space) } ?? 0
            return (p.rowFrame(lastID)?.minY ?? 0) + AircMetrics.Row.pitch - cardH
        }
        func addTab() throws -> String {
            let p = Self.tpPages[next % Self.tpPages.count]
            next += 1
            return try c.store.openTab(url: p.0 + "/\(next)", inSpace: space, activate: false, title: p.1).id
        }

        run { [self] in
            TidyHint.dayOverride = "2031-04-01"
            TidyHint.allowedInScripts = true
            DividerRowView.previewsClear = true
            c.store.setLocalValue(TidyHint.dayKey, nil)
            c.window.setFrame(NSRect(x: 160, y: 160, width: 1100, height: 760), display: true)
            let s = c.store
            do {
                let sp = try s.createSpace(name: "Tidy Polish", profileID: s.selectedSpace.profileID)
                space = sp.id
                let pin = try s.openTab(url: "https://docs.example.com/handbook", inSpace: space, activate: false, title: "Handbook")
                try s.togglePin(pin.id, inSpace: space)
                pinnedID = pin.id
                let a = try addTab(), b = try addTab(), d = try addTab()
                openFolder = try s.createTodayFolder(named: "Reading", inSpace: space, containing: [.tab(a), .tab(b)]).id
                closedFolder = try s.createTodayFolder(named: "Later", inSpace: space, containing: [.tab(d)]).id
                try s.toggleFolder(closedFolder)
                for _ in 0..<5 { loose.append(try addTab()) }
                c.switchToSpace(space, animated: false)
                shownID = loose[2]
                c.show(shownID)
                c.reloadAll(animated: false)
            } catch {
                expect(false, "made the synthetic Space (\(error))")
                return finish()
            }
        }
        activate()
        wait(0.8)
        // 1. The card in the same render. Size the window so Today overflows 3 loose tabs from now (8 loose, in 6–11,
        // where the overflow rule decides).
        run { [self] in
            guard let p = page() else { return }
            p.layoutSubtreeIfNeeded()
            c.reloadAll(animated: false)
            let need = listY(p) + 2.5 * AircMetrics.Row.pitch - p.scrollView.contentSize.height
            var f = c.window.frame
            f.size.height += need
            f.origin.y -= need
            c.window.setFrame(f, display: true)
            p.layoutSubtreeIfNeeded()
            c.reloadAll(animated: false)
            p.layoutSubtreeIfNeeded()
            expect(card() == nil && listY(p) < p.scrollView.contentSize.height,
                   "[setup] with 5 loose tabs Today fits (list \(Int(listY(p))) of \(Int(p.scrollView.contentSize.height)) pt) and there's no card")
        }
        wait(0.4)
        for n in 1...4 {
            var rendersBefore = 0
            run { [self] in
                rendersBefore = page()?.renderCountForTesting ?? 0
                do { loose.append(try addTab()) } catch { expect(false, "added tab \(n) (\(error))") }
            }
            wait(0.35)
            run { [self] in
                guard let p = page() else { return }
                p.layoutSubtreeIfNeeded()
                // The rows as laid out, without the card (the render loop's y after the last row, less the card).
                let laidOut = listY(p)
                let overflows = laidOut > p.scrollView.contentSize.height
                let renders = p.renderCountForTesting - rendersBefore
                if card() != nil, cardAt < 0 { cardAt = n }
                expect((card() != nil) == overflows && renders == 1,
                       "[in-app tab \(n), \(5 + n) loose] card \(card() != nil ? "shown" : "absent"), Today \(overflows ? "overflows" : "fits") "
                       + "(rows \(Int(laidOut)) of \(Int(p.scrollView.contentSize.height)) pt), in \(renders) render(s), no reload")
                expect(abs(p.listHeightWithoutCardForTesting - laidOut) < 0.5,
                       "[tab \(n)] the rule's height (\(Int(p.listHeightWithoutCardForTesting)) pt) is the laid-out rows' (\(Int(laidOut)) pt)")
            }
        }
        run { expect(cardAt == 3, "the card first shows with the 3rd added tab, the one that makes Today overflow (at \(cardAt))") }
        // Its cost: the rule's arithmetic per render (report only; the render itself is unchanged otherwise).
        run { [self] in
            guard let p = page() else { return }
            let before = p.overflowRuleTimeForTesting
            for _ in 0..<200 { p.reload(animated: false) }
            let after = p.overflowRuleTimeForTesting
            let calls = after.calls - before.calls
            note("tidypolish \(engine): overflow rule \(calls) calls in 200 renders, "
                 + String(format: "%.2f µs per call", calls > 0 ? (after.seconds - before.seconds) / Double(calls) * 1e6 : 0))
        }

        // 2. Many tabs. Before (the preview off: as main draws it) and after, pointer on Clear: the header's parts
        // (line, Tidy, Clear) sit exactly where they did, and Arc's ↓ doesn't show (it's for the lone shown tab).
        var header: [String: [String: NSRect]] = [:]
        func headerFrames() -> [String: NSRect] {
            guard let d = divider() else { return [:] }
            return ["line": d.lineFrame, "tidy": d.tidy.isHidden ? .zero : d.tidy.frame, "clear": d.clearLabel.frame]
        }
        func offSidebar() -> NSPoint { NSPoint(x: c.window.contentView!.bounds.midX + 200, y: c.window.contentView!.bounds.midY) }
        func shots(_ label: String, lone: Bool) {
            for on in [false, true] {
                for dark in [false, true] {
                    run { [self] in
                        DividerRowView.previewsClear = on
                        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        c.reloadAll(animated: false)
                    }
                    // Off the sidebar, then along the divider onto Clear.
                    hover("off the sidebar") { offSidebar() }
                    hover("the divider's left end") { [self] in divider().map { $0.convert(NSPoint(x: 30, y: 7), to: nil) } }
                    hover("Clear (\(label), \(on ? "after" : "before"))") { centre(divider()?.clearLabel) }
                    run {
                        if on, !lone {
                            expect(lit() == expected, "[\(label), after, \(dark ? "dark" : "light")] the shot has Clear's rows lit (\(lit().count); "
                                   + "sidebar hovered \(divider()?.sidebarHovered == true), on Clear \(divider()?.clearHovered == true), preview \(page()?.isClearPreviewOn == true))")
                        }
                        let key = "\(label)-\(on)-\(dark)"
                        header[key] = headerFrames()
                        if !on { expect(divider()?.showsClearArrow == false && lit().isEmpty, "[\(label), before, \(dark ? "dark" : "light")] preview off: no ↓, nothing lit") }
                        else if dark {
                            let a = header["\(label)-false-false"] ?? [:], b = header["\(label)-true-false"] ?? [:]
                            let c2 = header["\(label)-false-true"] ?? [:], d2 = header[key] ?? [:]
                            expect(!a.isEmpty && a == b && c2 == d2 && a == c2,
                                   "[\(label)] the header is unchanged before/after, light and dark (line, Tidy, Clear: \(b.mapValues(NSStringFromRect)))")
                        }
                    }
                    capture("tidypolish-\(label)-\(on ? "after" : "before")\(dark ? "-dark" : "")")
                }
            }
            run { [self] in
                NSApp.appearance = NSAppearance(named: .aqua)
                DividerRowView.previewsClear = true
                c.reloadAll(animated: false)
            }
            hover("off the sidebar") { offSidebar() }
        }
        run { [self] in
            expected = Set(loose.filter { $0 != shownID }).union([openFolder, closedFolder])
            for t in c.store.todayFolderTabs(openFolder) { expected.insert(t.id) }
        }
        shots("many", lone: false)

        // 3. Hover on the divider, then on Clear.
        hover("the divider's left end") { [self] in
            guard let d = divider() else { return nil }
            return d.convert(NSPoint(x: 30, y: 7), to: nil)
        }
        run { [self] in
            framesBefore = frames()
            let targets = Set(c.clearTargets())
            expected = Set(loose.filter { $0 != shownID }).union([openFolder, closedFolder])
            for id in [openFolder] { for t in c.store.todayFolderTabs(id) { expected.insert(t.id) } }
            expect(divider()?.clearLabel.isHidden == false && divider()?.showsClearArrow == false && lit().isEmpty,
                   "[real hover] on the divider, off Clear: Clear shows, no ↓ (many tabs), no row lit")
            expect(!targets.contains(shownID) && !targets.contains(pinnedID) && targets.count == loose.count - 1 + 3,
                   "Clear's targets: every Today tab but the one on screen, folders' too, never the pinned one (\(targets.count))")
        }
        hover("Clear") { centre(divider()?.clearLabel) }
        run { [self] in
            let got = lit()
            expect(divider()?.showsClearArrow == false, "[real hover] on Clear with many tabs: no ↓ (Arc shows it only for the lone shown tab)")
            expect(got == expected,
                   "[real hover] on Clear: exactly Clear's rows light up (\(got.count) lit, \(expected.count) expected; extra \(got.subtracting(expected).sorted()), missing \(expected.subtracting(got).sorted()))")
            expect(!got.contains(shownID) && !got.contains(pinnedID) && !got.contains("tidyhint") && !got.contains("divider"),
                   "the shown tab, the pinned tab and the cards aren't lit")
            let now = frames()
            let moved = now.filter { framesBefore[$0.key] != $0.value }.map(\.key).sorted()
            expect(moved.isEmpty && now.count == framesBefore.count, "nothing moves when the highlight shows (moved: \(moved))")
        }
        run { [self] in
            NSApp.appearance = NSAppearance(named: .darkAqua)
            c.reloadAll(animated: false)
        }
        wait(0.3)
        run { expect(lit() == expected, "[dark] a render while on Clear keeps the same rows lit") }
        run { [self] in
            NSApp.appearance = NSAppearance(named: .aqua)
            c.reloadAll(animated: false)
        }
        wait(0.3)

        // 4. Hover-out.
        hover("the divider's left end") { [self] in divider().map { $0.convert(NSPoint(x: 30, y: 7), to: nil) } }
        run { expect(lit().isEmpty, "[real hover-out] off Clear onto the divider: nothing lit") }
        hover("Clear again") { centre(divider()?.clearLabel) }
        run { expect(lit() == expected, "[real hover] back on Clear: the same rows light up") }
        hover("off the sidebar") { offSidebar() }
        run { expect(divider()?.showsClearArrow == false && lit().isEmpty, "[real hover-out] out of the sidebar: no ↓, nothing lit") }

        // 5. Clear with a real click, then the toast's Undo.
        hover("Clear before the click") { centre(divider()?.clearLabel) }
        run { [self] in
            expect(lit() == expected, "[real hover] from the page straight onto Clear: Clear's rows light up (\(lit().count); "
                   + "sidebar hovered \(divider()?.sidebarHovered == true), on Clear \(divider()?.clearHovered == true), \(divider()?.hoverTrace ?? "-"))")
            layoutBefore = tpLayout(space)
            targetsBefore = c.clearTargets()
        }
        realClick("Clear") { divider()?.clearLabel }
        run { [self] in
            let gone = targetsBefore.filter { c.store.tab($0) == nil }
            expect(gone.count == targetsBefore.count && c.store.tab(shownID) != nil && c.store.tab(pinnedID) != nil
                    && c.store.todayFolder(openFolder) == nil && c.store.todayFolder(closedFolder) == nil,
                   "[real click] Clear archived exactly the lit tabs (\(gone.count)/\(targetsBefore.count)) and the folders it left empty; the shown and pinned tabs stay")
            expect(c.toast.shownText == "Archived \(targetsBefore.count) tabs" && c.toast.actionButton != nil,
                   "Clear's toast is unchanged: \(c.toast.shownText ?? "-") with Undo")
            // The driver puts the pointer back on Clear: only the tab on screen, now Today's only tab, is Clear's next.
            expect(lit().isSubset(of: [shownID]), "after Clear no archived row stays lit; at most the tab on screen, Clear's next (\(lit().sorted()))")
        }
        realClick("the toast's Undo", settle: 0.8) { [self] in c.toast.actionButton }
        run { [self] in expect(tpLayout(space) == layoutBefore, "[real click] the toast's Undo restores Today exactly") }
        hover("off the sidebar") { offSidebar() }

        // 6. The lone shown tab (Arc): Clear in-app leaves only the tab on screen. For reference, what closing it shows
        // (in-app close, then Undo). A real hover shows the ↓ in the gap before Clear (not over the line or Clear); a real
        // click on Clear archives that tab too and the window shows what it shows after the close; the toast's Undo (a
        // real click) puts it back in place, on screen.
        var layoutLone = "", afterClose: String? = "?"
        run { [self] in
            layoutBefore = tpLayout(space)
            c.clearToday()
        }
        wait(0.6)
        run { [self] in
            expect(c.store.todayRowTabs(ofSpace: space).map(\.id) == [shownID] && c.shownTabID == shownID,
                   "[in-app] with many tabs Clear keeps the one on screen (today's rule): only it is left")
            layoutLone = tpLayout(space)
            c.closeTab(shownID)
        }
        wait(0.6)
        run { [self] in
            afterClose = c.shownTabID
            c.undo()
        }
        wait(0.6)
        run { [self] in
            expect(c.store.tab(shownID) != nil && c.shownTabID == shownID && tpLayout(space) == layoutLone,
                   "[reference] closing the lone tab shows \(afterClose ?? "the empty page"); Undo brings it back on screen")
        }
        hover("the divider's left end (lone)") { [self] in divider().map { $0.convert(NSPoint(x: 30, y: 7), to: nil) } }
        run { [self] in
            guard let d = divider() else { return expect(false, "the divider is there") }
            let a = d.clearArrowFrame
            expect(d.showsClearArrow && d.tidy.isHidden && c.clearTargets() == [shownID],
                   "[real hover, lone tab] the ↓ shows before Clear (Tidy hidden), and Clear's targets are the tab on screen")
            expect(a.minX >= d.lineFrame.maxX && a.maxX <= d.clearLabel.frame.minX,
                   "the ↓ sits in the gap: line ends \(d.lineFrame.maxX), ↓ \(NSStringFromRect(a)), Clear starts \(d.clearLabel.frame.minX)")
        }
        hover("Clear (lone)") { centre(divider()?.clearLabel) }
        run { expect(divider()?.showsClearArrow == true && lit() == [shownID], "[real hover] on Clear, lone tab: the ↓ stays; the tab on screen is Clear's (selected, so its fill is unchanged)") }
        hover("off the sidebar") { offSidebar() }
        run { expect(divider()?.showsClearArrow == false, "[real hover-out] out of the sidebar: Clear and its ↓ hide") }
        shots("lone", lone: true)
        hover("Clear before the lone click") { centre(divider()?.clearLabel) }
        realClick("Clear (lone tab)") { divider()?.clearLabel }
        run { [self] in
            let archived = c.store.state.archive.values.contains { $0.tab.id == shownID }
            expect(c.store.tab(shownID) == nil && archived && c.store.todayRowTabs(ofSpace: space).isEmpty,
                   "[real click] Clear archives the lone tab on screen too (Arc)")
            expect(c.shownTabID == afterClose, "the window shows what closing the last Today tab shows (\(c.shownTabID ?? "the empty page"), expected \(afterClose ?? "the empty page"))")
            expect(c.toast.shownText == "Archived 1 tab" && c.toast.actionButton != nil, "the toast says so, with Undo (\(c.toast.shownText ?? "-"))")
            expect(divider()?.showsClearArrow == false, "no ↓ with Today empty")
        }
        realClick("the toast's Undo (lone)", settle: 0.8) { [self] in c.toast.actionButton }
        run { [self] in
            expect(tpLayout(space) == layoutLone && c.shownTabID == shownID,
                   "[real click] the toast's Undo puts the tab back in its place, on screen (shown \(c.shownTabID ?? "none"))")
        }
        hover("off the sidebar") { offSidebar() }
        run { [self] in
            _ = try? c.store.undo()   // the in-app Clear of the many tabs
            c.reloadAll(animated: false)
            expect(tpLayout(space) == layoutBefore, "[in-app] Undo after the first Clear restores Today exactly")
        }

        run { [self] in
            DividerRowView.previewsClear = true
            NSApp.appearance = nil
            TidyHint.dayOverride = nil
            TidyHint.allowedInScripts = false
            check(asserted >= 36, "\(tag): zero-guard: \(asserted) assertions made (36 expected)")
        }
    }
}
#endif
