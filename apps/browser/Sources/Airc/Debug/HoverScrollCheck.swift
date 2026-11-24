// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script hoverscroll`, both engines: a long Today list scrolled under a resting pointer shows hover on exactly one
/// row, the one under the pointer, during and after the scroll, and on none once the pointer leaves the sidebar.
///
/// - 40 synthetic Today tabs (data: pages, none loads); the real pointer moves onto a row with the UI driver (`--move`).
/// - Scrolls with the pointer still: wheel steps (36 pt) down and up, a burst of 10 at once, and 14 trackpad-sized
///   6 pt steps. The driver has no wheel command, so the scroll events are CGEvent-built NSEvents. A probe tries the
///   app's event queue first; on buildmac those events carry no window (window 0, screen-point location) and never reach
///   the list, so they go to the list's scrollWheel(with:) and the log says so. AppKit's tracking areas still see the
///   real, resting pointer, which is what the bug was about. Phased (began/changed/ended) gestures can't be delivered
///   from inside the app; the bounds-change path they'd take is the same.
/// - Every bounds change of the list's clip view is sampled (after the page's own handler): the rows that report hover,
///   and the ✕/copy buttons shown, against the row the pointer is over by geometry. Rows are 40 pt on a 41 pt pitch:
///   on that 1 pt gap, none or one of the two neighbours is right (AppKit's tracking areas include their edges).
/// - `AIRC_HOVERSCROLL_OFF=1` turns the fix off (the before arm: rows the list scrolled past keep their hover).
/// Needs `AIRC_REAL_KEYS=1 AIRC_REAL_CLICKS=1 AIRC_UI_DEDICATED_SESSION=1`. Zero-guard: fewer assertions than expected
/// is red.
extension SnapshotRunner {
    func hoverScrollScenario() {
        let tag = "hoverscroll \(app?.engine.name ?? "?")\(SpacePageView.hoverSyncOff ? " (fix off)" : "")"
        var asserted = 0
        func expect(_ ok: Bool, _ what: String) { asserted += 1; check(ok, "\(tag): \(what)") }
        var space = ""
        func page() -> SpacePageView? { c.pageView(for: space) }
        func describe(_ r: SidebarRowView?) -> String {
            guard let r else { return "none" }
            return (r as? TabRowView)?.spokenTitle ?? String(describing: type(of: r))
        }
        /// The row the real pointer is over, by geometry (the list's visible part only).
        func underPointer() -> SidebarRowView? {
            guard let p = page(), let w = p.window else { return nil }
            let pt = w.mouseLocationOutsideOfEventStream
            let clip = p.scrollView.contentView
            guard clip.bounds.contains(clip.convert(pt, from: nil)) else { return nil }
            return p.rows.values.first { !$0.isHidden && $0.superview === p.list && $0.convert($0.bounds, to: nil).contains(pt) }
        }
        /// Rows are 40 pt on a 41 pt pitch: on the 1 pt between two rows AppKit's tracking areas (edges included) may give
        /// either neighbour the hover. Those rows, for a pointer that no row strictly contains.
        func edgeRows() -> [SidebarRowView] {
            guard let p = page(), let w = p.window else { return [] }
            let pt = w.mouseLocationOutsideOfEventStream
            return p.rows.values.filter { !$0.isHidden && $0.superview === p.list && $0.convert($0.bounds, to: nil).insetBy(dx: 0, dy: -1).contains(pt) }
        }
        func hovered() -> [SidebarRowView] { page()?.rows.values.filter(\.isHovered) ?? [] }
        func buttonsShown() -> Int {
            page()?.rows.values.filter { ($0 as? TabRowView)?.copyButton.map { !$0.isHidden } ?? false }.count ?? 0
        }
        /// One sample: exact (hovered == [the row under the pointer]), how many rows show hover and ✕.
        /// On the gap between two rows (no row under the pointer): none, or one of those two, is right.
        struct Sample { let exact: Bool; let hovered: Int; let buttons: Int; let onGap: Bool; let detail: String }
        func sample() -> Sample {
            let h = hovered(), u = underPointer()
            let edge = u == nil ? edgeRows() : []
            let exact = u.map { u in h.count == 1 && h[0] === u } ?? (h.count <= 1 && h.allSatisfy { r in edge.contains { $0 === r } })
            let b = buttonsShown()
            return Sample(exact: exact && b == h.filter { $0 is TabRowView }.count, hovered: h.count, buttons: b, onGap: u == nil,
                          detail: "hovered [\(h.map(describe).joined(separator: ", "))], under \(describe(u))"
                          + (u == nil ? " (on the gap between \(edge.map(describe).joined(separator: " and ")))" : "") + ", ✕ on \(b)")
        }
        var samples: [Sample] = []
        var observer: NSObjectProtocol?
        func startSampling() {
            samples = []
            guard let clip = page()?.scrollView.contentView else { return }
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { _ in
                samples.append(sample())
            }
        }
        func stopSampling(_ what: String, minSamples: Int) {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            let bad = samples.filter { !$0.exact }
            note("\(tag): \(what): \(samples.count) samples during the scroll, \(bad.count) not exact, most rows hovered "
                 + "\(samples.map(\.hovered).max() ?? 0), most ✕ shown \(samples.map(\.buttons).max() ?? 0)")
            expect(samples.count >= minSamples, "\(what): the list scrolled (\(samples.count) bounds changes, ≥ \(minSamples))")
            expect(bad.isEmpty, "\(what): during the scroll, every sample has exactly the row under the pointer hovered "
                   + "(\(samples.count - bad.count)/\(samples.count)\(bad.first.map { "; first off: " + $0.detail } ?? ""))")
            expect((samples.map(\.hovered).max() ?? 0) <= 1, "\(what): never more than one row hovered during the scroll")
        }
        func settled(_ what: String) {
            wait(0.6)
            run { [self] in
                let s = sample()
                note("\(tag): \(what): \(s.detail)")
                expect(s.exact && (s.hovered == 1 || s.onGap), "\(what): exactly one row hovered, the one under the pointer, with its ✕ (\(s.detail))")
            }
        }
        /// How the scroll events reach the list: `queue` (NSApp.postEvent, dispatched as the window server's are) unless
        /// the probe finds the window doesn't route them to the list; then `scrollView` (the list's scrollWheel(with:)).
        var delivery = "queue"
        /// -1 when a negative wheel delta moves the list up here (the probe finds out): deltas below are "down" as < 0.
        var sign: Int32 = 1
        func wheel(_ d: Int32, phase: CGScrollPhase?) -> NSEvent? {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: d, wheel2: 0, wheel3: 0) else { return nil }
            if let at = CGEvent(source: nil)?.location { cg.location = at }
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(c.window.windowNumber))
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(c.window.windowNumber))
            if let phase {
                cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            }
            return NSEvent(cgEvent: cg)
        }
        func deliver(_ e: NSEvent) {
            if delivery == "queue" { NSApp.postEvent(e, atStart: false) } else { page()?.scrollView.scrollWheel(with: e) }
        }
        /// Scroll events at the real pointer's place.
        func post(_ deltas: [Int32], phases: [CGScrollPhase?] = []) {
            run {
                for (i, d) in deltas.enumerated() {
                    if let e = wheel(d * sign, phase: i < phases.count ? phases[i] : nil) { deliver(e) }
                }
            }
        }
        /// One wheel step each way: does it reach the list? What the app saw of it goes in the log.
        func probe(_ mode: String) {
            var origin: CGFloat = 0
            var seen: [String] = []
            var monitor: Any?
            var active = false
            run { [self] in
                // The fallback probes only when the queue didn't reach the list.
                active = mode == "queue" || delivery == "none"
                guard active else { return }
                delivery = mode
                origin = page()?.scrollView.contentView.bounds.minY ?? 0
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [self] e in
                    let hit = e.window?.contentView?.hitTest(e.locationInWindow)
                    seen.append("window \(e.window?.windowNumber ?? 0) (ours \(c.window.windowNumber)), at \(NSStringFromPoint(e.locationInWindow)), "
                                + "dy \(e.scrollingDeltaY) precise \(e.hasPreciseScrollingDeltas), hit \(hit.map { String(describing: type(of: $0)) } ?? "nil")")
                    return e
                }
                let pointer = c.window.mouseLocationOutsideOfEventStream
                note("\(tag): probe \(mode): pointer in window \(NSStringFromPoint(pointer))")
            }
            // At the top only one direction can move the list: -36 first, then +36 if that didn't.
            run { if active, let e = wheel(-36, phase: nil) { deliver(e) } }
            wait(0.25)
            run { [self] in
                guard active, (page()?.scrollView.contentView.bounds.minY ?? 0) == origin else { return }
                sign = -1
                if let e = wheel(36, phase: nil) { deliver(e) }
            }
            wait(0.25)
            run { [self] in
                guard active else { return }
                if let monitor { NSEvent.removeMonitor(monitor) }
                let moved = (page()?.scrollView.contentView.bounds.minY ?? 0) - origin
                note("\(tag): probe \(mode): list moved \(moved) pt (sign \(sign)); events seen: \(seen.isEmpty ? "none" : seen.joined(separator: " | "))")
                if moved == 0 { delivery = "none"; sign = 1 }
            }
        }

        func wheelSteps(_ n: Int, _ d: Int32) {
            for _ in 0..<n { post([d]); wait(0.05) }
        }
        func pointer(_ what: String, _ at: @escaping () -> NSPoint?) {
            step { [self] done in
                guard let p = at() else { expect(false, "\(what): a point to move to"); return done() }
                UIDriverClient.move(p, in: c.window, steps: 12, duration: 150) { good, out in
                    if !good { expect(false, "real pointer \(what): \(out.prefix(160))") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: done)
                }
            }
        }

        guard UIDriverClient.available, ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1" else {
            run { [self] in note("FAIL \(tag): needs the UI driver in a dedicated session (AIRC_REAL_KEYS=1, AIRC_UI_DEDICATED_SESSION=1)") }
            return
        }
        waitForPage()
        run { [self] in
            let store = c.store
            space = store.selectedSpace.id
            do {
                for k in 1...40 {
                    _ = try store.openTab(url: Self.page("Hover \(k)"), inSpace: space, activate: false, title: "Hover \(k)")
                }
            } catch { expect(false, "seeding 40 Today tabs (\(error))") }
            c.window.setFrame(NSRect(x: 220, y: 140, width: 1000, height: 640), display: true)
            c.reloadAll(animated: false)
            c.root.layoutSubtreeIfNeeded()
            page()?.scrollView.contentView.scroll(to: .zero)
            page()?.scrollView.reflectScrolledClipView(page()!.scrollView.contentView)
            let tabs = page()?.rows.values.filter { $0 is TabRowView }.count ?? 0
            let clipH = page()?.scrollView.contentView.bounds.height ?? 0
            let docH = page()?.list.frame.height ?? 0
            note("\(tag): \(tabs) tab rows, list \(Int(docH)) pt in a \(Int(clipH)) pt viewport")
            expect(tabs >= 40 && docH > clipH + 400, "40 Today tabs and a list that scrolls (\(tabs) rows, \(Int(docH)) pt in \(Int(clipH)) pt)")
        }
        activateForRealInput()
        // Onto a tab row a third of the way down the viewport, left of where ✕ and copy show.
        pointer("onto a row") { [self] in
            guard let p = page() else { return nil }
            let clip = p.scrollView.contentView
            let y = clip.bounds.minY + clip.bounds.height / 3
            guard let r = p.rows.values.first(where: { $0 is TabRowView && $0.frame.minY <= y && $0.frame.maxY > y }) else { return nil }
            return r.convert(NSPoint(x: r.bounds.minX + 70, y: r.bounds.midY), to: nil)
        }
        run { [self] in
            let s = sample()
            note("\(tag): resting on a row: \(s.detail)")
            expect(underPointer() is TabRowView && s.exact && s.hovered == 1, "the pointer on a row hovers that row only (\(s.detail))")
        }

        probe("queue")
        probe("scrollView")
        run { [self] in
            if delivery == "none" { expect(false, "scroll events reach the list (neither the queue nor scrollWheel(with:) moved it)") }
            note("\(tag): scroll events delivered by \(delivery == "queue" ? "the app's event queue (NSApp.postEvent)" : "the list's scrollWheel(with:)")")
        }
        settled("after the probe")
        run { startSampling() }
        wheelSteps(8, -36)
        wait(0.3)
        run { stopSampling("wheel down, 8 steps", minSamples: 4) }
        settled("after the wheel down")

        run { startSampling() }
        wheelSteps(5, 36)
        wait(0.3)
        run { stopSampling("wheel up, 5 steps", minSamples: 3) }
        settled("after the wheel up")

        // Ten steps posted at once (a fast flick of the wheel): one run-loop turn handles them all.
        run { startSampling() }
        post(Array(repeating: -30, count: 10))
        wait(0.3)
        // NSScrollView applies the 10 at once: one bounds change.
        run { stopSampling("a burst of 10 wheel steps", minSamples: 1) }
        settled("after the burst")

        // Trackpad-sized steps: 14 precise 6 pt deltas, 16 ms apart (phased gestures can't be delivered from inside the
        // app: NSScrollView takes a began only from the window server's event stream).
        run { startSampling() }
        for _ in 0..<14 { post([-6]); wait(0.016) }
        wait(0.3)
        run { stopSampling("fine trackpad-sized steps", minSamples: 8) }
        settled("after the fine steps")

        // The pointer leaves the sidebar: nothing hovered.
        pointer("onto the page") { [self] in c.card.convert(NSPoint(x: c.card.bounds.midX, y: c.card.bounds.midY), to: nil) }
        run { [self] in
            let h = hovered(), b = buttonsShown()
            expect(h.isEmpty && b == 0, "pointer off the sidebar: no row hovered (\(h.count): \(h.map(describe).joined(separator: ", ")); ✕ on \(b))")
        }
        // And a scroll of the list from code while the pointer is away (keeping the selected tab in view) hovers nothing.
        run { [self] in
            guard let p = page() else { return }
            p.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 120))
            p.scrollView.reflectScrolledClipView(p.scrollView.contentView)
        }
        wait(0.3)
        run { [self] in
            let h = hovered()
            expect(h.isEmpty && buttonsShown() == 0, "the list moved with the pointer off the sidebar: still none hovered (\(h.count))")
            expect(asserted >= 20, "zero-guard: \(asserted) assertions made (20 expected)")
        }
    }
}
#endif
