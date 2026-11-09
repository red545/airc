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
        // Profiling one action: AIRC_FRAMES_ONLY=newspace|cbfirst|cbnew|cburl|cbkey|switch|swipe|folder|sidebar|previewcache (and AIRC_FRAMES_RUNS) runs only
        // that one.
        let env = ProcessInfo.processInfo.environment
        let only = env["AIRC_FRAMES_ONLY"]
        let runs = env["AIRC_FRAMES_RUNS"].flatMap(Int.init) ?? 10
        func wanted(_ name: String) -> Bool { only == nil || only == name }
        if only == "mem3" { gapMemoryScenario(); return }
        seedFramesWorkload()
        run { [self] in clock.start(on: c.root) }
        if FrameProbe.enabled {
            run { [self] in
                note("frames: probe on, main run loop observers (order activities callout): " + FrameProbe.observers())
                note("frames: probe commit phases available \(class_getClassMethod(CATransaction.self, Selector(("addCommitHandler:forPhase:"))) != nil)")
                FrameProbe.watchKeyViewLookups()
                MainThreadSampler.shared.start()
            }
        }
        wait(1.5)
        run { [self] in
            framesEnvViolations = []
            report["refresh_hz"] = clock.refreshHz.map(FrameStats.round2) ?? NSNull()
            report["display_frames"] = clock.running
            report["environment_start"] = framesEnvironment()
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
                FrameProbe.begin("newspace \(i)", tag: 400 + i)
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
            for n in 0..<((wanted(mode == .newTab ? "cbnew" : "cburl") || (only == "cbfirst" && mode == .newTab)) ? runs : 0) {
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
                    FrameProbe.begin("\(only == "cbfirst" ? "cbfirst" : key) \(n)", tag: 300 + n)
                    presented(clock, { self.c.openCommandBar(mode: mode) }) { samples.append($0); MainThreadSampler.tag = 0; done() }
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

        if wanted("feedback") {
            var samples: [FrameSample] = []
            var pressed = 0
            for _ in 0..<runs {
                step { [self] done in
                    guard let page = c.sidebar.pager.pages.first(where: { $0.spaceID == c.currentSpaceID }),
                          let row = page.rows.values.compactMap({ $0 as? TabRowView }).first(where: { $0.tabID == c.shownTabID }),
                          let event = NSEvent.mouseEvent(with: .leftMouseDown,
                            location: row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil),
                            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                    else { return done() }
                    // mouseDown enters AppKit's nested tracking loop. Observe its first
                    // commit BEFORE entering, and release with an in-process event.
                    let start = CACurrentMediaTime()
                    var commit: Double?
                    let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in
                        if commit == nil && row.isPressed {
                            commit = CACurrentMediaTime(); pressed += 1
                        }
                    }
                    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
                    let release = Timer(timeInterval: 0.15, repeats: false) { _ in
                        if let up = NSEvent.mouseEvent(with: .leftMouseUp, location: event.locationInWindow,
                            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: event.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) {
                            NSApp.postEvent(up, atStart: false)
                        }
                    }
                    RunLoop.main.add(release, forMode: .common)
                    row.mouseDown(with: event)
                    CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
                    release.invalidate()
                    row.mouseUp(with: event)
                    if let commit {
                        let shown = clock.presented(after: commit)
                        let preceding = clock.ticks.last { $0 <= start }
                        samples.append(FrameSample(work: (CACurrentMediaTime() - start) * 1000,
                            commit: (commit - start) * 1000, presented: shown.map { ($0 - start) * 1000 },
                            frames: shown.flatMap { t in preceding.map { Int(((t - $0) / (clock.interval ?? (1 / 120))).rounded()) } }))
                    }
                    done()
                }
                wait(0.3)
            }
            run { report["feedback"] = FrameSample.json(samples, budget: 1000 / 120)
                report["feedback_pressed"] = pressed }
        }

        if wanted("suggestions") {
            var samples: [Double] = []
            var correct = 0
            run { [self] in report["suggestions_interceptor_installed"] = GapSuggestionProtocol.install(); c.openCommandBar(mode: .newTab) }
            wait(0.4)
            for i in 0..<runs {
                step { [self] done in
                    let query = "gapquery\(i)"
                    let start = CACurrentMediaTime()
                    c.commandBar?.type(query)
                    gapPoll({ self.c.commandBar?.resultTitles.contains(where: { $0.contains(query + " loopback") }) == true }, timeout: 2) {
                        if self.c.commandBar?.resultTitles.contains(where: { $0.contains(query + " loopback") }) == true {
                            correct += 1; samples.append((CACurrentMediaTime() - start) * 1000)
                        }
                        done()
                    }
                }
                wait(0.2)
            }
            run { [self] in
                report["suggestions_samples_ms"] = samples; report["suggestions_correct"] = correct
                report["suggestions_loopback_requests"] = GapSuggestionProtocol.requests
                c.closeCommandBar(); GapSuggestionProtocol.uninstall()
            }
        }

        // Verify actual tab AND history rows before the keystroke's first commit.
        if wanted("cbkey") {
            var keys: [FrameSample] = []
            var rows: [[String: Any]] = []
            run { [self] in
                let profile = c.store.profile(ofSpace: c.currentSpaceID).id
                for i in 0..<runs {
                    app?.history.recordVisit(profileID: profile, url: "https://history.example/gap\(i)", title: "gap\(i) history", typed: true)
                    _ = try? c.store.openTab(url: Self.page("gap\(i) tab"), inSpace: c.currentSpaceID, activate: false, title: "gap\(i) tab")
                }
                c.reloadAll(animated: false); c.openCommandBar(mode: .newTab)
            }
            wait(1)
            for i in 0..<runs {
                step { [self] done in
                    var start = 0.0
                    var historyAt: Double?
                    var tabFound = false
                    c.commandBar?.onHistoryApplied = { n in if n > 0 { historyAt = CACurrentMediaTime() } }
                    presented(clock, {
                        start = CACurrentMediaTime(); self.c.commandBar?.type("gap\(i)")
                        tabFound = self.c.commandBar?.results.contains { if case .tab = $0.action { return $0.title == "gap\(i) tab" }; return false } == true
                    }) { sample in
                        keys.append(sample)
                        let results = self.c.commandBar?.results ?? []
                        rows.append(["history_ms": historyAt.map { ($0 - start) * 1000 } ?? NSNull(),
                                     "history_before_commit": historyAt.map { $0 <= start + sample.commit / 1000 } ?? false,
                                     "tab_found": tabFound,
                                     "history_found": results.contains { $0.historyURL == "https://history.example/gap\(i)" }])
                        done()
                    }
                }
                wait(0.2)
            }
            run { [self] in
                c.commandBar?.onHistoryApplied = nil; c.closeCommandBar()
                report["command_bar_key"] = FrameSample.json(keys, budget: 8.0)
                report["local_results"] = rows
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
        var swipeTicks: [[Double]] = []
        for i in 0..<(only == nil ? 6 : only == "swipe" ? runs : 0) {
            step { [self] done in
                guard clock.isTicking else { return done() }
                let before = CACurrentMediaTime()
                let envBefore = framesEnvironmentProblem()
                FrameProbe.begin("swipe \(i)", tag: 100 + i)
                swipe(clock, towardsNext: i % 2 == 0) { [self] d in
                    // P02: a swipe with the window off screen at either end doesn't count.
                    if let why = envBefore ?? framesEnvironmentProblem() { framesEnvViolations.append("swipe: " + why); return done() }
                    swipeDeltas.append(d); swipeTicks.append(clock.ticks.filter { $0 >= before }); done()
                }
            }
            wait(0.3)
        }
        run { [self] in
            report["swipe_frames"] = DropStats(swipeDeltas, interval: clock.interval).json
            report["swipe_120hz"] = DropStats(swipeDeltas, interval: 1 / 120).json
            report["swipe_timestamps_s"] = swipeTicks
            note("frames: swipe " + DropStats(swipeDeltas, interval: clock.interval).description)
        }

        // SB-33: a folder closing and opening on its own curves (close: the ω 25 spring; open: 200 ms ease-out), toggle →
        // presented frame, then every frame. The toggle renders at once here (the store's change would render on the next
        // turn), so the sample includes the sidebar's re-render.
        var folderOpen: [FrameSample] = [], folderClose: [FrameSample] = []
        var folderOpenDeltas: [[Double]] = [], folderCloseDeltas: [[Double]] = []
        for _ in 0..<(only == nil ? 6 : only == "folder" ? runs : 0) {
            step { [self] done in
                guard let folder = c.store.pinnedRoots(ofSpace: c.currentSpaceID).first(where: { $0.kind == .folder }) else {
                    note("frames: no folder in the current Space")
                    return done()
                }
                let opening = folder.isCollapsed
                animation(clock, seconds: 0.45, {
                    self.c.toggleFolder(folder.id)
                    self.c.reloadAll(animated: true)
                }) { s, d in
                    if opening { folderOpen.append(s); folderOpenDeltas.append(d) } else { folderClose.append(s); folderCloseDeltas.append(d) }
                    done()
                }
            }
            wait(0.3)
        }
        if wanted("folder") {
            run { [self] in
                report["folder_open"] = FrameSample.json(folderOpen, budget: 16.7)
                report["folder_close"] = FrameSample.json(folderClose, budget: 16.7)
                report["folder_open_frames"] = DropStats(folderOpenDeltas, interval: clock.interval).json
                report["folder_close_frames"] = DropStats(folderCloseDeltas, interval: clock.interval).json
                note("frames: folder open " + FrameSample.text(folderOpen) + "; motion " + DropStats(folderOpenDeltas, interval: clock.interval).description)
                note("frames: folder close " + FrameSample.text(folderClose) + "; motion " + DropStats(folderCloseDeltas, interval: clock.interval).description)
            }
        }

        // Sidebar hide and show (⌘S): every frame of the 100–110 ms animation, the page reflowing. P02: started on a
        // vsync and ended on the first vsync that finds the sidebar at rest, so the duration is in whole frames, with the
        // frame deltas in between for drops.
        var hide: [Double] = [], show: [Double] = []
        var hideFrames: [Double] = [], showFrames: [Double] = []
        var hideDeltas: [[Double]] = [], showDeltas: [[Double]] = []
        for _ in 0..<(only == nil ? 5 : only == "sidebar" ? runs : 0) {
            for target: CGFloat in [0, 1] {
                step { [self] done in
                    guard clock.isTicking else { return done() }
                    let envBefore = framesEnvironmentProblem()
                    FrameProbe.begin("sidebar \(target == 0 ? "hide" : "show")", tag: target == 0 ? 200 : 201)
                    clock.atNextFrame { [self] vsync in
                        let start = CACurrentMediaTime()
                        c.toggleSidebar()
                        clock.everyFrame { [self] t in
                            let atRest = abs(c.sidebarFraction - target) < 0.001
                            if !atRest && t - vsync < 2 { return true }
                            if let why = envBefore ?? framesEnvironmentProblem() {
                                framesEnvViolations.append("sidebar: " + why)
                            } else if atRest {
                                if FrameProbe.enabled {
                                    FrameProbe.marks.append(["label": FrameProbe.label, "start_vsync_ms": vsync * 1000, "rest_vsync_ms": t * 1000,
                                                             "ticks_ms": clock.ticks.filter { $0 >= vsync && $0 <= t }.map { $0 * 1000 }])
                                }
                                let ms = (CACurrentMediaTime() - start) * 1000
                                let byFrames = (t - vsync) * 1000
                                if target == 0 { hide.append(ms); hideFrames.append(byFrames); hideDeltas.append(clock.deltas(from: vsync, to: t)) }
                                else { show.append(ms); showFrames.append(byFrames); showDeltas.append(clock.deltas(from: vsync, to: t)) }
                            }
                            DispatchQueue.main.async(execute: done)
                            return false
                        }
                    }
                }
                wait(0.3)
            }
        }
        if only == "dialogslide" { dialogDuringSidebarSlide() }
        if only == "devstrip" { developerStripAcrossSpaces() }
        run { [self] in
            report["sidebar_hide_samples_ms"] = hide
            report["sidebar_show_samples_ms"] = show
            report["sidebar_hide_vsync_ms"] = hideFrames.map(FrameStats.round2)
            report["sidebar_show_vsync_ms"] = showFrames.map(FrameStats.round2)
            report["sidebar_hide_frames"] = DropStats(hideDeltas, interval: clock.interval).json
            report["sidebar_show_frames"] = DropStats(showDeltas, interval: clock.interval).json
            report["environment_end"] = framesEnvironment()
            report["environment_violations"] = framesEnvViolations
            note("frames: sidebar hide \(FrameStats(hideFrames)) by vsync, show \(FrameStats(showFrames)); environment problems \(framesEnvViolations.count)")
            if FrameProbe.enabled {
                report["swipe_late_at"] = DropStats(swipeDeltas, interval: 1 / 120).lateAt
                note("frames: probe \(MainThreadSampler.shared.count) samples every \(MainThreadSampler.shared.interval) µs, full \(MainThreadSampler.shared.full)")
                note("frames: probe key-view lookups " + FrameProbe.keyViewSummary)
                FrameProbe.write(to: dir)
            }
            clock.stop()
        }
        // P02b: the harness symbolicates the probe's addresses with `atos -p`, which needs this process alive, and
        // writes probe-symbols.done when it has (at most 120 s).
        if FrameProbe.enabled {
            step { [self] done in
                waitUntil({ FileManager.default.fileExists(atPath: self.dir.appendingPathComponent("probe-symbols.done").path) }, timeout: 120) {
                    done()
                }
            }
        }
        run { [self] in
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: dir.appendingPathComponent("frames.json"))
            }
        }
    }

    /// P02b (`AIRC_FRAMES_ONLY=dialogslide`, Chromium, launched with `--airc-test=modalDialogs` and `--airc-data-dir`
    /// whose Chromium folder exists): a page's JS alert stays where the engine put it over the page card through ⌘S. The
    /// engine's dialog parent follows the page lazily while no dialog shows (bde185a), so: an alert shown right after a
    /// slide, before the lazy re-anchor, lands where one shown at rest does; an alert held through hide and show ends
    /// each slide at the same place relative to the card. Cancelled through the engine's test hook.
    private func dialogDuringSidebarSlide() {
        #if canImport(AircCore)
        guard let engine = app?.engine as? ChromiumEngine else { return run { [self] in note("dialogslide: Chromium only") } }
        let page = { self.c.shownTabID.flatMap { self.c.engineTab(for: $0) } }
        func dialogs() -> [[String: Any]] { page().map { engine.modalDialogState(for: $0)["dialogs"] as? [[String: Any]] ?? [] } ?? [] }
        func dialogWindow() -> NSWindow? {
            guard let n = (dialogs().first?["windowNumber"] as? NSNumber)?.intValue else { return nil }
            return NSApp.windows.first { $0.windowNumber == n }
        }
        /// The dialog's place relative to the page card on screen: centre x offset and top offset (points).
        func offset() -> (dx: CGFloat, top: CGFloat)? {
            guard let w = dialogWindow(), w.isVisible else { return nil }
            let card = c.window.convertToScreen(c.card.convert(c.card.bounds, to: nil))
            return (w.frame.midX - card.midX, card.maxY - w.frame.maxY)
        }
        func alert(_ name: String, _ got: @escaping ((dx: CGFloat, top: CGFloat)?) -> Void) {
            step { [self] done in
                page()?.evaluate("setTimeout(function(){alert('\(name)')}, 0); 1") { _ in }
                waitUntil({ offset() != nil }, timeout: 8) { got(offset()); done() }
            }
        }
        func cancel(_ name: String) {
            step { [self] done in
                let ok = page().map { engine.cancelModalDialog(in: $0) } ?? false
                waitUntil({ dialogs().isEmpty }, timeout: 4) {
                    self.check(ok && dialogs().isEmpty, "dialogslide: \(name): the alert closes (handler found \(ok))")
                    done()
                }
            }
        }
        func same(_ a: (dx: CGFloat, top: CGFloat)?, _ b: (dx: CGFloat, top: CGFloat)?) -> Bool {
            guard let a, let b else { return false }
            return abs(a.dx - b.dx) <= 1.5 && abs(a.top - b.top) <= 1.5
        }
        func text(_ o: (dx: CGFloat, top: CGFloat)?) -> String { o.map { String(format: "dx %.1f, top %.1f", $0.dx, $0.top) } ?? "no dialog" }
        /// With the window off screen AppKit defers dialogs: that's FAIL-ENV with the reason, never a pass.
        func verdict(_ ok: Bool, _ what: String) {
            if let why = framesEnvironmentProblem() { note("FAIL-ENV " + what + " (\(why))") } else { check(ok, what) }
        }
        var atRest: (dx: CGFloat, top: CGFloat)?
        // 1. At rest, sidebar shown: where the engine puts an alert over this card.
        alert("p02b rest") { o in atRest = o; verdict(o != nil, "dialogslide: an alert shows over the card at rest (\(text(o)))") }
        cancel("at rest")
        // 2. Right after a hide, before the parent's lazy re-anchor (150 ms): the dialog about to show re-anchors it.
        run { [self] in c.toggleSidebar() }
        wait(0.16)   // the slide (110 ms) is over; the lazy re-anchor isn't due yet
        alert("p02b after hide") { o in
            verdict(same(o, atRest), "dialogslide: an alert shown right after ⌘S hides the sidebar sits over the card as at rest (\(text(o)); at rest \(text(atRest)))")
        }
        cancel("after hide")
        run { [self] in c.toggleSidebar() }
        wait(0.5)
        // 3. Held through hide and show: at rest after each slide, at the same place relative to the card.
        alert("p02b held") { _ in }
        var mid: (dx: CGFloat, top: CGFloat)?
        run { [self] in c.toggleSidebar() }
        wait(0.05)
        run { mid = offset() }
        wait(0.35)
        run { [self] in
            let o = offset()
            verdict(same(o, atRest), "dialogslide: an alert held through ⌘S (hide) ends over the card as at rest (\(text(o)); mid-slide \(text(mid)))")
            c.toggleSidebar()
        }
        wait(0.4)
        run {
            let o = offset()
            verdict(same(o, atRest), "dialogslide: and through ⌘S (show) (\(text(o)))")
        }
        cancel("held")
        #else
        run { [self] in note("dialogslide: Chromium only") }
        #endif
    }

    /// P02b (`AIRC_FRAMES_ONLY=devstrip`): a hidden Developer Mode strip is no longer configured on every page render, so
    /// it must still show and hide with its page: a localhost page (Developer Mode turns on by itself there) shows it, a
    /// Space without one hides it, and coming back shows it again; an ordinary page hides it, the localhost one shows it.
    private func developerStripAcrossSpaces() {
        var server: LocalPageServer?
        var base = ""
        var tabID = ""
        let strip = { self.c.pageView(for: self.c.currentSpaceID)?.developerStrip }
        let shown = { (strip()?.isHidden == false) && (strip()?.window != nil) }
        step { [self] done in
            server = LocalPageServer(pages: ["/dev.html": "<title>devstrip</title><p>local</p><script>console.log('p02b')</script>"])
            guard let server else { return done() }
            server.start { port in
                base = port.map { "http://localhost:\($0)" } ?? ""
                done()
            }
        }
        run { [self] in
            guard !base.isEmpty, let t = try? c.store.openTab(url: base + "/dev.html", inSpace: c.currentSpaceID, title: "devstrip") else {
                return check(false, "devstrip: the loopback page opens")
            }
            tabID = t.id
            c.reloadAll(animated: false)
            c.show(t.id, focus: false)
        }
        step { [self] done in
            waitUntil({ self.c.engineTab(for: tabID)?.isLoading == false && shown() }, timeout: 10) {
                self.check(shown(), "devstrip: a localhost page shows the strip (count \(strip()?.countTitle ?? "-"))")
                done()
            }
        }
        let home = { self.c.store.orderedSpaces[0].id }, other = { self.c.store.orderedSpaces[1].id }
        run { [self] in c.switchToSpace(other(), animated: false) }
        wait(0.5)
        run { [self] in check(!shown(), "devstrip: a Space with no developer page has no strip") }
        run { [self] in c.switchToSpace(home(), animated: false); if c.shownTabID != tabID { c.show(tabID, focus: false) } }
        wait(0.5)
        run { [self] in check(shown(), "devstrip: back on its Space the strip shows again (count \(strip()?.countTitle ?? "-"))") }
        run { [self] in if let url = URL(string: Self.page("Ordinary page")) { c.engineTab(for: tabID)?.load(url) } }
        step { [self] done in
            waitUntil({ self.c.engineTab(for: tabID)?.title == "Ordinary page" && !shown() }, timeout: 8) {
                self.check(!shown(), "devstrip: an ordinary page in the same tab hides it")
                done()
            }
        }
        run { [self] in if let url = URL(string: base + "/dev.html") { c.engineTab(for: tabID)?.load(url) } }
        step { [self] done in
            waitUntil({ self.c.engineTab(for: tabID)?.title == "devstrip" && shown() }, timeout: 8) {
                self.check(shown(), "devstrip: and the localhost page shows it again")
                server?.stop()
                done()
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
        let unprobed = dirty ? { [self] in work(); note("frames: dirty after the action: " + ViewCensus.dirty(c.window)) } : work
        // P02b: with the probe on, the turn's phases and Core Animation's commit phases are marked too.
        var probeMarks: [String: Double] = [:]
        let probeLabel = FrameProbe.label
        let work = FrameProbe.enabled ? { unprobed(); FrameProbe.markTurn { probeMarks = $0 } } : unprobed
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
        let before = framesEnvironmentProblem()
        clock.atNextFrame { [self] vsync in
            let t0 = CACurrentMediaTime()
            FrameTiming.measure(work) { [self] t in
                let commit = t0 + t.frame / 1000
                let shown = clock.presented(after: commit)
                let interval = clock.interval ?? (1.0 / 120)
                var sample = FrameSample(work: t.work, commit: t.frame, presented: shown.map { ($0 - t0) * 1000 },
                                         frames: shown.map { Int((($0 - vsync) / interval).rounded()) })
                // P02: a sample only counts with the display really showing our window, start to end.
                if let why = before ?? framesEnvironmentProblem() {
                    sample.environment = why
                    framesEnvViolations.append(why)
                }
                if FrameProbe.enabled {
                    FrameProbe.marks.append(["label": probeLabel, "vsync_ms": vsync * 1000, "t0_ms": t0 * 1000, "commit_ms": sample.commit,
                                             "work_ms": sample.work, "presented_ms": sample.presented ?? -1, "frames": sample.frames ?? -1,
                                             "marks": probeMarks, "environment": sample.environment ?? ""])
                }
                done(sample)
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
            if FrameProbe.enabled, phase == .ended || i == 0 {
                FrameProbe.marks.append(["label": FrameProbe.label, (phase == .ended ? "release_vsync_ms" : "start_vsync_ms"): t * 1000,
                                         "at_ms": CACurrentMediaTime() * 1000])
            }
            i += 1
            return phase != .ended
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { done(clock.deltas(from: start, to: start + 0.7)) }
    }
}

/// The seeded tabs whose pages load in the background.
private var framesRecent: [String] = []
/// P02: samples taken while the display didn't really show the window (they're reported, never counted).
private var framesEnvViolations: [String] = []

extension SnapshotRunner {
    /// Why a frame sample wouldn't be a real presentation now: the screen locked, our window off the active Space or
    /// covered. Nil when the display shows it.
    func framesEnvironmentProblem() -> String? {
        if Self.screenLocked { return "the screen is locked" }
        if !c.window.isOnActiveSpace { return "the window isn't on the active Space" }
        if !c.window.occlusionState.contains(.visible) { return "the window is covered" }
        return nil
    }

    func framesEnvironment() -> [String: Any] {
        ["locked": Self.screenLocked, "active_space": c.window.isOnActiveSpace,
         "visible": c.window.occlusionState.contains(.visible), "key": c.window.isKeyWindow,
         "hid_idle_s": FrameStats.round2(CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!))]
    }
}

/// One action's timing: main-thread work, the commit, and the presented frame (ms from the action's start).
struct FrameSample {
    var work: Double
    var commit: Double
    var presented: Double?
    /// Vsyncs from the one the action started on to the one that shows it (1 = the next frame).
    var frames: Int?
    /// P02: why the sample doesn't count (the window off the active Space, covered, the screen locked); nil: it does.
    var environment: String? = nil

    static func json(_ s: [FrameSample], budget: Double) -> [String: Any] {
        let presented = s.compactMap(\.presented)
        return ["runs": s.count, "budget_ms": budget,
                "environment_violations": s.compactMap(\.environment),
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
    /// P02: where in its run each late frame fell (the delta's index from the run's start), to tell a hitch at a fixed
    /// point of an animation (its first frame, a page swap) from scattered drops.
    let lateAt: [Int]
    init(_ runs: [[Double]], interval: CFTimeInterval?) {
        deltas = runs.flatMap { $0 }
        let ms = (interval ?? 1.0 / 120) * 1000
        self.interval = ms
        self.runs = runs.count
        lateAt = runs.flatMap { run in run.indices.filter { run[$0] > ms * 1.5 } }
    }
    /// Gaps longer than 1.5 intervals.
    var late: [Double] { deltas.filter { $0 > interval * 1.5 } }
    var missed: Int { late.reduce(0) { $0 + Int(($1 / interval).rounded()) - 1 } }
    var json: [String: Any] {
        ["runs": runs, "frames": deltas.count, "late_frames": late.count, "missed_vsyncs": missed,
         "max_delta_ms": FrameStats.round2(deltas.max() ?? 0), "median_delta_ms": FrameStats.round2(FrameStats(deltas).median.isNaN ? 0 : FrameStats(deltas).median),
         "late_deltas_ms": late.map(FrameStats.round2), "late_at": lateAt]
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
// MARK: - P02b: where a late frame's time goes

/// `AIRC_FRAMES_PROBE=1` (P02b): a sampling profiler for the main thread while the measured actions run, so a late
/// commit or a late animation frame can be attributed to the code that ran in it (Instruments needs Developer Tools
/// access, which the build Mac doesn't grant without a prompt). A background thread suspends the main thread every
/// `AIRC_FRAMES_PROBE_US` µs (default 250), copies its frame-pointer chain into a preallocated buffer and resumes it.
/// Nothing allocates or locks while the main thread is stopped (it may hold malloc's lock). Diagnostic only: the
/// suspensions cost the main thread a few per cent, so probe runs never give the timing numbers.
final class MainThreadSampler: @unchecked Sendable {
    static let shared = MainThreadSampler()
    /// What the main thread is doing now (the scenario sets it; samples carry it).
    nonisolated(unsafe) static var tag = 0
    private let capacity = 6_000_000
    private let buffer = UnsafeMutablePointer<UInt64>.allocate(capacity: 6_000_000)
    private var used = 0
    private var mainThread: thread_act_t = 0
    private var stackLow: UInt64 = 0, stackHigh: UInt64 = 0
    private let lock = NSLock()
    private var running = false
    private var stopped = DispatchSemaphore(value: 0)
    private(set) var interval: useconds_t = 250
    private(set) var count = 0
    private(set) var full = false

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    /// Call on the main thread.
    func start() {
        guard !isRunning else { return }
        mainThread = pthread_mach_thread_np(pthread_self())
        let top = UInt64(UInt(bitPattern: pthread_get_stackaddr_np(pthread_self())))
        stackHigh = top
        stackLow = top - UInt64(pthread_get_stacksize_np(pthread_self()))
        interval = useconds_t(ProcessInfo.processInfo.environment["AIRC_FRAMES_PROBE_US"].flatMap(Int.init) ?? 250)
        lock.lock(); running = true; lock.unlock()
        stopped = DispatchSemaphore(value: 0)
        let t = Thread { [self] in loop() }
        t.qualityOfService = .userInteractive
        t.name = "p02b.sampler"
        t.start()
    }

    func stop() {
        lock.lock()
        let was = running
        running = false
        lock.unlock()
        if was { stopped.wait() }
    }

    private func loop() {
        while true {
            lock.lock()
            let go = running
            lock.unlock()
            if !go { break }
            sampleOnce()
            usleep(interval)
        }
        stopped.signal()
    }

    private func sampleOnce() {
        #if arch(arm64)
        guard used + 200 < capacity else { full = true; return }
        let tag = UInt64(bitPattern: Int64(Self.tag))
        let t = mach_absolute_time()
        guard thread_suspend(mainThread) == KERN_SUCCESS else { return }
        var state = arm_thread_state64_t()
        var n = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &state) { p in
            p.withMemoryRebound(to: natural_t.self, capacity: Int(n)) { thread_get_state(mainThread, ARM_THREAD_STATE64, $0, &n) }
        }
        if kr != KERN_SUCCESS { thread_resume(mainThread); return }
        let mask: UInt64 = 0x0000_7FFF_FFFF_FFFF   // pointer authentication bits off
        let start = used
        buffer[start] = t
        buffer[start + 1] = tag
        var i = start + 3
        buffer[i] = state.__pc & mask; i += 1
        let lrSlot = i; buffer[i] = state.__lr & mask; i += 1
        var fp = state.__fp
        var first = true
        while fp >= stackLow, fp + 16 <= stackHigh, fp & 7 == 0, i - start < 190 {
            guard let frame = UnsafePointer<UInt64>(bitPattern: UInt(fp)) else { break }
            let next = frame[0]
            let ret = frame[1] & mask
            if ret == 0 { break }
            if first, ret == buffer[lrSlot] { buffer[lrSlot] = 0 }   // the leaf had pushed its frame: LR is this caller
            first = false
            buffer[i] = ret; i += 1
            if next <= fp { break }
            fp = next
        }
        thread_resume(mainThread)
        buffer[start + 2] = UInt64(i - start - 3)
        used = i
        count += 1
        #endif
    }

    /// Writes `probe-samples.txt` (one sample per line: ms on CACurrentMediaTime's clock, tag, return addresses leaf
    /// first) and `probe-pcs.txt` (each address once, with dladdr's image and nearest exported symbol); clears.
    func write(to dir: URL) {
        stop()
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let toMs = Double(info.numer) / Double(info.denom) / 1e6
        var lines: [String] = []
        var pcs = Set<UInt64>()
        var i = 0
        while i < used {
            let t = Double(buffer[i]) * toMs
            let tag = Int64(bitPattern: buffer[i + 1])
            let depth = Int(buffer[i + 2])
            var frames: [String] = []
            for k in 0..<depth where buffer[i + 3 + k] != 0 {
                let pc = buffer[i + 3 + k]
                pcs.insert(pc)
                frames.append(String(pc, radix: 16))
            }
            lines.append(String(format: "%.4f %lld ", t, tag) + frames.joined(separator: " "))
            i += 3 + depth
        }
        try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("probe-samples.txt"), atomically: true, encoding: .utf8)
        var map: [String] = []
        for pc in pcs.sorted() {
            var d = Dl_info()
            var line = String(pc, radix: 16)
            if dladdr(UnsafeRawPointer(bitPattern: UInt(pc)), &d) != 0 {
                let image = d.dli_fname.map { String(cString: $0) } ?? "?"
                let base = UInt64(UInt(bitPattern: d.dli_fbase))
                let sym = d.dli_sname.map { String(cString: $0) } ?? "?"
                let off = pc &- UInt64(UInt(bitPattern: d.dli_saddr))
                line += " \(image) \(String(base, radix: 16)) \(sym)+\(off)"
            }
            map.append(line)
        }
        try? map.joined(separator: "\n").write(to: dir.appendingPathComponent("probe-pcs.txt"), atomically: true, encoding: .utf8)
        used = 0
        count = 0
    }
}

/// P02b probe marks: the phases of an action's run-loop turn and of its Core Animation commit, on CACurrentMediaTime's
/// clock (ms), written to `probe-marks.json` with the sampler's stacks.
enum FrameProbe {
    static let enabled = ProcessInfo.processInfo.environment["AIRC_FRAMES_PROBE"] == "1"
    nonisolated(unsafe) static var marks: [[String: Any]] = []
    /// The action being measured ("cbfirst 0"); samples carry `MainThreadSampler.tag`.
    nonisolated(unsafe) static var label = ""

    static func begin(_ label: String, tag: Int) {
        self.label = label
        MainThreadSampler.tag = tag
    }

    /// `CATransaction`'s commit phases (`addCommitHandler:forPhase:`, not in the public header: 0 before layout, 1 before
    /// the commit, 2 after it). False when the runtime doesn't have it.
    @discardableResult
    static func onCommitPhase(_ phase: Int32, _ block: @escaping () -> Void) -> Bool {
        let sel = Selector(("addCommitHandler:forPhase:"))
        guard let m = class_getClassMethod(CATransaction.self, sel) else { return false }
        typealias F = @convention(c) (AnyClass, Selector, @escaping @convention(block) () -> Void, Int32) -> Void
        unsafeBitCast(method_getImplementation(m), to: F.self)(CATransaction.self, sel, block, phase)
        return true
    }

    /// After `work` (inside its run-loop turn): when the turn reaches its before-waiting observers (order 0), the one
    /// just before Core Animation's (order 1999999), and CA's own commit phases. `done` gets the marks (ms).
    static func markTurn(_ done: @escaping ([String: Double]) -> Void) {
        var m: [String: Double] = [:]
        let now = { CACurrentMediaTime() * 1000 }
        m["work_end"] = now()
        let phases = ["ca_pre_layout", "ca_pre_commit", "ca_post_commit"]
        for (i, name) in phases.enumerated() { onCommitPhase(Int32(i)) { if m[name] == nil { m[name] = now() } } }
        for (order, name) in [(0, "bw_first"), (1_999_999, "bw_before_ca"), (Int.max, "bw_after_ca")] {
            let o = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex(order)) { _, _ in
                if m[name] == nil { m[name] = now() }
                if name == "bw_after_ca" { done(m) }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
        }
    }

    /// The main run loop's observers, once (their orders say which runs before Core Animation's commit).
    static func observers() -> String {
        let d = CFCopyDescription(CFRunLoopGetMain()) as String
        return d.components(separatedBy: "\n").filter { $0.contains("CFRunLoopObserver") }
            .map { line -> String in
                let order = line.range(of: "order = ").map { String(line[$0.upperBound...].prefix { $0 != "," }) } ?? "?"
                let callout = line.range(of: "callout = ").map { String(line[$0.upperBound...].prefix { $0 != " " && $0 != "(" }) } ?? "?"
                let act = line.range(of: "activities = ").map { String(line[$0.upperBound...].prefix { $0 != "," }) } ?? "?"
                return "\(order) \(act) \(callout)"
            }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: "; ")
    }

    /// AppKit's key-view lookups (`nextValidKeyView`, `previousValidKeyView`) by receiver class: calls and ms. With no
    /// key loop of its own a view's lookup walks the whole window (P02b: AutoFill asks after every focus).
    nonisolated(unsafe) static var keyViewLookups: [String: (calls: Int, ms: Double)] = [:]

    static func watchKeyViewLookups() {
        for name in ["nextValidKeyView", "previousValidKeyView"] {
            let sel = Selector(name)
            guard let m = class_getInstanceMethod(NSView.self, sel) else { continue }
            typealias F = @convention(c) (NSView, Selector) -> NSView?
            let original = unsafeBitCast(method_getImplementation(m), to: F.self)
            let block: @convention(block) (NSView) -> NSView? = { v in
                let t = CACurrentMediaTime()
                let r = original(v, sel)
                let key = name + " " + String(describing: type(of: v))
                let old = keyViewLookups[key] ?? (0, 0)
                keyViewLookups[key] = (old.calls + 1, old.ms + (CACurrentMediaTime() - t) * 1000)
                return r
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
    }

    static var keyViewSummary: String {
        keyViewLookups.sorted { $0.value.ms > $1.value.ms }.map { String(format: "%@ ×%d %.2f ms", $0.key, $0.value.calls, $0.value.ms) }
            .joined(separator: ", ")
    }

    static func write(to dir: URL) {
        let value: [String: Any] = ["pid": Int(getpid()), "marks": marks, "key_view_lookups": keyViewSummary, "interval_us": Int(MainThreadSampler.shared.interval),
                                    "samples": MainThreadSampler.shared.count, "full": MainThreadSampler.shared.full]
        MainThreadSampler.shared.write(to: dir)
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("probe-marks.json"))
        }
    }
}
#endif
