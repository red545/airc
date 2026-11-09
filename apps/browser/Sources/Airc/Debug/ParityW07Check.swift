// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit

/// `--script parityw07` (both engines): the window drags from the top of the page (Browser/PageDrag.swift), on a
/// loopback page with a link and a field in its top strip and text below.
///   - the strip is the page's part of the title-bar band (≈ 18 pt under the 10 pt margin), the card's width; the
///     window server leaves it to the app (the strip decides), drags the window from the margin and from the
///     sidebar's empty top area, and the page below is the page's;
///   - real presses (posted to our own window, never HID): a press that moves drags the window (`performDrag` with the
///     press; the window itself isn't moved, the owner's screen stays as it is) and the page sees nothing; a click
///     goes to the page view as AppKit would send it (a window that isn't key: only to a view that takes first clicks);
///     ⌘ held, the strip stands aside; a double-click does the system's title-bar action (Zoom, Minimize, nothing);
///   - off with the setting off, the toolbar shown, or in full screen;
///   - a split: each pane's top drags too, and the pane's handle stays its own;
///   - the link followed by a click in the strip, and text selected by a drag below it, need a key window: FAIL-ENV in
///     scripted runs (the app is never activated).
extension SnapshotRunner {
    func parityW07Scenario() {
        var server: LocalPageServer?
        var base = ""
        var tab = ""
        var drags: [NSEvent] = []
        var doubles: [String] = []
        let strip = { self.c.card.dragStrip! }

        func evaluate(_ js: String, _ then: @escaping (Any?) -> Void) {
            guard let p = c.engineTab(for: tab) else { return then(nil) }
            p.evaluate(js, completion: then)
        }
        /// A window point in the strip's band, `x` from the card's left.
        func stripPoint(_ x: CGFloat, _ s: PageTopDragStrip? = nil) -> NSPoint {
            let v = s ?? strip()
            let r = v.activeRect
            return v.convert(NSPoint(x: r.minX + x, y: r.midY), to: nil)
        }
        /// Posts real presses to our own window (never HID): `clicks` presses at `p` (a moving one ends at `to`), each with
        /// its release, on a timer that also runs inside tracking loops.
        func press(_ p: @escaping () -> NSPoint, to: (() -> NSPoint)? = nil, clicks: Int = 1, mods: NSEvent.ModifierFlags = [],
                   _ done: @escaping () -> Void) {
            let w = c.window, at = p(), end = to?()
            func mouse(_ t: NSEvent.EventType, _ q: NSPoint, _ n: Int) -> NSEvent? {
                NSEvent.mouseEvent(with: t, location: q, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: n, pressure: t == .leftMouseUp ? 0 : 1)
            }
            var plan: [(Double, NSEvent.EventType, NSPoint, Int)] = []
            for k in 0..<clicks {
                let t0 = Double(k) * 0.15
                plan.append((t0, .leftMouseDown, at, k + 1))
                if let end {
                    for s in 1...6 {
                        let f = CGFloat(s) / 6
                        plan.append((t0 + 0.02 * Double(s), .leftMouseDragged, NSPoint(x: at.x + (end.x - at.x) * f, y: at.y + (end.y - at.y) * f), k + 1))
                    }
                }
                plan.append((t0 + (end == nil ? 0.06 : 0.16), .leftMouseUp, end ?? at, k + 1))
            }
            for (t, type, q, n) in plan {
                let timer = Timer(timeInterval: t, repeats: false) { _ in if let e = mouse(type, q, n) { NSApp.postEvent(e, atStart: false) } }
                RunLoop.main.add(timer, forMode: .common)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (plan.last?.0 ?? 0) + 0.4, execute: done)
        }
        func reset() {
            PageTopDragStrip.last = nil
            drags = []
            doubles = []
            evaluate("downs = 0; clicks = 0; 0") { _ in }
        }

        step { [self] done in
            let page = """
                <!doctype html><title>w07</title><style>body{margin:0;font:16px -apple-system}
                #top{position:absolute;top:0;left:0;height:40px;width:60%;display:block;background:#dfe}
                #field{position:absolute;top:2px;right:20px;width:200px;height:28px}
                #text{position:absolute;top:140px;left:40px;width:600px}</style>
                <a id=top href="/followed">The page's top bar: a link</a><input id=field value="a field in the strip">
                <p id=text>Some text below the strip to select with a drag.</p>
                <script>var downs=0,clicks=0;document.addEventListener('mousedown',function(){downs++});
                document.addEventListener('click',function(e){clicks++;if(e.target.id=='top')e.preventDefault()});</script>
                """
            server = LocalPageServer(pages: ["/w07": page, "/followed": "<!doctype html><title>followed</title>followed"])
            server?.start { port in
                if let port { base = "http://127.0.0.1:\(port)" } else { self.check(false, "parityw07: a loopback page server") }
                done()
            }
        }
        run { [self] in
            guard let t = try? c.store.openTab(url: base + "/w07", inSpace: c.currentSpaceID, title: "w07") else { return check(false, "parityw07: a tab") }
            tab = t.id
            c.reloadAll(animated: false)
            c.show(tab)
            PageTopDragStrip.dragOverride = { _, e in drags.append(e) }
            PageTopDragStrip.doubleClickOverride = { _, a in doubles.append(a) }
            PageTopDragStrip.fullScreenOverride = false
        }
        waitForPage()

        // The strip's place, and where a real press goes before the app sees it.
        run { [self] in
            let w: NSWindow = c.window
            let band = w.frame.height - w.contentLayoutRect.maxY
            let cardTop = w.frame.height - c.card.convert(c.card.bounds, to: nil).maxY
            let r = strip().convert(strip().activeRect, to: nil)
            let cardWidth = c.card.bounds.width
            check(abs(r.height - (band - cardTop)) <= 1 && r.height >= 10 && abs(r.width - cardWidth) <= 1 && abs(r.maxY - w.frame.height + cardTop) <= 1,
                  String(format: "parityw07: the strip is the page's part of the title-bar band, the card's width (%.0f pt under the %.0f pt margin, band %.0f, width %.0f of %.0f)",
                         r.height, cardTop, band, r.width, cardWidth))
            let frame = w.contentView!.superview!
            func hit(_ p: NSPoint) -> NSView? { frame.hitTest(frame.convert(p, from: nil)) }
            let inStrip = stripPoint(30)
            let margin = NSPoint(x: inStrip.x, y: w.frame.height - cardTop / 2)
            let below = c.card.convert(NSPoint(x: 60, y: c.card.bounds.height - 150), to: nil)
            // The sidebar's empty top area: its points in the band, past the traffic lights, that no button takes.
            let sb = c.sidebar.convert(c.sidebar.bounds, to: nil)
            let row = stride(from: sb.minX + 80, to: sb.maxX - 8, by: 8).map { NSPoint(x: $0, y: w.frame.height - 6) }
            let empty = row.filter { Self.windowServerDrags(at: $0, hit: hit($0), in: w) != nil }
            let stripServer = Self.windowServerDrags(at: inStrip, hit: hit(inStrip), in: w)
            let marginServer = Self.windowServerDrags(at: margin, hit: hit(margin), in: w)
            let sidebarServer: String? = empty.isEmpty ? nil : "\(empty.count) of \(row.count) points along its top"
            let page = c.engineTab(for: tab)?.view
            let belowHit = hit(below)
            let belowIsPage = belowHit.map { v in page.map { v === $0 || v.isDescendant(of: $0) } ?? false } ?? false
            check(stripServer == nil && marginServer != nil && sidebarServer != nil && belowIsPage,
                  "parityw07: a real press in the strip comes to the app (the strip decides: \(stripServer ?? "yes")); the window server drags the window "
                  + "from the margin (\(marginServer ?? "no")) and the sidebar's empty top area (\(sidebarServer ?? "no")); below the strip the page has "
                  + "the press (\(Self.describe(belowHit)))")
        }

        uiCase(window: { self.c.window }) {
            run { [self] in
                uiAttempt?.needsKeyWindow = false
                uiAttempt?.needsUncoveredWindow = false
                reset()
            }
            wait(0.2)
            // A press that moves: the window drags; the page sees nothing.
            step { done in press({ stripPoint(80) }, to: { NSPoint(x: stripPoint(80).x + 40, y: stripPoint(80).y - 6) }) { done() } }
            step { [self] done in
                evaluate("downs") { v in
                    let start = stripPoint(80)
                    let ok = drags.count == 1 && drags.first.map { abs($0.locationInWindow.x - start.x) < 1 && $0.type == .leftMouseDown } == true
                        && PageTopDragStrip.last == "drag" && (v as? Int ?? (v as? NSNumber)?.intValue) == 0
                    self.check(ok, "parityw07: a press in the strip that moves drags the window, from the press (performDrag \(drags.count)×, \(PageTopDragStrip.last ?? "-")); "
                               + "the page sees no press (\(v ?? "?"))")
                    done()
                }
            }
            // A click: to the page view, as AppKit would send it.
            run { reset() }
            step { done in press({ stripPoint(80) }) { done() } }
            step { [self] done in
                let p = stripPoint(80)
                let host = c.card.hostView
                let target = host.flatMap { $0.hitTest($0.superview!.convert(p, from: nil)) }
                let probe = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: 0, windowNumber: c.window.windowNumber,
                                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                let takesFirst = target?.acceptsFirstMouse(for: probe) == true
                let key = c.window.isKeyWindow
                evaluate("downs + ',' + clicks") { v in
                    let counts = (v as? String) ?? "?"
                    let reached = counts != "0,0"
                    let expected = key || takesFirst
                    let last = PageTopDragStrip.last ?? "-"
                    self.check(drags.isEmpty && reached == expected && last == (expected ? "click → " + Self.describe(target) : "first click only"),
                               "parityw07: a click in the strip goes to the page view as AppKit would send it (\(last); window key \(key), the view takes "
                               + "first clicks \(takesFirst); the page's mousedown, click: \(counts)), and doesn't drag (\(drags.count))")
                    done()
                }
            }
            // ⌘ held: the strip stands aside.
            run { reset() }
            step { done in press({ stripPoint(80) }, to: { NSPoint(x: stripPoint(80).x + 40, y: stripPoint(80).y) }, mods: .command) { done() } }
            run { [self] in
                check(PageTopDragStrip.last == nil && drags.isEmpty,
                      "parityw07: with ⌘ held the strip stands aside: the press is the page's (strip \(PageTopDragStrip.last ?? "not involved"), drags \(drags.count))")
            }
            // Double-click: the system's title-bar action.
            for setting in ["Maximize", "Minimize", "None", "Fill"] {
                run { reset(); PageTopDragStrip.doubleClickSetting = setting }
                step { done in press({ stripPoint(80) }, clicks: 2) { done() } }
                run { [self] in
                    check(doubles == [setting] && drags.isEmpty,
                          "parityw07: a double-click in the strip does the title-bar action \(setting) asks for (\(doubles), drags \(drags.count))")
                }
            }
            run { [self] in
                PageTopDragStrip.doubleClickSetting = nil
                note("parityw07: this Mac's title-bar double-click: \(PageTopDragStrip.doubleClickAction)")
            }
        }

        // Off: the setting, the toolbar, full screen.
        /// With `pressing`, a moving press where the strip would be shows it takes nothing (not with the toolbar shown: the
        /// press would land on the toolbar).
        func standsAside(_ what: String, pressing: Bool = true, _ set: @escaping () -> Void, _ unset: @escaping () -> Void) {
            run { set(); reset() }
            wait(0.3)
            if pressing {
                step { done in press({ NSPoint(x: self.c.card.convert(NSPoint(x: 80, y: 0), to: nil).x, y: self.c.window.frame.height - 14) },
                                     to: { NSPoint(x: self.c.card.convert(NSPoint(x: 120, y: 0), to: nil).x, y: self.c.window.frame.height - 14) }) { done() } }
            }
            run { [self] in
                check(strip().activeRect.isEmpty && PageTopDragStrip.last == nil && drags.isEmpty,
                      "parityw07: \(what): the strip is off (rect \(NSStringFromRect(strip().activeRect)), \(PageTopDragStrip.last ?? "not involved"))")
                unset()
            }
            wait(0.3)
        }
        standsAside("with the setting off (Arc's “Allow window dragging from the top of webpages”)",
                    { self.app?.settings.values.dragsWindowFromPageTop = false }, { self.app?.settings.values.dragsWindowFromPageTop = true })
        standsAside("with the toolbar shown", pressing: false, { self.c.togglePageToolbar() }, { self.c.togglePageToolbar() })
        standsAside("in full screen", { PageTopDragStrip.fullScreenOverride = true }, { PageTopDragStrip.fullScreenOverride = false })

        // A split: each pane's top drags; the handle stays the pane's.
        var panes: [String] = []
        run { [self] in
            let sid = c.currentSpaceID
            guard let other = try? c.store.openTab(url: base + "/w07?pane", inSpace: sid, activate: false, title: "w07 pane"),
                  let x = try? c.store.createSplit([tab, other.id], inSpace: sid, focused: tab) else { return check(false, "parityw07: a split") }
            panes = x.tabIDs
            c.reloadAll(animated: false)
            c.show(tab)
        }
        step { [self] done in waitUntil({ self.c.splitContainer.panes.count == 2 && !self.c.animator.isRunning("split") }, timeout: 8) { done() } }
        uiCase(window: { self.c.window }) {
            run { [self] in
                uiAttempt?.needsKeyWindow = false
                uiAttempt?.needsUncoveredWindow = false
                reset()
            }
            step { [self] done in
                guard let pane = c.splitContainer.pane(for: panes[1]), let s = pane.dragStrip else { check(false, "parityw07: the second pane"); return done() }
                // The handle shows as the pointer comes near the top (posted moves don't reach tracking areas).
                let h = pane.handle
                h.setShown(true)
                let grab = h.convert(NSPoint(x: h.grabRect.midX, y: h.grabRect.midY), to: nil)
                let frame = c.window.contentView!.superview!
                let atGrab = frame.hitTest(frame.convert(grab, from: nil))
                h.setShown(false)
                check(!s.activeRect.isEmpty && atGrab === h,
                      "parityw07: a split pane has the strip too (\(NSStringFromRect(s.activeRect))), and its handle stays its own (\(Self.describe(atGrab)))")
                press({ stripPoint(40, s) }, to: { NSPoint(x: stripPoint(40, s).x + 30, y: stripPoint(40, s).y) }) { done() }
            }
            run { [self] in
                check(drags.count == 1 && PageTopDragStrip.last == "drag", "parityw07: a press that moves in the second pane's strip drags the window (\(drags.count)×)")
            }
        }
        run { [self] in
            if let x = c.store.split(containing: tab) { try? c.store.separateSplit(x.id) }
            c.show(tab)
        }
        waitForPage()

        // What needs a key window: a click in the strip following the link, and text selected by a drag below it.
        uiCase(window: { self.c.window }) {
            run { [self] in
                uiAttempt?.needsKeyWindow = true
                uiAttempt?.needsUncoveredWindow = true
                uiAttempt?.point = stripPoint(30)
                reset()
            }
            step { done in press({ stripPoint(30) }) { done() } }
            step { [self] done in
                evaluate("clicks") { v in
                    self.check((v as? Int ?? (v as? NSNumber)?.intValue ?? 0) >= 1,
                               "parityw07: a click on the link in the strip reaches it in a key window (clicks \(v ?? "?"))")
                    done()
                }
            }
            step { done in
                let a = self.c.card.convert(NSPoint(x: 42, y: self.c.card.bounds.height - 150), to: nil)
                press({ a }, to: { NSPoint(x: a.x + 160, y: a.y) }) { done() }
            }
            step { [self] done in
                evaluate("String(window.getSelection())") { v in
                    let s = (v as? String) ?? ""
                    self.check(s.count >= 5 && PageTopDragStrip.last == nil,
                               "parityw07: a drag below the strip selects the page's text, the strip not involved (“\(s)”)")
                    done()
                }
            }
        }
        run {
            PageTopDragStrip.dragOverride = nil
            PageTopDragStrip.doubleClickOverride = nil
            PageTopDragStrip.doubleClickSetting = nil
            PageTopDragStrip.fullScreenOverride = nil
            server?.stop()
        }
    }
}
#endif
