// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// `--script s16` (both engines): S16 sidebar tab screenshots with REAL input. The pointer moves and the card's buttons
/// are clicked by the stable UI driver (`AIRC_REAL_KEYS=1`, `AIRC_UI_DEDICATED_SESSION=1`, launched in front), so the
/// rows' own tracking areas see the pointer, as a person's mouse. Without the driver or a key window it reports FAIL-ENV
/// and stops: a posted-event run is `--script previews`.
///   - the card comes after the dwell (none at 0.25 s), beside the sidebar, with the right page's picture: a background
///     tab its kept one, the page on screen a live one, at the display's scale;
///   - an unloaded tab shows its last picture with "Not loaded · pictured …", an old picture "Pictured N min ago";
///   - pin, add to Favorites, remove from Favorites, split and Peek, each with a real click on the card;
///   - "Show Hover Preview" off in a pinned tab's menu: no card for that row, others still have theirs; back on;
///   - Settings' "Show tab previews" off: no card;
///   - VoiceOver: the card is a labelled group, its buttons named and pressable;
///   - 50 tabs pictured one after another: the kept pictures stay at the cache's limit, least recently used go first.
extension SnapshotRunner {
    func parityS16Scenario() {
        let tp = { self.c.tabPreview }
        let engine = { self.app?.engine.name ?? "?" }
        var server: LocalPageServer?
        var base = ""
        var home = ""
        var red = "", blue = "", green = ""
        var many: [String] = []
        var realMoves = 0, realClicks = 0
        var envFailed = false
        let page = { self.c.pageView(for: self.c.currentSpaceID) }
        let hues = ["#d32f2f", "#1e5fd6", "#2e9b4f"]
        func colored(_ name: String, _ hex: String) -> String {
            "<title>\(name) page</title><style>html,body{margin:0;height:100%;background:\(hex)}"
                + "h1{margin:0;padding:48px;font:600 56px -apple-system,sans-serif;color:#fff}</style><h1>\(name)</h1>"
        }
        func row(_ tabID: String) -> TabRowView? {
            guard let p = page() else { return nil }
            p.layoutSubtreeIfNeeded()
            return p.list.subviews.compactMap { $0 as? TabRowView }.first { $0.tabID == tabID }
        }
        func pinnedRow(_ itemID: String) -> TabRowView? {
            guard let p = page() else { return nil }
            p.layoutSubtreeIfNeeded()
            return p.list.subviews.compactMap { $0 as? TabRowView }.first { $0.entry?.item?.id == itemID }
        }
        func tile(_ itemID: String) -> FavoriteTileView? {
            guard let p = page() else { return nil }
            p.layoutSubtreeIfNeeded()
            return p.favorites.subviews.compactMap { $0 as? FavoriteTileView }.first { $0.item?.id == itemID }
        }
        func centre(_ v: NSView) -> NSPoint { v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil) }
        func s16(_ ok: Bool, _ what: String) { check(ok, "s16 \(engine()): " + what) }
        func realInput() -> Bool {
            UIDriverClient.available && ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1"
                && NSApp.isActive && c.window.isKeyWindow && c.window.isOnActiveSpace
        }
        func averageColor(_ img: CGImage?) -> (r: Double, g: Double, b: Double)? {
            guard let img else { return nil }
            var px = [UInt8](repeating: 0, count: 64)
            guard let ctx = CGContext(data: &px, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: 4, height: 4))
            var r = 0.0, g = 0.0, b = 0.0
            for i in 0..<16 { r += Double(px[4 * i]); g += Double(px[4 * i + 1]); b += Double(px[4 * i + 2]) }
            return (r / 4080, g / 4080, b / 4080)
        }
        func describe(_ x: (r: Double, g: Double, b: Double)?) -> String {
            x.map { String(format: "rgb %.2f %.2f %.2f", $0.r, $0.g, $0.b) } ?? "no picture"
        }
        func isRed(_ x: (r: Double, g: Double, b: Double)?) -> Bool { x.map { $0.r > 0.6 && $0.b < 0.4 } ?? false }
        func isBlue(_ x: (r: Double, g: Double, b: Double)?) -> Bool { x.map { $0.b > 0.6 && $0.r < 0.4 } ?? false }
        func isGreen(_ x: (r: Double, g: Double, b: Double)?) -> Bool { x.map { $0.g > 0.45 && $0.r < 0.4 } ?? false }

        /// A real HID move to `point()` (window coordinates); every later step is skipped once the environment failed.
        func move(_ what: String, _ point: @escaping () -> NSPoint?) {
            step { [self] done in
                guard !envFailed else { return done() }
                guard realInput() else {
                    envFailed = true
                    note("FAIL-ENV s16 \(engine()): \(what): no real input (driver \(UIDriverClient.available), active \(NSApp.isActive), "
                         + "key \(c.window.isKeyWindow), on active Space \(c.window.isOnActiveSpace))")
                    return done()
                }
                guard let p = point() else { s16(false, "\(what): target not on screen"); return done() }
                UIDriverClient.move(p, in: c.window) { [self] ok, out in
                    if ok { realMoves += 1 } else { envFailed = true; note("FAIL-ENV s16 \(engine()): \(what): driver move failed: \(out)") }
                    done()
                }
            }
        }
        /// Off the sidebar, onto the page, until any card is gone (past the grace and the warm return).
        func away() {
            move("pointer to the page") { [self] in centre(c.card) }
            wait(0.7)
        }
        func waitShown(_ timeout: Double = 2, _ then: @escaping () -> Void) {
            waitUntil({ tp().isShowing }, timeout: timeout, then: then)
        }
        /// A real click at the card's button.
        func click(_ b: TabPreviewCardView.Button, _ what: String, until ok: @escaping () -> Bool) {
            var before: String?
            run { before = tp().shownEntry?.id }
            // Straight from the row to the button, across the rows below it (menu aim keeps the card on its row).
            move("\(what): to the button") { tp().card?.windowPoint(of: b) }
            run { [self] in
                guard !envFailed else { return }
                s16(tp().isShowing && tp().shownEntry?.id == before,
                    "\(what): the card stays on its row while the pointer crosses other rows to it (aims \(tp().stats.aims.suffix(4)))")
            }
            wait(0.35)   // longer than the grace off the row: the card must stay while the pointer is on it
            step { [self] done in
                guard !envFailed else { return done() }
                guard tp().isShowing, let p = tp().card?.windowPoint(of: b) else {
                    s16(false, "\(what): the card stays while the pointer crosses to it")
                    return done()
                }
                let g = c.window.convertPoint(toScreen: p), top = NSScreen.screens.first?.frame.maxY ?? 0
                UIDriverClient.run(["--click", String(Double(g.x)), String(Double(top - g.y))]) { [self] okay, out in
                    if okay { realClicks += 1 } else { envFailed = true; note("FAIL-ENV s16 \(engine()): \(what): driver click failed: \(out)") }
                    waitUntil(ok, timeout: 3) { done() }
                }
            }
        }

        // MARK: Fixtures

        step { [self] done in
            var pages: [String: LocalPageServer.Page] = [
                "/red.html": .init(body: colored("Red", hues[0])),
                "/blue.html": .init(body: colored("Blue", hues[1])),
                "/green.html": .init(body: colored("Green", hues[2])),
            ]
            for i in 0..<47 {
                let hex = String(format: "#%02x%02x%02x", 40 + (i * 37) % 200, 40 + (i * 71) % 200, 40 + (i * 113) % 200)
                pages["/p\(i).html"] = .init(body: colored("Page \(i)", hex))
            }
            server = LocalPageServer(responses: pages)
            server?.start { port in
                base = port.map { "http://localhost:\($0)" } ?? ""
                done()
            }
        }
        run { [self] in
            guard !base.isEmpty else { return s16(false, "a loopback server") }
            home = c.currentSpaceID
            try? c.store.updateSpace(home) { $0.theme.appearance = .light }
            red = (try? c.store.openTab(url: base + "/red.html", inSpace: home, title: "Red page"))?.id ?? ""
            blue = (try? c.store.openTab(url: base + "/blue.html", inSpace: home, title: "Blue page"))?.id ?? ""
            green = (try? c.store.openTab(url: base + "/green.html", inSpace: home, title: "Green page"))?.id ?? ""
            c.reloadAll(animated: false)
            NSApp.activate(ignoringOtherApps: true)
            c.window.makeKeyAndOrderFront(nil)
        }
        step { [self] done in
            waitUntil({ self.c.window.isKeyWindow && NSApp.isActive }, timeout: 5) {
                self.note("s16 \(engine()): real input \(realInput()) (driver \(UIDriverClient.available), active \(NSApp.isActive), "
                          + "key \(self.c.window.isKeyWindow), scale \(self.c.window.backingScaleFactor))")
                done()
            }
        }
        func showAndSettle(_ id: @escaping () -> String) {
            run { [self] in c.show(id(), focus: false) }
            step { [self] done in
                waitUntil({ self.c.engineTab(for: id())?.isLoading == false && self.c.engineTab(for: id())?.title.hasSuffix("page") == true },
                          timeout: 8) { done() }
            }
            wait(1.6)   // the picture taken once a shown page has settled (1.2 s)
        }
        showAndSettle { red }
        showAndSettle { green }
        showAndSettle { blue }   // blue on screen; red and green kept

        // MARK: 1. The dwell and a background tab's kept picture

        away()
        move("onto the red row") { row(red).map(centre) }
        var enteredAt: CFTimeInterval = 0
        run { enteredAt = tp().stats.lastEnterAt }
        step { done in
            let at = enteredAt + 0.25 - CACurrentMediaTime()
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, at)) { done() }
        }
        run { [self] in
            guard !envFailed else { return }
            s16(enteredAt > 0 && !tp().isShowing, "no card 0.25 s after the pointer reached the row (real move)")
        }
        step { done in waitShown { done() } }
        run { [self] in
            guard !envFailed else { return }
            let dwell = tp().stats.lastShownAt - enteredAt
            s16(tp().isShowing && dwell >= TabPreviewController.dwell - 0.02 && dwell < TabPreviewController.dwell + 0.25,
                String(format: "the card after the dwell: %.0f ms from the row's own enter event (%.0f ms set)", dwell * 1000,
                       TabPreviewController.dwell * 1000))
            let color = averageColor(tp().card?.thumbnailImage)
            s16(tp().thumbnail == .cached && isRed(color) && tp().card?.staleHintText == nil,
                "a background tab shows its kept picture, fresh: no age hint (\(tp().thumbnail.rawValue), \(describe(color)), "
                + "hint \(tp().card?.staleHintText ?? "none"))")
            if let card = tp().presentedCard, let r = row(red) {
                let cardRect = card.convert((card as? TabPreviewCardView)?.cardRect ?? card.bounds, to: nil)
                let sidebar = c.sidebar.convert(c.sidebar.bounds, to: nil)
                let rowRect = r.convert(r.bounds, to: nil)
                s16(abs(cardRect.minX - sidebar.maxX - TabPreviewController.gap) < 2 && abs(cardRect.maxY - rowRect.maxY) < 12,
                    "beside the sidebar, level with the row (card x \(Int(cardRect.minX)), sidebar edge \(Int(sidebar.maxX)))")
            }
            if let img = tp().card?.thumbnailImage {
                let need = (TabPreviewCardView.width - 2 * TabPreviewCardView.inset) * c.window.backingScaleFactor
                s16(CGFloat(img.width) >= need * 0.95,
                    "the picture is sharp at the display's scale (\(img.width) px wide for \(Int(need)) px)")
            }
            // VoiceOver
            if let card = tp().card {
                let buttons = (card.accessibilityChildren() ?? []).compactMap { $0 as? NSView }.filter { $0.accessibilityRole() == .button }
                let names = buttons.compactMap { $0.accessibilityLabel() }
                s16(card.accessibilityRole() == .group && card.accessibilityLabel() == "Preview of Red page, \(card.hostText)"
                    && names == ["Pin Tab", "Add to Favorites", "Open in Split View", "Peek"],
                    "VoiceOver: \"\(card.accessibilityLabel() ?? "-")\", buttons \(names)")
            }
        }
        capture("s16-kept-light")

        // MARK: 2. Row to row: the page on screen is pictured live

        move("onto the blue row") { row(blue).map(centre) }
        wait(0.5)
        run { [self] in
            guard !envFailed else { return }
            let color = averageColor(tp().card?.thumbnailImage)
            s16(tp().isShowing && tp().shownEntry?.liveTab?.id == blue && tp().thumbnail == .live && isBlue(color)
                && tp().card?.staleHintText == nil,
                "the page on screen: a live picture, no hint (\(tp().thumbnail.rawValue), \(describe(color)))")
        }

        // MARK: 3. Unloaded: the last picture with its hint; an old picture of a loaded page

        away()
        run { [self] in
            guard let p = c.engineTab(for: red) else { return }
            #if canImport(AircCore)
            if c.app?.engine is ChromiumEngine, !ProtectedMedia.isWebKitPage(p) { _ = p.discard(); return }
            #endif
            _ = p
            c.forgetPage(red, close: true)
        }
        wait(0.5)
        move("onto the unloaded red row") { row(red).map(centre) }
        step { done in waitShown { done() } }
        run { [self] in
            guard !envFailed else { return }
            let color = averageColor(tp().card?.thumbnailImage)
            let hint = tp().card?.staleHintText ?? ""
            s16(c.isPageUnloaded(red) && tp().thumbnail == .cached && isRed(color) && hint.hasPrefix("Not loaded · pictured "),
                "an unloaded tab shows its last picture with \"\(hint)\" (unloaded \(c.isPageUnloaded(red)), \(describe(color)))")
            s16(tp().card?.accessibilityHelp() == hint, "VoiceOver reads the hint as the card's help")
            tp().card?.layoutSubtreeIfNeeded()
            s16(tp().card?.staleHintFits == true, "the hint's whole text fits its pill")
        }
        capture("s16-unloaded-light")
        away()
        run { TabPreviewCache.shared.backdateForTesting(5 * 60 + 5) }
        move("onto the green row") { row(green).map(centre) }
        step { done in waitShown { done() } }
        run { [self] in
            guard !envFailed else { return }
            let color = averageColor(tp().card?.thumbnailImage)
            s16(tp().thumbnail == .cached && isGreen(color) && tp().card?.staleHintText == "Pictured 5 min ago",
                "a loaded tab's 5-minute-old picture says \"\(tp().card?.staleHintText ?? "nothing")\" (\(describe(color)))")
        }
        run { [self] in
            try? c.store.updateSpace(home) { $0.theme.appearance = .dark }
            c.reloadAll(animated: false)
        }
        away()
        move("onto the green row, dark") { row(green).map(centre) }
        step { done in waitShown { done() } }
        wait(0.5)
        run { [self] in
            guard !envFailed else { return }
            s16(tp().isShowing && c.currentPalette.isDark && tp().card?.staleHintText != nil, "the card and its hint in a dark theme")
        }
        capture("s16-stale-dark")
        run { [self] in
            try? c.store.updateSpace(home) { $0.theme.appearance = .light }
            c.reloadAll(animated: false)
        }

        // MARK: 4. Quick actions with real clicks

        away()
        move("onto the green row (pin)") { row(green).map(centre) }
        step { done in waitShown { done() } }
        click(.pin, "pin a Today tab") { [self] in c.store.item(c.store.tab(green)?.itemID)?.isFavorite == false }
        run { [self] in
            guard !envFailed else { return }
            let item = c.store.item(c.store.tab(green)?.itemID)
            s16(item != nil && item?.isFavorite == false && !tp().isShowing && tp().stats.actions.last == "pin",
                "pin (real click): pinned \(item != nil), actions \(tp().stats.actions)")
        }
        var greenItem = ""
        run { [self] in greenItem = c.store.tab(green)?.itemID ?? "" }

        // "Show Hover Preview" off for the pinned row, from its menu.
        away()
        run { [self] in
            guard let r = pinnedRow(greenItem), let e = r.entry else { return s16(false, "the pinned green row") }
            let m = c.menu(for: e)
            guard let i = m.items.firstIndex(where: { $0.title == "Show Hover Preview" }) else {
                return s16(false, "a pinned tab's menu has \"Show Hover Preview\" (\(m.items.map(\.title)))")
            }
            s16(m.items[i].state == .on, "a pinned tab's menu: \"Show Hover Preview\", on")
            m.performActionForItem(at: i)
        }
        var shows = 0
        run { shows = tp().stats.shows }
        move("onto the pinned green row (preview off)") { pinnedRow(greenItem).map(centre) }
        wait(1.0)
        run { [self] in
            guard !envFailed else { return }
            s16(!tp().isShowing && tp().stats.shows == shows, "\"Show Hover Preview\" off: no card for that row after 1 s")
        }
        move("onto the blue row (others keep theirs)") { row(blue).map(centre) }
        step { done in waitShown { done() } }
        run { [self] in
            guard !envFailed else { return }
            s16(tp().isShowing && tp().shownEntry?.liveTab?.id == blue, "another row still has its card")
        }
        away()
        run { [self] in
            guard let e = pinnedRow(greenItem)?.entry else { return }
            let m = c.menu(for: e)
            guard let i = m.items.firstIndex(where: { $0.title == "Show Hover Preview" }) else { return }
            s16(m.items[i].state == .off, "the menu shows it off")
            m.performActionForItem(at: i)
        }
        move("onto the pinned green row (preview on)") { pinnedRow(greenItem).map(centre) }
        step { done in waitShown { done() } }
        run { [self] in
            guard !envFailed else { return }
            s16(tp().isShowing && tp().shownEntry?.item?.id == greenItem, "back on: the pinned row's card")
        }
        click(.favorite, "add a pinned tab to Favorites") { [self] in c.store.item(greenItem)?.isFavorite == true }
        run { [self] in
            guard !envFailed else { return }
            s16(c.store.item(greenItem)?.isFavorite == true && tp().stats.actions.last == "favorite", "add to Favorites (real click)")
        }
        away()
        move("onto the green Favorite") { tile(greenItem).map(centre) }
        step { done in waitShown { done() } }
        click(.favorite, "remove a Favorite from its tile") { [self] in c.store.item(greenItem)?.isFavorite != true }
        run { [self] in
            guard !envFailed else { return }
            let back = c.store.todayTabs(ofSpace: home).first { $0.url.hasSuffix("/green.html") }
            s16(c.store.item(greenItem)?.isFavorite != true && back != nil && tp().stats.actions.last == "unfavorite",
                "remove from Favorites (real click): back in Today \(back != nil)")
            green = back?.id ?? green
        }
        away()
        move("onto the red row (split)") { row(red).map(centre) }
        step { done in waitShown { done() } }
        click(.split, "open in a split with the page on screen") { [self] in c.shownSplitID != nil }
        run { [self] in
            guard !envFailed else { return }
            let x = c.shownSplitID.flatMap { c.store.split($0) }
            s16(x.map { Set($0.tabIDs) == [red, blue] } ?? false, "split (real click): \(x?.tabIDs.count ?? 0) panes")
            c.separateShownSplit()
            c.show(blue, focus: false)
        }
        away()
        move("onto the green row (Peek)") { row(green).map(centre) }
        step { done in waitShown { done() } }
        click(.peek, "Peek") { [self] in c.peek != nil }
        run { [self] in
            guard !envFailed else { return }
            s16(c.peek != nil && tp().stats.actions.last == "peek", "Peek (real click)")
            c.closePeek()
        }
        wait(0.4)

        // MARK: 5. Settings' "Show tab previews" off

        away()
        run { [self] in app?.settings.values.tabPreviews = false }
        run { shows = tp().stats.shows }
        move("onto the blue row (previews off)") { row(blue).map(centre) }
        wait(1.0)
        run { [self] in
            guard !envFailed else { return }
            s16(!tp().isShowing && tp().stats.shows == shows && TabPreviewCache.shared.count == 0,
                "Show tab previews off: no card after 1 s, no pictures kept")
            app?.settings.values.tabPreviews = true
        }

        // MARK: 6. Memory: 50 tabs pictured one after another

        away()
        var footprintBefore: UInt64 = 0
        run { [self] in
            footprintBefore = Self.physFootprint()
            many = (0..<47).compactMap { (try? c.store.openTab(url: base + "/p\($0).html", inSpace: home, title: "Page \($0)"))?.id }
            c.reloadAll(animated: false)
        }
        for i in 0..<47 {
            step { [self] done in
                guard i < many.count else { return done() }
                let id = many[i]
                c.show(id, focus: false)
                waitUntil({ self.c.engineTab(for: id)?.isLoading == false && self.c.engineTab(for: id)?.title.hasPrefix("Page") == true },
                          timeout: 5) {
                    tp().capture(id, reason: .hover) { _ in done() }
                }
            }
        }
        run { [self] in
            let cache = TabPreviewCache.shared
            let mb = Double(cache.storedBytes) / 1_048_576
            let limitMB = Double(TabPreviewCache.limit) * Double(TabPreviewCache.maxPixels.width * TabPreviewCache.maxPixels.height * 4) / 1_048_576
            let total = c.store.todayTabs(ofSpace: home).count
            let newestKept = many.suffix(5).allSatisfy { cache.hasShotForTesting(tab: $0) }
            let oldestGone = many.prefix(5).allSatisfy { !cache.hasShotForTesting(tab: $0) }
            // Red's page was closed on WebKit (forgetPage) and discarded on Chromium: 49 or 50 rows.
            s16(many.count == 47 && total >= 49 && cache.count <= TabPreviewCache.limit && mb <= limitMB && newestKept && oldestGone,
                String(format: "50 tabs opened (%d in Today): %d pictures kept (limit %d), %.1f MB decoded (bound %.1f MB); newest kept %@, oldest evicted %@",
                       total, cache.count, TabPreviewCache.limit, mb, limitMB, "\(newestKept)", "\(oldestGone)"))
            let after = Self.physFootprint()
            note(String(format: "s16 %@: app footprint %.0f MB → %.0f MB over 47 more tabs (pages included)", engine(),
                        Double(footprintBefore) / 1_048_576, Double(after) / 1_048_576))
        }
        // A real hover on a newest row still shows its kept picture after the churn.
        move("onto a recent row") { row(many.dropLast().last ?? "").map(centre) }
        step { done in waitShown { done() } }
        run { [self] in
            guard !envFailed else { return }
            s16(tp().isShowing && tp().thumbnail == .cached, "after 50 tabs a recent tab still shows its kept picture (\(tp().thumbnail.rawValue))")
        }
        away()
        run { [self] in
            note("s16 \(engine()): \(realMoves) real pointer moves, \(realClicks) real clicks (stable UI driver); actions \(tp().stats.actions)")
            server?.stop()
        }
    }

    /// The app's physical footprint (what Activity Monitor's Memory shows).
    static func physFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }
}
#endif
