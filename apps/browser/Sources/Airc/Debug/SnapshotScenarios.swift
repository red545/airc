// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit
import QuartzCore
import os

/// Main-thread cost of one action, the way the §2.12 budgets mean it.
struct FrameTime: CustomStringConvertible {
    /// The action itself.
    var work: Double
    /// From the action's start until Core Animation has committed the frame that shows it.
    var frame: Double
    /// Main-thread work the action left for later (deferred reloads, animation ticks) in the next 100 ms.
    var followUp: Double

    var description: String {
        String(format: "%.2f ms to first frame (action %.2f ms), then %.2f ms more main-thread work over 100 ms", frame, work, followUp)
    }
}

enum FrameTiming {
    /// Runs `work` inside the current run-loop pass and reports when that pass's Core Animation commit finished
    /// (a `beforeWaiting` observer ordered after CA's), then sums the main thread's busy spans over the next 100 ms.
    /// Points of Interest around each measured frame (action start → commit end), for Instruments traces.
    static let signposts = OSLog(subsystem: "app.airc.frames", category: .pointsOfInterest)

    static func measure(_ work: () -> Void, completion: @escaping (FrameTime) -> Void) {
        let t0 = CACurrentMediaTime()
        let id = OSSignpostID(log: signposts)
        os_signpost(.begin, log: signposts, name: "frame", signpostID: id)
        work()
        let t1 = CACurrentMediaTime()
        var first: Double?
        var busyStart: Double?
        var busy = 0.0
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, CFIndex.max) { o, activity in
            let t = CACurrentMediaTime()
            if activity == .afterWaiting {
                busyStart = t
                return
            }
            if first == nil {
                first = t
                os_signpost(.end, log: signposts, name: "frame", signpostID: id)
            } else if let s = busyStart {
                busy += t - s
                busyStart = nil
            }
            if t - t0 > 0.1 {
                CFRunLoopRemoveObserver(CFRunLoopGetMain(), o, .commonModes)
                completion(FrameTime(work: (t1 - t0) * 1000, frame: ((first ?? t) - t0) * 1000, followUp: busy * 1000))
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        // Make sure the loop wakes up again within the window even when nothing else is scheduled.
        for i in 1...6 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.02 * Double(i)) {} }
    }

    static func summary(_ times: [FrameTime]) -> String {
        let frames = times.map(\.frame).sorted()
        let follow = times.map(\.followUp).sorted()
        func med(_ a: [Double]) -> Double { a.isEmpty ? 0 : a[a.count / 2] }
        return String(format: "first frame median %.2f ms, max %.2f ms; follow-up median %.2f ms (n=%d)",
                      med(frames), frames.last ?? 0, med(follow), times.count)
    }
}

extension SnapshotRunner {
    /// The Mac's 1-minute load average, logged with timings (another build may be using the CPU).
    static func loadAverage() -> String {
        var l = [Double](repeating: 0, count: 3)
        return getloadavg(&l, 3) == 3 ? String(format: "%.1f %.1f %.1f on %d cores", l[0], l[1], l[2], ProcessInfo.processInfo.activeProcessorCount) : "?"
    }

    // MARK: Space switch timing

    func measureSpaceSwitches() {
        var times: [FrameTime] = []
        // Neighbours and longer jumps, by click/key (animated, as ⌃1–9 and footer clicks are).
        run { Perf.reset(); Perf.enabled = true }
        for name in ["work", "studio", "work", "personal", "money", "personal", "studio", "personal"] {
            step { [self] done in
                FrameTiming.measure({ self.c.switchToSpace(self.spaces[name]!, animated: true) }) { t in
                    times.append(t)
                    done()
                }
            }
            wait(0.45)
        }
        run { [self] in
            Perf.enabled = false
            note("space switch: " + FrameTiming.summary(times))
            note("space switch, each (action / first frame / follow-up, ms): "
                 + times.map { String(format: "%.2f/%.2f/%.1f", $0.work, $0.frame, $0.followUp) }.joined(separator: ", "))
            note("space switch sections (avg ms): " + Perf.report())
            note("load: " + Self.loadAverage())
        }
    }

    // MARK: Command Bar

    func commandBarScenario() {
        run { [self] in
            // History of this profile, as if browsed for a while (the pages loaded above are in it too).
            guard let h = c.app?.history else { return }
            let pid = c.store.profile(ofSpace: c.currentSpaceID).id
            for (url, title, n) in [("https://en.wikipedia.org/wiki/Lisbon", "Lisbon - Wikipedia", 3),
                                    ("https://www.wikipedia.org/", "Wikipedia", 6),
                                    ("https://en.wikipedia.org/wiki/Wikitext", "Wikitext - Wikipedia", 1),
                                    ("https://github.com/apple/swift", "apple/swift", 4)] {
                for _ in 0..<n { h.recordVisit(profileID: pid, url: url, title: title, typed: n > 3) }
            }
            note("history entries in this profile: \(h.entries(ofProfile: pid).count)")
            c.openCommandBar(mode: .newTab)
            c.commandBar?.type("wiki")
        }
        wait(0.7)
        capture("06-command-bar")
        run { [self] in
            note("command bar \"wiki\": inline \"\(c.commandBar?.inlineText ?? "-")\"; rows: "
                 + (c.commandBar?.resultTitles.joined(separator: " | ") ?? ""))
            c.commandBar?.type("/pin")
        }
        wait(0.4)
        capture("06b-command-bar-actions")
        run { [self] in
            note("command bar \"/pin\": rows: " + (c.commandBar?.resultTitles.joined(separator: " | ") ?? ""))
            c.closeCommandBar()
            c.openCommandBar(mode: .editURL)
        }
        wait(0.4)
        capture("06c-command-bar-url")
        run { [self] in
            note("⌘L opens over the URL field: frame \(c.commandBar.map { NSStringFromRect($0.panelRect) } ?? "-")")
            c.closeCommandBar()
        }
        // One live request, to check the real suggestion path (the screenshot uses canned suggestions).
        step { [self] done in
            var finished = false
            let once = { if !finished { finished = true; done() } }
            SuggestionService.live.fetch("lisbon", engine: .google, profileID: "check") { list in
                self.note("live Google suggestions for \"lisbon\": \(list.count) (\(list.prefix(3).joined(separator: ", ")))")
                once()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if !finished { self.note("live Google suggestions: no answer in 5 s") }
                once()
            }
        }
    }

    // MARK: Library and folder preview

    func libraryAndFolderPreview() {
        run { [self] in
            // Close two Today tabs so the Archive has something in it.
            for t in c.store.todayTabs(ofSpace: c.currentSpaceID).filter({ $0.id != c.shownTabID }).prefix(2) { c.closeTab(t.id) }
            c.toggleLibrary()
        }
        wait(0.7)
        capture("11-library")
        run { [self] in
            note("library: \(c.store.archivedEntries.count) archived; card x = \(Int(c.card.frame.minX))")
            c.toggleLibrary()
        }
        wait(0.6)
        run { [self] in
            guard let trips = c.store.pinnedRoots(ofSpace: c.currentSpaceID).first(where: { $0.kind == .folder }) else { return note("no folder") }
            if !trips.isCollapsed { try? c.store.toggleFolder(trips.id) }
        }
        wait(0.4)
        step { [self] done in
            guard let page = c.pageView(for: c.currentSpaceID),
                  let row = page.list.subviews.compactMap({ $0 as? FolderRowView }).first, let item = row.item else { note("no folder row"); return done() }
            c.folderPreview.hoverBegan(folder: item, row: row)
            DispatchQueue.main.asyncAfter(deadline: .now() + FolderPreviewController.delay + 0.8, execute: done)
        }
        capture("11b-folder-preview")
        run { [self] in
            note("folder preview: \(c.folderPreview.panel != nil ? "shown" : "not shown")")
            c.folderPreview.hide()
        }
    }

    // MARK: Settings

    func settingsScenario() {
        for page in SettingsPage.allCases {
            run { [self] in c.app?.showSettings(page: page) }
            wait(page == .general ? 0.8 : 0.35)
            step { [self] done in
                guard let w = c.app?.settingsWindow?.window else { return done() }
                captureWindow(w, name: "20-settings-\(page.rawValue)", rounded: 0, done)
            }
        }
        run { [self] in c.app?.settingsWindow?.window.orderOut(nil) }
        // Settings → Import → "Import…" re-runs onboarding at the import step (ON-3); Esc leaves it.
        run { [self] in c.app?.startOnboarding(mode: .rerun, atImport: true) }
        wait(2.6)
        step { [self] done in
            guard let w = c.app?.onboarding?.window else { note("re-import: no onboarding window"); return done() }
            captureWindow(w, name: "21-reimport", rounded: AircMetrics.Onboarding.windowRadius, done)
        }
        run { [self] in
            if let w = c.app?.onboarding?.window { MainActor.assumeIsolated { w.cancelOperation(nil) } }
            note("re-import closed with Esc: \(c.app?.onboarding == nil)")
        }
        wait(0.3)
    }

    // MARK: Onboarding (ON-1…5), on the synthetic import fixture

    func onboardingScenario() {
        guard let o = onboarding else { return }
        let m = o.model
        wait(0.8)
        captureOnboarding("ob-01-welcome")
        run { m.onNext?() }
        wait(3.2)   // discovery, the live rebuild, favicons
        captureOnboarding("ob-02-arc")
        run { [self] in
            note("arc step: \(m.counts.spaces) Spaces, \(m.counts.profiles) profiles, \(m.counts.tabs) pinned tabs, \(m.counts.favorites) Favorites; changes: \(m.importChanges.map(\.summary).joined(separator: "; "))")
            m.choosing = true
            m.chosenSpaces.remove("arc-space:demo-launch")
        }
        wait(0.6)
        captureOnboarding("ob-02b-choose")
        run {
            m.choosing = false
            m.onImportEverything?()
        }
        wait(0.25)
        captureOnboarding("ob-03-accounts-importing")
        run { [self] in
            if let r = m.result {
                note("import applied: \(r.spacesCreated) Spaces created, \(r.profilesCreated.count) profiles created, \(r.pinnedTabs) pinned, \(r.folders) folders, \(r.favorites) Favorites, \(r.todayTabs) Today")
            }
            let store = app?.store
            note("store after import: spaces=\(store?.orderedSpaces.map(\.name) ?? []) profiles=\(store?.orderedProfiles.map(\.name) ?? [])")
            m.hoveredProfile = "arc-profile:Profile 1"
            if let i = m.previewSpaces.firstIndex(where: { $0.profileSourceID == "arc-profile:Profile 1" }) { m.focusedSpace = i }
        }
        wait(1.6)
        captureOnboarding("ob-03-accounts")
        run { m.hoveredProfile = nil; m.onNext?() }
        wait(0.7)
        captureOnboarding("ob-03b-logins")
        run { [self] in
            m.onImportLogins?()   // automated: refuses, never touches the Keychain
            note("logins in an automated run: \(m.logins)")
            m.onSkipLogins?()
        }
        wait(0.7)
        run {
            m.focusedSpace = 2
            m.themes[m.previewSpaces[2].sourceID] = DesignTheme.preset("ember")!.model
            m.onThemeChange?()
        }
        wait(0.6)
        captureOnboarding("ob-04-theme")
        run { [self] in
            m.themes[m.previewSpaces[2].sourceID] = nil
            m.onThemeChange?()
            m.onNext?()
            note("step after Looks right: \(m.step)")
        }
        wait(0.8)
        captureOnboarding("ob-05-done")
        run { [self] in
            MainActor.assumeIsolated { o.window.cancelOperation(nil) }   // Esc goes back a step (ON-5)
            note("Esc on the card → \(m.step)")
            m.onNext?()
        }
        wait(0.6)
        step { [self] done in
            o.onFinished = { c in
                self.note("expanded into the browser window: \(NSStringFromRect(c.window.frame)); key: \(c.window.isVisible)")
                done()
            }
            m.onOpen?()
            // One frame of the expansion: the overlay window alone (AircDesign's expansion overlay).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                if let overlay = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("ExpansionOverlay") && $0.isVisible }) {
                    self.captureOwnWindow(overlay, name: "ob-06-expanding")
                } else {
                    self.note("ob-06-expanding: no overlay window on screen")
                }
            }
        }
        wait(0.4)
        waitForPage()
        capture("ob-07-browser")
        run { [self] in
            note("after onboarding: " + "spaces=\(c.store.orderedSpaces.map(\.name)) current=\(c.store.space(c.currentSpaceID)?.name ?? "-") "
                 + "pinned=\(c.store.pinnedRows(ofSpace: c.currentSpaceID).count) favorites=\(c.store.favorites(ofProfile: c.store.profile(ofSpace: c.currentSpaceID).id).count)")
            note("settings: onboarding completed = \(c.app?.settings.values.onboardingCompletedAt != nil)")
        }
    }

    func captureOnboarding(_ name: String) {
        step { [self] done in
            guard let w = onboarding?.window else { return done() }
            captureWindow(w, name: name, rounded: AircMetrics.Onboarding.windowRadius, done)
        }
    }

    /// Renders a window's content (SwiftUI included) to `name`.png. Rounded windows are drawn on a sample desktop
    /// with their shadow, like the mockups; the blur isn't captured (the window isn't key, so it's opaque).
    func captureWindow(_ w: NSWindow, name: String, rounded: CGFloat, _ done: @escaping () -> Void) {
        guard let view = w.contentView else { return done() }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let content = render(view)
        let size = view.bounds.size
        let margin: CGFloat = rounded > 0 ? 70 : 0
        let canvas = NSSize(width: size.width + 2 * margin, height: size.height + 2 * margin)
        let scale: CGFloat = 2
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = canvas
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let r = NSRect(x: margin, y: margin, width: size.width, height: size.height)
        if rounded > 0 {
            NSGradient(colors: [NSColor(red: 0.20, green: 0.17, blue: 0.40, alpha: 1), NSColor(red: 0.55, green: 0.32, blue: 0.55, alpha: 1),
                                NSColor(red: 0.90, green: 0.55, blue: 0.40, alpha: 1)])?.draw(in: NSRect(origin: .zero, size: canvas), angle: -35)
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 30
            shadow.shadowOffset = NSSize(width: 0, height: -14)
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            NSColor.black.setFill()
            NSBezierPath(roundedRect: r, xRadius: rounded, yRadius: rounded).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSBezierPath(roundedRect: r, xRadius: rounded, yRadius: rounded).addClip()
        }
        content?.draw(in: r)
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
        note("wrote \(name).png")
        done()
    }

    /// One of our own windows exactly as the window server shows it (CGWindowListCreateImage with that window's ID
    /// only, so nothing else on screen is ever captured; no Screen Recording permission is needed for our windows).
    /// Empty while the screen is locked; then nothing is written.
    func captureOwnWindow(_ w: NSWindow, name: String) {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return note("\(name): no window capture") }
        let fn = unsafeBitCast(sym, to: Fn.self)
        let includingWindow: UInt32 = 1 << 3, bestResolution: UInt32 = 1 << 3, ignoreFraming: UInt32 = 1 << 0
        guard let img = fn(.null, includingWindow, UInt32(w.windowNumber), bestResolution | ignoreFraming)?.takeRetainedValue(),
              img.width > 8 else { return note("\(name): window not capturable (screen locked?)") }
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
        note("wrote \(name).png (\(img.width)×\(img.height))")
    }
}

/// Section timings on hot paths, collected only while a scenario turns them on (never in normal use).
enum Perf {
    static var enabled = false
    private static var totals: [String: (sum: Double, n: Int)] = [:]
    private static var order: [String] = []

    @inline(__always) static func time<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let t0 = CACurrentMediaTime()
        defer {
            let d = (CACurrentMediaTime() - t0) * 1000
            if totals[name] == nil { order.append(name) }
            totals[name, default: (0, 0)].sum += d
            totals[name, default: (0, 0)].n += 1
        }
        return try body()
    }

    static func reset() { totals = [:]; order = [] }

    /// "name avg ms (n)" per section, in first-seen order.
    static func report() -> String {
        order.map { k in
            let t = totals[k]!
            return String(format: "%@ %.2f", k, t.sum / Double(max(1, t.n)))
        }.joined(separator: ", ")
    }
}
#endif
