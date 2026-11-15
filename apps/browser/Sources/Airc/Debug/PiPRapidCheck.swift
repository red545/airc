// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import WebKit

// `--script pipreturn-rapid` (both engines; the Chromium build lists localhost as a Safari-engine service itself):
//
// 1. The tray's Hide and Picture in Picture back to back, 20 times: the reopen arrives while WebKit's previous system
//    player is still closing. Each round must end with exactly one open system player (WebKit's state and PIPAgent's
//    window), the video in it and playing, and the tray row saying so.
// 2. A close that arrives while the open is still entering, 5 times: it ends closed, the video plays on inline, the tray
//    agrees; the next open works.
// 3. Another tab: its open while the first tab's player closes, and an open while the first tab's player is up. One
//    system player at a time, the newest tab's. An open waiting for a close is replaced by a newer one (it's answered
//    "replaced").
// 4. Chromium's own player: 20 actual leave/reentry pairs, stable after deferred host exits, and close during open.
//
// Loopback video pages, generated silent media. No camera, microphone, screen capture, input events or focus changes.

extension SnapshotRunner {
    func pipRapidCase(port: @escaping () -> UInt16, firstSpace: @escaping () -> String,
                      verdict: @escaping (Bool, String) -> Void, beginCase: (String) -> Void, endCase: () -> Void) {
        let main = c
        var a = "", b = "", away = ""
        var media: MediaCenter? { MediaLibrary.shared.media }
        func page(_ id: String) -> WebKitTab? { main?.engineTab(for: id) as? WebKitTab }
        func row(_ id: String) -> MediaCenter.Player? { media?.players.first { $0.tabID == id } }
        func onScreen() -> [[String: Any]] { (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? [] }
        func width(_ w: [String: Any]) -> CGFloat {
            (w[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }?.width ?? 0
        }
        /// The system players macOS actually shows: PIPAgent's (or AVKit's) on-screen windows.
        func agentWindows() -> Int {
            onScreen().filter { w in
                let owner = w[kCGWindowOwnerName as String] as? String ?? ""
                return (owner.contains("PIP") || owner.contains("Picture")) && width(w) > 40
            }.count
        }
        /// Owners and layers of every other process's on-screen window (no window titles).
        func otherWindows() -> String {
            onScreen().filter { ($0[kCGWindowOwnerPID as String] as? Int32) != getpid() && width($0) > 40 }
                .map { "\($0[kCGWindowOwnerName as String] as? String ?? "?")@\($0[kCGWindowLayer as String] as? Int ?? 0) \(Int(width($0)))" }
                .joined(separator: ", ")
        }
        func openTabs() -> String {
            [("A", a), ("B", b)].map { n, id in "\(n) \(page(id).map(SystemPictureInPicture.isOpen) == true ? "open" : "closed")" }.joined(separator: ", ")
        }
        /// Exactly one open system player, `id`'s, playing, in the page and the tray.
        func onlyOpen(_ id: String) -> Bool {
            guard let p = page(id) else { return false }
            return SystemPictureInPicture.isOpen(p) && SystemPictureInPicture.openCount == 1 && agentWindows() == 1
                && row(id)?.inSystemPictureInPicture == true && !SystemPictureInPicture.hasQueuedOpen
        }
        func noneOpen() -> Bool {
            SystemPictureInPicture.openCount == 0 && agentWindows() == 0 && !SystemPictureInPicture.hasQueuedOpen
                && [a, b].allSatisfy { row($0)?.inSystemPictureInPicture != true }
        }
        let inPage = "(document.pictureInPictureElement === v || v.webkitPresentationMode === 'picture-in-picture') && !v.paused"
        let inline = "!document.pictureInPictureElement && v.webkitPresentationMode === 'inline' && !v.paused"
        /// Waits for `ok` (4 s), then checks it and the page expression in the same turn.
        func settle(_ what: String, _ id: @escaping () -> String, _ ok: @escaping () -> Bool, page js: String, timeout: Double = 4) {
            step { [self] done in
                let started = Date()
                waitUntil(ok, timeout: timeout) {
                    let waited = Date().timeIntervalSince(started)
                    guard let p = page(id()) else { verdict(false, "pipreturn: \(what) (no page)"); return done() }
                    p.evaluate("JSON.stringify([!!(\(js)), document.pictureInPictureElement === v, v.webkitPresentationMode, v.paused])") { v in
                        let text = v as? String ?? "?"
                        verdict(ok() && text.hasPrefix("[true"),
                                String(format: "pipreturn: %@ (%.2f s; %@; system players %d, PIPAgent windows %d, tray %@; page %@)", what, waited,
                                       openTabs(), SystemPictureInPicture.openCount, agentWindows(),
                                       row(id())?.inSystemPictureInPicture == true ? "open" : "closed", text))
                        done()
                    }
                }
            }
        }
        func hide(_ id: String, _ done: @escaping () -> Void) {
            if let r = row(id) { media?.systemMiniPlayer("hide", r, completion: done) }
            else { page(id)?.closeSystemPictureInPicture(pause: false, completion: done) ?? done() }
        }

        beginCase("rapid reopen")
        run { [self] in
            guard port() != 0, let main else { return }
            do {
                a = try main.store.openTab(url: "http://localhost:\(port())/video", inSpace: firstSpace()).id
                b = try main.store.openTab(url: "http://localhost:\(port())/video", inSpace: firstSpace()).id
                away = try main.store.openTab(url: "data:text/html,<title>Notes</title><p>Notes", inSpace: firstSpace()).id
                main.reloadAll(animated: false); main.show(b, focus: false)
            } catch { check(false, "pipreturn: rapid setup \(error)") }
        }
        // Each tab loads once it's shown.
        step { [self] done in waitUntil({ page(b)?.isLoading == false && page(b)?.title == "Video" }, timeout: 15) { done() } }
        run { main?.show(a, focus: false) }
        step { [self] done in
            waitUntil({ [a, b].allSatisfy { page($0)?.isLoading == false && page($0)?.title == "Video" } }, timeout: 15) { done() }
        }
        for id in [{ a }, { b }] {
            step { done in page(id())?.evaluate("v.play(); true") { _ in done() } ?? done() }
            settle("rapid: a video page plays", id, { true }, page: "!v.paused")
        }
        run { main?.show(away, focus: false) }
        wait(0.4)
        step { [self] done in
            guard let p = page(a) else { return done() }
            p.requestSystemPictureInPicture { r in self.note("pipreturn: rapid: first open: \(r)"); done() }
        }
        settle("rapid: tab A's video is in the system picture in picture", { a }, { onlyOpen(a) }, page: inPage)
        run { self.note("pipreturn: rapid: other processes' on-screen windows with A's player open: \(otherWindows())") }

        // 1. Hide, and Picture in Picture before the close has finished.
        for round in 1...20 {
            step { [self] done in
                var closed = false, answer: String?
                let started = Date()
                let events = SystemPictureInPicture.events.count
                hide(a) { closed = true }
                page(a)?.requestSystemPictureInPicture { answer = $0 } ?? { answer = "no page" }()
                waitUntil({ closed && answer != nil }, timeout: 10) {
                    self.note(String(format: "pipreturn: rapid %d: closed %@, reopen answered %@ after %.2f s; %@", round, closed ? "yes" : "no",
                                     answer ?? "nothing", Date().timeIntervalSince(started),
                                     SystemPictureInPicture.events.dropFirst(events).joined(separator: "; ")))
                    verdict(answer == "requested", "pipreturn: rapid \(round): the reopen during the close is answered requested (\(answer ?? "nothing"))")
                    done()
                }
            }
            settle("rapid \(round): close→reopen ends with exactly one open system player, playing, the tray in sync", { a }, { onlyOpen(a) }, page: inPage)
        }

        // 2. A close while the open is still entering.
        endCase()
        beginCase("close during open")
        for round in 1...5 {
            step { done in hide(a, done) }
            settle("close during open \(round): set-up closed", { a }, noneOpen, page: inline)
            step { [self] done in
                var closed = false, answer: String?
                let events = SystemPictureInPicture.events.count
                page(a)?.requestSystemPictureInPicture { answer = $0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + (round == 1 ? 0 : 0.05 * Double(round))) {
                    page(a)?.closeSystemPictureInPicture(pause: false) { closed = true } ?? { closed = true }()
                }
                waitUntil({ closed && answer != nil }, timeout: 10) {
                    self.note("pipreturn: close during open \(round): open answered \(answer ?? "nothing"), closed \(closed); "
                              + SystemPictureInPicture.events.dropFirst(events).joined(separator: "; "))
                    done()
                }
            }
            settle("close during open \(round): ends closed, the video inline and playing, the tray in sync", { a }, noneOpen, page: inline)
            step { done in page(a)?.requestSystemPictureInPicture { _ in done() } ?? done() }
            settle("close during open \(round): the next open has exactly one system player", { a }, { onlyOpen(a) }, page: inPage)
        }

        // 3. Two tabs, one system player.
        endCase()
        beginCase("rapid other tab")
        for round in 1...5 {
            // B's open while A's player closes.
            step { done in
                var closed = false, answer: String?
                hide(a) { closed = true }
                page(b)?.requestSystemPictureInPicture { answer = $0 }
                self.waitUntil({ closed && answer != nil }, timeout: 10) {
                    self.note("pipreturn: rapid other tab \(round): B answered \(answer ?? "nothing")"); done()
                }
            }
            settle("rapid other tab \(round): B's open during A's close leaves only B's player", { b }, { onlyOpen(b) }, page: inPage)
            settle("rapid other tab \(round): A's video is back inline and plays", { a }, { true }, page: inline)
            // A's open while B's player is up: B's closes first.
            step { done in page(a)?.requestSystemPictureInPicture { r in self.note("pipreturn: rapid other tab \(round): A answered \(r)"); done() } ?? done() }
            settle("rapid other tab \(round): A's open with B's player up leaves only A's", { a }, { onlyOpen(a) }, page: inPage)
            settle("rapid other tab \(round): B's video is back inline and plays", { b }, { true }, page: inline)
        }
        // A newer open replaces one that waits for a close.
        step { [self] done in
            var closed = false, first: String?, second: String?
            hide(a) { closed = true }
            page(a)?.requestSystemPictureInPicture { first = $0 }
            page(b)?.requestSystemPictureInPicture { second = $0 }
            waitUntil({ closed && first != nil && second != nil }, timeout: 10) {
                verdict(first == "replaced" && second == "requested",
                        "pipreturn: rapid: an open waiting for a close is replaced by a newer one (A \(first ?? "nothing"), B \(second ?? "nothing"))")
                done()
            }
        }
        settle("rapid: the newer open has the only system player", { b }, { onlyOpen(b) }, page: inPage)
        step { done in hide(b, done) }
        settle("rapid: all closed at the end", { b }, noneOpen, page: inline)
        run {
            let lines = SystemPictureInPicture.events
            self.note("pipreturn: rapid: \(lines.count) serialization log lines; timeouts \(lines.filter { $0.contains("waited") }.count)")
            verdict(!lines.contains { $0.contains("waited") && $0.contains("runs now") },
                    "pipreturn: rapid: no open had to fall back to the \(Int(SystemPictureInPicture.queueTimeout)) s timeout")
        }
        endCase()

        #if canImport(AircCore)
        if let chromium = app?.engine as? ChromiumEngine { chromiumRapidCase(chromium, port: port, firstSpace: firstSpace, verdict: verdict, beginCase: beginCase, endCase: endCase) }
        #endif
        run { for id in [a, b, away] where !id.isEmpty { main?.closeTab(id) } }
        wait(0.5)
    }

    #if canImport(AircCore)
    /// Chromium's own video picture in picture (127.0.0.1 is a Chromium page): close and reopen at once.
    private func chromiumRapidCase(_ chromium: ChromiumEngine, port: @escaping () -> UInt16, firstSpace: @escaping () -> String,
                                   verdict: @escaping (Bool, String) -> Void, beginCase: (String) -> Void, endCase: () -> Void) {
        let main = c
        var tab = "", away = ""
        func page() -> EngineTab? { main?.engineTab(for: tab) }
        func window() -> NSWindow? { page().flatMap { PiPEngineOverlay.state($0, in: chromium)?["window"] as? NSWindow } }
        // Guarded test windows use normal level; count their recorded production
        // configuration too, without raising them over another application's work.
        func floating() -> Int {
            NSApp.windows.filter {
                let selector = NSSelectorFromString("aircProductionPiPConfiguration")
                let tagged = $0.responds(to: selector) && $0.value(forKey: "aircProductionPiPConfiguration") is NSDictionary
                return $0.isVisible && ($0.level == .floating || tagged) && $0.frame.width > 40
            }.count
        }
        func evaluate(_ js: String, _ done: @escaping (Any?, String?) -> Void) {
            guard let p = page() else { return done(nil, "no page") }
            chromium.devToolsCall("Runtime.evaluate", params: ["expression": js, "userGesture": true, "awaitPromise": true, "returnByValue": true], in: p) { r, e in
                done((r?["result"] as? [String: Any])?["value"], e.map { "\($0)" })
            }
        }
        func describe(_ v: Any?, _ e: String?) -> String { v.map { "\($0)" } ?? e ?? "nothing" }
        let open = "v.requestPictureInPicture().then(function(){ return 'in'; }, function(e){ return 'refused ' + e.name; })"
        let forcedRace = ProcessInfo.processInfo.arguments.contains {
            $0.hasPrefix("--airc-test=") && $0.dropFirst("--airc-test=".count).split(separator: ",").contains("pipExitRace")
        }
        // Normally the host owns the exit: wait for its leave event, without a
        // competing page Stop() that could disconnect the pending native reply.
        // With the guarded delay, the page deliberately closes/reopens FIRST to
        // exercise a stale native exit against a genuinely new generation.
        let leave = forcedRace
            ? "if (document.pictureInPictureElement) await document.exitPictureInPicture();"
            : "if (document.pictureInPictureElement) await new Promise(resolve => v.addEventListener('leavepictureinpicture', resolve, {once:true}));"
        func onlyOne() -> Bool {
            guard let w = window(), w.isVisible, let p = page() else { return false }
            return floating() == 1 && PiPOverlays.shared.controls(for: p)?.window === w
        }
        func settle(_ what: String, _ ok: @escaping () -> Bool, page js: String, record: ((Bool) -> Void)? = nil) {
            step { [self] done in
                let started = Date()
                waitUntil(ok, timeout: 4) {
                    evaluate("JSON.stringify([!!(\(js)), document.pictureInPictureElement === v, v.paused])") { v, _ in
                        let text = v as? String ?? "?"
                        let passed = ok() && text.hasPrefix("[true")
                        record?(passed)
                        verdict(passed,
                                String(format: "pipreturn: chromium %@ (%.2f s; window %@, PiP windows %d, Airc controls on it %@; page %@)",
                                       what, Date().timeIntervalSince(started), window()?.isVisible == true ? "visible" : "none", floating(),
                                       page().map { PiPOverlays.shared.controls(for: $0)?.window != nil && PiPOverlays.shared.controls(for: $0)?.window === window() } == true ? "yes" : "no", text))
                        done()
                    }
                }
            }
        }
        beginCase("chromium rapid reopen")
        run { [self] in
            guard let main else { return }
            do {
                tab = try main.store.openTab(url: "http://127.0.0.1:\(port())/aspect", inSpace: firstSpace()).id
                away = try main.store.openTab(url: "data:text/html,<title>Notes</title><p>Notes", inSpace: firstSpace()).id
                main.reloadAll(animated: false); main.show(tab, focus: false)
            } catch { check(false, "pipreturn: chromium rapid setup \(error)") }
        }
        step { [self] done in waitUntil({ page()?.isLoading == false && page()?.title == "Aspect" }, timeout: 15) { done() } }
        step { done in evaluate("window.__pipEntries = 0; window.__pipLeaves = 0; v.addEventListener('enterpictureinpicture', () => ++window.__pipEntries); v.addEventListener('leavepictureinpicture', () => ++window.__pipLeaves); load('/movie.mp4').then(function(){ return 'playing'; })") { _, _ in done() } }
        step { done in evaluate(open) { v, e in self.note("pipreturn: chromium rapid: first open \(describe(v, e))"); done() } }
        settle("rapid: the video is in Chromium's picture in picture", onlyOne, page: "document.pictureInPictureElement === v && !v.paused")
        var greenRounds = 0
        var entered = false
        for round in 1...20 {
            step { [self] done in
                entered = false
                guard let p = page() else { verdict(false, "pipreturn: chromium rapid: missing page"); return done() }
                chromium.closePictureInPicture(p)
                // Blink resolves a request for the current element with the OLD
                // window. Require a real leave/reentry, with no sleep between them.
                evaluate("(async () => { \(leave) return await \(open); })()") { v, e in
                    entered = (v as? String) == "in"
                    verdict(entered, "pipreturn: chromium rapid \(round): actual leave then reopen enters (\(describe(v, e)))")
                    done()
                }
            }
            // Cross both normal posted tasks and the scratch-only 500 ms race
            // injection. An instantaneous visible-window sample is insufficient.
            wait(0.75)
            settle("rapid \(round): close→reopen ends with exactly one picture in picture window, Airc's controls on it", onlyOne,
                   page: "document.pictureInPictureElement === v && !v.paused && window.__pipEntries === \(round + 1) && window.__pipLeaves === \(round)",
                   record: { if entered && $0 { greenRounds += 1 } })
        }
        run { verdict(greenRounds == 20, "pipreturn: chromium rapid: all 20 real reentries stay open (\(greenRounds)/20)") }
        endCase()
        beginCase("chromium close during open")
        for round in 1...5 {
            step { [self] done in
                guard let p = page() else { return done() }
                chromium.closePictureInPicture(p)
                waitUntil({ page().map { PiPEngineOverlay.state($0, in: chromium)?["window"] == nil } ?? true && floating() == 0 }, timeout: 4) {
                    // Start the entry without waiting for it, and close before it has a window.
                    evaluate("window.__entry = \(open); 'started'") { _, _ in
                        if let p = page() { chromium.closePictureInPicture(p) }
                        evaluate("window.__entry") { v, _ in
                            self.note("pipreturn: chromium close during open \(round): open answered \(describe(v, nil))")
                            if let p = page() { chromium.closePictureInPicture(p) }   // an entry that finished after the close
                            done()
                        }
                    }
                }
            }
            settle("close during open \(round): the window is gone, the video plays inline", {
                (window()?.isVisible != true) && floating() == 0
            }, page: "!document.pictureInPictureElement && !v.paused")
            step { done in evaluate(open) { _, _ in done() } }
            settle("close during open \(round): the next open has exactly one window", onlyOne, page: "document.pictureInPictureElement === v")
        }
        run { if let p = page() { chromium.closePictureInPicture(p) } }
        wait(0.5)
        run { for id in [tab, away] where !id.isEmpty { main?.closeTab(id) } }
        endCase()
    }
    #endif
}
#endif
