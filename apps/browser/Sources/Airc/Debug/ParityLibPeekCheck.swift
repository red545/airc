// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit
import ImageIO
import WebKit

/// `--script paritylibpeek` (both engines), L05 and N07/N08 (docs/qa/parity-audit.md), on a loopback page:
///   - a real click on a note in Library › Notes opens it in Peek over the page (the page stays the shown tab), its
///     editor in the card; real typing edits the note; a real click on the Peek's Open in Space shows it in its Space;
///   - a real click on an Easel in Library › Easels opens it in Peek; a real click on its toolbar's Share and Export
///     button and real ↓/Return pick Export as Web Page…; the save panel is driven with real keys (⇧⌘G, a scratch
///     folder, Return): the ZIP has index.html, easel.json and the picture, and index.html renders the board in a page
///     (a WKWebView reading the unzipped folder: every block drawn, the picture decoded); real Esc closes the Peek;
///   - a real ⌃-click on the Easel's Library row and real keys pick Export as Image…, the save panel likewise: the PNG
///     is the whole Easel at 2×, transparent outside the blocks, cut to them;
///   - Delete Easel… on another row: real Esc cancels Arc's question; a real click on its Delete Easel button deletes (rows gone, folder in the
///     Trash); a real ⌘Z brings the rows and the folder back.
/// Screenshots: libpeek-note-peek.png, libpeek-easel-menu.png, libpeek-library-menu.png, libpeek-delete.png.
/// Without AIRC_REAL_KEYS the same paths run without real input, and the real-input cases SKIP.
extension SnapshotRunner {
    func parityLibPeekScenario() {
        final class S {
            var server: LocalPageServer?
            var page = "", noteTab = "", noteID = "", easelID = "", oldID = "", easelTab = "", oldTab = ""
            var scratch: URL!
            var web: WKWebView?
            var probe: [String: Any] = [:]
            var trashedLeftovers: [URL] = []
        }
        let s = S()
        let engine = app?.engine is WebKitEngine ? "WebKit" : "Chromium"
        func label(_ t: String) -> String { "paritylibpeek \(engine): " + t }
        let real = UIDriverClient.requested
        // The run's own 240 s watchdog (SnapshotWatchdog) writes the log and a sample; this only takes a deleted test
        // Easel back out of the Trash first.
        let watchdog = DispatchWorkItem {
            for u in s.trashedLeftovers { try? FileManager.default.removeItem(at: u) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 230, execute: watchdog)

        // MARK: Real input helpers

        /// A window point (of `window`, the browser window by default) as the driver's global display point.
        func global(_ p: NSPoint, in window: NSWindow? = nil) -> (String, String)? {
            guard let main = NSScreen.screens.first else { return nil }
            let g = (window ?? c.window).convertPoint(toScreen: p)
            return ("\(Double(g.x).rounded())", "\(Double(main.frame.maxY - g.y).rounded())")
        }
        func click(_ p: NSPoint?, ctrl: Bool = false, in window: NSWindow? = nil, _ what: String, then: @escaping (Bool) -> Void) {
            guard let p, let g = global(p, in: window) else { check(false, label("\(what) is on screen")); return then(false) }
            // A posted move first: SwiftUI rows track the pointer (airc-posted-click-real-pointer).
            UIDriverClient.run(["--click", g.0, g.1] + (ctrl ? ["--mods", "ctrl"] : [])) { ok, out in
                if !ok { self.note("FAIL-ENV \(label(what)): the driver refused (\(out))") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { then(ok) }
            }
        }
        /// A combo whose letter is the key that types it in this layout (UIDriverClient.keys reads the layout: main thread).
        func mapped(_ combo: String) -> String {
            var parts = combo.split(separator: "+").map(String.init)
            if let last = parts.last, last.count == 1, last.first?.isLetter == true, let k = UIDriverClient.keys(typing: last)?.first, !k.contains("+") {
                parts[parts.count - 1] = k
            }
            return parts.joined(separator: "+")
        }
        /// HID keys to the frontmost app (save panels are another process's view in our window), off the main thread;
        /// `combo` already mapped (`mapped`, `UIDriverClient.keys`).
        func hidKey(_ combo: String) -> Bool {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: UIDriverClient.path)
            p.arguments = ["--json", "--key", combo]
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "CFFIXED_USER_HOME")
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            guard (try? p.run()) != nil else { return false }
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            Thread.sleep(forTimeInterval: 0.12)
            return p.terminationStatus == 0 && out.replacingOccurrences(of: " ", with: "").contains("\"ok\":true")
        }
        /// Off the main thread: `keys` from `UIDriverClient.keys(typing:)`, read on main.
        func typeKeys(_ keys: [String]?) -> Bool {
            guard let keys else { return false }
            for k in keys { guard hidKey(k) else { return false } }
            return true
        }
        func onMain<T>(_ body: @escaping () -> T) -> T? {
            var value: T?
            let sem = DispatchSemaphore(value: 0)
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { value = body(); sem.signal() }
            CFRunLoopWakeUp(CFRunLoopGetMain())
            return sem.wait(timeout: .now() + 2) == .success ? value : nil
        }
        /// Opens a menu with `open`, captures it, and picks `title` with real ↓/↑ and Return.
        func pick(_ what: String, _ title: String, shot: String, open: @escaping (@escaping (Bool) -> Void) -> Void, then: @escaping (Bool) -> Void) {
            var opened = false, trace: [String] = []
            var token: NSObjectProtocol?
            func finish(_ ok: Bool) {
                if let token { NotificationCenter.default.removeObserver(token) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.note(label("\(what): keys \(trace.joined(separator: " "))"))
                    self.check(ok, label("\(what): a real click opens the menu and real keys pick \(title)"))
                    then(ok)
                }
            }
            token = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { n in
                guard !opened, let m = n.object as? NSMenu, m.supermenu == nil, m.items.contains(where: { $0.title == title }) else { return }
                opened = true
                // The menu as it's drawn, over the window (both are this app's windows).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.captureWithMenus(shot) }
                DispatchQueue.global(qos: .userInitiated).async {
                    var picked = false
                    defer { if !picked { _ = hidKey("esc") }; finish(picked) }
                    Thread.sleep(forTimeInterval: 0.8)
                    var dir = "down", last: String? = nil
                    for _ in 0..<30 {
                        if (onMain { m.highlightedItem?.title } ?? nil) == title { picked = hidKey("return"); trace.append("⏎"); return }
                        guard hidKey(dir) else { trace.append("\(dir) failed"); return }
                        let now = onMain { m.highlightedItem?.title } ?? nil
                        trace.append((dir == "down" ? "↓" : "↑") + (now ?? "-"))
                        if now == last, now != nil { dir = dir == "down" ? "up" : "down" }
                        last = now
                    }
                }
            }
            open { ok in
                guard ok else { return finish(false) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if !opened { finish(false) } }
            }
        }
        /// Drives the open save panel with real keys: ⇧⌘G, the scratch folder, Return, then Return to save.
        func savePanel(_ what: String, then: @escaping (Bool) -> Void) {
            waitUntil({ EaselExporting.panel?.isVisible == true }, timeout: 5) {
                guard EaselExporting.panel?.isVisible == true else { self.check(false, label("\(what): the save panel opens")); return then(false) }
                let goTo = mapped("cmd+shift+g"), all = mapped("cmd+a"), folder = UIDriverClient.keys(typing: s.scratch.path)
                DispatchQueue.global(qos: .userInitiated).async {
                    // The panel is another process's view: give it time to take the keys at each step.
                    Thread.sleep(forTimeInterval: 1.5)
                    var ok = hidKey(goTo)
                    Thread.sleep(forTimeInterval: 1.8)
                    ok = ok && hidKey(all) && typeKeys(folder)
                    Thread.sleep(forTimeInterval: 1.0)
                    ok = ok && hidKey("return")
                    Thread.sleep(forTimeInterval: 1.8)
                    ok = ok && hidKey("return")
                    Thread.sleep(forTimeInterval: 1.5)
                    // The panel (another process) sometimes drops the save Return after the folder's: one more real
                    // Return while it's still open (as ParityEaselAllCheck).
                    var again = false
                    if ok, onMain({ EaselExporting.panel?.isVisible == true }) ?? false {
                        again = true
                        ok = hidKey("return")
                        Thread.sleep(forTimeInterval: 1.5)
                    }
                    let open = onMain { EaselExporting.panel?.isVisible == true } ?? true
                    DispatchQueue.main.async {
                        self.note(label("\(what): save panel keys sent \(ok) (⇧⌘G, the folder, Return, Return\(again ? ", Return again" : "")); panel still open: \(open)"))
                        // A panel the keys didn't finish mustn't hold the window for the next cases.
                        if open, let panel = EaselExporting.panel { self.c.window.endSheet(panel) }
                        then(ok && !open)
                    }
                }
            }
        }
        func anchorPoint(_ name: String) -> NSPoint? {
            guard let host = c.library, let v = TestAnchors.view(name, in: host) else { return nil }
            host.layoutSubtreeIfNeeded()
            let r = v.convert(v.bounds, to: nil)
            return NSPoint(x: r.minX + min(80, r.width / 2), y: r.midY)
        }
        func openLibrary(_ section: LibraryModel.Section, then: @escaping () -> Void) {
            if c.library == nil { c.toggleLibrary() }
            c.library?.model.section = section
            c.library?.model.revision += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: then)
        }

        // MARK: Setup

        step { [self] done in
            s.scratch = FileManager.default.temporaryDirectory.appendingPathComponent("libpeek-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try? FileManager.default.createDirectory(at: s.scratch, withIntermediateDirectories: true)
            s.server = LocalPageServer(pages: ["/home": "<!doctype html><title>Home</title><body style='background:#eef'><h1>Home page</h1>"])
            s.server?.start { port in
                guard let port else { self.check(false, label("a loopback page server")); return done() }
                let sid = self.c.currentSpaceID
                s.page = (try? self.c.store.openTab(url: "http://127.0.0.1:\(port)/home", inSpace: sid, title: "Home"))?.id ?? ""
                let doc = NoteDocument(blocks: [NoteBlock(kind: .heading1, runs: [NoteRun("Peek plan")]),
                                                NoteBlock(kind: .paragraph, runs: [NoteRun("First line")])])
                let n = try? self.c.store.createNote(inSpace: sid, document: doc)
                s.noteTab = n?.id ?? ""
                s.noteID = NoteURL.noteID(n?.url) ?? ""
                // The Easel to peek and export: two filled rectangles at its corners, a text, and a picture.
                let files = EaselCenter.shared.files
                s.easelID = newID()
                var e = EaselDocument(id: s.easelID, title: "Peek board")
                e.add(EaselBlock(frame: EaselRect(x: 0, y: 0, width: 100, height: 60), content: .shape(EaselShape(.rectangle, fill: .red))))
                e.add(EaselBlock(frame: EaselRect(x: 400, y: 300, width: 100, height: 60), content: .shape(EaselShape(.rectangle, fill: .darkBlue))))
                e.add(EaselBlock(frame: EaselRect(x: 120, y: 20, width: 240, height: 60), content: .text(EaselText(plain: "Moodboard"))))
                try? files.save(e)
                if let img = Self.libpeekPicture(), let pic = EaselCenter.shared.storePicture(img, ext: "png", in: s.easelID) {
                    e.add(EaselBlock(frame: EaselRect(x: 150, y: 120, width: 120, height: 120), content: .image(pic)))
                    try? files.save(e)
                }
                s.easelTab = (try? self.c.store.createEasel(s.easelID, inSpace: sid, title: "Peek board"))?.id ?? ""
                // The Easel to delete: a Today row and a pinned one.
                s.oldID = newID()
                var o = EaselDocument(id: s.oldID, title: "Old board")
                o.add(EaselBlock(frame: EaselRect(x: 0, y: 0, width: 80, height: 80), content: .shape(EaselShape(.ellipse, fill: .lightGreen))))
                try? files.save(o)
                s.oldTab = (try? self.c.store.createEasel(s.oldID, inSpace: sid, title: "Old board"))?.id ?? ""
                _ = try? self.c.store.reopenEasel(s.oldID, title: "Old board", inSpace: sid)
                self.c.reloadAll(animated: false)
                self.c.show(s.page, focus: false)
                self.waitUntil({ self.c.engineTab(for: s.page)?.isLoading == false }, timeout: 8) {
                    self.check(!s.page.isEmpty && !s.noteID.isEmpty && files.exists(s.easelID) && files.exists(s.oldID) && self.c.shownTabID == s.page,
                               label("setup: a page shown, a note, the Easel to peek (with a picture) and one to delete"))
                    done()
                }
            }
        }

        // MARK: Without real input: the same paths, called directly

        guard real else {
            run { [self] in
                guard let n = c.store.note(s.noteID) else { return check(false, label("the note exists")) }
                check(LibraryNotes.peek(n, in: c) && c.documentPeek?.kind == .note(s.noteID) && c.shownTabID == s.page,
                      label("Library › Notes: the note opens in Peek over the page (no real input)"))
                c.documentPeek?.openInSpace()
                check(c.documentPeek == nil && c.shownNote?.noteID == s.noteID, label("Open in Space shows it in its Space (no real input)"))
                c.show(s.page, focus: false)
                skip(label("real clicks, typing, save panels, ⌘Z need AIRC_REAL_KEYS=1 in a dedicated session"))
            }
            step { [self] done in
                let ed = EaselCenter.shared.editor(for: s.easelID, store: c.store)
                let png = s.scratch.appendingPathComponent("x.png")
                EaselExporting.write(.image, editor: ed, to: png) { ok in
                    self.check(ok && Self.libpeekPNGSize(png) != nil, label("Export as Image writes a PNG (no real input)"))
                    try? FileManager.default.removeItem(at: s.scratch)
                    s.server?.stop()
                    watchdog.cancel()
                    done()
                }
            }
            return
        }

        step { [self] done in
            NSApp.activate(ignoringOtherApps: true)
            c.window.makeKeyAndOrderFront(nil)
            waitUntil({ self.c.window.isKeyWindow && NSApp.isActive }, timeout: 5) {
                self.note(label("real input: key \(self.c.window.isKeyWindow), active \(NSApp.isActive), layout \(UIDriverClient.layoutName)"))
                done()
            }
        }

        // MARK: 1. A note in Peek, editable
        run { [self] in if let sh = c.window.attachedSheet { c.window.endSheet(sh) }; note(label("case: 1. A note in Peek, editable")) }

        uiCase(window: { self.c.window }) {
            step { [self] done in openLibrary(.notes, then: done) }
            step { [self] done in
                uiAttempt?.point = anchorPoint("library.note.\(s.noteID)")
                click(anchorPoint("library.note.\(s.noteID)"), "the note's Library row") { _ in
                    self.waitUntil({ self.c.documentPeek?.kind == .note(s.noteID) && self.c.library == nil }, timeout: 4) {
                        let p = self.c.documentPeek
                        let ed = NoteCenter.shared.existingEditor(s.noteID)
                        self.check(p != nil && ed?.view.isDescendant(of: p!.view.pageHost) == true && self.c.shownTabID == s.page
                                   && self.c.engineTab(for: s.page) != nil && p?.view.titleLabel.stringValue == "Peek plan",
                                   label("a real click on a Library note opens it in Peek over the page, titled, the page still the shown tab"))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { done() }
                    }
                }
            }
            step { [self] done in
                captureOwnWindow(c.window, name: "libpeek-note-peek")
                guard let tv = NoteCenter.shared.existingEditor(s.noteID)?.textView else { check(false, label("the note's editor")); return done() }
                c.window.makeFirstResponder(tv)
                tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
                let word = UIDriverClient.keys(typing: " peekword")
                DispatchQueue.global(qos: .userInitiated).async {
                    let ok = typeKeys(word)
                    DispatchQueue.main.async {
                        self.waitUntil({ self.c.store.note(s.noteID)?.document.plainText.contains("peekword") == true }, timeout: 3) {
                            self.check(ok && self.c.store.note(s.noteID)?.document.plainText.contains("First line peekword") == true,
                                       label("real typing in the Peek edits the note (\(self.c.store.note(s.noteID)?.document.plainText.debugDescription ?? "nil"))"))
                            done()
                        }
                    }
                }
            }
        }

        // MARK: 2. Open in Space
        run { [self] in if let sh = c.window.attachedSheet { c.window.endSheet(sh) }; note(label("case: 2. Open in Space")) }

        uiCase(window: { self.c.window }) {
            step { [self] done in
                let b = c.documentPeek?.view.expandButton
                let pt = b.map { $0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: nil) }
                check(b?.toolTip == "Open in Space (⌘O)", label("the Peek's expand button is Open in Space"))
                click(pt, "the Peek's Open in Space") { _ in
                    self.waitUntil({ self.c.documentPeek == nil && self.c.shownNote?.noteID == s.noteID }, timeout: 4) {
                        let v = NoteCenter.shared.existingEditor(s.noteID)?.view
                        self.check(self.c.documentPeek == nil && self.c.shownTabID == s.noteTab && v?.superview === self.c.card
                                   && self.c.store.note(s.noteID)?.document.plainText.contains("peekword") == true,
                                   label("a real click on Open in Space closes the Peek and shows the note as its tab, the edit kept"))
                        self.c.show(s.page, focus: false)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { done() }
                    }
                }
            }
        }

        // MARK: 3. An Easel in Peek; Export as Web Page… from its menu
        run { [self] in if let sh = c.window.attachedSheet { c.window.endSheet(sh) }; note(label("case: 3. An Easel in Peek; Export as Web Page… from its menu")) }

        uiCase(window: { self.c.window }) {
            step { [self] done in openLibrary(.easels, then: done) }
            step { [self] done in
                waitUntil({ anchorPoint("library.easel.\(s.easelID)") != nil }, timeout: 4) {
                    click(anchorPoint("library.easel.\(s.easelID)"), "the Easel's Library row") { _ in
                        self.waitUntil({ self.c.documentPeek?.kind == .easel(s.easelID) && self.c.library == nil }, timeout: 4) {
                            let ed = EaselCenter.shared.existingEditor(s.easelID)
                            self.check(self.c.documentPeek.map { ed?.view.isDescendant(of: $0.view.pageHost) == true } == true && self.c.shownTabID == s.page,
                                       label("a real click on a Library Easel opens it in Peek over the page"))
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { done() }
                        }
                    }
                }
            }
            step { [self] done in
                let share = EaselCenter.shared.existingEditor(s.easelID)?.view.toolbar.descendants.first { $0.accessibilityIdentifier() == "easel.share" }
                let pt = share.map { $0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: nil) }
                pick("the Easel's Share and Export menu", "Export as Web Page…", shot: "libpeek-easel-menu",
                     open: { then in click(pt, "the Easel's Share and Export button", then: then) }) { ok in
                    guard ok else { return done() }
                    savePanel("Export as Web Page…") { _ in done() }
                }
            }
            step { [self] done in
                let zip = s.scratch.appendingPathComponent("Peek board.zip")
                waitUntil({ EaselExporting.last?.url.resolvingSymlinksInPath().path == zip.resolvingSymlinksInPath().path }, timeout: 6) {
                    let entries = (try? Data(contentsOf: zip)).flatMap(ZipReader.entries) ?? []
                    let names = entries.map(\.name)
                    let assets = names.filter { $0.hasPrefix("Peek board/assets/") }
                    self.check(names.contains("Peek board/index.html") && names.contains("Peek board/easel.json") && assets.count == 1,
                               label("the save panel, driven by real keys, wrote Peek board.zip: index.html, easel.json and the picture (\(names))"))
                    // Unzipped, index.html renders the board in a page.
                    let dir = s.scratch.appendingPathComponent("unzipped", isDirectory: true)
                    for e in entries {
                        let u = dir.appendingPathComponent(e.name)
                        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? e.data.write(to: u)
                    }
                    let index = dir.appendingPathComponent("Peek board/index.html")
                    let config = WKWebViewConfiguration()
                    config.websiteDataStore = .nonPersistent()
                    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
                    s.web = web
                    web.loadFileURL(index, allowingReadAccessTo: dir)
                    let js = """
                    JSON.stringify({blocks: document.querySelectorAll('.easel .b').length,
                      imgs: Array.from(document.images).map(i => i.complete && i.naturalWidth > 0),
                      text: document.body.innerText.includes('Moodboard'),
                      width: document.querySelector('.easel') ? document.querySelector('.easel').getBoundingClientRect().width : 0})
                    """
                    var tries = 0
                    func poll() {
                        tries += 1
                        web.evaluateJavaScript(js) { r, _ in
                            let o = (r as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
                            let imgs = o["imgs"] as? [Bool] ?? []
                            if (o["blocks"] as? Int ?? 0) >= 4, !imgs.isEmpty, imgs.allSatisfy({ $0 }) || tries > 20 {
                                s.probe = o
                                self.check((o["blocks"] as? Int) == 4 && imgs == [true] && o["text"] as? Bool == true && (o["width"] as? Double ?? 0) > 100,
                                           label("index.html renders in a page: 4 blocks, the picture decoded, the text (\(o))"))
                                return done()
                            }
                            if tries > 20 {
                                self.check(false, label("index.html renders in a page (\(o))"))
                                return done()
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: poll)
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
                }
            }
            step { [self] done in
                s.web = nil
                // Real Esc closes the Peek (the Easel's selection is empty).
                EaselCenter.shared.existingEditor(s.easelID)?.selection = []
                UIDriverClient.press(["esc"], pid: getpid()) { ok, _ in
                    self.waitUntil({ self.c.documentPeek == nil }, timeout: 3) {
                        self.check(ok && self.c.documentPeek == nil && self.c.shownTabID == s.page, label("real Esc closes the Easel's Peek; the page stays"))
                        done()
                    }
                }
            }
        }

        // MARK: 4. Export as Image… from the Library row's menu
        run { [self] in if let sh = c.window.attachedSheet { c.window.endSheet(sh) }; note(label("case: 4. Export as Image… from the Library row's menu")) }

        uiCase(window: { self.c.window }) {
            step { [self] done in openLibrary(.easels, then: done) }
            step { [self] done in
                pick("the Easel's Library row menu", "Export as Image…", shot: "libpeek-library-menu",
                     open: { then in click(anchorPoint("library.easel.\(s.easelID)"), ctrl: true, "the Easel's Library row (⌃-click)", then: then) }) { ok in
                    guard ok else { return done() }
                    savePanel("Export as Image…") { _ in done() }
                }
            }
            step { [self] done in
                let png = s.scratch.appendingPathComponent("Peek board.png")
                waitUntil({ EaselExporting.last?.url.resolvingSymlinksInPath().path == png.resolvingSymlinksInPath().path }, timeout: 6) {
                    let ed = EaselCenter.shared.editor(for: s.easelID, store: self.c.store)
                    let want = EaselPicture.render(ed.document, easelID: s.easelID, scale: 2, look: ed.exportLook, transparent: true)?.image
                    let got = Self.libpeekPNGSize(png)
                    // The rectangles span 500 × 360 points: 2× is 1000 × 720 pixels, give or take their edges' antialiasing.
                    let near = got.map { abs($0.width - 1000) <= 6 && abs($0.height - 720) <= 6 } ?? false
                    self.check(got != nil && got?.width == want?.width && got?.height == want?.height && near && got?.alpha == true
                               && got?.cornerClear == true && got?.edgesTouched == true,
                               label("the save panel, driven by real keys, wrote Peek board.png: the whole Easel at 2× (\(got.map { "\($0.width)×\($0.height)" } ?? "none")), "
                                     + "transparent outside the blocks, cut to them"))
                    if self.c.library != nil { self.c.toggleLibrary() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { done() }
                }
            }
        }

        // MARK: 5. Delete Easel…: cancel, delete, ⌘Z
        run { [self] in if let sh = c.window.attachedSheet { c.window.endSheet(sh) }; note(label("case: 5. Delete Easel…: cancel, delete, ⌘Z")) }

        uiCase(window: { self.c.window }) {
            step { [self] done in openLibrary(.easels, then: done) }
            step { [self] done in
                waitUntil({ anchorPoint("library.easel.\(s.oldID)") != nil }, timeout: 4) {
                    pick("the old Easel's Library row menu (cancel)", "Delete Easel…", shot: "libpeek-delete-menu",
                         open: { then in click(anchorPoint("library.easel.\(s.oldID)"), ctrl: true, "the old Easel's Library row (⌃-click)", then: then) }) { ok in
                        self.waitUntil({ LibraryEasels.deleteAlert?.window.isVisible == true }, timeout: 4) {
                            let a = LibraryEasels.deleteAlert
                            self.check(ok && a?.messageText == "Are you sure you want to delete this Easel?" && a?.buttons.first?.title == "Delete Easel",
                                       label("Delete Easel… asks Arc's question (\(a?.messageText ?? "no alert"))"))
                            self.captureOwnWindow(self.c.window, name: "libpeek-delete")
                            UIDriverClient.press(["esc"], pid: getpid()) { _, _ in
                                self.waitUntil({ LibraryEasels.deleteAlert?.window.isVisible != true }, timeout: 3) {
                                    self.check(EaselCenter.shared.files.exists(s.oldID) && self.c.store.tabs(showingEasel: s.oldID).count == 2,
                                               label("real Esc cancels: the Easel and its rows stay"))
                                    done()
                                }
                            }
                        }
                    }
                }
            }
            step { [self] done in
                pick("the old Easel's Library row menu", "Delete Easel…", shot: "libpeek-delete-menu2",
                     open: { then in click(anchorPoint("library.easel.\(s.oldID)"), ctrl: true, "the old Easel's Library row (⌃-click)", then: then) }) { _ in
                    self.waitUntil({ LibraryEasels.deleteAlert?.window.isVisible == true }, timeout: 4) {
                        let b = LibraryEasels.deleteAlert?.buttons.first
                        let pt = b.map { $0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: nil) }
                        click(pt, in: b?.window, "the alert's Delete Easel button") { _ in
                            self.waitUntil({ !EaselCenter.shared.files.exists(s.oldID) }, timeout: 4) {
                                let trashed = LibraryEasels.trashed[s.oldID]
                                if let trashed { s.trashedLeftovers.append(trashed) }
                                self.check(!EaselCenter.shared.files.exists(s.oldID) && self.c.store.tabs(showingEasel: s.oldID).isEmpty
                                           && !self.c.store.referencedEaselIDs.contains(s.oldID)
                                           && trashed.map { FileManager.default.fileExists(atPath: $0.path) && $0.path.contains("/.Trash") } == true
                                           && self.c.store.undoLabel == "Delete Easel",
                                           label("a real click on Delete Easel deletes: its rows go, its folder is in the Trash (\(trashed?.lastPathComponent ?? "nowhere"))"))
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { done() }
                            }
                        }
                    }
                }
            }
            step { [self] done in
                let trashed = LibraryEasels.trashed[s.oldID]
                // ⌘Z belongs to a text field with the keyboard (the Library's search); none should have it here.
                let fr = c.window.firstResponder
                note(label("before ⌘Z the keyboard is with \(fr.map { String(describing: type(of: $0)) } ?? "nothing")"))
                if fr is NSTextView { c.window.makeFirstResponder(nil) }
                UIDriverClient.press(["cmd+z"], pid: getpid()) { ok, out in
                    self.waitUntil({ EaselCenter.shared.files.exists(s.oldID) }, timeout: 4) {
                        self.check(ok && EaselCenter.shared.files.exists(s.oldID) && self.c.store.tabs(showingEasel: s.oldID).count == 2
                                   && EaselCenter.shared.files.load(s.oldID).document.blocks.count == 1
                                   && trashed.map { !FileManager.default.fileExists(atPath: $0.path) } == true && LibraryEasels.trashed[s.oldID] == nil,
                                   label("a real ⌘Z brings back its rows and its folder, out of the Trash (\(ok ? "" : out))"))
                        if self.c.library != nil { self.c.toggleLibrary() }
                        done()
                    }
                }
            }
        }

        run { [self] in
            if let sh = c.window.attachedSheet { c.window.endSheet(sh) }
            for u in s.trashedLeftovers where FileManager.default.fileExists(atPath: u.path) { try? FileManager.default.removeItem(at: u) }
            try? FileManager.default.removeItem(at: s.scratch)
            s.server?.stop()
            watchdog.cancel()
        }
    }

    /// One of this app's windows and the menus it has open, drawn where they are on screen (only our own windows).
    func captureWithMenus(_ name: String) {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return note("\(name): no window capture") }
        let fn = unsafeBitCast(sym, to: Fn.self)
        let w = c.window
        let menus = NSApp.windows.filter { $0.isVisible && $0 !== w && NSStringFromClass(type(of: $0)).contains("Menu") }
        var box = w.frame
        for m in menus { box = box.union(m.frame) }
        let scale = w.backingScaleFactor
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(box.width * scale), pixelsHigh: Int(box.height * scale), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = box.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        var drawn = 0
        for win in [w] + menus {
            guard let img = fn(.null, 1 << 3, UInt32(win.windowNumber), (1 << 3) | (1 << 0))?.takeRetainedValue(), img.width > 8 else { continue }
            NSImage(cgImage: img, size: win.frame.size).draw(in: NSRect(x: win.frame.minX - box.minX, y: win.frame.minY - box.minY,
                                                                         width: win.frame.width, height: win.frame.height))
            drawn += 1
        }
        NSGraphicsContext.restoreGraphicsState()
        guard drawn > 0 else { return note("\(name): window not capturable (screen locked?)") }
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
        note("wrote \(name).png (\(drawn) windows, \(menus.count) menus)")
    }

    /// A 64 × 64 PNG: an orange square with a white dot.
    static func libpeekPicture() -> Data? {
        guard let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 0.5, blue: 0.1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fillEllipse(in: CGRect(x: 20, y: 20, width: 24, height: 24))
        return ctx.makeImage().flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
    }

    /// A PNG's pixel size, whether it has alpha, whether its top-left corner is clear (outside the blocks), and whether
    /// something shows on each of its four edges (cut to the blocks).
    static func libpeekPNGSize(_ url: URL) -> (width: Int, height: Int, alpha: Bool, cornerClear: Bool, edgesTouched: Bool)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let p = data.assumingMemoryBound(to: UInt8.self)
        func a(_ x: Int, _ y: Int) -> UInt8 { p[y * w * 4 + x * 4 + 3] }
        let top = (0..<w).contains { a($0, 0) > 0 }, bottom = (0..<w).contains { a($0, h - 1) > 0 }
        let left = (0..<h).contains { a(0, $0) > 0 }, right = (0..<h).contains { a(w - 1, $0) > 0 }
        let alpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(img.alphaInfo)
        // Top right: the red rectangle is top left, the blue one bottom right; the top-right corner is outside both.
        return (w, h, alpha, a(w - 1, 0) == 0, top && bottom && left && right)
    }
}

private extension NSView {
    var descendants: [NSView] { subviews + subviews.flatMap(\.descendants) }
}
#endif
