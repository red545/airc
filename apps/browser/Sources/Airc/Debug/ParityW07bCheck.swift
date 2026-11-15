// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircDesign
import AircKit

/// `--script parityw07b` (both engines; a dedicated UI session under the UI lock, `AIRC_UI_DEDICATED_SESSION=1`): W07's
/// window margins, inactive dimming and double-click, with **real** mouse input from the build Mac's stable UI driver
/// (infra/ui-driver; HID events through the window server), except where a line says "posted".
///   - every empty margin drags the window by the drag's delta: the sidebar's empty list area, its top band, the gaps
///     above, right of and below the page card, and the top of the page (page-top dragging, on by default);
///   - a drag that starts on a tab reorders the tabs and leaves the window where it is;
///   - another app's window clicked (a Finder window of an empty folder in the run's directory), the sidebar dims to
///     `SidebarView.inactiveOpacity` on a 0.2 s fade, in a light Space, a dark Space, the four saturated Spaces (ember,
///     ocean, forest, grape: their dim is clamped so text keeps its contrast floor), with Reduce Transparency and with
///     Increase Contrast (no dim); our window clicked again, it comes back to 1. The dim is measured on pixels (the layer
///     tree's render, `CALayer.render`): the fade of a tab title's ink against the window ground, and the contrast it
///     leaves (≥ 4.5:1) from the measured ground and fade;
///   - W07c (Arc's DraggableWhenInactive): with Finder in front and our window in the background, a REAL first drag from
///     each margin (the six above) moves the window by the drag, with no second drag;
///   - posted (the driver's clicks always carry click count 1, so it can't double-click): a double-click on a margin
///     does the system's "Double-click a window's title bar" action (Zoom/Fill, Minimize, nothing); on the sidebar's empty
///     list area it opens a new tab, as Arc's does.
/// Window PNGs (our views render themselves; no screen capture): w07b-active-<look>.png, w07b-inactive-<look>.png.
extension SnapshotRunner {
    func parityW07bScenario() {
        var server: LocalPageServer?
        var base = ""
        var tabs: [String] = []
        var real = false
        var home = NSRect.zero
        var finderPID: pid_t = 0
        var finderWindow: CGWindowID = 0
        let driver = UIDriverClient.path

        func screenTop() -> CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }
        /// A window point (AppKit, bottom-left origin) as the driver's global display point (top-left origin).
        func cg(_ p: NSPoint) -> CGPoint {
            let s = c.window.convertPoint(toScreen: p)
            return CGPoint(x: s.x, y: screenTop() - s.y)
        }
        func n(_ v: CGFloat) -> String { String(format: "%.1f", v) }
        /// One driver command off the main thread (AppKit keeps handling the input it posts); `done` on main.
        func drive(_ args: [String], _ done: @escaping (Bool, String) -> Void) { UIDriverClient.run(args, done) }
        /// The window on top at a window point, as the window server sees it.
        func topWindow(at p: NSPoint) -> Int { NSWindow.windowNumber(at: c.window.convertPoint(toScreen: p), belowWindowWithWindowNumber: 0) }
        /// The window's layer tree as Core Animation composites it (layer opacity included, which the window PNGs'
        /// `cacheDisplay` leaves out), so the dimmed sidebar shows. The page's own pixels aren't in it (engine layers).
        /// The layer tree rendered over opaque black (so the window's translucency can't leave holes): the pixels (RGBA,
        /// premultiplied, alpha 255) and the image. Rows come out vertically flipped (see `flipped`).
        func layerShot() -> (w: Int, h: Int, rowBytes: Int, px: [UInt8], image: CGImage)? {
            guard let layer = c.root.layer else { return nil }
            let size = c.root.bounds.size, scale: CGFloat = 2
            guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
            ctx.scaleBy(x: scale, y: scale)
            layer.presentation()?.render(in: ctx) ?? layer.render(in: ctx)
            guard let image = ctx.makeImage(), let data = ctx.data else { return nil }
            let count = ctx.bytesPerRow * ctx.height
            let px = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: count))
            return (ctx.width, ctx.height, ctx.bytesPerRow, px, image)
        }
        func layerPNG(_ name: String, _ shot: (w: Int, h: Int, rowBytes: Int, px: [UInt8], image: CGImage)? = nil) {
            guard let image = (shot ?? layerShot())?.image else { return }
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
            note("wrote \(name).png (layer tree)")
        }
        typealias Shot = (w: Int, h: Int, rowBytes: Int, px: [UInt8], image: CGImage)
        /// The row of a pixel at a root-view point (top-left origin, points). The render comes out flipped (a flipped view's
        /// layer drawn into a y-up context); `flipped` says which way this run's shots are, decided from the first
        /// measurement (the orientation where the title's band shows ink).
        func pixel(_ s: Shot, x: Int, yTop: Int, flipped: Bool) -> [Double] {
            let row = flipped ? s.h - 1 - yTop : yTop
            guard x >= 0, x < s.w, row >= 0, row < s.h else { return [0, 0, 0] }
            let i = row * s.rowBytes + x * 4
            return [Double(s.px[i]) / 255, Double(s.px[i + 1]) / 255, Double(s.px[i + 2]) / 255]
        }
        /// The ink in a band of the shot (root points, top-left origin): the ground (per-channel median) and the pixel the
        /// ink shows most at, with its ink share α = Σ(p−g)(ink−g) / Σ(ink−g)² (α = coverage × the ink's alpha). At a given
        /// pixel when `at` is set (the same place in the other shot).
        func inkShare(_ s: Shot, band: CGRect, ink: [Double], flipped: Bool, at: (Int, Int)? = nil)
            -> (pos: (Int, Int), alpha: Double, ground: [Double], spread: Double) {
            var xs: [Int] = [], ys: [Int] = []
            for y in stride(from: Int(band.minY * 2), to: Int(band.maxY * 2), by: 1) {
                for x in stride(from: Int(band.minX * 2), to: Int(band.maxX * 2), by: 1) { xs.append(x); ys.append(y) }
            }
            var chans: [[Double]] = [[], [], []]
            for (x, y) in zip(xs, ys) { let p = pixel(s, x: x, yTop: y, flipped: flipped); for k in 0..<3 { chans[k].append(p[k]) } }
            let ground = chans.map { $0.sorted()[$0.count / 2] }
            let d = (0..<3).map { ink[$0] - ground[$0] }
            let norm = d.reduce(0) { $0 + $1 * $1 }
            func share(_ p: [Double]) -> Double {
                guard norm > 1e-9 else { return 0 }
                var dot = 0.0
                for k in 0..<3 { dot += (p[k] - ground[k]) * d[k] }
                return dot / norm
            }
            if let at { return (at, share(pixel(s, x: at.0, yTop: at.1, flipped: flipped)), ground, 0) }
            var best = (0, 0), top = -Double.infinity, spread = 0.0
            for (x, y) in zip(xs, ys) {
                let a = share(pixel(s, x: x, yTop: y, flipped: flipped))
                spread += abs(a)
                if a > top { top = a; best = (x, y) }
            }
            return (best, top, ground, spread / Double(max(xs.count, 1)))
        }

        // Setup: three tabs on a loopback page, the window on one side of the screen, a Finder window on the other.
        step { [self] done in
            let page = "<!doctype html><title>w07b</title><body style='margin:0;font:16px -apple-system;background:#fff'><p style='margin:80px'>W07b</p>"
            server = LocalPageServer(pages: ["/a": page, "/b": page, "/c": page])
            server?.start { port in
                if let port { base = "http://127.0.0.1:\(port)" } else { self.check(false, "parityw07b: a loopback page server") }
                done()
            }
        }
        run { [self] in
            real = ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1" && FileManager.default.isExecutableFile(atPath: driver)
            if !real { note("FAIL-ENV parityw07b: real input needs AIRC_UI_DEDICATED_SESSION=1 and the stable UI driver at \(driver)") }
            let sid = c.currentSpaceID
            for (i, p) in ["/a", "/b", "/c"].enumerated() {
                if let t = try? c.store.openTab(url: base + p, inSpace: sid, activate: i == 2, title: "w07b " + p) { tabs.append(t.id) }
            }
            c.reloadAll(animated: false)
            if let last = tabs.last { c.show(last) }
            app?.settings.values.dragsWindowFromPageTop = true
        }
        waitForPage()
        step { [self] done in
            guard real else { return done() }
            // A Finder window of an empty folder of our own, not activated: the "other app" a click moves focus to.
            let folder = dir.appendingPathComponent("w07b-other-window", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
            NSWorkspace.shared.open([folder], withApplicationAt: finder, configuration: config) { _, _ in }
            // The dedicated session's preflight hides other apps: show Finder's windows again, without activating it.
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").forEach { $0.unhide() }
            let deadline = Date().addingTimeInterval(6)
            func look() {
                let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
                let found = list.first { ($0[kCGWindowOwnerName as String] as? String) == "Finder" && ($0[kCGWindowLayer as String] as? Int) == 0
                    && (($0[kCGWindowBounds as String] as? [String: CGFloat])?["Width"] ?? 0) > 200 }
                if let found, let b = found[kCGWindowBounds as String] as? [String: CGFloat] {
                    finderPID = (found[kCGWindowOwnerPID as String] as? Int).map { pid_t($0) } ?? 0
                    finderWindow = (found[kCGWindowNumber as String] as? Int).map { CGWindowID($0) } ?? 0
                    // Our window on the half of the screen the Finder window's middle isn't on.
                    let screen = c.window.screen ?? NSScreen.screens[0]
                    let v = screen.visibleFrame
                    let finderMidX = (b["X"] ?? 0) + (b["Width"] ?? 0) / 2
                    // Room on every side for a drag's 60 pt (macOS stops a dragged window at the screen's edge).
                    let width = min(900, v.width * 0.55), height = min(680, v.height - 200)
                    let x = finderMidX > v.midX ? v.minX + 120 : v.maxX - width - 120
                    home = NSRect(x: x, y: v.minY + (v.height - height) / 2, width: width, height: height)
                    c.window.setFrame(home, display: true)
                    note("parityw07b: Finder window \(finderWindow) (pid \(finderPID)) at \(b), ours at \(NSStringFromRect(home)) on a \(NSStringFromRect(v)) screen")
                    return done()
                }
                if Date() < deadline { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: look) } else {
                    note("FAIL-ENV parityw07b: no Finder window to click")
                    home = c.window.frame
                    done()
                }
            }
            look()
        }
        wait(0.6)

        // 1. Every empty margin drags the window by the drag's delta (real drags).
        let margins: [(String, () -> NSPoint?)] = [
            ("the sidebar's empty list area", { [self] in
                let sb = c.sidebar.convert(c.sidebar.bounds, to: nil)
                // Above the footer, tray and update banner: under the last row on a three-tab Space.
                let bottom = AircMetrics.Footer.height + c.sidebar.tray.height + c.sidebar.update.height
                // The first point no other window (a leftover Finder window of an earlier run) covers.
                let points = stride(from: CGFloat(60), through: 240, by: 20).flatMap { dy in
                    [sb.midX, sb.minX + 40, sb.maxX - 40].map { NSPoint(x: $0, y: sb.minY + bottom + dy) }
                }
                return points.first { topWindow(at: $0) == c.window.windowNumber } ?? points[0]
            }),
            ("the sidebar's top band, between the toggle and Back", { [self] in
                let h = c.sidebar.header
                let t = h.toggle.convert(h.toggle.bounds, to: nil), b = h.back.convert(h.back.bounds, to: nil)
                return NSPoint(x: (t.maxX + b.minX) / 2, y: c.window.frame.height - 6)
            }),
            ("the gap above the page", { [self] in
                let card = c.card.convert(c.card.bounds, to: nil)
                return NSPoint(x: card.midX, y: card.maxY + AircMetrics.Window.cardInset / 2)
            }),
            ("the gap right of the page", { [self] in
                let card = c.card.convert(c.card.bounds, to: nil)
                return NSPoint(x: card.maxX + AircMetrics.Window.cardInset / 2 + 1, y: card.midY)
            }),
            ("the gap below the page", { [self] in
                let card = c.card.convert(c.card.bounds, to: nil)
                return NSPoint(x: card.midX, y: card.minY - AircMetrics.Window.cardInset / 2 - 1)
            }),
            ("the top of the page (page-top dragging)", { [self] in
                let s = c.card.dragStrip!
                let r = s.convert(s.activeRect, to: nil)
                return r.isEmpty ? nil : NSPoint(x: r.midX, y: r.midY)
            }),
        ]
        for (name, point) in margins {
            uiCase(window: { self.c.window }) {
                run { [self] in uiAttempt?.needsKeyWindow = false }
                step { [self] done in
                    guard real else { return done() }
                    c.window.setFrame(home, display: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        guard let p = point() else { self.check(false, "parityw07b: \(name): a point to press"); return done() }
                        let frame = self.c.window.contentView!.superview!
                        let hit = frame.hitTest(frame.convert(p, from: nil))
                        guard topWindow(at: p) == self.c.window.windowNumber else {
                            self.note("FAIL-ENV parityw07b real drag from \(name): another window is over ours there")
                            return done()
                        }
                        let before = self.c.window.frame
                        let start = cg(p), d = CGPoint(x: 60, y: 40)
                        drive(["--drag", n(start.x), n(start.y), n(start.x + d.x), n(start.y + d.y)]) { ok, out in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                let after = self.c.window.frame
                                let dx = after.minX - before.minX, dy = before.maxY - after.maxY
                                guard ok else {
                                    self.note("FAIL-ENV parityw07b real drag from \(name): the driver refused (\(out))")
                                    return done()
                                }
                                self.check(abs(dx - d.x) <= 1 && abs(dy - d.y) <= 1 && after.size == before.size,
                                           "parityw07b: real drag from \(name) (\(Self.describe(hit))) moves the window by the drag "
                                           + "(\(n(dx)), \(n(dy)) for \(n(d.x)), \(n(d.y)); size \(NSStringFromSize(before.size)) → \(NSStringFromSize(after.size)))")
                                self.c.window.setFrame(home, display: true)
                                done()
                            }
                        }
                    }
                }
            }
        }

        // 2. A drag that starts on a tab reorders the tabs; the window stays.
        uiCase(window: { self.c.window }) {
            run { [self] in uiAttempt?.needsKeyWindow = false }
            step { [self] done in
                guard real else { return done() }
                let sid = c.currentSpaceID
                let order = c.store.todayTabs(ofSpace: sid).map(\.id).filter { tabs.contains($0) }
                guard order.count == 3, let page = c.pageView(for: sid),
                      let first = page.rows[order[0]], let third = page.rows[order[2]] else {
                    check(false, "parityw07b: three tab rows (\(order.count))"); return done()
                }
                let a = first.convert(NSPoint(x: first.bounds.midX, y: first.bounds.midY), to: nil)
                // Past the third row's middle: the dragged tab lands after it.
                let t = third.convert(third.bounds, to: nil)
                let b = NSPoint(x: t.midX, y: t.minY + 3)
                let before = c.window.frame
                let s = cg(a), e = cg(b)
                drive(["--drag", n(s.x), n(s.y), n(e.x), n(e.y)]) { ok, out in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        guard ok else { self.note("FAIL-ENV parityw07b real tab drag: the driver refused (\(out))"); return done() }
                        let now = self.c.store.todayTabs(ofSpace: sid).map(\.id).filter { tabs.contains($0) }
                        let title = { (id: String) in self.c.store.tab(id)?.title ?? id }
                        self.check(now != order && now.last == order[0] && self.c.window.frame == before,
                                   "parityw07b: a real drag that starts on a tab reorders the tabs (\(order.map(title)) → \(now.map(title))) "
                                   + "and leaves the window where it is (\(NSStringFromRect(before)) → \(NSStringFromRect(self.c.window.frame)))")
                        done()
                    }
                }
            }
        }

        // 3. Inactive dimming: a light Space, a dark Space, the saturated Spaces, Reduce Transparency, Increase Contrast.
        var original: AircKit.SpaceTheme?
        run { [self] in original = c.store.space(c.currentSpaceID)?.theme }
        /// A point of the Finder window that none of ours covers (global display point, top-left origin); nil, noted, if none.
        func otherAppPoint(_ label: String) -> CGPoint? {
            let list = (CGWindowListCopyWindowInfo([.optionIncludingWindow], finderWindow) as? [[String: Any]]) ?? []
            guard let b = list.first?[kCGWindowBounds as String] as? [String: CGFloat] else {
                note("FAIL-ENV parityw07b \(label): the Finder window is gone"); return nil
            }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            let ours = c.window.frame
            let candidates = stride(from: r.minX + 30, to: r.maxX - 30, by: 40).map { CGPoint(x: $0, y: r.minY + r.height * 0.6) }
            // Away from our window (and its shadow); the click proves itself: Finder must come to the front.
            guard let p = candidates.first(where: { q in !ours.insetBy(dx: -30, dy: -30).contains(NSPoint(x: q.x, y: screenTop() - q.y)) })
            else { note("FAIL-ENV parityw07b \(label): no point of the Finder window away from ours"); return nil }
            return p
        }
        /// The pixel measurement of the fade: a plain tab row's title (`palette.textPrimary`: the `text` ink) in the active
        /// and the inactive render of the layer tree. The fade is the ratio of the ink's share at the title's strongest
        /// pixel (coverage cancels), and the contrast it leaves is the ink at (its alpha × that fade) on the measured
        /// inactive ground, against the design system's floor.
        func measureDim(_ look: String, _ a: Shot?, _ i: Shot?, expected: CGFloat) {
            let sid = c.currentSpaceID
            let shown = c.shownTabID
            guard let a, let i, let page = c.pageView(for: sid),
                  let id = tabs.first(where: { $0 != shown && page.rows[$0] != nil }), let row = page.rows[id] else {
                note("FAIL-ENV parityw07b \(look): no plain tab row to measure on"); return
            }
            let r = c.currentPalette.resolved
            let ink = [r.text.red, r.text.green, r.text.blue]
            let f = c.root.convert(row.bounds, from: row)
            let band = CGRect(x: f.minX + 34, y: f.minY + 3, width: max(20, f.width - 80), height: max(8, f.height - 6))
            let up = inkShare(a, band: band, ink: ink, flipped: false), down = inkShare(a, band: band, ink: ink, flipped: true)
            let flip = down.alpha > up.alpha
            let ma = flip ? down : up
            guard ma.alpha > 0.15 else {
                note("FAIL-ENV parityw07b \(look): no title ink found in the row's band \(band) (best share \(String(format: "%.2f", ma.alpha)))")
                return
            }
            let mi = inkShare(i, band: band, ink: ink, flipped: flip, at: ma.pos)
            let k = mi.alpha / ma.alpha
            let e = Double(expected)
            let ground = AircColor(red: mi.ground[0], green: mi.ground[1], blue: mi.ground[2])
            let shownInk = AircColor(red: r.text.red, green: r.text.green, blue: r.text.blue).alpha(r.text.alpha * k)
            let contrast = shownInk.contrast(on: ground)
            let activeGround = AircColor(red: ma.ground[0], green: ma.ground[1], blue: ma.ground[2])
            let activeContrast = r.text.contrast(on: activeGround)
            func s(_ v: Double) -> String { String(format: "%.3f", v) }
            check(abs(k - e) <= 0.03,
                  "parityw07b \(look): the title's ink fades by \(s(k)) in the layer render (share \(s(ma.alpha)) → \(s(mi.alpha)) "
                  + "at pixel \(ma.pos), \(flip ? "flipped" : "upright") render), the dim is \(s(e))")
            check(contrast >= ResolvedTheme.Floor.text - 0.05,
                  "parityw07b \(look): the dimmed title keeps its contrast floor, measured on pixels: \(String(format: "%.2f", contrast)):1 "
                  + "(ink alpha \(s(r.text.alpha)) × \(s(k)) on the measured ground \(ground); active \(String(format: "%.2f", activeContrast)):1; "
                  + "floor \(ResolvedTheme.Floor.text))")
        }
        let looks: [(name: String, preset: String, reduce: Bool, increase: Bool)] = [
            ("light", "sky", false, false), ("dark", "midnight", false, false), ("reduce-transparency", "midnight", true, false),
            ("ember", "ember", false, false), ("ocean", "ocean", false, false), ("forest", "forest", false, false),
            ("grape", "grape", false, false), ("increase-contrast", "ember", false, true),
        ]
        var activeShot: Shot?
        for look in looks {
            run { [self] in
                try? c.store.updateSpace(c.currentSpaceID) { $0.theme = DesignTheme.preset(look.preset)!.model }
                MainActor.assumeIsolated {
                    AircTranslucency.reduceTransparencyOverride = look.reduce ? true : nil
                    AircTranslucency.increaseContrastOverride = look.increase ? true : nil
                }
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
            }
            wait(0.6)
            uiCase(window: { self.c.window }) {
                run { [self] in uiAttempt?.needsKeyWindow = false; uiAttempt?.needsUncoveredWindow = false }
                step { [self] done in
                    guard real else { return done() }
                    let main = c.window.isMainWindow, active = NSApp.isActive
                    check(main && c.sidebar.dimmedTo == 1 && c.sidebar.pager.alphaValue == 1,
                          "parityw07b \(look.name): the active window's sidebar isn't dimmed (main \(main), app active \(active), "
                          + "content \(c.sidebar.pager.alphaValue))")
                    activeShot = layerShot()
                    layerPNG("w07b-layers-active-\(look.name)", activeShot)
                    captureNow("w07b-active-\(look.name)", done)
                }
                step { [self] done in
                    guard real, finderWindow != 0 else { return done() }
                    guard let p = otherAppPoint(look.name) else { return done() }
                    let topThere = NSWindow.windowNumber(at: NSPoint(x: p.x, y: screenTop() - p.y), belowWindowWithWindowNumber: 0)
                    note("parityw07b \(look.name): clicking the Finder window at \(p) (top window there \(topThere), Finder's \(finderWindow))")
                    let target = SidebarView.inactiveOpacity(for: c.currentPalette.resolved, increaseContrast: look.increase)
                    drive(["--click", n(p.x), n(p.y)]) { ok, out in
                        guard ok else { self.note("FAIL-ENV parityw07b \(look.name): the driver refused the click (\(out))"); return done() }
                        // Mid-fade, then settled.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                            let mid = self.c.sidebar.pager.layer?.presentation()?.opacity
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                let front = NSWorkspace.shared.frontmostApplication
                                let alpha = self.c.sidebar.pager.alphaValue
                                let views: [NSView] = [self.c.sidebar.header, self.c.sidebar.pager, self.c.sidebar.footer]
                                // Increase Contrast: no dim. Otherwise a dim between 0.85 and 1 (the clamp).
                                let range = look.increase ? target == 1 : (target >= 0.85 && target < 1)
                                self.check(!self.c.window.isMainWindow && front?.processIdentifier == finderPID
                                           && abs(alpha - target) < 0.005 && range && views.allSatisfy { abs($0.alphaValue - target) < 0.005 },
                                           "parityw07b \(look.name): a real click on another app's window (front: \(front?.localizedName ?? "?")) dims the "
                                           + "sidebar: header, rows and footer at \(String(format: "%.3f", alpha)) (expected \(String(format: "%.3f", target))); "
                                           + "mid-fade \(mid.map { String(format: "%.3f", $0) } ?? "-")"
                                           + (look.reduce ? "; Reduce Transparency on (\(AircTranslucency.systemReducesTransparency))" : "")
                                           + (look.increase ? "; Increase Contrast on (\(AircTranslucency.systemIncreasesContrast))" : ""))
                                let shot = layerShot()
                                layerPNG("w07b-layers-inactive-\(look.name)", shot)
                                measureDim(look.name, activeShot, shot, expected: target)
                                self.captureNow("w07b-inactive-\(look.name)", done)
                            }
                        }
                    }
                }
                step { [self] done in
                    guard real, finderWindow != 0 else { return done() }
                    // Back: a real click on an empty margin of ours that no other window covers (sidebar, right, bottom).
                    let picks = [margins[0], margins[3], margins[4]].compactMap { $0.1() }
                    guard let q = picks.first(where: { topWindow(at: $0) == c.window.windowNumber }) else {
                        note("FAIL-ENV parityw07b \(look.name): every margin of ours is under another window"); return done()
                    }
                    let p = cg(q)
                    drive(["--click", n(p.x), n(p.y)]) { ok, out in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            guard ok else { self.note("FAIL-ENV parityw07b \(look.name): the driver refused the click back (\(out))"); return done() }
                            let a = self.c.sidebar.pager.alphaValue
                            self.check(self.c.window.isMainWindow && NSApp.isActive && a == 1 && self.c.sidebar.dimmedTo == 1,
                                       "parityw07b \(look.name): a real click back on our window brings the sidebar back (main \(self.c.window.isMainWindow), "
                                       + "content \(a))")
                            done()
                        }
                    }
                }
            }
        }
        run { [self] in
            MainActor.assumeIsolated {
                AircTranslucency.reduceTransparencyOverride = nil
                AircTranslucency.increaseContrastOverride = nil
            }
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
            if let original { try? c.store.updateSpace(c.currentSpaceID) { $0.theme = original } }
        }

        // 3b. W07c (Arc's DraggableWhenInactive): with another app (Finder) in front and our window in the background, a real
        // FIRST drag from each margin moves the window by the drag: no click to activate first, no second drag.
        for (name, point) in margins {
            uiCase(window: { self.c.window }) {
                run { [self] in uiAttempt?.needsKeyWindow = false; uiAttempt?.needsUncoveredWindow = false }
                step { [self] done in
                    guard real, finderWindow != 0 else { return done() }
                    c.window.setFrame(home, display: true)
                    guard let p = otherAppPoint("W07c " + name) else { return done() }
                    drive(["--click", n(p.x), n(p.y)]) { ok, out in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                            if !ok { self.note("FAIL-ENV parityw07b W07c \(name): the driver refused the click on Finder (\(out))") }
                            done()
                        }
                    }
                }
                step { [self] done in
                    guard real, finderWindow != 0 else { return done() }
                    let front = NSWorkspace.shared.frontmostApplication
                    guard front?.processIdentifier == finderPID, !c.window.isMainWindow else {
                        note("FAIL-ENV parityw07b W07c \(name): Finder isn't in front of our window (front: \(front?.localizedName ?? "?"), "
                             + "our window main \(c.window.isMainWindow))")
                        return done()
                    }
                    guard let p = point(), topWindow(at: p) == c.window.windowNumber else {
                        note("FAIL-ENV parityw07b W07c \(name): another window is over ours there"); return done()
                    }
                    let frame = c.window.contentView!.superview!
                    let hit = frame.hitTest(frame.convert(p, from: nil))
                    let firstMouse = hit?.acceptsFirstMouse(for: nil) ?? false
                    let before = c.window.frame
                    let start = cg(p), d = CGPoint(x: 60, y: 40)
                    drive(["--drag", n(start.x), n(start.y), n(start.x + d.x), n(start.y + d.y)]) { ok, out in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            guard ok else { self.note("FAIL-ENV parityw07b W07c \(name): the driver refused the drag (\(out))"); return done() }
                            let after = self.c.window.frame
                            let dx = after.minX - before.minX, dy = before.maxY - after.maxY
                            self.check(abs(dx - d.x) <= 1 && abs(dy - d.y) <= 1 && after.size == before.size,
                                       "parityw07b W07c: the first real drag from \(name) (\(Self.describe(hit)), takes the first press: \(firstMouse)) on an "
                                       + "inactive window (Finder in front) moves it by the drag (\(n(dx)), \(n(dy)) for \(n(d.x)), \(n(d.y)); "
                                       + "\(self.c.window.isMainWindow ? "then active" : "still in the background"))")
                            self.c.window.setFrame(home, display: true)
                            done()
                        }
                    }
                }
                // Our window back in front for what follows.
                step { [self] done in
                    guard real, finderWindow != 0 else { return done() }
                    if c.window.isMainWindow { return done() }
                    let picks = [margins[0], margins[3], margins[4]].compactMap { $0.1() }
                    guard let q = picks.first(where: { topWindow(at: $0) == c.window.windowNumber }) else { return done() }
                    let p = cg(q)
                    drive(["--click", n(p.x), n(p.y)]) { _, _ in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: done) }
                }
            }
        }

        // 4. Double-click (posted: the driver can't double-click). Margins: the system's title-bar action.
        var doubles: [String] = []
        var drags = 0
        func doubleClick(at p: NSPoint, _ done: @escaping () -> Void) {
            let w = c.window
            for k in 0..<2 {
                for (dt, type) in [(0.0, NSEvent.EventType.leftMouseDown), (0.05, .leftMouseUp)] {
                    let timer = Timer(timeInterval: Double(k) * 0.15 + dt, repeats: false) { _ in
                        if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: k + 1,
                                                      pressure: type == .leftMouseUp ? 0 : 1) { NSApp.postEvent(e, atStart: false) }
                    }
                    RunLoop.main.add(timer, forMode: .common)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: done)
        }
        run {
            PageTopDragStrip.doubleClickOverride = { _, a in doubles.append(a) }
            PageTopDragStrip.dragOverride = { _, _ in drags += 1 }
            RootView.dragOverride = { _, _ in drags += 1 }
        }
        let doubleMargins = margins.filter { !$0.0.hasPrefix("the sidebar's empty list") }
        for setting in ["Maximize", "Minimize", "None"] {
            for (name, point) in doubleMargins {
                uiCase(window: { self.c.window }) {
                    run { [self] in uiAttempt?.needsKeyWindow = false; doubles = []; drags = 0; PageTopDragStrip.doubleClickSetting = setting }
                    step { [self] done in
                        guard let p = point() else { check(false, "parityw07b: \(name): a point"); return done() }
                        let before = c.window.frame
                        doubleClick(at: p) {
                            let after = self.c.window.frame
                            // The title-bar band may be the window frame's own (AppKit then does the system's action itself:
                            // only the default Zoom, which this Mac's setting gives, can be told from a moved frame).
                            let system = PageTopDragStrip.doubleClickAction
                            let byFrame = doubles.isEmpty && after != before && setting == system
                            self.check(doubles == [setting] || byFrame,
                                       "parityw07b: a posted double-click on \(name) does the title-bar action \(setting) asks for "
                                       + "(\(byFrame ? "AppKit's own title bar, the window zoomed" : "\(doubles)"); presses on the margin \(drags))")
                            if after != before { self.c.window.setFrame(home == .zero ? before : home, display: true) }
                            done()
                        }
                    }
                }
            }
        }
        // The sidebar's empty list area: a new tab (Arc).
        uiCase(window: { self.c.window }) {
            run { [self] in uiAttempt?.needsKeyWindow = false; doubles = []; PageTopDragStrip.doubleClickSetting = "Maximize" }
            step { [self] done in
                guard let p = margins[0].1() else { return done() }
                doubleClick(at: p) {
                    let open = self.c.isCommandBarOpen(mode: .newTab)
                    self.check(open && doubles.isEmpty, "parityw07b: a posted double-click on the sidebar's empty list area opens a new tab, "
                               + "as Arc's does (New Tab open \(open), title-bar actions \(doubles))")
                    if open { self.c.closeCommandBar() }
                    done()
                }
            }
        }
        run { [self] in
            PageTopDragStrip.doubleClickOverride = nil
            PageTopDragStrip.dragOverride = nil
            PageTopDragStrip.doubleClickSetting = nil
            RootView.dragOverride = nil
            note("parityw07b: this Mac's title-bar double-click: \(PageTopDragStrip.doubleClickAction)")
        }
        // Close our Finder window (it's the key Finder window: the last click on Finder was on it).
        step { [self] done in
            guard real, finderPID != 0 else { server?.stop(); return done() }
            let list = (CGWindowListCopyWindowInfo([.optionIncludingWindow], finderWindow) as? [[String: Any]]) ?? []
            guard !list.isEmpty else { server?.stop(); return done() }
            NSRunningApplication(processIdentifier: finderPID)?.activate(options: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == finderPID
                guard front else { self.note("parityw07b: left the Finder window open (Finder isn't in front)"); server?.stop(); return done() }
                drive(["--key", "cmd+w", "--pid", String(finderPID)]) { ok, out in
                    self.note("parityw07b: closed the Finder window (\(ok ? "ok" : out))")
                    server?.stop()
                    done()
                }
            }
        }
    }
}
#endif
