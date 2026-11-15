// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import ApplicationServices
import AircKit
import WebKit

/// `--script paritieaselall` (also `parityeaselall`; both engines), N08 / L05 (docs/qa/parity-audit.md): three
/// synthetic Easels ("Trip" with a picture, another "Trip", "Moodboard"), then
///   1. Library › Easels' card: a real click on Export All Easels; the save panel driven with real keys (⇧⌘G, a scratch
///      folder, Return, Return). The ZIP holds the list page, the README and one folder per Easel ("Trip", "Trip 2",
///      "Moodboard"), the picture in its Easel's folder; unzipped with ditto, the list page links all three and every
///      Easel's index.html renders its board in a page (a WKWebView: blocks, the picture decoded, the text);
///   2. progress and Cancel: an export of 9,000 Easels (the three, many times) shows "Saving your Easels…" with its count
///      moving while the main thread keeps answering; a real click on Cancel stops it and leaves no file;
///   3. File › Export Easel… (real ⌃F2 and arrow keys through the menu bar, else the item run in-app, labelled): the
///      one export panel with its Format menu. Its default (Image) and real Return write a PNG of the whole Easel at 2×,
///      transparent and cut to the blocks; again, a real typed name ending in .zip picks Web Page and writes the ZIP,
///      whose page renders.
/// Screenshots: easelall-card.png, easelall-progress.png, easelall-file-menu.png.
/// Without AIRC_REAL_KEYS the same paths run without real input, and the real-input cases SKIP.
extension SnapshotRunner {
    /// The centre of the menu bar title `title` in Quartz global points, from this app's own accessibility tree; nil when
    /// the tree can't be read.
    static func easelAllMenuBarTitleCenter(_ title: String) -> CGPoint? {
        let app = AXUIElementCreateApplication(getpid())
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success, let barEl = bar else { return nil }
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(barEl as! AXUIElement, kAXChildrenAttribute as CFString, &kids) == .success,
              let items = kids as? [AXUIElement] else { return nil }
        for item in items {
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &t)
            guard (t as? String) == title else { continue }
            var pos: CFTypeRef?, size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &pos) == .success,
                  AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &size) == .success else { return nil }
            var p = CGPoint.zero, sz = CGSize.zero
            AXValueGetValue(pos as! AXValue, .cgPoint, &p)
            AXValueGetValue(size as! AXValue, .cgSize, &sz)
            return sz.width > 0 ? CGPoint(x: p.x + sz.width / 2, y: p.y + sz.height / 2) : nil
        }
        return nil
    }

    func parityEaselAllScenario() {
        final class S {
            var scratch: URL!
            var ids: [String] = []
            var tripID = "", portoID = "", moodID = "", tripTab = ""
            var web: WKWebView?
            var zip: URL?
            var bigSeen = false, bigCounts: [Int] = [], maxGap = 0.0, lastTick = 0.0
            var phase = "start", gaps: [String] = [], cancelGap = 0.0
        }
        let s = S()
        let engine = app?.engine is WebKitEngine ? "WebKit" : "Chromium"
        func label(_ t: String) -> String { "paritieaselall \(engine): " + t }
        let real = UIDriverClient.requested

        // MARK: Real input helpers (as ParityLibPeekCheck's)

        func global(_ p: NSPoint, in window: NSWindow? = nil) -> (String, String)? {
            guard let main = NSScreen.screens.first else { return nil }
            let g = (window ?? c.window).convertPoint(toScreen: p)
            return ("\(Double(g.x).rounded())", "\(Double(main.frame.maxY - g.y).rounded())")
        }
        func click(_ p: NSPoint?, in window: NSWindow? = nil, _ what: String, then: @escaping (Bool) -> Void) {
            guard let p, let g = global(p, in: window) else { check(false, label("\(what) is on screen")); return then(false) }
            UIDriverClient.run(["--click", g.0, g.1]) { ok, out in
                if !ok { self.note("FAIL-ENV \(label(what)): the driver refused (\(out))") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { then(ok) }
            }
        }
        func mapped(_ combo: String) -> String {
            var parts = combo.split(separator: "+").map(String.init)
            if let last = parts.last, last.count == 1, last.first?.isLetter == true, let k = UIDriverClient.keys(typing: last)?.first, !k.contains("+") {
                parts[parts.count - 1] = k
            }
            return parts.joined(separator: "+")
        }
        /// HID keys to the frontmost app, off the main thread (`--keycode` when `code`).
        func hidKey(_ combo: String, code: Bool = false) -> Bool {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: UIDriverClient.path)
            p.arguments = ["--json", code ? "--keycode" : "--key", combo]
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
        /// Drives an open save panel with real keys: the name first when given (⌘A, typed), then ⇧⌘G, the scratch folder,
        /// Return, and Return to save.
        func savePanel(_ what: String, _ panel: @escaping () -> NSSavePanel?, name: String? = nil, then: @escaping (Bool) -> Void) {
            waitUntil({ panel()?.isVisible == true }, timeout: 6) {
                guard panel()?.isVisible == true else { self.check(false, label("\(what): the save panel opens")); return then(false) }
                let goTo = mapped("cmd+shift+g"), all = mapped("cmd+a"), folder = UIDriverClient.keys(typing: s.scratch.path)
                let typed = name.flatMap { UIDriverClient.keys(typing: $0) }
                DispatchQueue.global(qos: .userInitiated).async {
                    Thread.sleep(forTimeInterval: 1.5)
                    var ok = true
                    if name != nil {
                        ok = hidKey(all) && typeKeys(typed)
                        Thread.sleep(forTimeInterval: 0.8)
                    }
                    ok = ok && hidKey(goTo)
                    Thread.sleep(forTimeInterval: 1.8)
                    ok = ok && hidKey(all) && typeKeys(folder)
                    Thread.sleep(forTimeInterval: 1.0)
                    ok = ok && hidKey("return")
                    Thread.sleep(forTimeInterval: 1.8)
                    ok = ok && hidKey("return")
                    Thread.sleep(forTimeInterval: 1.5)
                    // The panel (another process) sometimes takes the folder's Return late and drops the next one: one
                    // more real Return while it's still open.
                    var again = false
                    if ok, onMain({ panel()?.isVisible == true }) ?? false {
                        again = true
                        ok = hidKey("return")
                        Thread.sleep(forTimeInterval: 1.5)
                    }
                    let open = onMain { panel()?.isVisible == true } ?? true
                    DispatchQueue.main.async {
                        self.note(label("\(what): save panel keys sent \(ok) (\(name.map { "the name \($0), " } ?? "")⇧⌘G, the folder, Return, Return\(again ? ", Return again" : "")); panel still open: \(open)"))
                        if open, let p = panel() { self.c.window.endSheet(p) }
                        then(ok && !open)
                    }
                }
            }
        }
        func anchorPoint(_ name: String) -> NSPoint? {
            guard let host = c.library, let v = TestAnchors.view(name, in: host) else { return nil }
            host.layoutSubtreeIfNeeded()
            let r = v.convert(v.bounds, to: nil)
            return NSPoint(x: r.minX + min(40, r.width / 2), y: r.midY)
        }
        func openLibrary(then: @escaping () -> Void) {
            if c.library == nil { c.toggleLibrary() }
            c.library?.model.section = .easels
            c.library?.model.revision += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: then)
        }
        func unzip(_ zip: URL, into dir: URL) -> Bool {
            try? FileManager.default.removeItem(at: dir)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", zip.path, dir.path]
            guard (try? p.run()) != nil else { return false }
            p.waitUntilExit()
            return p.terminationStatus == 0
        }
        /// Loads `page` in a page of its own and returns what the probe script says.
        func render(_ page: URL, root: URL, js: String, ready: @escaping ([String: Any]) -> Bool, then: @escaping ([String: Any]) -> Void) {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
            s.web = web
            web.loadFileURL(page, allowingReadAccessTo: root)
            var tries = 0
            func poll() {
                tries += 1
                web.evaluateJavaScript(js) { r, _ in
                    let o = (r as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
                    if ready(o) || tries > 24 { s.web = nil; return then(o) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: poll)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: poll)
        }
        let boardJS = """
        JSON.stringify({blocks: document.querySelectorAll('.easel .b').length,
          imgs: Array.from(document.images).map(i => i.complete && i.naturalWidth > 0),
          text: document.body.innerText})
        """
        /// Checks that an Easel's page renders: `blocks` blocks, its pictures decoded, `text` on it.
        func renderBoard(_ page: URL, root: URL, blocks: Int, pictures: Int, text: String, _ what: String, then: @escaping () -> Void) {
            render(page, root: root, js: boardJS, ready: { o in
                let imgs = o["imgs"] as? [Bool] ?? []
                return (o["blocks"] as? Int ?? 0) >= blocks && imgs.count == pictures && imgs.allSatisfy { $0 }
            }) { o in
                let imgs = o["imgs"] as? [Bool] ?? []
                self.check((o["blocks"] as? Int) == blocks && imgs == Array(repeating: true, count: pictures) && (o["text"] as? String ?? "").contains(text),
                           label("\(what) renders in a page: \(blocks) blocks, \(pictures) picture(s) decoded, “\(text)” (\(o["blocks"] ?? "-") blocks, \(imgs))"))
                then()
            }
        }

        // MARK: Setup

        step { [self] done in
            s.scratch = FileManager.default.temporaryDirectory.appendingPathComponent("easelall-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try? FileManager.default.createDirectory(at: s.scratch, withIntermediateDirectories: true)
            let files = EaselCenter.shared.files, sid = c.currentSpaceID
            func make(_ title: String, _ blocks: [EaselBlock], picture: Bool = false) -> String {
                let id = newID()
                var e = EaselDocument(id: id, title: title)
                for b in blocks { e.add(b) }
                if picture, let img = Self.libpeekPicture(), let pic = EaselCenter.shared.storePicture(img, ext: "png", in: id) {
                    e.add(EaselBlock(frame: EaselRect(x: 150, y: 120, width: 120, height: 120), content: .image(pic)))
                }
                try? files.save(e)
                let tab = (try? c.store.createEasel(id, inSpace: sid, title: title))?.id ?? ""
                if title == "Trip", picture { s.tripTab = tab }
                s.ids.append(id)
                return id
            }
            s.tripID = make("Trip", [EaselBlock(frame: EaselRect(x: 0, y: 0, width: 100, height: 60), content: .shape(EaselShape(.rectangle, fill: .red))),
                                     EaselBlock(frame: EaselRect(x: 400, y: 300, width: 100, height: 60), content: .shape(EaselShape(.rectangle, fill: .darkBlue))),
                                     EaselBlock(frame: EaselRect(x: 120, y: 20, width: 240, height: 60), content: .text(EaselText(plain: "Lisbon")))], picture: true)
            s.portoID = make("Trip", [EaselBlock(frame: EaselRect(x: 0, y: 0, width: 240, height: 60), content: .text(EaselText(plain: "Porto")))])
            s.moodID = make("Moodboard", [EaselBlock(frame: EaselRect(x: 0, y: 0, width: 80, height: 80), content: .shape(EaselShape(.ellipse, fill: .lightGreen))),
                                          EaselBlock(frame: EaselRect(x: 100, y: 0, width: 240, height: 60), content: .text(EaselText(plain: "Colours")))])
            c.reloadAll(animated: false)
            check(s.ids.allSatisfy(files.exists) && !s.tripTab.isEmpty, label("setup: three Easels (Trip with a picture, another Trip, Moodboard)"))
            done()
        }

        /// Checks Export All's ZIP at `zip`: its entries, then (unzipped) the list page and each Easel's page.
        func verifyArchive(_ zip: URL, _ how: String, then: @escaping () -> Void) {
            let entries = (try? Data(contentsOf: zip)).flatMap(ZipReader.entries) ?? []
            let names = Set(entries.map(\.name))
            let root = zip.deletingPathExtension().lastPathComponent
            let tripFolders = ["Trip", "Trip 2"]
            let pics = names.filter { $0.hasPrefix("\(root)/Trip/assets/") || $0.hasPrefix("\(root)/Trip 2/assets/") }
            let want = ["index.html", "README.md"] + (tripFolders + ["Moodboard"]).flatMap { ["\($0)/index.html", "\($0)/easel.json"] }
            check(want.allSatisfy { names.contains("\(root)/\($0)") } && pics.count == 1 && !names.contains { $0.hasPrefix("\(root)/Moodboard/assets/") },
                  label("\(how): the ZIP holds the list, the README and a folder per Easel (Trip, Trip 2, Moodboard), the picture in its Easel's (\(names.count) entries)"))
            let readme = entries.first { $0.name == "\(root)/README.md" }.map { String(decoding: $0.data, as: UTF8.self) } ?? ""
            check(readme.contains("- ✅ Trip: saved (`Trip/`)") && readme.contains("- ✅ Trip: saved (`Trip 2/`)") && readme.contains("- ✅ Moodboard: saved"),
                  label("\(how): the README's export log lists each Easel as saved"))
            let dir = s.scratch.appendingPathComponent("unzipped", isDirectory: true)
            guard unzip(zip, into: dir) else { check(false, label("\(how): ditto unzips it")); return then() }
            let top = dir.appendingPathComponent(root, isDirectory: true)
            // Which "Trip" folder is the one with the picture (the Library's order decides).
            let lisbon = tripFolders.first { f in pics.contains { $0.hasPrefix("\(root)/\(f)/") } } ?? "Trip"
            let porto = tripFolders.first { $0 != lisbon }!
            let linksJS = "JSON.stringify({links: Array.from(document.querySelectorAll('a.card')).map(a => a.getAttribute('href')), text: document.body.innerText})"
            render(top.appendingPathComponent("index.html"), root: top, js: linksJS, ready: { ($0["links"] as? [String])?.isEmpty == false }) { o in
                let links = o["links"] as? [String] ?? []
                let ours = ["Trip/index.html", "Trip%202/index.html", "Moodboard/index.html"]
                let resolve = links.allSatisfy { FileManager.default.fileExists(atPath: top.appendingPathComponent($0.removingPercentEncoding ?? $0).path) }
                self.check(ours.allSatisfy(links.contains) && resolve && (o["text"] as? String ?? "").contains("Your Easels"),
                           label("\(how): the unzipped list page renders and links every Easel's page, each there (\(links))"))
                renderBoard(top.appendingPathComponent("\(lisbon)/index.html"), root: top, blocks: 4, pictures: 1, text: "Lisbon", "\(how): \(lisbon)/index.html") {
                    renderBoard(top.appendingPathComponent("\(porto)/index.html"), root: top, blocks: 1, pictures: 0, text: "Porto", "\(how): \(porto)/index.html") {
                        renderBoard(top.appendingPathComponent("Moodboard/index.html"), root: top, blocks: 2, pictures: 0, text: "Colours", "\(how): Moodboard/index.html") {
                            then()
                        }
                    }
                }
            }
        }

        /// File › Export Easel…'s result at `url`: a PNG like Export as Image…'s, or a ZIP whose page renders.
        func verifyFileMenuExport(_ url: URL, kind: EaselEditor.ExportKind, _ how: String, then: @escaping () -> Void) {
            waitUntil({ EaselExporting.last?.url.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path }, timeout: 8) {
                let last = EaselExporting.last
                switch kind {
                case .image:
                    let ed = EaselCenter.shared.editor(for: s.tripID, store: self.c.store)
                    let want = EaselPicture.render(ed.document, easelID: s.tripID, scale: 2, look: ed.exportLook, transparent: true)?.image
                    let got = Self.libpeekPNGSize(url)
                    self.check(last?.ok == true && last?.kind == .image && got != nil && got?.width == want?.width && got?.height == want?.height
                               && got.map { abs($0.width - 1000) <= 6 && abs($0.height - 720) <= 6 } == true && got?.alpha == true
                               && got?.cornerClear == true && got?.edgesTouched == true,
                               label("\(how): \(url.lastPathComponent) is the whole Easel at 2× (\(got.map { "\($0.width)×\($0.height)" } ?? "none")), transparent, cut to the blocks"))
                    then()
                case .webPage:
                    let entries = (try? Data(contentsOf: url)).flatMap(ZipReader.entries) ?? []
                    let names = Set(entries.map(\.name))
                    self.check(last?.ok == true && last?.kind == .webPage && names.contains("Trip/index.html") && names.contains("Trip/easel.json")
                               && names.filter { $0.hasPrefix("Trip/assets/") }.count == 1,
                               label("\(how): \(url.lastPathComponent) is the web page ZIP: index.html, easel.json, the picture (\(names.sorted()))"))
                    let dir = s.scratch.appendingPathComponent("unzipped-one", isDirectory: true)
                    guard unzip(url, into: dir) else { self.check(false, label("\(how): ditto unzips it")); return then() }
                    renderBoard(dir.appendingPathComponent("Trip/index.html"), root: dir, blocks: 4, pictures: 1, text: "Lisbon", "\(how): its index.html", then: then)
                }
            }
        }

        /// 9,000 Easels' export: the sheet and its count while the main thread answers; `cancel` stops it.
        func bigExport(cancel: @escaping (@escaping () -> Void) -> Void, then: @escaping () -> Void) {
            EaselCenter.shared.summaries { list in
                let ours = list.filter { s.ids.contains($0.id) }
                let many = Array(repeating: ours, count: 3_000).flatMap { $0 }
                let url = s.scratch.appendingPathComponent("Many.zip")
                s.lastTick = CACurrentMediaTime()
                let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
                    let now = CACurrentMediaTime(), gap = now - s.lastTick
                    if s.phase == "export" { s.maxGap = max(s.maxGap, gap) } else if s.phase == "cancel" { s.cancelGap = max(s.cancelGap, gap) }
                    if gap > 0.05, s.gaps.count < 20 { s.gaps.append("\(s.phase) \(Int(gap * 1000)) ms at done \(EaselExportAll.job?.done ?? -1)") }
                    s.lastTick = now
                    if let j = EaselExportAll.job { s.bigCounts.append(j.done) }
                    if EaselExportAll.progressWindow?.sheetParent === self.c.window { s.bigSeen = true }
                }
                RunLoop.main.add(timer, forMode: .common)
                var finished = false
                EaselExportAll.start(many, to: url, in: self.c) { _ in finished = true }
                self.waitUntil({ (EaselExportAll.job?.done ?? 0) >= 30 || finished }, timeout: 20) {
                    self.captureOwnWindow(self.c.window, name: "easelall-progress")
                    if let w = EaselExportAll.progressWindow { self.captureOwnWindow(w, name: "easelall-progress-sheet") }
                    // The capture itself holds the main thread: measure from here, for a second, then Cancel.
                    s.lastTick = CACurrentMediaTime()
                    s.maxGap = 0
                    s.phase = "export"
                    let title = EaselExportAll.progressWindow?.title
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { s.phase = "cancel"; cancel {
                        self.waitUntil({ finished }, timeout: 20) {
                            timer.invalidate()
                            s.phase = "done"
                            self.note(label("main-thread gaps over 50 ms: \(s.gaps.isEmpty ? "none" : s.gaps.joined(separator: "; ")); longest while cancelling \(Int(s.cancelGap * 1000)) ms"))
                            let r = EaselExportAll.last
                            let moved = Set(s.bigCounts).count
                            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: s.scratch.path))?.filter { $0.contains("Many.zip") } ?? []
                            self.check(s.bigSeen && title == "Saving your Easels…" && moved >= 3,
                                       label("9,000 Easels: “Saving your Easels…” shows while they export, its count moving (\(moved) values seen)"))
                            self.check(s.maxGap < 0.25, label("9,000 Easels: the main thread keeps answering while they export (longest gap \(Int(s.maxGap * 1000)) ms over 1 s)"))
                            self.check(finished && r?.cancelled == true && leftovers.isEmpty && EaselExportAll.job == nil && self.c.window.attachedSheet == nil,
                                       label("Cancel stops the export, closes the sheet and leaves no file (\(leftovers))"))
                            then()
                        }
                    } }
                }
            }
        }

        // MARK: Without real input: the same paths, called directly

        guard real else {
            step { [self] done in
                EaselCenter.shared.summaries { list in
                    let ours = list.filter { s.ids.contains($0.id) }
                    let url = s.scratch.appendingPathComponent("All.zip")
                    EaselExportAll.start(ours, to: url, in: self.c) { r in
                        self.check(r.ok && r.saved == 3, label("Export All Easels writes the archive (no real input)"))
                        verifyArchive(url, "Export All Easels (no real input)") { done() }
                    }
                }
            }
            step { [self] done in bigExport(cancel: { then in EaselExportAll.job?.cancel(); then() }) { done() } }
            step { [self] done in
                let ed = EaselCenter.shared.editor(for: s.tripID, store: c.store)
                let png = s.scratch.appendingPathComponent("Trip.png"), zip = s.scratch.appendingPathComponent("Trip web.zip")
                EaselExporting.write(.image, editor: ed, to: png) { _ in
                    verifyFileMenuExport(png, kind: .image, "Export as Image (no real input)") {
                        EaselExporting.write(.webPage, editor: ed, to: zip) { _ in
                            verifyFileMenuExport(zip, kind: .webPage, "Export as Web Page (no real input)") {
                                self.skip(label("real clicks, menu keys and save panels need AIRC_REAL_KEYS=1 in a dedicated session"))
                                try? FileManager.default.removeItem(at: s.scratch)
                                done()
                            }
                        }
                    }
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

        // MARK: 1. Export All Easels from the Library card
        run { [self] in if let sh = c.window.attachedSheet { c.window.endSheet(sh) }; note(label("case: 1. Export All Easels from the Library card")) }

        uiCase(window: { self.c.window }) {
            step { [self] done in openLibrary(then: done) }
            step { [self] done in
                waitUntil({ anchorPoint("library.easels.exportAll") != nil }, timeout: 4) {
                    let card = self.c.library.flatMap { TestAnchors.view("library.easels.exportAllCard", in: $0) }
                    self.check(card != nil, label("Library › Easels shows the card “Your Easels are yours to keep” with Export All Easels"))
                    self.captureOwnWindow(self.c.window, name: "easelall-card")
                    self.uiAttempt?.point = anchorPoint("library.easels.exportAll")
                    click(anchorPoint("library.easels.exportAll"), "the card's Export All Easels") { _ in
                        self.waitUntil({ EaselExportAll.panel?.isVisible == true }, timeout: 5) {
                            let p = EaselExportAll.panel
                            self.check(p?.isVisible == true && p?.prompt == "Export" && p?.message == "Save an archive of all your Easels as web pages you can open anywhere."
                                       && p?.nameFieldStringValue.hasPrefix("Airc Easels - ") == true && p?.nameFieldStringValue.hasSuffix(".zip") == true,
                                       label("a real click on Export All Easels opens Arc's save panel (\(p?.nameFieldStringValue ?? "none"))"))
                            savePanel("Export All Easels", { EaselExportAll.panel }) { _ in done() }
                        }
                    }
                }
            }
            step { [self] done in
                waitUntil({ EaselExportAll.last.map { $0.url.deletingLastPathComponent().resolvingSymlinksInPath().path == s.scratch.resolvingSymlinksInPath().path } == true
                            && EaselExportAll.job == nil }, timeout: 20) {
                    let r = EaselExportAll.last
                    s.zip = r?.url
                    // The test profile may hold other Easels; ours are all saved.
                    let ours = r?.entries.filter { e in ["Trip", "Moodboard"].contains(e.title) && e.isSaved }.count ?? 0
                    let toast = self.c.toast
                    self.check(r?.ok == true && ours == 3 && r.map { FileManager.default.fileExists(atPath: $0.url.path) } == true
                               && toast.shownText == "Your Easels are saved" && toast.actionButton?.title == "Show in Finder",
                               label("the export finishes: \(r?.url.lastPathComponent ?? "no file"), the toast “\(toast.shownText ?? "-")” with \(toast.actionButton?.title ?? "no button")"))
                    guard let zip = r?.url else { return done() }
                    verifyArchive(zip, "Export All Easels") {
                        if self.c.library != nil { self.c.toggleLibrary() }
                        done()
                    }
                }
            }
        }

        // MARK: 2. Progress with many Easels; a real click on Cancel
        run { [self] in if let sh = c.window.attachedSheet { c.window.endSheet(sh) }; note(label("case: 2. Progress with many Easels; Cancel")) }

        uiCase(window: { self.c.window }) {
            step { [self] done in
                bigExport(cancel: { then in
                    let w = EaselExportAll.progressWindow
                    let b = w?.contentView.flatMap { TestAnchors.view("easelAll.cancel", in: $0) }
                    let pt = b.map { $0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: nil) }
                    click(pt, in: w, "the progress sheet's Cancel") { _ in then() }
                }) { done() }
            }
        }

        // MARK: 3. File › Export Easel…: the one export panel, Image then Web Page
        run { [self] in if let sh = c.window.attachedSheet { c.window.endSheet(sh) }; note(label("case: 3. File › Export Easel…")) }

        /// Opens File › Export Easel… with real ⌃F2 (focus the menu bar), → to File, ↓ into it, ↓ to the item and
        /// Return. If the menu bar never takes the keys (the shortcut is off), the item runs in-app, and says so.
        func fileMenuExport(_ what: String, then: @escaping () -> Void) {
            guard let file = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "File" || $0.title == "File" })?.submenu,
                  let item = file.items.first(where: { $0.title == "Export Easel…" }) else {
                check(false, label("the File menu has Export Easel…")); return then()
            }
            var opened = false, trace: [String] = []
            // Tracking from the menu bar is posted for the main menu, a menu opened on its own for itself.
            let token = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { n in
                guard !opened, let m = n.object as? NSMenu, m === file || m === NSApp.mainMenu else { return }
                opened = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.captureWithMenus("easelall-file-menu") }
            }
            // Where File's title is in the menu bar, from this app's own accessibility tree (global, top-left origin).
            let fileTitle = Self.easelAllMenuBarTitleCenter("File")
            trace.append("AX trusted \(AXIsProcessTrusted()), File at \(fileTitle.map { "\(Int($0.x)),\(Int($0.y))" } ?? "unknown")")
            DispatchQueue.global(qos: .userInitiated).async {
                var picked = false, how = ""
                if let pt = fileTitle {
                    // A real click on File's title in the menu bar.
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: UIDriverClient.path)
                    p.arguments = ["--json", "--click", "\(Int(pt.x))", "\(Int(pt.y))"]
                    var env = ProcessInfo.processInfo.environment
                    env.removeValue(forKey: "CFFIXED_USER_HOME")
                    p.environment = env
                    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                    let ok = (try? p.run()) != nil
                    if ok { p.waitUntilExit() }
                    trace.append("click \(ok && p.terminationStatus == 0 ? "sent" : "refused")")
                    Thread.sleep(forTimeInterval: 0.8)
                    how = "a real click on File in the menu bar"
                }
                if !opened {
                    // ⌃F2 (the physical F2 key, keycode 120) focuses the menu bar; ↓ opens a menu, → moves to the next.
                    how = "real ⌃F2"
                    _ = hidKey("ctrl+120", code: true)
                    Thread.sleep(forTimeInterval: 0.6)
                    for _ in 0..<6 where !opened {
                        _ = hidKey("down")
                        Thread.sleep(forTimeInterval: 0.5)
                        if !opened { _ = hidKey("esc"); _ = hidKey("right"); Thread.sleep(forTimeInterval: 0.3) }
                    }
                }
                if opened {
                    var last: String?
                    for _ in 0..<40 {
                        let now = onMain { file.highlightedItem?.title } ?? nil
                        if now == item.title { picked = hidKey("return"); trace.append("⏎"); break }
                        guard hidKey("down") else { break }
                        let after = onMain { file.highlightedItem?.title } ?? nil
                        trace.append("↓\(after ?? "-")")
                        if after == last, after != nil { break }
                        last = after
                    }
                    if !picked { _ = hidKey("esc"); _ = hidKey("esc") }
                } else {
                    _ = hidKey("esc")
                }
                // The real pointer stays where the click left it, on the menu bar, where it disturbs later presses
                // (airc-posted-click-real-pointer): park it over the window again.
                if let park = onMain({ global(NSPoint(x: self.c.window.frame.width / 2, y: self.c.window.frame.height / 2)) }) ?? nil {
                    let m = Process()
                    m.executableURL = URL(fileURLWithPath: UIDriverClient.path)
                    m.arguments = ["--json", "--move", park.0, park.1]
                    var env = ProcessInfo.processInfo.environment
                    env.removeValue(forKey: "CFFIXED_USER_HOME")
                    m.environment = env
                    m.standardOutput = FileHandle.nullDevice; m.standardError = FileHandle.nullDevice
                    if (try? m.run()) != nil { m.waitUntilExit() }
                }
                DispatchQueue.main.async {
                    NotificationCenter.default.removeObserver(token)
                    self.note(label("\(what): menu keys \(trace.joined(separator: " "))"))
                    if picked {
                        self.check(true, label("\(what): \(how) opens File, and real ↓/Return pick Export Easel…"))
                    } else {
                        self.note(label("\(what): the menu bar didn't take real keys (⌃F2 off?); File › Export Easel… runs in-app (performActionForItem)"))
                        file.performActionForItem(at: file.index(of: item))
                    }
                    then()
                }
            }
        }

        uiCase(window: { self.c.window }) {
            step { [self] done in
                c.show(s.tripTab, focus: false)
                EaselExporting.lastChosen = .image
                waitUntil({ self.c.shownEasel?.easelID == s.tripID }, timeout: 4) {
                    fileMenuExport("File › Export Easel… (Image)") {
                        self.waitUntil({ EaselExporting.panel?.isVisible == true }, timeout: 5) {
                            let p = EaselExporting.panel, f = EaselExporting.formats
                            self.check(p?.isVisible == true && p?.title == "Export Easel" && p?.prompt == "Export" && f?.kind == .image
                                       && f?.popup.itemTitles == ["Image (PNG)", "Web Page (ZIP)"] && p?.nameFieldStringValue == "Trip.png",
                                       label("File › Export Easel… opens the one export panel: Format Image (PNG) or Web Page (ZIP), named Trip.png (\(p?.nameFieldStringValue ?? "none"))"))
                            savePanel("File › Export Easel… (Image)", { EaselExporting.panel }) { _ in
                                verifyFileMenuExport(s.scratch.appendingPathComponent("Trip.png"), kind: .image, "File › Export Easel…, Image") { done() }
                            }
                        }
                    }
                }
            }
            step { [self] done in
                fileMenuExport("File › Export Easel… (Web Page)") {
                    self.waitUntil({ EaselExporting.panel?.isVisible == true }, timeout: 5) {
                        savePanel("File › Export Easel… (Web Page)", { EaselExporting.panel }, name: "Trip web.zip") { _ in
                            verifyFileMenuExport(s.scratch.appendingPathComponent("Trip web.zip"), kind: .webPage, "File › Export Easel…, a typed .zip name") {
                                self.check(EaselExporting.lastChosen == .webPage, label("File › Export Easel… offers Web Page first next time"))
                                done()
                            }
                        }
                    }
                }
            }
        }

        run { [self] in
            if let sh = c.window.attachedSheet { c.window.endSheet(sh) }
            if c.library != nil { c.toggleLibrary() }
            try? FileManager.default.removeItem(at: s.scratch)
        }
    }
}
#endif
