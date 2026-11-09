// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircDesign
import AircKit

/// `--script sidebarright` (WIN-5, Browser/SidebarSide.swift), both engines, on loopback pages. In both positions, at
/// the default, minimum and maximum widths: the sidebar, the page card, the resize handle on the inner edge, the header
/// toggle, the traffic lights (at the window's top left either way), the tab preview card beside the sidebar, the
/// drop zones that page to the neighbouring Space, the ⌘L bar over the URL field, the Library and its back
/// button on the footer's Library button, and the downloads card and update question above the footer. Then ⌘S with
/// the sidebar on the right (it slides off to the right, the reveal strip is the right edge, the floating sidebar comes
/// in from there, a drag on the inner edge resizes), and the setting changing live across two windows (a third opened
/// on the right comes up on the right). Ends on the left, as it started.
extension SnapshotRunner {
    func sidebarRightScenario() {
        var server: LocalPageServer?
        var tabs: [String] = []
        let fake = FakeReadyUpdate(version: "1.0 (209901010002)")
        let i = AircMetrics.Window.cardInset
        func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 0.5 }
        func r(_ f: NSRect) -> String { String(format: "(%.0f, %.0f, %.0f × %.0f)", f.minX, f.minY, f.width, f.height) }
        func page(_ name: String, _ hex: String) -> String {
            "<!doctype html><title>\(name)</title><style>html,body{margin:0;height:100%;background:\(hex)}"
                + "h1{margin:0;padding:56px;font:600 52px -apple-system,sans-serif;color:#fff}</style><h1>\(name)</h1>"
        }
        func rows(_ w: WindowController) -> [TabRowView] {
            guard let p = w.pageView(for: w.currentSpaceID) else { return [] }
            p.layoutSubtreeIfNeeded()
            return p.list.subviews.compactMap { $0 as? TabRowView }
        }
        func lightCenters(_ w: NSWindow) -> [CGPoint] {
            [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { w.standardWindowButton($0) }.map { b in
                let f = b.convert(b.bounds, to: nil)
                return CGPoint(x: f.midX, y: w.frame.height - f.midY)
            }
        }
        func setRight(_ onRight: Bool) {
            app?.setSidebarOnRight(onRight)
            for w in app?.controllers ?? [] { w.root.layoutSubtreeIfNeeded() }
        }

        /// The docked layout of window `w`, the sidebar on `onRight`'s side, `label` for the log.
        func docked(_ w: WindowController, onRight: Bool, _ label: String) {
            w.layoutRoot()
            w.root.layoutSubtreeIfNeeded()
            let b = w.root.bounds, s = w.sidebarWidth
            let side = w.sidebar.frame, card = w.card.frame, handle = w.resizeHandle.frame
            let sideOK = onRight ? close(side.minX, b.width - s) && close(side.maxX, b.width) : close(side.minX, 0) && close(side.maxX, s)
            let cardOK = onRight ? close(card.minX, i) && close(card.maxX, b.width - s) : close(card.minX, s) && close(card.maxX, b.width - i)
            check(w.sidebarOnRight == onRight && sideOK && cardOK && close(card.minY, i) && close(card.maxY, b.height - i)
                  && close(side.width, s) && close(side.height, b.height),
                  "sidebarright \(label): sidebar \(r(side)), page card \(r(card)) in \(Int(b.width)) × \(Int(b.height)) (inset \(Int(i)) away from the sidebar)")
            let inner = onRight ? side.minX : side.maxX
            check(close(handle.midX, inner) && !w.resizeHandle.isHidden,
                  "sidebarright \(label): the resize handle is on the sidebar's inner edge (handle \(r(handle)), edge x \(Int(inner)))")
            let t = w.sidebar.header.toggle
            let want = onRight ? DesignGaps.toggleXFullscreen : AircMetrics.Sidebar.toggleX
            check(close(t.frame.minX, want) && t.symbol == (onRight ? "sidebar.right" : "sidebar.left"),
                  "sidebarright \(label): the header toggle at x \(Int(t.frame.minX)) (\(Int(want))), \(t.symbol)")
            let lights = lightCenters(w.window), arc = AircMetrics.Window.trafficLightCenters
            let at = lights.count == 3 && zip(lights, arc).allSatisfy { close($0.x, $1.x) && close($0.y, $1.y) }
            let shown = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].allSatisfy { w.window.standardWindowButton($0)?.isHidden == false }
            // Over the sidebar on the left, over the page on the right (Arc's top-left corner either way).
            let over = lights.allSatisfy { p in (onRight ? card : side).contains(NSPoint(x: p.x, y: p.y)) }
            check(at && shown && over, "sidebarright \(label): the traffic lights at the window's top left, over the "
                  + (onRight ? "page" : "sidebar") + ": " + lights.map { String(format: "(%.0f, %.0f)", $0.x, $0.y) }.joined(separator: " "))
            // The tab preview card: beside the sidebar, on the page's side, inside the window.
            if let row = rows(w).first {
                let f = TabPreviewController.frame(beside: row, in: w).insetBy(dx: TabPreviewCardView.margin, dy: TabPreviewCardView.margin)
                let beside = onRight ? close(f.maxX, side.minX - TabPreviewController.gap) || close(f.minX, 8)
                    : close(f.minX, side.maxX + TabPreviewController.gap) || close(f.maxX, b.width - 8)
                check(beside && b.contains(f), "sidebarright \(label): the tab preview card \(r(f)) opens to the "
                      + (onRight ? "left" : "right") + " of the sidebar")
            } else {
                check(false, "sidebarright \(label): a tab row for the preview")
            }
            // Dragging a tab: the outer edge pages on, the inner edge back or on, and a bit over the page too.
            let ew = SpacePageView.edgeWidth
            let outer = onRight ? side.maxX - 2 : side.minX + 2
            let innerIn = onRight ? side.minX + 2 : side.maxX - 2
            let innerOut = onRight ? side.minX - ew : side.maxX + ew
            let deep = onRight ? side.minX - 4 * ew : side.maxX + 4 * ew
            let mid = side.midX
            let zones = [outer, innerIn, innerOut, deep, mid].map { SpacePageView.edgeSide(at: $0, sidebar: side, onRight: onRight) }
            let want3 = onRight ? [1, -1, -1, 0, 0] : [-1, 1, 1, 0, 0]
            check(zones == want3, "sidebarright \(label): drag edges (outer, inner, just over the page, deep in the page, middle) "
                  + "page by \(zones) (\(want3)): left is the previous Space, right the next")
            // ⌘L: the bar over the URL field, growing over the page.
            w.openCommandBar(mode: .editURL)
            if let bar = w.commandBar {
                w.root.layoutSubtreeIfNeeded()
                let p = bar.panelRect
                let anchored = onRight ? close(p.maxX, side.maxX - AircMetrics.Sidebar.inset) : close(p.minX, side.minX + AircMetrics.Sidebar.inset)
                check(anchored && b.contains(p), "sidebarright \(label): ⌘L's bar \(r(p)) starts at the URL field's "
                      + (onRight ? "right" : "left") + " edge and stays in the window")
            } else {
                check(false, "sidebarright \(label): ⌘L opens the bar")
            }
            w.closeCommandBar()
        }

        step { [self] done in
            let pages = Dictionary(uniqueKeysWithValues: [("a", "Coral", "#e0644f"), ("b", "Lagoon", "#2f8fa6"), ("c", "Moss", "#5f8f4e")].map {
                ("/\($0.0).html", page($0.1, $0.2))
            })
            server = LocalPageServer(pages: pages)
            server?.start { port in
                guard let port else { self.check(false, "sidebarright: the loopback page server starts"); return self.finish() }
                let store = self.c.store
                setRight(false)
                let home = store.selectedSpace.id
                try? store.updateSpace(home) { $0.name = "Home" }
                _ = try? store.createSpace(name: "Work", icon: .emoji("💼"), theme: DesignTheme.preset("sky")!.model,
                                           profileID: store.selectedSpace.profileID, after: home)
                for n in ["a", "b", "c"] {
                    if let t = try? store.openTab(url: "http://127.0.0.1:\(port)/\(n).html", inSpace: home) { tabs.append(t.id) }
                }
                self.c.switchToSpace(home, animated: false)
                if let first = tabs.first { self.c.show(first, focus: false) }
                done()
            }
        }
        waitForPage()
        wait(0.3)

        // 1. Both positions at the default, minimum and maximum widths.
        for (name, width) in [("default", AircMetrics.Sidebar.defaultWidth), ("min", AircMetrics.Sidebar.minWidth), ("max", AircMetrics.Sidebar.maxWidth)] {
            for onRight in [false, true] {
                let label = "\(onRight ? "right" : "left"), \(name) width"
                run { [self] in
                    setRight(onRight)
                    c.setSidebarWidth(width)
                    docked(c, onRight: onRight, label)
                }
                wait(0.3)   // the side's cross-fade
                capture("sidebarright-\(onRight ? "right" : "left")-\(name)")
            }
        }
        run { [self] in c.setSidebarWidth(AircMetrics.Sidebar.defaultWidth); setRight(true) }

        // 2. The footer on the right: the update pill, the downloads card above it, the Library's back button.
        run { [self] in
            UpdateCenter.shared.setReady(fake)
            MediaLibrary.shared.showDownloadCardForTesting(count: 1)
        }
        step { [self] done in
            let u = c.sidebar.update
            let full = UpdateButtonView.topInset + UpdateButtonView.pillHeight + UpdateButtonView.bottomInset
            waitUntil({ u.isShowing && abs(u.height - full) < 0.5 && MediaLibrary.shared.promptView != nil }, timeout: 3) {
                self.c.root.layoutSubtreeIfNeeded()
                let u = self.c.sidebar.update, side = self.c.sidebar.frame
                let pill = self.c.root.convert(u.pillRect, from: u)
                guard let card = MediaLibrary.shared.promptView else { self.check(false, "sidebarright footer: the downloads card shows"); return done() }
                let f = card.frame
                let aligned = close(f.maxX, side.maxX - AircMetrics.Sidebar.inset) || close(f.minX, 8)
                self.check(side.contains(NSPoint(x: pill.midX, y: pill.midY)) && aligned && f.maxY <= pill.minY && self.c.root.bounds.contains(f),
                           "sidebarright footer: the update pill \(r(pill)) in the sidebar, the downloads card \(r(f)) above it on the sidebar's right inset")
                self.captureNow("sidebarright-right-footer") { done() }
            }
        }
        run { [self] in
            MediaLibrary.shared.promptView?.model.onAnswer?(.keepDownloading)
            UpdateCenter.shared.setReady(nil)
        }
        run { [self] in c.toggleLibrary() }
        step { [self] done in
            waitUntil({ self.c.libraryFraction == 1 }, timeout: 3) {
                self.c.root.layoutSubtreeIfNeeded()
                guard let lib = self.c.library else { self.check(false, "sidebarright library: it opens"); return done() }
                let b = self.c.root.bounds, button = self.c.sidebar.footer.libraryButton
                let back = self.c.root.convert(lib.back.bounds, from: lib.back), was = self.c.root.convert(button.bounds, from: button)
                self.check(close(lib.frame.maxX, b.width) && close(self.c.card.frame.minX, i) && close(self.c.card.frame.maxX, b.width - lib.frame.width)
                           && close(back.minX, was.minX) && close(back.minY, was.minY),
                           "sidebarright library: from the right (\(r(lib.frame))), pushing the card \(r(self.c.card.frame)); its back button \(r(back)) "
                           + "on the Library button \(r(was))")
                self.captureNow("sidebarright-right-library") { done() }
            }
        }
        run { [self] in c.toggleLibrary() }
        step { [self] done in waitUntil({ self.c.library == nil }, timeout: 3) { done() } }

        // 3. ⌘S on the right: the sidebar slides off to the right; the right edge reveals it, floating.
        run { [self] in
            if !c.sidebarHidden { c.toggleSidebar() }
            check([NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].allSatisfy {
                c.window.standardWindowButton($0)?.isHidden == true
            }, "sidebarright hiding: traffic lights hide at the start of the slide")
        }
        step { [self] done in waitUntil({ self.c.sidebarFraction <= 0.001 }, timeout: 2) { done() } }
        run { [self] in
            c.root.layoutSubtreeIfNeeded()
            let b = c.root.bounds, card = c.card.frame
            let edge = c.revealController?.edgeFrame ?? .zero
            check(c.sidebar.frame.minX >= b.width - 0.5 && close(card.minX, i) && close(card.maxX, b.width - i),
                  "sidebarright hidden: the sidebar off the right edge (\(r(c.sidebar.frame))), the page card \(r(card))")
            check(close(edge.maxX, b.width) && close(edge.width, DesignGaps.revealEdge) && close(edge.height, b.height),
                  "sidebarright hidden: the reveal strip is the window's right edge \(r(edge))")
            let hiddenLights = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].allSatisfy { c.window.standardWindowButton($0)?.isHidden == true }
            check(hiddenLights, "sidebarright hidden: the traffic lights hide with the sidebar, as on the left")
        }
        capture("sidebarright-right-hidden")
        run { [self] in c.revealController?.reveal() }
        step { [self] done in
            let want = c.root.bounds.width - AircMetrics.Sidebar.floatingInset
            waitUntil({ abs((self.c.revealController?.floatingFrame.maxX ?? 0) - want) < 0.5 }, timeout: 2) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: done)
            }
        }
        run { [self] in
            c.root.layoutSubtreeIfNeeded()
            let b = c.root.bounds, f = c.revealController?.floatingFrame ?? .zero
            let inset = AircMetrics.Sidebar.floatingInset
            let side = c.sidebar.convert(c.sidebar.bounds, to: c.root)
            let ok = c.revealController?.isRevealed == true && close(f.maxX, b.width - inset) && close(f.minY, inset)
                && close(f.width, c.sidebarWidth) && close(side.minX, f.minX)
            if !ok, Self.screenLocked {
                note("FAIL-ENV sidebarright revealed: the floating sidebar didn't arrive (\(r(f))): the screen is locked, and the spring runs on the display link")
            } else {
                check(ok, "sidebarright revealed: the floating sidebar \(r(f)), \(Int(inset)) pt in from the right, top and bottom")
            }
            if let row = rows(c).first {
                let p = TabPreviewController.frame(beside: row, in: c).insetBy(dx: TabPreviewCardView.margin, dy: TabPreviewCardView.margin)
                check(close(p.maxX, side.minX - TabPreviewController.gap) || close(p.minX, 8),
                      "sidebarright revealed: the tab preview card \(r(p)) opens to the left of the floating sidebar")
            }
        }
        capture("sidebarright-right-revealed")
        run { [self] in c.revealController?.dock() }
        step { [self] done in waitUntil({ self.c.sidebarFraction >= 1 && self.c.revealController?.isRevealed != true }, timeout: 2) { done() } }
        run { [self] in docked(c, onRight: true, "right, docked again") }

        // 4. A drag on the inner (left) edge: to the left widens, as the pointer goes.
        step { [self] done in
            let w = c.window, h = c.resizeHandle
            let startWidth = c.sidebarWidth
            let p = h.convert(NSPoint(x: h.bounds.midX, y: h.bounds.midY), to: nil)
            func mouse(_ t: NSEvent.EventType, _ x: CGFloat) -> NSEvent? {
                NSEvent.mouseEvent(with: t, location: NSPoint(x: x, y: p.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: t == .leftMouseUp ? 0 : 1)
            }
            guard let down = mouse(.leftMouseDown, p.x), let drag = mouse(.leftMouseDragged, p.x - 40), let up = mouse(.leftMouseUp, p.x - 40) else {
                check(false, "sidebarright resize: events"); return done()
            }
            NSApp.postEvent(drag, atStart: false)
            NSApp.postEvent(up, atStart: false)
            h.mouseDown(with: down)
            let grew = c.sidebarWidth - startWidth
            check(close(grew, 40) && close(c.sidebar.frame.maxX, c.root.bounds.width),
                  "sidebarright resize: 40 pt to the left on the inner edge widens the sidebar by \(Int(grew)) pt (\(Int(startWidth)) → \(Int(c.sidebarWidth)))")
            c.setSidebarWidth(startWidth)
            done()
        }

        // 5. Live, across windows: a second window, the setting flipped twice, a third window opened on the right.
        var second: WindowController?
        run { [self] in
            setRight(false)
            second = app?.openNewWindow(from: c, commandBar: false)
        }
        step { [self] done in waitUntil({ (self.app?.controllers.count ?? 0) >= 2 }, timeout: 3) { done() } }
        run { [self] in
            guard let w2 = second else { return check(false, "sidebarright windows: a second window opens") }
            let w1 = c!
            docked(w2, onRight: false, "window 2, left")
            setRight(true)
            docked(w1, onRight: true, "window 1, live to the right")
            docked(w2, onRight: true, "window 2, live to the right")
            check(app?.store.windowState.sidebarOnRight == true, "sidebarright windows: the setting is kept (telemetry's sidebar_position reads it)")
        }
        capture("sidebarright-live-right")
        run { [self] in
            let third = app?.openNewWindow(from: second, commandBar: false)
            if let third {
                third.root.layoutSubtreeIfNeeded()
                docked(third, onRight: true, "window 3, opened on the right")
                third.window.performClose(nil)
            } else {
                check(false, "sidebarright windows: a third window opens")
            }
        }
        wait(0.4)
        run { [self] in
            setRight(false)
            for (n, w) in (app?.controllers ?? []).enumerated() { docked(w, onRight: false, "window \(n + 1), live back to the left") }
        }
        capture("sidebarright-live-left")
        run { [self] in second?.window.performClose(nil) }
        step { [self] done in waitUntil({ (self.app?.controllers.count ?? 0) == 1 }, timeout: 3) { done() } }
        run { server?.stop() }
    }
}
#endif
