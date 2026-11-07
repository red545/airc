// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit
import QuartzCore
import os

/// `--script frames` (app pass 6): the §2.12 budgets measured to the presented frame, for runs with the display on.
///
/// Every action starts in a display-link callback, right after a vsync, so its time to the presented frame is a whole
/// number of frames: 1 means it showed on the very next vsync (the "within one frame" budgets). "Presented" is the
/// first vsync after the Core Animation commit that carries the change (the earliest the render server can show it).
/// Animations are checked frame to frame: a gap between display-link callbacks longer than 1.5 intervals is a frame
/// the main thread missed. Synthetic data only: local pages, made-up names. Results go to `frames.json` and the log.
extension SnapshotRunner {
    func framesScenario() {
        let clock = FrameClock()
        var report: [String: Any] = ["engine": app?.engine.name ?? "?"]
        // Profiling one action: AIRC_FRAMES_ONLY=newspace|cbfirst|cbnew|cburl|cbkey|switch|swipe|sidebar|previewcache (and AIRC_FRAMES_RUNS) runs only
        // that one.
        let env = ProcessInfo.processInfo.environment
        let only = env["AIRC_FRAMES_ONLY"]
        let runs = env["AIRC_FRAMES_RUNS"].flatMap(Int.init) ?? 10
        func wanted(_ name: String) -> Bool { only == nil || only == name }
        seedFramesWorkload()
        run { [self] in clock.start(on: c.root) }
        wait(1.5)
        run { [self] in
            report["refresh_hz"] = clock.refreshHz.map(FrameStats.round2) ?? NSNull()
            report["display_frames"] = clock.running
            report["load"] = Self.loadAverage()
            let census = ViewCensus(window: c.window)
            report["views"] = census.summary
            note("frames: views " + census.description)
            report["idle_layout_ms"] = FrameStats(idleLayoutPasses()).json
            note("frames: text probe " + Self.textProbe())
            note("frames: refresh \(report["refresh_hz"]!) Hz, idle window layout pass \(FrameStats(idleLayoutPasses()))")
        }

        // The page card's own cost per size change (a window resize, ⌘S and the Library change it every frame): its
        // frame, layout and the Core Animation commit that carries them, 60 one-point steps. No display needed.
        if wanted("card") {
            run { [self] in
                let card = c.card
                let base = card.frame
                var ms: [Double] = []
                for i in 1...60 {
                    let t0 = CACurrentMediaTime()
                    card.frame = NSRect(x: base.minX, y: base.minY, width: base.width - CGFloat(i), height: base.height - CGFloat(i % 2))
                    card.layoutSubtreeIfNeeded()
                    CATransaction.flush()
                    ms.append((CACurrentMediaTime() - t0) * 1000)
                }
                c.layoutRoot()
                CATransaction.flush()
                ms.sort()
                let q = { (f: Double) in ms[min(ms.count - 1, Int(Double(ms.count) * f))] }
                report["card_resize_ms"] = ["median": FrameStats.round2(q(0.5)), "p95": FrameStats.round2(q(0.95)), "max": FrameStats.round2(ms.last ?? 0)]
                note(String(format: "frames: card resize step (frame, layout, commit) median %.3f ms, p95 %.3f ms, max %.3f ms", q(0.5), q(0.95), ms.last ?? 0))
            }
        }

        // A full-session cache control: thirty independent page-sized bitmaps, no screen capture.
        // The ordinary hidden 30-page workload may keep no pictures, so measure this bound separately.
        if wanted("previewcache") && only != nil {
            run { [self] in
                let cache = TabPreviewCache.shared
                cache.removeAll()
                for i in 0..<30 {
                    guard let bitmap = CGContext(data: nil, width: 640, height: 400, bitsPerComponent: 8,
                                                 bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                    bitmap.setFillColor(CGColor(red: CGFloat(i) / 30, green: 0.4, blue: 0.6, alpha: 1))
                    bitmap.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
                    if let image = bitmap.makeImage() {
                        cache.store(image, url: "https://example.com/", tab: "cache-\(i)", item: nil)
                    }
                }
                let count = cache.count, bytes = cache.storedBytes
                let lru = (0..<30).allSatisfy { i in
                    let retained = cache.shot(tab: "cache-\(i)", item: nil, url: "https://example.com/") != nil
                    return retained == (i >= 30 - min(30, TabPreviewCache.limit))
                }
                cache.trim(to: 8)
                let warningCount = cache.count
                cache.removeAll()
                report["preview_cache"] = ["entries": count, "bytes": bytes, "lru_correct": lru,
                                            "warning_entries": warningCount, "cleared_entries": cache.count]
                note("frames: preview cache \(count) entries, \(bytes) bytes; LRU \(lru)")
            }
        }

        // New Space: Create → presented frame (the Space is deleted again after each run).
        var newSpace: [FrameSample] = []
        var created = 0
        var correctFooters = 0
        for i in 0..<(wanted("newspace") ? runs : 0) {
            run { [self] in
                c.openNewSpacePanel()
                c.newSpacePanel?.model.name = "Frames \(i)"
            }
            wait(0.6)
            step { [self] done in
                guard c.newSpacePanel != nil else { note("frames: new space \(i): the card didn't open"); return done() }
                presented(clock, { self.c.newSpacePanel?.model.onCreate?() }) { newSpace.append($0); done() }
            }
            wait(0.5)
            run { [self] in
                if c.store.space(c.currentSpaceID)?.name == "Frames \(i)" { created += 1 }
                let footer = c.sidebar.footer.cellViews.compactMap { $0 as? SpaceBarView.SpaceCell }
                if footer.map(\.spaceID) == c.store.orderedSpaces.map(\.id),
                   zip(footer, c.store.orderedSpaces).allSatisfy({ cell, space in
                       let expected: String
                       switch space.icon {
                       case .emoji(let e)?: expected = e
                       case .symbol?: expected = "◆"
                       case nil: expected = ""
                       }
                       return cell.label.stringValue == expected
                   }) { correctFooters += 1 }
                if let s = c.store.orderedSpaces.first(where: { $0.name == "Frames \(i)" }) {
                    try? c.store.deleteSpace(s.id)
                    c.reloadAll(animated: false)
                    c.switchToSpace(c.store.orderedSpaces[0].id, animated: false)
                }
            }
            wait(0.4)
        }
        run { [self] in
            report["new_space"] = FrameSample.json(newSpace, budget: 8.3)
            report["new_space_created"] = created
            report["new_space_correct_footers"] = correctFooters
            note("frames: new space " + FrameSample.text(newSpace) + "; \(created) of \(newSpace.count) created and shown")
            let census = ViewCensus(window: c.window)
            report["views_after_new_space"] = census.summary
            note("frames: views after New Space " + census.description)
        }

        // Command bar: ⌘T and ⌘L, open → presented frame.
        for (key, mode) in [("command_bar_new_tab", CommandBarMode.newTab), ("command_bar_edit_url", .editURL)] {
            var samples: [FrameSample] = []
            var tabSwitches = 0
            for _ in 0..<((wanted(mode == .newTab ? "cbnew" : "cburl") || (only == "cbfirst" && mode == .newTab)) ? runs : 0) {
                if only == "cbfirst" {
                    run { [self] in
                        let tabs = c.store.todayTabs(ofSpace: c.currentSpaceID).filter { c.engineTab(for: $0.id) != nil }
                        if let other = tabs.first(where: { $0.id != c.shownTabID }) {
                            c.show(other.id, focus: false)
                            if c.shownTabID == other.id { tabSwitches += 1 }
                        }
                    }
                    wait(0.25)
                }
                step { [self] done in
                    presented(clock, { self.c.openCommandBar(mode: mode) }) { samples.append($0); done() }
                }
                wait(0.35)
                run { [self] in c.closeCommandBar() }
                wait(0.35)
            }
            run { [self] in
                report[key] = FrameSample.json(samples, budget: 8.0)
                report[key + "_tab_switches"] = tabSwitches
                note("frames: \(key) " + FrameSample.text(samples))
            }
        }

        // A keystroke in the open bar (local results in its frame): the query alternates so every key changes them.
        var keys: [FrameSample] = []
        if wanted("cbkey") {
            run { [self] in c.openCommandBar(mode: .newTab) }
            wait(0.4)
            for i in 0..<runs {
                step { [self] done in
                    let text = ["w", "wi", "wik", "wiki", "g", "gi", "git", "gith"][i % 8]
                    presented(clock, { self.c.commandBar?.type(text) }) { keys.append($0); done() }
                }
                wait(0.2)
            }
            run { [self] in
                c.closeCommandBar()
                report["command_bar_key"] = FrameSample.json(keys, budget: 8.0)
                note("frames: command_bar_key " + FrameSample.text(keys))
            }
        }

        // Space switch by click or key: input → presented frame, then every frame of the slide.
        var switches: [FrameSample] = []
        var switchDeltas: [[Double]] = []
        for i in 0..<(wanted("switch") ? runs : 0) {
            step { [self] done in
                let spaces = c.store.orderedSpaces
                let target = spaces[i % 2 == 0 ? 1 : 0].id
                animation(clock, seconds: 0.4, { self.c.switchToSpace(target, animated: true) }) { s, d in
                    switches.append(s); switchDeltas.append(d); done()
                }
            }
            wait(0.25)
        }
        run { [self] in
            report["space_switch"] = FrameSample.json(switches, budget: 16.7)
            report["space_switch_frames"] = DropStats(switchDeltas, interval: clock.interval).json
            note("frames: space switch " + FrameSample.text(switches) + "; slide " + DropStats(switchDeltas, interval: clock.interval).description)
        }
        // A jump of three Spaces (⌃4 from the first): the main-thread spring.
        var jumpDeltas: [[Double]] = []
        for i in 0..<(only == nil ? 4 : 0) {
            step { [self] done in
                let spaces = c.store.orderedSpaces
                let target = spaces[i % 2 == 0 ? min(3, spaces.count - 1) : 0].id
                animation(clock, seconds: 0.5, { self.c.switchToSpace(target, animated: true) }) { _, d in jumpDeltas.append(d); done() }
            }
            wait(0.25)
        }
        run { [self] in
            report["space_jump_frames"] = DropStats(jumpDeltas, interval: clock.interval).json
            note("frames: space jump " + DropStats(jumpDeltas, interval: clock.interval).description)
        }

        // Swipe: a two-finger swipe of half a page over 0.2 s, released, then the settle. Display-link driven, so
        // only with the display on (the settle never runs otherwise).
        var swipeDeltas: [[Double]] = []
        for i in 0..<(only == nil ? 6 : only == "swipe" ? runs : 0) {
            step { [self] done in
                guard clock.isTicking else { return done() }
                swipe(clock, towardsNext: i % 2 == 0) { d in swipeDeltas.append(d); done() }
            }
            wait(0.3)
        }
        run { [self] in
            report["swipe_frames"] = DropStats(swipeDeltas, interval: clock.interval).json
            note("frames: swipe " + DropStats(swipeDeltas, interval: clock.interval).description)
        }

        // Sidebar hide and show (⌘S): every frame of the 100–110 ms animation, the page reflowing.
        var hideDeltas: [[Double]] = [], showDeltas: [[Double]] = []
        for _ in 0..<(only == nil ? 5 : only == "sidebar" ? runs : 0) {
            step { [self] done in
                guard clock.isTicking else { return done() }
                animation(clock, seconds: 0.25, { self.c.toggleSidebar() }) { _, d in hideDeltas.append(d); done() }
            }
            wait(0.3)
            step { [self] done in
                guard clock.isTicking else { return done() }
                animation(clock, seconds: 0.25, { self.c.toggleSidebar() }) { _, d in showDeltas.append(d); done() }
            }
            wait(0.3)
        }
        run { [self] in
            report["sidebar_hide_frames"] = DropStats(hideDeltas, interval: clock.interval).json
            report["sidebar_show_frames"] = DropStats(showDeltas, interval: clock.interval).json
            note("frames: sidebar hide " + DropStats(hideDeltas, interval: clock.interval).description)
            note("frames: sidebar show " + DropStats(showDeltas, interval: clock.interval).description)
            clock.stop()
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: dir.appendingPathComponent("frames.json"))
            }
        }
    }

    /// 3 profiles, 6 Spaces in different themes, pinned rows and a folder, Favorites, 30 Today tabs; 8 pages loaded.
    /// Pages are local `data:` documents, so nothing touches the network.
    private func seedFramesWorkload() {
        run { [self] in
            let store = c.store
            do {
                let first = store.defaultProfile
                let work = try c.profiles.createProfile(name: "Work", emoji: "", color: nil)
                let studio = try c.profiles.createProfile(name: "Studio", emoji: "", color: nil)
                let profiles = [first.id, work.id, studio.id]
                let themes = ["mint", "sky", "grape", "paper", "lemon", "sky"]
                var ids: [String] = [store.selectedSpace.id]
                try store.updateSpace(ids[0]) { $0.name = "Space 1"; $0.icon = .emoji("🏠"); $0.theme = DesignTheme.preset("mint")!.model }
                for i in 1..<6 {
                    let s = try store.createSpace(name: "Space \(i + 1)", icon: .emoji(["💼", "🎨", "📚", "🌱", "✈️"][i - 1]),
                                                  theme: DesignTheme.preset(themes[i])!.model, profileID: profiles[i % 3], after: ids.last!)
                    ids.append(s.id)
                }
                for (p, profile) in profiles.enumerated() {
                    for f in 0..<3 {
                        try favorite(Self.page("Favorite \(p)-\(f)"), title: "Favorite \(f + 1)", icon: nil, profile: profile,
                                     space: ids[p])
                    }
                }
                var recent: [String] = []
                for (i, sid) in ids.enumerated() {
                    for k in 0..<3 { try pin(Self.page("Pinned \(i)-\(k)"), title: "Pinned page \(k + 1)", icon: nil, space: sid) }
                    let folder = try store.createFolder(named: "Folder", inSpace: sid)
                    for k in 0..<2 { try pin(Self.page("Folder \(i)-\(k)"), title: "Folder page \(k + 1)", icon: nil, space: sid, parent: folder.id) }
                    for k in 0..<5 {
                        let t = try store.openTab(url: Self.page("Today \(i)-\(k)"), inSpace: sid, activate: k == 0, title: "Today page \(k + 1)")
                        if k < 2, recent.count < 8 { recent.append(t.id) }
                    }
                }
                c.reloadAll(animated: false)
                c.switchToSpace(ids[0], animated: false)
                framesRecent = recent
                note("frames: seeded \(store.orderedProfiles.count) profiles, \(store.orderedSpaces.count) spaces, \(store.state.tabs.count) tabs")
            } catch {
                note("frames: seed failed: \(error)")
            }
        }
        step { [self] done in
            var remaining = c.store.orderedProfiles.count
            for p in c.store.orderedProfiles {
                c.profiles.whenLoaded(p.id) { _ in
                    remaining -= 1
                    if remaining == 0 { done() }
                }
            }
        }
        run { [self] in
            if let first = c.store.lastActiveTab(ofSpace: c.currentSpaceID) { c.show(first.id, focus: false) }
            for id in framesRecent { c.loadPageInBackground(id) }
        }
        wait(2)
        // Every Space shown once, so none is building its first page while it's measured.
        for i in 0..<6 {
            run { [self] in c.switchToSpace(c.store.orderedSpaces[min(i, c.store.orderedSpaces.count - 1)].id, animated: false) }
            wait(0.25)
        }
        run { [self] in c.switchToSpace(c.store.orderedSpaces[0].id, animated: false) }
        wait(1)
    }

    /// A short local page (about 200 characters of URL, like a real one) that writes enough text to reflow.
    static func page(_ name: String) -> String {
        let html = "<title>\(name)</title><body style='font:15px/1.5 system-ui;margin:40px'><h1>\(name)</h1><script>"
            + "document.write('<p>Synthetic text that wraps and reflows as the page resizes.</p>'.repeat(40))</script>"
        return "data:text/html," + (html.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "#&+"))) ?? "")
    }

    /// What one label's measure costs with the app's fonts (µs per call, 200 calls each).
    static func textProbe() -> String {
        func time(_ name: String, _ body: (Int) -> Void) -> String {
            let t = CACurrentMediaTime()
            for i in 0..<200 { body(i) }
            return String(format: "%@ %.1f µs", name, (CACurrentMediaTime() - t) / 200 * 1e6)
        }
        let row = AircFont.row.appFont
        let plain = NSFont.systemFont(ofSize: row.pointSize)
        let text = "Today page 1 · a synthetic title"
        let attributed = NSAttributedString(string: text, attributes: [.font: row])
        return [
            "font \(row.fontName) \(row.pointSize)",
            time("size, same string") { _ in _ = attributed.size() },
            time("size, new string") { i in _ = NSAttributedString(string: text + "\(i)", attributes: [.font: row]).size() },
            time("size, plain system font") { i in _ = NSAttributedString(string: text + "\(i)", attributes: [.font: plain]).size() },
            time("appFont getter") { _ in _ = AircFont.row.appFont },
            time("CTLine new string") { i in
                _ = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: text + "\(i)", attributes: [.font: row])), nil, nil, nil)
            },
        ].joined(separator: ", ")
    }

    /// Times an empty window layout pass (nothing moves): what AppKit's tree walk costs on every commit.
    private func idleLayoutPasses() -> [Double] {
        (0..<30).map { _ in
            c.root.needsLayout = true
            let t = CACurrentMediaTime()
            c.window.layoutIfNeeded()
            return (CACurrentMediaTime() - t) * 1000
        }
    }

    /// Starts `work` right after a vsync and reports the frame that presents it.
    private func presented(_ clock: FrameClock, _ work: @escaping () -> Void, _ done: @escaping (FrameSample) -> Void) {
        let dirty = ProcessInfo.processInfo.environment["AIRC_FRAMES_DIRTY"] == "1"
        let counting = ProcessInfo.processInfo.environment["AIRC_FRAMES_COUNT"] == "1"
        if counting { LayoutCounter.install(); LayoutCounter.reset() }
        let sections = ProcessInfo.processInfo.environment["AIRC_FRAMES_SECTIONS"] == "1"
        if dirty || sections { Perf.enabled = true; Perf.reset() }
        let work = dirty ? { [self] in work(); note("frames: dirty after the action: " + ViewCensus.dirty(c.window)) } : work
        let done = counting || sections ? { [self] (s: FrameSample) in
            if counting { note("frames: counted in the first frame: " + LayoutCounter.summary) }
            note("frames: sections (ms) " + Perf.report())
            done(s)
        } : done
        guard clock.isTicking else {
            // Display asleep: no frames to start on or to present in. The commit is all there is.
            DispatchQueue.main.async {
                FrameTiming.measure(work) { t in done(FrameSample(work: t.work, commit: t.frame, presented: nil, frames: nil)) }
            }
            return
        }
        clock.atNextFrame { vsync in
            let t0 = CACurrentMediaTime()
            FrameTiming.measure(work) { t in
                let commit = t0 + t.frame / 1000
                let shown = clock.presented(after: commit)
                let interval = clock.interval ?? (1.0 / 120)
                done(FrameSample(work: t.work, commit: t.frame, presented: shown.map { ($0 - t0) * 1000 },
                                 frames: shown.map { Int((($0 - vsync) / interval).rounded()) }))
            }
        }
    }

    /// `presented`, then the frame-to-frame deltas over `seconds` from the start.
    private func animation(_ clock: FrameClock, seconds: Double, _ work: @escaping () -> Void,
                           _ done: @escaping (FrameSample, [Double]) -> Void) {
        var start: CFTimeInterval = CACurrentMediaTime()
        if clock.isTicking { clock.atNextFrame { start = $0 } }
        let id = OSSignpostID(log: FrameTiming.signposts)
        os_signpost(.begin, log: FrameTiming.signposts, name: "animation", signpostID: id)
        presented(clock, work) { sample in
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds - 0.1)) {
                os_signpost(.end, log: FrameTiming.signposts, name: "animation", signpostID: id)
                done(sample, clock.deltas(from: start, to: start + seconds))
            }
        }
    }

    /// A trackpad swipe fed to the pager one event per frame (as the trackpad delivers them), then released.
    private func swipe(_ clock: FrameClock, towardsNext: Bool, _ done: @escaping ([Double]) -> Void) {
        let pager = c.sidebar.pager
        let frames = 24
        let step = pager.pageWidth * 0.55 / CGFloat(frames) / CGFloat(SwipePaging.trackingRatio)
        let dx = towardsNext ? -step : step
        var i = 0
        var start: CFTimeInterval = 0
        clock.everyFrame { t in
            if i == 0 { start = t }
            let phase: NSEvent.Phase = i == 0 ? .began : i < frames ? .changed : .ended
            pager.track(phase: phase, momentum: [], dx: phase == .ended ? 0 : dx, dy: 0, precise: true)
            i += 1
            return phase != .ended
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { done(clock.deltas(from: start, to: start + 0.7)) }
    }
}

/// The seeded tabs whose pages load in the background.
private var framesRecent: [String] = []

/// One action's timing: main-thread work, the commit, and the presented frame (ms from the action's start).
struct FrameSample {
    var work: Double
    var commit: Double
    var presented: Double?
    /// Vsyncs from the one the action started on to the one that shows it (1 = the next frame).
    var frames: Int?

    static func json(_ s: [FrameSample], budget: Double) -> [String: Any] {
        let presented = s.compactMap(\.presented)
        return ["runs": s.count, "budget_ms": budget,
                "presented_ms": FrameStats(presented).json, "commit_ms": FrameStats(s.map(\.commit)).json,
                "work_ms": FrameStats(s.map(\.work)).json,
                "frames": s.map { $0.frames.map { $0 as Any } ?? NSNull() },
                "next_frame_share": s.isEmpty ? 0 : FrameStats.round2(Double(s.filter { $0.frames == 1 }.count) / Double(s.count)),
                "presented_samples_ms": presented.map(FrameStats.round2),
                "commit_samples_ms": s.map { FrameStats.round2($0.commit) },
                "work_samples_ms": s.map { FrameStats.round2($0.work) }]
    }

    static func text(_ s: [FrameSample]) -> String {
        let f = s.compactMap(\.frames)
        return "presented \(FrameStats(s.compactMap(\.presented))), commit \(FrameStats(s.map(\.commit))), work \(FrameStats(s.map(\.work))), frames \(f)"
    }
}

struct FrameStats: CustomStringConvertible {
    let values: [Double]
    init(_ v: [Double]) { values = v.sorted() }
    var median: Double { values.isEmpty ? .nan : values[values.count / 2] }
    /// Nearest-rank p95 (with 10 runs, the second-largest value... rounded up to the largest).
    var p95: Double { values.isEmpty ? .nan : values[min(values.count - 1, Int((0.95 * Double(values.count)).rounded(.up)) - 1)] }
    var max: Double { values.last ?? .nan }
    var json: [String: Any] {
        values.isEmpty ? ["n": 0] : ["median": Self.round2(median), "p95": Self.round2(p95), "max": Self.round2(max), "n": values.count]
    }
    var description: String {
        values.isEmpty ? "n/a" : String(format: "median %.2f p95 %.2f max %.2f ms (n=%d)", median, p95, max, values.count)
    }
    static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
}

/// Frame-to-frame deltas of the display link during animations: how many vsyncs the main thread missed.
struct DropStats: CustomStringConvertible {
    let deltas: [Double]
    let interval: Double
    let runs: Int
    init(_ runs: [[Double]], interval: CFTimeInterval?) {
        deltas = runs.flatMap { $0 }
        self.interval = (interval ?? 1.0 / 120) * 1000
        self.runs = runs.count
    }
    /// Gaps longer than 1.5 intervals.
    var late: [Double] { deltas.filter { $0 > interval * 1.5 } }
    var missed: Int { late.reduce(0) { $0 + Int(($1 / interval).rounded()) - 1 } }
    var json: [String: Any] {
        ["runs": runs, "frames": deltas.count, "late_frames": late.count, "missed_vsyncs": missed,
         "max_delta_ms": FrameStats.round2(deltas.max() ?? 0), "median_delta_ms": FrameStats.round2(FrameStats(deltas).median.isNaN ? 0 : FrameStats(deltas).median),
         "late_deltas_ms": late.map(FrameStats.round2)]
    }
    var description: String {
        String(format: "%d frames over %d runs, %d late (%d vsyncs missed), max delta %.2f ms, interval %.2f ms", deltas.count, runs,
               late.count, missed, deltas.max() ?? 0, interval)
    }
}

/// The window's whole view tree, as AppKit's layout pass walks it (from the theme frame down, hidden views included).
struct ViewCensus: CustomStringConvertible {
    var total = 0
    var hidden = 0
    /// Views inside a hidden subtree (the hidden view included): walked on every pass, never drawn.
    var inHiddenSubtrees = 0
    /// Views that would make AppKit build a temporary Auto Layout engine (constraints, or no autoresizing translation).
    var autoLayout: [String] = []
    /// Views under each of the root view's children and each sidebar page.
    var parts: [(String, Int)] = []

    init(window: NSWindow) {
        guard let frame = window.contentView?.superview else { return }
        let engine = Selector(("_layoutEngine"))
        hasEngine = window.responds(to: engine) && window.perform(engine) != nil
        walk(frame, inHidden: false)
        if let root = window.contentView {
            for v in root.subviews { parts.append((String(describing: type(of: v)), Self.count(v))) }
            parts.append(("(theme frame minus content)", Self.count(frame) - Self.count(root)))
            if let pager = (root.subviews.first { $0 is SidebarView } as? SidebarView)?.pager {
                if let page = pager.strip.subviews.first {
                    var classes: [String: Int] = [:]
                    func tally(_ v: NSView) { classes[String(describing: type(of: v)), default: 0] += 1; v.subviews.forEach(tally) }
                    tally(page)
                    pageClasses = classes.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                }
                for p in pager.strip.subviews { parts.append(("page " + ((p as? SpacePageView)?.spaceID.prefix(6).description ?? "?") + (p.isHidden ? " (hidden)" : ""), Self.count(p))) }
            }
        }
    }

    /// Views holding constraints AppKit made from autoresizing masks (an engine has laid the window out).
    var autoresizing = 0
    /// Whether the window has an Auto Layout engine right now (AppKit's private `_layoutEngine`, debug only).
    var hasEngine = false

    private mutating func walk(_ v: NSView, inHidden: Bool) {
        total += 1
        let h = inHidden || v.isHidden
        if v.isHidden { hidden += 1 }
        if h { inHiddenSubtrees += 1 }
        let own = v.constraints.filter { !$0.isAutoresizing }
        if v.constraints.count > own.count { autoresizing += 1 }
        if !own.isEmpty || !v.translatesAutoresizingMaskIntoConstraints {
            let kinds = Set(own.map { String(describing: type(of: $0)) }).sorted().joined(separator: "/")
            autoLayout.append("\(type(of: v))[\(own.count) \(kinds)\(v.translatesAutoresizingMaskIntoConstraints ? "" : ", no tAMIC")] in \(v.superview.map { String(describing: type(of: $0)) } ?? "-")")
        }
        if String(describing: type(of: v)).contains("HostingView") {
            var chain: [String] = []
            var p = v.superview
            while let q = p, chain.count < 3 { chain.append(String(describing: type(of: q))); p = q.superview }
            hosting.append(chain.joined(separator: "<") + (h ? " (hidden)" : ""))
        }
        for s in v.subviews { walk(s, inHidden: h) }
    }

    /// SwiftUI hosting views and where they sit (each lays out its graph in the commit).
    var hosting: [String] = []
    /// The first attached sidebar page's views by class.
    var pageClasses = ""

    static func count(_ v: NSView) -> Int { 1 + v.subviews.reduce(0) { $0 + count($1) } }

    /// What the next commit will lay out and draw: views with needsLayout / needsDisplay set, by class.
    static func dirty(_ window: NSWindow) -> String {
        var layout: [String: Int] = [:], display: [String: Int] = [:]
        func walk(_ v: NSView, hidden: Bool) {
            let h = hidden || v.isHidden
            let name = String(describing: type(of: v)) + (h ? "(hidden)" : "")
            if v.needsLayout { layout[name, default: 0] += 1 }
            if v.needsDisplay { display[name, default: 0] += 1 }
            v.subviews.forEach { walk($0, hidden: h) }
        }
        if let f = window.contentView?.superview { walk(f, hidden: false) }
        func fmt(_ d: [String: Int]) -> String {
            "\(d.values.reduce(0, +)) [" + d.sorted { $0.value > $1.value }.prefix(14).map { "\($0.key) \($0.value)" }.joined(separator: ", ") + "]"
        }
        return "layout " + fmt(layout) + "; display " + fmt(display)
    }

    var summary: [String: Any] {
        ["total": total, "hidden": hidden, "in_hidden_subtrees": inHiddenSubtrees, "auto_layout": autoLayout,
         "autoresizing_holders": autoresizing, "window_engine": hasEngine, "hosting_views": hosting,
         "parts": Dictionary(parts.map { ($0.0, $0.1) }, uniquingKeysWith: +)]
    }

    var description: String {
        "\(total) views, \(hidden) hidden, \(inHiddenSubtrees) in hidden subtrees; window engine \(hasEngine), "
            + "\(autoresizing) views hold autoresizing constraints; own constraints: "
            + (autoLayout.isEmpty ? "none" : autoLayout.prefix(30).joined(separator: ", ") + (autoLayout.count > 30 ? " …(\(autoLayout.count))" : ""))
            + "; hosting views \(hosting.count): " + Dictionary(hosting.map { ($0, 1) }, uniquingKeysWith: +).map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
            + "; parts: " + parts.map { "\($0.0) \($0.1)" }.joined(separator: ", ") + "; a page: " + pageClasses
    }
}

private extension NSLayoutConstraint {
    var isAutoresizing: Bool { String(describing: type(of: self)) == "NSAutoresizingMaskLayoutConstraint" }
}

/// `AIRC_FRAMES_COUNT=1`: counts label layouts and text-field draws per action, by the part of the window they're in
/// (debug only: swizzles `-layout` on AircFadingLabel and `-drawRect:` on NSTextField for the run).
enum LayoutCounter {
    nonisolated(unsafe) static var layouts: [String: Int] = [:]
    nonisolated(unsafe) static var draws: [String: Int] = [:]
    nonisolated(unsafe) static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        swizzle(AircFadingLabel.self, #selector(NSView.layout)) { layouts[part(of: $0), default: 0] += 1 }
        swizzle(NSTextField.self, #selector(NSView.draw(_:)), rect: true) { draws[part(of: $0), default: 0] += 1 }
    }

    static func reset() { layouts = [:]; draws = [:] }

    static var summary: String {
        func fmt(_ d: [String: Int]) -> String {
            "\(d.values.reduce(0, +)) [" + d.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + "]"
        }
        return "label layouts " + fmt(layouts) + "; text draws " + fmt(draws)
    }

    private static func part(of v: NSView) -> String {
        var hidden = false
        var p: NSView? = v
        while let q = p {
            if q.isHidden { hidden = true }
            switch q {
            case is CommandBarView: return "command bar" + (hidden ? " (hidden)" : "")
            case let page as SpacePageView: return "page \(page.spaceID.prefix(4))" + (hidden ? " (hidden)" : "")
            case is SpaceBarView: return "footer"
            case is PageCardView: return "card"
            default: p = q.superview
            }
        }
        return "other"
    }

    private static func swizzle(_ cls: AnyClass, _ sel: Selector, rect: Bool = false, _ count: @escaping (NSView) -> Void) {
        guard let m = class_getInstanceMethod(cls, sel) else { return }
        let original = method_getImplementation(m)
        if rect {
            typealias F = @convention(c) (NSView, Selector, NSRect) -> Void
            let f = unsafeBitCast(original, to: F.self)
            let block: @convention(block) (NSView, NSRect) -> Void = { v, r in count(v); f(v, sel, r) }
            method_setImplementation(m, imp_implementationWithBlock(block))
        } else {
            typealias F = @convention(c) (NSView, Selector) -> Void
            let f = unsafeBitCast(original, to: F.self)
            let block: @convention(block) (NSView) -> Void = { v in count(v); f(v, sel) }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
    }
}
#endif
