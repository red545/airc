// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// `--script cbfirstkeys` (cmdfast): no key is lost or reordered when the Command Bar opens. Its field starts its
/// editing session a run-loop turn after ⌘T (CommandBarView.focus(with:)), at every opening, the first after launch
/// included. Real presses from the UI driver
/// (AIRC_REAL_KEYS=1, a dedicated session, the window key), PID-targeted to this foreground app, each the moment the
/// last one was delivered (the driver posts one combo per call; it can't post a sequence in one):
///   abc     ⌘T a b c Return: exactly one search for “abc” (a loopback stand-in for every engine);
///   paste   ⌘T ⌘V: the field holds exactly the pasteboard's text (unique per repetition);
///   esc     ⌘T Esc: the bar closes;
///   layout  ⌘T “:/” typed layout-aware (the build Mac's Austrian layout: Shift+. and Shift+7): the field is “:/”.
/// Each case runs AIRC_CBFIRSTKEYS_REPS times (default 20) in two timings: natural (the session starts ~1 ms after
/// the opening's frame), and held (it waits 300 ms, so every key after ⌘T arrives while it is pending: the counters
/// show the key, not the timer, started it, with the session held 2 s: the driver delivers a key every ~0.3 s). Then a
/// burst: ⌘T a b c Return and ⌘T Esc posted to the app's queue all at once (posted events, labelled; not the driver),
/// so the keys race the natural ~1 ms timer. The first repetition is the process's first opening. IME composition isn't covered (no input method is enabled on
/// the build Mac, and the driver doesn't compose).
extension SnapshotRunner {
    func commandBarFirstKeysScenario() {
        let engineName = app?.engine is WebKitEngine ? "WebKit" : "Chromium"
        let tag = "cbfirstkeys (\(engineName))"
        let reps = ProcessInfo.processInfo.environment["AIRC_CBFIRSTKEYS_REPS"].flatMap(Int.init) ?? 20
        let pid = ProcessInfo.processInfo.processIdentifier
        let lock = NSLock()
        var requests: [String] = []
        var server: LocalPageServer?
        var port: UInt16 = 0
        var realInput = false
        var summary: [String: (pass: Int, fail: Int, byKey: Int, byTimer: Int)] = [:]
        var gaps: [Double] = []

        step { [self] done in
            server = LocalPageServer(pages: [:])
            server?.requestHandler = { req in
                lock.withLock { requests.append(req.target) }
                return .init(body: "<!doctype html><title>cbfirstkeys results</title><p>results</p>")
            }
            server?.start { p in
                port = p ?? 0
                SearchEngineStandIn.origin = "http://127.0.0.1:\(port)"
                done()
            }
        }
        run { [self] in
            check(port != 0, "\(tag): the loopback stand-in engine listens")
            app?.settings.values.suggestionsEnabled = false
            note("\(tag): layout \(UIDriverClient.layoutName), driver available \(UIDriverClient.available)")
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
                    self.note("FAIL-ENV \(tag): the window isn't key on the active Space (active \(NSApp.isActive), key \(self.c.window.isKeyWindow), "
                              + "front \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-"))")
                }
                done()
            }
        }
        wait(1)

        /// The keys, one driver call each, the next as soon as the last is delivered; the time between deliveries.
        func press(_ combos: [String], _ done: @escaping (Bool, String) -> Void) {
            var last = CACurrentMediaTime()
            func next(_ rest: ArraySlice<String>) {
                guard let k = rest.first else { return done(true, "") }
                UIDriverClient.run(["--key", k, "--pid", String(pid)]) { ok, out in
                    let now = CACurrentMediaTime()
                    if k != combos.first { gaps.append((now - last) * 1000) }
                    last = now
                    guard ok else { return done(false, "\(k): \(out.prefix(80))") }
                    next(rest.dropFirst())
                }
            }
            next(combos[...])
        }
        /// Key down and up for each combo, all queued before the first is handled.
        func postBurst(_ combos: [String]) -> Bool {
            let codes: [String: (UInt16, String, NSEvent.ModifierFlags)] = [
                "cmd+t": (17, "t", .command), "a": (0, "a", []), "b": (11, "b", []), "c": (8, "c", []),
                "return": (36, "\r", []), "esc": (53, "\u{1b}", []),
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
        func searched(_ q: String, since: Int) -> Int {
            lock.withLock { requests.dropFirst(since).filter { $0.range(of: "[?&]q=\(q)(&|$)", options: .regularExpression) != nil }.count }
        }

        let cases: [(name: String, keys: () -> [String]?)] = [
            ("abc", { ["cmd+t", "a", "b", "c", "return"] }),
            ("paste", { ["cmd+t", "cmd+v"] }),
            ("esc", { ["cmd+t", "esc"] }),
            ("layout", { UIDriverClient.keys(typing: ":/").map { ["cmd+t"] + $0 } }),
        ]
        // AIRC_CBFIRSTKEYS_TIMING=natural|held runs one timing per launch (the runner's 330 s bound).
        let timings = ProcessInfo.processInfo.environment["AIRC_CBFIRSTKEYS_TIMING"].map { [$0] } ?? ["natural", "held", "burst"]
        for timing in timings {
            // burst: the same keys with no gap at all, posted to the app's queue in one go (the driver can't).
            for (name, keys) in cases where timing != "burst" || name == "abc" || name == "esc" {
                for n in 0..<reps {
                    var since = 0
                    var stats = CommandBarView.sessionStats
                    var pasted = ""
                    // No bar open; the page has the keyboard.
                    run { [self] in
                        if c.commandBar != nil { c.closeCommandBar() }
                    }
                    wait(0.25)
                    step { [self] done in
                        guard realInput else { return done() }
                        CommandBarView.pendingDelay = timing == "held" ? 2.0 : 0.001
                        since = lock.withLock { requests.count }
                        stats = CommandBarView.sessionStats
                        pasted = "pasted\(n)\(timing.prefix(1))"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(pasted, forType: .string)
                        guard let combos = keys() else {
                            check(false, "\(tag) \(name): “:/” can be typed on layout \(UIDriverClient.layoutName)")
                            return done()
                        }
                        guard NSApp.isActive, c.window.isKeyWindow else {
                            note("FAIL-ENV \(tag) \(timing) \(name) #\(n): the window lost key (front \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-"))")
                            return done()
                        }
                        if timing == "burst" {
                            let posted = postBurst(combos)
                            if !posted { self.check(false, "\(tag) burst \(name) #\(n): every key posted (\(combos))") }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { done() }
                            return
                        }
                        press(combos) { ok, out in
                            if !ok { self.check(false, "\(tag) \(timing) \(name) #\(n): driver delivered every key (\(out))") }
                            // Past the held window and the bar's own work.
                            DispatchQueue.main.asyncAfter(deadline: .now() + (timing == "held" ? 0.45 : 0.25)) { done() }
                        }
                    }
                    step { [self] done in
                        guard realInput else { return done() }
                        func finish(_ ok: Bool, _ what: String) {
                            let after = CommandBarView.sessionStats
                            let byKey = after.startedByKey - stats.startedByKey, byTimer = after.startedByTimer - stats.startedByTimer
                            // Held: the key must have found the session pending (else the case proves nothing).
                            // Held Esc: the app's key monitor closes the bar before any view gets the key (handleSuggestionKey), so
                            // the bar must close with the session still pending (neither the key nor the timer started it).
                            let pendingHit = timing != "held" || (name == "esc" ? byKey == 0 && byTimer == 0 : byKey == 1)
                            let key = "\(timing) \(name)"
                            var s = summary[key] ?? (0, 0, 0, 0)
                            if ok && pendingHit { s.pass += 1 } else { s.fail += 1 }
                            s.byKey += byKey; s.byTimer += byTimer
                            summary[key] = s
                            if !ok || !pendingHit {
                                let log = (self.c.commandBar ?? self.c.spareCommandBar)?.keyLog.suffix(8).joined(separator: ",") ?? "-"
                                self.check(false, "\(tag) \(key) #\(n): \(what); session started by key \(byKey), timer \(byTimer); keys [\(log)]")
                            }
                            if self.c.commandBar != nil { self.c.closeCommandBar() }
                            done()
                        }
                        let bar = c.commandBar
                        let field = bar?.fieldText
                        switch name {
                        case "abc":
                            let count = { searched("abc", since: since) }
                            waitUntil({ count() >= 1 }, timeout: 5) {
                                let others = lock.withLock { requests.dropFirst(since).filter { $0.contains("q=") && $0.range(of: "[?&]q=abc(&|$)", options: .regularExpression) == nil } }
                                let open = self.c.commandBar
                                finish(count() == 1 && others.isEmpty && open == nil,
                                       "Return searched “abc” \(count())×, other searches \(others.prefix(2)), bar " + (open == nil ? "closed" : "open “\(open?.fieldText ?? "")”"))
                            }
                        case "paste":
                            finish(field == pasted, "field “\(field ?? "-")” (pasteboard “\(pasted)”)")
                        case "esc":
                            finish(bar == nil, bar == nil ? "the bar closed" : "the bar is still open (“\(field ?? "")”)")
                        default:
                            finish(field == ":/", "field “\(field ?? "-")”")
                        }
                    }
                }
                run { [self] in
                    guard realInput, let s = summary["\(timing) \(name)"] else { return }
                    check(s.fail == 0 && s.pass == reps,
                          "\(tag) \(timing) \(name): \(s.pass)/\(reps) exact (session started by the key \(s.byKey)×, by the timer \(s.byTimer)×)")
                }
            }
        }
        run { [self] in
            CommandBarView.pendingDelay = 0.001
            SearchEngineStandIn.origin = nil
            server?.stop()
            let g = gaps.sorted()
            if !g.isEmpty {
                note(String(format: "\(tag): time between real key deliveries median %.1f ms, min %.1f ms (n=%d)", g[g.count / 2], g[0], g.count))
            }
        }
    }
}
#endif
