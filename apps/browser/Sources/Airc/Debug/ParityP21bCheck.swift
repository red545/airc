// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// A fake ready update whose notes are a loopback page and whose install runs what the check gives it.
private final class NotesReadyUpdate: ReadyUpdate {
    let version: String
    let releaseNotesURL: URL?
    private(set) var installs = 0
    var onInstall: (() -> Void)?
    init(version: String, notes: URL?) { self.version = version; releaseNotesURL = notes }
    func installAndRelaunch() { installs += 1; onInstall?() }
}

/// `--script parityp21b` (P21b, docs/qa/parity-audit.md E13/E15), both engines, loopback pages, a fake ready update
/// (scripted runs never start Sparkle; infra/updates proves Sparkle's own download, install and relaunch):
///   1. Personalization: the icons this build has; Outline goes up as the Dock's icon and back; the choice is in
///      settings.json; sound effects off silence every beep in the app (a real one: Bold with nothing editable);
///      haptic feedback off gives the app a performer that taps nothing.
///   2. What would be interrupted: a page playing music (the real probe, every window), the question's line for it,
///      Not Now keeps the update.
///   3. Restarting by itself (Arc's "Automatically update my Arc"): off by default; never in an automated run; on a fake
///      idle clock (never by waiting) it waits for Developer Mode pages, music playing or paused part-way, typed text,
///      a page that would ask "Leave site?", a private window with a page, Airc in front, input under 30 minutes ago,
///      the setting off, and (as the probe reports them) a call, screen sharing, a download, a page still sending and
///      picture in picture; it restarts once nothing would be interrupted, and once only per update.
///   4. See What's New from the pill's menu and from the question: the update's own notes in a new tab; Airc's release
///      notes when it has none.
///   5. Chromium: a restart cancelled by a page's "Leave site?" keeps every window, tab and the ready update, and the
///      next quit saves the session again.
/// `--script p21b-write` / `p21b-read` (the same data folder): two windows, two Spaces and a split, restarted through
/// the update; they all come back, with "Updated!".
extension SnapshotRunner {
    func parityP21bScenario() {
        let center = UpdateCenter.shared
        var server: LocalPageServer?, media: MediaLibServer?
        var base = "", mediaBase = ""
        var music = "", dirty = ""
        let notes = { URL(string: base + "/notes.html")! }
        var update = NotesReadyUpdate(version: "1.0 (209901010000)", notes: nil)
        var beeps = 0, beepsBefore = 0, silencedBefore = 0
        let button = { self.c.sidebar.update }
        func page(_ id: String) -> EngineTab? { c.engineTab(for: id) }
        /// Runs `js` as a click would: Chromium through DevTools' user gesture, WebKit's own evaluation is one.
        func gesture(_ id: @escaping () -> String, _ js: String) {
            step { [self] done in
                guard let p = page(id()) else { return done() }
                #if canImport(AircCore)
                if let chromium = app?.engine as? ChromiumEngine {
                    chromium.devToolsCall("Runtime.evaluate", params: ["expression": js, "userGesture": true, "awaitPromise": true,
                                                                     "returnByValue": true], in: p) { _, _ in done() }
                    return
                }
                #endif
                p.evaluate(js) { _ in done() }
            }
        }
        func risks(_ then: @escaping (UpdateRestartRisks) -> Void) {
            step { done in UpdateCenter.risksInEveryWindow { r in then(r); done() } }
        }
        func idle(_ name: String, away: TimeInterval = 31 * 60, active: Bool = false, expect: [IdleUpdatePolicy.Blocker],
                  installs: Int) {
            step { [self] done in
                center.idleTestClock = { (idle: away, active: active) }
                center.checkIdleRestart { blockers in
                    self.check(blockers == expect && update.installs == installs,
                               "parityp21b: idle: \(name) (\(blockers.map(\.rawValue)), installs \(update.installs))")
                    done()
                }
            }
        }

        step { [self] done in
            let leave = "<!doctype html><title>Unsaved</title><body style='font:18px -apple-system;padding:30px'><input id=f>"
                + "<script>onbeforeunload=function(e){if(window.__ask){e.preventDefault();e.returnValue=''}}</script>"
            server = LocalPageServer(pages: [
                "/plain.html": "<!doctype html><title>Plain</title><p style='font:18px -apple-system;padding:30px'>Plain page</p>",
                "/notes.html": "<!doctype html><title>Airc 1.0 notes</title><h1>What's new</h1>",
                "/leave.html": leave,
            ])
            media = MediaLibServer()
            server?.start { port in
                guard let port else { self.check(false, "parityp21b: the loopback pages"); return self.finish() }
                base = "http://127.0.0.1:\(port)"
                media?.start { mport in
                    mediaBase = mport.map { "http://127.0.0.1:\($0)" } ?? ""
                    done()
                }
            }
        }
        run { [self] in
            #if AIRC_TESTING
            AppPersonalization.testBeep = { beeps += 1 }
            #endif
            let sid = c.currentSpaceID
            guard let a = try? c.store.openTab(url: base + "/plain.html", inSpace: sid, activate: false, title: "Plain") else { return }
            c.reloadAll(animated: false)
            c.show(a.id, focus: true)
        }
        waitForPage()

        // 1. Personalization.
        run { [self] in
            let p = AppPersonalization.preferences
            check(p == PersonalizationPreferences() && AppPersonalization.availableIcons == [.holographic, .outline],
                  "parityp21b: personalization starts as Holographic, sounds and haptics on; this build has \(AppPersonalization.availableIcons.map(\.title))")
            // What the Dock shows, drawn at 32 px, against what it showed at launch (the app's own icon, as this
            // build's bundle has it): Outline differs, Holographic matches again.
            let launched = NSImage(data: NSApp.applicationIconImage.tiffRepresentation ?? Data())
            let difference = { Self.p21bIconDifference(NSApp.applicationIconImage, launched) }
            let custom = { difference() > 12 }
            check(Self.p21bIconDifference(AppPersonalization.image(for: .outline), launched) > 12,
                  "parityp21b: the Outline icon isn't the app's own")
            AppPersonalization.update { $0.appIcon = .outline }
            check(custom(), "parityp21b: Outline goes up as the Dock's icon (drawn on the icon grid; difference \(Int(difference())))")
            let reread = AppSettings(directory: AppPaths.dataDirectory).values.personalization
            check(reread.appIcon == .outline, "parityp21b: the icon choice is in settings.json (\(reread.appIcon.rawValue))")
            AppPersonalization.update { $0.appIcon = .holographic }
            check(difference() < 4, "parityp21b: Holographic again gives the Dock the app's own icon back (difference \(Int(difference())))")

            // Sounds: the app's own beeps (Format › Bold with nothing editable on the page beeps, through the page).
            beepsBefore = beeps
            NSSound.beep()
            FormatRouter.shared.apply(.bold, in: c.window)
        }
        wait(0.6)
        run { [self] in
            check(beeps >= beepsBefore + 1, "parityp21b: sound effects on, the app beeps (\(beeps - beepsBefore), Bold's \(beeps - beepsBefore > 1 ? "too" : "not on this engine"))")
            AppPersonalization.update { $0.playsSounds = false }
            beepsBefore = beeps
            silencedBefore = AppPersonalization.silencedBeeps
            NSSound.beep()
            FormatRouter.shared.apply(.bold, in: c.window)
            let reads = AppSettings(directory: AppPaths.dataDirectory).values.personalization.playsSounds
            check(!reads, "parityp21b: sound effects off is saved")
        }
        wait(0.6)
        run { [self] in
            check(beeps == beepsBefore && AppPersonalization.silencedBeeps > silencedBefore,
                  "parityp21b: sound effects off: no beep at all (\(beeps - beepsBefore) heard, \(AppPersonalization.silencedBeeps - silencedBefore) kept quiet)")
            AppPersonalization.update { $0.playsSounds = true }

            // Haptics.
            let on = NSHapticFeedbackManager.defaultPerformer
            AppPersonalization.update { $0.haptics = false }
            let off = NSHapticFeedbackManager.defaultPerformer
            let skipped = AppPersonalization.SilentHaptics.shared.skipped
            off.perform(.alignment, performanceTime: .now)
            check(on !== AppPersonalization.SilentHaptics.shared && off === AppPersonalization.SilentHaptics.shared
                  && AppPersonalization.SilentHaptics.shared.skipped == skipped + 1,
                  "parityp21b: Haptic feedback on is the trackpad's performer, off taps nothing")
            AppPersonalization.update { $0.haptics = true }
        }

        // 2. Music playing.
        run { [self] in
            guard !mediaBase.isEmpty, let t = try? c.store.openTab(url: mediaBase + "/music", inSpace: c.currentSpaceID, activate: false) else {
                return check(false, "parityp21b: the music page opens")
            }
            music = t.id
            c.reloadAll(animated: false)
            c.show(music, focus: false)
        }
        waitForPage()
        gesture({ music }, "document.getElementById('a').play().then(function(){navigator.mediaSession.playbackState='playing'})")
        step { [self] done in
            waitUntil({ page(music).map { (self.app?.engine as? EngineMedia)?.mediaSession(of: $0).playback == .playing || $0.isAudible } ?? true },
                      timeout: 6) { done() }
        }
        risks { [self] r in
            check(r.playing && !r.isEmpty && r.lines.contains("Music or video is playing. Restarting stops it."),
                  "parityp21b: music playing is something a restart interrupts (\(r.logText))")
        }
        // The click asks first; Not Now keeps the update.
        run { [self] in
            center.riskProbe = nil
            center.setReady(update)
            c.show(c.store.todayTabs(ofSpace: c.currentSpaceID).first { $0.id != music }?.id ?? music, focus: false)
            center.restart(from: c)
        }
        step { [self] done in waitUntil({ center.confirm != nil }, timeout: 3) { done() } }
        run { [self] in
            let lines = center.confirm?.model.risks.lines ?? []
            check(lines.contains("Music or video is playing. Restarting stops it.") && update.installs == 0,
                  "parityp21b: Restart to Update asks first while music plays in another tab (\(lines))")
            center.confirm?.model.onAnswer?(false)
        }
        wait(0.3)
        run { [self] in check(center.ready === update && update.installs == 0 && button().isShowing, "parityp21b: Not Now keeps the update and its button") }

        // 3. Restarting by itself, on a fake idle clock (HID idle seconds, Airc in front); never by waiting.
        run { [self] in
            let shown = NSApp.windows.filter(\.isVisible).map { w -> String in
                var depth = 0, p = w.parent
                while let q = p { depth += 1; p = q.parent }
                return "\(NSStringFromClass(type(of: w))) depth \(depth) level \(w.level.rawValue) \(Int(w.frame.width))×\(Int(w.frame.height))"
            }
            note("parityp21b: windows on screen: \(shown.joined(separator: "; ")); a dialog among them: \(UpdateCenter.dialogOnScreen)")
        }
        run { [self] in
            check(app?.settings.values.restartToUpdateWhenIdle == false && !IdleUpdatePolicy().enabled,
                  "parityp21b: Automatically update my Airc is off until turned on, as Arc's")
            center.setReady(update)
        }
        step { [self] done in
            // No fake clock: this is an automated run, which never restarts by itself.
            center.idleTestClock = nil
            app?.settings.values.restartToUpdateWhenIdle = true
            center.checkIdleRestart { blockers in
                self.check(blockers.contains(.automated) && update.installs == 0 && UpdateCenter.isAutomatedRun,
                           "parityp21b: idle: never in an automated run (\(blockers.map(\.rawValue)))")
                done()
            }
        }
        // Developer Mode on by itself for these loopback pages (localhost): what a local server's pages hold back.
        idle("waits for Developer Mode pages (a local server's)", expect: [.media, .developerMode], installs: 0)
        run { [self] in app?.settings.values.developerAutomatic = false }
        idle("waits while music plays", expect: [.media], installs: 0)
        idle("waits while Airc is in front", active: true, expect: [.active], installs: 0)
        idle("waits after input 29 minutes ago (HID idle, not Airc in the background)", away: 29 * 60, expect: [.recentInput], installs: 0)
        run { [self] in app?.settings.values.restartToUpdateWhenIdle = false }
        idle("waits with Automatically update my Airc off", expect: [.turnedOff], installs: 0)
        run { [self] in app?.settings.values.restartToUpdateWhenIdle = true }
        gesture({ music }, "document.getElementById('a').pause();navigator.mediaSession.playbackState='paused';true")
        step { [self] done in
            waitUntil({ page(music).map { (self.app?.engine as? EngineMedia)?.mediaSession(of: $0).playback != .playing && !$0.isAudible } ?? true },
                      timeout: 6) { done() }
        }
        idle("waits for music paused part-way (it would start over)", expect: [.media], installs: 0)
        // The music page goes elsewhere: no media left.
        run { page(music)?.load(URL(string: base + "/plain.html")!) }
        step { [self] done in
            waitUntil({ page(music).map { $0.url?.path == "/plain.html" && !$0.isLoading
                && (self.app?.engine as? EngineMedia)?.mediaSession(of: $0).playback == EngineMediaSession.Playback.none } ?? true },
                      timeout: 8) { done() }
        }
        // A page with typed text, and one that would ask "Leave site?" (it needs the person's touch first).
        run { [self] in
            guard let t = try? c.store.openTab(url: base + "/leave.html", inSpace: c.currentSpaceID, activate: false) else { return }
            dirty = t.id
            c.reloadAll(animated: false)
            c.show(dirty, focus: false)
        }
        waitForPage()
        gesture({ dirty }, "document.getElementById('f').focus();document.getElementById('f').value='draft';window.__ask=true;true")
        var asks = false
        step { [self] done in
            let js = "JSON.stringify({v:document.getElementById('f').value,d:document.getElementById('f').defaultValue,r:" + UpdateRestartRisks.pageScript + "})"
            guard let p = page(dirty) else { return done() }
            p.evaluate(js) { v in self.note("parityp21b: the typed-text page says \(v.map { "\($0)" } ?? "nothing")"); done() }
        }
        risks { [self] r in
            asks = r.leaveSite == 1
            check(r.editedForms == 1, "parityp21b: the probe sees a page with typed text (\(r.logText))")
            if !asks { note("parityp21b: idle: the unsaved page has no user activation on this engine (\(r.logText)): Leave site? isn't asked") }
        }
        step { [self] done in
            center.idleTestClock = { (idle: 31 * 60, active: false) }
            center.checkIdleRestart { blockers in
                let want: [IdleUpdatePolicy.Blocker] = asks ? [.leaveSite, .editedForms] : [.editedForms]
                self.check(blockers == want && update.installs == 0,
                           "parityp21b: idle: waits for a page that would ask Leave site? and has typed text (\(blockers.map(\.rawValue)))")
                done()
            }
        }
        gesture({ dirty }, "window.__ask=false;true")
        idle("waits for typed text alone (no Leave site? handler)", expect: [.editedForms], installs: 0)
        gesture({ dirty }, "document.getElementById('f').value='';true")
        // A private window with a page.
        var privateWindow: PrivateWindowController?
        step { [self] done in
            guard let app else { return done() }
            PrivateBrowsing.shared.open(app: app) { w in
                privateWindow = w
                _ = w?.openPage(URL(string: base + "/plain.html"), foreground: true)
                done()
            }
        }
        wait(0.6)
        idle("waits while a private window has pages (they'd be lost)", expect: [.privateWindows], installs: 0)
        run { privateWindow?.closeWindow() }
        step { done in self.waitUntil({ PrivateBrowsing.shared.windows.isEmpty }, timeout: 5) { done() } }
        // The other reasons, as the real probe reports them (a call, screen sharing, a download, a loading page,
        // picture in picture), each on its own.
        let others: [(String, (inout UpdateRestartRisks) -> Void, IdleUpdatePolicy.Blocker)] = [
            ("a call", { $0.call = true }, .call), ("screen sharing", { $0.screenSharing = true }, .screenSharing),
            ("a download", { $0.downloads = 1 }, .downloads), ("a page still sending", { $0.loading = 1 }, .loading),
            ("picture in picture", { $0.pictureInPicture = true }, .pictureInPicture),
        ]
        for (name, risk, blocker) in others {
            run { center.riskProbe = { _, done in var r = UpdateRestartRisks(); risk(&r); done(r) } }
            idle("waits for \(name)", expect: [blocker], installs: 0)
        }
        run { center.riskProbe = nil }
        idle("restarts once nothing would be interrupted", expect: [], installs: 1)
        idle("tries once per update", expect: [.notReady], installs: 1)
        run { [self] in
            center.idleTestClock = nil
            app?.settings.values.restartToUpdateWhenIdle = false
            app?.settings.values.developerAutomatic = true
            check(update.installs == 1, "parityp21b: the idle restart went through the same install as the button")
        }

        // 4. See What's New.
        run { [self] in
            update = NotesReadyUpdate(version: "1.0 (209901020000)", notes: notes())
            center.setReady(update)
            let menu = button().pillMenu()
            check(menu.items.map(\.title) == [UpdateButtonView.hoverTitle, UpdateConfirmModel.whatsNewTitle],
                  "parityp21b: the pill's menu: Restart to Update, See What’s New (\(menu.items.map(\.title)))")
            if let i = menu.items.firstIndex(where: { $0.title == UpdateConfirmModel.whatsNewTitle }) { menu.performActionForItem(at: i) }
        }
        step { [self] done in waitUntil({ self.c.shownTabID.flatMap { self.c.engineTab(for: $0) }?.url?.path == "/notes.html" }, timeout: 6) { done() } }
        run { [self] in
            check(c.shownTabID.flatMap { c.engineTab(for: $0) }?.url?.path == "/notes.html" && update.installs == 0,
                  "parityp21b: See What’s New opens the update's own release notes in a new tab, nothing installs")
            check(UpdateCenter.shared.whatsNewURL == notes(), "parityp21b: the update's notes are What's New")
            let none = NotesReadyUpdate(version: "1.0 (209901030000)", notes: nil)
            center.setReady(none)
            check(center.whatsNewURL == ParityCommandCatalog.releaseNotes, "parityp21b: an update without notes points to Airc's release notes")
            center.setReady(update)
            center.riskProbe = { _, done in var r = UpdateRestartRisks(); r.downloads = 1; done(r) }
            center.restart(from: c)
        }
        step { [self] done in waitUntil({ center.confirm != nil }, timeout: 3) { done() } }
        run { [self] in
            let tabs = c.store.todayTabs(ofSpace: c.currentSpaceID).count
            center.confirm?.model.onWhatsNew?()
            check(c.store.todayTabs(ofSpace: c.currentSpaceID).count == tabs + 1 && center.confirm != nil,
                  "parityp21b: the question's See What’s New opens the notes and keeps the question")
            center.confirm?.model.onAnswer?(false)
            center.riskProbe = nil
        }
        wait(0.4)

        // 5. A cancelled restart.
        cancelledRestart(update: { update }, dirty: { dirty }, gesture: gesture)

        run { [self] in
            // The run's own quit mustn't ask.
            for t in c.store.todayTabs(ofSpace: c.currentSpaceID) { page(t.id)?.evaluate("window.__ask=false;onbeforeunload=null;true") { _ in } }
            center.setReady(nil)
            AppPersonalization.testBeep = nil
            server?.stop()
            media?.stop()
        }
        wait(0.4)
    }

    /// Chromium: the page asks "Leave site?" during the update's quit and the person stays. The dialog is read and
    /// answered through the engine's test hook (`--airc-test=modalDialogs`, its scratch test gate; build-app.sh passes
    /// it to this run on Chromium); without the hook the case is skipped before any quit starts. If the dialog doesn't
    /// come or doesn't go, the page's handler is cleared and the run ends at once (finishForcing): never a hung app
    /// holding the UI lock.
    private func cancelledRestart(update: @escaping () -> NotesReadyUpdate, dirty: @escaping () -> String,
                                  gesture: (@escaping () -> String, String) -> Void) {
        #if canImport(AircCore)
        guard let engine = app?.engine as? ChromiumEngine else {
            return run { [self] in note("parityp21b: a quit cancelled by Leave site? is Chromium's (WebKit pages don't ask at quit; the question above does)") }
        }
        let center = UpdateCenter.shared
        var windows = 0, tabs: [String] = [], gated = false
        func dialogs() -> [[String: Any]] {
            c.engineTab(for: dirty()).map { engine.modalDialogState(for: $0)["dialogs"] as? [[String: Any]] ?? [] } ?? []
        }
        func clearHandler() { c.engineTab(for: dirty())?.evaluate("window.__ask=false;onbeforeunload=null;true") { _ in } }
        run { [self] in
            c.show(dirty(), focus: false)
            gated = c.engineTab(for: dirty()).map { !engine.modalDialogState(for: $0).isEmpty } ?? false
            if !gated { note("parityp21b: cancel: SKIP: no modal-dialog test hook in this launch (--airc-test=modalDialogs); no quit started") }
        }
        // (Without the hook nothing quits; the run's last step clears the handler again.)
        gesture(dirty, "document.getElementById('f').value='draft again';window.__ask=true;true")
        run { [self] in
            guard gated else { return }
            windows = app?.controllers.count ?? 0
            tabs = c.store.todayTabs(ofSpace: c.currentSpaceID).map(\.id)
            update().onInstall = { NSApp.terminate(nil) }
            center.restart(from: c)
        }
        step { [self] done in
            guard gated else { return done() }
            waitUntil({ center.confirm != nil }, timeout: 3) { done() }
        }
        run { [self] in
            guard gated else { return }
            check(center.confirm?.model.risks.leaveSite == 1, "parityp21b: cancel: the page with unsaved changes is in the question first")
            center.confirm?.model.onAnswer?(true)
        }
        step { [self] done in
            guard gated else { return done() }
            waitUntil({ !dialogs().isEmpty }, timeout: 8) {
                guard !dialogs().isEmpty else {
                    clearHandler()
                    return self.finishForcing("FAIL parityp21b: cancel: the quit for the update never reached the page's Leave site?")
                }
                self.check(true, "parityp21b: cancel: the quit for the update reaches the page's Leave site?")
                done()
            }
        }
        step { [self] done in
            guard gated else { return done() }
            // Stay: the dialog's Cancel, through the engine's handler for it.
            let pressed = c.engineTab(for: dirty()).map { engine.cancelModalDialog(in: $0) } ?? false
            waitUntil({ dialogs().isEmpty && self.app?.windowSession.quitting == false }, timeout: 5) {
                guard dialogs().isEmpty, self.app?.windowSession.quitting == false else {
                    clearHandler()
                    return self.finishForcing("FAIL parityp21b: cancel: Stay didn't close Leave site? (handler found \(pressed))")
                }
                self.check(pressed, "parityp21b: cancel: Stay pressed and the quit is cancelled")
                done()
            }
        }
        wait(0.8)
        run { [self] in
            guard gated else { return }
            let same = c.store.todayTabs(ofSpace: c.currentSpaceID).map(\.id) == tabs
            check(app?.controllers.count == windows && same && c.window.isVisible && c.engineTab(for: dirty())?.isClosed == false,
                  "parityp21b: cancel: every window, tab and page stays (\(app?.controllers.count ?? 0) windows, tabs the same \(same))")
            check(app?.windowSession.quitting == false, "parityp21b: cancel: the session is the app's again (the next quit saves it)")
            check(center.ready === update() && p21bButton.isShowing && update().installs == 1,
                  "parityp21b: cancel: the update stays ready, its button too")
            update().onInstall = nil
        }
        #endif
    }

    /// How different two icons look at 32 px (mean channel difference, 0–255).
    static func p21bIconDifference(_ a: NSImage?, _ b: NSImage?) -> Double {
        func pixels(_ i: NSImage?) -> [UInt8] {
            guard let i, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 128, bitsPerPixel: 32)
            else { return [] }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            i.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
            NSGraphicsContext.restoreGraphicsState()
            return Array(UnsafeBufferPointer(start: rep.bitmapData, count: 32 * 32 * 4))
        }
        let x = pixels(a), y = pixels(b)
        guard x.count == y.count, !x.isEmpty else { return 255 }
        return Double(zip(x, y).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(x.count)
    }

    private var p21bButton: UpdateButtonView { c.sidebar.update }

    // MARK: Across the update's restart

    private struct P21bExpected: Codable {
        struct W: Codable { var spaceID: String; var tabID: String?; var split: [String]? }
        var windows: [W]
    }

    private var p21bExpectedFile: URL { dir.appendingPathComponent("p21b-session.json") }

    /// Two windows on two Spaces, the second with a split on screen, then Restart to Update. The run's end is the quit
    /// Sparkle's install starts (`NSApp.terminate`), after the version stamp says the build was older.
    func p21bWrite() {
        var server: LocalPageServer?, base = ""
        step { [self] done in
            server = LocalPageServer(pages: [
                "/a.html": "<!doctype html><title>Home page</title><p>Home</p>",
                "/b.html": "<!doctype html><title>Left</title><p>Left</p>",
                "/c.html": "<!doctype html><title>Right</title><p>Right</p>",
            ])
            server?.start { port in
                base = port.map { "http://127.0.0.1:\($0)" } ?? ""
                done()
            }
        }
        run { [self] in
            guard let app, !base.isEmpty, let a = try? c.store.openTab(url: base + "/a.html", inSpace: c.currentSpaceID, activate: false, title: "Home page"),
                  let work = try? c.store.createSpace(name: "Work", icon: nil, theme: c.store.selectedSpace.theme,
                                                      profileID: c.store.profile(ofSpace: c.currentSpaceID).id, after: c.currentSpaceID),
                  let l = try? c.store.openTab(url: base + "/b.html", inSpace: work.id, activate: false, title: "Left"),
                  let r = try? c.store.openTab(url: base + "/c.html", inSpace: work.id, activate: false, title: "Right"),
                  let x = try? c.store.createSplit([l.id, r.id], inSpace: work.id, axis: .horizontal, focused: r.id) else {
                return check(false, "p21b-write: two Spaces, a split")
            }
            c.reloadAll(animated: false)
            c.show(a.id, focus: false)
            let w2 = app.openNewWindow(from: c, spaceID: work.id, tab: .id(r.id), commandBar: false)
            w2?.show(r.id, focus: false)
            check(app.controllers.count == 2 && w2?.shownSplitID == x.id, "p21b-write: two windows, the Work one shows its split")
        }
        wait(1.0)
        run { [self] in
            guard let app else { return }
            let expected = P21bExpected(windows: app.controllers.map {
                .init(spaceID: $0.currentSpaceID, tabID: $0.shownTabID, split: $0.store.split($0.shownSplitID)?.tabIDs)
            })
            try? JSONEncoder().encode(expected).write(to: p21bExpectedFile)
            try? Data("0.0.1 (1)".utf8).write(to: UpdateCenter.lastVersionFile)
            let update = NotesReadyUpdate(version: "1.0 (209901010000)", notes: nil)
            UpdateCenter.shared.riskProbe = { _, done in done(UpdateRestartRisks()) }
            UpdateCenter.shared.setReady(update)
            UpdateCenter.shared.restart(from: c)
            check(update.installs == 1, "p21b-write: Restart to Update with nothing at risk installs at once")
            UpdateCenter.shared.riskProbe = nil
            server?.stop()
        }
    }

    func p21bRead() {
        wait(1.0)
        step { [self] done in
            guard let app, let data = try? Data(contentsOf: p21bExpectedFile),
                  let expected = try? JSONDecoder().decode(P21bExpected.self, from: data) else {
                check(false, "p21b-read: the write run left its expectations")
                return done()
            }
            check(app.controllers.count == expected.windows.count, "p21b-read: \(expected.windows.count) windows come back (\(app.controllers.count))")
            for (i, (w, e)) in zip(app.controllers, expected.windows).enumerated() {
                let split = w.store.split(w.shownSplitID)?.tabIDs
                check(w.currentSpaceID == e.spaceID && w.shownTabID == e.tabID && split == e.split,
                      "p21b-read: window \(i + 1): its Space (\(w.store.space(w.currentSpaceID)?.name ?? "?")), tab and \(e.split == nil ? "no split" : "split") as before")
            }
            UpdateCenter.shared.noteLaunchedVersion(inScriptedRun: true)
            waitUntil({ self.c.toast.shownText?.hasPrefix("Updated!") == true }, timeout: 15) {
                let stamp = try? String(contentsOf: UpdateCenter.lastVersionFile, encoding: .utf8)
                self.check(self.c.toast.shownText == UpdateCenter.updatedMessage(UpdateCenter.runningVersion) && stamp == UpdateCenter.runningVersion,
                           "p21b-read: after the update's restart: “\(self.c.toast.shownText ?? "no toast")”")
                done()
            }
        }
        capture("p21b-restored")
    }
}
#endif
