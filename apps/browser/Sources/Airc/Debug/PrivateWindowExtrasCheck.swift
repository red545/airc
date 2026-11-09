// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script private`, second part (both engines; PW-1, PrivateWindowExtras.swift), on loopback pages:
///   - ⌘F opens the find field over the private window's page; typing finds the matches, ⌘G moves on (Chromium:
///     "2 of 3"), Esc closes it;
///   - the page's shortcuts first (CB-3), as in the main window: ⌘F and ⌘L a page uses stay the page's, a page that
///     doesn't leaves them to the window; ⌘Z in a page field undoes the field's typing; ⇧⌘V pastes plain text;
///   - a download from a private window: a row in its sidebar, the file in the downloads folder (the run's scratch
///     folder, never ~/Downloads), nothing in the main window's Downloads; the list goes with the session and a new
///     private window starts with none; the file stays.
/// Keys are posted to the app's queue for the private window, which this run treats as key (ShortcutsCheck's
/// stand-in); never HID input. The general pasteboard is saved first and put back.
extension SnapshotRunner {
    private static let privateEditor = """
        <!doctype html><meta charset=utf-8><title>private keys</title>
        <style>body{margin:0;font:15px -apple-system,sans-serif}#ed{position:absolute;left:40px;top:40px;width:420px;height:90px;border:1px solid #999}
        #in{position:absolute;left:40px;top:160px;width:420px}p{position:absolute;left:40px;top:200px}</style>
        <div id=ed contenteditable>Hello world</div>
        <input id=in value="one two three" autocomplete=off>
        <p>needle one, needle two, needle three</p>
        <script>
        var ed=document.getElementById('ed'),inp=document.getElementById('in');
        var log=[],prevent={},loadID=Math.random().toString(36).slice(2);
        function combo(e){return (e.metaKey?'cmd+':'')+(e.ctrlKey?'ctrl+':'')+(e.altKey?'alt+':'')+(e.shiftKey?'shift+':'')+e.code}
        addEventListener('keydown',function(e){var c=combo(e);if(prevent[c])e.preventDefault();log.push('kd '+c+(e.defaultPrevented?' prevented':''))},true);
        addEventListener('beforeinput',function(e){log.push('bi '+e.inputType)},true);
        addEventListener('paste',function(e){log.push('paste')},true);
        function reset(){ed.innerHTML='Hello world';inp.value='one two three';prevent={};log=[]}
        function selectText(el,a,b){el.focus();var t=el.firstChild,r=document.createRange();r.setStart(t,a);r.setEnd(t,b);var s=getSelection();s.removeAllRanges();s.addRange(r)}
        function caret(el,a,b){el.focus();el.setSelectionRange(a,b===undefined?a:b)}
        function state(){var l=log;log=[];return JSON.stringify({ed:ed.innerHTML,iv:inp.value,active:(document.activeElement||{}).id||'',loadID:loadID,log:l})}
        </script>
        """

    func privateWindowExtrasScenario() {
        let chromium = app?.engine.name.hasPrefix("Chromium") == true
        let tag = chromium ? "chromium" : "webkit"
        Key.strict = chromium
        var server: LocalPageServer?
        var port: UInt16 = 0
        var w: PrivateWindowController?
        var savedPasteboard: [[NSPasteboard.PasteboardType: Data]] = []
        let token = "pwx\(Int.random(in: 100_000...999_999))"
        let scratch = AppPaths.dataDirectory.appendingPathComponent("private-downloads", isDirectory: true)
        var opened: [String] = []
        var home = ""
        func base() -> String { "http://127.0.0.1:\(port)" }
        let page = { w?.shownPage }

        step { [self] done in
            let file = String(repeating: "private download \(token)\n", count: 400)
            server = LocalPageServer(responses: [
                "/editor": .init(body: Self.privateEditor),
                "/start": .init(body: "<!doctype html><title>start</title><a id=a href='/file.bin'>file</a>"),
                "/file.bin": .init(headers: ["Content-Disposition": "attachment; filename=\"private-\(token).txt\""], body: file),
            ])
            guard let server else { check(false, "private extras: the loopback server starts"); return done() }
            server.start { p in
                if let p { port = p } else { self.check(false, "private extras: the loopback server starts") }
                done()
            }
        }
        // The downloads go to a scratch folder: WebKit's by its override; Chromium's by the Space profile's download
        // folder, which its private session inherits. So the private window comes from a Space with such a profile.
        step { [self] done in
            try? FileManager.default.removeItem(at: scratch)
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            DownloadCenter.interceptOpen = { opened.append($0.download.fileName); return true }
            DownloadCenter.reveal = { _ in }
            WebKitLibrary.directoryOverride = scratch
            WebKitLibrary.opener = { opened.append($0.lastPathComponent) }
            savedPasteboard = Self.pasteboardItems()
            home = c.currentSpaceID
            guard chromium else { return done() }
            do {
                let p = try c.store.createProfile(name: "Private downloads")
                let folder = Self.chromiumUserData.appendingPathComponent(p.engineDirectory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let prefs = ["download": ["default_directory": scratch.path, "prompt_for_download": false, "directory_upgrade": true],
                             "savefile": ["default_directory": scratch.path]]
                try JSONSerialization.data(withJSONObject: prefs).write(to: folder.appendingPathComponent("Preferences"))
                let first = c.store.selectedSpace
                let space = try c.store.createSpace(name: "Private downloads", icon: nil, theme: first.theme, profileID: p.id, after: first.id)
                let t = try c.store.openTab(url: "data:text/html,%3Ctitle%3Eanchor%3C/title%3E", inSpace: space.id)
                c.profiles.whenLoaded(p.id, { [self] _ in
                    c.reloadAll(animated: false)
                    c.switchToSpace(space.id, animated: false)
                    c.show(t.id, focus: false)
                    done()
                }, failed: { self.check(false, "private extras: the downloads profile loads"); done() })
            } catch {
                check(false, "private extras: setup (\(error))")
                done()
            }
        }
        step { [self] done in
            guard let app, port != 0 else { return done() }
            PrivateBrowsing.shared.open(app: app) { x in
                w = x
                x?.openPage(URL(string: base() + "/editor"))
                done()
            }
        }
        waitPrivate(page, title: "private keys", "private extras (\(tag)): the editor page loads in a private window")

        // MARK: Find (⌘F ⌘G, Esc)
        // With the keyboard outside the page, ⌘F is the window's at once (the page-first path is checked below, where
        // the window stands in as key: an unused key comes back through the main menu, which goes to the key window).
        run { [self] in
            guard let w else { return }
            w.window.makeFirstResponder(nil)
            postKey(.cmd("⌘F", 3, "f"), to: w.window)
        }
        step { [self] done in
            waitUntil({ w?.findBar != nil }, timeout: 3) {
                guard let w, let bar = w.findBar else { self.check(false, "private extras (\(tag)): ⌘F opens the find field"); return done() }
                self.check(bar.superview === w.root && w.window.firstResponder === bar.field.currentEditor()
                           && bar.frame.maxX <= w.card.frame.maxX && bar.frame.minX >= w.card.frame.minX,
                           "private extras (\(tag)): ⌘F opens the find field over the private window's page, with the keyboard (\(Self.describe(w.window.firstResponder)))")
                // A click into the field first: a window that never had a mouse-down drops posted keys.
                let p = bar.field.convert(NSPoint(x: bar.field.bounds.midX, y: bar.field.bounds.midY), to: nil)
                self.click(at: p, in: w.window) {
                    for ch in "needle" { self.postText(String(ch), to: w.window) }
                    self.waitUntil({ bar.statusText.contains("3") }, timeout: 4) {
                        self.check(bar.field.stringValue == "needle" && bar.statusText.contains("3"),
                                   "private extras (\(tag)): typing finds the page's three matches (\"\(bar.field.stringValue)\": \"\(bar.statusText)\")")
                        done()
                    }
                }
            }
        }
        run { [self] in if let w { postKey(.cmd("⌘G", 5, "g"), to: w.window) } }
        step { [self] done in
            guard let bar = w?.findBar else { return done() }
            // Chromium says which match is active (routed to this window's bar); WebKit only counts them.
            let want = chromium ? "2 of 3" : "3 matches"
            waitUntil({ bar.statusText == want }, timeout: 3) {
                self.check(bar.statusText == want, "private extras (\(tag)): ⌘G goes to the next match (\"\(bar.statusText)\")")
                done()
            }
        }
        capturePrivate({ w }, "private-window-find")
        run { [self] in if let w { postText("\u{1b}", keyCode: 53, to: w.window) } }
        step { [self] done in
            waitUntil({ w?.findBar == nil }, timeout: 3) {
                self.check(w?.findBar == nil, "private extras (\(tag)): Esc closes the find field")
                done()
            }
        }

        // MARK: The page's shortcuts first (CB-3)
        // The page takes the keyboard (and ⌘ keys as key equivalents) only in a key window: ShortcutsCheck's stand-in.
        run { [self] in if let w { Self.emulateKeyWindow(w.window) { [weak self] in self?.note($0) } } }
        step { [self] done in clickIntoPrivatePage({ w }) { _ in done() } }
        for (key, state, undo) in [
            (Key.cmd("⌘F", 3, "f"), { (x: PrivateWindowController) in x.findBar != nil ? "find field" : "-" }, { (x: PrivateWindowController) in x.closeFind(refocusPage: true) }),
            (Key.cmd("⌘L", 37, "l"), { (x: PrivateWindowController) in x.commandBar.map { "command bar \($0.mode)" } ?? "-" }, { (x: PrivateWindowController) in x.closeCommandBar() }),
        ] {
            var before = ""
            run { if let w { before = state(w) } }
            privateKeyCase(key, { w }, setup: "reset();prevent['\(key.page)']=1;caret(inp,3)", settle: KeyMonitor.pageAnswerTimeout + 0.15) { [self] s, log in
                let after = w.map(state) ?? "?"
                check(log.filter { $0.hasPrefix("kd \(key.page)") } == ["kd \(key.page) prevented"] && after == before,
                      "private extras (\(tag)): \(key.name) a page uses stays the page's (window: \(before) → \(after), log \(log.joined(separator: ", ")))")
            }
            wait(1.05)   // past the second-press window
            privateKeyCase(key, { w }, setup: "reset();caret(inp,3)", settle: 0.4) { [self] s, log in
                let after = w.map(state) ?? "?"
                check(log.filter { $0.hasPrefix("kd \(key.page)") } == ["kd \(key.page)"] && after != before,
                      "private extras (\(tag)): \(key.name) a page doesn't use runs the window's command once (window: \(before) → \(after), log \(log.joined(separator: ", ")))")
                if let w { undo(w) }
            }
            wait(0.3)
            step { [self] done in clickIntoPrivatePage({ w }) { _ in done() } }
        }
        // ⌘Z in a page field: the field's own undo (the Edit menu's undo: on the page), never a browser command.
        let undo = Key.cmd("⌘Z", 6, "z")
        privateKeyCase(undo, { w }, setup: "reset();caret(inp,13);document.execCommand('insertText',false,' four')") { [self] s, log in
            check(s["iv"] as? String == "one two three" && log.contains { $0.hasPrefix("bi historyUndo") } && log.filter { $0.hasPrefix("kd \(undo.page)") }.count == 1,
                  "private extras (\(tag)): ⌘Z in a page field undoes its typing (\"\(s["iv"] ?? "-")\", log \(log.joined(separator: ", ")))")
        }
        // ⇧⌘V: Paste and Match Style, the clipboard's text without its formatting.
        let rich = "<meta charset=utf-8><b>Bold</b> and <i>rich</i>"
        let matchStyle = Key.cmdShift("⇧⌘V", 9, "V")
        run { Self.putRichText(html: rich, plain: "Bold and rich") }
        privateKeyCase(matchStyle, { w }, setup: "reset();ed.innerHTML='x';selectText(ed,1,1)") { [self] s, log in
            let html = s["ed"] as? String ?? ""
            check(log.contains("kd \(matchStyle.page)") && log.contains("paste") && html.contains("Bold and rich") && !html.contains("<b>"),
                  "private extras (\(tag)): ⇧⌘V pastes plain text into the page (\(html), log \(log.joined(separator: ", ")))")
        }
        run { [self] in
            KeyMonitor.testKeyWindowDispatch = nil
            if UICheckAttempt.mayRestorePasteboard { Self.restorePasteboard(savedPasteboard) }
            else { note("private extras: the pasteboard changed outside the check; left as it is") }
        }

        // MARK: Downloads
        var fileRow: DownloadCenter.Item?
        run { [self] in
            check(w?.downloads != nil && w?.sidebar.downloads.isHidden == true,
                  "private extras (\(tag)): the private session has a downloads list, empty and out of view at first")
            page()?.load(URL(string: base() + "/start")!)
        }
        waitPrivate(page, title: "start", "private extras (\(tag)): a page with a file link loads")
        run { page()?.load(URL(string: base() + "/file.bin")!) }
        // The private session inherits the parent's download preferences: no Save panel.
        // Cancel a regressed panel safely so the remaining isolation checks can still run.
        var asked = false
        step { [self] done in
            waitUntil({ w?.window.attachedSheet is NSSavePanel || w?.downloads?.items.contains { $0.download.state == .complete } == true }, timeout: 10) {
                if let panel = w?.window.attachedSheet as? NSSavePanel {
                    asked = true
                    panel.cancel(nil)
                }
                self.check(!asked && w?.downloads?.items.contains { $0.download.state == .complete } == true,
                           "private extras (\(tag)): the download completes without a Save panel")
                done()
            }
        }
        step { [self] done in
            guard asked else { return done() }
            waitUntil({ w?.window.attachedSheet == nil && w?.downloads?.items.allSatisfy { $0.download.state != .inProgress } == true }, timeout: 5) {
                let r = w?.downloads?.items.first
                self.check(r != nil && r?.download.state != .inProgress,
                           "private extras (\(tag)): the private window lists its download, ended when the panel was cancelled (\(r.map { DownloadCenter.status($0) } ?? "no row"))")
                done()
            }
        }
        step { [self] done in
            if asked {
                fileRow = w?.downloads?.items.first
                self.skip("private extras (\(tag)): the download into the folder and opening it (the engine asked where to save)")
                return done()
            }
            waitUntil({ w?.downloads?.items.contains { $0.download.state == .complete && $0.download.fileName.contains(token) } == true }, timeout: 10) {
                fileRow = w?.downloads?.items.first { $0.download.fileName.contains(token) }
                let file = scratch.appendingPathComponent("private-\(token).txt")
                let body = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                self.check(fileRow?.download.state == .complete && body.contains(token),
                           "private extras (\(tag)): a private window's download finishes into the downloads folder (\(fileRow.map { DownloadCenter.status($0) } ?? "no row"), \(body.count) bytes)")
                if fileRow?.download.state != .complete {
                    for r in w?.downloads?.items ?? [] {
                        let d = r.download
                        self.note("private extras: row \(d.fileName) state \(d.state) \(d.received)/\(d.total ?? -1) path \(d.path ?? "-") "
                                  + "dangerous \(d.dangerous) type \(d.dangerType) paused \(d.paused) interrupt \(d.interruptReason)")
                    }
                    let others = NSApp.windows.filter { $0.isVisible && $0 !== w?.window && $0 !== self.c.window }
                    self.note("private extras: other windows \(others.map { "\(type(of: $0)) \($0.title)" }), sheet \(w?.window.attachedSheet.map { "\(type(of: $0))" } ?? "none")")
                }
                done()
            }
        }
        wait(0.4)
        run { [self] in
            guard let w else { return }
            w.root.layoutSubtreeIfNeeded()
            let view = w.sidebar.downloads
            check(!view.isHidden && view.frame.height == PrivateDownloadsView.rowHeight && w.sidebar.downloadRows == 1,
                  "private extras (\(tag)): its row shows in the private window's sidebar (\(Int(view.frame.height)) pt, \(w.sidebar.downloadRows) row)")
            let main = MediaLibrary.shared.downloads?.items ?? []
            check(!main.contains { $0.download.fileName.contains(token) || $0.download.url.contains("/file.bin") },
                  "private extras (\(tag)): the main window's Downloads don't list it (\(main.count) rows there)")
        }
        capturePrivate({ w }, "private-window-downloads")
        // A click on a finished download opens the file (recorded here, never opened on the build Mac). A first click
        // a background window's SwiftUI view swallows is made once more, as the main sidebar's tray check does.
        step { [self] done in
            guard !asked, let w, let row = fileRow, let host = w.sidebar.downloads.hostingView else { return done() }
            let name = "private.download.\(row.download.id)"
            func attempt(_ n: Int) {
                clickAnchor(name, in: host) {
                    self.waitUntil({ opened.contains(row.download.fileName) }, timeout: 1.5) {
                        if !opened.contains(row.download.fileName), n == 0 { return attempt(1) }
                        self.check(opened.contains(row.download.fileName),
                                   "private extras (\(tag)): a click on the finished download opens the file (\(TestAnchors.lastHit[name] ?? "-"))")
                        done()
                    }
                }
            }
            attempt(0)
        }
        // The session ends with its last window: the list goes, the file stays; a new private window lists nothing. A
        // download still running makes the window ask first (its own sheet): this run answers Cancel Downloads.
        run { w?.closeWindow() }
        step { [self] done in
            waitUntil({ w?.window.attachedSheet != nil || PrivateBrowsing.shared.windows.isEmpty }, timeout: 3) {
                if let win = w?.window, win.attachedSheet != nil {
                    let texts = self.sheetTexts(of: win)
                    self.note("private extras: closing asked first: \(texts.joined(separator: " / "))")
                    self.pressSheetButton(texts.contains { $0.contains("downloads") } ? "Cancel Downloads" : "Cancel Download", in: win)
                }
                done()
            }
        }
        step { [self] done in
            let pid = c.store.profile(ofSpace: c.currentSpaceID).id
            waitUntil({ PrivateBrowsing.shared.windows.isEmpty && PrivateBrowsing.shared.sessionEnded(pid, app: self.app) }, timeout: 10) {
                let file = scratch.appendingPathComponent("private-\(token).txt")
                self.check(PrivateBrowsing.shared.downloads(of: pid) == nil && (asked || FileManager.default.fileExists(atPath: file.path)),
                           "private extras (\(tag)): closing the last private window drops its downloads list and keeps the file")
                done()
            }
        }
        step { [self] done in
            guard let app else { return done() }
            PrivateBrowsing.shared.open(app: app) { x in
                w = x
                done()
            }
        }
        step { [self] done in
            waitUntil({ w?.downloads != nil }, timeout: 2) {
                let n = w?.downloads?.items.count ?? -1
                self.check(n == 0 && w?.sidebar.downloads.isHidden == true, "private extras (\(tag)): a new private window starts with no downloads (\(n))")
                let main = MediaLibrary.shared.downloads?.items ?? []
                self.check(!main.contains { $0.download.fileName.contains(token) }, "private extras (\(tag)): still none in the main window's Downloads")
                done()
            }
        }
        run { [self] in
            w?.closeWindow()
            server?.stop()
            DownloadCenter.interceptOpen = nil
            DownloadCenter.reveal = { NSWorkspace.shared.activateFileViewerSelecting($0) }
            WebKitLibrary.directoryOverride = nil
            if !home.isEmpty { c.switchToSpace(home, animated: false) }
        }
        wait(1)
    }

    /// Waits until the private page shows `title`, loaded.
    private func waitPrivate(_ tab: @escaping () -> EngineTab?, title: String, _ what: String) {
        step { [self] done in
            waitUntil({ tab()?.title == title && tab()?.isLoading == false }, timeout: 12) {
                self.check(tab()?.title == title, what + " (\(tab()?.title ?? "no page"))")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done)
            }
        }
    }

    /// Plain typing for `window`'s first responder (a key-down/up pair).
    func postText(_ chars: String, keyCode: UInt16 = 0, to window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode) else { continue }
            NSApp.postEvent(e, atStart: false)
        }
    }

    /// `k` for `window`, as the layout makes it, through the app's queue.
    func postKey(_ k: Key, to window: NSWindow) {
        if k.unavailable { return note("SKIP \(k.name): this keyboard layout can't type it (\(Self.layoutName))") }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: k.mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: k.chars,
                                           charactersIgnoringModifiers: k.ignoring, isARepeat: false, keyCode: k.code) else { continue }
            NSApp.postEvent(e, atStart: false)
        }
    }

    /// Gives the private page the keyboard and waits until it has it (`focusedPage`): posted clicks first, as
    /// clickIntoPage does for the main window (they also give the page a user activation), each followed by up to 1 s
    /// for the engine to move the keyboard; then, if three clicks didn't (a ship run, 2026-11-06: "3×: user activation
    /// 0, focused false", and every key case after it failed for that alone), the page's own focus(). `done(true)` once
    /// it has the keyboard, whichever way; `done(false)` if it still hasn't.
    func clickIntoPrivatePage(_ w: @escaping () -> PrivateWindowController?, _ done: @escaping (Bool) -> Void) {
        var clicks = 0
        let hasKeyboard = { w()?.focusedPage != nil }
        func attempt() {
            guard let x = w(), let page = x.shownPage else { return done(false) }
            if hasKeyboard(), clicks > 0 { return done(true) }
            guard clicks < 3 else {
                note("private extras: \(clicks) clicks left the page without the keyboard (first responder "
                     + "\(Self.describe(x.window.firstResponder))); giving it the keyboard with the page's focus()")
                page.focus()
                return waitUntil(hasKeyboard, timeout: 1) {
                    self.note("private extras: after focus() the page \(hasKeyboard() ? "has" : "still hasn't") the keyboard")
                    done(hasKeyboard())
                }
            }
            let p = x.card.convert(NSPoint(x: x.card.bounds.midX, y: x.card.bounds.maxY - 60), to: nil)
            clicks += 1
            click(at: p, in: x.window) {
                self.waitUntil(hasKeyboard, timeout: 1) {
                    page.evaluate("navigator.userActivation ? navigator.userActivation.hasBeenActive : true") { active in
                        if active as? Bool == true && hasKeyboard() {
                            self.note("private extras: clicked into the page \(clicks)×: user activation \(active ?? "-"), focused true")
                            done(true)
                        } else {
                            attempt()
                        }
                    }
                }
            }
        }
        attempt()
    }

    /// ShortcutsCheck's keyCase for the private window's page.
    func privateKeyCase(_ k: Key, _ w: @escaping () -> PrivateWindowController?, setup: String, settle: Double = 0.35,
                        verdict: @escaping ([String: Any], [String]) -> Void) {
        uiCase(window: { w()?.window }) {
            run { [self] in
                uiAttempt?.monitorsPasteboard = ["c", "x", "v"].contains(k.ignoring.lowercased())
                uiAttempt?.pasteboardReadOnly = k.ignoring.lowercased() == "v"
                if uiAttempt?.retry == true { w()?.closeFind(refocusPage: true); w()?.closeCommandBar() }
            }
            if k.unavailable { return run { [self] in skip("private extras: \(k.name): this keyboard layout can't type it (\(Self.layoutName))") } }
            step { [self] done in
                if w()?.focusedPage != nil { return done() }
                clickIntoPrivatePage(w) { _ in done() }
            }
            step { done in
                guard let p = w()?.shownPage else { return done() }
                p.evaluate("(function(){\(setup);return loadID})()") { _ in done() }
            }
            // Right before the key, not only before the setup: the page has the keyboard (the case is about where its keys
            // go, so it must have it), and the key monitor sends this window's keys through it. Otherwise the key goes
            // straight to the window's command and the case fails for the setup, not for what it checks.
            var unready: String?
            step { [self] done in
                guard let x = w() else { return done() }
                func post() {
                    unready = nil
                    postKey(k, to: x.window)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.waitUntil({ !KeyMonitor.isWaitingForPage }, timeout: 3) {
                            DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: done)
                        }
                    }
                }
                let routed = PrivateBrowsing.shared.window(for: x.window) === x && KeyMonitor.testKeyWindowDispatch != nil
                if x.focusedPage != nil, routed { return post() }
                note("private extras: \(k.name): the page lost the keyboard after the setup (first responder "
                     + "\(Self.describe(x.window.firstResponder)), keys routed \(routed)); back into it, and the setup again")
                clickIntoPrivatePage(w) { ok in
                    guard ok, routed, let p = x.shownPage else {
                        unready = "the page never had the keyboard (first responder \(Self.describe(x.window.firstResponder)), "
                            + "this window's keys routed \(routed))"
                        return done()
                    }
                    // The click moved the caret the setup put: the setup again, then the key.
                    p.evaluate("(function(){\(setup);return loadID})()") { _ in post() }
                }
            }
            step { [self] done in
                guard let p = w()?.shownPage else { check(false, "private extras: \(k.name): no page"); return done() }
                p.evaluate("state()") { v in
                    let s = (v as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
                    // Not posted: the verdict fails, saying why.
                    if let unready {
                        verdict(s, ["(not posted: \(unready))"])
                        return done()
                    }
                    self.uiAttempt?.recordInputDelivery((s["log"] as? [String] ?? []).contains { $0.hasPrefix("kd \(k.page)") })
                    self.uiAttempt?.sample()
                    verdict(s, s["log"] as? [String] ?? ["(no answer: \(String(describing: v)))"])
                    done()
                }
            }
        }
    }
}
#endif
