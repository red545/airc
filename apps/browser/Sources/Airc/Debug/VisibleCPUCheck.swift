// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit

/// visiblecpu: what a visible, idle page costs in front. Chrome draws only what changes; so must we. A page with one
/// small composited animation (a copy of Wikipedia's "pulsating dot", the one animation perf13's Wikipedia page runs)
/// and a static page are shown in the front window at a fixed window frame, with the sidebar shown and hidden. Each
/// case settles, then the CPU time of the app, its Chromium helpers (proc_pid_rusage) and the WindowServer (`ps`) is
/// read over AIRC_VISIBLECPU_SECONDS (default 15; the run must end within the watchdog's 240 s). No script runs in the
/// measured page during the window (a rAF counter would itself make the page draw every frame). On WebKit the CPU
/// covers the app only: WebKit's web-content processes aren't our children.
///
/// AIRC_VISIBLECPU_URLS (`|`-separated) adds pages (e.g. the real Wikipedia page). AIRC_VISIBLECPU_FRAME "x,y,w,h"
/// (screen points, origin top-left of the main screen) sets the window frame; default 1440×900 at the top left.
/// AIRC_VISIBLECPU_TRACE=1: after each case the check writes "trace <case>" to phase.txt and holds the page for 9 s,
/// for an outside CDP tracer (artifacts/visiblecpu/run/vcpu.py, `--remote-debugging-port`) to count compositor frames.
///
/// Budgets are REPORT-ONLY (they never fail): each case logs "REPORT … vs Chrome" against Chrome 157's cost of the same
/// page on the build Mac (AIRC_VISIBLECPU_CHROME_PULSE, default 10%; static 2%; artifacts/visiblecpu/REPORT.md). The
/// goal is ≤ 1.2× Chrome for the pulsing dot and ≤ 1% for the static page. Checks cover only that every case was
/// measured in front. Run it in front (AIRC_LA_AS_OWNER=1) with AIRC_KEEP_OCCLUSION=1, like hiddenpaint.
///
/// TODO(visiblecpu): turn the budgets into checks once the engine is an official build (engine/build.sh's
/// out/AircRelease args: is_official_build=true, chrome_pgo_phase=2, ThinLTO). Today's non-official engine costs
/// ~1.7× Chrome on the pulsing dot, and that gap is the engine's codegen, not app code.
extension SnapshotRunner {
    static let pulsePage = """
        <!doctype html><title>pulse</title>
        <style>body{margin:40px;font:15px -apple-system,sans-serif}#d{position:relative;left:60px;top:30px;width:0;height:0}
        #d::before,#d::after{content:'';display:block;position:absolute;border-radius:50%;background-color:#36c}
        #d::before{width:36px;height:36px;top:-18px;left:-18px;opacity:0;animation:pulse 3s ease-out infinite}
        #d::after{width:12px;height:12px;top:-6px;left:-6px}
        @keyframes pulse{0%{transform:scale(0);opacity:0}25%{transform:scale(0);opacity:.1}50%{transform:scale(.1);opacity:.3}
        75%{transform:scale(.5);opacity:.5}100%{transform:scale(1);opacity:0}}</style>
        <div id=d></div><p style="margin-top:60px">A page whose only change is a small pulsing dot.</p>
        """
    static let quietPage = "<!doctype html><title>static</title><p style='font:15px -apple-system;margin:40px'>A static page.</p>"

    func visibleCPUScenario() {
        let env = ProcessInfo.processInfo.environment
        let engine = app?.engine.name ?? "?"
        let tag = "visiblecpu \(engine)"
        let seconds = Double(env["AIRC_VISIBLECPU_SECONDS"] ?? "") ?? 15
        let chromePulse = Double(env["AIRC_VISIBLECPU_CHROME_PULSE"] ?? "") ?? 10
        let tracing = env["AIRC_VISIBLECPU_TRACE"] == "1"
        let extra = (env["AIRC_VISIBLECPU_URLS"] ?? "").split(separator: "|").map(String.init)
        var server: LocalPageServer?
        var tabs: [(name: String, id: String)] = []
        var results: [[String: Any]] = []
        let phase = dir.appendingPathComponent("phase.txt")
        func say(_ line: String) {
            let text = "\(Date().timeIntervalSince1970) \(line)\n"
            if let h = try? FileHandle(forWritingTo: phase) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close() }
            else { try? text.write(to: phase, atomically: true, encoding: .utf8) }
        }
        func visible() -> Bool { c.window.isVisible && c.window.occlusionState.contains(.visible) && c.window.isOnActiveSpace }
        func setSidebar(hidden: Bool) {
            c.animator.cancel("sidebar")
            c.sidebarHidden = hidden
            c.sidebarFraction = hidden ? 0 : 1
            c.layoutRoot()
            c.root.layoutSubtreeIfNeeded()
        }

        step { [self] done in
            if env["AIRC_LA_AS_OWNER"] == "1" {
                NSApp.activate(ignoringOtherApps: true)
                c.window.makeKeyAndOrderFront(nil)
            }
            if let screen = NSScreen.screens.first {
                let parts = (env["AIRC_VISIBLECPU_FRAME"] ?? "").split(separator: ",").compactMap { Double($0) }
                let v = screen.visibleFrame
                let (x, y, w, h) = parts.count == 4 ? (parts[0], parts[1], parts[2], parts[3]) : (v.minX - screen.frame.minX, 0, 1440, 900)
                // Top-left origin (as Chrome's --window-position) → AppKit's bottom-left.
                let top = parts.count == 4 ? screen.frame.maxY - y : v.maxY
                c.window.setFrame(NSRect(x: screen.frame.minX + x, y: top - h, width: w, height: h), display: true)
            }
            guard let s = LocalPageServer(pages: ["/pulse": Self.pulsePage, "/static": Self.quietPage]) else {
                check(false, "\(tag): the loopback server starts"); return done()
            }
            server = s
            s.start { p in
                guard let p else { self.check(false, "\(tag): the loopback server starts"); return done() }
                let base = "http://127.0.0.1:\(p)"
                let space = self.c.currentSpaceID
                do {
                    for (i, url) in extra.enumerated().reversed() {
                        tabs.insert(("page\(i + 1)", try self.c.store.openTab(url: url, inSpace: space, title: "Page \(i + 1)").id), at: 0)
                    }
                    tabs.insert(("static", try self.c.store.openTab(url: base + "/static", inSpace: space, title: "Static").id), at: 0)
                    tabs.insert(("pulse", try self.c.store.openTab(url: base + "/pulse", inSpace: space, title: "Pulse").id), at: 0)
                } catch { self.check(false, "\(tag): open the tabs (\(error))"); return done() }
                self.c.reloadAll(animated: false)
                self.c.show(tabs[0].id, focus: false)
                done()
            }
        }
        waitForPage()
        wait(2)

        /// `key`: the tab (pulse, static, page1…); its id exists once the first step has run.
        func measure(_ name: String, key: String) {
            var url = ""
            run { [self] in
                guard let id = tabs.first(where: { $0.name == key })?.id else { return }
                url = c.store.tab(id)?.url ?? key
                c.show(id, focus: false)
            }
            waitForPage()
            step { [self] done in
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    guard visible() else {
                        self.note("FAIL-ENV \(tag) \(name): our window isn't on screen in front (occlusion/Space)")
                        return done()
                    }
                    let cpu0 = Self.processCPU(), ws0 = Self.windowServerSeconds(), t0 = CACurrentMediaTime()
                    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                        let cpu1 = Self.processCPU(), ws1 = Self.windowServerSeconds(), dt = CACurrentMediaTime() - t0
                        var perKind: [String: Double] = [:]
                        for (pid, x) in cpu1 { if let y = cpu0[pid] { perKind[x.kind, default: 0] += (x.seconds - y.seconds) / dt * 100 } }
                        let total = perKind.values.reduce(0, +)
                        let ws = (ws0 != nil && ws1 != nil) ? (ws1! - ws0!) / dt * 100 : -1
                        let kinds = perKind.sorted { $0.value > $1.value }.map { "\($0.key) \(String(format: "%.2f", $0.value))" }
                            .joined(separator: ", ")
                        let page = self.c.window.contentView?.frame.size ?? .zero
                        self.note("MEASURE \(tag) \(name): CPU " + String(format: "%.2f", total) + "% (\(kinds)); WindowServer "
                                  + String(format: "%.2f", ws) + "%; \(Int(dt)) s; window \(Int(self.c.window.frame.width))×"
                                  + "\(Int(self.c.window.frame.height)) (content \(Int(page.width))×\(Int(page.height))), sidebar "
                                  + "\(self.c.sidebarHidden ? "hidden" : "shown"), key \(self.c.window.isKeyWindow), \(url)")
                        results.append(["case": name, "cpu": total, "cpu_by_kind": perKind, "windowserver": ws, "seconds": dt,
                                        "sidebar_hidden": self.c.sidebarHidden, "url": url])
                        // Report-only (see the TODO above): never a FAIL until the engine is an official build.
                        if engine.hasPrefix("WebKit") {
                            self.note("REPORT \(tag) \(name): " + String(format: "%.2f", total) + "% CPU, app process only "
                                      + "(WebKit's web-content process isn't ours to read): not comparable with Chrome")
                        } else if name.hasPrefix("static") {
                            self.note("REPORT \(tag) \(name): " + String(format: "%.2f", total) + "% CPU (goal ≤ 1%; Chrome ~2%): "
                                      + (total <= 1 ? "within" : "OVER") + " the goal")
                        } else if name.hasPrefix("pulse") {
                            self.note("REPORT \(tag) \(name): " + String(format: "%.2f", total) + "% CPU vs Chrome "
                                      + String(format: "%.1f", chromePulse) + "% = " + String(format: "%.2f", total / chromePulse)
                                      + "× (goal ≤ 1.2×): " + (total <= chromePulse * 1.2 ? "within" : "OVER") + " the goal")
                        }
                        guard tracing else { return done() }
                        say("trace \(name) \(url)")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 9) { done() }
                    }
                }
            }
        }

        // The run must end within the snapshot watchdog's 240 s: the sidebar-hidden pass repeats only the pulse page.
        let passes = env["AIRC_VISIBLECPU_HIDDEN"] == "0" ? [false] : env["AIRC_VISIBLECPU_HIDDEN"] == "only" ? [true] : [false, true]
        for hidden in passes {
            run { setSidebar(hidden: hidden) }
            wait(1)
            for key in hidden && passes.count > 1 ? ["pulse"] : ["pulse", "static"] + extra.indices.map({ "page\($0 + 1)" }) {
                measure(key + (hidden ? ", sidebar hidden" : ""), key: key)
            }
        }

        run { [self] in
            setSidebar(hidden: false)
            let expected = passes.reduce(0) { n, hidden in n + (hidden && passes.count > 1 ? 1 : 2 + extra.count) }
            check(results.count == expected, "\(tag): every case was measured in front (\(results.count) of \(expected))")
            if let data = try? JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]) {
                try? data.write(to: dir.appendingPathComponent("visiblecpu.json"))
            }
            say("done")
            server?.stop()
            finish()
        }
    }

    /// CPU seconds of the WindowServer, from `ps` (our process can't read another user's rusage).
    static func windowServerSeconds() -> Double? {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-A", "-o", "time=,comm="]
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let line = String(decoding: data, as: UTF8.self).split(separator: "\n").first(where: { $0.hasSuffix("/WindowServer") })
        else { return nil }
        let time = line.split(separator: " ").first.map(String.init) ?? ""
        var secs = 0.0
        for part in time.split(separator: ":") { secs = secs * 60 + (Double(part) ?? 0) }
        return secs
    }
}
#endif
