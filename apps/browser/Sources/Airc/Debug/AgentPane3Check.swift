// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// agentux3, part of `--script agentpane2`: the live page card's frame-by-frame record while the agent works
/// (AgentPaneFlickerProbe), and "needs you" landing in one click from every entry point (AgentAttention).
/// `AIRC_AGENTPANE2_ONLY=flicker,needsyou` runs only these cases (after set-up).
extension AgentPane2Check {
    static var only: Set<String>? {
        guard let v = ProcessInfo.processInfo.environment["AIRC_AGENTPANE2_ONLY"], !v.isEmpty else { return nil }
        return Set(v.split(separator: ",").map { String($0) })
    }

    static func runs(_ name: String) -> Bool { only?.contains(name) ?? true }

    // MARK: Flicker

    /// The agent works on an animated fixture page for ~10 s (clicks, scrolls, one navigation) while the window
    /// server's pictures of the card are taken at 30 Hz; every picture must show the page (no blank or black frame),
    /// never older content after newer, and the page always at the same place.
    func caseFlicker(_ done: @escaping () -> Void) {
        k.extraPages["/flicker.html"] = AgentPaneFlickerProbe.page
        let b = k.base
        let turns: [FakeModelServer.Turn] = [
            .tool("navigate", ["url": "\(b)/flicker.html"]), .tool("wait", ["duration": 1.5]),
            .tool("left_click", ["coordinate": [200, 205]]), .tool("wait", ["duration": 1]),
            .tool("scroll", ["scroll_direction": "down", "scroll_amount": 5, "coordinate": [300, 400]]), .tool("wait", ["duration": 1]),
            .tool("left_click", ["coordinate": [300, 400]]), .tool("wait", ["duration": 1]),
            .tool("scroll", ["scroll_direction": "up", "scroll_amount": 3, "coordinate": [300, 400]]), .tool("wait", ["duration": 1]),
            .tool("navigate", ["url": "\(b)/flicker.html?again"]), .tool("wait", ["duration": 1.5]),
            .tool("left_click", ["coordinate": [200, 205]]), .tool("wait", ["duration": 0.5]),
            .tool("scroll", ["scroll_direction": "down", "scroll_amount": 2, "coordinate": [300, 400]]),
            .tool("wait", ["duration": 30]), .text("Never reached."),
        ]
        k.front { [self] _ in
            // agentmainview: the card shows the agent's page while the person looks at another tab (the main view
            // shows it otherwise), and the viewport is the main view's (the points stay inside it).
            let home = c.shownTabID
            k.start("flicker", turns, task: "Click around the flicker fixture")
            wait({ self.k.events.contains("tool wait") || AgentMainView.shared.runShown(in: self.c) }, 20) { [self] in
            if let home { c.show(home) }
            wait({ self.k.events.contains("tool wait") && AgentPaneLiveView.current?.window != nil && AgentPaneLiveView.current?.mode != "none" }, 20) { [self] in
                guard let v = AgentPaneLiveView.current, let w = v.window, let rect = AgentPaneFlickerProbe.rect(of: v) else {
                    check(false, "flicker: the live card shows while the agent works"); return stopRun(done)
                }
                guard AgentPaneFlickerProbe.available else {
                    note("FAIL-ENV agentpane2 \(engine): flicker: no window-server pictures (AIRC_DISABLE_LEGACY_WINDOW_CAPTURE)"); return stopRun(done)
                }
                let probe = AgentPaneFlickerProbe(window: w, rect: rect, hz: AgentPaneFlickerProbe.defaultHz)
                // cardflicker: the agent window's own picture (its top 120 pt: marker and counter) in the same tick,
                // and the hosts on every run-loop turn, to tell a blank of the card from one of the engine's output.
                let agent = run.runWindowID.flatMap { AgentCenter.shared.windows[$0] }
                if let aw = agent?.window, let main = NSScreen.screens.first {
                    let f = aw.frame
                    probe.follower = AgentPaneFlickerProbe(window: aw, rect: CGRect(x: f.minX, y: main.frame.maxY - f.maxY, width: f.width, height: 120), hz: probe.hz)
                }
                let trace = AgentPaneHostTrace(clock: { probe.elapsed }, agentWindow: { agent?.window }, card: { AgentPaneLiveView.current?.debugState ?? "none" })
                let previousTabs = agent?.onTabsChanged
                agent?.onTabsChanged = { previousTabs?(); trace.note("url \(agent?.activeTab?.url?.absoluteString ?? "-") loading \(agent?.activeTab?.isLoading == true)") }
                let views0 = AgentPaneLiveView.made
                probe.sampleState = { [weak self] in
                    let cur = AgentPaneLiveView.current
                    let id = cur.map { String(UInt(bitPattern: ObjectIdentifier($0).hashValue) % 10000) } ?? "nil"
                    return "view \(id) \(cur?.debugState ?? "none") run \(self?.run.state.isActive == true ? "active" : "idle") steps \(self?.run.steps.count ?? 0)"
                }
                let previous = run.onEvent
                var navAt: Double?
                run.onEvent = { [weak self] e in
                    previous?(e)
                    probe.event(e)
                    trace.note("event \(e)")
                    if e == "tool navigate", navAt == nil, self?.k.events.filter({ $0 == "tool navigate" }).count ?? 0 >= 2 { navAt = probe.elapsed }
                }
                // agentmainfix: the whole counter must be on the page, or its fast bits read as a slow page.
                let viewport = agent?.size ?? .zero
                check(viewport.width >= 540, "flicker: the fixture's counter fits the agent's viewport (\(Int(viewport.width)) px wide, counter to 520)")
                note("agentpane2 \(engine): flicker: card \(NSStringFromRect(v.convert(v.bounds, to: nil))) in window #\(w.windowNumber) (key \(w.isKeyWindow)), mode \(v.mode), capture \(NSStringFromRect(rect))")
                trace.start()
                probe.start(seconds: 10) { [self] in
                    run.onEvent = previous
                    trace.stop()
                    agent?.onTabsChanged = previousTabs
                    let all = probe.summary()
                    let nav = navAt.map { probe.summary(from: $0, to: $0 + 1.5) }
                    let name = "agentpane2-flicker-\(engine)"
                    probe.write(to: runner.dir, name: name)
                    try? trace.text.write(to: runner.dir.appendingPathComponent("\(name)-hosts.tsv"), atomically: true, encoding: .utf8)
                    if let f = probe.follower {
                        f.write(to: runner.dir, name: "\(name)-engine")
                        note("agentpane2 \(engine): flicker: the agent window's own picture (diagnosis, not checked): \(f.summary().line)")
                        for l in f.badLines() { note("agentpane2 \(engine): flicker engine bad frame \(l)") }
                    }
                    note("agentpane2 \(engine): flicker: \(all.line)")
                    if let nav { note("agentpane2 \(engine): flicker: around the second navigation: \(nav.line)") }
                    note("agentpane2 \(engine): flicker: live card views made during the run: \(AgentPaneLiveView.made - views0), installs \(AgentPaneLiveView.installs)")
                    for l in probe.badLines() { note("agentpane2 \(engine): flicker bad frame \(l)") }
                    for l in probe.stateChanges() { note("agentpane2 \(engine): flicker app state \(l)") }
                    check(all.frames >= 240 && all.nocapture == 0, "flicker: ≥ 240 window-server pictures of the card in 10 s (\(all.frames), \(String(format: "%.1f", all.hz)) Hz)")
                    check(all.blank + all.black + all.other == 0, "flicker: no blank, black or missing-page frames (\(all.blank) blank, \(all.black) black, \(all.other) other)")
                    check(all.stale == 0, "flicker: never older content after newer (\(all.stale) stale frames)")
                    check(all.jump == 0, "flicker: the page never jumps in the card (\(all.jump) jumps)")
                    check(AgentPaneLiveView.made - views0 == 0, "flicker: the card's picture view is never rebuilt while the agent works (\(AgentPaneLiveView.made - views0) new)")
                    if engine == "chromium" {
                        check(v.mode == "live" && all.updates >= 0.7 * all.hz,
                              "flicker: Chromium shows the page live at the page's frame rate (\(v.mode), \(String(format: "%.1f", all.updates)) updates/s at \(String(format: "%.1f", all.hz)) Hz pictures)")
                    } else {
                        check(all.updates >= 0.8 * AgentPaneLiveView.copiesPerSecond && all.maxGap <= 2.5 * max(all.medianGap, 1000 / AgentPaneLiveView.copiesPerSecond),
                              "flicker: WebKit copies come at a steady rate (\(String(format: "%.1f updates/s, gap median %.0f ms, max %.0f ms", all.updates, all.medianGap, all.maxGap)))")
                    }
                    stopRun(done)
                }
            }
            }
        }
    }

    func stopRun(_ done: @escaping () -> Void) {
        run.stop()
        k.untilIdle(8) { done() }
    }
}
#endif
