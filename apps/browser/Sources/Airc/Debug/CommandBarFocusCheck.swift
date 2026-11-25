// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit
import WebKit

/// `--script cbfocus` (feedback: typing into ⌘T's bar sometimes typed nothing, and the keys reached the page
/// underneath, a YouTube video paused or popped out). With a playing video page as the tab, in each case below: ⌘T,
/// then “k”, Space, “i” (YouTube's pause, pause and picture-in-picture keys), then Esc. Asserted per case: the page
/// (and its frame) saw no key, the bar's field holds exactly “k i” (the first key too), the field has the keyboard,
/// and after Esc the keyboard is back where it was. Real presses from the UI driver (AIRC_REAL_KEYS=1, a dedicated
/// session), PID-targeted, one combo per call (~0.3 s apart); `burst` posts its keys to the app's queue at once
/// (labelled posted). The fixture is a loopback page: a canvas `captureStream` video (no camera), a text box and a
/// frame with its own box; with `?steal=1` it calls `window.focus()` and focuses its player every 150 ms, as an
/// aggressive player page does. `AIRC_CBFOCUS_BEFORE=1` turns the bar's keyboard guard off (the before arm, one
/// binary); `AIRC_CBFOCUS_CASES=a,b` picks cases (the runner's time bound). Every refused or allowed attempt to take
/// the keyboard from the open bar is logged with its caller (CommandBarView.focusAttempts): the cause.
///
/// fskeys: `fullscreen` runs on both engines (Chromium's element full screen fills the page's card in the browser window):
/// ⌘T leaves it within the exit budget (WebKit 1.5 s, its window's animation, 0.7–1.0 s measured; Chromium 0.5 s), keys typed meanwhile land
/// in the field. The exit cases leave element full screen another way and time it from the input to the page back in its
/// window, with no full-screen window left and the browser window key (never a half state): `fsesc` (a real Esc),
/// `fsbutton` (a real click on the page's own exit button), `fstab` (a tab switch), `fsrace` (WebKit: the page enters full
/// screen while a presentation close of its tab is still waiting, here for a stand-in player window that then goes; before
/// fskeys that close then waited for the full screen too, and every later exit of the tab joined it and never ran; then a
/// tab switch). `AIRC_FSKEYS_BEFORE=1`: the presentation close's unbounded wait (the before arm).
/// fskeys: who discards queued events (NSApplication.discardEvents(matching:before:)), with the caller, for keys typed
/// during WebKit's full-screen exit that neither the page nor the app's key monitor ever saw.
enum DiscardLog {
    static var entries: [String] = []
    private static var installed = false
    static func install() {
        guard !installed else { return }
        installed = true
        let cls: AnyClass = NSApplication.self
        guard let a = class_getInstanceMethod(cls, #selector(NSApplication.discardEvents(matching:before:))),
              let b = class_getInstanceMethod(cls, #selector(NSApplication.airc_discardEvents(matching:before:))) else { return }
        method_exchangeImplementations(a, b)
    }
    static func record(_ mask: NSEvent.EventTypeMask) {
        let caller = Thread.callStackSymbols.dropFirst(2).prefix(6)
            .map { $0.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).prefix(3).joined(separator: " ") }
        entries.append(String(format: "%.3f mask %llx: ", CACurrentMediaTime(), mask.rawValue) + caller.joined(separator: " < "))
    }
}

extension NSApplication {
    @objc func airc_discardEvents(matching mask: NSEvent.EventTypeMask, before lastEvent: NSEvent?) {
        DiscardLog.record(mask)
        airc_discardEvents(matching: mask, before: lastEvent)   // the original (exchanged)
    }
}

extension SnapshotRunner {
    func commandBarFocusScenario() {
        let engineName = app?.engine is WebKitEngine ? "WebKit" : "Chromium"
        let arm = CommandBarView.guardsKeyboard ? "fix" : "before"
        let tag = "cbfocus (\(engineName), \(arm))"
        let pid = ProcessInfo.processInfo.processIdentifier
        let all = ["load", "click", "input", "iframe", "steal", "fullscreen", "tabswitch", "space", "twice", "held", "burst",
                   "littlearc", "agent", "pip", "inactive", "tab"]
        let exitCases = ["fsesc", "fsbutton", "fstab", "fsrace"]
        let picked = ProcessInfo.processInfo.environment["AIRC_CBFOCUS_CASES"].map { $0.split(separator: ",").map(String.init) } ?? all + exitCases
        // fskeys: how long leaving element full screen may take, from the input to the page back in the browser window.
        let exitBudget = engineName == "WebKit" ? 1500.0 : 500.0
        var server: LocalPageServer?
        var port: UInt16 = 0
        var realInput = false
        var video = "", stealer = "", other = "", farVideo = ""
        var home = "", far = ""
        var little: LittleArcController?
        var results: [String: String] = [:]
        let typedKeys = ["k", "space", "i"], expected = "k i"

        let videoPage = """
        <!doctype html><title>cbfocus video</title>
        <style>body{margin:0;background:#111;color:#eee;font:14px -apple-system,sans-serif}#wrap{width:640px;height:360px}
        video{width:640px;height:360px;display:block;background:#000}input{margin:8px;font-size:16px;width:200px}iframe{border:0}
        #wrap{position:relative}#leave{position:absolute;left:40px;top:300px;font-size:16px;padding:6px 12px}</style>
        <div id=wrap tabindex=0><video id=player muted playsinline autoplay tabindex=0></video><button id=leave onclick="window.leaveClicks++;document.exitFullscreen()">Exit</button></div>
        <input id=box placeholder=box><iframe id=fr src="/frame" width=320 height=60></iframe>
        <script>
        const keys = []; window.keysSeen = keys; window.pauses = 0; window.pipOpens = 0; window.focusCalls = 0; window.leaveClicks = 0;
        const c = document.createElement('canvas'); c.width = 320; c.height = 180; const g = c.getContext('2d'); let n = 0;
        setInterval(() => { n++; g.fillStyle = 'hsl(' + (n * 7 % 360) + ',60%,40%)'; g.fillRect(0, 0, 320, 180);
          g.fillStyle = '#fff'; g.font = '20px sans-serif'; g.fillText(String(n), 12, 30); }, 33);
        const v = document.getElementById('player'); v.srcObject = c.captureStream(30); v.play().catch(() => {});
        addEventListener('keydown', e => {
          keys.push((e.metaKey || e.altKey || e.ctrlKey ? 'mod:' : '') + 'top:' + e.key + (e.target && e.target.id ? '@' + e.target.id : ''));
          if (e.target && e.target.id === 'box') return;
          if (e.key === ' ' || e.key === 'k') { e.preventDefault(); if (v.paused) v.play(); else { v.pause(); window.pauses++; } }
          if (e.key === 'i') v.requestPictureInPicture().then(() => window.pipOpens++).catch(err => keys.push('pipError:' + err.name));
          if (e.key === 'f') document.getElementById('wrap').requestFullscreen().catch(err => keys.push('fsError:' + err.name));
        }, true);
        addEventListener('message', e => { if (e.data && e.data.cbfocusKey) keys.push('frame:' + e.data.cbfocusKey); });
        if (location.search.includes('steal=1')) setInterval(() => {
          window.focusCalls++; try { window.focus(); } catch (e) {}
          const a = document.activeElement; if (!a || a === document.body) document.getElementById('wrap').focus();
        }, 150);
        window.cbfocusState = () => JSON.stringify({keys: keys.slice(), paused: v.paused, pauses: window.pauses, pip: !!document.pictureInPictureElement,
          pipOpens: window.pipOpens, fs: !!document.fullscreenElement, active: document.activeElement ? (document.activeElement.id || document.activeElement.tagName) : null,
          frameActive: (() => { try { const d = document.getElementById('fr').contentDocument; return d && d.activeElement ? (d.activeElement.id || d.activeElement.tagName) : null; } catch (e) { return 'x'; } })(),
          focusCalls: window.focusCalls, hasFocus: document.hasFocus(), leaveClicks: window.leaveClicks});
        </script>
        """
        let framePage = """
        <!doctype html><style>body{margin:0;background:#222}input{margin:8px;font-size:16px;width:200px}</style>
        <input id=fi placeholder=frame><script>addEventListener('keydown', e => parent.postMessage({cbfocusKey: (e.metaKey || e.altKey || e.ctrlKey ? 'mod:' : '') + e.key}, '*'), true);</script>
        """

        // MARK: helpers
        func page(_ id: String) -> EngineTab? { c.engineTab(for: id) }
        func state(_ tab: EngineTab?, _ then: @escaping ([String: Any]) -> Void) {
            guard let tab else { return then([:]) }
            tab.evaluate("window.cbfocusState ? window.cbfocusState() : '{}'") { v in
                let d = (v as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
                then(d)
            }
        }
        func js(_ tab: EngineTab?, _ code: String, _ then: @escaping () -> Void) {
            guard let tab else { return then() }
            tab.evaluate(code) { _ in then() }
        }
        /// Who has the window's keyboard, in words.
        func responder(_ w: NSWindow) -> String {
            guard let r = w.firstResponder else { return "nil" }
            if let bar = c.commandBar, bar.hasKeyboard { return "bar" }
            if let v = r as? NSView {
                for id in [video, stealer, other, farVideo] where !id.isEmpty {
                    if let pv = page(id)?.view, v === pv || v.isDescendant(of: pv) { return "page(\(id == video ? "video" : id == stealer ? "steal" : id == other ? "other" : "far"))" }
                }
                if let host = c.card.hostView, v.isDescendant(of: host) { return "page-host \(Swift.type(of: v))" }
            }
            if r === w { return "window" }
            return String(describing: Swift.type(of: r))
        }
        /// The page is in element full screen, by its engine's own state.
        func inFullscreen(_ tab: EngineTab?) -> Bool {
            if let w = tab as? WebKitTab { return w.webView.fullscreenState != .notInFullscreen }
            #if canImport(AircCore)
            return (tab as? ChromiumTab)?.isElementFullscreen == true
            #else
            return false
            #endif
        }
        /// A full-screen window of WebKit's still on screen.
        func fullscreenWindowShowing() -> Bool {
            NSApp.windows.contains { $0.isVisible && $0 !== c.window && String(describing: Swift.type(of: $0)).contains("FullScreen") }
        }
        func windowName(_ v: NSView?) -> String {
            v?.window === c.window ? "the browser window" : v?.window.map { String(describing: Swift.type(of: $0)) } ?? "no window"
        }
        // AIRC_CBFOCUS_HID=1: the driver's plain HID presses (to the frontmost app) instead of PID-targeted ones.
        let hid = ProcessInfo.processInfo.environment["AIRC_CBFOCUS_HID"] == "1"
        func key(_ combo: String, _ done: @escaping (Bool, String) -> Void) {
            guard hid, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                return UIDriverClient.run(["--key", combo, "--pid", String(pid)], done)
            }
            UIDriverClient.run(["--key", combo], done)
        }
        func keys(_ combos: [String], _ done: @escaping (Bool, String) -> Void) {
            guard let k = combos.first else { return done(true, "") }
            key(k) { ok, out in ok ? keys(Array(combos.dropFirst()), done) : done(false, "\(k): \(out.prefix(120))") }
        }
        /// A real click at an element's centre (a CSS selector, in the top document; `dx/dy` from its top-left instead).
        func clickPage(_ tab: EngineTab?, _ selector: String, offset: (Double, Double)? = nil, _ done: @escaping (Bool, String) -> Void) {
            guard let tab else { return done(false, "no page") }
            let at = offset.map { "[r.left+\($0.0), r.top+\($0.1)]" } ?? "[r.left+r.width/2, r.top+r.height/2]"
            tab.evaluate("JSON.stringify((function(){var r=document.querySelector('\(selector)').getBoundingClientRect();return \(at);})())") { v in
                let xy = (v as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [Double] } ?? []
                let view = tab.view
                guard xy.count == 2, let window = view.window, let top = NSScreen.screens.first?.frame.maxY else { return done(false, "no point \(v ?? "nil")") }
                guard NSApp.isActive, window.isKeyWindow else { return done(false, "window not key") }
                let inView = NSPoint(x: xy[0], y: view.isFlipped ? xy[1] : view.bounds.height - xy[1])
                let screen = window.convertPoint(toScreen: view.convert(inView, to: nil))
                UIDriverClient.run(["--click", String(Double(screen.x)), String(Double(top - screen.y))], done)
            }
        }
        func postBurst(_ combos: [String]) -> Bool {
            let codes: [String: (UInt16, String, NSEvent.ModifierFlags)] = [
                "cmd+t": (17, "t", .command), "k": (40, "k", []), "space": (49, " ", []), "i": (34, "i", []),
            ]
            var events: [NSEvent] = []
            for k in combos {
                guard let (code, ch, mods) = codes[k] else { return false }
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods,
                                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: c.window.windowNumber,
                                                   context: nil, characters: ch, charactersIgnoringModifiers: ch, isARepeat: false,
                                                   keyCode: code) else { return false }
                    events.append(e)
                }
            }
            for e in events { NSApp.postEvent(e, atStart: false) }
            return true
        }

        // MARK: setup
        DiscardLog.install()
        step { [self] done in
            server = LocalPageServer(pages: ["/video": videoPage, "/frame": framePage,
                                             "/other": "<!doctype html><title>cbfocus other</title><p>other"])
            server?.start { p in port = p ?? 0; done() }
        }
        run { [self] in
            check(port != 0, "\(tag): the loopback fixture listens")
            app?.settings.values.suggestionsEnabled = false
            note("\(tag): layout \(UIDriverClient.layoutName), driver available \(UIDriverClient.available), cases \(picked.joined(separator: ","))")
            guard port != 0 else { return }
            home = c.currentSpaceID
            do {
                let base = "http://127.0.0.1:\(port)"
                video = try c.store.openTab(url: base + "/video", inSpace: home).id
                stealer = try c.store.openTab(url: base + "/video?steal=1", inSpace: home).id
                other = try c.store.openTab(url: base + "/other", inSpace: home).id
                if picked.contains("space") {
                    let s = try c.store.createSpace(name: "cbfocus far", icon: nil, theme: c.store.selectedSpace.theme,
                                                    profileID: c.store.profile(ofSpace: home).id, after: home)
                    far = s.id
                    farVideo = try c.store.openTab(url: base + "/video?far=1", inSpace: far).id
                }
                c.reloadAll(animated: false)
                c.show(video, focus: true)
            } catch { check(false, "\(tag): setup \(error)") }
        }
        step { [self] done in
            waitUntil({ page(video)?.isLoading == false && page(video)?.title == "cbfocus video" }, timeout: 20) { done() }
        }
        step { [self] done in
            guard UIDriverClient.available else {
                note("FAIL-ENV \(tag): real keys need AIRC_REAL_KEYS=1 and the UI driver")
                return done()
            }
            NSApp.activate(ignoringOtherApps: true)
            c.window.makeKeyAndOrderFront(nil)
            waitUntil({ NSApp.isActive && self.c.window.isKeyWindow }, timeout: 3) {
                realInput = NSApp.isActive && self.c.window.isKeyWindow && self.c.window.isOnActiveSpace
                if !realInput {
                    self.note("FAIL-ENV \(tag): the window isn't key on the active Space (active \(NSApp.isActive), key \(self.c.window.isKeyWindow))")
                }
                done()
            }
        }
        wait(1)

        // MARK: cases
        for name in all where picked.contains(name) && name != "tab" {
            var target = video          // the page under the bar
            var before = ""             // who had the keyboard before ⌘T
            var beforeActive: String?   // the page's focused element before ⌘T
            var attempts = 0, reclaims = 0
            var setupNote = ""
            var keysOK = true, keysOut = ""
            var skip = false
            var exitsBefore = 0

            // 1. The case's state.
            run { [self] in
                if c.commandBar != nil { c.closeCommandBar() }
                CommandBarView.pendingDelay = name == "held" ? 2.0 : 0.001
                target = name == "steal" ? stealer : video
                setupNote = ""
                skip = !realInput
            }
            step { [self] done in
                guard !skip else { return done() }
                switch name {
                case "steal", "tabswitch":
                    // tabswitch: from the other tab, ⌃PageDown/⌃PageUp is a real tab switch right before ⌘T.
                    c.show(name == "tabswitch" ? other : stealer, focus: true)
                    waitUntil({ page(target)?.isLoading == false }, timeout: 10) { done() }
                default:
                    if c.shownTabID != video { c.show(video, focus: true) }
                    waitUntil({ page(video)?.isLoading == false }, timeout: 10) { done() }
                }
            }
            wait(0.4)
            step { [self] done in
                guard !skip else { return done() }
                let t = page(target)
                func finish(_ ok: Bool, _ what: String) {
                    setupNote = what
                    if !ok { note("FAIL-ENV \(tag) \(name): setup \(what)"); skip = true }
                    done()
                }
                switch name {
                case "click", "steal", "held", "burst", "twice", "load":
                    clickPage(t, "#player") { ok, out in finish(ok, ok ? "clicked the video" : "click \(out.prefix(80))") }
                case "input":
                    clickPage(t, "#box") { ok, out in finish(ok, ok ? "clicked the page's box" : "click \(out.prefix(80))") }
                case "iframe":
                    clickPage(t, "#fr", offset: (60, 24)) { ok, out in finish(ok, ok ? "clicked the frame's box" : "click \(out.prefix(80))") }
                case "fullscreen":
                    clickPage(t, "#player") { ok, out in
                        guard ok else { return finish(false, "click \(out.prefix(80))") }
                        key("f") { ok, out in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                state(t) { s in finish(ok && s["fs"] as? Bool == true, "element full screen \(s["fs"] ?? "?") \(out.prefix(60))") }
                            }
                        }
                    }
                case "pip":
                    clickPage(t, "#player") { ok, out in
                        guard ok else { return finish(false, "click \(out.prefix(80))") }
                        key("i") { ok, _ in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                state(t) { s in
                                    let up = s["pip"] as? Bool == true
                                    finish(ok && up, "picture in picture \(up) \((s["keys"] as? [String])?.suffix(2) ?? [])")
                                }
                            }
                        }
                    }
                case "agent":
                    clickPage(t, "#player") { ok, _ in
                        AgentPaneController.show(self.c)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { finish(ok, "agent pane open \(AgentPaneController.pane(of: self.c)?.isShown == true)") }
                    }
                case "littlearc":
                    clickPage(t, "#player") { ok, _ in
                        little = self.app?.openLittleArc(url: URL(string: "http://127.0.0.1:\(port)/video?little=1"))
                        self.waitUntil({ little?.page?.isLoading == false && little?.window.isKeyWindow == true }, timeout: 10) {
                            finish(little != nil, "Little Airc open, key \(little?.window.isKeyWindow == true)")
                        }
                    }
                case "space":
                    clickPage(t, "#player") { ok, out in finish(ok, ok ? "clicked the video" : "click \(out.prefix(80))") }
                case "inactive":
                    clickPage(t, "#player") { ok, _ in
                        NSApp.deactivate()
                        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate(options: [])
                        self.waitUntil({ !NSApp.isActive }, timeout: 4) { finish(ok && !NSApp.isActive, "app inactive \(!NSApp.isActive)") }
                    }
                case "tabswitch":
                    finish(true, "on the other tab")
                default:
                    finish(true, "")
                }
            }
            wait(0.6)
            // 2. Reset the page's log, note who has the keyboard; then the case's own lead-in and ⌘T, “k”, Space, “i”.
            step { [self] done in
                guard !skip else { return done() }
                let clear = "window.keysSeen && (window.keysSeen.length = 0); true"
                js(page(video), clear) { js(page(stealer), clear) { js(page(farVideo), clear) {
                    js(little?.page, clear) {
                        state(page(target)) { s in
                            beforeActive = s["active"] as? String
                            before = responder(self.c.window)
                            attempts = CommandBarView.focusAttempts.count
                            reclaims = CommandBarView.reclaims.count
                            exitsBefore = CommandBarView.fullscreenExits.count
                            done()
                        }
                    }
                } } }
            }
            step { [self] done in
                guard !skip else { return done() }
                func then(_ ok: Bool, _ out: String) {
                    keysOK = ok; keysOut = out
                    DispatchQueue.main.asyncAfter(deadline: .now() + (name == "held" ? 2.3 : 0.5)) { done() }
                }
                switch name {
                case "load":
                    // ⌘T while the page loads again (a navigation: a new document, maybe a new renderer).
                    page(target)?.load(URL(string: "http://127.0.0.1:\(port)/video?load=\(Int.random(in: 1...99999))")!)
                    keys(["cmd+t"] + typedKeys, then)
                case "tabswitch":
                    // A real tab switch, then ⌘T at once: the page under the bar is the one switched to.
                    keys(["ctrl+pageup"]) { ok, out in
                        guard ok else { return then(false, out) }
                        if let id = self.c.shownTabID, id != other { target = id }
                        keys(["cmd+t"] + typedKeys, then)
                    }
                case "space":
                    keys(["cmd+opt+right"]) { ok, out in
                        guard ok else { return then(false, out) }
                        keys(["cmd+opt+left", "cmd+t"] + typedKeys, then)
                    }
                case "twice":
                    keys(["cmd+t", "cmd+t", "cmd+t"] + typedKeys, then)
                case "burst":
                    let posted = postBurst(["cmd+t"] + typedKeys)
                    then(posted, posted ? "posted" : "not posted")
                case "littlearc":
                    c.window.makeKeyAndOrderFront(nil)
                    keys(["cmd+t"] + typedKeys, then)
                case "inactive":
                    NSApp.activate(ignoringOtherApps: true)
                    c.window.makeKeyAndOrderFront(nil)
                    // The driver refuses a background target: ⌘T the moment the app is in front.
                    waitUntil({ NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }, timeout: 3) {
                        keys(["cmd+t"] + typedKeys, then)
                    }
                default:
                    keys(["cmd+t"] + typedKeys, then)
                }
            }
            // 3. What the bar, the page and the keyboard show.
            step { [self] done in
                guard !skip else { return done() }
                let bar = c.commandBar
                let typed = bar?.query ?? "(closed)"
                let field = bar?.fieldText ?? ""
                let who = responder(c.window)
                let tries = CommandBarView.focusAttempts.dropFirst(attempts)
                let took = CommandBarView.reclaims.dropFirst(reclaims)
                state(page(target)) { s in
                    state(little?.page) { ls in
                        let seen = (s["keys"] as? [String] ?? []) + (ls["keys"] as? [String] ?? []).map { "little:" + $0 }
                        // The shortcut's own presses (⌘T's ⌘, ⌥⌘→) reach the page before the bar opens: not typing.
                        let modifierOnly: Set<String> = ["Meta", "Alt", "Control", "Shift"]
                        let pageKeys = seen.filter { k in !k.contains("mod:") && !modifierOnly.contains(String(k.split(separator: ":").last ?? "").split(separator: "@").first.map(String.init) ?? "") }
                        let cause = tries.map { "\($0.refused ? "refused" : "ALLOWED") \($0.pending ? "(pending)" : "(editor)") \($0.caller)" }
                        let label = "\(tag) \(name)\(name == "burst" ? " (posted)" : "")"
                        self.note("\(label): setup “\(setupNote)”, keyboard before ⌘T \(before), page focus \(beforeActive ?? "-"); after typing: "
                                  + "keyboard \(who), typed “\(typed)” field “\(field)”, page keys \(pageKeys) (all \(seen)), paused \(s["paused"] ?? "?") pip \(s["pip"] ?? "?"); "
                                  + "attempts on the bar's keyboard \(cause.isEmpty ? "none" : cause.joined(separator: " | ")); reclaimed from \(Array(took))")
                        if !keysOK { self.check(false, "\(label): the driver delivered every key (\(keysOut))") }
                        self.check(pageKeys.isEmpty, "\(label): the page saw no key while the bar was open (\(pageKeys))")
                        self.check(typed == expected, "\(label): the field holds exactly “\(expected)”, the first key included (typed “\(typed)”, field “\(field)”)")
                        self.check(who == "bar", "\(label): the bar's field has the keyboard (\(who))")
                        results[name] = pageKeys.isEmpty && typed == expected ? "ok" : "REPRO pageKeys=\(pageKeys.count) typed=“\(typed)”"
                        if name == "fullscreen" {
                            // fskeys: ⌘T left element full screen (both engines), within the exit budget, the page back here.
                            let exits = Array(CommandBarView.fullscreenExits.dropFirst(exitsBefore))
                            let ms = exits.first.flatMap(Double.init)
                            let v = page(target)?.view
                            self.check(exits.count == 1 && ms.map { $0 <= exitBudget } == true,
                                       "\(label): ⌘T left element full screen within \(Int(exitBudget)) ms (exits \(exits) ms)")
                            self.check(!inFullscreen(page(target)) && s["fs"] as? Bool != true && v?.window === self.c.window && !fullscreenWindowShowing()
                                       && NSApp.keyWindow === self.c.window,
                                       "\(label): after ⌘T the page is out of full screen in the browser window, which is key (engine full screen "
                                       + "\(inFullscreen(page(target))), fullscreenElement \(s["fs"] ?? "?"), page in \(windowName(v)), full-screen window "
                                       + "\(fullscreenWindowShowing()), key window \(NSApp.keyWindow.map { String(describing: Swift.type(of: $0)) } ?? "nil"))")
                        }
                        done()
                    }
                }
            }
            // Full screen: did ⌘T ask the page to leave it, and does the engine? (diagnostic notes)
            step { [self] done in
                guard !skip, name == "fullscreen" else { return done() }
                let t = page(target)
                func fs() -> String {
                    let w = t as? WebKitTab
                    return (w.map { "fullscreenState \($0.webView.fullscreenState.rawValue), exit requests \($0.elementFullscreenExitRequests)" }
                        ?? "Chromium full screen \(inFullscreen(t))") + ", page view in \(windowName(t?.view))"
                }
                note("\(tag) fullscreen: event discards so far \(DiscardLog.entries)")
                note("\(tag) fullscreen: after typing: \(fs()); keys held and replayed per exit \(CommandBarView.heldKeyCounts), ⌘T exits \(CommandBarView.fullscreenExits) ms, "
                     + "presentation closes \(WebKitTab.presentationCloses)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.note("\(tag) fullscreen: +1 s: \(fs())"); done() }
            }
            // 4. Esc: the keyboard goes back where it was.
            step { [self] done in
                guard !skip else { return done() }
                if c.commandBar == nil { return done() }
                // Where the window's keyboard goes after Esc, sampled every 10 ms on the main thread, and where things stand.
                var changes: [String] = []
                let start = CACurrentMediaTime()
                var last = responder(c.window)
                let poll = Timer(timeInterval: 0.01, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        let now = responder(self.c.window)
                        if now != last { changes.append(String(format: "+%.0f ms ", (CACurrentMediaTime() - start) * 1000) + now); last = now }
                    }
                }
                RunLoop.main.add(poll, forMode: .common)
                func where_() -> String {
                    let v = page(target)?.view
                    let key = NSApp.keyWindow.map { String(describing: Swift.type(of: $0)) } ?? "nil"
                    return "keyboard \(responder(self.c.window)), key window \(key), page view in "
                        + (v?.window === self.c.window ? "the browser window" : v?.window.map { String(describing: Swift.type(of: $0)) } ?? "no window")
                        + ", hidden \(v?.isHiddenOrHasHiddenAncestor ?? false)"
                }
                key("esc") { _, _ in
                    let at100 = { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { changes.append("@100 ms " + where_()) } }
                    at100()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        poll.invalidate()
                        self.note("\(tag) \(name): after Esc: \(where_()); keyboard changes [\(changes.joined(separator: " | "))]")
                        done()
                    }
                }
            }
            step { [self] done in
                guard !skip else { return done() }
                let who = responder(c.window)
                state(page(target)) { s in
                    let label = "\(tag) \(name)"
                    if self.c.commandBar != nil {
                        self.check(false, "\(label): Esc closed the bar")
                    } else if ["load", "tabswitch", "fullscreen"].contains(name) {
                        if name == "fullscreen" {
                            let v = page(target)?.view
                            self.check(v?.window === self.c.window && s["fs"] as? Bool != true,
                                       "\(label): the page left full screen, back in the browser window (in \(v?.window.map { String(describing: Swift.type(of: $0)) } ?? "no window"), fullscreenElement \(s["fs"] ?? "?"))")
                        }
                        // A new document, another tab, a page out of full screen: the page under the bar has the keyboard.
                        let want = target == stealer ? "page(steal)" : target == other ? "page(other)" : "page(video)"
                        self.check(who == want, "\(label): after Esc the page under the bar has the keyboard (\(who); want \(want))")
                    } else if name == "agent" || name == "littlearc" || name == "inactive" || name == "space" {
                        self.note("\(label): after Esc the keyboard is \(who) (before ⌘T \(before))")
                        self.check(who == before || before.hasPrefix("page") && who.hasPrefix("page"),
                                   "\(label): after Esc the keyboard is back where it was (\(who); before \(before))")
                    } else {
                        let active = s["active"] as? String
                        self.check(who == before && active == beforeActive,
                                   "\(label): after Esc the keyboard is back where it was (\(who), page focus \(active ?? "-"); before \(before), \(beforeActive ?? "-"))")
                    }
                    done()
                }
            }
            // WebKit still in full screen after Esc: does leaving it work at all from here? (diagnostic notes)
            step { [self] done in
                guard !skip, name == "fullscreen", let w = page(target) as? WebKitTab, w.webView.fullscreenState != .notInFullscreen else { return done() }
                let before = w.elementFullscreenExitRequests
                w.leaveElementFullscreen()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.note("\(tag) fullscreen: the check's own leaveElementFullscreen: requests \(before) → \(w.elementFullscreenExitRequests), "
                              + "fullscreenState now \(w.webView.fullscreenState.rawValue)")
                    // A plain exitFullscreen() of its own, past the tab's presentation-exit chain.
                    w.webView.evaluateJavaScript("document.fullscreenElement ? (document.exitFullscreen(), 'asked') : 'none'") { v, e in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            self.note("\(tag) fullscreen: direct exitFullscreen() \(v ?? e.map { "\($0)" } ?? "-"): fullscreenState now \(w.webView.fullscreenState.rawValue), "
                                      + "page view in " + (w.view.window === self.c.window ? "the browser window" : w.view.window.map { String(describing: Swift.type(of: $0)) } ?? "no window"))
                            done()
                        }
                    }
                }
            }
            // 5. Back to a playing inline video, one window, this Space.
            step { [self] done in
                if c.commandBar != nil { c.closeCommandBar() }
                CommandBarView.pendingDelay = 0.001
                if name == "agent" { AgentPaneController.pane(of: c)?.close() }
                if name == "littlearc", let l = little { l.window.close(); little = nil }
                if c.currentSpaceID != home { c.switchSpace(offset: -1) }
                if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
                c.window.makeKeyAndOrderFront(nil)
                let code = "(document.pictureInPictureElement ? document.exitPictureInPicture() : Promise.resolve()).catch(()=>{});"
                    + "(document.fullscreenElement ? document.exitFullscreen() : Promise.resolve()).catch(()=>{});"
                    + "var v=document.getElementById('player'); v && v.play().catch(()=>{}); true"
                js(page(target), code) { DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { done() } }
            }
        }
        // MARK: fskeys exit cases: leave element full screen another way; timed, and never a half state.
        for name in exitCases where picked.contains(name) {
            let label = "\(tag) \(name)"
            var skip = false
            var entered = ""
            var sent = 0.0
            var leftMS: Double?
            var trail: [String] = []
            run { [self] in
                if c.commandBar != nil { c.closeCommandBar() }
                skip = !realInput
                entered = ""; leftMS = nil; trail = []
                if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
                c.window.makeKeyAndOrderFront(nil)
            }
            // 1. Element full screen: a real click on the video and “f” (the page's own requestFullscreen); fsrace enters
            // it in the same turn its tab is shown (the tab's presentation close is still running).
            step { [self] done in
                guard !skip else { return done() }
                if name == "fsrace" {
                    c.show(other, focus: true)
                    return waitUntil({ self.c.shownTabID == other }, timeout: 3) { done() }
                }
                if c.shownTabID != video { c.show(video, focus: true) }
                waitUntil({ page(video)?.isLoading == false && !inFullscreen(page(video)) }, timeout: 5) { done() }
            }
            wait(0.5)
            step { [self] done in
                guard !skip else { return done() }
                func entering(_ how: String) {
                    waitUntil({
                        let t = page(video)
                        return (t as? WebKitTab).map { $0.webView.fullscreenState == .inFullscreen } ?? inFullscreen(t)
                    }, timeout: 4) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            state(page(video)) { s in
                                if let w = page(video) as? WebKitTab, name == "fsrace" { SystemPictureInPicture.setOpenForTesting(w, false) }
                                entered = inFullscreen(page(video)) && s["fs"] as? Bool == true ? how : ""
                                if entered.isEmpty { self.note("FAIL-ENV \(label): setup: no element full screen (\(how), fullscreenElement \(s["fs"] ?? "?"))"); skip = true }
                                done()
                            }
                        }
                    }
                }
                if name == "fsrace" { c.show(video, focus: true) }
                // fsrace on WebKit: a presentation close is still waiting (here for a player window that is still
                // closing) when the page enters full screen; the player window then goes. Before fskeys that close went
                // on waiting for the full screen too, so every later leave of the tab joined it and never ran.
                let racing = name == "fsrace" ? page(video) as? WebKitTab : nil
                DispatchQueue.main.asyncAfter(deadline: .now() + (name == "fsrace" ? 0.3 : 0)) {
                    if let w = racing {
                        SystemPictureInPicture.setOpenForTesting(w, true)
                        w.closeMediaPresentations()
                    }
                    clickPage(page(video), "#player") { ok, out in
                        guard ok else { self.note("FAIL-ENV \(label): setup click \(out.prefix(80))"); skip = true; return done() }
                        key("f") { ok, out in
                            guard ok else { self.note("FAIL-ENV \(label): setup key f \(out.prefix(80))"); skip = true; return done() }
                            entering(racing == nil ? "real click and f" : "real click and f, a presentation close waiting")
                        }
                    }
                }
            }
            // 2. Leave it, and time it: from the input to the page out of full screen, back in the browser window (a tab
            // switch: out of WebKit's window), no full-screen window left.
            step { [self] done in
                guard !skip else { return done() }
                let t = page(video)
                let away = name == "fstab" || name == "fsrace"
                func out() -> Bool {
                    guard !inFullscreen(t), !fullscreenWindowShowing() else { return false }
                    return away ? t?.view.window == nil || t?.view.window === c.window : t?.view.window === c.window
                }
                var last = ""
                func watch() {
                    let start = sent
                    let timer = Timer(timeInterval: 0.01, repeats: true) { timer in
                        MainActor.assumeIsolated {
                            let now = "engine \(inFullscreen(t)) window \(windowName(t?.view)) fs-window \(fullscreenWindowShowing())"
                            if now != last { trail.append(String(format: "+%.0f ms ", (CACurrentMediaTime() - start) * 1000) + now); last = now }
                            if out() { leftMS = (CACurrentMediaTime() - start) * 1000; timer.invalidate(); return done() }
                            if CACurrentMediaTime() - start > 5 { timer.invalidate(); done() }
                        }
                    }
                    RunLoop.main.add(timer, forMode: .common)
                }
                switch name {
                case "fsesc":
                    sent = CACurrentMediaTime()
                    key("esc") { ok, o in if !ok { self.check(false, "\(label): the driver delivered Esc (\(o.prefix(80)))") } }
                    watch()
                case "fsbutton":
                    // The page's own button (a real click where it is in full screen); the time runs from the click.
                    sent = CACurrentMediaTime()
                    clickPage(t, "#leave") { ok, o in if !ok { self.check(false, "\(label): the real click on the page's Exit button (\(o.prefix(80)))") } }
                    watch()
                default:   // fstab, fsrace: a tab switch, as the sidebar or ⌃Tab does
                    sent = CACurrentMediaTime()
                    c.show(other, focus: true)
                    watch()
                }
            }
            // 3. Asserts: left in time, not a half state, the page's document agrees; then back to the video tab.
            step { [self] done in
                guard !skip else { return done() }
                let t = page(video)
                state(t) { s in
                    let closes = WebKitTab.presentationCloses.suffix(3)
                    self.note("\(label): Exit clicks seen by the page \(s["leaveClicks"] ?? "?")")
                    self.note("\(label): entered \(entered); left in \(leftMS.map { String(format: "%.0f ms", $0) } ?? "never (5 s)"); "
                              + "trail [\(trail.joined(separator: " | "))]; presentation closes \(Array(closes)); key window "
                              + "\(NSApp.keyWindow.map { String(describing: Swift.type(of: $0)) } ?? "nil")"
                              + ((t as? WebKitTab).map { ", fullscreenState \($0.webView.fullscreenState.rawValue), exit requests \($0.elementFullscreenExitRequests)" } ?? ""))
                    self.check(leftMS.map { $0 <= exitBudget } == true,
                               "\(label): left element full screen within \(Int(exitBudget)) ms (\(leftMS.map { String(format: "%.0f ms", $0) } ?? "never"))")
                    self.check(!inFullscreen(t) && s["fs"] as? Bool != true && !fullscreenWindowShowing() && NSApp.keyWindow === self.c.window,
                               "\(label): no half state: the engine and the page are out of full screen, no full-screen window, the browser window key "
                               + "(engine \(inFullscreen(t)), fullscreenElement \(s["fs"] ?? "?"), full-screen window \(fullscreenWindowShowing()), page in \(windowName(t?.view)))")
                    results[name] = leftMS.map { $0 <= exitBudget } == true ? "ok" : "REPRO left \(leftMS.map { String(format: "%.0f ms", $0) } ?? "never")"
                    done()
                }
            }
            step { [self] done in
                guard !skip else { return done() }
                // The page comes back to the browser window, playing, out of full screen (a later exit isn't stuck).
                if c.shownTabID != video { c.show(video, focus: true) }
                waitUntil({ page(video)?.view.window === self.c.window }, timeout: 3) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        let t = page(video)
                        state(t) { s in
                            self.check(t?.view.window === self.c.window && !inFullscreen(t) && s["fs"] as? Bool != true && s["paused"] as? Bool == false,
                                       "\(label): back on its tab the video plays inline in the browser window (page in \(windowName(t?.view)), "
                                       + "fullscreenElement \(s["fs"] ?? "?"), paused \(s["paused"] ?? "?"))")
                            done()
                        }
                    }
                }
            }
            run { [self] in
                // Whatever happened, the next case starts windowed, with no stand-in player window.
                if let w = page(video) as? WebKitTab { SystemPictureInPicture.setOpenForTesting(w, false) }
                js(page(video), "(document.fullscreenElement ? document.exitFullscreen() : Promise.resolve()).catch(()=>{}); var v=document.getElementById('player'); v && v.play().catch(()=>{}); true") {}
            }
            wait(1.0)
        }
        // MARK: Tab (owner, 2026-11-24): Tab always switches Search ↔ Ask, the text kept; ⇧Tab too; the hint shows.
        if picked.contains("tab") {
            var log: [String] = []
            func expectMode(_ what: String, ask: Bool, typed: String) {
                let b = c.commandBar
                let t = b?.modeToggleForTesting
                let ok = b != nil && b?.askMode == ask && t?.ask == ask && b?.query == typed && t?.isHidden == false && t?.showsTabHint == true
                    && b?.hasKeyboard == true
                check(ok, "\(tag) tab: \(what): \(ask ? "Ask" : "Search"), “\(typed)” kept, the Tab hint shown, the field keeps the keyboard "
                      + "(ask \(b?.askMode ?? false), typed “\(b?.query ?? "-")”, switch shown \(t?.isHidden == false), hint \(t?.showsTabHint ?? false), keyboard \(responder(c.window)))")
            }
            func press(_ combos: [String], _ then: @escaping () -> Void) {
                step { done in
                    guard realInput else { return done() }
                    keys(combos) { ok, out in
                        if !ok { self.check(false, "\(tag) tab: the driver delivered \(combos) (\(out))") }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { done() }
                    }
                }
                run { if realInput { then() } }
            }
            run { [self] in
                if c.commandBar != nil { c.closeCommandBar() }
                if c.shownTabID != video { c.show(video, focus: true) }
            }
            wait(0.5)
            step { [self] done in
                guard realInput else { return done() }
                clickPage(page(video), "#player") { _, _ in
                    js(page(video), "window.keysSeen && (window.keysSeen.length = 0); true") { done() }
                }
            }
            press(["cmd+t", "k", "i", "t"]) { [self] in
                let t = c.commandBar?.modeToggleForTesting
                log.append("hint after typing \(t?.showsTabHint ?? false)")
                expectMode("typed “kit”", ask: false, typed: "kit")
            }
            press(["tab"]) { expectMode("Tab", ask: true, typed: "kit") }
            press(["tab"]) { expectMode("Tab again", ask: false, typed: "kit") }
            press(["shift+tab"]) { expectMode("⇧Tab", ask: true, typed: "kit") }
            press(["shift+tab"]) { expectMode("⇧Tab again", ask: false, typed: "kit") }
            press(["down", "tab"]) { expectMode("a row picked (↓), then Tab", ask: true, typed: "kit") }
            press(["esc", "esc"]) { [self] in check(c.commandBar == nil, "\(tag) tab: Esc leaves Ask, Esc again closes the bar") }
            press(["cmd+t", "tab"]) { expectMode("Tab on the empty field", ask: true, typed: "") }
            press(["tab"]) { expectMode("Tab again on the empty field", ask: false, typed: "") }
            step { [self] done in
                guard realInput else { return done() }
                state(page(video)) { s in
                    let pageKeys = (s["keys"] as? [String] ?? []).filter { !$0.contains("mod:") && !["Meta", "Alt", "Control", "Shift"].contains(String($0.split(separator: ":").last ?? "").split(separator: "@").first.map(String.init) ?? "") }
                    self.note("\(tag) tab: \(log.joined(separator: ", ")); page keys \(s["keys"] ?? "-")")
                    self.check(pageKeys.isEmpty, "\(tag) tab: the page saw no key, Tab included (\(pageKeys))")
                    results["tab"] = pageKeys.isEmpty ? "ok" : "page keys \(pageKeys)"
                    if self.c.commandBar != nil { self.c.closeCommandBar() }
                    done()
                }
            }
        }
        run { [self] in
            CommandBarView.pendingDelay = 0.001
            server?.stop()
            let summary = (all + exitCases).filter { picked.contains($0) }.map { "\($0) \(results[$0] ?? "skipped")" }
            note("\(tag): summary \(summary.joined(separator: "; "))")
            // zero-guard: cases that never ran (no real input) are a failure, never a green.
            check(!results.isEmpty, "\(tag): at least one case ran with real keys (\(results.count)/\(picked.count))")
        }
    }
}
#endif
