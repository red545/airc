// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit
import Network
#if canImport(AircCore)
import AircCore
#endif

/// `--script medialib-downloads | medialib-media | medialib-call` (`medialib` runs all three; each fits the runner's
/// four minutes on its own). Loopback pages only, served by MediaLibServer; downloads go to a scratch folder in the
/// run's data folder (never ~/Downloads), nothing is opened in another app or shown in Finder, and the call is a
/// canvas and a silent oscillator on both engines: no camera, no microphone, so no macOS prompt (fake devices still
/// made Chromium ask macOS on the build Mac). Audio is silent.
///
/// - downloads: progress in the sidebar and a click there opening the Library on Downloads; pause and resume; a
///   download the server cuts off, retried; cancel and remove; a risky file's card (Keep… → Cancel, Discard; Keep →
///   Keep Anyway); the Library's list and search, open, Show in Finder and the file to drag; the "still running"
///   question before a close.
/// - media: a Media Session page's player in the tray (metadata, artwork), next / pause / play from the tray by real
///   clicks, in any Space, a click on the player going to its tab, and four players condensing into three rows.
/// - call: the call's page moving into the call window when it leaves the screen (a tab or Space switch, the window
///   off screen; not Airc merely resigning active, nor a window passing over it) and back (Back to Tab, the sidebar,
///   the window on screen again), mic / camera / leave from the tray and the window, the
///   site's own picture in picture winning, the settings (a site set to never, off), ✕; a heartbeat every 250 ms
///   proves one page load throughout (no reload, no drop).
extension SnapshotRunner {
    func mediaLibScenario() {
        let x = MediaLibContext()
        let parts = script == "medialib" ? ["downloads", "media", "call"] : [String(script.dropFirst("medialib-".count))]
        step { [self] done in
            x.server = MediaLibServer()
            x.server?.start { port in
                x.base = port.map { "http://127.0.0.1:\($0)" } ?? ""
                self.check(!x.base.isEmpty, "medialib: the loopback server starts")
                done()
            }
        }
        run { [self] in
            #if canImport(AircCore)
            if app?.engine is ChromiumEngine {
                check(Pass13.missing.isEmpty, "medialib: the framework has engine pass 13's selectors"
                      + (Pass13.missing.isEmpty ? "" : " (missing: \(Pass13.missing.joined(separator: ", ")))"))
            }
            #endif
            let lib = MediaLibrary.shared
            check(lib.downloads != nil && lib.media != nil, "medialib: downloads \(lib.downloads != nil), media \(lib.media != nil) on \(app?.engine.name ?? "?")")
        }
        if parts.contains("downloads") { mediaLibDownloads(x) }
        if parts.contains("media") { mediaLibMedia(x) }
        if parts.contains("call") { mediaLibCall(x) }
        run { [self] in
            note("medialib: done")
            x.server?.stop()
        }
    }

    // MARK: Helpers

    fileprivate var isChromium: Bool {
        #if canImport(AircCore)
        return app?.engine is ChromiumEngine
        #else
        return false
        #endif
    }

    /// A page's `expression` (JSON-able result).
    fileprivate func pageValue(_ tabID: @escaping () -> String, _ expression: String, _ then: @escaping (Any?) -> Void) {
        guard let page = c.engineTab(for: tabID()) else { return then(nil) }
        page.evaluate(expression, completion: then)
    }

    /// Waits until `tab`'s page has a title that contains `title` (or `timeout`).
    fileprivate func waitForTitle(_ tab: @escaping () -> String, _ title: String, timeout: Double = 10) {
        step { [self] done in
            waitUntil({ self.c.engineTab(for: tab())?.title.contains(title) == true }, timeout: timeout) { done() }
        }
    }

    /// A real click on a tray control (its name read when the step runs: tab IDs come later).
    /// `effect`: what the click does; one that didn't arrive (SwiftUI's tap misses posted clicks while the owner works
    /// on the build Mac) is made once more, and noted with what it hit.
    fileprivate func clickTray(_ anchor: @escaping @autoclosure () -> String, effect: (() -> Bool)? = nil) {
        step { [self] done in
            guard let host = c.sidebar.tray.hostingView else { check(false, "click \(anchor()): no tray"); return done() }
            let name = anchor()
            func attempt(_ n: Int) {
                whenStill(name) {
                    self.clickAnchor(name, in: host) {
                        guard let effect else { return done() }
                        self.waitUntil(effect, timeout: 1.5) {
                            if effect() || n > 0 { return done() }
                            self.note("click \(name) didn't arrive (\(TestAnchors.lastHit[name] ?? "-")); once more")
                            attempt(1)
                        }
                    }
                }
            }
            attempt(0)
        }
    }

    /// A real click on the downloads card's `name`; one that didn't arrive (see clickTray) is made once more.
    fileprivate func clickCard(_ name: String, effect: @escaping () -> Bool, _ done: @escaping () -> Void) {
        func attempt(_ n: Int) {
            guard let v = MediaLibrary.shared.promptView else { return done() }
            whenStill(name) {
                self.clickAnchor(name, in: v.hostingView) {
                    self.waitUntil(effect, timeout: 1.5) {
                        if effect() || n > 0 { return done() }
                        self.note("click \(name) didn't arrive (\(TestAnchors.lastHit[name] ?? "-")); once more")
                        attempt(1)
                    }
                }
            }
        }
        attempt(0)
    }

    /// Once a control has kept its place for 0.25 s (a row still rising out of the footer moves), at most 2 s.
    fileprivate func whenStill(_ name: String, _ then: @escaping () -> Void) {
        let deadline = CACurrentMediaTime() + 2
        var last: CGRect?, since = CACurrentMediaTime()
        func poll() {
            let now = TestAnchors.frames[name], t = CACurrentMediaTime()
            if now != nil, now == last { if t - since >= 0.25 { return then() } } else { since = t }
            last = now
            if t > deadline { return then() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
        }
        poll()
    }

    /// A real click on a Library control: its hosting view keeps the titlebar's safe area, so its root (where the
    /// anchors are measured from) starts below it.
    fileprivate func clickLibrary(_ name: String, _ done: @escaping () -> Void) {
        guard let host = c.library?.subviews.first, let w = host.window, let f = TestAnchors.frames[name] else {
            note("FAIL click \(name): not on screen")
            return done()
        }
        let inset = host.safeAreaInsets
        click(at: host.convert(NSPoint(x: f.midX + inset.left, y: f.midY + inset.top), to: nil), in: w, done)
    }

    /// The window as `capture` draws it, with the downloads card on top (the capture draws the page over anything
    /// reaching into the page card; on screen the card is above it).
    fileprivate func captureWithCard(_ name: String) {
        step { [self] done in
            captureNow(name) { [self] in
                let url = dir.appendingPathComponent(name + ".png")
                guard let card = MediaLibrary.shared.promptView, let image = render(card), let base = NSImage(contentsOf: url) else { return done() }
                let size = c.root.bounds.size
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0)!
                rep.size = size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                base.draw(in: NSRect(origin: .zero, size: size))
                let f = card.frame
                let r = NSRect(x: f.minX, y: size.height - f.maxY, width: f.width, height: f.height)
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
                shadow.shadowBlurRadius = 18
                shadow.shadowOffset = NSSize(width: 0, height: -6)
                NSGraphicsContext.saveGraphicsState()
                shadow.set()
                NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14).addClip()
                image.draw(in: r)
                NSGraphicsContext.restoreGraphicsState()
                NSGraphicsContext.restoreGraphicsState()
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                done()
            }
        }
    }

    /// A real click on one of the call window's buttons (shown first: they hide when the pointer isn't there).
    /// `effect`: what the click does; a click that didn't arrive (a busy build Mac) is made once more, and noted.
    fileprivate func clickCallButton(_ button: @escaping (CallWindowView) -> NSView, _ label: String, effect: @escaping () -> Bool) {
        step { [self] done in
            guard let panel = MediaLibrary.shared.calls.window as? CallPanel, panel.isVisible else {
                check(false, "call: the call window is up for \(label)")
                return done()
            }
            func attempt(_ n: Int) {
                panel.view.flashControls()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    let b = button(panel.view)
                    self.click(at: b.convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), to: nil), in: panel) {
                        self.waitUntil(effect, timeout: 1.5) {
                            if effect() || n > 0 { return done() }
                            let p = b.convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), to: nil)
                            let frame = panel.contentView?.superview
                            let hit = frame.flatMap { $0.hitTest($0.convert(p, from: nil)) }
                            self.note("call: the click on \(label) didn't arrive (window key \(panel.isKeyWindow), controls \(panel.view.controlsVisible), "
                                      + "hits \(hit.map { String(describing: type(of: $0)) } ?? "nothing"), button \(b.frame)); once more")
                            attempt(1)
                        }
                    }
                }
            }
            attempt(0)
        }
    }

    /// Posted mouse events: a press in the middle of the call window, a drag by a share of the screen, a release.
    fileprivate func dragCallWindow(fx: CGFloat, fy: CGFloat, command: Bool) {
        step { [self] done in
            guard let w = MediaLibrary.shared.calls.window, w.isVisible, let v = w.screen?.visibleFrame else {
                check(false, "call: the call window is up for the drag")
                return done()
            }
            let dx = (fx * v.width).rounded(), dy = (fy * v.height).rounded()
            let start = NSPoint(x: w.frame.midX.rounded(), y: w.frame.midY.rounded())
            let flags: NSEvent.ModifierFlags = command ? .command : []
            func post(_ type: NSEvent.EventType, _ screen: NSPoint) {
                let p = NSPoint(x: screen.x - w.frame.minX, y: screen.y - w.frame.minY)
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                              pressure: type == .leftMouseUp ? 0 : 1) { NSApp.postEvent(e, atStart: false) }
            }
            post(.leftMouseDown, start)
            // Each step once the last one has moved the window: a posted event's location is taken against the frame
            // when it's handled (as the window server's are), so it mustn't be computed against a stale one.
            let origin = w.frame.origin
            var k = 0, waited = 0
            let n = 12
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { t in
                let f0 = CGFloat(k) / CGFloat(n)
                let expected = NSPoint(x: origin.x + dx * f0, y: origin.y + dy * f0)
                if k > 0, hypot(w.frame.minX - expected.x, w.frame.minY - expected.y) > 0.5, waited < 120 { waited += 1; return }
                waited = 0
                k += 1
                let f = CGFloat(min(k, n)) / CGFloat(n)
                let p = NSPoint(x: start.x + dx * f, y: start.y + dy * f)
                if k <= n { post(.leftMouseDragged, p) } else {
                    t.invalidate()
                    post(.leftMouseUp, p)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: done)
                }
            }
            RunLoop.main.add(t, forMode: .common)
        }
    }

    // MARK: Downloads

    private func mediaLibDownloads(_ x: MediaLibContext) {
        var helper = ""
        var opened: [String] = [], revealed: [URL] = []
        let scratch = AppPaths.dataDirectory.appendingPathComponent("medialib-downloads", isDirectory: true)
        func center() -> DownloadCenter? { MediaLibrary.shared.downloads }
        func row(_ path: String, _ ok: (DownloadCenter.Item) -> Bool = { _ in true }) -> DownloadCenter.Item? {
            center()?.items.first { URL(string: $0.download.url)?.path == path && ok($0) }
        }
        func load(_ path: String) { run { [self] in c.engineTab(for: helper)?.load(URL(string: x.base + path)!) } }
        func waitFor(_ what: String, timeout: Double = 8, _ cond: @escaping () -> Bool) {
            step { [self] done in waitUntil({ x.aborted || cond() }, timeout: timeout) { done() } }
            run { [self] in if !x.aborted, !cond() { note("downloads: still waiting for \(what)") } }
        }
        step { [self] done in
            try? FileManager.default.removeItem(at: scratch)
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            DownloadCenter.finishedLinger = 1.5
            DownloadCenter.interceptOpen = { opened.append($0.download.fileName); return true }
            DownloadCenter.reveal = { revealed += $0 }
            WebKitLibrary.directoryOverride = scratch
            WebKitLibrary.opener = { opened.append($0.lastPathComponent) }
            do {
                // Chromium: a profile of its own, whose folder gets the scratch download folder before it loads.
                let first = c.store.selectedSpace
                var profileID = first.profileID
                if isChromium {
                    let p = try c.store.createProfile(name: "Downloads test")
                    let folder = Self.chromiumUserData.appendingPathComponent(p.engineDirectory, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let prefs = ["download": ["default_directory": scratch.path, "prompt_for_download": false, "directory_upgrade": true],
                                 "savefile": ["default_directory": scratch.path]]
                    try JSONSerialization.data(withJSONObject: prefs).write(to: folder.appendingPathComponent("Preferences"))
                    profileID = p.id
                }
                let space = try c.store.createSpace(name: "Downloads", icon: nil, theme: first.theme, profileID: profileID, after: first.id)
                helper = try c.store.openTab(url: x.base + "/dl", inSpace: space.id).id
                c.profiles.whenLoaded(profileID, { [self] _ in
                    c.reloadAll(animated: false)
                    c.switchToSpace(space.id, animated: false)
                    c.show(helper, focus: false)
                    done()
                }, failed: { self.check(false, "downloads: the test profile loads"); x.aborted = true; done() })
            } catch {
                check(false, "downloads: setup (\(error))")
                x.aborted = true
                done()
            }
        }
        waitForTitle({ helper }, "Downloads fixture")

        // 1. Progress in the sidebar, into the scratch folder only.
        load("/slow")
        waitFor("the slow download to start") { row("/slow").map { $0.download.received > 0 && $0.download.path != nil } ?? false }
        run { [self] in
            guard let r = row("/slow"), let path = r.download.path else { x.aborted = true; return check(false, "downloads: /slow arrives in the list") }
            if !path.hasPrefix(scratch.path) {
                // Never into the owner's folders: stop it and everything after.
                center()?.perform(.cancel, r)
                x.aborted = true
                return check(false, "downloads: the download goes to the run's scratch folder (it went to \(path); cancelled)")
            }
            check(true, "downloads: /slow downloads into the run's scratch folder")
            x.mark = r.download.received
        }
        wait(0.5)
        run { [self] in
            guard !x.aborted, let r = row("/slow") else { return }
            let plan = c.sidebar.tray.model.plan
            check(r.download.received > x.mark && r.download.state == .inProgress && plan.downloads.contains { $0.id == r.id }
                  && c.sidebar.tray.height > 30,
                  "downloads: progress shows in the sidebar (\(x.mark) → \(r.download.received) of \(r.download.total ?? -1) bytes, "
                  + "tray \(Int(c.sidebar.tray.height)) pt, \"\(DownloadCenter.status(r, host: false))\")")
        }
        capture("medialib-download-progress")
        // A click on the row: the Library, on Downloads.
        step { [self] done in
            guard !x.aborted, let r = row("/slow") else { return done() }
            x.key = "tray.download.\(r.download.id)"
            done()
        }
        clickTray(x.key, effect: { self.c.library != nil })
        run { [self] in
            guard !x.aborted else { return }
            check(c.library?.model.section == .downloads, "downloads: a click on the sidebar's row opens the Library on Downloads "
                  + "(open \(c.library != nil), section \(c.library?.model.section.rawValue ?? "-"))")
        }
        wait(0.5)
        capture("medialib-library-downloading")
        run { [self] in if c.library != nil { c.toggleLibrary() } }
        wait(0.4)

        // 2. Pause, then resume to the end.
        run { [self] in if let r = row("/slow") { check(center()?.perform(.pause, r) == true, "downloads: pause is accepted") } }
        waitFor("the pause") { row("/slow")?.download.paused == true }
        run { x.mark = row("/slow")?.download.received ?? 0 }
        wait(0.8)
        run { [self] in
            guard !x.aborted, let r = row("/slow") else { return }
            check(r.download.paused && r.download.received - x.mark < 70_000 && DownloadCenter.status(r).hasPrefix("Paused"),
                  "downloads: paused, it stops (\(x.mark) → \(r.download.received) bytes, \"\(DownloadCenter.status(r))\")")
            check(center()?.perform(.resume, r) == true, "downloads: resume is accepted")
        }
        waitFor("the slow download to finish", timeout: 12) { row("/slow")?.download.state == .complete }
        run { [self] in
            guard !x.aborted, let r = row("/slow") else { return }
            let size = r.download.path.flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? NSNumber }?.intValue
            check(r.download.state == .complete && size == MediaLibServer.slowSize,
                  "downloads: resumed, it finishes whole (\(size ?? -1) of \(MediaLibServer.slowSize) bytes at \(r.download.fileName))")
        }
        run { [self] in check(c.sidebar.tray.model.plan.downloads.contains { $0.download.state == .complete }, "downloads: the finished file stays in the sidebar a moment") }
        wait(2.2)
        run { [self] in
            check(c.sidebar.tray.model.plan.downloads.isEmpty && c.sidebar.tray.height == 0,
                  "downloads: then the sidebar's row goes (tray \(c.sidebar.tray.height) pt)")
        }

        // 3. Cut off by the server, retried.
        load("/interrupt")
        waitFor("the cut-off download to fail", timeout: 15) { row("/interrupt")?.download.state == .interrupted }
        run { [self] in
            guard !x.aborted, let r = row("/interrupt") else { return check(false, "downloads: the cut-off download arrives") }
            check(r.download.state == .interrupted, "downloads: a download the server cuts off fails (\"\(DownloadCenter.status(r))\")")
            x.server?.stopCutting()
            check(center()?.perform(.retry, r) == true, "downloads: retry is accepted")
        }
        waitFor("the retry", timeout: 10) { row("/interrupt")?.download.state == .complete }
        wait(0.4)
        run { [self] in
            guard !x.aborted else { return }
            let rows = center()?.items.filter { URL(string: $0.download.url)?.path == "/interrupt" } ?? []
            check(rows.count == 1 && rows.first?.download.state == .complete,
                  "downloads: retried, it finishes, one row for it (\(rows.map { "\($0.download.state)" }.joined(separator: ", ")))")
        }

        // 4. Cancel, then off the list.
        load("/slow?2")
        waitFor("the second slow download") { row("/slow", { $0.download.state == .inProgress && $0.download.received > 0 }) != nil }
        run { [self] in
            guard let r = row("/slow", { $0.download.state == .inProgress }) else { return }
            x.key = r.id
            check(center()?.perform(.cancel, r) == true, "downloads: cancel is accepted")
        }
        waitFor("the cancel") { center()?.item(x.key)?.download.state == .cancelled }
        run { [self] in
            guard !x.aborted, let r = center()?.item(x.key) else { return }
            check(r.download.state == .cancelled && center()?.file(r) == nil, "downloads: cancelled, no file (\"\(DownloadCenter.status(r))\")")
            check(center()?.perform(.remove, r) == true, "downloads: remove from the list is accepted")
        }
        waitFor("the removal") { center()?.item(x.key) == nil }
        run { [self] in if !x.aborted { check(center()?.item(x.key) == nil, "downloads: removed, it's off the list") } }

        // 5. A risky file: its card. Discard once, Keep (confirmed) once.
        for (n, keep) in [(1, false), (2, true)] {
            // A page the person navigated to first, then the page's own navigation (no user gesture: Chromium warns).
            load("/dl?\(n)")
            wait(0.8)
            run { [self] in c.engineTab(for: helper)?.evaluate("location.href='/danger?\(n)'", completion: nil) }
            waitFor("the risky download") { row("/danger", { $0.download.url.hasSuffix("?\(n)") }) != nil }
            wait(0.6)
            step { [self] done in
                guard !x.aborted, let r = row("/danger", { $0.download.url.hasSuffix("?\(n)") }) else { return done() }
                guard r.download.dangerous else {
                    skip("downloads: this engine didn't mark the .command file risky (Chromium's file policy decides; PASS13)")
                    center()?.perform(r.download.state == .inProgress ? .cancel : .remove, r)
                    x.skipDanger = true
                    return done()
                }
                x.key = r.id
                waitUntil({ MediaLibrary.shared.promptView != nil }, timeout: 2) {
                    let card = MediaLibrary.shared.promptView
                    self.check(card != nil && MediaLibrary.shared.dangerPrompt?.id == r.id,
                               "downloads: a risky file asks Keep or Discard (card \(card != nil), file \(r.download.fileName))")
                    done()
                }
            }
            if n == 1 { captureWithCard("medialib-download-danger") }
            step { [self] done in
                guard !x.aborted, !x.skipDanger, MediaLibrary.shared.promptView != nil else { return done() }
                clickCard("download.keep", effect: { MediaLibrary.shared.promptView?.model.confirmingKeep == true }, done)
            }
            step { [self] done in
                guard !x.aborted, !x.skipDanger, let v = MediaLibrary.shared.promptView else { return done() }
                check(v.model.confirmingKeep, "downloads: Keep… asks to confirm (a real click)")
                let click = {
                    self.clickCard(keep ? "download.keepAnyway" : "download.keepCancel", effect: {
                        keep ? MediaLibrary.shared.promptView == nil : MediaLibrary.shared.promptView?.model.confirmingKeep == false
                    }, done)
                }
                guard n == 2 else { return click() }
                self.captureNow("medialib-download-keep-confirm") { click() }
            }
            if !keep {
                step { [self] done in
                    guard !x.aborted, !x.skipDanger, let v = MediaLibrary.shared.promptView else { return done() }
                    check(!v.model.confirmingKeep, "downloads: Cancel goes back to Keep / Discard")
                    clickCard("download.discard", effect: { MediaLibrary.shared.promptView == nil }, done)
                }
            }
            waitFor("the answer", timeout: 6) {
                x.skipDanger || (keep ? center()?.item(x.key)?.download.state == .complete : center()?.item(x.key) == nil)
            }
            run { [self] in
                guard !x.aborted, !x.skipDanger else { return }
                let r = center()?.item(x.key)
                if keep {
                    check(r?.download.state == .complete && r?.download.dangerous == false && r.flatMap { center()?.file($0) } != nil,
                          "downloads: Keep Anyway keeps the file (\(r.map { "\($0.download.state)" } ?? "gone"))")
                } else {
                    let left = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path))?.filter { $0.contains("inert") } ?? []
                    check(r == nil && left.isEmpty, "downloads: Discard deletes it (row \(r == nil ? "gone" : "still there"), files \(left))")
                }
                check(MediaLibrary.shared.promptView == nil, "downloads: the card closes after the answer")
            }
        }

        // 6. The Library: the list, its search, open, Show in Finder and the file a drag carries.
        run { [self] in c.showLibrary(.downloads) }
        wait(0.8)
        capture("medialib-library-downloads")
        run { [self] in
            guard !x.aborted, let all = center()?.items else { return }
            let names = Set(LibraryDownloadsView.filter(all, "retry").map(\.download.fileName))
            check(names.count == 1 && names.first?.hasPrefix("retry") == true && LibraryDownloadsView.filter(all, "").count == all.count,
                  "downloads: the Library's search finds by name (\"retry\" → \(names.sorted()))")
            c.library?.model.downloadsQuery = "slow"
        }
        wait(0.5)
        capture("medialib-library-search")
        run { [self] in c.library?.model.downloadsQuery = "" }
        wait(0.4)
        step { [self] done in
            guard !x.aborted, let r = row("/slow", { $0.download.state == .complete }), let host = c.library?.subviews.first else { return done() }
            _ = host
            clickLibrary("library.download.\(r.download.id)", done)
        }
        run { [self] in
            guard !x.aborted, let r = row("/slow", { $0.download.state == .complete }) else { return }
            check(opened.contains(r.download.fileName), "downloads: a click on a finished row opens it (recorded: \(opened))")
            center()?.showInFinder(r)
            let file = center()?.file(r)
            check(file != nil && revealed.last == file, "downloads: Show in Finder reveals the file (\(revealed.last?.lastPathComponent ?? "-"))")
            check(file.map { FileManager.default.fileExists(atPath: $0.path) && NSItemProvider(contentsOf: $0) != nil } ?? false,
                  "downloads: a finished row drags out its file (\(file?.lastPathComponent ?? "-"))")
            c.toggleLibrary()
        }
        wait(0.5)

        // 7. Closing with a download running asks first.
        load("/slow?3")
        waitFor("a running download") { row("/slow", { $0.download.state == .inProgress && $0.download.received > 0 }) != nil }
        run { [self] in
            guard !x.aborted else { return }
            x.answer = nil
            if let ask = MediaLibrary.shared.downloads?.engine.downloadsCloseConfirmation, MediaLibrary.shared.downloads?.engine.asksBeforeClosingWithDownloads == true {
                ask(1) { x.answer = $0 }   // what the engine calls before a close or quit would cancel it
            } else {
                check(c.downloadsHoldClose(), "downloads: the window waits before closing with a download running")
            }
        }
        step { [self] done in waitUntil({ MediaLibrary.shared.promptView != nil }, timeout: 2) { done() } }
        captureWithCard("medialib-download-close")
        step { [self] done in
            guard !x.aborted, MediaLibrary.shared.promptView != nil else { check(false, "downloads: the still-running card shows"); return done() }
            clickCard("download.keepDownloading", effect: { MediaLibrary.shared.promptView == nil }, done)
        }
        wait(0.4)
        run { [self] in
            guard !x.aborted else { return }
            let running = row("/slow", { $0.download.state == .inProgress }) != nil
            check(c.window.isVisible && running && MediaLibrary.shared.promptView == nil && (x.answer ?? false) == false,
                  "downloads: Keep Downloading keeps the window and the download (window \(c.window.isVisible), running \(running))")
            if let r = row("/slow", { $0.download.state == .inProgress }) { center()?.perform(.cancel, r) }
        }
        wait(0.5)
        run { [self] in
            DownloadCenter.interceptOpen = nil
            DownloadCenter.reveal = { NSWorkspace.shared.activateFileViewerSelecting($0) }
            WebKitLibrary.opener = { NSWorkspace.shared.open($0) }
            note("downloads: scratch folder holds \((try? FileManager.default.contentsOfDirectory(atPath: scratch.path))?.sorted() ?? [])")
        }
    }

    /// The engine's test gate (engine/core/airc_launch_switches.cc) lets `--airc-test` through: the mock keychain
    /// (every scripted run has it) and `--airc-data-dir` whose existing Chromium folder is the user data folder. Unsigned
    /// test builds only, which this is.
    static var engineTestGateOpens: Bool {
        guard let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--airc-data-dir=") }) else { return false }
        let scratch = URL(fileURLWithPath: String(arg.dropFirst("--airc-data-dir=".count))).appendingPathComponent("Chromium")
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: scratch.path, isDirectory: &dir), dir.boolValue else { return false }
        return scratch.resolvingSymlinksInPath().standardizedFileURL.path == chromiumUserData.resolvingSymlinksInPath().standardizedFileURL.path
    }

    static var chromiumUserData: URL {
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--user-data-dir=") }) {
            return URL(fileURLWithPath: String(arg.dropFirst("--user-data-dir=".count)), isDirectory: true)
        }
        return AppPaths.chromium
    }

    // MARK: Media

    private func mediaLibMedia(_ x: MediaLibContext) {
        var home = "", music = "", other = "", elsewhere = ""
        var extra: [String] = []
        func player() -> MediaCenter.Player? { MediaLibrary.shared.media?.players.first { $0.tabID == music } }
        func session() -> EngineMediaSession? { MediaLibrary.shared.media?.sessions[music]?.session }
        run { [self] in
            do {
                home = c.currentSpaceID
                let first = c.store.selectedSpace
                music = try c.store.openTab(url: x.base + "/music", inSpace: home).id
                other = try c.store.openTab(url: "data:text/html,<title>Reading</title>", inSpace: home).id
                elsewhere = try c.store.createSpace(name: "Elsewhere", icon: nil, theme: first.theme, profileID: first.profileID, after: home).id
                _ = try c.store.openTab(url: "data:text/html,<title>Elsewhere</title>", inSpace: elsewhere)
                c.reloadAll(animated: false)
                c.show(music, focus: false)
            } catch { check(false, "media: setup (\(error))") }
        }
        waitForTitle({ music }, "Music")
        playMusic({ music })
        step { [self] done in waitUntil({ session()?.playback == .playing && session()?.title == "Fixture Song" }, timeout: 8) { done() } }
        run { [self] in
            check(session()?.playback == .playing && session()?.title == "Fixture Song",
                  "media: the page's Media Session reaches the app (\(session().map { "\($0.playback) \($0.title)" } ?? "none"))")
            check(player() == nil, "media: the tab on screen isn't in the tray")
            c.show(other, focus: false)
        }
        step { [self] done in waitUntil({ player() != nil && self.c.sidebar.tray.height > 30 }, timeout: 3) { done() } }
        run { [self] in
            let p = player()
            check(p?.title == "Fixture Song" && p?.subtitle == "Airc Band" && p?.session.artwork.first?.hasSuffix("/art.png") == true,
                  "media: leaving the tab, its player shows in the tray (\(p.map { "\($0.title) / \($0.subtitle) / \($0.session.artwork)" } ?? "none"))")
        }
        wait(0.6)
        capture("medialib-tray-music")
        clickTray("tray.next.\(music)", effect: { player()?.title == "Fixture Song 2" })
        step { [self] done in waitUntil({ player()?.title == "Fixture Song 2" }, timeout: 3) { done() } }
        step { [self] done in
            pageValue({ music }, "state()") { v in
                let s = v as? [String: Any] ?? [:]
                self.check((s["track"] as? NSNumber)?.intValue == 2 && player()?.title == "Fixture Song 2",
                           "media: Next in the tray (a real click) plays the next track (page \(s), tray \(player()?.title ?? "-"))")
                done()
            }
        }
        clickTray("tray.play.\(music)", effect: { session()?.playback == .paused })
        step { [self] done in waitUntil({ session()?.playback == .paused }, timeout: 3) { done() } }
        step { [self] done in
            pageValue({ music }, "state()") { v in
                let paused = ((v as? [String: Any])?["paused"] as? Bool) == true
                self.check(paused && session()?.playback == .paused, "media: Pause in the tray pauses the page (paused \(paused), session \(session()?.playback.rawValue ?? "-"))")
                done()
            }
        }
        clickTray("tray.play.\(music)", effect: { session()?.playback == .playing })
        step { [self] done in waitUntil({ session()?.playback == .playing }, timeout: 3) { done() } }
        run { [self] in check(session()?.playback == .playing, "media: Play in the tray plays it again") }
        // Any Space: the tray is the window's, not the Space's.
        run { [self] in c.switchToSpace(elsewhere, animated: false) }
        wait(0.6)
        run { [self] in check(player() != nil, "media: in another Space the player is still in the tray") }
        clickTray("tray.player.\(music)", effect: { self.c.shownTabID == music })
        step { [self] done in waitUntil({ self.c.shownTabID == music }, timeout: 3) { done() } }
        run { [self] in
            check(c.currentSpaceID == home && c.shownTabID == music && player() == nil,
                  "media: a click on the player goes to its tab, in its Space (shown \(c.shownTabID == music), Space \(c.currentSpaceID == home))")
        }
        // Several sessions condense: three rows, the rest in the last row's menu.
        for n in 2...4 {
            run { [self] in
                if let t = try? c.store.openTab(url: x.base + "/music?n=\(n)", inSpace: home) { extra.append(t.id); c.show(t.id, focus: false) }
            }
            waitForTitle({ extra.last ?? "" }, "Music")
            playMusic({ extra.last ?? "" })
        }
        run { [self] in c.show(other, focus: false) }
        step { [self] done in waitUntil({ (MediaLibrary.shared.media?.players.count ?? 0) >= 4 }, timeout: 6) { done() } }
        wait(0.5)
        run { [self] in
            let plan = c.sidebar.tray.model.plan
            for id in [music] + extra {
                guard let page = c.engineTab(for: id) else { continue }
                let s = MediaLibrary.shared.media?.engine.mediaSession(of: page)
                note("media: \(page.title): engine session \(s.map { "\($0.playback) \($0.title)" } ?? "none"), tray \(MediaLibrary.shared.media?.sessions[id] != nil)")
            }
            check(plan.players.count == 3 && plan.morePlayers.count == 1,
                  "media: four players condense into three rows and a +1 (\(plan.players.count) rows, \(plan.morePlayers.count) more)")
        }
        capture("medialib-tray-condensed")
        run { [self] in
            for id in extra { c.closeTab(id) }
            c.engineTab(for: music)?.evaluate("document.getElementById('a').pause()", completion: nil)
        }
        wait(0.6)
    }

    /// Starts the page's (silent) audio as a click would: Chromium through DevTools' user gesture, WebKit's own
    /// evaluation is one.
    fileprivate func playMusic(_ tab: @escaping () -> String) {
        let js = "document.getElementById('a').play().then(function(){navigator.mediaSession.playbackState='playing';document.title='Music playing'})"
        step { [self] done in
            guard let page = c.engineTab(for: tab()) else { return done() }
            #if canImport(AircCore)
            if let chromium = app?.engine as? ChromiumEngine {
                chromium.devToolsCall("Runtime.evaluate", params: ["expression": js, "userGesture": true, "awaitPromise": true, "returnByValue": true],
                                      in: page) { _, _ in done() }
                return
            }
            #endif
            page.evaluate(js) { _ in done() }
        }
    }

    // MARK: Call

    private func mediaLibCall(_ x: MediaLibContext) {
        var home = "", call = "", other = "", away = "", loadID: String?
        let calls = MediaLibrary.shared.calls
        func session() -> EngineMediaSession? { MediaLibrary.shared.media?.sessions[call]?.session }
        func inCallWindow() -> Bool {
            guard let page = c.engineTab(for: call) else { return false }
            return calls.holds(call) && calls.window?.isVisible == true && page.view.window === calls.window
        }
        func inMain() -> Bool {
            guard let page = c.engineTab(for: call) else { return false }
            return !calls.holds(call) && page.view.window === c.window && calls.window?.isVisible != true
        }
        /// The call is the same page load, live.
        func sample(_ label: String) {
            step { [self] done in
                pageValue({ call }, "state()") { v in
                    let s = v as? [String: Any] ?? [:]
                    let id = s["id"] as? String
                    if loadID == nil { loadID = id }
                    let tracks = s["tracks"] as? [[String: Any]] ?? []
                    let live = tracks.count == 2 && tracks.allSatisfy { $0["state"] as? String == "live" }
                    let peers = s["peers"] as? [String] ?? []
                    let connected = peers == ["connected", "connected"]
                    self.note("call \(label): page heartbeat \(s["beats"] ?? "-"), server \(x.server?.beatSummary().count ?? -1)")
                    if !connected, !self.isChromium, live, id == loadID {
                        self.note("call \(label): WebKit's loopback peers are \(peers) (tracks live, same page)")
                    }
                    self.check(id != nil && id == loadID && live && (connected || !self.isChromium),
                               "call \(label): the same live call (load \(id == loadID ? "same" : "\(id ?? "none") ≠ \(loadID ?? "-")"), tracks live \(live), peers \(peers))")
                    done()
                }
            }
        }
        func expectWindow(_ label: String, _ want: Bool, timeout: Double = 3) {
            step { [self] done in waitUntil({ want ? inCallWindow() : !calls.isShowing }, timeout: timeout) { done() } }
            run { [self] in
                check(want ? inCallWindow() : (!calls.isShowing && !calls.holds(call)),
                      "call \(label): " + (want ? "the page is in the call window" : "no call window")
                      + " (window \(calls.window?.isVisible == true), holds \(calls.holds(call)))")
            }
        }
        run { [self] in
            do {
                home = c.currentSpaceID
                let first = c.store.selectedSpace
                // No devices, fake or not: on the build Mac, Chromium asked macOS for the microphone even with fake devices
                // and the engine's system-permission stand-in (2026-11-06: the owner saw six prompts). The call is a canvas
                // and a silent oscillator on both engines; AIRC_MEDIALIB_DEVICES=1 (a machine nobody uses) asks for devices.
                let devices = isChromium && ProcessInfo.processInfo.environment["AIRC_MEDIALIB_DEVICES"] == "1"
                    && CommandLine.arguments.contains("--use-fake-device-for-media-stream") && Self.engineTestGateOpens
                note("call: \(devices ? "fake devices (Chromium)" : "a canvas and a silent oscillator, no devices")")
                // The owner's own windows cover the test window at random: the window's visibility is simulated, except
                // in the ordered-out check.
                CallWindowController.followsWindowVisibility = false
                call = try c.store.openTab(url: x.base + "/call" + (devices ? "?devices=1" : ""), inSpace: home).id
                other = try c.store.openTab(url: "data:text/html,<title>Notes</title>", inSpace: home).id
                away = try c.store.createSpace(name: "Away", icon: nil, theme: first.theme, profileID: first.profileID, after: home).id
                _ = try c.store.openTab(url: "data:text/html,<title>Away</title>", inSpace: away)
                c.reloadAll(animated: false)
                c.show(call, focus: false)
            } catch { check(false, "call: setup (\(error))") }
        }
        waitForTitle({ call }, "(live)", timeout: 12)
        step { [self] done in waitUntil({ session()?.isCall == true }, timeout: 4) { done() } }
        run { [self] in
            let s = session()
            check(s?.isCall == true && s?.actions.isSuperset(of: ["togglemicrophone", "togglecamera", "hangup"]) == true,
                  "call: the page's call reaches the app (actions \(s?.actions.sorted() ?? []), mic \(s?.microphoneOn ?? false))")
        }
        wait(1)
        sample("start")

        // A tab switch: into the call window.
        run { [self] in c.show(other, focus: false) }
        expectWindow("tab switch", true)
        sample("in the call window")
        run { [self] in
            let p = MediaLibrary.shared.media?.players.first { $0.tabID == call }
            check(p?.isCall == true, "call: its controls are in the tray too (\(p?.subtitle ?? "none"))")
        }
        wait(1.2)
        step { [self] done in
            guard let w = calls.window else { return done() }
            (w as? CallPanel)?.view.flashControls()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.captureOwnWindow(w, name: "medialib-call-window")
                done()
            }
        }
        capture("medialib-tray-call")
        // Dragged anywhere (here from the middle of the page), it springs to the nearest corner; with ⌘ it stays put.
        dragCallWindow(fx: -0.6, fy: 0.6, command: false)
        step { [self] done in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let w = calls.window, let v = w.screen?.visibleFrame else { return done() }
                let f = w.frame, i = CallPanel.cornerInset
                self.check(abs(f.minX - (v.minX + i)) < 1.5 && abs(f.maxY - (v.maxY - i)) < 1.5 && inCallWindow(),
                           "call: a drag moves the call window and it springs to the nearest corner (at \(Int(f.minX)), \(Int(f.maxY)); "
                           + "corner \(Int(v.minX + i)), \(Int(v.maxY - i)))")
                done()
            }
        }
        dragCallWindow(fx: 0.2, fy: -0.2, command: true)
        step { [self] done in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let w = calls.window, let v = w.screen?.visibleFrame else { return done() }
                let f = w.frame, i = CallPanel.cornerInset
                let want = NSPoint(x: v.minX + i + (0.2 * v.width).rounded(), y: v.maxY - i - (0.2 * v.height).rounded())
                self.check(abs(f.minX - want.x) < 1.5 && abs(f.maxY - want.y) < 1.5,
                           "call: with ⌘ the drag places it freely (at \(Int(f.minX)), \(Int(f.maxY)))")
                (w as? CallPanel)?.snapToCorner()   // back to a corner for the rest
                done()
            }
        }
        wait(0.8)
        // The microphone from the tray, the camera from the window (real clicks).
        clickTray("tray.mic.\(call)", effect: { session()?.microphoneOn == false })
        step { [self] done in waitUntil({ session()?.microphoneOn == false }, timeout: 3) { done() } }
        step { [self] done in
            pageValue({ call }, "state()") { v in
                let s = v as? [String: Any] ?? [:]
                let audio = (s["tracks"] as? [[String: Any]])?.first { $0["kind"] as? String == "audio" }
                self.check((s["mic"] as? Bool) == false && (audio?["enabled"] as? Bool) == false && session()?.microphoneOn == false,
                           "call: Mute in the tray mutes the call's microphone (page mic \(s["mic"] ?? "-"), track enabled \(audio?["enabled"] ?? "-"))")
                done()
            }
        }
        clickCallButton({ $0.camera }, "camera", effect: { session()?.cameraOn == false })
        step { [self] done in waitUntil({ session()?.cameraOn == false }, timeout: 3) { done() } }
        step { [self] done in
            pageValue({ call }, "state()") { v in
                let s = v as? [String: Any] ?? [:]
                self.check((s["cam"] as? Bool) == false && session()?.cameraOn == false,
                           "call: the call window's camera button turns the camera off (page \(s["cam"] ?? "-"))")
                done()
            }
        }
        clickCallButton({ $0.mic }, "microphone", effect: { session()?.microphoneOn == true })
        step { [self] done in waitUntil({ session()?.microphoneOn == true }, timeout: 3) { done() } }
        run { [self] in
            check(session()?.microphoneOn == true && (calls.window as? CallPanel)?.view.mic.symbol == "mic.fill",
                  "call: the call window's microphone button unmutes it, and shows it")
        }
        sample("after the controls")
        // Back to Tab.
        clickCallButton({ $0.back }, "Back to Tab", effect: { inMain() })
        step { [self] done in waitUntil({ inMain() && self.c.shownTabID == call }, timeout: 3) { done() } }
        run { [self] in check(inMain() && c.shownTabID == call, "call: Back to Tab puts the page back in its tab (shown \(c.shownTabID == call))") }
        sample("back in its tab")

        // A Space switch, and back through the sidebar.
        run { [self] in c.switchToSpace(away, animated: false) }
        expectWindow("Space switch", true)
        sample("in the call window from another Space")
        run { [self] in c.switchToSpace(home, animated: false) }
        step { [self] done in waitUntil({ inMain() }, timeout: 3) { done() } }
        run { [self] in check(inMain() && c.shownTabID == call, "call: back in its Space, the page is back in the card") }
        sample("back from the Space switch")

        // Airc resigning active with its window still on screen (Notification Center, Spotlight, a menu-bar extra)
        // isn't the call leaving the screen.
        run { NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp) }
        expectWindow("Airc resigns active, its window still on screen", false, timeout: 1.5)
        // Off screen for less than the settle (a window passing over it): nothing.
        run { calls.windowVisibility(false) }
        wait(0.2)
        run { calls.windowVisibility(true) }
        expectWindow("the window off screen only a moment", false, timeout: 1.2)
        // Off screen (minimized, hidden, covered): after the settle the call goes to its window, and comes back with it.
        run { calls.windowVisibility(false) }
        expectWindow("the window off screen", true, timeout: 3)
        run { [self] in
            check(calls.reason == .hidden && c.card.subviews.contains { $0.identifier?.rawValue == "airc.callAway" },
                  "call: the card says the call is in its own window")
        }
        run { calls.windowVisibility(true) }
        step { [self] done in waitUntil({ inMain() }, timeout: 3) { done() } }
        run { [self] in
            check(inMain() && c.shownTabID == call && !c.card.subviews.contains { $0.identifier?.rawValue == "airc.callAway" },
                  "call: the window back on screen, the call is back in the card")
        }
        sample("back from off screen")
        // The real thing: the window ordered out, through its occlusion notification (a scratch window keeps the app
        // from quitting with no window up).
        var keeper: NSWindow?
        run { [self] in
            CallWindowController.followsWindowVisibility = true
            keeper = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 100, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
            keeper?.title = "Call test"
            keeper?.orderFront(nil)
            c.window.orderOut(nil)
        }
        wait(0.3)
        run { [self] in
            note("call: ordered out: visible \(c.window.isVisible), occlusion \(c.window.occlusionState.rawValue), on screen as the call "
                 + "window sees it \(calls.windowOnScreen)")
        }
        expectWindow("the window ordered out", true, timeout: 3)
        run { [self] in
            c.window.orderFront(nil)
            keeper?.orderOut(nil)
            keeper = nil
            CallWindowController.followsWindowVisibility = false
            calls.windowVisibility(true)
        }
        step { [self] done in waitUntil({ inMain() }, timeout: 3) { done() } }
        run { [self] in check(inMain(), "call: ordered in again, the call is back in the card") }
        sample("back from ordered out")

        // The site's own picture in picture wins.
        run { [self] in c.show(other, focus: false) }
        expectWindow("before the site's picture in picture", true)
        run { [self] in
            guard let page = c.engineTab(for: call) else { return }
            #if canImport(AircCore)
            // What the engine reports when the page opens its Document PiP (Chromium's automatic entry needs HTTPS).
            if let chromium = app?.engine as? ChromiumEngine { chromium.pictureInPictureDidChange?(page, ["active": true, "kind": "document"]); return }
            #endif
            calls.pictureInPictureChanged(page, active: true)
        }
        expectWindow("the site opened its own picture in picture", false)
        run { [self] in c.show(call, focus: false) }
        wait(0.5)
        run { [self] in c.show(other, focus: false) }
        expectWindow("while the site's picture in picture is up", false, timeout: 1.5)
        run { [self] in
            guard let page = c.engineTab(for: call) else { return }
            calls.pictureInPictureChanged(page, active: false)
            c.show(call, focus: false)
        }
        wait(0.5)
        sample("after the site's picture in picture")

        // Settings: a site set to never, and off.
        for setting in ["never", "off"] {
            run { [self] in
                guard let s = app?.settings else { return }
                if setting == "never" { s.values.pipSites[WindowController.pictureInPictureOrigin(x.base)!] = false } else { s.values.pipAutomatic = false }
                c.show(other, focus: false)
            }
            expectWindow("picture in picture \(setting == "never" ? "set to never for the site" : "off")", false, timeout: 1.5)
            run { [self] in
                guard let s = app?.settings else { return }
                s.values.pipSites = [:]
                s.values.pipAutomatic = true
                c.show(call, focus: false)
            }
            wait(0.5)
        }

        // ✕: the window goes, the call goes on in its tab, and doesn't come back until the tab has been on screen.
        run { [self] in c.show(other, focus: false) }
        expectWindow("before ✕", true)
        clickCallButton({ $0.close }, "✕", effect: { !calls.isShowing })
        expectWindow("after ✕", false)
        run { [self] in c.switchToSpace(away, animated: false) }
        expectWindow("✕, then another Space", false, timeout: 1.5)
        sample("after ✕")
        run { [self] in c.switchToSpace(home, animated: false); c.show(call, focus: false) }
        wait(0.6)

        // Leave from the call window: the call ends and the window goes.
        run { [self] in c.show(other, focus: false) }
        expectWindow("before Leave", true)
        clickCallButton({ $0.leave }, "Leave", effect: { session()?.isCall != true })
        step { [self] done in waitUntil({ session()?.isCall != true && !calls.isShowing }, timeout: 4) { done() } }
        step { [self] done in
            pageValue({ call }, "state()") { v in
                let s = v as? [String: Any] ?? [:]
                self.check((s["ended"] as? Bool) == true && !calls.isShowing && session()?.isCall != true && s["id"] as? String == loadID,
                           "call: Leave in the call window hangs up, and the window goes (page ended \(s["ended"] ?? "-"), window \(calls.isShowing))")
                done()
            }
        }
        wait(0.6)
        run { [self] in
            // Every 250 ms from the page; a background app's timers can be clamped to once a second (App Nap, WebKit's
            // hidden-page throttling), so continuity is the measure: one load, no gap over 3 s, until now.
            let b = x.server?.beatSummary() ?? (count: 0, ids: [], maxGap: 0, span: 0, sinceLast: .infinity)
            check(b.ids.count == 1 && b.maxGap < 3000 && b.sinceLast < 3 && b.span > 8,
                  String(format: "call: one page load throughout, its heartbeat never stopped (%d beats over %.0f s, %d loads, longest gap %.0f ms, last %.1f s ago)",
                         b.count, b.span, b.ids.count, b.maxGap, b.sinceLast))
        }
    }
}

final class MediaLibContext {
    var server: MediaLibServer?
    var base = ""
    var aborted = false
    var skipDanger = false
    var mark: Int64 = 0
    var key = ""
    var answer: Bool?
}

extension SidebarTrayView {
    var hostingView: NSView? { subviews.first }
}

extension LibraryDownloadsView {
    /// The Library's search, as the list applies it.
    static func filter(_ items: [DownloadCenter.Item], _ query: String) -> [DownloadCenter.Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return items.filter { q.isEmpty || CommandSearch.score(q, in: $0.download.fileName) != nil
            || CommandSearch.score(q, in: URLRules.displayHost($0.download.url)) != nil }
    }
}

// MARK: - The loopback server

/// 127.0.0.1 only, on an ephemeral port: the fixture pages, slow and resumable downloads, one the server cuts off the
/// first time, a risky file, silent audio, artwork, and the call page's heartbeats.
final class MediaLibServer {
    static let slowSize = 1_048_576
    static let interruptSize = 524_288
    private let listener: NWListener
    private let queue = DispatchQueue(label: "airc.test.medialib-server")
    private var beats: [(at: CFTimeInterval, id: String)] = []
    private var cutting = true
    /// /interrupt stops cutting off (before the check's retry).
    func stopCutting() { queue.sync { cutting = false } }
    private let art: Data
    private let silence: Data

    init?() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        params.acceptLocalOnly = true
        guard let l = try? NWListener(using: params) else { return nil }
        listener = l
        art = Self.artwork()
        silence = Self.silentWAV(seconds: 6)
    }

    func start(_ ready: @escaping (UInt16?) -> Void) {
        var answered = false
        listener.stateUpdateHandler = { [listener] state in
            let port: UInt16?
            switch state {
            case .ready: port = listener.port?.rawValue
            case .failed, .cancelled: port = nil
            default: return
            }
            DispatchQueue.main.async {
                guard !answered else { return }
                answered = true
                ready(port)
            }
        }
        listener.newConnectionHandler = { [weak self] c in self?.serve(c) }
        listener.start(queue: queue)
    }

    func stop() { listener.cancel() }

    /// Heartbeats so far: how many, which page loads, the longest gap (ms), the seconds they span, and how long ago the
    /// last one came.
    func beatSummary() -> (count: Int, ids: Set<String>, maxGap: Double, span: Double, sinceLast: Double) {
        queue.sync {
            let gaps = zip(beats, beats.dropFirst()).map { ($1.at - $0.at) * 1000 }
            let first = beats.first?.at ?? 0, last = beats.last?.at ?? 0
            return (beats.count, Set(beats.map(\.id)), gaps.max() ?? 0, last - first, beats.isEmpty ? .infinity : CACurrentMediaTime() - last)
        }
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, Data())
    }

    private func receive(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return c.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                return complete || error != nil || buffer.count > 65536 ? c.cancel() : self.receive(c, buffer)
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let lines = head.split(separator: "\r\n").map(String.init)
            func header(_ name: String) -> String? {
                lines.dropFirst().first { $0.lowercased().hasPrefix(name + ":") }.map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
            }
            let length = Int(header("content-length") ?? "") ?? 0
            if buffer.count - end.upperBound < length, !complete, error == nil { return self.receive(c, buffer) }
            let parts = lines.first?.split(separator: " ") ?? []
            let method = parts.first.map(String.init) ?? "GET"
            let target = parts.dropFirst().first.map(String.init) ?? "/"
            let path = String(target.split(separator: "?").first ?? "/")
            let body = buffer[end.upperBound...].prefix(length)
            self.respond(c, method: method, path: path, range: header("range"), body: Data(body))
        }
    }

    private func respond(_ c: NWConnection, method: String, path: String, range: String?, body: Data) {
        switch (method, path) {
        case ("POST", "/beat"):
            if let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let id = o["id"] as? String {
                beats.append((CACurrentMediaTime(), id))
            }
            send(c, "204 No Content", [:], Data())
        case (_, "/dl"): send(c, "200 OK", ["Content-Type": "text/html; charset=utf-8"], Data(Self.downloadsPage.utf8))
        case (_, "/music"): send(c, "200 OK", ["Content-Type": "text/html; charset=utf-8"], Data(Self.musicPage.utf8))
        case (_, "/call"): send(c, "200 OK", ["Content-Type": "text/html; charset=utf-8"], Data(Self.callPage.utf8))
        case (_, "/art.png"): send(c, "200 OK", ["Content-Type": "image/png"], art)
        case (_, "/silence.wav"): sendRange(c, silence, type: "audio/wav", range: range)
        case (_, "/danger"):
            send(c, "200 OK", ["Content-Type": "application/octet-stream", "Content-Disposition": "attachment; filename=\"inert.command\""],
                 Data(repeating: 0x23, count: 32))
        case (_, "/slow"):
            stream(c, name: "slow.bin", size: Self.slowSize, range: range, chunk: 16_384, every: 0.12)
        case (_, "/interrupt"):
            // Cut off (and not resumable) until the check retries: Chromium restarts a few times by itself first.
            let cut = cutting
            stream(c, name: "retry.bin", size: Self.interruptSize, range: range, chunk: 65_536, every: 0.05,
                   cutAfter: cut ? 131_072 : nil, resumable: !cut)
        default:
            send(c, "404 Not Found", ["Content-Type": "text/plain"], Data("not found".utf8))
        }
    }

    private func send(_ c: NWConnection, _ status: String, _ headers: [String: String], _ body: Data) {
        var h = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n"
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) { h += "\(k): \(v)\r\n" }
        c.send(content: Data((h + "\r\n").utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }

    /// A static file with byte ranges (WebKit's media loading asks for them).
    private func sendRange(_ c: NWConnection, _ data: Data, type: String, range: String?) {
        guard let r = range, r.hasPrefix("bytes=") else { return send(c, "200 OK", ["Content-Type": type, "Accept-Ranges": "bytes"], data) }
        let bounds = r.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
        let from = min(bounds.first.flatMap { $0 } ?? 0, max(0, data.count - 1))
        let to = min(bounds.count > 1 ? (bounds[1] ?? data.count - 1) : data.count - 1, data.count - 1)
        guard from <= to else { return send(c, "416 Range Not Satisfiable", ["Content-Range": "bytes */\(data.count)"], Data()) }
        send(c, "206 Partial Content", ["Content-Type": type, "Accept-Ranges": "bytes", "Content-Range": "bytes \(from)-\(to)/\(data.count)"],
             data.subdata(in: from..<(to + 1)))
    }

    /// `size` bytes of "A", `chunk` at a time, `every` seconds apart; a Range resumes; `cutAfter` drops the connection.
    private func stream(_ c: NWConnection, name: String, size: Int, range: String?, chunk: Int, every: TimeInterval, cutAfter: Int? = nil,
                        resumable: Bool = true) {
        var start = 0
        if resumable, let r = range, r.hasPrefix("bytes="), let n = Int(r.dropFirst(6).split(separator: "-").first ?? "") { start = min(n, size) }
        let partial = start > 0
        var h = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\nContent-Type: application/octet-stream\r\n"
        h += "Content-Disposition: attachment; filename=\"\(name)\"\r\n"
        if resumable { h += "Accept-Ranges: bytes\r\nETag: \"airc-\(name)-1\"\r\nLast-Modified: Thu, 05 Nov 2026 12:00:00 GMT\r\n" }
        h += "Content-Length: \(size - start)\r\nConnection: close\r\n"
        if partial { h += "Content-Range: bytes \(start)-\(size - 1)/\(size)\r\n" }
        c.send(content: Data((h + "\r\n").utf8), completion: .contentProcessed { _ in })
        var sent = start
        func next() {
            if let cut = cutAfter, sent >= cut { return c.cancel() }
            guard sent < size else { return c.send(content: nil, isComplete: true, completion: .contentProcessed { _ in c.cancel() }) }
            let n = min(chunk, size - sent)
            sent += n
            c.send(content: Data(repeating: 0x41, count: n), completion: .contentProcessed { [weak self] error in
                guard error == nil, let self else { return c.cancel() }
                self.queue.asyncAfter(deadline: .now() + every, execute: next)
            })
        }
        queue.asyncAfter(deadline: .now() + every, execute: next)
    }

    private static func artwork() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 96, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(colors: [NSColor(red: 0.95, green: 0.45, blue: 0.35, alpha: 1), NSColor(red: 0.45, green: 0.30, blue: 0.85, alpha: 1)])?
            .draw(in: NSRect(x: 0, y: 0, width: 96, height: 96), angle: -45)
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: NSRect(x: 30, y: 30, width: 36, height: 36)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    /// 16 kHz mono 16-bit zeros: a media session without a sound on the build Mac's speakers.
    private static func silentWAV(seconds: Int) -> Data {
        let samples = 16_000 * seconds
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + samples * 2)); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(samples * 2))
        d.append(Data(count: samples * 2))
        return d
    }

    static let downloadsPage = """
    <!doctype html><meta charset="utf-8"><title>Downloads fixture</title>
    <body style="font:15px system-ui;padding:24px">Downloads fixture: slow, cut off once, and a risky file.</body>
    """

    static let musicPage = """
    <!doctype html><meta charset="utf-8"><title>Music</title>
    <body style="margin:0;background:#1d2b3a;color:#fff;font:16px system-ui;padding:24px"><audio id="a" src="/silence.wav" loop></audio><div id="t"></div>
    <script>
    var n = Number(new URLSearchParams(location.search).get('n') || 1), track = 1, a = document.getElementById('a'), ms = navigator.mediaSession;
    function meta(){
      ms.metadata = new MediaMetadata({title: 'Fixture Song' + (track > 1 ? ' ' + track : '') + (n > 1 ? ' (' + n + ')' : ''),
        artist: 'Airc Band', album: 'Loopback', artwork: [{src: '/art.png', sizes: '96x96', type: 'image/png'}]});
      document.getElementById('t').textContent = ms.metadata.title;
    }
    meta();
    ms.setActionHandler('play', function(){ a.play(); ms.playbackState = 'playing'; });
    ms.setActionHandler('pause', function(){ a.pause(); ms.playbackState = 'paused'; });
    ms.setActionHandler('nexttrack', function(){ track++; meta(); });
    ms.setActionHandler('previoustrack', function(){ if (track > 1) track--; meta(); });
    function state(){ return {track: track, paused: a.paused, title: ms.metadata.title}; }
    a.play().then(function(){ ms.playbackState = 'playing'; document.title = 'Music playing'; }).catch(function(){ document.title = 'Music ready'; });
    </script>
    """

    static let callPage = """
    <!doctype html><meta charset="utf-8"><title>Call fixture</title>
    <style>body{margin:0;background:#193349;color:#fff;font:14px system-ui;overflow:hidden}video{width:100vw;height:100vh;object-fit:cover}
    #s{position:fixed;left:12px;bottom:12px;padding:4px 8px;border-radius:6px;background:rgba(0,0,0,.4)}</style>
    <video id="v" autoplay muted playsinline></video><audio id="r" src="/silence.wav" loop></audio><div id="s">connecting</div>
    <script>
    var id = (crypto.randomUUID ? crypto.randomUUID() : String(Math.random()).slice(2)), events = [], stream, a, b, mic = true, cam = true, ended = false;
    var sent = 0, failed = 0, ticks = 0;
    var devices = new URLSearchParams(location.search).has('devices');
    function synthetic(){
      var c = document.createElement('canvas'); c.width = 320; c.height = 180; var x = c.getContext('2d'), n = 0;
      setInterval(function(){ x.fillStyle = 'hsl(' + (n++ * 3 % 360) + ',45%,40%)'; x.fillRect(0, 0, 320, 180);
        x.fillStyle = '#fff'; x.font = '600 18px system-ui'; x.fillText('Airc call fixture', 18, 96); }, 66);
      var ac = new (window.AudioContext || window.webkitAudioContext)(), o = ac.createOscillator(), g = ac.createGain(), d = ac.createMediaStreamDestination();
      g.gain.value = 0; o.connect(g); g.connect(d); o.start();
      var s = c.captureStream(15); d.stream.getAudioTracks().forEach(function(t){ s.addTrack(t); }); return s;
    }
    function state(){ return {id: id, visibility: document.visibilityState, peers: [a && a.connectionState, b && b.connectionState],
      tracks: stream ? stream.getTracks().map(function(t){ return {kind: t.kind, state: t.readyState, enabled: t.enabled}; }) : [],
      mic: mic, cam: cam, ended: ended, events: events.slice(-6), beats: {ticks: ticks, sent: sent, failed: failed}}; }
    setInterval(function(){ ticks++; fetch('/beat', {method: 'POST', body: JSON.stringify(state())}).then(function(){ sent++; }, function(){ failed++; }); }, 250);
    function report(){
      try { navigator.mediaSession.setMicrophoneActive(mic); navigator.mediaSession.setCameraActive(cam); } catch (e) {}
      document.getElementById('s').textContent = ended ? 'call ended' : (mic ? 'mic on' : 'muted') + ' · ' + (cam ? 'camera on' : 'camera off');
    }
    async function start(){
      stream = devices ? await navigator.mediaDevices.getUserMedia({audio: true, video: true}) : synthetic();
      a = new RTCPeerConnection(); b = new RTCPeerConnection();
      a.onicecandidate = function(e){ e.candidate && b.addIceCandidate(e.candidate); };
      b.onicecandidate = function(e){ e.candidate && a.addIceCandidate(e.candidate); };
      b.ontrack = function(e){ document.getElementById('v').srcObject = e.streams[0]; };
      stream.getTracks().forEach(function(t){ a.addTrack(t, stream); });
      await a.setLocalDescription(await a.createOffer()); await b.setRemoteDescription(a.localDescription);
      await b.setLocalDescription(await b.createAnswer()); await a.setRemoteDescription(b.localDescription);
      var ms = navigator.mediaSession;
      ms.setActionHandler('togglemicrophone', function(){ mic = !mic; stream.getAudioTracks().forEach(function(t){ t.enabled = mic; }); events.push('mic:' + mic); report(); });
      ms.setActionHandler('togglecamera', function(){ cam = !cam; stream.getVideoTracks().forEach(function(t){ t.enabled = cam; }); events.push('cam:' + cam); report(); });
      ms.setActionHandler('hangup', hangup);
      // The far end's audio, as a call plays it (silent here: the fake devices' tone never reaches the speakers).
      document.getElementById('r').play().catch(function(e){ events.push('audio:' + e.name); });
      report(); events.push('started'); document.title = 'Call fixture (live)';
    }
    function hangup(){
      ended = true; events.push('hangup');
      if (stream) stream.getTracks().forEach(function(t){ t.stop(); });
      if (a) a.close(); if (b) b.close();
      document.getElementById('r').pause();
      ['togglemicrophone', 'togglecamera', 'hangup'].forEach(function(k){ try { navigator.mediaSession.setActionHandler(k, null); } catch (e) {} });
      report(); document.title = 'Call fixture (ended)';
    }
    start().catch(function(e){ events.push('error:' + e.name); document.title = 'Call fixture (error ' + e.name + ')'; });
    </script>
    """
}
#endif
