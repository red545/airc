// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import CoreGraphics
import ObjectiveC

/// Owner P0 (2026-11-05): "can't click into the browser window". Real clicks on a text field, a button and a link in a
/// page served from 127.0.0.1, and typing into the field, on both engines.
///
/// Before each click, what it would hit is logged at both levels: the window server (is our window the top one at that
/// point, or does one of our own windows lie over it?) and the view tree (the view AppKit's hit test picks, and the one
/// Chromium's page view checks in `-shouldIgnoreMouseEvent:`, which drops the click unless the window's content view
/// hit-tests into the page). The page also reports whether it is rendering (`requestAnimationFrame` ticks), since an
/// occluded or hidden Chromium page takes clicks but never paints them.
extension SnapshotRunner {
    private static let inputPage = """
        <!doctype html><title>input 0</title>
        <style>body{margin:0;font:15px -apple-system,sans-serif}.t{position:absolute;left:60px;width:220px;height:36px;box-sizing:border-box}</style>
        <input id=field class=t style="top:60px" autocomplete=off>
        <button id=button class=t style="top:130px">Press</button>
        <a id=link class=t style="top:200px" href="/next">Follow this link</a>
        <script>
        var presses=0,downs=0,frames=0;
        document.getElementById('button').addEventListener('click',function(){presses++;document.title='input '+presses});
        document.addEventListener('mousedown',function(){downs++});
        (function tick(){frames++;requestAnimationFrame(tick)})();
        </script>
        """
    private static let locateScript = """
        (function(){var o={};['field','button','link'].forEach(function(id){var r=document.getElementById(id).getBoundingClientRect();\
        o[id]=[r.left+r.width/2,r.top+r.height/2]});o.vw=innerWidth;o.vh=innerHeight;o.visibility=document.visibilityState;\
        o.frames=frames;return o})()
        """

    /// `situation` names how a person got to the page (the clickbug report's add-ons): its steps, from `interlude`, run
    /// between opening the page and the first click, e.g. a Space switch away and back, or the Command Bar.
    func pageInput(_ situation: String = "", interlude: () -> Void = {}) {
        var server: LocalPageServer?
        var tabID = ""
        var points: [String: NSPoint] = [:]
        let page = { self.c.engineTab(for: tabID) }
        let label = "page input" + (situation.isEmpty ? "" : " (\(situation))")
        func evaluate(_ script: String, _ then: @escaping (Any?) -> Void) {
            guard let p = page() else { return then(nil) }
            p.evaluate(script, completion: then)
        }
        step { [self] done in
            guard let s = LocalPageServer(pages: ["/input": Self.inputPage, "/next": "<title>next</title><p>Followed</p>"]) else {
                check(false, "\(label): the loopback server starts"); return done()
            }
            server = s
            s.start { port in
                guard let port else { self.check(false, "\(label): the loopback server starts"); return done() }
                guard let t = try? self.c.store.openTab(url: "http://127.0.0.1:\(port)/input", inSpace: self.c.currentSpaceID,
                                                        title: "Input test") else { return done() }
                tabID = t.id
                self.c.reloadAll(animated: false)
                self.c.show(t.id, focus: false)
                done()
            }
        }
        waitForPage()
        interlude()
        // Where the page's controls are on screen, and whether the page renders.
        step { [self] done in
            evaluate(Self.locateScript) { value in
                let o = value as? [String: Any] ?? [:]
                guard let view = page()?.view, !o.isEmpty else {
                    self.check(false, "\(label): the page answers (\(String(describing: value)))"); return done()
                }
                for id in ["field", "button", "link"] {
                    guard let xy = (o[id] as? [Any])?.compactMap({ ($0 as? NSNumber)?.doubleValue }), xy.count == 2 else { continue }
                    let p = NSPoint(x: xy[0], y: view.isFlipped ? xy[1] : Double(view.bounds.height) - xy[1])
                    points[id] = view.convert(p, to: nil)
                }
                let frames = (o["frames"] as? NSNumber)?.intValue ?? 0
                self.note("\(label): viewport \(o["vw"] ?? "-")×\(o["vh"] ?? "-") in a \(Int(view.bounds.width))×\(Int(view.bounds.height)) view, "
                          + "visibility \(o["visibility"] ?? "-"), window key \(self.c.window.isKeyWindow), main \(self.c.window.isMainWindow), "
                          + "app active \(NSApp.isActive), occlusion visible \(self.c.window.occlusionState.contains(.visible)), "
                          + "first responder \(Self.describe(self.c.window.firstResponder)), card empty state \(self.c.card.showsEmptyState), "
                          + "shows the test tab \(self.c.shownTabID == tabID)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    evaluate("frames") { later in
                        let n = ((later as? NSNumber)?.intValue ?? frames) - frames
                        // WebKit doesn't render a window the owner's own windows cover; Chromium does.
                        if n < 5, !self.c.window.occlusionState.contains(.visible) {
                            self.skip("\(label): the page renders (\(n) animation frames in 0.6 s): the window is covered")
                        } else {
                            self.check(n >= 5, "\(label): the page renders (\(n) animation frames in 0.6 s)")
                        }
                        done()
                    }
                }
            }
        }
        // The page's top edge lies in the window's titlebar band: a click there must reach the page, not drag the window.
        run { [self] in
            guard let view = page()?.view else { return }
            let top = view.convert(NSPoint(x: view.bounds.midX, y: view.isFlipped ? 4 : view.bounds.height - 4), to: nil)
            let frame = c.window.contentView?.superview
            let hit = frame.flatMap { $0.hitTest($0.convert(top, from: nil)) }
            let why = Self.windowServerDrags(at: top, hit: hit, in: c.window)
            check(why == nil, String(format: "\(label): a click 4 pt into the page's top (%.0f pt below the window's top) reaches the page", c.window.frame.height - top.y)
                  + (why.map { ": \($0)" } ?? ""))
        }
        // The text field: a click focuses it (the page view takes the keyboard), then typed keys land in it.
        clickInPage({ points["field"] }, "field", label, page: { page()?.view })
        step { [self] done in
            evaluate("document.activeElement && document.activeElement.id") { value in
                let focused = (value as? String) == "field"
                let responder = self.c.window.firstResponder
                let inPage = (responder as? NSView).map { v in page().map { v === $0.view || v.isDescendant(of: $0.view) } ?? false } ?? false
                self.keyCheck(focused && inPage, "\(label): a click on the text field focuses it (active element \(value ?? "none"), "
                           + "first responder \(Self.describe(responder))\(inPage ? ", in the page" : ", not in the page"))")
                done()
            }
        }
        run { [self] in typeText("hello") }
        step { [self] done in
            // The field's value is read from the page (asynchronously), so poll it until it reads "hello" or 2 s pass.
            let deadline = Date().addingTimeInterval(2)
            func poll() {
                evaluate("document.getElementById('field').value") { value in
                    if (value as? String) == "hello" || Date() > deadline {
                        self.keyCheck((value as? String) == "hello", "\(label): typing goes into the field (value “\(value ?? "-")”)")
                        done()
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
                    }
                }
            }
            poll()
        }
        // The button: a click runs its handler.
        clickInPage({ points["button"] }, "button", label, page: { page()?.view })
        step { [self] done in
            waitUntil({ page()?.title == "input 1" }, timeout: 2) {
                evaluate("downs") { downs in
                    self.keyCheck(page()?.title == "input 1",
                               "\(label): a click on the button runs its handler (title \(page()?.title ?? "-"), page saw \(downs ?? "?") mouse-downs)")
                    done()
                }
            }
        }
        // The link: a click follows it.
        clickInPage({ points["link"] }, "link", label, page: { page()?.view })
        step { [self] done in
            waitUntil({ page()?.url?.path == "/next" && page()?.isLoading == false }, timeout: 4) {
                self.keyCheck(page()?.url?.path == "/next", "\(label): a click on the link follows it (now \(page()?.url?.path ?? "-"))")
                server?.stop()
                done()
            }
        }
    }

    /// A click's effect on the page, checked only while the window is key. Scripted runs never activate the app (the
    /// build Mac is someone's laptop), and a page in an inactive window takes a click as activation only (Chromium's
    /// `acceptsFirstMouse` is NO, as in Chrome), so there it's a SKIP; the structural checks above still run. The
    /// real-click runs (the owner allows the test window key briefly) check it.
    private func keyCheck(_ ok: Bool, _ what: String) {
        if c.window.isKeyWindow || ok { check(ok, what) } else { skip(what + ": the window isn't key") }
    }

    /// Logs what a click at the window point `point()` would hit, then clicks there through the app's event queue.
    /// `FAIL` when one of our own windows lies over the point or the view under it isn't the page.
    private func clickInPage(_ point: @escaping () -> NSPoint?, _ name: String, _ label: String, page: @escaping () -> NSView?) {
        step { [self] done in
            guard let p = point(), let pageView = page() else { check(false, "\(label): the \(name) is on screen"); return done() }
            let (ok, text) = describeHit(at: p, page: pageView)
            check(ok, "\(label): the \(name) is under a click (\(text))")
            if let route = ProcessInfo.processInfo.environment["AIRC_CG_CLICKS"] {
                cgClick(at: p, in: c.window, hid: route == "hid", done)
            } else {
                click(at: p, in: c.window, done)
            }
        }
        wait(0.25)
    }

    /// Diagnosis only (`AIRC_CG_CLICKS=pid|hid`): the click as Quartz events, posted to this process (`pid`: through
    /// the window server's event queue for the app, as a person's click arrives) or to the HID system (`hid`: moves
    /// the real pointer and activates the app; needs the Accessibility permission, so never in the suite).
    private func cgClick(at p: NSPoint, in w: NSWindow, hid: Bool, _ done: @escaping () -> Void) {
        let screen = w.convertPoint(toScreen: p)
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let location = CGPoint(x: screen.x, y: top - screen.y)
        note("page input: Quartz click (\(hid ? "HID" : "to this process")) at \(location), may post: \(CGPreflightPostEventAccess())")
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .left) else { continue }
            e.setIntegerValueField(.mouseEventClickState, value: 1)
            if hid {
                e.post(tap: .cghidEventTap)
            } else {
                e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(w.windowNumber))
                e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(w.windowNumber))
                e.postToPid(getpid())
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: done)
    }

    /// Clicks the middle of the page card until the shown page has the keyboard and a user activation (at most three
    /// clicks): a window that never had a mouse-down drops posted keys, and Chromium takes a background window's
    /// first click as activating it, without passing it to the page.
    func clickIntoPage(_ done: @escaping () -> Void) {
        var clicks = 0
        func attempt() {
            guard let page = c.shownTabID.flatMap({ c.engineTab(for: $0) }) else { return done() }
            let p = c.card.convert(NSPoint(x: c.card.bounds.midX, y: c.card.bounds.midY), to: nil)
            clicks += 1
            click(at: p, in: c.window) {
                page.evaluate("navigator.userActivation ? navigator.userActivation.hasBeenActive : true") { active in
                    if (active as? Bool == true && self.c.focusedPage != nil) || clicks >= 3 {
                        self.note("clicked into the page \(clicks)×: user activation \(active ?? "-"), focused \(self.c.focusedPage != nil)")
                        done()
                    } else {
                        attempt()
                    }
                }
            }
        }
        attempt()
    }

    /// What a mouse-down at the window point `p` reaches: the top window at that screen point, AppKit's hit view and
    /// the content view's hit view (Chromium's own check).
    func describeHit(at p: NSPoint, page: NSView) -> (Bool, String) {
        let w = c.window
        var parts: [String] = []
        var ok = true
        let top = NSWindow.windowNumber(at: w.convertPoint(toScreen: p), belowWindowWithWindowNumber: 0)
        if top != w.windowNumber {
            let info = Self.windowInfo(top)
            // Another app's window over ours (the build Mac is in use) isn't the app's fault; one of ours is.
            if info.pid == getpid() { ok = false }
            parts.append("top window at the point is \(info.text), not ours")
        }
        guard let content = w.contentView, let frame = content.superview else { return (false, "no content view") }
        let q = frame.convert(p, from: nil)
        let hit = frame.hitTest(q), contentHit = content.hitTest(q)
        let inPage = { (v: NSView?) in v.map { $0 === page || $0.isDescendant(of: page) } ?? false }
        if !inPage(hit) || !inPage(contentHit) { ok = false }
        parts.append("hit \(Self.chain(hit, to: page))")
        if contentHit !== hit { parts.append("content view's hit \(Self.chain(contentHit, to: page))") }
        // A real click never reaches the app where the window server drags the window instead; posted clicks skip the
        // window server, so check its two conditions directly.
        if let why = Self.windowServerDrags(at: p, hit: hit, in: w) { ok = false; parts.append("a real click would drag the window: \(why)") }
        return (ok, parts.joined(separator: "; "))
    }

    /// Why the window server would drag the window on a real press at window point `p` instead of sending it to the
    /// app, or nil: a window movable by its background and a hit view that says it can move it; or a point in the
    /// titlebar band that no view up the hit view's chain claims (`_opaqueRectForWindowMoveWhenInTitlebar`).
    static func windowServerDrags(at p: NSPoint, hit: NSView?, in w: NSWindow) -> String? {
        guard let hit else { return nil }
        if w.isMovableByWindowBackground, hit.mouseDownCanMoveWindow {
            return "movable by its background and \(describe(hit)) answers mouseDownCanMoveWindow"
        }
        let band = w.frame.height - w.contentLayoutRect.maxY
        guard p.y > w.frame.height - band else { return nil }
        let selector = NSSelectorFromString("_opaqueRectForWindowMoveWhenInTitlebar")
        typealias Rect = @convention(c) (AnyObject, Selector) -> NSRect
        var v: NSView? = hit
        while let view = v {
            if let m = class_getInstanceMethod(type(of: view), selector) {
                let opaque = unsafeBitCast(method_getImplementation(m), to: Rect.self)(view, selector)
                if opaque.contains(view.convert(p, from: nil)) { return nil }
            }
            v = view.superview
        }
        return String(format: "%.0f pt from the top, in the %.0f pt titlebar band, and nothing claims it", w.frame.height - p.y, band)
    }

    static func describe(_ r: NSResponder?) -> String { r.map { String(describing: type(of: $0)) } ?? "none" }

    /// The view and its superviews up to `page` (or five levels), innermost first.
    static func chain(_ v: NSView?, to page: NSView) -> String {
        guard var v else { return "nothing" }
        var names = [String(describing: type(of: v)) + (v.isHidden ? " (hidden)" : "")]
        while v !== page, names.count < 6, let s = v.superview {
            v = s
            names.append(v === page ? "page" : String(describing: type(of: v)))
        }
        return names.joined(separator: " < ") + (v === page ? "" : " (not in the page)")
    }

    /// The owner, name and level of a window on screen, from the window server.
    static func windowInfo(_ number: Int) -> (pid: pid_t, text: String) {
        guard number > 0, let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]],
              let d = list.first else { return (0, "window \(number)") }
        let pid = (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
        let ours = NSApp.windows.first { $0.windowNumber == number }.map { " \(String(describing: type(of: $0)))" } ?? ""
        let text = "window \(number)\(ours) of \(d[kCGWindowOwnerName as String] ?? "?") (pid \(pid)), "
            + "“\(d[kCGWindowName as String] ?? "")”, layer \(d[kCGWindowLayer as String] ?? "?"), alpha \(d[kCGWindowAlpha as String] ?? "?")"
        return (pid, text)
    }
}
#endif
