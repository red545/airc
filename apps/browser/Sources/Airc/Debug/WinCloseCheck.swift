// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircDesign
import AircKit

/// `--script winclose` (both engines; a dedicated UI session under the UI lock, `AIRC_UI_DEDICATED_SESSION=1`,
/// `AIRC_REAL_KEYS=1`, `AIRC_REAL_CLICKS=1`, `AIRC_LA_AS_OWNER=1`): every window kind can be closed the Arc way (WIN-8),
/// with **real** drags, pointer moves, clicks and keys from the build Mac's stable UI driver:
///   1. a tab dragged out of the sidebar: its new window's traffic lights show at (20,24), are what a click there hits
///      (no view or window over them), the Window menu lists the window and File has Close Window ⇧⌘W; a real click
///      on its close button closes it, and the tab stays in the sidebar;
///   2. the same with its sidebar hidden (real ⌘S): no lights at rest; the revealed sidebar shows them once it's at
///      rest, 5 pt in; the pointer at the top-left shows them; a real click there closes the window;
///   3. Move to New Window, then real ⇧⌘W closes it;
///   4. real ⌘W on a window's last tab closes the window (the tab goes to the Archive);
///   5. real ⌘W in an empty window (⌘N on a Space without tabs) closes it;
///   6. a private window and a Little Airc window: lights hit-testable, a real click closes each;
///   7. the last window: real ⌘W on its last tab shows the empty state and the window stays, and so does a second ⌘W.
/// `winclose-write` / `winclose-read` (same data folder, no --ephemeral): a moved-out window with its sidebar hidden
/// comes back after a relaunch with no lights at rest; the pointer at its top-left shows them and a real click closes it.
extension SnapshotRunner {
    private final class WinCloseState {
        var server: LocalPageServer?
        var base = ""
        var tabs: [String: String] = [:]
        var real = false
        var home = NSRect.zero
        var drops: [NSPoint] = []
        weak var w: WindowController?
        /// The first window (`c` follows the window used last, which a drag-out changes).
        weak var source: WindowController?
    }

    private var winCloseTag: String { "winclose \(app?.engine is WebKitEngine ? "webkit" : "chromium")" }

    // MARK: Helpers

    private func winCloseReal() -> Bool {
        UIDriverClient.requested && ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1"
            && FileManager.default.isExecutableFile(atPath: UIDriverClient.path)
    }

    private func wcScreenTop() -> CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }
    private func wcN(_ v: CGFloat) -> String { String(format: "%.1f", v) }

    /// `window` key, in front, on the active Space (FAIL-ENV otherwise).
    private func wcFront(_ window: NSWindow, _ done: @escaping (Bool) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        waitUntil({ NSApp.isActive && window.isKeyWindow && window.isOnActiveSpace }, timeout: 3) {
            let ok = NSApp.isActive && window.isKeyWindow && window.isOnActiveSpace
            if !ok {
                self.note("FAIL-ENV \(self.winCloseTag): window not key/active (active=\(NSApp.isActive), key=\(window.isKeyWindow), "
                          + "space=\(window.isOnActiveSpace), locked=\(Self.screenLocked))")
            }
            done(ok)
        }
    }

    /// The close button's centre in window coordinates, whether it's visible, and whether a click there reaches it:
    /// the frame view's hit test lands on it (nothing of ours over it) and no other window is above that point.
    private func wcLights(_ window: NSWindow) -> (center: NSPoint, visible: Bool, hit: Bool, desc: String) {
        guard let b = window.standardWindowButton(.closeButton), let frameView = window.contentView?.superview else {
            return (.zero, false, false, "no close button")
        }
        let p = b.convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), to: nil)
        let visible = !b.isHiddenOrHasHiddenAncestor && b.window === window && b.alphaValue > 0.5
        let v = frameView.hitTest(p)
        let onButton = v.map { sequence(first: $0, next: { $0.superview }).contains { $0 === b } } ?? false
        let screen = window.convertPoint(toScreen: p)
        let top = NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0)
        let desc = "centre (\(wcN(p.x)),\(wcN(window.frame.height - p.y))) from the top-left, visible \(visible), "
            + "hits \(v.map { String(describing: type(of: $0)) } ?? "nothing"), top window \(top == window.windowNumber ? "ours" : wcDescribe(top))"
        return (p, visible, visible && onButton && top == window.windowNumber, desc)
    }

    /// Which window a window number is: one of ours (class, title, level, frame) or another app's.
    private func wcDescribe(_ number: Int) -> String {
        if let w = NSApp.window(withWindowNumber: number) {
            return "\(number) ours: \(type(of: w)) '\(w.title)' level \(w.level.rawValue) \(NSStringFromRect(w.frame))"
        }
        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]]
        let owner = list?.first?[kCGWindowOwnerName as String] as? String ?? "?"
        let layer = list?.first?[kCGWindowLayer as String] as? Int ?? -1
        return "\(number) of \(owner) layer \(layer)"
    }

    /// A real click on `window`'s close button (after a real move onto it, which also shows hidden lights); `done(closed)`.
    private func wcRealClose(_ window: NSWindow, what: String, inset: CGFloat = 0,
                             centre: CGPoint = AircMetrics.Window.trafficLightCenters[0], _ done: @escaping (Bool) -> Void) {
        let tag = winCloseTag
        wcFront(window) { ok in
            guard ok else { return done(false) }
            let target = NSPoint(x: centre.x + inset, y: window.frame.height - centre.y - inset)
            UIDriverClient.move(target, in: window) { moved, out in
                if !moved { self.note("FAIL-ENV \(tag): the driver refused the move (\(out))"); return done(false) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let l = self.wcLights(window)
                    let expectX = centre.x + inset, expectY = centre.y + inset
                    let placed = abs(l.center.x - expectX) <= 1.5 && abs(window.frame.height - l.center.y - expectY) <= 1.5
                    self.check(l.hit && placed, "\(tag): \(what): the close button is visible and hit-testable at "
                               + "(\(Int(expectX)),\(Int(expectY))) (\(l.desc))")
                    guard l.hit else { return done(false) }
                    let s = window.convertPoint(toScreen: l.center)
                    UIDriverClient.run(["--click", self.wcN(s.x), self.wcN(self.wcScreenTop() - s.y)]) { clicked, out in
                        if !clicked { self.note("FAIL-ENV \(tag): the driver refused the click (\(out))") }
                        self.waitUntil({ !window.isVisible }, timeout: 4) {
                            self.check(!window.isVisible, "\(tag): \(what): a real click on the close button closes the window")
                            done(!window.isVisible)
                        }
                    }
                }
            }
        }
    }

    private func wcPress(_ combo: String, _ done: @escaping (Bool) -> Void) {
        UIDriverClient.press([combo], pid: ProcessInfo.processInfo.processIdentifier) { ok, out in
            if !ok { self.note("FAIL-ENV \(self.winCloseTag): the driver refused \(combo) (\(out))") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { done(ok) }
        }
    }

    private func wcSetUp(_ s: WinCloseState, paths: [String]) {
        step { [self] done in
            s.server = LocalPageServer(pages: [:])
            s.server?.handler = { path in
                LocalPageServer.Page(headers: ["Cache-Control": "no-store", "Content-Type": "text/html"],
                                     body: "<!doctype html><title>winclose \(path)</title><body style='font:24px -apple-system;padding:60px'>\(path)")
            }
            s.server?.start { port in
                if let port { s.base = "http://127.0.0.1:\(port)" } else { self.check(false, "\(self.winCloseTag): a loopback page server") }
                done()
            }
        }
        run { [self] in
            s.real = winCloseReal()
            s.source = c
            if !s.real { note("FAIL-ENV \(winCloseTag): real input needs AIRC_UI_DEDICATED_SESSION=1, AIRC_REAL_KEYS=1 and the stable UI driver") }
            let sid = c.currentSpaceID
            for p in paths {
                if let t = try? c.store.openTab(url: s.base + "/winclose-" + p, inSpace: sid, activate: false, title: "winclose " + p) { s.tabs[p] = t.id }
            }
            c.reloadAll(animated: false)
            guard let main = NSScreen.screens.first else { return }
            let v = main.visibleFrame
            let width = min(620, (v.width - 160) / 2.3), height = min(560, v.height - 160)
            s.home = NSRect(x: v.minX + 20, y: v.minY + (v.height - height) / 2, width: width, height: height)
            c.window.setFrame(s.home, display: true)
            s.drops = [NSPoint(x: s.home.maxX + 220, y: v.midY + 40)]
            note("\(winCloseTag): screen=\(NSStringFromRect(main.frame)) visible=\(NSStringFromRect(v)) source=\(NSStringFromRect(s.home)) real=\(s.real)")
        }
    }

    /// A real drag of `id`'s row from the source window to the desktop; `done(new window)`.
    private func wcDragOut(_ s: WinCloseState, _ id: String, _ done: @escaping (WindowController?) -> Void) {
        guard let source = s.source else { return done(nil) }
        let tag = winCloseTag
        if source.store.tab(id)?.isToday == true { _ = try? source.store.move(.tab(id), to: .today(spaceID: source.currentSpaceID, index: 0)) }
        source.window.setFrame(s.home, display: true)
        // Shown first and given time to settle (rows animate to their new places), as parityw10drag's mark() does.
        source.show(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.wcFront(source.window) { ok in
            guard ok, let page = source.pageView(for: source.currentSpaceID) else { return done(nil) }
            page.layoutSubtreeIfNeeded()
            guard let r = page.rows[id] else { self.check(false, "\(tag): the row to drag"); return done(nil) }
            let press = r.convert(NSPoint(x: r.bounds.midX, y: r.bounds.midY), to: nil)
            let frameView = source.window.contentView?.superview
            let hit = frameView?.hitTest(press)
            guard let hit, sequence(first: hit, next: { $0.superview }).contains(where: { $0 is SidebarRowView }) else {
                self.check(false, "\(tag): the press at \(NSStringFromPoint(press)) is on a sidebar row")
                return done(nil)
            }
            let before = self.app?.controllers ?? []
            let a = source.window.convertPoint(toScreen: press), e = s.drops[0]
            UIDriverClient.run(["--drag", self.wcN(a.x), self.wcN(self.wcScreenTop() - a.y), self.wcN(e.x), self.wcN(self.wcScreenTop() - e.y)]) { ok, out in
                if !ok { self.note("FAIL-ENV \(tag): the driver refused the drag (\(out))") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    let made = (self.app?.controllers ?? []).filter { w in !before.contains { $0 === w } }
                    self.check(made.count == 1 && made.first?.shownTabID == id,
                               "\(tag): a real drag out of the sidebar opens one window showing the tab (\(made.count), shows "
                               + "\(made.first?.shownTabID.flatMap { source.store.tab($0)?.url } ?? "-"), dragged \(source.store.tab(id)?.url ?? "-"))")
                    done(made.count == 1 ? made.first : nil)
                }
            }
        } }
    }

    // MARK: --script winclose

    func winCloseScenario() {
        let s = WinCloseState()
        let tag = winCloseTag
        wcSetUp(s, paths: ["a", "b", "c", "d", "e", "f"])
        wait(1.5)

        // 1. Drag-out → lights hit-testable, Window menu, File › Close Window, real click closes.
        step { [self] done in
            guard s.real, let src = s.source, let id = s.tabs["a"] else { return done() }
            wcDragOut(s, id) { w in
                guard let w else { return done() }
                self.wcFront(w.window) { _ in
                    let l = self.wcLights(w.window)
                    self.check(l.hit, "\(tag): dragged-out window: the traffic lights are visible and hit-testable (\(l.desc))")
                    let listed = NSApp.windowsMenu?.items.contains { ($0.target as AnyObject?) === w.window } == true
                    self.check(listed, "\(tag): dragged-out window: the Window menu lists it (\(w.window.title))")
                    let close = NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu?.items.first { $0.title == "Close Window" }
                    let shiftW = close.map { item -> Bool in
                        let mods = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
                        return (item.keyEquivalent == "w" && mods == [.command, .shift]) || (item.keyEquivalent == "W" && mods == .command)
                    } ?? false
                    self.check(shiftW,
                               "\(tag): File › Close Window is ⇧⌘W (\(close.map { "\($0.keyEquivalentModifierMask.rawValue) \($0.keyEquivalent)" } ?? "missing"))")
                    self.wcRealClose(w.window, what: "dragged-out window") { _ in
                        self.check(src.window.isVisible && src.store.tab(id) != nil,
                                   "\(tag): dragged-out window: the source stays and the tab stays in the sidebar")
                        done()
                    }
                }
            }
        }
        wait(0.8)

        // 2. Sidebar hidden in the dragged-out window.
        step { [self] done in
            guard s.real, let src = s.source, let id = s.tabs["b"] else { return done() }
            wcDragOut(s, id) { w in
                guard let w else { return done() }
                s.w = w
                self.wcFront(w.window) { ok in
                    guard ok else { return done() }
                    self.wcPress("cmd+s") { _ in
                        self.waitUntil({ w.sidebarHidden && w.sidebarFraction <= 0.001 }, timeout: 2) {
                            // The pointer onto the page, away from the top-left.
                            UIDriverClient.move(NSPoint(x: w.window.frame.width / 2, y: w.window.frame.height / 2), in: w.window) { _, _ in
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                    self.check(w.sidebarHidden && !self.wcLights(w.window).visible,
                                               "\(tag): sidebar hidden (real ⌘S): no traffic lights at rest (\(self.wcLights(w.window).desc))")
                                    done()
                                }
                            }
                        }
                    }
                }
            }
        }
        step { [self] done in
            guard s.real, let w = s.w, let r = w.revealController else { return done() }
            r.reveal()
            waitUntil({ r.isAtRest }, timeout: 2) {
                let l = self.wcLights(w.window)
                let inset = AircMetrics.Sidebar.floatingInset
                self.check(r.isAtRest && l.hit && abs(l.center.x - (20 + inset)) <= 1.5,
                           "\(tag): sidebar hidden: the revealed sidebar shows the traffic lights at rest, \(Int(inset)) pt in (\(l.desc))")
                r.hide()
                self.waitUntil({ !r.isRevealed }, timeout: 2) {
                    self.check(!self.wcLights(w.window).visible, "\(tag): sidebar hidden: they go with the revealed sidebar")
                    done()
                }
            }
        }
        step { [self] done in
            guard s.real, let w = s.w else { return done() }
            wcRealClose(w.window, what: "sidebar-hidden window (pointer at the top-left)", inset: AircMetrics.Sidebar.floatingInset) { _ in done() }
        }
        wait(0.8)

        // 3. Move to New Window, then real ⇧⌘W.
        step { [self] done in
            guard s.real, let src = s.source, let id = s.tabs["c"] else { return done() }
            wcFront(src.window) { ok in
                guard ok, let w = src.openInNewWindow(id) else { return done() }
                // As the person sees it: 1 s after Move to New Window, without the check bringing anything forward.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let order = NSApp.orderedWindows.filter { $0.isVisible }.prefix(3).map { "'\($0.title)'" }.joined(separator: ", ")
                let l = self.wcLights(w.window)
                self.check(l.hit && w.window.isKeyWindow,
                           "\(tag): Move to New Window: the new window is key and in front, its traffic lights hit-testable "
                           + "(key \(w.window.isKeyWindow), order \(order); \(l.desc))")
                self.wcPress("cmd+shift+w") { _ in
                    self.waitUntil({ !w.window.isVisible }, timeout: 3) {
                        self.check(!w.window.isVisible && src.window.isVisible, "\(tag): real ⇧⌘W closes the moved-out window, the source stays")
                        done()
                    }
                }
            } }
        }
        wait(0.8)

        // 4. Real ⌘W on a window's last tab.
        step { [self] done in
            guard s.real, let src = s.source, let app else { return done() }
            let store = src.store
            guard let solo = try? store.createSpace(name: "Solo", profileID: store.selectedSpace.profileID, after: src.currentSpaceID),
                  let t = try? store.openTab(url: s.base + "/winclose-solo", inSpace: solo.id, activate: false, title: "winclose solo"),
                  let w = app.openNewWindow(from: src, spaceID: solo.id, tab: .id(t.id), commandBar: false) else {
                check(false, "\(tag): a window on a Space with one tab")
                return done()
            }
            wcFront(w.window) { ok in
                guard ok else { return done() }
                self.check(w.shownTabID == t.id, "\(tag): ⌘W case: the window shows its Space's only tab")
                self.wcPress("cmd+w") { _ in
                    self.waitUntil({ !w.window.isVisible }, timeout: 4) {
                        self.check(!w.window.isVisible && store.tab(t.id) == nil && src.window.isVisible,
                                   "\(tag): real ⌘W on the window's last tab closes the tab and the window (visible \(w.window.isVisible), "
                                   + "tab \(store.tab(t.id) == nil ? "archived" : "still there"))")
                        done()
                    }
                }
            }
        }
        wait(0.8)

        // 5. Real ⌘W in an empty window.
        step { [self] done in
            guard s.real, let src = s.source, let app else { return done() }
            let store = src.store
            guard let empty = try? store.createSpace(name: "Empty", profileID: store.selectedSpace.profileID, after: src.currentSpaceID),
                  let w = app.openNewWindow(from: src, spaceID: empty.id, tab: .none, commandBar: false) else {
                check(false, "\(tag): a window on a Space without tabs")
                return done()
            }
            wcFront(w.window) { ok in
                guard ok else { return done() }
                self.check(w.shownTabID == nil, "\(tag): empty window: nothing shown")
                self.wcPress("cmd+w") { _ in
                    self.waitUntil({ !w.window.isVisible }, timeout: 3) {
                        self.check(!w.window.isVisible && src.window.isVisible, "\(tag): real ⌘W in an empty window closes it")
                        done()
                    }
                }
            }
        }
        wait(0.8)

        // 6. Private and Little Airc windows.
        step { [self] done in
            guard s.real, let app else { return done() }
            PrivateBrowsing.shared.open(app: app) { p in
                guard let p else { self.check(false, "\(tag): a private window opens"); return done() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.wcRealClose(p.window, what: "private window") { _ in done() }
                }
            }
        }
        wait(0.8)
        step { [self] done in
            guard s.real, let app, let l = app.openLittleArc(url: URL(string: s.base + "/winclose-little")) else { return done() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.wcRealClose(l.window, what: "Little Airc window", centre: AircMetrics.LittleArc.trafficLightCenters[0]) { _ in done() }
            }
        }
        wait(0.8)

        // 7. The last window: ⌘W on its last tab shows the empty state; the window stays.
        step { [self] done in
            guard s.real, let src = s.source, let app else { return done() }
            for w in app.controllers where w !== src { w.window.performClose(nil) }
            let store = src.store
            guard let last = try? store.createSpace(name: "Last", profileID: store.selectedSpace.profileID, after: src.currentSpaceID),
                  let t = try? store.openTab(url: s.base + "/winclose-last", inSpace: last.id, activate: false, title: "winclose last") else {
                check(false, "\(tag): a Space with one tab for the last window")
                return done()
            }
            src.switchToSpace(last.id, animated: false)
            src.show(t.id, focus: false)
            waitUntil({ app.controllers.count == 1 }, timeout: 4) { self.wcFront(src.window) { ok in
                guard ok else { return done() }
                self.check(app.controllers.count == 1, "\(tag): last window: it is the only browser window (\(app.controllers.count))")
                self.wcPress("cmd+w") { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.check(src.window.isVisible && store.tab(t.id) == nil,
                                   "\(tag): last window: real ⌘W on its last tab closes the tab and the window stays "
                                   + "(shows \(src.shownTabID.map { src.store.tab($0)?.title ?? $0 } ?? "the empty state"))")
                        self.wcPress("cmd+w") { _ in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                self.check(src.window.isVisible, "\(tag): last window: a second ⌘W leaves it open")
                                done()
                            }
                        }
                    }
                }
            } }
        }
        run { s.server?.stop() }
    }

    // MARK: --script winclose-write / winclose-read

    func winCloseWrite() {
        let s = WinCloseState()
        let tag = "winclose-write"
        wcSetUp(s, paths: ["r", "q"])
        wait(1.0)
        step { [self] done in
            guard let id = s.tabs["r"], let w = s.source?.openInNewWindow(id) else { check(false, "\(tag): Move to New Window"); return done() }
            if let main = NSScreen.screens.first {
                let v = main.visibleFrame
                w.window.setFrame(NSRect(x: s.home.maxX + 140, y: v.minY + 120, width: 640, height: 480), display: true)
            }
            w.toggleSidebar()
            waitUntil({ w.sidebarHidden && w.sidebarFraction <= 0.001 }, timeout: 2) {
                self.check(self.app?.controllers.count == 2 && w.sidebarHidden, "\(tag): two windows, the moved-out one with its sidebar hidden")
                self.app?.scheduleSessionSave()
                done()
            }
        }
        wait(1.5)
        run { s.server?.stop() }
    }

    func winCloseRead() {
        let tag = "winclose-read"
        var w: WindowController?
        step { [self] done in
            waitUntil({ (self.app?.controllers.count ?? 0) >= 2 }, timeout: 10) {
                let all = self.app?.controllers ?? []
                w = all.first { win in
                    win.sidebarHidden && (win.shownTabID.flatMap { win.store.tab($0)?.url.hasSuffix("/winclose-r") } ?? false)
                }
                self.check(all.count == 2 && w != nil,
                           "\(tag): both windows come back, the moved-out one with its sidebar hidden and its tab (\(all.count))")
                done()
            }
        }
        step { [self] done in
            guard let w else { return done() }
            guard winCloseReal() else { note("FAIL-ENV \(tag): real input needs the stable UI driver"); return done() }
            wcFront(w.window) { ok in
                guard ok else { return done() }
                UIDriverClient.move(NSPoint(x: w.window.frame.width / 2, y: w.window.frame.height / 2), in: w.window) { _, _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        self.check(!self.wcLights(w.window).visible, "\(tag): no traffic lights at rest after the relaunch")
                        self.wcRealClose(w.window, what: "restored sidebar-hidden window", inset: AircMetrics.Sidebar.floatingInset) { _ in
                            let rest = self.app?.controllers ?? []
                            self.check(rest.count == 1 && rest.first?.window.isVisible == true, "\(tag): the other window stays")
                            done()
                        }
                    }
                }
            }
        }
    }
}
#endif
