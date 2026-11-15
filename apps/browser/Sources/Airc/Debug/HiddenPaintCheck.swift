// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import Darwin

/// MEM-6 (hiddenpaint): a page the person can't see must be hidden to the renderer, as in Chrome: no animation frames,
/// `document.visibilityState == "hidden"`, (almost) no CPU in the GPU process and the renderer. And showing it again
/// must paint at once.
///
/// A loopback page runs a CSS animation and a requestAnimationFrame loop (the worst case: a page that always animates)
/// and records every frame's wall-clock time and every visibility change. For each state the check waits for it to
/// settle (Chromium waits 1 s before it marks a page occluded), then counts the page's frames and the CPU time of the
/// app and its child processes (proc_pid_rusage) over 5 s. States: the page in front (baseline), in a background tab,
/// its window minimized, covered by another (opaque, ordinary-level) window of ours, left on another Space (one of our
/// windows in its own full-screen Space), ordered out, and the app hidden. After each, it restores the window and
/// measures the time from the restore to the page's first new frame.
///
/// Extra baselines: a static page in front (no animation), and AIRC_HIDDENPAINT_URL in front if set (perf13's busy
/// Wikipedia page), to tell what a visible page itself costs.
///
/// Run it in front (dedicated session, AIRC_LA_AS_OWNER=1) and with AIRC_KEEP_OCCLUSION=1: scripted runs otherwise
/// pass Chromium --disable-backgrounding-occluded-windows, which keeps occluded and minimized pages visible on purpose.
/// Every state starts from a window that macOS reports as visible, or the case is FAIL-ENV.
extension SnapshotRunner {
    private static let paintPage = """
        <!doctype html><title>hiddenpaint</title>
        <style>body{margin:40px;font:15px -apple-system,sans-serif}#s{width:90px;height:90px;border-radius:12px;background:#4a8;
        animation:spin 1.2s linear infinite}@keyframes spin{to{transform:rotate(360deg)}}</style>
        <div id=s></div><p>hiddenpaint probe</p>
        <script>
        var frames=0,ring=[],vis=[[Date.now(),document.visibilityState]];
        document.addEventListener('visibilitychange',function(){vis.push([Date.now(),document.visibilityState])});
        (function tick(){frames++;ring.push(performance.timeOrigin+performance.now());if(ring.length>400)ring.shift();
          requestAnimationFrame(tick)})();
        </script>
        """
    private static let staticPage = "<!doctype html><title>static</title><p style='font:15px -apple-system'>A static page.</p>"
    private static let blankPage = "<!doctype html><title>other</title><p style='font:15px -apple-system'>Another tab.</p>"
    private static let readScript = """
        (typeof frames === 'number' ? {frames:frames,visibility:document.visibilityState,now:Date.now(),ring:ring.slice(-400),
          vis:vis.slice(-8)} : {frames:0,visibility:document.visibilityState,now:Date.now(),ring:[],vis:[]})
        """

    func hiddenPaintScenario() {
        var server: LocalPageServer?
        var port: UInt16 = 0
        var probe = "", other = "", still = "", remote = ""
        var cover: NSWindow?
        var spaceWindow: NSWindow?
        var results: [[String: Any]] = []
        let engine = app?.engine.name ?? "?"
        let tag = "hiddenpaint \(engine)"
        let url = ProcessInfo.processInfo.environment["AIRC_HIDDENPAINT_URL"] ?? ""

        func read(_ id: String, _ then: @escaping ([String: Any]) -> Void) {
            guard let page = c.engineTab(for: id) else { return then([:]) }
            page.evaluate(Self.readScript) { then($0 as? [String: Any] ?? [:]) }
        }
        func visible() -> Bool { c.window.isVisible && c.window.occlusionState.contains(.visible) && c.window.isOnActiveSpace }

        step { [self] done in
            if ProcessInfo.processInfo.environment["AIRC_LA_AS_OWNER"] == "1" {
                NSApp.activate(ignoringOtherApps: true)
                c.window.makeKeyAndOrderFront(nil)
            }
            guard let s = LocalPageServer(pages: ["/paint": Self.paintPage, "/static": Self.staticPage, "/other": Self.blankPage]) else {
                check(false, "\(tag): the loopback server starts"); return done()
            }
            server = s
            s.start { p in
                guard let p else { self.check(false, "\(tag): the loopback server starts"); return done() }
                port = p
                let space = self.c.currentSpaceID
                let base = "http://127.0.0.1:\(p)"
                do {
                    still = try self.c.store.openTab(url: base + "/static", inSpace: space, title: "Static").id
                    other = try self.c.store.openTab(url: base + "/other", inSpace: space, title: "Other").id
                    if !url.isEmpty { remote = try self.c.store.openTab(url: url, inSpace: space, title: "Remote").id }
                    probe = try self.c.store.openTab(url: base + "/paint", inSpace: space, title: "Paint").id
                } catch { self.check(false, "\(tag): open the tabs (\(error))"); return done() }
                self.c.reloadAll(animated: false)
                self.c.show(probe, focus: false)
                done()
            }
        }
        waitForPage()
        wait(1.5)

        /// Settles `seconds`, then measures the page `id` for 5 s.
        func measure(_ name: String, _ id: @escaping () -> String, settle: Double = 2.5,
                     expectHidden: Bool, precondition: @escaping () -> String? = { nil }) {
            step { [self] done in
                DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                    if let why = precondition() {
                        self.note("FAIL-ENV \(tag) \(name): \(why)")
                        return done()
                    }
                    read(id()) { a in
                        let cpu0 = Self.processCPU(), t0 = CACurrentMediaTime()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            read(id()) { b in
                                let cpu1 = Self.processCPU(), dt = CACurrentMediaTime() - t0
                                let fps = Double(((b["frames"] as? NSNumber)?.intValue ?? 0) - ((a["frames"] as? NSNumber)?.intValue ?? 0)) / dt
                                var perKind: [String: Double] = [:]
                                for (pid, x) in cpu1 { if let y = cpu0[pid] { perKind[x.kind, default: 0] += (x.seconds - y.seconds) / dt * 100 } }
                                let total = perKind.values.reduce(0, +)
                                let vis = b["visibility"] as? String ?? "?"
                                let kinds = perKind.sorted { $0.value > $1.value }.map { "\($0.key) \(String(format: "%.2f", $0.value))" }
                                    .joined(separator: ", ")
                                self.note("MEASURE \(tag) \(name): visibility \(vis), \(String(format: "%.1f", fps)) frames/s, CPU "
                                          + String(format: "%.2f", total) + "% (\(kinds)); window visible \(self.c.window.isVisible), "
                                          + "occlusion visible \(self.c.window.occlusionState.contains(.visible)), "
                                          + "on active Space \(self.c.window.isOnActiveSpace), miniaturized \(self.c.window.isMiniaturized), "
                                          + "app hidden \(NSApp.isHidden)")
                                results.append(["state": name, "visibility": vis, "fps": fps, "cpu": total, "cpu_by_kind": perKind])
                                if expectHidden {
                                    self.check(vis == "hidden" && fps < 1, "\(tag) \(name): the page is hidden and draws nothing "
                                               + "(\(vis), \(String(format: "%.1f", fps)) frames/s)")
                                } else if id() == probe {
                                    self.check(vis == "visible" && fps > 30, "\(tag) \(name): the page in front is visible and animates "
                                               + "(\(vis), \(String(format: "%.1f", fps)) frames/s)")
                                }
                                done()
                            }
                        }
                    }
                }
            }
        }
        /// Undoes a state, then: the page is visible again, and its first frame after the restore came quickly.
        /// `back`: when the window is back on screen (un-minimizing animates for about half a second); timed from there.
        func restore(_ name: String, back: @escaping () -> Bool = { true }, _ undo: @escaping () -> Void) {
            step { [self] done in
                undo()
                waitUntil(back, timeout: 3) { done() }
            }
            step { [self] done in
                let t = Date().timeIntervalSince1970 * 1000
                let deadline = Date().addingTimeInterval(3)
                func poll() {
                    read(probe) { b in
                        let ring = (b["ring"] as? [NSNumber])?.map(\.doubleValue) ?? []
                        let first = ring.first { $0 > t }
                        if (b["visibility"] as? String) == "visible", let first {
                            self.check(first - t < 300, "\(tag) \(name) → shown: the page paints at once "
                                       + "(first frame \(Int(first - t)) ms after the restore)")
                            self.note("MEASURE \(tag) \(name) restore_first_frame_ms \(Int(first - t)); visibility log \(b["vis"] ?? "-")")
                            return done()
                        }
                        if Date() > deadline {
                            self.check(false, "\(tag) \(name) → shown: the page is visible and paints within 3 s "
                                       + "(\(b["visibility"] ?? "-"), log \(b["vis"] ?? "-"))")
                            return done()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: poll)
                    }
                }
                poll()
            }
            wait(1)
        }
        let notVisible: () -> String? = { visible() ? nil : "our window isn't on screen in front (occlusion/Space)" }

        measure("front", { probe }, expectHidden: false, precondition: notVisible)

        // A background tab of the front window.
        run { [self] in c.show(other, focus: false) }
        measure("background tab", { probe }, expectHidden: true)
        restore("background tab") { [self] in c.show(probe, focus: false) }

        // Minimized.
        run { [self] in c.window.miniaturize(nil) }
        measure("minimized", { probe }, settle: 3, expectHidden: true,
                precondition: { [self] in c.window.isMiniaturized ? nil : "the window didn't minimize" })
        restore("minimized", back: { [self] in !c.window.isMiniaturized && c.window.occlusionState.contains(.visible) }) { [self] in
            c.window.deminiaturize(nil)
        }
        wait(1)

        // Covered by an opaque, ordinary-level window of ours (macOS reports the window occluded).
        run { [self] in
            let w = NSWindow(contentRect: c.window.frame.insetBy(dx: -8, dy: -8), styleMask: [.borderless], backing: .buffered, defer: false)
            w.isOpaque = true
            w.backgroundColor = .windowBackgroundColor
            w.isReleasedWhenClosed = false
            w.order(.above, relativeTo: c.window.windowNumber)
            cover = w
        }
        measure("covered", { probe }, settle: 3, expectHidden: true,
                precondition: { [self] in c.window.occlusionState.contains(.visible) ? "macOS still reports the window visible" : nil })
        restore("covered") { cover?.orderOut(nil); cover = nil }

        // On another Space: one of our windows takes its own full-screen Space, so the main window's Space isn't shown.
        run {
            let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 500, height: 400), styleMask: [.titled, .resizable],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.fullScreenPrimary]
            w.title = "hiddenpaint Space"
            w.makeKeyAndOrderFront(nil)
            w.toggleFullScreen(nil)
            spaceWindow = w
        }
        step { [self] done in waitUntil({ !self.c.window.isOnActiveSpace }, timeout: 6) { done() } }
        measure("other Space", { probe }, settle: 2.5, expectHidden: true,
                precondition: { [self] in c.window.isOnActiveSpace ? "the main window is still on the active Space" : nil })
        restore("other Space") { spaceWindow?.toggleFullScreen(nil) }
        step { [self] done in
            waitUntil({ !(spaceWindow?.styleMask.contains(.fullScreen) ?? false) && self.c.window.isOnActiveSpace }, timeout: 6) {
                spaceWindow?.orderOut(nil); spaceWindow = nil
                self.c.window.makeKeyAndOrderFront(nil)
                done()
            }
        }
        wait(1)

        // Ordered out (MEM-6's own case: a closed window whose pages live on).
        run { [self] in c.window.orderOut(nil) }
        measure("ordered out", { probe }, settle: 2.5, expectHidden: true)
        restore("ordered out") { [self] in c.window.makeKeyAndOrderFront(nil) }

        // The app hidden (⌘H).
        run { NSApp.hide(nil) }
        measure("app hidden", { probe }, settle: 2.5, expectHidden: true)
        restore("app hidden") { [self] in
            NSApp.unhide(nil)
            c.window.makeKeyAndOrderFront(nil)
        }
        wait(1)

        // What a visible page costs: a static one, and perf13's page if given.
        run { [self] in c.show(still, focus: false) }
        measure("static page in front", { still }, expectHidden: false, precondition: notVisible)
        if !url.isEmpty {
            run { [self] in c.show(remote, focus: false) }
            waitForPage()
            // Which animations keep the visible page drawing (perf13 saw one on its Wikipedia page).
            step { [self] done in
                let script = """
                    document.getAnimations().filter(a => a.playState === 'running').map(a => { const t = a.effect && a.effect.target;
                      const timing = a.effect ? a.effect.getComputedTiming() : {};
                      return [a.constructor.name, a.animationName || a.transitionProperty || a.id || '', t ? (t.tagName + '#' + t.id + '.' +
                        String(t.className).slice(0, 60)) : '-', String(timing.iterations), t ? t.getBoundingClientRect().width + 'x' +
                        t.getBoundingClientRect().height : '-', t ? getComputedStyle(t).visibility + '/' + getComputedStyle(t).display : '-'] })
                    """
                c.engineTab(for: remote)?.evaluate(script) { v in
                    self.note("hiddenpaint \(engine): running animations on \(url): \(String(describing: v))")
                    done()
                }
            }
            measure("\(url) in front", { remote }, settle: 6, expectHidden: false, precondition: notVisible)
            run { [self] in c.show(probe, focus: false) }
            // Frames come from the probe only; this one checks the remote page's visibility.
            measure("background tab behind \(url)", { remote }, expectHidden: true)
        }
        run { [self] in
            note("hiddenpaint: results \(results.count) states, port \(port)")
            if let data = try? JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]) {
                try? data.write(to: dir.appendingPathComponent("hiddenpaint.json"))
            }
            server?.stop()
            finish()
        }
    }

    /// CPU seconds of this process and its descendants (Chromium's helpers), keyed by pid, with Chromium's process
    /// type (`--type=` from the arguments).
    static func processCPU() -> [Int32: (kind: String, seconds: Double)] {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        var out: [Int32: (kind: String, seconds: Double)] = [:]
        var queue = [getpid()]
        while let pid = queue.popLast() {
            var info = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            if ok == 0 {
                let ticks = Double(info.ri_user_time + info.ri_system_time)
                out[pid] = (pid == getpid() ? "main" : processKind(pid), ticks * Double(timebase.numer) / Double(timebase.denom) / 1e9)
            }
            var children = [pid_t](repeating: 0, count: 256)
            let n = proc_listchildpids(pid, &children, Int32(children.count * MemoryLayout<pid_t>.size))
            if n > 0 { queue += children.prefix(Int(n)).filter { $0 > 0 } }
        }
        return out
    }

    private static func processKind(_ pid: Int32) -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return "child" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return "child" }
        let args = buffer.prefix(size).split(separator: 0).compactMap { String(bytes: $0, encoding: .utf8) }
        if let type = args.first(where: { $0.hasPrefix("--type=") })?.dropFirst(7) {
            if type == "utility", let sub = args.first(where: { $0.hasPrefix("--utility-sub-type=") }) {
                return "utility:" + (sub.split(separator: ".").last.map(String.init) ?? "")
            }
            return String(type)
        }
        return args.first.map { ($0 as NSString).lastPathComponent } ?? "child"
    }
}
#endif
