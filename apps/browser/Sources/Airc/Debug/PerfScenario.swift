// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit
import Darwin
import QuartzCore

/// Launch timestamps for `--script perf`: process start (from the kernel), the window, and the first time the main
/// thread was free to take input after it.
enum PerfLaunch {
    static var windowAt: Date?
    static var interactiveAt: Date?

    static var processStart: Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let t = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1e6)
    }

    /// The window is up: the next time the run loop is about to wait (Core Animation has committed the frame and no
    /// work is queued), the app is interactive.
    static func windowOpened() {
        windowAt = Date()
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) { _, _ in
            if interactiveAt == nil { interactiveAt = Date() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}

/// The display's frames while a measurement runs (CADisplayLink), so an action's time is taken to the frame that
/// presents it, not to the layout pass. Stopped while idle. With the display asleep there are no frames: then the
/// Core Animation commit is reported instead and `source` says so.
final class FrameClock: NSObject {
    private var link: CADisplayLink?
    private(set) var ticks: [CFTimeInterval] = []
    private(set) var interval: CFTimeInterval?

    func start(on view: NSView) {
        guard link == nil else { return }
        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ l: CADisplayLink) {
        ticks.append(l.timestamp)
        let d = l.targetTimestamp - l.timestamp
        if d > 0 { interval = d }
        if ticks.count > 4000 { ticks.removeFirst(1000) }
        // Handlers run once per frame until they return false (`--script frames` starts its actions on a frame).
        let handlers = onTick
        onTick = []
        onTick += handlers.filter { $0(l.timestamp) }
    }

    private var onTick: [(CFTimeInterval) -> Bool] = []

    /// Runs `block` in the next frame's callback, right after its vsync (`timestamp`).
    func atNextFrame(_ block: @escaping (CFTimeInterval) -> Void) {
        onTick.append { block($0); return false }
    }

    /// Runs `block` in every frame's callback until it returns false.
    func everyFrame(_ block: @escaping (CFTimeInterval) -> Bool) { onTick.append(block) }

    /// The vsyncs between `a` and `b` as the main thread saw them, and how far apart they were.
    func deltas(from a: CFTimeInterval, to b: CFTimeInterval) -> [Double] {
        let window = ticks.filter { $0 >= a && $0 <= b }
        return zip(window, window.dropFirst()).map { ($0.1 - $0.0) * 1000 }
    }

    var running: Bool { !ticks.isEmpty }
    /// A frame arrived in the last 100 ms (the display is on and the window on it).
    var isTicking: Bool { (ticks.last.map { CACurrentMediaTime() - $0 < 0.1 }) ?? false }
    var refreshHz: Double? { interval.map { 1 / $0 } }

    /// The first frame shown after a commit at `t` (the next vsync).
    func presented(after t: CFTimeInterval) -> CFTimeInterval? { ticks.first { $0 >= t } }

    /// Frames missed between `a` and `b`: gaps longer than 1.5 intervals, counted in whole frames.
    func dropped(from a: CFTimeInterval, to b: CFTimeInterval) -> Int {
        guard let interval else { return 0 }
        let window = ticks.filter { $0 >= a && $0 <= b }
        return zip(window, window.dropFirst()).reduce(0) { n, p in
            let gap = p.1 - p.0
            return n + (gap > interval * 1.5 ? Int((gap / interval).rounded()) - 1 : 0)
        }
    }
}

extension SnapshotRunner {
    /// `--script perf`: the reference workload from `--perf-workload` (3 profiles, 6 Spaces, 30 tabs, the 8 recent
    /// ones loaded), timings to the presented frame, then idle until the harness asks for the 100-tab leak cycle
    /// through `--perf-control`. Events are JSON lines in `--perf-events`. See infra/perf/README.md.
    func perfScenario() {
        let o = LaunchOptions.current
        guard let workloadURL = o.perfWorkload, let data = try? Data(contentsOf: workloadURL),
              let workload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            note("perf: no readable --perf-workload")
            return finish()
        }
        let perf = PerfRun(runner: self, events: o.perfEvents, control: o.perfControl)
        objc_setAssociatedObject(self, &perfRunKey, perf, .OBJC_ASSOCIATION_RETAIN)
        perf.seed(workload, loadAll: o.perfLoadAll)
        waitForWorkload(perf)
        run { perf.emitReady() }
        perf.reportPages()
        run { perf.watchControl() }
        // The all-loaded variant (MEM-4) only needs its pages: no timings, no leak cycle. The reference run's timed
        // actions show every loaded page once; they wait until the harness has sampled memory and idle CPU (its
        // "measure" action), so those are taken from the same untouched state as Chrome's.
        if !o.perfLoadAll {
            step { done in perf.whenMeasureRequested(done) }
            perf.measureTimings()
        }
        // Keep running (no snapshots, no periodic UI work) until the harness ends the run.
        step { _ in }
    }

    private func waitForWorkload(_ perf: PerfRun) {
        step { [self] done in
            let deadline = Date().addingTimeInterval(20)
            func poll() {
                let pages = perf.loaded.compactMap { c.engineTab(for: $0) }
                if pages.allSatisfy({ !$0.isLoading }) || Date() > deadline {
                    // At most 20 s per page, then stop navigation (the harness's rule).
                    pages.filter(\.isLoading).forEach { $0.stop() }
                    perf.stopped = pages.filter(\.isLoading).count
                    return done()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: poll)
            }
            poll()
        }
    }
}

private var perfRunKey = 0

/// One perf run's state.
final class PerfRun {
    unowned let runner: SnapshotRunner
    var c: WindowController { runner.c }
    private let events: FileHandle?
    private let control: URL?
    private var controlSource: DispatchSourceFileSystemObject?
    private var leakStarted = false
    let clock = FrameClock()
    /// The recent tabs whose pages are loaded.
    var loaded: [String] = []
    var stopped = 0
    private var timings: [String: Any] = [:]

    init(runner: SnapshotRunner, events: URL?, control: URL?) {
        self.runner = runner
        self.control = control
        if let events {
            FileManager.default.createFile(atPath: events.path, contents: nil)
            self.events = try? FileHandle(forWritingTo: events)
        } else {
            self.events = nil
        }
    }

    /// One JSON line, flushed to disk at once.
    func emit(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        events?.seekToEndOfFile()
        events?.write(data + Data("\n".utf8))
        try? events?.synchronize()
        runner.note("perf event: " + (String(data: data, encoding: .utf8) ?? ""))
    }

    // MARK: Workload

    func seed(_ w: [String: Any], loadAll: Bool = false) {
        runner.run { [self] in
            let store = c.store
            let names = (w["profiles"] as? [String]) ?? []
            do {
                // Profile 0 is the default one; the others take the warm spare, as a person's would.
                var profileIDs: [String] = []
                for (i, n) in names.enumerated() {
                    if i == 0 {
                        try store.updateProfile(store.defaultProfile.id) { $0.name = n }
                        profileIDs.append(store.defaultProfile.id)
                    } else {
                        profileIDs.append(try c.profiles.createProfile(name: n, emoji: "", color: nil).id)
                    }
                }
                var spaceIDs: [Int: String] = [:]
                var after = store.selectedSpace.id
                for s in (w["spaces"] as? [[String: Any]]) ?? [] {
                    guard let id = s["id"] as? Int, let p = s["profile"] as? Int, profileIDs.indices.contains(p) else { continue }
                    if spaceIDs.isEmpty {
                        try store.updateSpace(after) { $0.name = "Space \(id + 1)"; $0.profileID = profileIDs[p] }
                        spaceIDs[id] = after
                    } else {
                        let made = try store.createSpace(name: "Space \(id + 1)", icon: nil, theme: .neutral, profileID: profileIDs[p], after: after)
                        spaceIDs[id] = made.id
                        after = made.id
                    }
                }
                var firstRecent: String?
                for t in (w["tabs"] as? [[String: Any]]) ?? [] {
                    guard let url = t["url"] as? String, let si = t["space"] as? Int, let sid = spaceIDs[si] else { continue }
                    let recent = t["recent"] as? Bool ?? false
                    let tab = try store.openTab(url: url, inSpace: sid, activate: recent, title: url)
                    if recent || loadAll {
                        loaded.append(tab.id)
                        if firstRecent == nil, si == 0, recent { firstRecent = tab.id }
                    }
                }
                c.reloadAll(animated: false)
                if let first = spaceIDs[0] { c.switchToSpace(first, animated: false) }
                self.firstRecent = firstRecent
                runner.note("perf: seeded \(store.orderedProfiles.count) profiles, \(store.orderedSpaces.count) spaces, \(store.state.tabs.count) tabs")
            } catch {
                runner.note("perf: seed failed: \(error)")
            }
        }
        // Chromium loads a new profile asynchronously: every page waits for its profile.
        runner.step { [self] done in
            var remaining = c.store.orderedProfiles.count
            for p in c.store.orderedProfiles {
                c.profiles.whenLoaded(p.id) { _ in
                    remaining -= 1
                    if remaining == 0 { done() }
                }
            }
        }
        runner.run { [self] in
            if let id = firstRecent { c.show(id, focus: false) }
            for id in loaded where id != firstRecent { c.loadPageInBackground(id) }
            runner.note("perf: \(loaded.filter { c.engineTab(for: $0) != nil }.count) of \(loaded.count) recent pages loading")
        }
    }

    private var firstRecent: String?

    func emitReady() {
        let tabs = c.store.state.tabs.keys
        let loadedNow = tabs.filter { c.engineTab(for: $0) != nil }.count
        emit(["event": "workload_ready", "profiles": c.store.orderedProfiles.count, "spaces": c.store.orderedSpaces.count,
              "loaded_tabs": loadedNow, "unloaded_tabs": tabs.count - loadedNow, "stopped_loads": stopped,
              "engine": runner.app?.engine.name ?? "?"])
    }

    // MARK: Timings (input → presented frame)

    func measureTimings() {
        let r = runner
        r.run { [self] in
            clock.start(on: c.root)
            if let start = PerfLaunch.processStart, let ready = PerfLaunch.interactiveAt {
                timings["interactive_ms"] = ms(ready.timeIntervalSince(start))
            }
            if let w = PerfLaunch.windowAt, let ready = PerfLaunch.interactiveAt {
                timings["sidebar_ready_ms"] = ms(ready.timeIntervalSince(w))
            }
        }
        r.wait(0.3)
        // Space switches between neighbours, as a footer click or ⌃-number does (animated).
        var spaceFrames: [Double] = []
        var spaceSource = "display"
        var switchStart: CFTimeInterval = 0
        r.run { switchStart = CACurrentMediaTime() }
        for i in 0..<8 {
            r.step { [self] done in
                let spaces = c.store.orderedSpaces
                let target = spaces[(i % 2 == 0) ? 1 : 0].id
                frame({ self.c.switchToSpace(target, animated: true) }) { v, src in
                    spaceFrames.append(v)
                    if src != "display" { spaceSource = src }
                    done()
                }
            }
            r.wait(0.35)
        }
        r.run { [self] in
            timings["space_frame_ms"] = median(spaceFrames)
            timings["space_frame_samples_ms"] = spaceFrames.map(round2)
            timings["space_frame_source"] = spaceSource
            timings["dropped_frames"] = clock.running ? clock.dropped(from: switchStart, to: CACurrentMediaTime()) : NSNull()
        }
        // A loaded tab: switch between two loaded tabs of the first Space.
        var tabFrames: [Double] = []
        for i in 0..<6 {
            r.step { [self] done in
                let space = c.store.orderedSpaces[0].id
                let candidates = c.store.todayTabs(ofSpace: space).filter { c.engineTab(for: $0.id) != nil }
                guard candidates.count >= 2 else { return done() }
                let t = candidates[i % 2]
                frame({ self.c.show(t.id, focus: false) }) { v, _ in tabFrames.append(v); done() }
            }
            r.wait(0.25)
        }
        r.run { [self] in
            timings["tab_paint_ms"] = tabFrames.isEmpty ? NSNull() : median(tabFrames)
            timings["tab_paint_note"] = "input to the presented frame that shows the already-loaded page view; the engine's own paint is not observable"
        }
        // New Space (and its profile when one is new): Enter → presented frame. The Space is removed again.
        r.run { [self] in
            c.openNewSpacePanel()
            c.newSpacePanel?.model.name = "Perf"
        }
        r.wait(0.4)
        r.step { [self] done in
            frame({ self.c.newSpacePanel?.model.onCreate?() }) { v, _ in
                self.timings["new_space_ms"] = v
                done()
            }
        }
        r.wait(0.5)
        r.run { [self] in
            if let s = c.store.orderedSpaces.first(where: { $0.name == "Perf" }) {
                try? c.store.deleteSpace(s.id)
                c.reloadAll(animated: false)
                c.switchToSpace(c.store.orderedSpaces[0].id, animated: false)
            }
        }
        r.wait(0.4)
        // Command Bar: first frame (five openings: the first, then the reused bar), local results in the frame of each
        // keystroke, suggestions round trip. The main thread's own work and Perf sections say where a frame goes.
        var opens: [Double] = [], openWork: [Double] = [], keys: [Double] = [], keyWork: [Double] = []
        r.run { Perf.enabled = true; Perf.reset() }
        for i in 0..<5 {
            r.step { [self] done in
                frame({ self.c.openCommandBar(mode: .newTab) }) { v, _, w in
                    opens.append(v); openWork.append(w)
                    if i == 0 { self.timings["command_first_open_sections"] = Perf.report(); Perf.reset() }
                    done()
                }
                // The live service below stands in for the bar's own: it is warmed right after the bar's frame, as the
                // bar's is.
                if i == 4 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) {
                        SuggestionService.live.prewarm(engine: .google, profileID: "perf")
                    }
                }
            }
            r.wait(0.3)
            if i < 4 {
                r.run { [self] in c.closeCommandBar() }
                r.wait(0.3)
            }
        }
        r.run { [self] in
            timings["command_frame_ms"] = median(opens)
            timings["command_frame_first_ms"] = opens.first ?? NSNull()
            timings["command_frame_samples_ms"] = opens.map(round2)
            timings["command_open_work_ms"] = median(openWork)
            timings["command_open_work_samples_ms"] = openWork.map(round2)
            timings["command_open_sections"] = Perf.report()
            Perf.reset()
        }
        for text in ["w", "wi", "wik", "wiki"] {
            r.step { [self] done in
                frame({ self.c.commandBar?.type(text) }) { v, _, w in keys.append(v); keyWork.append(w); done() }
            }
            r.wait(0.15)
        }
        r.run { [self] in
            timings["command_local_ms"] = median(keys)
            timings["command_local_samples_ms"] = keys.map(round2)
            timings["command_key_work_ms"] = median(keyWork)
            timings["command_key_sections"] = Perf.report()
            Perf.enabled = false
        }
        r.step { [self] done in
            let t0 = CACurrentMediaTime()
            var finished = false
            SuggestionService.live.fetch("wikipedia", engine: .google, profileID: "perf") { list in
                guard !finished else { return }
                finished = true
                self.timings["command_suggestions_ms"] = list.isEmpty ? NSNull() : self.ms(CACurrentMediaTime() - t0)
                done()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard !finished else { return }
                finished = true
                self.timings["command_suggestions_ms"] = NSNull()
                done()
            }
        }
        r.run { [self] in c.closeCommandBar() }
        r.wait(0.3)
        // ⌘S: hide and show, from the key to the end of the animation.
        sidebarToggle(r, key: "sidebar_hide_ms", to: 0)
        r.wait(0.3)
        sidebarToggle(r, key: "sidebar_show_ms", to: 1)
        r.wait(0.3)
        // MEM-2: an empty loaded profile, three times on its own; the largest main-process growth.
        var deltas: [Double] = []
        for i in 0..<3 {
            r.step { [self] done in
                let before = PerfRun.footprintMB()
                guard let engine = runner.app?.engine else { return done() }
                engine.loadProfile(directory: "Perf-Empty-\(i)") { p in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        deltas.append(PerfRun.footprintMB() - before)
                        if let p { engine.deleteProfile(p) { _ in } }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: done)
                    }
                }
            }
        }
        r.run { [self] in
            clock.stop()
            timings["empty_profile_mb"] = deltas.max().map(round2) ?? NSNull()
            timings["empty_profile_samples_mb"] = deltas.map(round2)
            timings["empty_profile_note"] = "phys_footprint growth of the app process only (WebKit keeps a profile's cost in its shared network process)"
            timings["refresh_hz"] = clock.refreshHz.map(round2) ?? NSNull()
            timings["frame_source"] = clock.running ? "display link (next vsync after the commit)" : "commit (display asleep: no frames)"
            timings["idle_timer_count"] = c.repeatingTimerCount
            timings["next_wakeup_s"] = c.nextArchiveWakeup.map { round2($0.timeIntervalSinceNow) } ?? NSNull()
            timings["engine"] = runner.app?.engine.name ?? "?"
            var line: [String: Any] = ["event": "timings"]
            line.merge(timings) { a, _ in a }
            emit(line)
        }
    }

    /// MEM-6: what each loaded page reports once its loads are done: its visibility, the animation frames it
    /// got in a second and its running animations. A page that isn't on screen must say hidden and get no frames, as
    /// Chrome's background tabs do; one that gets frames keeps the renderer and the GPU busy at idle.
    func reportPages() {
        runner.step { [self] done in
            let script = """
            new Promise(resolve => { let frames = 0; const tick = () => { frames++; requestAnimationFrame(tick) };
              requestAnimationFrame(tick);
              setTimeout(() => resolve({visibility: document.visibilityState, frames,
                animations: document.getAnimations().filter(a => a.playState === 'running').length}), 1000) })
            """
            var pages: [[String: Any]] = []
            let group = DispatchGroup()
            for id in loaded {
                guard let page = c.engineTab(for: id) else { continue }
                group.enter()
                page.evaluate(script) { value in
                    var row: [String: Any] = ["url": page.url?.absoluteString ?? "", "title": page.title,
                                              "shown": id == self.c.shownTabID]
                    (value as? [String: Any])?.forEach { row[$0.key] = $0.value }
                    if value == nil { row["error"] = "no answer" }
                    pages.append(row)
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                self.emit(["event": "pages", "pages": pages, "window_visible": self.c.window.isVisible,
                           "window_occlusion_visible": self.c.window.occlusionState.contains(.visible)])
                done()
            }
        }
    }

    private func sidebarToggle(_ r: SnapshotRunner, key: String, to target: CGFloat) {
        r.step { [self] done in
            let t0 = CACurrentMediaTime()
            c.toggleSidebar()
            let deadline = t0 + 1.5
            func poll() {
                if abs(c.sidebarFraction - target) < 0.001 {
                    timings[key] = ms(CACurrentMediaTime() - t0)
                    return done()
                }
                if CACurrentMediaTime() > deadline {
                    timings[key] = NSNull()   // the animation never finished (no display frames)
                    if target == 0, !c.sidebarHidden { c.toggleSidebar() }
                    return done()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.004, execute: poll)
            }
            poll()
        }
    }

    /// Runs `work` and reports the time to the frame that presents it, or to the commit when there are no frames.
    private func frame(_ work: () -> Void, _ done: @escaping (Double, String) -> Void) {
        frame(work) { v, source, _ in done(v, source) }
    }

    /// The same, with the main thread's time in `work` itself (ms): the rest is layout, drawing and the commit.
    private func frame(_ work: () -> Void, _ done: @escaping (Double, String, Double) -> Void) {
        let t0 = CACurrentMediaTime()
        FrameTiming.measure(work) { [self] t in
            let commit = t0 + t.frame / 1000
            if clock.running, let shown = clock.presented(after: commit) {
                done(ms(shown - t0), "display", round2(t.work))
            } else {
                done(round2(t.frame), "commit", round2(t.work))
            }
        }
    }

    // MARK: Control (the 100-tab leak cycle)

    /// Watches the control file's folder with a file-system event source (no polling timer).
    func watchControl() {
        guard let control else { return }
        let dir = control.deletingLastPathComponent()
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return runner.note("perf: can't watch \(dir.path)") }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in self?.readControl() }
        src.setCancelHandler { close(fd) }
        src.resume()
        controlSource = src
        readControl()
    }

    private var measureRequested = false
    private var onMeasure: (() -> Void)?

    /// Runs `done` once the harness has asked for the timed actions (`{"action":"measure"}`).
    func whenMeasureRequested(_ done: @escaping () -> Void) {
        if measureRequested { return done() }
        onMeasure = done
    }

    private func readControl() {
        guard let control, let data = try? Data(contentsOf: control),
              let cmd = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if cmd["action"] as? String == "measure", !measureRequested {
            measureRequested = true
            onMeasure?()
            onMeasure = nil
        }
        guard !leakStarted, cmd["action"] as? String == "leak" else { return }
        leakStarted = true
        let count = cmd["count"] as? Int ?? 100
        let url = cmd["url"] as? String ?? "about:blank"
        let timeout = cmd["page_timeout_seconds"] as? Double ?? 20
        leakCycle(remaining: count, opened: 0, closed: 0, url: url, timeout: timeout)
    }

    /// Opens a real engine tab, waits for its load (bounded), closes it and drops its page; 100 times, one at a time.
    private func leakCycle(remaining: Int, opened: Int, closed: Int, url: String, timeout: Double) {
        guard remaining > 0 else {
            // Let the engine finish destroying the last pages, then report.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                try? c.store.flush()
                emit(["event": "leak_closed", "opened": opened, "closed": closed, "tabs_now": c.store.state.tabs.count])
            }
            return
        }
        let space = c.store.orderedSpaces[0].id
        guard let tab = try? c.store.openTab(url: url, inSpace: space, activate: false, title: url),
              let page = c.loadPageInBackground(tab.id) else {
            return leakCycle(remaining: remaining - 1, opened: opened, closed: closed, url: url, timeout: timeout)
        }
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if page.isLoading, Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: poll)
                return
            }
            c.discardScratchTab(tab.id)
            DispatchQueue.main.async { [self] in
                leakCycle(remaining: remaining - 1, opened: opened + 1, closed: closed + 1, url: url, timeout: timeout)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: poll)
    }

    // MARK: Helpers

    /// This process's physical footprint (what Activity Monitor calls Memory), decimal MB.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1e6 : 0
    }

    private func ms(_ s: Double) -> Double { round2(s * 1000) }
    private func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
    private func median(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.sorted()[a.count / 2] }
}
#endif
