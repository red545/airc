// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircDesign
import AircKit

/// `--script parityp02` then `--script parityp02-relaunch` on the same data (both engines), P02's Space header states
/// (Arc ref §2.4) on loopback pages. Input is real where it says so: clicks and keys from the build Mac's UI driver
/// (HID; keys PID-targeted at our foreground app), with AIRC_UI_DEDICATED_SESSION=1 and AIRC_REAL_KEYS=1.
///   - a real click on a named Space's header folds its pinned section: the rows below rise on the folder-close spring
///     (ω 25, ζ 1) while the pinned rows fade under them; the chevron turns a quarter turn on the row spring (sampled
///     mid-turn); a second click opens it on the folder-open curve (200 ms ease-out) and turns it back;
///   - folded over the tab on screen, the name is bold; real ← and → on the header fold and open it; with Reduce
///     Motion the list cross-fades and the chevron turns at once;
///   - an unnamed Space doesn't fold (R §2.4, "only named Spaces"): its row shows no chevron and a real click leaves
///     the pinned rows; clearing a folded Space's name opens it;
///   - the only Space, unnamed and without an icon: renamed to nothing with real keys, its row hides; a second Space
///     brings it back, deleting that hides it again; Show Space Header, then a name typed with real keys, shows it for good;
///   - Today empty, and only Favorites (no pinned rows, no Today): the row shows and folds;
///   - the relaunch: the folded Space comes back folded with its chevron turned and the other Space open; a real click
///     opens it.
extension SnapshotRunner {
    private static let p02Pages = ["/mail", "/docs", "/notes", "/today-a", "/today-b", "/fav"]

    /// The header's chevron (a bare 20 pt layer: read from the tree, so this check also builds on trees without P02).
    private func p02Chevron(_ h: SpaceHeaderView) -> CALayer? {
        h.layer?.sublayers?.first { $0.delegate == nil && $0.bounds.size == CGSize(width: 20, height: 20) && $0.contents != nil }
    }
    private func p02Angle(_ l: CALayer?, presentation: Bool = true) -> Double {
        guard let l else { return .nan }
        return ((presentation ? l.presentation() ?? l : l).value(forKeyPath: "transform.rotation.z") as? NSNumber)?.doubleValue ?? .nan
    }
    /// Where a folded chevron ends: a quarter turn that makes "down" point right (sign by the layer's y axis).
    private func p02End(_ flipped: Bool) -> Double { flipped ? -Double.pi / 2 : Double.pi / 2 }
    private func p02Real() -> Bool {
        UIDriverClient.available && ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1"
    }
    /// A point on the header's name, clear of ••• and the profile pill.
    private func p02HeaderPoint(_ h: SpaceHeaderView) -> NSPoint {
        h.convert(NSPoint(x: min(70, h.bounds.width / 3), y: h.bounds.midY), to: nil)
    }

    /// Our window in front and key (the dedicated session launches us in front; if not, one real click on the gap below
    /// the page, which does nothing else).
    private func p02Front(_ tag: String) {
        step { [self] done in
            guard p02Real() else { return done() }
            if NSApp.isActive, c.window.isKeyWindow { return done() }
            let card = c.card.convert(c.card.bounds, to: nil)
            let p = NSPoint(x: card.midX, y: card.minY - AircMetrics.Window.cardInset / 2 - 1)
            let s = c.window.convertPoint(toScreen: p), top = NSScreen.screens.first?.frame.maxY ?? 0
            UIDriverClient.run(["--click", String(Double(s.x)), String(Double(top - s.y))]) { _, _ in
                self.waitUntil({ NSApp.isActive && self.c.window.isKeyWindow }, timeout: 3) {
                    if !(NSApp.isActive && self.c.window.isKeyWindow) {
                        self.note("FAIL-ENV \(tag): our window isn't the active key window (active \(NSApp.isActive))")
                    }
                    done()
                }
            }
        }
    }

    /// A real click at `point` while sampling, every frame, the chevron's drawn turn and, once the fold shows in the
    /// list, the rows' motion. `then(ok, samples, motion)` on main.
    private func p02Click(_ tag: String, header: @escaping () -> SpaceHeaderView?, at point: (() -> NSPoint)? = nil,
                          then: @escaping (Bool, [Double], [String: String]) -> Void) {
        guard let h = header(), let page = c.pageView(for: c.currentSpaceID) else { return then(false, [], [:]) }
        var samples: [Double] = []
        var motion: [String: String] = [:]
        let sid = c.currentSpaceID
        let wasCollapsed = c.store.space(sid)?.pinnedCollapsed
        let pinnedIDs = Set(c.store.pinnedRows(ofSpace: sid).map(\.id))
        let foldBefore = p02FoldText(page)
        var ticks = 0
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            guard let self else { return }
            samples.append(self.p02Angle(self.p02Chevron(h)))
            guard motion.isEmpty, self.c.store.space(sid)?.pinnedCollapsed != wasCollapsed else { return }
            ticks += 1
            guard self.p02FoldText(page) != foldBefore || ticks >= 3 else { return }
            motion = self.p02Motion(page, pinnedIDs: pinnedIDs)
        }
        RunLoop.main.add(timer, forMode: .common)
        let finish: (Bool, String) -> Void = { ok, out in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                timer.invalidate()
                if !ok { self.note("FAIL-ENV \(tag): the driver's click (\(out.prefix(200)))") }
                then(ok, samples, motion)
            }
        }
        if p02Real() {
            // Laid out first: a change just before (Favorites appearing) moves the row.
            c.window.contentView?.layoutSubtreeIfNeeded()
            let p = point?() ?? p02HeaderPoint(h)
            // Plain HID click (the driver refuses an empty --mods), only into our active key window on the active Space.
            guard NSApp.isActive, c.window.isKeyWindow, c.window.isOnActiveSpace,
                  NSWindow.windowNumber(at: c.window.convertPoint(toScreen: p), belowWindowWithWindowNumber: 0) == c.window.windowNumber else {
                return finish(false, "our window isn't the active key window, or another window covers the point")
            }
            // Past the double-click interval since the last case's click, or the press counts as a double-click (rename).
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval + 0.15) { [self] in
                c.window.contentView?.layoutSubtreeIfNeeded()
                let q = point?() ?? p02HeaderPoint(h)
                let s = c.window.convertPoint(toScreen: q), top = NSScreen.screens.first?.frame.maxY ?? 0
                UIDriverClient.run(["--click", String(Double(s.x)), String(Double(top - s.y))], finish)
            }
        } else {
            finish(false, "real input needs AIRC_REAL_KEYS=1, AIRC_UI_DEDICATED_SESSION=1 and the stable UI driver")
        }
    }

    /// Real keys at our own (foreground) process, sampling as `p02Click` does.
    private func p02Keys(_ tag: String, _ combos: [String], header: SpaceHeaderView?,
                         then: @escaping (Bool, [Double], [String: String]) -> Void) {
        guard let page = c.pageView(for: c.currentSpaceID) else { return then(false, [], [:]) }
        var samples: [Double] = []
        var motion: [String: String] = [:]
        let sid = c.currentSpaceID
        let wasCollapsed = c.store.space(sid)?.pinnedCollapsed
        let pinnedIDs = Set(c.store.pinnedRows(ofSpace: sid).map(\.id))
        let foldBefore = p02FoldText(page)
        var ticks = 0
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let header { samples.append(self.p02Angle(self.p02Chevron(header))) }
            guard motion.isEmpty, self.c.store.space(sid)?.pinnedCollapsed != wasCollapsed else { return }
            ticks += 1
            guard self.p02FoldText(page) != foldBefore || ticks >= 3 else { return }
            motion = self.p02Motion(page, pinnedIDs: pinnedIDs)
        }
        RunLoop.main.add(timer, forMode: .common)
        let finish: (Bool, String) -> Void = { ok, out in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                timer.invalidate()
                if !ok { self.note("FAIL-ENV \(tag): the driver's keys (\(out.prefix(200)))") }
                then(ok, samples, motion)
            }
        }
        guard p02Real() else { return finish(false, "real input needs AIRC_REAL_KEYS=1, AIRC_UI_DEDICATED_SESSION=1 and the stable UI driver") }
        UIDriverClient.press(combos, pid: getpid(), finish)
    }

    /// How the list moves in the render that showed a fold: the first moving row's position animation, a leaving or
    /// arriving pinned row's fade, the list's cross-fade, and the page's recorded fold.
    private func p02FoldText(_ page: SpacePageView) -> String {
        page.lastFold.map { "\($0.folderID) opening \($0.opening) reduceMotion \($0.reduceMotion)" } ?? "none"
    }
    private func p02Motion(_ page: SpacePageView, pinnedIDs: Set<String>) -> [String: String] {
        var m: [String: String] = [:]
        m["fold"] = p02FoldText(page)
        for v in page.list.subviews {
            guard let l = v.layer else { continue }
            if m["move"] == nil, let a = l.animation(forKey: "springPosition") {
                if let s = a as? CASpringAnimation {
                    m["move"] = String(format: "spring stiffness %.0f damping %.1f", s.stiffness, s.damping)
                } else if let b = a as? CABasicAnimation {
                    m["move"] = String(format: "curve %.3f s", b.duration)
                }
            }
            let id = (v as? SidebarRowView)?.navID ?? ""
            if m["fade"] == nil, pinnedIDs.contains(id) || !page.rows.values.contains(where: { $0 === v }),
               let f = l.animation(forKey: "fade") as? CABasicAnimation {
                m["fade"] = String(format: "%.2f s, z %.0f", f.duration, l.zPosition)
            }
        }
        m["crossfade"] = page.list.layer?.animation(forKey: kCATransition) != nil ? "yes" : "no"
        return m
    }

    private func p02PinnedShown(_ sid: String) -> Int {
        guard let page = c.pageView(for: sid) else { return -1 }
        let ids = Set(c.store.pinnedRows(ofSpace: sid).map(\.id))
        return page.rows.keys.filter(ids.contains).count
    }

    /// Mid-turn samples: some drawn angle strictly between the two ends.
    private func p02MidTurn(_ samples: [Double], from a: Double, to b: Double) -> Bool {
        let lo = min(a, b) + 0.05, hi = max(a, b) - 0.05
        return samples.contains { $0 > lo && $0 < hi }
    }
    private func p02Fmt(_ samples: [Double]) -> String {
        var distinct: [Double] = []
        for v in samples where distinct.last.map({ abs($0 - v) > 0.01 }) ?? true { distinct.append(v) }
        return distinct.prefix(8).map { String(format: "%.2f", $0) }.joined(separator: " → ")
    }

    /// Writes the window and a 4× close-up of the header (layer tree, so the chevron's turn shows).
    private func p02Shot(_ name: String) {
        capture(name)
        run { [self] in
            guard let h = c.pageView(for: c.currentSpaceID)?.header, let layer = h.layer, !h.isHidden else { return }
            let size = h.bounds.size, scale: CGFloat = 4
            guard size.width > 0, let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            let dark = c.store.space(c.currentSpaceID).map { c.palette(for: $0).isDark } ?? false
            ctx.setFillColor(NSColor(white: dark ? 0.16 : 0.92, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
            ctx.scaleBy(x: scale, y: scale)
            if h.isFlipped { ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1) }
            layer.render(in: ctx)
            guard let image = ctx.makeImage(),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
            try? png.write(to: dir.appendingPathComponent(name + "-header.png"))
            note("wrote \(name)-header.png (header layer tree, 4×)")
        }
    }

    func parityP02Scenario() {
        var server: LocalPageServer?
        var base = ""
        var home = ""
        var ids: [String: String] = [:]
        func page() -> SpacePageView? { c.pageView(for: c.currentSpaceID) }
        func header() -> SpaceHeaderView? { page()?.header }
        func titles(_ m: NSMenu) -> [String] { m.items.filter { !$0.isSeparatorItem }.map(\.title) }
        func fire(_ m: NSMenu, _ title: String) -> Bool {
            guard let k = m.items.firstIndex(where: { $0.title == title }) else { return false }
            m.performActionForItem(at: k)
            return true
        }

        step { [self] done in
            var pages: [String: String] = [:]
            for p in Self.p02Pages { pages[p] = "<!doctype html><title>\(p.dropFirst())</title><body style='font:15px -apple-system'><p>\(p.dropFirst())</p>" }
            server = LocalPageServer(pages: pages)
            server?.start { port in
                if let port { base = "http://127.0.0.1:\(port)" } else { self.check(false, "parityp02: a loopback page server") }
                done()
            }
        }
        // One Space, named, three pinned tabs (the last one on screen), two Today tabs.
        run { [self] in
            home = c.currentSpaceID
            guard c.store.orderedSpaces.count == 1, !base.isEmpty else {
                return check(false, "parityp02: the run starts with one Space (\(c.store.orderedSpaces.count)) and a page server")
            }
            app?.settings.values.showsSpaceHeaderOnSingleUnnamed = false
            MainActor.assumeIsolated { AircMotion.reduceMotionOverride = false }
            SpacePageView.reduceMotionForTesting = false
            do {
                try c.store.updateSpace(home) { $0.name = "Home"; $0.icon = nil; $0.pinnedCollapsed = false }
                for p in ["/mail", "/docs", "/notes"] {
                    let t = try c.store.openTab(url: base + p, inSpace: home, activate: false, title: String(p.dropFirst()))
                    try c.store.togglePin(t.id, inSpace: home)
                    ids[p] = t.id
                }
                for p in ["/today-a", "/today-b"] {
                    ids[p] = try c.store.openTab(url: base + p, inSpace: home, activate: false, title: String(p.dropFirst())).id
                }
            } catch { return check(false, "parityp02: the sidebar fixture (\(error))") }
            c.reloadAll(animated: false)
            c.show(ids["/notes"]!)
        }
        waitForPage()
        p02Front("parityp02")
        run { [self] in
            check(p02PinnedShown(home) == 3 && header()?.isHidden == false,
                  "parityp02: Home shows its name row and its three pinned rows (\(p02PinnedShown(home)))")
            _ = page()?.focusKeyboard(on: SpacePageView.headerNavID)
        }
        wait(0.3)
        p02Shot("parityp02-1-expanded")
        run { [self] in
            let a = p02Angle(p02Chevron(header()!))
            check(abs(a) < 0.01, String(format: "parityp02: open, the chevron points down (%.2f rad)", a))
        }

        // A real click folds; the motion and the chevron's turn (the keyboard on the row shows the chevron, as the
        // pointer does).
        uiCase(window: { self.c.window }) {
            run { [self] in _ = page()?.focusKeyboard(on: SpacePageView.headerNavID) }
            step { [self] done in
                p02Click("parityp02 fold", header: header) { ok, samples, motion in
                    guard ok else { return done() }
                    let s = self.c.store.space(home)
                    let end = self.p02End(self.p02Chevron(header()!)?.contentsAreFlipped() ?? false)
                    self.check(s?.pinnedCollapsed == true && self.p02PinnedShown(home) == 0,
                               "parityp02 fold: a real click on Home's header folds its pinned section (collapsed \(s?.pinnedCollapsed ?? false), pinned rows shown \(self.p02PinnedShown(home)))")
                    self.check(motion["fold"] == "\(SpacePageView.headerNavID) opening false reduceMotion false" && motion["move"] == "spring stiffness 625 damping 50.0"
                               && motion["fade"]?.hasPrefix("0.15 s, z -1") == true,
                               "parityp02 fold: the rows below rise on the folder-close spring (ω 25, ζ 1) while the pinned rows fade under them (\(motion))")
                    self.check(self.p02MidTurn(samples, from: 0, to: end) && abs((samples.last ?? .nan) - end) < 0.01,
                               "parityp02 fold: the chevron turns a quarter turn, drawn mid-turn (\(self.p02Fmt(samples)); ends at \(String(format: "%.2f", end)))")
                    let turn = header().flatMap { $0.responds(to: NSSelectorFromString("p02LastTurn")) ? $0.value(forKey: "p02LastTurn") as? [Double] : nil } ?? []
                    self.check(turn.count == 5 && abs(turn[3] - AircSpring.row.stiffness) < 1 && abs(turn[4] - AircSpring.row.damping) < 0.5,
                               "parityp02 fold: on the row spring (0.13 s, ζ 0.9: \(turn.map { String(format: "%.2f", $0) }))")
                    self.check(header()?.isEmphasized == true,
                               "parityp02 fold: folded over the tab on screen (a pinned one), the name is bold")
                    done()
                }
            }
        }
        run { [self] in _ = page()?.focusKeyboard(on: SpacePageView.headerNavID) }
        wait(0.3)
        p02Shot("parityp02-2-folded")
        uiCase(window: { self.c.window }) {
            run { [self] in _ = page()?.focusKeyboard(on: SpacePageView.headerNavID) }
            step { [self] done in
                p02Click("parityp02 open", header: header) { ok, samples, motion in
                    guard ok else { return done() }
                    let end = self.p02End(self.p02Chevron(header()!)?.contentsAreFlipped() ?? false)
                    self.check(self.c.store.space(home)?.pinnedCollapsed == false && self.p02PinnedShown(home) == 3 && header()?.isEmphasized == false,
                               "parityp02 open: a second real click opens it (pinned rows \(self.p02PinnedShown(home)), not bold)")
                    self.check(motion["fold"] == "\(SpacePageView.headerNavID) opening true reduceMotion false" && motion["move"] == "curve 0.200 s",
                               "parityp02 open: the rows move on the folder-open curve, 200 ms ease-out (\(motion))")
                    self.check(self.p02MidTurn(samples, from: end, to: 0) && abs(samples.last ?? .nan) < 0.01,
                               "parityp02 open: the chevron turns back, drawn mid-turn (\(self.p02Fmt(samples)))")
                    done()
                }
            }
        }

        // Real ← and → on the header; then with Reduce Motion.
        uiCase(window: { self.c.window }) {
            run { [self] in _ = page()?.focusKeyboard(on: SpacePageView.headerNavID) }
            step { [self] done in
                p02Keys("parityp02 keys", ["left"], header: header()) { ok, _, _ in
                    guard ok else { return done() }
                    let foldedNow = self.c.store.space(home)?.pinnedCollapsed == true
                    self.p02Keys("parityp02 keys", ["right"], header: header()) { ok2, _, _ in
                        guard ok2 else { return done() }
                        self.check(foldedNow && self.c.store.space(home)?.pinnedCollapsed == false
                                   && (self.c.window.firstResponder as? SidebarRowView)?.navID == SpacePageView.headerNavID,
                                   "parityp02 keys: real ← on the header folds the section, → opens it, the keyboard stays on the header")
                        done()
                    }
                }
            }
        }
        uiCase(window: { self.c.window }) {
            run { [self] in
                MainActor.assumeIsolated { AircMotion.reduceMotionOverride = true }
                SpacePageView.reduceMotionForTesting = true
                _ = page()?.focusKeyboard(on: SpacePageView.headerNavID)
            }
            step { [self] done in
                p02Keys("parityp02 reduce motion", ["left"], header: header()) { ok, samples, motion in
                    guard ok else { return done() }
                    let end = self.p02End(self.p02Chevron(header()!)?.contentsAreFlipped() ?? false)
                    self.check(self.c.store.space(home)?.pinnedCollapsed == true && motion["fold"]?.hasSuffix("reduceMotion true") == true
                               && motion["crossfade"] == "yes" && motion["move"] == nil
                               && !self.p02MidTurn(samples, from: 0, to: end) && abs((samples.last ?? .nan) - end) < 0.01,
                               "parityp02 reduce motion: the list cross-fades, nothing slides, the chevron turns at once (\(motion); \(self.p02Fmt(samples)))")
                    self.p02Keys("parityp02 reduce motion", ["right"], header: header()) { _, _, _ in done() }
                }
            }
            run {
                MainActor.assumeIsolated { AircMotion.reduceMotionOverride = false }
                SpacePageView.reduceMotionForTesting = false
            }
        }

        // An unnamed Space doesn't fold (two Spaces, so its row shows).
        run { [self] in
            if let s = try? c.store.createSpace(name: "Second", profileID: c.store.profile(ofSpace: home).id, after: home) { ids["second"] = s.id }
            c.reloadAll(animated: false)
            c.renameSpace(home, to: "")
            c.reloadAll(animated: false)
            _ = page()?.focusKeyboard(on: SpacePageView.headerNavID)
        }
        wait(0.3)
        run { [self] in
            let chev = p02Chevron(header()!)
            check(header()?.isHidden == false && chev?.isHidden == true,
                  "parityp02 unnamed: with two Spaces the unnamed one shows its row, with no chevron under the keyboard (chevron shown \(chev.map { !$0.isHidden } ?? false))")
            c.window.makeFirstResponder(c.engineTab(for: ids["/notes"]!)?.view)
        }
        p02Shot("parityp02-3-unnamed-two-spaces")
        uiCase(window: { self.c.window }) {
            step { [self] done in
                p02Click("parityp02 unnamed", header: header) { ok, _, _ in
                    guard ok else { return done() }
                    self.check(self.c.store.space(home)?.pinnedCollapsed == false && self.p02PinnedShown(home) == 3,
                               "parityp02 unnamed: a real click on an unnamed Space's row leaves its pinned section open (Arc: only named Spaces fold)")
                    done()
                }
            }
        }
        run { [self] in
            try? c.store.updateSpace(home) { $0.name = "Home"; $0.pinnedCollapsed = true }
            c.renameSpace(home, to: "")
            check(c.store.space(home)?.pinnedCollapsed == false, "parityp02 unnamed: clearing a folded Space's name opens its pinned section")
            let command = CommandMenus.all.first { $0.id == "tabs.collapsePinned" }
            check(command?.isEnabled?(c) == false,
                  "parityp02 unnamed: Tabs › Collapse Pinned Section is off for an unnamed Space")
        }

        // The only Space: renamed to nothing with real keys, the row hides; a second Space brings it back.
        run { [self] in
            if let second = ids["second"] { try? c.store.deleteSpace(second) }
            try? c.store.updateSpace(home) { $0.name = "Home" }
            c.reloadAll(animated: false)
        }
        uiCase(window: { self.c.window }) {
            run { [self] in _ = fire(c.spaceMenu(spaceID: home), "Rename Space…") }
            wait(0.2)
            step { [self] done in
                p02Keys("parityp02 singleton", ["delete", "return"], header: nil) { ok, _, _ in
                    guard ok else { return done() }
                    self.c.reloadAll(animated: false)
                    let hidden = header()?.isHidden == true && !(page()?.navItems.contains { $0.id == SpacePageView.headerNavID } ?? true)
                    self.check(self.c.store.space(home)?.name == "" && hidden,
                               "parityp02 singleton: the only Space renamed to nothing with real keys (⌫ ↩) hides its name row and keyboard stop "
                               + "(name “\(self.c.store.space(home)?.name ?? "?")”, hidden \(hidden))")
                    done()
                }
            }
        }
        p02Shot("parityp02-4-singleton-unnamed-hidden")
        run { [self] in
            if let s = try? c.store.createSpace(name: "Second", profileID: c.store.profile(ofSpace: home).id, after: home) { ids["second"] = s.id }
            c.reloadAll(animated: false)
            let shown = header()?.isHidden == false
            try? c.store.deleteSpace(ids["second"] ?? "")
            c.reloadAll(animated: false)
            check(shown && header()?.isHidden == true,
                  "parityp02 singleton: a second Space brings the unnamed row back (\(shown)), deleting it hides the row again (\(header()?.isHidden == true))")
            let m = c.spaceMenu(spaceID: home)
            check(fire(m, "Show Space Header") && header()?.isHidden == false,
                  "parityp02 singleton: Show Space Header shows it (\(titles(m).prefix(4)))")
        }
        uiCase(window: { self.c.window }) {
            run { [self] in _ = fire(c.spaceMenu(spaceID: home), "Rename Space…") }
            wait(0.2)
            step { [self] done in
                let keys = UIDriverClient.keys(typing: "Home") ?? []
                p02Keys("parityp02 singleton", keys + ["return"], header: nil) { ok, _, _ in
                    guard ok else { return done() }
                    self.app?.settings.values.showsSpaceHeaderOnSingleUnnamed = false
                    self.c.reloadAll(animated: false)
                    self.check(self.c.store.space(home)?.name == "Home" && header()?.isHidden == false
                               && !titles(self.c.spaceMenu(spaceID: home)).contains { $0.hasSuffix("Space Header") },
                               "parityp02 singleton: a name typed with real keys keeps the row with the switch off, and the menu no longer offers it "
                               + "(name “\(self.c.store.space(home)?.name ?? "?")”)")
                    done()
                }
            }
        }

        // Today empty; then only Favorites.
        run { [self] in
            for p in ["/today-a", "/today-b"] { _ = try? c.store.closeTab(ids[p]!) }
            c.reloadAll(animated: false)
        }
        uiCase(window: { self.c.window }) {
            step { [self] done in
                p02Click("parityp02 today empty", header: header) { ok, _, _ in
                    guard ok else { return done() }
                    let f = self.c.store.space(home)?.pinnedCollapsed == true && self.p02PinnedShown(home) == 0
                    self.check(header()?.isHidden == false && f && self.c.store.todayRows(ofSpace: home).isEmpty,
                               "parityp02 Today empty: the row shows and a real click folds the pinned rows")
                    done()
                }
            }
        }
        p02Shot("parityp02-5-today-empty-folded")
        run { [self] in
            try? c.store.updateSpace(home) { $0.pinnedCollapsed = false }
            let pid = c.store.profile(ofSpace: home).id
            if let t = try? c.store.openTab(url: base + "/fav", inSpace: home, activate: false, title: "fav") {
                try? c.store.move(.tab(t.id), to: .favorites(profileID: pid, index: 0))
            }
            for item in c.store.pinnedRoots(ofSpace: home) {
                do { try c.store.deleteItem(item.id) } catch { note("parityp02 only Favorites: removing a pinned row: \(error)") }
            }
            c.reloadAll(animated: false)
        }
        uiCase(window: { self.c.window }) {
            step { [self] done in
                let favs = self.c.store.favorites(ofProfile: self.c.store.profile(ofSpace: home).id).count
                p02Click("parityp02 only Favorites", header: header) { ok, samples, _ in
                    guard ok else { return done() }
                    let end = self.p02End(self.p02Chevron(header()!)?.contentsAreFlipped() ?? false)
                    self.check(favs >= 1 && self.c.store.pinnedRows(ofSpace: home).isEmpty && header()?.isHidden == false
                               && self.c.store.space(home)?.pinnedCollapsed == true && abs((samples.last ?? .nan) - end) < 0.01
                               && self.c.store.favorites(ofProfile: self.c.store.profile(ofSpace: home).id).count == favs,
                               "parityp02 only Favorites: with no pinned rows and no Today the row shows; a real click turns the chevron and leaves the Favorites "
                               + "(Favorites \(favs), pinned \(self.c.store.pinnedRows(ofSpace: home).count), Today \(self.c.store.todayRows(ofSpace: home).count), "
                               + "folded \(self.c.store.space(home)?.pinnedCollapsed ?? false), chevron \(String(format: "%.2f", samples.last ?? .nan)) of \(String(format: "%.2f", end)))")
                    self.p02Click("parityp02 only Favorites", header: header) { _, _, _ in done() }
                }
            }
        }
        p02Shot("parityp02-6-only-favorites")

        // For the relaunch: Home folded over two pinned rows, Second open.
        run { [self] in
            do {
                for p in ["/mail", "/docs"] {
                    let t = try c.store.openTab(url: base + p, inSpace: home, activate: false, title: String(p.dropFirst()))
                    try c.store.togglePin(t.id, inSpace: home)
                }
                let s = try c.store.createSpace(name: "Second", profileID: c.store.profile(ofSpace: home).id, after: home)
                let t = try c.store.openTab(url: base + "/notes", inSpace: s.id, activate: false, title: "notes")
                try c.store.togglePin(t.id, inSpace: s.id)
                try c.store.updateSpace(home) { $0.pinnedCollapsed = true }
                try c.store.updateSpace(s.id) { $0.pinnedCollapsed = false }
                c.reloadAll(animated: false)
                note("parityp02: left Home folded (2 pinned) and Second open (1 pinned) for parityp02-relaunch")
            } catch { check(false, "parityp02: the relaunch fixture (\(error))") }
        }
        run { server = nil; _ = server }
    }

    func parityP02RelaunchScenario() {
        func header() -> SpaceHeaderView? { c.pageView(for: c.currentSpaceID)?.header }
        var home = "", second = ""
        run { [self] in
            home = c.store.orderedSpaces.first { $0.name == "Home" }?.id ?? ""
            second = c.store.orderedSpaces.first { $0.name == "Second" }?.id ?? ""
            guard !home.isEmpty, !second.isEmpty else { return check(false, "parityp02-relaunch: Home and Second from parityp02 (\(c.store.orderedSpaces.map(\.name)))") }
            MainActor.assumeIsolated { AircMotion.reduceMotionOverride = false }
            c.switchToSpace(home, animated: false)
            c.reloadAll(animated: false)
        }
        wait(0.5)
        p02Front("parityp02-relaunch")
        run { [self] in
            guard !home.isEmpty else { return }
            let h = header()!
            let end = p02End(p02Chevron(h)?.contentsAreFlipped() ?? false)
            let a = p02Angle(p02Chevron(h), presentation: false)
            check(c.store.space(home)?.pinnedCollapsed == true && p02PinnedShown(home) == 0 && c.store.pinnedRows(ofSpace: home).count == 2,
                  "parityp02-relaunch: Home comes back folded (its 2 pinned rows hidden)")
            check(abs(a - end) < 0.01, String(format: "parityp02-relaunch: its chevron is drawn turned (%.2f rad)", a))
            check(c.store.space(second)?.pinnedCollapsed == false && p02PinnedShown(second) == 1,
                  "parityp02-relaunch: Second comes back open (per Space)")
            _ = c.pageView(for: home)?.focusKeyboard(on: SpacePageView.headerNavID)
        }
        wait(0.3)
        p02Shot("parityp02-7-relaunch-folded")
        run { [self] in c.window.makeFirstResponder(nil) }
        uiCase(window: { self.c.window }) {
            step { [self] done in
                p02Click("parityp02-relaunch", header: header) { ok, _, _ in
                    guard ok else { return done() }
                    self.check(self.c.store.space(home)?.pinnedCollapsed == false && self.p02PinnedShown(home) == 2,
                               "parityp02-relaunch: a real click opens it")
                    done()
                }
            }
        }
    }
}
#endif
