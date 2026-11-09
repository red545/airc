// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircDesign
import AircKit

/// `--script sidebarpolish`, both engines, with synthetic pinned rows and Today tabs (no page needs to load). Five
/// sidebar-feel fixes from the parity audit, each driven through the handler real input reaches, because a scripted run
/// can't make that input:
/// - SB-61: the hidden sidebar's reveal dwell, armed through the edge strip's own `mouseMoved` (posted moves never reach
///   tracking areas). A scripted window is never key and the pointer is the owner's, so those two are stood in. The
///   dwell reveals only if all of it still holds when it ends: not after the window lost key, the pointer left, ⌘S
///   showed the sidebar, a menu began tracking (its notification, as TabPreviewCheck posts it) or a button went down.
///   With nothing stood in, the run's real state (not key) refuses too.
/// - WIN-4: drags on the resize handle (its own mouseDown with posted drag events, as sidebarright does): below the
///   minimum hides it, at the minimum it stays; on the right too; it comes back at the minimum.
/// - SP-21 / SP-25: swipes fed to the pager's `track` (posted events carry no trackpad phases): 22.7 pt of pull on
///   screen readies New Space past the last Space and the Library past the first, with hysteresis; only a finger lifted
///   while ready acts; a swipe that didn't start on the end page never pulls.
/// - SB-33: a folder closing and opening, the animations read back from the rows' layers: open on the 200 ms
///   cubic-bezier(0, 0, 0.58, 1), close on the critically damped ω 25 spring, the children under the moving rows; the
///   same with Reduce Motion (a 150 ms cross-fade, nothing moves); and an ordinary row change still on the row spring.
extension SnapshotRunner {
    func sidebarPolishScenario() {
        typealias Conditions = SidebarRevealGate.Conditions
        var spaces: [String] = []
        var folderID = ""
        func near(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool { abs(a - b) <= tolerance }
        func points(_ f: CAMediaTimingFunction?) -> [Float] {
            guard let f else { return [] }
            var out: [Float] = []
            for i in 1...2 {
                var v: [Float] = [0, 0]
                f.getControlPoint(at: i, values: &v)
                out += v
            }
            return out
        }
        func describe(_ a: CAAnimation?) -> String {
            switch a {
            case let s as CASpringAnimation:
                return String(format: "spring k %.0f, c %.1f, m %.0f, %.3f s", s.stiffness, s.damping, s.mass, s.duration)
            case let b as CABasicAnimation:
                return String(format: "curve %.3f s (%@)", b.duration, points(b.timingFunction).map { String(format: "%.2f", $0) }.joined(separator: ", "))
            case let t as CATransition: return String(format: "transition %.3f s", t.duration)
            default: return "none"
            }
        }
        /// The sidebar hidden or docked at once (no display-link animation to wait for).
        func setHidden(_ hidden: Bool) {
            c.animator.cancel("sidebar")
            c.sidebarHidden = hidden
            c.sidebarFraction = hidden ? 0 : 1
            c.store.updateWindowState { $0.sidebarHidden = hidden }
            c.layoutRoot()
            c.root.layoutSubtreeIfNeeded()
        }

        run { [self] in
            let store = c.store
            do {
                let home = store.selectedSpace.id
                try store.updateSpace(home) { $0.name = "Home" }
                let profile = store.selectedSpace.profileID
                let work = try store.createSpace(name: "Work", icon: .emoji("💼"), theme: DesignTheme.preset("sky")!.model,
                                                 profileID: profile, after: home)
                let side = try store.createSpace(name: "Side", icon: .emoji("🌱"), theme: DesignTheme.preset("mint")!.model,
                                                 profileID: profile, after: work.id)
                spaces = [home, work.id, side.id]
                try pin(Self.page("Pinned one"), title: "Pinned one", icon: nil, space: home)
                let folder = try store.createFolder(named: "Folder", inSpace: home)
                folderID = folder.id
                for k in 1...3 { try pin(Self.page("In folder \(k)"), title: "In folder \(k)", icon: nil, space: home, parent: folder.id) }
                try pin(Self.page("Pinned two"), title: "Pinned two", icon: nil, space: home)
                for k in 1...3 { _ = try store.openTab(url: Self.page("Today \(k)"), inSpace: home, activate: false, title: "Today \(k)") }
                c.reloadAll(animated: false)
                c.switchToSpace(home, animated: false)
                note("sidebarpolish: window key \(c.window.isKeyWindow), app active \(NSApp.isActive), screen locked \(Self.screenLocked)")
            } catch {
                check(false, "sidebarpolish: seeding the Spaces and rows (\(error))")
            }
        }
        wait(0.5)

        // MARK: SB-61, the reveal dwell

        let standIn: (inout Conditions) -> Void = { $0.windowIsKey = true; $0.pointerInStrip = true; $0.mouseButtonDown = false }
        run { [self] in setHidden(true); c.revealController?.layout() }
        /// One dwell: armed by the strip's mouseMoved with `before` stood in, `midway` halfway through, `after` stood in
        /// from then on; ends with `expect` (nil: it reveals).
        func dwell(_ label: String, expect: SidebarRevealGate.Refusal?, realState: Bool = false,
                   midway: (() -> Void)? = nil, after: ((inout Conditions) -> Void)? = nil, cleanup: (() -> Void)? = nil) {
            var count = 0
            run { [self] in
                guard let r = c.revealController else { return check(false, "sidebarpolish reveal \(label): a reveal controller") }
                count = r.dwellVerdicts.count
                r.testConditions = realState ? nil : standIn
                let e = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 2, y: c.root.bounds.midY), modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: c.window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
                if let e { r.edgeView.mouseMoved(with: e) }
                check(r.isDwelling && !r.isRevealed, "sidebarpolish reveal \(label): the strip's mouseMoved starts the dwell")
            }
            wait(DesignGaps.revealDelay * 0.5)
            run { [self] in
                midway?()
                if let after { c.revealController?.testConditions = after }
            }
            step { [self] done in
                waitUntil({ (self.c.revealController?.dwellVerdicts.count ?? 0) > count }, timeout: 1) {
                    guard let r = self.c.revealController, r.dwellVerdicts.count > count else {
                        self.check(false, "sidebarpolish reveal \(label): the dwell ended")
                        return done()
                    }
                    let verdict = r.dwellVerdicts[count]
                    let what = verdict.map { "refused: \($0.rawValue)" } ?? "revealed"
                    if label == "real state", self.c.window.isKeyWindow {
                        self.note("SKIP sidebarpolish reveal real state: the window is key (the owner clicked it?), \(what)")
                    } else {
                        self.check(verdict == expect && r.isRevealed == (expect == nil),
                                   "sidebarpolish reveal \(label): \(what) after \(Int(DesignGaps.revealDelay * 1000)) ms "
                                   + "(want \(expect.map { "refused: \($0.rawValue)" } ?? "revealed"))")
                    }
                    r.testConditions = nil
                    if r.isRevealed { r.dock(); setHidden(true) }
                    cleanup?()
                    done()
                }
            }
        }
        dwell("all held", expect: nil)
        dwell("window lost key during the dwell", expect: .notKey, after: { $0.windowIsKey = false; $0.pointerInStrip = true; $0.mouseButtonDown = false })
        dwell("pointer left during the dwell", expect: .pointerLeft, after: { $0.windowIsKey = true; $0.pointerInStrip = false; $0.mouseButtonDown = false })
        dwell("⌘S showed the sidebar during the dwell", expect: .notHidden, midway: { [self] in c.toggleSidebar() },
              cleanup: { setHidden(true) })
        let menu = NSMenu(title: "sidebarpolish")
        dwell("a menu opened during the dwell", expect: .menu,
              midway: { NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu) },
              cleanup: { NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu) })
        dwell("a press began during the dwell", expect: .drag, after: { $0.windowIsKey = true; $0.pointerInStrip = true; $0.mouseButtonDown = true })
        dwell("real state", expect: .notKey, realState: true)

        // MARK: WIN-4, the hide point

        /// A drag of `dx` on the resize handle from `width` (one drag event); the sidebar on the right if `onRight`. A
        /// drag that hides keeps the sidebar's last width (Arc ref §1): one event past the minimum leaves it at `width`.
        func resize(_ label: String, from width: CGFloat, by dx: CGFloat, onRight: Bool, hides: Bool) {
            run { [self] in
                setHidden(false)
                app?.setSidebarOnRight(onRight)
                c.setSidebarWidth(width)
                c.root.layoutSubtreeIfNeeded()
                let w = c.window, h = c.resizeHandle
                let p = h.convert(NSPoint(x: h.bounds.midX, y: h.bounds.midY), to: nil)
                func mouse(_ t: NSEvent.EventType, _ x: CGFloat) -> NSEvent? {
                    NSEvent.mouseEvent(with: t, location: NSPoint(x: x, y: p.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: t == .leftMouseUp ? 0 : 1)
                }
                guard let down = mouse(.leftMouseDown, p.x), let drag = mouse(.leftMouseDragged, p.x + dx), let up = mouse(.leftMouseUp, p.x + dx) else {
                    return check(false, "sidebarpolish resize \(label): events")
                }
                NSApp.postEvent(drag, atStart: false)
                NSApp.postEvent(up, atStart: false)
                h.mouseDown(with: down)
                let hidden = c.sidebarHidden
                let kept = c.sidebarWidth
                setHidden(false)
                check(hidden == hides && (hides ? near(Double(kept), Double(width), 0.01) : near(Double(kept), Double(width + (onRight ? -dx : dx)), 0.01)),
                      "sidebarpolish resize \(label): \(Int(width)) pt dragged \(String(format: "%+.1f", dx)) pt on the "
                      + (onRight ? "left (inner) edge" : "right (inner) edge") + " → " + (hidden ? "hidden, comes back at \(Int(kept)) pt" : "\(String(format: "%.1f", kept)) pt, shown")
                      + " (want " + (hides ? "hidden" : "shown") + ", minimum \(Int(AircMetrics.Sidebar.minWidth)))")
            }
        }
        let minW = AircMetrics.Sidebar.minWidth
        resize("toward the minimum", from: AircMetrics.Sidebar.defaultWidth, by: minW + 1 - AircMetrics.Sidebar.defaultWidth, onRight: false, hides: false)
        resize("onto the minimum", from: minW + 10, by: -10, onRight: false, hides: false)
        resize("1 pt past the minimum", from: minW, by: -1, onRight: false, hides: true)
        resize("in one drag from 200 pt", from: 200, by: -37, onRight: false, hides: true)
        resize("1 pt past the minimum, sidebar on the right", from: minW, by: 1, onRight: true, hides: true)
        run { [self] in
            app?.setSidebarOnRight(false)
            c.setSidebarWidth(AircMetrics.Sidebar.defaultWidth)
            setHidden(false)
        }
        wait(0.3)

        // MARK: SP-21 / SP-25, the detents

        let detent = SwipeOverscroll.detent
        /// A swipe on Space `startIndex`: `toward` −1 pulls toward the next Space (past the last), +1 toward the previous.
        /// Fed 0.5 pt per event out to `travel`, then back to `back` (if any) and out again to `travel`; ends with `end`.
        func pull(_ label: String, startIndex: Int, toward: CGFloat, travel: CGFloat, back: CGFloat? = nil,
                  end: NSEvent.Phase, expectReadyAt: Bool, acts: Bool) {
            var hapticsBefore = 0
            run { [self] in
                c.switchToSpace(spaces[startIndex], animated: false)
                let pager = c.sidebar.pager
                hapticsBefore = pager.detentHaptics
                let width = Double(pager.pageWidth)
                let want = SwipeOverscroll.fingerTravel(forPull: detent, pageWidth: width)
                let step: CGFloat = 0.5
                var moved: CGFloat = step
                var readyAt: (travel: CGFloat, points: Double)?
                var disarmedAt: Double?
                var rearmed = false
                pager.track(phase: .began, momentum: [], dx: step * toward, dy: 0, precise: true)
                func feed(_ d: CGFloat) {
                    pager.track(phase: .changed, momentum: [], dx: d * toward, dy: 0, precise: true)
                    moved += d
                }
                let isReady = { toward < 0 ? pager.pullState.createReady : pager.pullState.libraryReady }
                while moved < travel {
                    feed(step)
                    if readyAt == nil, isReady() { readyAt = (moved, pager.pullState.points) }
                }
                if let back {
                    while moved > back {
                        feed(-step)
                        if disarmedAt == nil, !isReady() { disarmedAt = pager.pullState.points }
                    }
                    while moved < travel {
                        feed(step)
                        if isReady() { rearmed = true }
                    }
                }
                let state = pager.pullState
                pager.track(phase: end, momentum: [], dx: 0, dy: 0, precise: true)
                let endName = end == .ended ? "lifted" : "cancelled"
                if expectReadyAt {
                    let at = readyAt
                    check(at != nil && near(Double(at!.travel), want, 0.51) && at!.points >= detent && at!.points < detent + 0.35,
                          "sidebarpolish \(label): ready after \(at.map { String(format: "%.1f", $0.travel) } ?? "never") pt of finger travel "
                          + "(want \(String(format: "%.1f", want)) at \(Int(width)) pt), \(at.map { String(format: "%.2f", $0.points) } ?? "-") pt pulled on screen (detent \(detent))")
                } else {
                    check(readyAt == nil && !state.createReady && !state.libraryReady,
                          "sidebarpolish \(label): never ready (\(String(format: "%.1f", moved)) pt of travel, \(String(format: "%.1f", state.points)) pt pulled past "
                          + "\(state.end.map { "\($0)" } ?? "no end"))")
                }
                if let back {
                    check(disarmedAt.map { near($0, detent - SwipeOverscroll.hysteresis, 0.35) } == true && rearmed,
                          "sidebarpolish \(label): pulled back, it disarms at \(disarmedAt.map { String(format: "%.2f", $0) } ?? "never") pt "
                          + "(want \(detent - SwipeOverscroll.hysteresis)) and readies again")
                }
                let haptics = pager.detentHaptics - hapticsBefore
                let wantHaptics = !expectReadyAt ? 0 : back == nil ? 1 : 2
                check(haptics == wantHaptics, "sidebarpolish \(label): \(haptics) detent haptic(s) (want \(wantHaptics); counted, not played, in a scripted run)")
                note("sidebarpolish \(label): \(endName) at \(String(format: "%.1f", state.points)) pt pulled, ready \(toward < 0 ? state.createReady : state.libraryReady)")
            }
            step { [self] done in
                let opened = { toward < 0 ? self.c.newSpacePanel != nil : self.c.library != nil }
                waitUntil(opened, timeout: acts ? 1 : 0.4) {
                    let what = toward < 0 ? "Create a Space" : "the Library"
                    self.check(opened() == acts, "sidebarpolish \(label): " + (opened() ? "\(what) opened" : "nothing opened")
                               + " (want " + (acts ? "\(what)" : "nothing") + ")")
                    if toward < 0 { self.c.newSpacePanel?.model.onCancel?() }
                    if toward > 0, self.c.library != nil { self.c.toggleLibrary() }
                    done()
                }
            }
            step { [self] done in waitUntil({ self.c.library == nil && self.c.newSpacePanel == nil }, timeout: 2) { done() } }
            run { [self] in
                if c.library != nil || c.newSpacePanel != nil {
                    note((Self.screenLocked ? "FAIL-ENV" : "FAIL") + " sidebarpolish \(label): the Library or Create a Space didn't close (springs run on the display link)")
                }
            }
            wait(0.4)
        }
        let n = 3
        pull("pull past the last Space", startIndex: n - 1, toward: -1, travel: 60, back: 40, end: .ended, expectReadyAt: true, acts: true)
        pull("pull past the last Space, lifted under the detent", startIndex: n - 1, toward: -1, travel: 45, end: .ended, expectReadyAt: false, acts: false)
        pull("pull past the last Space, gesture cancelled while ready", startIndex: n - 1, toward: -1, travel: 60, end: .cancelled, expectReadyAt: true, acts: false)
        pull("swipe toward the last Space from the one before it", startIndex: n - 2, toward: -1, travel: 300, end: .ended, expectReadyAt: false, acts: false)
        pull("pull past the first Space", startIndex: 0, toward: 1, travel: 60, back: 40, end: .ended, expectReadyAt: true, acts: true)
        pull("pull past the first Space, lifted under the detent", startIndex: 0, toward: 1, travel: 45, end: .ended, expectReadyAt: false, acts: false)
        pull("swipe toward the first Space from the second", startIndex: 1, toward: 1, travel: 300, end: .ended, expectReadyAt: false, acts: false)
        run { [self] in c.switchToSpace(spaces[0], animated: false) }
        wait(0.5)

        // MARK: SB-33, the folder curves

        func fold(_ label: String, reduceMotion: Bool) {
            var before: [String: NSRect] = [:]
            var opening = false
            run { [self] in
                SpacePageView.reduceMotionForTesting = reduceMotion
                guard let page = c.pageView(for: c.currentSpaceID) else { return check(false, "sidebarpolish fold \(label): the page") }
                page.layoutSubtreeIfNeeded()
                before = page.rows.mapValues(\.frame)
                opening = c.store.item(folderID)?.isCollapsed == true
                c.toggleFolder(folderID)
            }
            step { [self] done in
                let page = c.pageView(for: c.currentSpaceID)
                waitUntil({ page?.lastFold.map { $0.folderID == folderID && $0.opening == opening && $0.reduceMotion == reduceMotion } == true }, timeout: 1) {
                    defer { SpacePageView.reduceMotionForTesting = nil; done() }
                    guard let page, let last = page.lastFold, last.opening == opening else {
                        return self.check(false, "sidebarpolish fold \(label): the folder " + (opening ? "opened" : "closed") + " with its own motion")
                    }
                    let children = Set(self.c.store.children(of: .pinned(spaceID: self.c.currentSpaceID), parent: folderID).map(\.id))
                    // Rows that stayed and moved, children that came (open) or are fading away (close).
                    let moved = page.rows.filter { id, v in before[id].map { abs($0.minY - v.frame.minY) > 0.5 } == true }
                    let came = page.rows.filter { id, _ in before[id] == nil }.map(\.value)
                    let going = page.list.subviews.compactMap { $0 as? SidebarRowView }.filter { v in !page.rows.values.contains { $0 === v } }
                    let motions = moved.values.map { $0.layer?.animation(forKey: "springPosition") }
                    let fades = (opening ? came : going).map { $0.layer?.animation(forKey: "fade") }
                    let under = (opening ? came : going).allSatisfy { $0.layer?.zPosition == -1 }
                    let firstMotion = describe(motions.first ?? nil), firstFade = describe(fades.first ?? nil)
                    let summary = "\(moved.count) rows moved (\(firstMotion)), \(opening ? came.count : going.count) children "
                        + (opening ? "faded in" : "fading out") + " (\(firstFade))" + (under ? ", under the rows" : "")
                    note("sidebarpolish fold \(label): " + summary)
                    if reduceMotion {
                        let transition = page.list.layer?.animation(forKey: kCATransition)
                        check(motions.allSatisfy { $0 == nil } && fades.allSatisfy { $0 == nil } && going.isEmpty
                              && (transition as? CATransition).map { near($0.duration, AircMotion.reducedDuration, 0.001) } == true && !moved.isEmpty,
                              "sidebarpolish fold \(label): with Reduce Motion nothing slides or fades on its own; the list cross-fades "
                              + "(\(describe(transition))). " + summary)
                        return
                    }
                    let childCount = opening ? came.count : going.count
                    if opening {
                        let curve = AircCurve.folderOpen
                        let want = [Float(curve.c1.x), Float(curve.c1.y), Float(curve.c2.x), Float(curve.c2.y)]
                        let curveOK: (CAAnimation?) -> Bool = { a in
                            guard let b = a as? CABasicAnimation, !(b is CASpringAnimation) else { return false }
                            return near(b.duration, curve.duration, 0.001) && zip(points(b.timingFunction), want).allSatisfy { abs($0 - $1) < 0.001 }
                        }
                        check(!moved.isEmpty && motions.allSatisfy(curveOK) && childCount == children.count && fades.allSatisfy(curveOK) && under,
                              "sidebarpolish fold \(label): the rows below move on cubic-bezier(0, 0, 0.58, 1) over 200 ms and the \(children.count) "
                              + "children fade in on it, under them. " + summary)
                    } else {
                        let spring = AircSpring.fold
                        let springOK = motions.allSatisfy { a in
                            guard let s = a as? CASpringAnimation else { return false }
                            return near(s.stiffness, 625, 0.5) && near(s.damping, 50, 0.05) && near(s.mass, 1, 0.001)
                                && near(s.duration, s.settlingDuration, 0.001)
                        }
                        let fadeOK = fades.allSatisfy { ($0 as? CABasicAnimation).map { near($0.duration, SpacePageView.foldFade, 0.001) } == true }
                        check(!moved.isEmpty && springOK && childCount == children.count && fadeOK && under,
                              "sidebarpolish fold \(label): the rows below move on the critically damped ω 25 spring (k 625, c 50, m 1; "
                              + "within 0.1 % after \(String(format: "%.0f", spring.settlingDuration * 1000)) ms) and the \(children.count) children fade out in "
                              + "\(Int(SpacePageView.foldFade * 1000)) ms under them. " + summary)
                    }
                }
            }
            wait(0.5)
            capture("sidebarpolish-folder-" + label.replacingOccurrences(of: ", Reduce Motion", with: "-reduced"))
        }
        run { [self] in
            if c.store.item(folderID)?.isCollapsed == true { c.toggleFolder(folderID) }
        }
        wait(0.5)
        fold("close", reduceMotion: false)
        fold("open", reduceMotion: false)
        fold("close, Reduce Motion", reduceMotion: true)
        fold("open, Reduce Motion", reduceMotion: true)

        // A control: an ordinary row change (a new Today tab) still moves the rows on the row spring.
        var rowsBefore: [String: NSRect] = [:]
        run { [self] in
            guard let page = c.pageView(for: c.currentSpaceID) else { return }
            page.layoutSubtreeIfNeeded()
            rowsBefore = page.rows.mapValues(\.frame)
            _ = try? c.store.openTab(url: Self.page("Today 4"), inSpace: c.currentSpaceID, activate: false, title: "Today 4")
        }
        step { [self] done in
            let page = c.pageView(for: c.currentSpaceID)
            waitUntil({ (page?.rows.count ?? 0) > rowsBefore.count }, timeout: 1) {
                let moved = page?.rows.filter { id, v in rowsBefore[id].map { abs($0.minY - v.frame.minY) > 0.5 } == true } ?? [:]
                let anims = moved.values.map { $0.layer?.animation(forKey: "springPosition") }
                let row = AircSpring.row
                let ok = !moved.isEmpty && anims.allSatisfy { a in (a as? CASpringAnimation).map { near($0.stiffness, row.stiffness, 1) } == true }
                self.check(ok, "sidebarpolish fold control: a new Today tab moves \(moved.count) rows on the row spring "
                           + "(\(describe(anims.first ?? nil)); want k \(Int(row.stiffness.rounded())))")
                done()
            }
        }
    }
}
#endif
