// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit

/// `--script feedbackbtn` (both engines): the sidebar footer reads Archive · Space icons · Feedback · + (owner,
/// 2026-11-16). Real driver clicks (AIRC_REAL_KEYS=1, the stable UI driver, AIRC_UI_DEDICATED_SESSION=1):
///   - with 1, 5 and 12 Spaces: Feedback sits just left of "+", the Space icons stay between Archive and it (or, when
///     it gives way, between Archive and "+"), centred in their region, never overlapping either button;
///   - Feedback opens the feedback sheet on this window (Cancel closes it); tooltip and VoiceOver label unchanged;
///   - "+" opens its menu (Esc closes it); Archive opens the Library and a second click in place closes it.
extension SnapshotRunner {
    func feedbackButtonScenario() {
        guard UIDriverClient.available, ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1" else {
            run { [self] in note("FAIL-ENV feedbackbtn: real input needs AIRC_REAL_KEYS=1, the stable UI driver and AIRC_UI_DEDICATED_SESSION=1") }
            return
        }
        func footer() -> SpaceBarView { c.sidebar.footer }
        func r(_ f: NSRect) -> String { "\(Int(f.minX))–\(Int(f.maxX))" }
        func activate() {
            step { [self] done in
                NSApp.activate(ignoringOtherApps: true)
                c.window.makeKeyAndOrderFront(nil)
                waitUntil({ NSApp.isActive && self.c.window.isKeyWindow }, timeout: 3) { done() }
            }
        }
        /// A real driver click at a view's centre (Quartz global coordinates, top-left origin; no --mods).
        func realClick(_ view: @escaping () -> NSView?, _ what: String, settle: Double = 0.5) {
            step { [self] done in
                c.sidebar.layoutSubtreeIfNeeded()
                guard let v = view(), let w = v.window, let primary = NSScreen.screens.first, !v.isHidden else {
                    check(false, "feedbackbtn [real click] \(what): on screen")
                    return done()
                }
                let g = w.convertPoint(toScreen: v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil))
                UIDriverClient.run(["--click", String(Double(g.x.rounded())), String(Double((primary.frame.maxY - g.y).rounded()))]) { ok, out in
                    if !ok { self.note("FAIL-ENV feedbackbtn [real click] \(what): \(out)") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: done)
                }
            }
        }
        func key(_ combo: String, _ what: String) {
            step { [self] done in
                UIDriverClient.run(["--key", combo, "--pid", "\(getpid())"]) { ok, out in
                    if !ok { self.note("FAIL-ENV feedbackbtn [real key] \(what): \(out)") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: done)
                }
            }
        }
        func renderFooter(_ name: String) {
            run { [self] in
                let v = c.sidebar
                v.layoutSubtreeIfNeeded()
                let f = footer().frame
                if let image = render(v), let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    let k = CGFloat(rep.pixelsWide) / max(1, v.bounds.width)
                    let band = CGRect(x: 0, y: (f.minY - 30) * k, width: v.bounds.width * k, height: (f.height + 30) * k)
                    if let cg = rep.cgImage?.cropping(to: band.integral) {
                        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
                        note("wrote \(name).png")
                    }
                }
            }
        }
        /// The footer's geometry for `n` Spaces at the current width.
        func layoutCheck(_ n: Int, expectFeedback: Bool) {
            run { [self] in
                c.sidebar.layoutSubtreeIfNeeded()
                let bar = footer()
                let lib = bar.libraryButton.frame, plus = bar.plusButton.frame, fb = bar.feedbackButton.frame
                let cells = bar.cellViews.map(\.frame)
                let left = cells.first?.minX ?? .infinity, right = cells.last?.maxX ?? -.infinity
                let limit = bar.showsFeedback ? fb.minX : plus.minX
                let inside = cells.isEmpty || (left >= lib.maxX - 0.5 && right <= limit + 0.5)
                let ordered = zip(cells, cells.dropFirst()).allSatisfy { $0.maxX <= $1.minX + 0.5 }
                // Centred in their region (SpaceBarLayout.region): equal room on both sides.
                let region = SpaceBarLayout.region(sidebarWidth: Double(bar.bounds.width), feedback: bar.showsFeedback)
                let centred = cells.isEmpty || abs((left - CGFloat(region.x)) - (CGFloat(region.x + region.span) - right)) < 1
                check(bar.showsFeedback == expectFeedback && cells.count == (n < 2 ? 0 : n) && inside && ordered && centred
                      && plus.maxX <= bar.bounds.maxX + 0.5 && plus.minX > lib.maxX
                      && (!bar.showsFeedback || (fb.maxX <= plus.minX + 0.5 && fb.maxX >= plus.minX - 4 && fb.minX > lib.maxX)),
                      "feedbackbtn: \(n) Space(s) at \(Int(bar.bounds.width)) pt: Archive \(r(lib)) · Spaces \(cells.isEmpty ? "-" : r(NSRect(x: left, y: 0, width: right - left, height: 1))) (\(cells.map { Int($0.width) })) · Feedback \(bar.showsFeedback ? r(fb) : "hidden") · + \(r(plus)); expected Feedback \(expectFeedback ? "shown" : "hidden"), in order, centred, no overlap")
            }
        }
        var added: [String] = []
        func setSpaces(_ n: Int) {
            run { [self] in
                for id in added { try? c.store.deleteSpace(id) }
                added = []
                let home = c.currentSpaceID
                let profile = c.store.profile(ofSpace: home).id
                let icons = ["🍎", "🍐", "🍊", "🍋", "🍌", "🍉", "🍇", "🍓", "🫐", "🍒", "🍑"]
                var after = home
                for i in 0..<max(0, n - 1) {
                    if let sp = try? c.store.createSpace(name: "Test \(i + 2)", icon: .emoji(icons[i % icons.count]), profileID: profile, after: after) {
                        added.append(sp.id)
                        after = sp.id
                    }
                }
                c.reloadAll(animated: false)
                c.sidebar.layoutSubtreeIfNeeded()
            }
            wait(0.4)
        }

        var widthBefore: CGFloat = 0
        activate()
        run { [self] in
            widthBefore = c.sidebarWidth
            c.setSidebarWidth(260)
            app?.settings.values.sidebarFeedbackButton = true
            c.sidebar.layoutSubtreeIfNeeded()
            let b = footer().feedbackButton
            check(b.toolTip == "Send Feedback" && b.accessibilityLabel() == "Send Feedback" && b.accessibilityRole() == .button,
                  "feedbackbtn: tooltip and VoiceOver label unchanged (\(b.toolTip ?? "-"), \(b.accessibilityLabel() ?? "-"))")
        }
        // 1, 5 and 12 Spaces at 260 pt: Feedback shows with 1 and 5, gives way with 12 (each icon would drop under 24 pt).
        for (n, shows) in [(1, true), (5, true), (12, false)] {
            setSpaces(n)
            layoutCheck(n, expectFeedback: shows)
            renderFooter("feedbackbtn-footer-\(n)spaces")
        }
        // The default 228 pt with 3 Spaces (the common case) and the 164 pt minimum with 1.
        setSpaces(3)
        run { [self] in c.setSidebarWidth(228) }
        layoutCheck(3, expectFeedback: true)
        renderFooter("feedbackbtn-footer-228-3spaces")
        setSpaces(1)
        run { [self] in c.setSidebarWidth(AircMetrics.Sidebar.minWidth) }
        layoutCheck(1, expectFeedback: true)
        setSpaces(5)
        run { [self] in c.setSidebarWidth(260) }
        layoutCheck(5, expectFeedback: true)

        // Feedback (5 Spaces, so it sits between the icons and +): a real click opens the sheet on this window.
        realClick({ footer().feedbackButton }, "the footer's Feedback button")
        step { [self] done in waitUntil({ FeedbackSheet.active != nil }, timeout: 4) { done() } }
        run { [self] in
            let s = FeedbackSheet.active
            check(s?.parent === c.window && s?.sheet.isVisible == true, "feedbackbtn [real click]: Feedback, left of +, opens the feedback sheet on this window")
        }
        step { [self] done in
            guard let h = FeedbackSheet.active?.sheet.contentView, let w = h.window, let p = anchorPoint("feedback.cancel", in: h),
                  let primary = NSScreen.screens.first else { FeedbackSheet.active?.close(); return done() }
            let g = w.convertPoint(toScreen: p)
            UIDriverClient.run(["--click", String(Double(g.x.rounded())), String(Double((primary.frame.maxY - g.y).rounded()))]) { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: done)
            }
        }
        run { [self] in
            if FeedbackSheet.active != nil { FeedbackSheet.active?.close() }
            check(FeedbackSheet.active == nil, "feedbackbtn [real click]: Cancel closes the sheet")
        }
        // +: a real click opens its menu (watched by didBeginTracking); a real Esc closes it.
        var plusOpened = false, plusTitles: [String] = []
        var token: NSObjectProtocol?
        run {
            token = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { n in
                guard let m = n.object as? NSMenu, m !== NSApp.mainMenu else { return }
                plusOpened = true
                plusTitles = m.items.map(\.title)
            }
        }
        realClick({ footer().plusButton }, "the footer's + button", settle: 0.8)
        key("escape", "Esc closes the + menu")
        run { [self] in
            if let t = token { NotificationCenter.default.removeObserver(t) }
            check(plusOpened && plusTitles.contains("New Space…"), "feedbackbtn [real click]: + opens its menu (\(plusTitles.prefix(4).joined(separator: ", ")))")
        }
        // Archive: a real click opens the Library; a second one in the same place (its back button) closes it.
        realClick({ footer().libraryButton }, "the footer's Archive button", settle: 1.0)
        run { [self] in check(c.library != nil, "feedbackbtn [real click]: Archive opens the Library") }
        realClick({ footer().libraryButton }, "Archive again (the Library's back button)", settle: 1.0)
        run { [self] in check(c.library == nil, "feedbackbtn [real click]: a second click in place closes the Library") }
        run { [self] in
            for id in added { try? c.store.deleteSpace(id) }
            c.reloadAll(animated: false)
            c.setSidebarWidth(widthBefore)
        }
    }
}
#endif
