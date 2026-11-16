// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// `--script hardreload` (both engines): ⇧⌘R reloads the shown page bypassing the cache (Chrome's Reload Ignoring
/// Cache, Arc's Force Refresh the Page), ⌘R is a normal reload. A loopback fixture serves a page and a script, both
/// `Cache-Control: max-age=3600`, and records every request with its headers. Real keys from the UI driver
/// (AIRC_REAL_KEYS=1, a dedicated session, the app in front), PID-targeted; each result says which input it used.
///   main     the page has the keyboard: ⌘R fetches the page (the script may come from the cache); ⇧⌘R fetches the page
///            AND the script again, both with `Cache-Control: no-cache` (or Pragma: no-cache);
///   sidebar  the window has the keyboard (no page focus): ⇧⌘R still hard-reloads the shown page;
///   little   Little Airc in front: ⇧⌘R hard-reloads its page (its own key table), ⌘R reloads it.
/// The View menu has Reload Ignoring Cache on ⇧⌘R, and the Command Bar finds it as "hard reload".
extension SnapshotRunner {
    func hardReloadScenario() {
        let engineName = app?.engine is WebKitEngine ? "WebKit" : "Chromium"
        let tag = "hardreload (\(engineName))"
        let pid = ProcessInfo.processInfo.processIdentifier
        let lock = NSLock()
        var log: [(path: String, headers: [String: String])] = []
        var server: LocalPageServer?
        var port: UInt16 = 0
        var realInput = false
        var little: LittleArcController?

        step { [self] done in
            server = LocalPageServer(pages: [:])
            server?.requestHandler = { req in
                lock.withLock { log.append((req.path, req.headers)) }
                let cache = ["Cache-Control": "max-age=3600"]
                switch req.path {
                case "/asset.js":
                    return .init(headers: cache.merging(["Content-Type": "text/javascript"]) { $1 },
                                 body: "document.documentElement.dataset.asset = 'loaded';")
                case "/favicon.ico": return .init(status: "404 Not Found", body: "")
                default:
                    return .init(headers: cache, body: "<!doctype html><title>hardreload fixture</title><p>fixture</p><input id=f>"
                                 + "<script src=\"/asset.js\"></script>")
                }
            }
            server?.start { p in port = p ?? 0; done() }
        }
        run { [self] in check(port != 0, "\(tag): the fixture server listens") }

        // Menu and Command Bar entries.
        run { [self] in
            let item = NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu?.items.first { $0.title == "Reload Ignoring Cache" }
            let mask = item?.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
            check((item?.keyEquivalent == "R" && mask == .command) || (item?.keyEquivalent == "r" && mask == [.command, .shift]),
                  "\(tag): View › Reload Ignoring Cache is on ⇧⌘R (\(item.map { "\($0.keyEquivalent) \($0.keyEquivalentModifierMask.rawValue)" } ?? "missing"))")
            let aliases = ParityCommandCatalog.aliases["Reload Ignoring Cache"] ?? []
            check(aliases.contains("hard reload"), "\(tag): the Command Bar finds Reload Ignoring Cache as “hard reload” (\(aliases))")
        }

        func count(_ path: String, since: Int) -> Int { lock.withLock { log.dropFirst(since).filter { $0.path == path || (path == "/" && ["/main", "/little", "/peek"].contains($0.path)) }.count } }
        func bypassed(_ path: String, since: Int) -> (Int, String) {
            lock.withLock {
                let hits = log.dropFirst(since).filter { $0.path == path || (path == "/" && ["/main", "/little", "/peek"].contains($0.path)) }
                let n = hits.filter { ($0.headers["cache-control"] ?? "").contains("no-cache") || ($0.headers["pragma"] ?? "").contains("no-cache") }.count
                let h = hits.map { "cache-control=\($0.headers["cache-control"] ?? "-") pragma=\($0.headers["pragma"] ?? "-")" }.joined(separator: "; ")
                return (n, h)
            }
        }
        var mark = 0
        func key(_ combo: String, _ what: String, targeted: Bool = true) {
            step { [self] done in
                guard realInput else { return done() }
                mark = lock.withLock { log.count }
                UIDriverClient.run(["--key", combo] + (targeted ? ["--pid", "\(pid)"] : [])) { ok, out in
                    if !ok { self.note("FAIL-ENV \(tag) [real key] \(what): \(out.prefix(160))") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: done)   // past the 1 s page-answer timeout
                }
            }
        }
        func expectHard(_ what: String) {
            run { [self] in
                guard realInput else { return }
                let (doc, dh) = bypassed("/", since: mark), (asset, ah) = bypassed("/asset.js", since: mark)
                check(doc >= 1 && asset >= 1, "\(tag) [real key, PID-targeted] \(what): ⇧⌘R refetches the page and its cached script with no-cache "
                      + "(page \(count("/", since: mark))×, no-cache \(doc) [\(dh)]; script \(count("/asset.js", since: mark))×, no-cache \(asset) [\(ah)])")
            }
        }
        func expectNormal(_ what: String) {
            run { [self] in
                guard realInput else { return }
                let (doc, dh) = bypassed("/", since: mark), (asset, ah) = bypassed("/asset.js", since: mark)
                check(count("/", since: mark) >= 1 && doc == 0 && asset == 0, "\(tag) [real key, PID-targeted] \(what): ⌘R reloads without bypassing the cache "
                      + "(page \(count("/", since: mark))× [\(dh)]; script \(count("/asset.js", since: mark))× [\(ah)])")
            }
        }

        step { [self] done in
            guard UIDriverClient.available, ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1" else {
                note("FAIL-ENV \(tag): real keys need AIRC_REAL_KEYS=1, the UI driver and AIRC_UI_DEDICATED_SESSION=1")
                return done()
            }
            NSApp.activate(ignoringOtherApps: true)
            c.window.makeKeyAndOrderFront(nil)
            waitUntil({ NSApp.isActive && self.c.window.isKeyWindow }, timeout: 4) {
                realInput = NSApp.isActive && self.c.window.isKeyWindow && self.c.window.isOnActiveSpace
                if !realInput {
                    self.note("FAIL-ENV \(tag): the window isn't key on the active Space (active \(NSApp.isActive), key \(self.c.window.isKeyWindow))")
                }
                done()
            }
        }
        // main: the page has the keyboard.
        run { [self] in c.navigate(to: URL(string: "http://127.0.0.1:\(port)/main")!, newTab: true) }
        step { [self] done in waitUntil({ count("/asset.js", since: 0) >= 1 }, timeout: 8) { done() } }
        wait(1)
        run { [self] in c.shownTabID.flatMap { c.engineTab(for: $0) }?.focus() }
        wait(0.5)
        key("cmd+r", "main ⌘R")
        expectNormal("main (page focused)")
        run { [self] in c.shownTabID.flatMap { c.engineTab(for: $0) }?.focus() }
        wait(0.5)
        key("cmd+shift+r", "main ⇧⌘R")
        expectHard("main (page focused)")
        // A second ⇧⌘R right after (the page answered "unused" the first time; no second-press rule may swallow it).
        key("cmd+shift+r", "main ⇧⌘R again")
        expectHard("main (page focused, pressed again)")
        // HID: the same key to whatever is in front (us), not PID-targeted.
        run { [self] in c.shownTabID.flatMap { c.engineTab(for: $0) }?.focus() }
        wait(0.5)
        key("cmd+shift+r", "main ⇧⌘R (HID)", targeted: false)
        expectHard("main (page focused, HID key to the front app)")
        // A text field on the page has the keyboard.
        step { [self] done in
            let page = c.shownTabID.flatMap { c.engineTab(for: $0) }
            page?.focus()
            page?.evaluate("document.getElementById('f').focus(); document.activeElement && document.activeElement.id") { v in
                self.note("\(tag): page field focused: \(String(describing: v))"); done()
            }
        }
        wait(0.5)
        key("cmd+shift+r", "field ⇧⌘R")
        expectHard("page text field focused")
        // The address (⌘L) is being edited.
        run { [self] in c.openCommandBar(mode: .editURL) }
        wait(0.8)
        run { [self] in note("\(tag): Command Bar open \(c.commandBar != nil), first responder \(String(describing: c.window.firstResponder.map { type(of: $0) }))") }
        key("cmd+shift+r", "⌘L bar ⇧⌘R")
        expectHard("⌘L Command Bar open")
        run { [self] in if c.commandBar != nil { c.closeCommandBar() } }
        wait(0.5)
        // sidebar: the window, not the page, has the keyboard.
        run { [self] in c.window.makeFirstResponder(c.window.contentView) }
        wait(0.3)
        key("cmd+shift+r", "sidebar ⇧⌘R")
        expectHard("window focused")
        // peek: a Peek over the tab has the keyboard; the keys reload the Peek's page, not the tab behind it.
        step { [self] done in
            guard let opener = c.shownTabID.flatMap({ c.engineTab(for: $0) }) else { check(false, "\(tag): a page to Peek from"); return done() }
            c.window.makeKeyAndOrderFront(nil)
            c.openPeek(URL(string: "http://127.0.0.1:\(port)/peek")!, from: opener)
            waitUntil({ self.c.peek?.page.url?.path == "/peek" && count("/asset.js", since: 0) > 0 }, timeout: 8) { done() }
        }
        wait(1.5)
        run { [self] in c.peek?.page.focus() }
        wait(0.3)
        key("cmd+r", "Peek ⌘R")
        expectNormal("Peek")
        run { [self] in
            guard realInput else { return }
            check(lock.withLock { log.dropFirst(mark).filter { $0.path == "/main" }.isEmpty } && lock.withLock { log.dropFirst(mark).contains { $0.path == "/peek" } },
                  "\(tag) [real key, PID-targeted] Peek: ⌘R reloads the Peek's page, not the tab behind it")
        }
        run { [self] in c.peek?.page.focus() }
        wait(0.3)
        key("cmd+shift+r", "Peek ⇧⌘R")
        expectHard("Peek")
        run { [self] in
            guard realInput else { return }
            check(lock.withLock { log.dropFirst(mark).filter { $0.path == "/main" }.isEmpty } && lock.withLock { log.dropFirst(mark).contains { $0.path == "/peek" } },
                  "\(tag) [real key, PID-targeted] Peek: ⇧⌘R hard-reloads the Peek's page, not the tab behind it")
        }
        run { [self] in c.closePeek() }
        wait(0.8)
        // little: Little Airc in front.
        step { [self] done in
            little = app?.openLittleArc(url: URL(string: "http://127.0.0.1:\(port)/little"))
            guard let l = little else { check(false, "\(tag): Little Airc opens"); return done() }
            l.window.makeKeyAndOrderFront(nil)
            waitUntil({ l.page?.url?.path == "/little" && l.window.isKeyWindow }, timeout: 8) { done() }
        }
        wait(1.5)
        run { little?.page?.focus() }
        wait(0.3)
        // ⌘R first: WebKit keeps a reload-from-origin's no-cache on the next plain reload of that document.
        key("cmd+r", "Little Airc ⌘R")
        expectNormal("Little Airc")
        run { little?.page?.focus() }
        wait(0.3)
        key("cmd+shift+r", "Little Airc ⇧⌘R")
        expectHard("Little Airc")
        run { little?.closeWindow() }
        run { server?.stop() }
    }
}
#endif
