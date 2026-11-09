// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script previews` (both engines): SB-45 tab previews on loopback pages (a red, a blue and a green page). Hover
/// calls the rows' and the card's own enter and exit handlers, what their tracking areas call: posted mouse moves never
/// reach tracking areas (the window server makes those events), so they can't drive hover in a background run. Clicks
/// on rows are posted through the app's event queue (a row's press tracks its own release); the card's buttons take
/// theirs through their own handlers, at the view the window hit-tests there. Never HID.
///   - the dwell (no card at 0.25 s, the card at about 0.4 s) and the card beside the sidebar, level with the row;
///   - a background tab shows its kept picture, the page on screen a live one, a tab never shown the placeholder, and
///     an unloaded (discarded) tab still its kept picture; row to row with the card up is instant;
///   - moving within a row runs nothing: no timer, no picture, no preview call (the hover cost, measured and logged);
///   - it hides on Esc, a scroll, a click, the sidebar collapsing and a menu, and never shows during a row drag or a
///     Space change; the pointer can cross to the card and use it;
///   - the actions: pin, add to Favorites, remove from Favorites, open in a split, Peek;
///   - Reduce Motion fades instead of growing; the card in a light and a dark theme; the setting turns it off.
extension SnapshotRunner {
    func previewsScenario() {
        let tp = { self.c.tabPreview }
        var server: LocalPageServer?
        var base = ""
        var red = "", blue = "", green = "", otherSpace = ""
        var home = ""
        /// The view the pointer is on (a row, the card; nil: elsewhere), whose exit handler runs when it moves on.
        var lastHovered: NSView?
        let page = { self.c.pageView(for: self.c.currentSpaceID) }
        func colored(_ name: String, _ hex: String) -> String {
            "<title>\(name) page</title><style>html,body{margin:0;height:100%;background:\(hex)}"
                + "h1{margin:0;padding:48px;font:600 56px -apple-system,sans-serif;color:#fff}</style><h1>\(name)</h1>"
        }
        func row(_ tabID: String) -> TabRowView? {
            guard let p = page() else { return nil }
            p.layoutSubtreeIfNeeded()
            return p.list.subviews.compactMap { $0 as? TabRowView }.first { $0.tabID == tabID }
        }
        func tile(_ itemID: String) -> FavoriteTileView? {
            guard let p = page() else { return nil }
            p.layoutSubtreeIfNeeded()
            return p.favorites.subviews.compactMap { $0 as? FavoriteTileView }.first { $0.item?.id == itemID }
        }
        func centre(_ v: NSView) -> NSPoint { v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil) }
        /// Window point of the page card's middle: on no row.
        func away() -> NSPoint { centre(c.card) }
        func mouseEvent(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1,
                               pressure: type == .leftMouseDown ? 1 : 0)
        }
        /// The pointer to `p` (window coordinates), over `target` (a row, the card, nil for elsewhere): the exit handler
        /// of the view it leaves, then the enter handler of the one it reaches, with events at `p`.
        func movePointer(to p: NSPoint, over target: NSView?) {
            if lastHovered !== target {
                if let prev = lastHovered, let e = NSEvent.enterExitEvent(with: .mouseExited, location: p, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: c.window.windowNumber, context: nil,
                    eventNumber: 0, trackingNumber: 0, userData: nil) { prev.mouseExited(with: e) }
                if let target, let e = NSEvent.enterExitEvent(with: .mouseEntered, location: p, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: c.window.windowNumber, context: nil,
                    eventNumber: 0, trackingNumber: 0, userData: nil) { target.mouseEntered(with: e) }
            }
            lastHovered = target
        }
        func hover(_ v: NSView?) {
            guard let v else { return movePointer(to: away(), over: nil) }
            movePointer(to: centre(v), over: v)
        }
        func waitShown(_ name: String, timeout: Double = 1.5, _ then: @escaping () -> Void) {
            waitUntil({ tp().isShowing }, timeout: timeout, then: then)
        }
        /// The window can't draw (screen locked, off the active Space, covered): engine pictures may not come.
        func undrawn() -> String? {
            if Self.screenLocked { return "the screen is locked" }
            if !c.window.isOnActiveSpace { return "our window isn't on the active Space" }
            if !c.window.occlusionState.contains(.visible) { return "our window is covered" }
            return nil
        }
        func pictureCheck(_ ok: Bool, _ what: String) {
            if !ok, let why = undrawn() { skip(what + " (\(why))") } else { check(ok, what) }
        }
        func averageColor(_ img: CGImage?) -> (r: Double, g: Double, b: Double)? {
            guard let img else { return nil }
            var px = [UInt8](repeating: 0, count: 64)
            guard let ctx = CGContext(data: &px, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: 4, height: 4))
            var r = 0.0, g = 0.0, b = 0.0
            for i in 0..<16 { r += Double(px[4 * i]); g += Double(px[4 * i + 1]); b += Double(px[4 * i + 2]) }
            return (r / 4080, g / 4080, b / 4080)
        }
        func describe(_ c: (r: Double, g: Double, b: Double)?) -> String {
            c.map { String(format: "rgb %.2f %.2f %.2f", $0.r, $0.g, $0.b) } ?? "no picture"
        }
        func ms(_ s: Double) -> String { String(format: "%.2f ms", s * 1000) }
        func median(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.sorted()[a.count / 2] }

        step { [self] done in
            server = LocalPageServer(responses: [
                "/red.html": .init(body: colored("Red", "#d32f2f")),
                "/blue.html": .init(body: colored("Blue", "#1e5fd6")),
                "/green.html": .init(body: colored("Green", "#2e9b4f")),
            ])
            server?.start { port in
                base = port.map { "http://localhost:\($0)" } ?? ""
                done()
            }
        }
        run { [self] in
            guard !base.isEmpty else { return check(false, "previews: a loopback server") }
            home = c.currentSpaceID
            try? c.store.updateSpace(home) { $0.theme.appearance = .light }
            red = (try? c.store.openTab(url: base + "/red.html", inSpace: home, title: "Red page"))?.id ?? ""
            blue = (try? c.store.openTab(url: base + "/blue.html", inSpace: home, title: "Blue page"))?.id ?? ""
            green = (try? c.store.openTab(url: base + "/green.html", inSpace: home, title: "Green page"))?.id ?? ""
            otherSpace = (try? c.store.createSpace(name: "Elsewhere", icon: .emoji("🌿"), profileID: c.store.profile(ofSpace: home).id,
                                                   after: home))?.id ?? ""
            c.reloadAll(animated: false)
            c.show(red, focus: false)
            note("previews: \(undrawn() ?? "window drawn"), key \(c.window.isKeyWindow)")
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
        showAndSettle { blue }
        run { [self] in
            let r = tp().stats.results.map { "\($0.reason) \($0.ok ? "ok" : "nil") \(ms($0.seconds))" }
            note("previews: pictures so far: " + r.joined(separator: ", "))
            pictureCheck(TabPreviewCache.shared.shot(tab: red, item: nil, url: base + "/red.html") != nil,
                         "previews: the red page left the screen with a picture kept (\(r.count) taken)")
        }

        // 1. Hover: the pointer comes onto the red row from off the sidebar.
        run { [self] in
            lastHovered = nil
            hover(nil)
            note("previews: hover through the rows' and the card's own enter and exit handlers")
        }
        wait(0.3)
        run { hover(row(red)) }
        // 2. The dwell, and the card beside the row.
        wait(0.25)
        run { [self] in check(!tp().isShowing, "previews: no card 0.25 s after the pointer rests on a row") }
        step { [self] done in waitShown("dwell") { done() } }
        run { [self] in
            let s = tp().stats
            let dwell = s.lastShownAt - s.lastEnterAt
            check(tp().isShowing && dwell >= 0.38 && dwell <= 0.6, "previews: the card after a dwell of \(ms(dwell)) (0.4 s)")
            check(s.lastPresentSprang, "previews: it grows on the popover spring from the row's edge")
            guard let card = tp().card, let r = row(red) else { return check(false, "previews: the card and its row") }
            let rect = card.convert(card.cardRect, to: c.root)
            let sidebar = c.sidebar.convert(c.sidebar.bounds, to: c.root)
            let rowRect = r.convert(r.bounds, to: c.root)
            let expectTop = min(max(8, rowRect.minY - 4), c.root.bounds.height - rect.height - 8)
            let beside = abs(rect.minX - (sidebar.maxX + TabPreviewController.gap)) <= 1
            let level = abs(rect.minY - expectTop) <= 1
            check(beside && level && c.root.bounds.contains(rect),
                  String(format: "previews: the card beside the sidebar (x %.0f, sidebar ends %.0f) and level with the row (top %.0f, row %.0f), %.0f × %.0f",
                         rect.minX, sidebar.maxX, rect.minY, rowRect.minY, rect.width, rect.height))
            check(card.titleText == "Red page" && card.hostText.hasPrefix("localhost"),
                  "previews: title \"\(card.titleText)\", host \"\(card.hostText)\"")
            let color = averageColor(card.thumbnailImage)
            pictureCheck(tp().thumbnail == .cached && (color.map { $0.r > 0.55 && $0.g < 0.4 && $0.b < 0.4 } ?? false),
                         "previews: a background tab shows its kept picture (\(tp().thumbnail.rawValue), \(describe(color)))")
        }
        capture("previews-card")

        // 3. Row to row: instant; the page on screen gets a live picture.
        run { [self] in hover(row(blue)) }
        step { [self] done in waitUntil({ tp().shownEntry?.liveTab?.id == blue }, timeout: 0.5) { done() } }
        run { [self] in
            let s = tp().stats
            check(tp().shownEntry?.liveTab?.id == blue && s.lastShownAt - s.lastEnterAt < 0.05,
                  "previews: row to row with the card up moves it at once (\(ms(s.lastShownAt - s.lastEnterAt)))")
        }
        step { [self] done in waitUntil({ tp().thumbnail == .live }, timeout: 1.2) { done() } }
        run { [self] in
            let color = averageColor(tp().card?.thumbnailImage)
            pictureCheck(tp().thumbnail == .live && (color.map { $0.b > 0.55 && $0.r < 0.4 } ?? false),
                         "previews: the page on screen shows a live picture (\(tp().thumbnail.rawValue), \(describe(color)))")
        }
        capture("previews-live")
        run { [self] in hover(row(green)) }
        wait(0.1)
        run { [self] in
            check(tp().shownEntry?.liveTab?.id == green && tp().thumbnail == .placeholder && tp().card?.showsPlaceholder == true,
                  "previews: a tab never shown gets the placeholder (\(tp().thumbnail.rawValue))")
        }
        capture("previews-placeholder")

        // 4. The hover cost: moves inside a row run nothing of the preview's.
        run { [self] in
            // Each move goes through the app and to the row's own mouseMoved (its favicon's "back to pinned URL" hover),
            // which is what runs per move while the pointer is on a row.
            guard let r = row(green) else { return check(false, "previews: the green row") }
            let s0 = tp().stats
            let c0 = s0.requests.values.reduce(0, +)
            var costs: [Double] = []
            let p = centre(r)
            for i in 0..<120 {
                let q = NSPoint(x: p.x - 40 + CGFloat(i % 80), y: p.y + CGFloat(i % 7) - 3)
                let t0 = CACurrentMediaTime()
                if let e = mouseEvent(.mouseMoved, q) { NSApp.sendEvent(e); r.mouseMoved(with: e) }
                costs.append(CACurrentMediaTime() - t0)
            }
            let s1 = tp().stats
            let still = s1.enters == s0.enters && s1.dwellTimers == s0.dwellTimers && s1.requests.values.reduce(0, +) == c0 && s1.shows == s0.shows
            check(still, "previews: 120 moves inside a row: \(s1.enters - s0.enters) preview calls, \(s1.dwellTimers - s0.dwellTimers) timers, "
                  + "\(s1.requests.values.reduce(0, +) - c0) pictures")
            note("previews: hover cost: a move inside a row \(ms(median(costs))) median, \(ms(costs.max() ?? 0)) max (the app's dispatch and the row's handler)")
        }
        // 5. Hiding: Esc.
        run { [self] in hover(nil); hover(row(blue)) }
        step { [self] done in waitShown("esc") { done() } }
        run { [self] in postKey("\u{1b}", keyCode: 53) }
        wait(0.15)
        run { [self] in check(!tp().isShowing, "previews: Esc hides it") }
        wait(0.5)
        run { [self] in check(!tp().isShowing, "previews: and it stays hidden while the pointer stays on the row") }
        // A scroll.
        run { [self] in hover(nil); hover(row(red)) }
        step { [self] done in waitShown("scroll") { done() } }
        run { [self] in
            if let r = row(red), let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0) {
                cg.location = c.window.convertPoint(toScreen: centre(r))
                cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(c.window.windowNumber))
                if let e = NSEvent(cgEvent: cg) { NSApp.sendEvent(e) }
            }
        }
        wait(0.1)
        run { [self] in check(!tp().isShowing, "previews: a scroll hides it") }
        // A click on another row.
        run { [self] in hover(nil) }
        wait(0.4)
        run { [self] in hover(row(blue)) }
        step { [self] done in waitShown("click") { done() } }
        step { [self] done in
            guard let r = row(red) else { return done() }
            hover(r)   // the card moves to red at once
            click(at: centre(r), in: c.window, done)
        }
        run { [self] in check(!tp().isShowing && c.shownTabID == red, "previews: a click on a row hides it (and opens the row)") }
        wait(0.6)
        run { [self] in check(!tp().isShowing, "previews: no card again until the pointer leaves the clicked row") }
        // The sidebar collapsing.
        run { [self] in hover(row(blue)) }
        step { [self] done in waitShown("collapse") { done() } }
        run { [self] in c.toggleSidebar() }
        wait(0.3)
        // The collapse moves the sidebar on the display link, which stops while the window isn't drawn.
        run { [self] in pictureCheck(!tp().isShowing, "previews: the sidebar collapsing hides it") }
        run { [self] in c.toggleSidebar() }
        wait(0.4)
        // A menu.
        run { [self] in hover(nil); hover(row(blue)) }
        step { [self] done in waitShown("menu") { done() } }
        run { [self] in
            let m = NSMenu()
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: m)
            check(!tp().isShowing, "previews: a menu opening hides it")
            NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: m)
        }
        // A Space change during the dwell.
        run { [self] in hover(nil); hover(row(green)) }
        wait(0.1)
        run { [self] in c.switchToSpace(otherSpace, animated: true) }
        wait(0.7)
        run { [self] in check(!tp().isShowing, "previews: no card when the Space changes during the dwell") }
        run { [self] in c.switchToSpace(home, animated: false) }
        wait(0.4)

        // 6. A row drag: the press hides the card; nothing shows while rows are dragged.
        run { [self] in hover(nil); hover(row(blue)) }
        step { [self] done in waitShown("drag") { done() } }
        step { [self] done in
            guard let r = row(blue), let other = row(green) else { check(false, "previews: drag rows"); return done() }
            let start = centre(r), end = NSPoint(x: start.x, y: start.y - 30)
            var duringPress: Bool?, duringDwell: Bool?, dragging = 0
            let probe = Timer(timeInterval: 0.15, repeats: false) { _ in
                duringPress = tp().isShowing
                dragging = self.c.dragsInProgress
                // A row entered mid-drag (the drag loop holds the real events): its dwell must not show a card.
                if let e = NSEvent.enterExitEvent(with: .mouseEntered, location: self.centre(of: other), modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: self.c.window.windowNumber,
                                                  context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) {
                    tp().hoverBegan(other, event: e)
                }
            }
            let late = Timer(timeInterval: 0.75, repeats: false) { _ in duringDwell = tp().isShowing }
            RunLoop.main.add(probe, forMode: .common)
            RunLoop.main.add(late, forMode: .common)
            let t0 = CACurrentMediaTime()
            let mover = Timer(timeInterval: 1.0 / 60, repeats: true) { t in
                let dt = CACurrentMediaTime() - t0
                if dt < 0.3 {
                    let f = CGFloat(dt / 0.3)
                    if let e = mouseEvent(.leftMouseDragged, NSPoint(x: start.x, y: start.y + (end.y - start.y) * f)) { NSApp.postEvent(e, atStart: false) }
                } else if dt < 0.9 {
                    if let e = mouseEvent(.leftMouseDragged, end) { NSApp.postEvent(e, atStart: false) }
                } else {
                    t.invalidate()
                    // Back where it started: the drop changes nothing.
                    if let e = mouseEvent(.leftMouseDragged, start) { NSApp.postEvent(e, atStart: false) }
                    if let e = mouseEvent(.leftMouseUp, start) { NSApp.postEvent(e, atStart: false) }
                }
            }
            RunLoop.main.add(mover, forMode: .common)
            // Through the app (its monitors see the press, as a person's), into the page's drag loop until the release.
            if let down = mouseEvent(.leftMouseDown, start) { NSApp.sendEvent(down) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.check(duringPress == false && duringDwell == false && dragging > 0,
                           "previews: hidden while a row is dragged (at the press \(duringPress.map { $0 ? "shown" : "hidden" } ?? "-"), "
                           + "after a dwell mid-drag \(duringDwell.map { $0 ? "shown" : "hidden" } ?? "-"), drags \(dragging))")
                tp().hoverEnded(other, event: nil)
                done()
            }
        }
        wait(0.6)
        run { [self] in check(!tp().isShowing, "previews: no card right after the drop") }

        // 7. Actions, with red on screen (the drag's press showed blue). The pointer crosses to the card and uses it.
        run { [self] in c.show(red, focus: false) }
        wait(0.3)
        func useButton(_ b: TabPreviewCardView.Button, on target: @escaping () -> NSView?, _ name: String,
                       then verify: @escaping () -> (Bool, String)) {
            run { [self] in hover(nil) }
            wait(0.35)
            run { [self] in hover(target()) }
            step { [self] done in waitShown(name) { done() } }
            run { [self] in
                guard let card = tp().card, let p = card.windowPoint(of: b) else { return }
                movePointer(to: p, over: card)
            }
            wait(0.35)   // longer than the grace off the row
            // The press and release go to the view under the button's centre (the window's own hit test), through its
            // handlers, in one turn. Posted clicks are routed by the window, and in a never-key window that can't
            // activate (the screen locked) it handed releases to the view an earlier press reached: Peek's release ran
            // the split button, the pin and Favorites clicks did nothing (2026-11-07, both engines).
            var hit = "-", actionsBefore = 0
            run { [self] in
                guard tp().isShowing, let card = tp().card, let p = card.windowPoint(of: b) else {
                    return check(false, "previews: \(name): the card stays while the pointer crosses to it")
                }
                check(card.isEnabled(b), "previews: \(name): the button is enabled")
                actionsBefore = tp().stats.actions.count
                guard let frame = c.window.contentView?.superview, let target = frame.hitTest(frame.convert(p, from: nil)),
                      let down = mouseEvent(.leftMouseDown, p), let up = mouseEvent(.leftMouseUp, p) else { return }
                hit = Self.describe(target) + String(format: " at x %.0f in the card", target.convert(target.bounds, to: card).minX)
                target.mouseDown(with: down)
                target.mouseUp(with: up)
            }
            wait(0.3)
            run { [self] in
                let (ok, detail) = verify()
                let acted = tp().stats.actions.count == actionsBefore + 1
                check(ok && !tp().isShowing && acted,
                      "previews: \(name) (\(detail); event \(acted ? tp().stats.actions.last ?? "-" : "-"); the click reached \(hit))")
            }
        }
        useButton(.pin, on: { row(green) }, "pin a Today tab") { [self] in
            let item = c.store.item(c.store.tab(green)?.itemID)
            return (item != nil && item?.isFavorite == false, "pinned \(item != nil)")
        }
        useButton(.favorite, on: { row(green) }, "add a pinned tab to Favorites") { [self] in
            let item = c.store.item(c.store.tab(green)?.itemID)
            return (item?.isFavorite == true, "Favorite \(item?.isFavorite == true)")
        }
        var greenItem = ""
        run { [self] in greenItem = c.store.tab(green)?.itemID ?? "" }
        useButton(.favorite, on: { tile(greenItem) }, "remove a Favorite from its tile") { [self] in
            let back = c.store.todayTabs(ofSpace: home).contains { $0.url.hasSuffix("/green.html") }
            return (c.store.item(greenItem)?.isFavorite != true && back, "back in Today \(back)")
        }
        run { [self] in green = c.store.todayTabs(ofSpace: home).first { $0.url.hasSuffix("/green.html") }?.id ?? green }
        useButton(.split, on: { row(blue) }, "open in a split with the page on screen") { [self] in
            let x = c.shownSplitID.flatMap { c.store.split($0) }
            return (x.map { Set($0.tabIDs) == [red, blue] } ?? false, "split \(x?.tabIDs.count ?? 0) panes")
        }
        run { [self] in
            c.separateShownSplit()
            c.show(red, focus: false)
        }
        wait(0.5)
        useButton(.peek, on: { row(green) }, "Peek") { [self] in
            let u = c.peek?.page.url?.absoluteString ?? ""
            return (c.peek != nil && (u.hasSuffix("/green.html") || u.isEmpty), "Peek open \(c.peek != nil)")
        }
        run { [self] in c.closePeek() }
        wait(0.4)

        // 8. An unloaded tab keeps its picture.
        run { [self] in
            hover(nil)
            guard let p = c.engineTab(for: blue) else { return }
            #if canImport(AircCore)
            if c.app?.engine is ChromiumEngine, !ProtectedMedia.isWebKitPage(p) { _ = p.discard(); return }
            #endif
            _ = p
            c.forgetPage(blue, close: true)
        }
        wait(0.5)
        run { [self] in hover(row(blue)) }
        step { [self] done in waitShown("unloaded") { done() } }
        run { [self] in
            let color = averageColor(tp().card?.thumbnailImage)
            pictureCheck(c.isPageUnloaded(blue) && tp().thumbnail == .cached && (color.map { $0.b > 0.55 } ?? false),
                         "previews: an unloaded tab shows its kept picture (unloaded \(c.isPageUnloaded(blue)), \(tp().thumbnail.rawValue), "
                         + "\(describe(color)))")
        }

        // 9. Reduce Motion, light and dark.
        run { [self] in
            hover(nil)
            TabPreviewController.reduceMotionOverride = true
        }
        wait(0.4)
        run { [self] in hover(row(red)) }
        step { [self] done in waitShown("reduce motion") { done() } }
        run { [self] in
            check(!tp().stats.lastPresentSprang && tp().card?.layer?.animation(forKey: "grow") == nil,
                  "previews: Reduce Motion fades it in without growing")
            TabPreviewController.reduceMotionOverride = nil
        }
        capture("previews-light")
        run { [self] in
            hover(nil)
            try? c.store.updateSpace(home) { $0.theme.appearance = .dark }
            c.reloadAll(animated: false)
        }
        wait(0.5)
        run { [self] in hover(row(red)) }
        step { [self] done in waitShown("dark") { done() } }
        wait(0.6)
        run { [self] in
            check(tp().isShowing && c.currentPalette.isDark, "previews: the card in a dark theme")
        }
        capture("previews-dark")

        // 10. The setting turns it off (and forgets the pictures).
        run { [self] in
            hover(nil)
            app?.settings.values.tabPreviews = false
        }
        wait(0.2)
        var timers = 0
        run { [self] in
            timers = tp().stats.dwellTimers
            hover(row(red))
        }
        wait(0.7)
        run { [self] in
            check(!tp().isShowing && tp().stats.dwellTimers == timers && TabPreviewCache.shared.count == 0,
                  "previews: Settings → Show tab previews off: no card, no timer, no pictures kept (\(TabPreviewCache.shared.count))")
            // The same moves inside a row as above, with previews off, for the difference.
            guard let r = row(red) else { return }
            var costs: [Double] = []
            let p = centre(r)
            for i in 0..<120 {
                let q = NSPoint(x: p.x - 40 + CGFloat(i % 80), y: p.y + CGFloat(i % 7) - 3)
                let t0 = CACurrentMediaTime()
                if let e = mouseEvent(.mouseMoved, q) { NSApp.sendEvent(e); r.mouseMoved(with: e) }
                costs.append(CACurrentMediaTime() - t0)
            }
            note("previews: hover cost with previews off: a move inside a row \(ms(median(costs))) median, \(ms(costs.max() ?? 0)) max")
        }
        run { [self] in
            app?.settings.values.tabPreviews = true
            hover(nil)
        }

        // The numbers for the report.
        run { [self] in
            let s = tp().stats
            note("previews: hover cost: entering a row \(ms(median(s.hoverCost))) median, \(ms(s.hoverCost.max() ?? 0)) max over \(s.hoverCost.count)")
            if let first = s.showCost.first {
                note("previews: showing the card: first \(ms(first)), then \(ms(median(Array(s.showCost.dropFirst())))) median over \(s.showCost.count)")
            }
            let byReason = Dictionary(grouping: s.results, by: \.reason)
            for (reason, rs) in byReason.sorted(by: { $0.key < $1.key }) {
                let ok = rs.filter(\.ok)
                note("previews: pictures (\(reason)): \(ok.count)/\(rs.count) came, \(ms(median(ok.map(\.seconds)))) median")
            }
            note("previews: \(s.dwellTimers) dwell timers, \(s.enters) row entries, \(s.shows) cards shown, actions \(s.actions)")
            server?.stop()
        }
    }

    private func centre(of v: NSView) -> NSPoint { v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil) }
}
#endif
