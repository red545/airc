// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import IOKit
import AircKit
#if canImport(AircCore)
import AircCore
#endif

extension SnapshotRunner {
    /// No rAF dependency: hidden pages may suspend animation callbacks. Geometry and
    /// document identity distinguish a restored document from an initial blank page.
    func scrollRestoreSample(_ page: EngineTab, completion: @escaping ([String: Any]) -> Void) {
        page.evaluate("""
        ({x:scrollX,y:scrollY,height:document.documentElement.scrollHeight,
          viewport:innerHeight,ready:document.readyState,visibility:document.visibilityState,
          path:location.pathname,title:document.title,instance:window.scrollFixtureInstance || null})
        """) { [self] value in
            var sample = value as? [String: Any] ?? ["error": "no sample"]
            let window = c.window
            let locked = Self.screenLocked
            sample["screen_locked"] = locked
            sample["timestamp"] = Date().timeIntervalSince1970
            let visible = window.isVisible && window.isOnActiveSpace && window.occlusionState.contains(.visible)
                && !window.isMiniaturized && !NSApp.isHidden && !locked
            sample["window_visible"] = window.isVisible
            sample["window_on_active_space"] = window.isOnActiveSpace
            sample["window_occlusion_visible"] = window.occlusionState.contains(.visible)
            sample["window_occlusion_raw"] = window.occlusionState.rawValue
            sample["actual_group"] = visible ? "visible" : "hidden"
            // Read only: no posted input, activation, clipboard or display wake.
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
            if service != 0 {
                if let idle = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
                    sample["hid_idle_seconds"] = idle.doubleValue / 1_000_000_000
                }
                IOObjectRelease(service)
            }
            completion(sample)
        }
    }

    /// One process covers native timeout, pressure and explicit unload, ordered-front and
    /// ordered-out. Every sample is classified by actual visibility, not this intent.
    /// Run three fresh processes per engine. A short dwell diagnoses
    /// pending native history-state updates; the default is beyond the hidden 5 s sync.
    func scrollRestoreScenario() {
        if ProcessInfo.processInfo.environment["AIRC_SCROLL_AUX"] == "1" {
            scrollRestoreAuxScenario(); return
        }
        let dwell = min(10, max(0, Double(ProcessInfo.processInfo.environment["AIRC_SCROLL_DWELL"] ?? "6") ?? 6))
        var server: LocalPageServer?
        var port: UInt16 = 0
        var rows: [[String: Any]] = []
        let foregroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        run { [self] in
            if ProcessInfo.processInfo.environment["AIRC_SCROLL_ALL_SPACES"] == "1" {
                // A test-only visibility option: never activate or switch the owner's Space.
                c.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            }
        }
        step { [self] done in
            let body = """
            <!doctype html><meta charset='utf-8'><title>scroll fixture</title>
            <link rel='icon' href='/favicon.ico'><style>body{margin:0}main{height:6000px}</style>
            <main>scroll restore fixture<input id='draft' value=''></main>
            <script>window.scrollFixtureInstance=String(Date.now())+'-'+Math.random()</script>
            """
            server = LocalPageServer(responses: [
                "/page": .init(body: body), "/other": .init(body: "<!doctype html><title>other</title>other"),
                "/favicon.ico": .init(headers: ["Content-Type": "image/png"], body: "",
                    data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAFUlEQVR4nGNgYPhPIhrVMKph2GoAAJLb/wFh5Z4RAAAAAElFTkSuQmCC"))
            ])
            guard let server else { check(false, "scroll: server created"); return done() }
            server.start { p in port = p ?? 0; self.check(port != 0, "scroll: server listening"); done() }
        }
        step { [self] done in
            // Warm this fixture's icon before creating tabs. A guessed loopback
            // favicon can omit the ephemeral port and put the host into retry
            // cooldown; a missing initial icon cannot test retention/restoration.
            guard let url = URL(string: "http://127.0.0.1:\(port)/favicon.ico") else { return done() }
            var answered = false
            func finish(_ ready: Bool) {
                guard !answered else { return }
                answered = true
                check(ready, "scroll: fixture favicon is available before measuring restoration")
                done()
            }
            FaviconCache.shared.load(url, retrying: true) { finish($0 != nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { finish(false) }
        }
        for hidden in [false, true] {
            for cause in ["timeout", "pressure", "manual"] {
                let label = "\(hidden ? "hidden" : "visible")/\(cause)"
                var id: String?, other: String?
                var initial: [String: Any] = [:]
                var row: [String: Any] = ["case": label, "dwell_seconds": dwell]
                var favicon: String?
                var didUnload = false
                let frames = FrameClock()
                run { [self] in
                    WindowController.unloadOverride = 86400
                    c.applyUnloadSetting()
                    // Ordering front never makes this window key or activates the app.
                    if hidden { c.window.orderOut(nil) } else { c.window.orderFront(nil) }
                    id = (try? c.store.openTab(url: "http://127.0.0.1:\(port)/page", inSpace: c.currentSpaceID, activate: false))?.id
                    other = (try? c.store.openTab(url: "http://127.0.0.1:\(port)/other", inSpace: c.currentSpaceID, activate: false))?.id
                    c.reloadAll(animated: false)
                    if let id { c.show(id, focus: false) }
                    if !hidden, let view = c.window.contentView { frames.start(on: view) }
                }
                step { [self] done in
                    waitUntil({ id.flatMap { self.c.engineTab(for: $0) }?.title == "scroll fixture"
                        && id.flatMap { self.c.engineTab(for: $0) }?.isLoading == false }, timeout: 10) { done() }
                }
                step { [self] done in
                    waitUntil({ id.flatMap { self.c.store.tab($0)?.faviconURL } != nil }, timeout: 5) { done() }
                }
                step { [self] done in
                    guard let page = id.flatMap({ c.engineTab(for: $0) }) else {
                        check(false, "\(label): page exists"); return done()
                    }
                    page.evaluate("scrollTo(0,700)") { _ in
                        self.scrollRestoreSample(page) { sample in
                            initial = sample; row["before"] = sample
                            self.check((sample["y"] as? Double) == 700 && (sample["height"] as? Double ?? 0) >= 6000,
                                       "\(label): fixture scrolls to 700")
                            done()
                        }
                    }
                }
                wait(dwell)
                run { [self] in
                    row["display_ticks_before"] = frames.ticks.count
                    row["display_ticking_before"] = frames.isTicking
                    row["window_visible_before"] = c.window.isVisible
                    row["window_occlusion_visible_before"] = c.window.occlusionState.contains(.visible)
                    row["foreground_unchanged_before"] = foregroundPID == NSWorkspace.shared.frontmostApplication?.processIdentifier
                    row["window_on_active_space_before"] = c.window.isOnActiveSpace
                    favicon = id.flatMap { c.store.tab($0)?.faviconURL }
                    row["favicon_before"] = favicon ?? "<missing>"
                    #if canImport(AircCore)
                    if let id, let page = c.engineTab(for: id) as? ChromiumTab {
                        c.unloadPage(id)
                        check(c.engineTab(for: id) === page && !c.isPageUnloaded(id),
                              "\(label): refused visible-tab discard keeps the page mapping")
                    }
                    #endif
                    if let other { c.show(other, focus: false) }
                }
                step { [self] done in
                    waitUntil({ other.flatMap { self.c.engineTab(for: $0) }?.title == "other"
                        && other.flatMap { self.c.engineTab(for: $0) }?.isLoading == false }, timeout: 10) { done() }
                }
                run { [self] in
                    guard let id, let page = c.engineTab(for: id) else { return }
                    switch cause {
                    case "timeout":
                        WindowController.unloadOverride = 2; c.applyUnloadSetting()
                    case "pressure":
                        #if canImport(AircCore)
                        if page is ChromiumTab {
                            row["pressure_accepted"] = AircEngine.simulateMemoryPressure(forTesting: 2)
                        } else { c.unloadDueTabs(pressure: true) }
                        #else
                        c.unloadDueTabs(pressure: true)
                        #endif
                    default:
                        c.unloadPage(id)
                    }
                }
                step { [self] done in
                    waitUntil({ id.map { self.c.isPageUnloaded($0) } == true }, timeout: 8) {
                        didUnload = id.map { self.c.isPageUnloaded($0) } == true
                        row["unloaded"] = didUnload
                        self.check(didUnload, "\(label): page unloaded")
                        row["title_retained"] = id.flatMap { self.c.store.tab($0)?.title } == "scroll fixture"
                        row["favicon_retained"] = favicon != nil && id.flatMap { self.c.store.tab($0)?.faviconURL } == favicon
                        WindowController.unloadOverride = 86400; self.c.applyUnloadSetting()
                        if let id { self.c.show(id, focus: false) }
                        done()
                    }
                }
                // Sample relative to showing, rather than interpreting isLoading=false
                // as proof that the restored navigation has already started/finished.
                for (delay, name) in [(0.5, "after_0_5s"), (1.5, "after_2s"), (4.0, "after_6s")] {
                    wait(delay)
                    step { [self] done in
                        guard let page = id.flatMap({ c.engineTab(for: $0) }) else {
                            row[name] = ["error": "no page"]; return done()
                        }
                        scrollRestoreSample(page) { sample in row[name] = sample; done() }
                    }
                }
                if hidden {
                    run { [self] in
                        row["window_visible_during_hidden_sample"] = c.window.isVisible
                        c.window.orderFront(nil)
                        if let view = c.window.contentView { frames.start(on: view) }
                    }
                    wait(6)
                    step { [self] done in
                        guard let page = id.flatMap({ c.engineTab(for: $0) }) else { return done() }
                        scrollRestoreSample(page) { sample in row["after_reveal"] = sample; done() }
                    }
                }
                run { [self] in
                    let last = row["after_6s"] as? [String: Any] ?? [:]
                    let y = last["y"] as? Double
                    let restored = didUnload && last["ready"] as? String == "complete"
                        && last["path"] as? String == "/page" && last["instance"] as? String != nil
                        && initial["instance"] as? String != nil && last["instance"] as? String != initial["instance"] as? String
                        && y.map { abs($0 - (initial["y"] as? Double ?? .infinity)) <= 2 } == true
                    row["restored"] = restored
                    if hidden {
                        let revealed = row["after_reveal"] as? [String: Any] ?? [:]
                        let revealOK = revealed["instance"] as? String == last["instance"] as? String
                            && (revealed["y"] as? Double).map { abs($0 - 700) <= 2 } == true
                        row["restored_after_reveal"] = revealOK
                        check(revealOK, "\(label): scroll remains within 2 px after ordering front")
                    }
                    row["display_ticking_after"] = frames.isTicking
                    frames.stop()
                    row["window_visible_after"] = c.window.isVisible
                    row["window_occlusion_visible_after"] = c.window.occlusionState.contains(.visible)
                    row["foreground_unchanged_after"] = foregroundPID == NSWorkspace.shared.frontmostApplication?.processIdentifier
                    row["title_restored"] = id.flatMap { c.engineTab(for: $0)?.title } == "scroll fixture"
                    row["favicon_restored"] = favicon != nil && id.flatMap { c.store.tab($0)?.faviconURL } == favicon
                    check(restored, "\(label): fresh document restores 700 ±2 px (\(y.map(String.init(describing:)) ?? "missing"))")
                    check(row["title_retained"] as? Bool == true && row["favicon_retained"] as? Bool == true,
                          "\(label): unloaded row retains title and favicon")
                    check(row["title_restored"] as? Bool == true && row["favicon_restored"] as? Bool == true,
                          "\(label): title and favicon restore")
                    rows.append(row)
                    // Write after every case, retaining evidence even on a later timeout.
                    let report: [String: Any] = ["engine": app?.engine.name ?? "?", "cases": rows]
                    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                        try? data.write(to: dir.appendingPathComponent("scrollrestore.json"))
                    }
                    for tab in [id, other].compactMap({ $0 }) { c.discardScratchTab(tab) }
                }
            }
        }
        // Script-restored unsaved values exercise the existing timeout safeguard
        // without posting input or requiring focus on the owner's desktop.
        var dirtyID: String?, shownID: String?
        run { [self] in
            WindowController.unloadOverride = 86400; c.applyUnloadSetting()
            dirtyID = (try? c.store.openTab(url: "http://127.0.0.1:\(port)/page", inSpace: c.currentSpaceID, activate: false))?.id
            shownID = (try? c.store.openTab(url: "http://127.0.0.1:\(port)/other", inSpace: c.currentSpaceID, activate: false))?.id
            c.reloadAll(animated: false)
            if let dirtyID { c.show(dirtyID, focus: false) }
        }
        step { [self] done in
            waitUntil({ dirtyID.flatMap { self.c.engineTab(for: $0) }?.title == "scroll fixture"
                && dirtyID.flatMap { self.c.engineTab(for: $0) }?.isLoading == false }, timeout: 10) { done() }
        }
        step { [self] done in
            guard let page = dirtyID.flatMap({ c.engineTab(for: $0) }) else {
                check(false, "scroll: dirty fixture exists"); return done()
            }
            page.evaluate("document.getElementById('draft').value='unsaved'; true") { result in
                self.check(result as? Bool == true, "scroll: dirty fixture has an unsaved value")
                if let shownID { self.c.show(shownID, focus: false) }
                WindowController.unloadOverride = 2; self.c.applyUnloadSetting()
                done()
            }
        }
        wait(5)
        step { [self] done in
            guard let dirtyID, let page = c.engineTab(for: dirtyID), !c.isPageUnloaded(dirtyID) else {
                check(false, "scroll: timeout protects dirty form"); return done()
            }
            page.evaluate("document.getElementById('draft').value") { value in
                self.check(value as? String == "unsaved", "scroll: timeout protects dirty form")
                page.evaluate("document.getElementById('draft').value=''; true") { _ in
                    // Explicitly reschedule the same policy after the form becomes clean.
                    self.c.applyUnloadSetting(); done()
                }
            }
        }
        step { [self] done in
            waitUntil({ dirtyID.map { self.c.isPageUnloaded($0) } == true }, timeout: 8) {
                self.check(dirtyID.map { self.c.isPageUnloaded($0) } == true,
                           "scroll: clean form can unload again")
                done()
            }
        }
        run { [self] in
            for tab in [dirtyID, shownID].compactMap({ $0 }) { c.discardScratchTab(tab) }
            WindowController.unloadOverride = nil; c.applyUnloadSetting()
            server?.stop()
        }
    }
}
#endif
