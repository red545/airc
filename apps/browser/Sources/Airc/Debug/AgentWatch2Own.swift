// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// watchfix, agentwatch2's own-agent case (owner evidence 2026-11-23, 0.1.55: Airc's own agent after a long run and
/// Continue: Watch and the pane's live card completely white while the steps ran). Part of `--script agentpane2`
/// (its fake model and pane set-up): `AIRC_AGENTPANE2_ONLY=watchlong`. The agent (fake model) navigates 18 times across
/// two sites (127.0.0.1 ↔ localhost: a new renderer each time) with go_back every fifth (back-forward cache), is
/// stopped mid-run, Continue, and navigates 16 more times. Watch is open on its page and the card shows beside it; the
/// window server's pictures of our own window are sampled 8 times a second at the fixture's cyan marker (page 0–96 pt)
/// in both, while the agent runs on the fixture (Stop closes the run's window: from Stop until Watch follows Continue's page,
/// and a page that isn't the fixture yet (a new window's about:blank), aren't counted). Checked: each shows the page in ≥ 90 % of samples after its first, never misses it for longer than 1 s, and
/// still shows it live at the end.
/// agentparallel (lead 2026-11-25): since agentmainview the agent's page is a tab of the window and the pane's card shows
/// only while another tab is selected. The case selects the person's own tab once the page is hosted (and again after
/// Continue brings the page back), and counts card samples only while another tab is selected.
extension AgentPane2Check {
    func caseWatchLong(_ done: @escaping () -> Void) {
        k.extraPages["/flicker.html"] = AgentPaneFlickerProbe.page
        let ip = k.base, lh = k.base.replacingOccurrences(of: "127.0.0.1", with: "localhost")
        var turns: [FakeModelServer.Turn] = []
        func navs(_ range: Range<Int>) {
            for i in range {
                turns.append(.tool("navigate", ["url": "\(i % 2 == 0 ? ip : lh)/flicker.html?n=\(i)"]))
                if i % 5 == 4 { turns.append(.tool("go_back", [:])) }
            }
        }
        navs(0..<18)
        let stopAt = turns.count
        turns.append(.tool("wait", ["duration": 30]))
        navs(18..<34)
        turns.append(.tool("wait", ["duration": 30]))
        turns.append(.text("Never reached."))
        k.front { [self] _ in
            k.start("watchlong", turns, task: "Look through the listings")
            wait({ AgentAttention.paneRowID != nil && AgentMainView.shared.runEntry != nil }, 20) { [self] in
                guard let row = AgentAttention.paneRowID else { check(false, "watchlong: the agent's page has a row"); return stopRun(done) }
                wlShowOwnTab()
                c.sidebar.agents.openWatch(row, takeKeys: false)
                var samples: [(t: Double, watch: Bool?, card: Bool?)] = []
                var trace: [String] = []
                let t0 = CACurrentMediaTime()
                var stopped = false, continued = false
                var stopT: Double?, followT: Double?
                func navCount() -> Int { k.events.filter { $0 == "tool navigate" || $0 == "tool go_back" }.count }
                let timer = Timer(timeInterval: 0.125, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        let s = (CACurrentMediaTime() - t0, self.wlWatchMarker(), self.wlCardMarker())
                        if let st = stopT, followT == nil, st < s.0, self.c.sidebar.agents.watch?.rowID != row { followT = s.0 }
                        // The stopped run has no page (Stop closes its window) until Continue's page is followed: not counted.
                        if let st = stopT, s.0 >= st, followT == nil { trace.append(String(format: "%.2f (stopped, not counted)", s.0)); return }
                        // Only while the agent's page is the fixture: a new window starts on about:blank (white, rightly),
                        // and after Continue the fake model may first redo the interrupted wait there.
                        let url = self.run.runWindowID.flatMap { AgentCenter.shared.windows[$0]?.activeTab?.url?.absoluteString } ?? ""
                        if !url.contains("flicker.html") { trace.append(String(format: "%.2f (page %@, not counted)", s.0, url.isEmpty ? "none" : url)); return }
                        samples.append(s)
                        let w = self.c.sidebar.agents.watch
                        trace.append(String(format: "%.2f", s.0) + " W" + (s.1.map { $0 ? "#" : "." } ?? "?") + " C" + (s.2.map { $0 ? "#" : "." } ?? "?")
                                     + " watch \(w?.rowID ?? "-") \(w?.debugLive ?? "-") card \(AgentPaneLiveView.current?.debugState ?? "-") pane \(AgentAttention.paneRowID ?? "-")")
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                // Stop mid-run once the first part has run, then Continue (the owner's sequence).
                wait({ navCount() >= stopAt - 1 && self.k.events.contains("tool wait") }, 60) { [self] in
                    stopped = true
                    stopT = CACurrentMediaTime() - t0
                    trace.append(String(format: "%.2f STOP", stopT!))
                    run.stop()
                    k.untilIdle(8) { [self] in
                        wlAfter(1) { [self] in
                            continued = true
                            trace.append(String(format: "%.2f CONTINUE", CACurrentMediaTime() - t0))
                            run.continueRun()
                            // Continue brings the page back into the main view: the person goes to their own tab again.
                            wlAfter(2) { [self] in wlShowOwnTab() }
                            wait({ navCount() >= turns.count - 3 && self.k.events.filter { $0 == "tool wait" }.count >= 2 }, 90) { [self] in
                                wlAfter(1.5) { [self] in
                                    timer.invalidate()
                                    try? trace.joined(separator: "\n").write(to: runner.dir.appendingPathComponent("watchlong-\(engine).txt"), atomically: true, encoding: .utf8)
                                    wlReport(samples, navs: navCount(), stopped: stopped, continued: continued)
                                    c.sidebar.agents.closeWatch()
                                    stopRun(done)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func wlAfter(_ s: Double, _ body: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: body) }

    private func wlReport(_ samples: [(t: Double, watch: Bool?, card: Bool?)], navs: Int, stopped: Bool, continued: Bool) {
        check(stopped && continued && navs >= 34, "watchlong: the agent ran \(navs) navigations (go_back included), stopped mid-run and continued")
        for (name, pick) in [("Watch", { (s: (t: Double, watch: Bool?, card: Bool?)) in s.watch }), ("the live card", { s in s.card })] {
            let seen = samples.compactMap { s in pick(s).map { (s.t, $0) } }
            guard let first = seen.firstIndex(where: { $0.1 }) else {
                check(false, "watchlong: \(name) shows the agent's page (\(seen.count) samples, never the page)"); continue
            }
            let after = Array(seen[first...])
            let shown = after.filter { $0.1 }.count
            var longest = 0.0, missSince: Double?
            for (t, ok) in after {
                if ok { if let m = missSince { longest = max(longest, t - m) }; missSince = nil } else if missSince == nil { missSince = t }
            }
            if let m = missSince, let last = after.last { longest = max(longest, last.0 - m) }
            let share = Double(shown) / Double(max(1, after.count))
            note("MEASURE agentpane2 \(engine) watchlong \(name): \(shown)/\(after.count) samples show the page, longest gap \(String(format: "%.2f", longest)) s")
            check(share >= 0.9 && longest <= 1.0,
                  "watchlong: \(name) shows the page through 34 navigations and a Continue (\(Int(share * 100)) % of samples, longest gap \(String(format: "%.2f", longest)) s)")
            check(after.suffix(4).contains { $0.1 }, "watchlong: \(name) still shows the page at the end")
        }
        if let w = c.sidebar.agents.watch { note("agentpane2 \(engine): watchlong Watch \(w.mode), installs \(w.liveInstalls), blank fallbacks \(w.blankFallbacks), screenshot copies \(w.screenshotCopies)") }
    }

    /// The fixture's cyan marker (page 0–96 pt) in our window's own picture at `points` of `view`.
    private func wlMarker(in view: NSView, at points: [CGPoint]) -> Bool? {
        guard ProcessInfo.processInfo.environment["AIRC_DISABLE_LEGACY_WINDOW_CAPTURE"] != "1", let w = view.window, w.windowNumber > 0,
              let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"), let main = NSScreen.screens.first else { return nil }
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let r = w.convertToScreen(view.convert(view.bounds, to: nil))
        let area = CGRect(x: r.minX, y: main.frame.maxY - r.maxY, width: r.width, height: r.height)
        guard let img = unsafeBitCast(sym, to: Fn.self)(area, 1 << 3, UInt32(w.windowNumber), 1 << 0)?.takeRetainedValue(), img.width > 8 else { return nil }
        let s = CGFloat(img.width) / max(1, view.bounds.width)
        let flipped = view.isFlipped
        let px = points.compactMap { p in AgentImages.pixel(img, x: Int(p.x * s), y: Int((flipped ? p.y : view.bounds.height - p.y) * s)) }
        guard !px.isEmpty else { return nil }
        return px.allSatisfy { $0.r < 60 && $0.g > 160 && $0.b > 160 }
    }

    /// The person picks their own tab (the fixture's home page): the agent's page parks and the pane shows its card.
    private func wlShowOwnTab() {
        guard let t = c.store.state.tabs.values.first(where: { $0.spaceID == c.currentSpaceID && $0.url.hasSuffix("/home.html") }) else {
            return note("agentpane2 \(engine): watchlong: no own tab to switch to")
        }
        if c.shownTabID != t.id { c.show(t.id, focus: false) }
    }

    private func wlWatchMarker() -> Bool? {
        guard let w = c.sidebar.agents.watch else { return nil }
        return wlMarker(in: w, at: [CGPoint(x: 30, y: 30), CGPoint(x: 60, y: 60)].map { w.viewPoint($0) })
    }

    private func wlCardMarker() -> Bool? {
        // The card exists only while another tab than the agent's is selected: not counted otherwise.
        guard !AgentMainView.shared.runShown(in: c) else { return nil }
        guard let v = AgentPaneLiveView.current, v.window != nil, v.bounds.width > 20 else { return nil }
        // The card shows the page's width across it, top-aligned: page point p at p × (card width / page width).
        let page = run.runWindowID.flatMap { AgentCenter.shared.windows[$0]?.size.width } ?? 1280
        let f = v.bounds.width / max(1, page)
        return wlMarker(in: v, at: [CGPoint(x: 30 * f, y: 30 * f), CGPoint(x: 60 * f, y: 60 * f)])
    }
}
#endif
