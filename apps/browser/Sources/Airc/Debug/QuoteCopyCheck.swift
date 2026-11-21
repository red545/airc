// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit
import CoreText

/// `--script quotecopy` (C06, Arc's quote links), real input from the stable UI driver where a person would act:
/// - a real drag selects a sentence far down a page; a real ⌃-click on it opens the page menu, where "Copy Quote Link"
///   comes right after Copy; real ↓ Return picks it: the clipboard has the page's whole-word `#:~:text=` link, and the
///   toast says Arc's "Copied Link" with "With Quote" and the quote bubble;
/// - a real click on Share Quote copies the same link with the same toast;
/// - that link, opened in a new tab, scrolls to the sentence;
/// - opt-outs, which get the page's plain link and a plain "Copied Link": a site sending
///   `Document-Policy: force-load-at-top` (real drag, real click on Share Quote), a PDF (the page menu's command on it,
///   hook-level: a PDF's text isn't the page's selection), and a private window (its page menu has no Copy Quote Link,
///   hook-level).
/// Needs AIRC_UI_DEDICATED_SESSION=1, AIRC_REAL_KEYS=1 and AIRC_LA_AS_OWNER=1; otherwise FAIL-ENV.
extension SnapshotRunner {
    private var quoteCopyReal: Bool {
        let env = ProcessInfo.processInfo.environment
        return UIDriverClient.available && env["AIRC_UI_DEDICATED_SESSION"] == "1" && env["AIRC_LA_AS_OWNER"] == "1"
    }

    /// `w` key, in front, on the active Space, Airc active; false with a FAIL-ENV line when it can't be.
    private func quoteCopyFront(_ w: NSWindow, _ label: String, _ done: @escaping (Bool) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        waitUntil({ NSApp.isActive && w.isKeyWindow && w.isOnActiveSpace }, timeout: 6) {
            let ok = NSApp.isActive && w.isKeyWindow && w.isOnActiveSpace
            if !ok {
                self.note("FAIL-ENV \(label): window not key/active (active=\(NSApp.isActive), key=\(w.isKeyWindow), space=\(w.isOnActiveSpace), "
                          + "front app \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-"))")
            }
            done(ok)
        }
    }

    /// A window point in Quartz global display points (the driver's).
    private func quoteCopyQuartz(_ p: NSPoint, in w: NSWindow) -> [String] {
        let s = w.convertPoint(toScreen: p)
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return [String(Double(s.x)), String(Double(top - s.y))]
    }

    /// `body` on the main thread from a background one, in every run-loop mode (a tracking menu's too).
    private static func quoteCopyOnMain<T>(_ body: @escaping () -> T) -> T? {
        var value: T?
        let sem = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { value = body(); sem.signal() }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        return sem.wait(timeout: .now() + 2) == .success ? value : nil
    }

    /// A real key press from the stable UI driver, waited for (from a background thread).
    private static func quoteCopyKey(_ combo: String) -> Bool {
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
        Thread.sleep(forTimeInterval: 0.15)
        return p.terminationStatus == 0 && out.replacingOccurrences(of: " ", with: "").contains("\"ok\":true")
    }

    /// A real ⌃-click at `point`, then real ↓ until `title` is highlighted and Return. Answers on main with what was
    /// picked, the menu's titles and a trace.
    private func quoteCopyMenuPick(at point: NSPoint, in w: NSWindow, title: String, _ done: @escaping (Bool, [String], String) -> Void) {
        var trace: [String] = [], titles: [String] = []
        var opened: NSMenu?, token: NSObjectProtocol?, finished = false
        func finish(_ picked: Bool) {
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                if let token { NotificationCenter.default.removeObserver(token) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done(picked, titles, trace.joined(separator: " ")) }
            }
        }
        token = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { n in
            guard opened == nil, let m = n.object as? NSMenu, m.supermenu == nil, m !== NSApp.mainMenu else { return }
            opened = m
            DispatchQueue.global(qos: .userInitiated).async {
                // WebKit adds its items (willOpenMenu) and Chromium updates its own after tracking begins.
                Thread.sleep(forTimeInterval: 0.5)
                titles = (Self.quoteCopyOnMain { m.items.filter { !$0.isHidden }.map { $0.isSeparatorItem ? "—" : $0.title } } ?? nil) ?? []
                trace.append("menu[\(titles.joined(separator: "|"))]")
                guard titles.contains(title) else {
                    _ = Self.quoteCopyKey("esc"); _ = Self.quoteCopyKey("esc")
                    return finish(false)
                }
                for _ in 0..<40 {
                    guard Self.quoteCopyKey("down") else { trace.append("down failed"); break }
                    let h: String? = (Self.quoteCopyOnMain { m.highlightedItem?.title } ?? nil) ?? nil
                    trace.append("↓" + (h ?? "-"))
                    if h == title {
                        let ok = Self.quoteCopyKey("return")
                        trace.append(ok ? "⏎" : "⏎ failed")
                        return finish(ok)
                    }
                }
                _ = Self.quoteCopyKey("esc"); _ = Self.quoteCopyKey("esc")
                finish(false)
            }
        }
        UIDriverClient.click(point, in: w, mods: "ctrl") { ok, out in
            if !ok { trace.append("driver ⌃-click: \(out)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                guard opened == nil, !finished else { return }
                trace.append("no menu opened (key \(NSApp.keyWindow.map { "\(type(of: $0))" } ?? "-"), active \(NSApp.isActive))")
                finish(false)
            }
        }
        // The step's own bound: a menu left open would hold the UI.
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            guard (Self.quoteCopyOnMain { finished } ?? false) == false else { return }
            _ = Self.quoteCopyKey("esc"); _ = Self.quoteCopyKey("esc")
            trace.append("menu step watchdog (20 s)")
            finish(false)
        }
    }

    /// A one-page PDF with `text` on it (drawn with Core Text).
    private static func quoteCopyPDF(_ text: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        ctx.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 18)]))
        ctx.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    func quoteCopyScenario() {
        let tag = "quotecopy"
        let engine = app?.engine is WebKitEngine ? "WebKit" : "Chromium"
        func label(_ s: String) -> String { "\(tag) \(engine): " + s }
        var server: LocalPageServer?
        var base = "", tab = ""
        let board = NSPasteboard(name: NSPasteboard.Name("airc.quotecopy.\(getpid())"))
        let oldLinkBoard = WindowController.linkPasteboard
        let sharedBefore = app?.settings.values.sharedQuotes
        let sentence = "Quiet harbours keep their lanterns lit long after the ferries stop"
        func page() -> EngineTab? { c.engineTab(for: tab) }
        func pill() -> QuotePillView? { c.quotePill }
        // The sentence far down a tall page: a link to it has to scroll.
        let body = "<style>body{margin:0;font:22px -apple-system,sans-serif}</style><div style='height:2400px'></div>"
            + "<p id=q style='margin:0 80px;line-height:40px'>\(sentence).</p><div style='height:2400px'></div>"

        step { [self] done in
            let pages: [String: LocalPageServer.Page] = [
                "/quote": .init(body: "<!doctype html><title>quote</title>" + body),
                "/policy": .init(headers: ["Document-Policy": "force-load-at-top"], body: "<!doctype html><title>policy</title>" + body),
                "/paper": .init(headers: ["Content-Type": "application/pdf"], body: "", data: Self.quoteCopyPDF(sentence)),
            ]
            server = LocalPageServer(responses: pages)
            server?.start { port in
                guard let port else { self.check(false, label("a loopback page server")); return done() }
                base = "http://127.0.0.1:\(port)"
                tab = (try? self.c.store.openTab(url: base + "/quote", inSpace: self.c.currentSpaceID, title: "quote").id) ?? ""
                WindowController.linkPasteboard = board
                WindowController.forgetQuotePageFacts()
                self.app?.settings.values.sharedQuotes = true
                if self.c.sidebarHidden { self.c.toggleSidebar() }
                self.c.show(tab, focus: true)
                self.waitUntil({ page()?.isLoading == false && page()?.title == "quote" }, timeout: 10) { done() }
            }
        }
        guard quoteCopyReal else {
            run { [self] in
                note("FAIL-ENV \(label("real input needs AIRC_UI_DEDICATED_SESSION=1, AIRC_REAL_KEYS=1, AIRC_LA_AS_OWNER=1 and the stable UI driver"))")
                WindowController.linkPasteboard = oldLinkBoard
                server?.stop()
            }
            return
        }

        var start = NSPoint.zero, end = NSPoint.zero, middle = NSPoint.zero
        /// The sentence, scrolled to the middle of the window: its first and last line's ends and its middle, in window points.
        func locate() {
            step { [self] done in
                c.root.layoutSubtreeIfNeeded()
                guard let view = page()?.view else { check(false, label("the page's view")); return done() }
                let js = "(function(){getSelection().removeAllRanges();var p=document.getElementById('q');p.scrollIntoView({block:'center'});"
                    + "var r=document.createRange();r.selectNodeContents(p.firstChild);var b=r.getClientRects();var f=b[0],l=b[b.length-1];"
                    + "return [f.left+3,(f.top+f.bottom)/2,l.right-14,(l.top+l.bottom)/2,(f.left+f.right)/2,(f.top+f.bottom)/2]})()"
                start = .zero
                page()?.evaluate(js) { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        page()?.evaluate(js) { v in
                            let xy = (v as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
                            guard xy.count == 6 else { self.check(false, label("the sentence is on screen (\(String(describing: v)))")); return done() }
                            func pt(_ x: Double, _ y: Double) -> NSPoint {
                                view.convert(NSPoint(x: x, y: view.isFlipped ? y : Double(view.bounds.height) - y), to: nil)
                            }
                            start = pt(xy[0], xy[1]); end = pt(xy[2], xy[3]); middle = pt(xy[4], xy[5])
                            done()
                        }
                    }
                }
            }
        }
        /// A real drag across the sentence; `after` gets the page's selection.
        func drag(_ after: @escaping (String) -> Void) {
            step { [self] done in
                quoteCopyFront(c.window, tag) { ok in
                    guard ok, start != .zero else { return done() }
                    UIDriverClient.run(["--drag"] + self.quoteCopyQuartz(start, in: self.c.window) + self.quoteCopyQuartz(end, in: self.c.window)) { ok, out in
                        if !ok { self.note("FAIL-ENV \(label("driver drag: \(out)"))") }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            page()?.evaluate("String(getSelection())") { v in
                                after((v as? String) ?? "")
                                done()
                            }
                        }
                    }
                }
            }
            wait(0.8)   // past the double-click interval
        }
        func realClick(_ p: @escaping () -> NSPoint?, _ what: String) {
            step { [self] done in
                quoteCopyFront(c.window, tag) { ok in
                    guard ok, let point = p() else { self.check(false, label("\(what) to click")); return done() }
                    // A plain click: the driver refuses an empty --mods.
                    UIDriverClient.run(["--click"] + self.quoteCopyQuartz(point, in: self.c.window)) { ok, out in
                        if !ok { self.note("FAIL-ENV \(label("driver click on \(what): \(out)"))") }
                        done()
                    }
                }
            }
            wait(0.3)
        }
        func pillPoint() -> NSPoint? {
            pill().flatMap { $0.isHidden ? nil : $0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: nil) }
        }
        /// The link the copy should make: the selection out to whole words.
        func expected(_ path: String, _ selection: String) -> String {
            let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard let r = sentence.range(of: trimmed) else { return "-" }
            var lo = r.lowerBound, hi = r.upperBound
            while lo > sentence.startIndex, sentence[sentence.index(before: lo)] != " " { lo = sentence.index(before: lo) }
            while hi < sentence.endIndex, sentence[hi] != " " { hi = sentence.index(after: hi) }
            return LinkCopyPolicy.textFragmentURL(base + path, selection: String(sentence[lo..<hi])) ?? "-"
        }
        /// After a copy: the clipboard changed from `before`; `then` reads it.
        func copied(_ before: @escaping () -> Int, _ then: @escaping (String) -> Void) {
            step { [self] done in
                waitUntil({ board.changeCount != before() }, timeout: 4) {
                    then(board.changeCount != before() ? board.string(forType: .string) ?? "" : "(nothing copied)")
                    done()
                }
            }
        }
        func toastSays() -> String {
            "\(c.toast.shownText ?? "-") · \(c.toast.shownDetail ?? "-") · \(c.toast.shownSymbol ?? "no glyph")"
        }
        var linkBefore = 0, want = "", quoteLink = ""

        // 1. The page menu: real drag, real ⌃-click on the selection, Copy Quote Link by real ↓ Return.
        locate()
        drag { [self] selection in
            want = expected("/quote", selection)
            check(selection.split(separator: " ").count >= 4 && want.contains("#:~:text="), label("a real drag selects the sentence's words (\"\(selection)\")"))
        }
        step { [self] done in
            quoteCopyFront(c.window, tag) { ok in
                guard ok, middle != .zero else { return done() }
                linkBefore = board.changeCount
                self.quoteCopyMenuPick(at: middle, in: self.c.window, title: QuoteLink.copyTitle) { picked, titles, trace in
                    self.note(label("page menu: \(trace)"))
                    let copy = titles.firstIndex(of: "Copy")
                    self.check(picked && copy.map { titles.indices.contains($0 + 1) && titles[$0 + 1] == QuoteLink.copyTitle } == true,
                               label("a real ⌃-click on the selection opens the page menu with \"\(QuoteLink.copyTitle)\" right after Copy, picked by real ↓ Return"))
                    done()
                }
            }
        }
        copied({ linkBefore }) { [self] link in
            quoteLink = link
            check(link == want, label("Copy Quote Link copies the page's whole-word link to the text (\(link); want \(want))"))
            check(c.toast.shownText == QuoteLink.copiedToast && c.toast.shownDetail == QuoteLink.withQuote && c.toast.shownSymbol == QuoteLink.symbol,
                  label("its toast is Arc's \"Copied Link\" with \"With Quote\" and the quote bubble (\(toastSays()))"))
        }
        wait(0.2)
        capture("quotecopy-\(engine.lowercased())-menu-toast")
        wait(2.5)

        // 2. Share Quote, by a real click. sidebarchrome (owner 2026-11-20): the chip is inside the address pill and
        // nothing below the pill moves (the first Favorite and the first pinned row, measured before and after).
        var layoutBefore: [(String, NSRect)] = []
        quoteChipFixtureRows()
        locate()
        run { [self] in layoutBefore = quoteChipLayout() }
        drag { _ in }
        step { [self] done in
            waitUntil({ pill()?.isHidden == false }, timeout: 3) {
                self.check(pill()?.isHidden == false, label("after the drag, Share Quote shows in the address pill"))
                if let p = pill() {
                    let place = self.quoteChipPlacement(p)
                    self.check(place.ok, label("at the pill's right end (\(place.why))"))
                }
                // Mid-slide and settled: the sidebar's rows never move.
                let mid = self.quoteChipShift(layoutBefore, self.quoteChipLayout())
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    let settled = self.quoteChipShift(layoutBefore, self.quoteChipLayout())
                    let names = layoutBefore.map(\.0)
                    self.check(mid.isEmpty && settled.isEmpty && names.contains("first Favorite") && names.contains("first pinned row"),
                               label("0 px layout shift: \(mid.isEmpty && settled.isEmpty ? "first Favorite \(NSStringFromRect(layoutBefore.first { $0.0 == "first Favorite" }?.1 ?? .zero)), first pinned row \(NSStringFromRect(layoutBefore.first { $0.0 == "first pinned row" }?.1 ?? .zero)) unchanged" : "moved: " + mid + " / " + settled)"))
                    linkBefore = board.changeCount
                    done()
                }
            }
        }
        capture("quotecopy-\(engine.lowercased())-chip")
        realClick(pillPoint, "Share Quote")
        copied({ linkBefore }) { [self] link in
            check(link == want, label("a real click on Share Quote copies the same link (\(link))"))
            check(c.toast.shownText == QuoteLink.copiedToast && c.toast.shownDetail == QuoteLink.withQuote,
                  label("with the same toast (\(toastSays()))"))
        }
        wait(0.2)
        capture("quotecopy-\(engine.lowercased())-pill-toast")

        // 3. The link opens in a new tab scrolled to the sentence.
        var opened = ""
        step { [self] done in
            guard quoteLink.contains("#:~:text=") else { check(false, label("a quote link to open")); return done() }
            opened = (try? c.store.openTab(url: quoteLink, inSpace: c.currentSpaceID, title: "opened").id) ?? ""
            c.show(opened, focus: true)
            waitUntil({ self.c.engineTab(for: opened)?.isLoading == false && self.c.engineTab(for: opened)?.title == "quote" }, timeout: 10) {
                // A text fragment scrolls once the page has laid out; give it a moment.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    self.c.engineTab(for: opened)?.evaluate("(function(){var r=document.getElementById('q').getBoundingClientRect();return [scrollY,r.top,r.bottom,innerHeight]})()") { v in
                        let n = (v as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
                        self.check(n.count == 4 && n[0] > 1500 && n[1] >= 0 && n[2] <= n[3],
                                   label("the copied link opens in a new tab scrolled to the sentence (scrollY, top, bottom, height: \(n))"))
                        done()
                    }
                }
            }
        }
        capture("quotecopy-\(engine.lowercased())-opened")
        run { [self] in
            if !opened.isEmpty { _ = try? c.store.closeTab(opened) }
            c.show(tab, focus: true)
        }
        wait(0.8)

        // 4. Opt-out: a site that always opens at the top (Document-Policy: force-load-at-top) gets a plain link.
        run { [self] in
            c.navigate(to: URL(string: base + "/policy")!, newTab: false)
        }
        step { [self] done in waitUntil({ page()?.isLoading == false && page()?.title == "policy" }, timeout: 10) { done() } }
        locate()
        drag { _ in }
        step { [self] done in
            waitUntil({ pill()?.isHidden == false }, timeout: 3) {
                self.check(pill()?.isHidden == false, label("on the force-load-at-top page Share Quote still shows"))
                linkBefore = board.changeCount
                done()
            }
        }
        realClick(pillPoint, "Share Quote")
        copied({ linkBefore }) { [self] link in
            check(link == base + "/policy", label("on a page sending Document-Policy: force-load-at-top, Share Quote copies the plain link (\(link))"))
            check(c.toast.shownText == QuoteLink.copiedToast && c.toast.shownDetail == "" && c.toast.shownSymbol == nil,
                  label("with a plain \"Copied Link\" (\(toastSays()))"))
            let facts = WindowController.lastQuoteFacts
            check(facts.flatMap(QuoteLink.optOut) == .forceLoadAtTop,
                  label("because of the header (\(facts.flatMap(QuoteLink.optOut)?.rawValue ?? "no opt-out"); policy \"\(facts?.documentPolicy ?? "-")\")"))
        }
        wait(0.2)
        capture("quotecopy-\(engine.lowercased())-optout-toast")

        // 5. Opt-out: a PDF (served without a .pdf name), by the page menu's command (hook-level).
        run { [self] in c.navigate(to: URL(string: base + "/paper")!, newTab: false) }
        step { [self] done in waitUntil({ page()?.isLoading == false && page()?.url?.path == "/paper" }, timeout: 10) { done() } }
        wait(1.0)
        run { [self] in
            linkBefore = board.changeCount
            if let p = page() { c.tab(p, pageMenuCommand: QuoteLinkMenu.id) }
        }
        step { [self] done in
            waitUntil({ board.changeCount != linkBefore }, timeout: 6) {
                let link = board.changeCount != linkBefore ? board.string(forType: .string) ?? "" : "(nothing copied)"
                let why = WindowController.lastQuoteFacts.flatMap(QuoteLink.optOut)
                self.check(link == base + "/paper" && self.c.toast.shownText == QuoteLink.copiedToast && self.c.toast.shownDetail == "",
                           label("hook-level: Copy Quote Link on a PDF copies its plain link with a plain \"Copied Link\" (\(link); \(toastSays()))"))
                self.check(why == .pdf || why == .unreadable,
                           label("hook-level: because it's a PDF (\(why?.rawValue ?? "no opt-out"); type \(WindowController.lastQuoteFacts?.contentType ?? "-"))"))
                done()
            }
        }

        // 6. Opt-out: a private window's page menu on selected text has no Copy Quote Link (hook-level).
        var privateWindow: PrivateWindowController?
        step { [self] done in
            guard let app else { return done() }
            PrivateBrowsing.shared.open(app: app) { w in privateWindow = w; done() }
        }
        step { [self] done in
            guard let w = privateWindow else { check(false, label("a private window")); return done() }
            let t = w.openPage(URL(string: base + "/quote"))
            waitUntil({ t.isLoading == false && t.title == "quote" }, timeout: 10) {
                let titles = w.tab(t, pageMenu: ["selection": sentence, "editable": false]).compactMap { $0["title"] }
                    + w.tab(t, pageMenu: ["hasSelection": true]).compactMap { $0["title"] }
                let main = page().map { self.c.tab($0, pageMenu: ["selection": sentence, "editable": false]).compactMap { $0["title"] } } ?? []
                self.check(!titles.contains(QuoteLink.copyTitle) && main.contains(QuoteLink.copyTitle),
                           label("hook-level: a private window's page menu on selected text has no \(QuoteLink.copyTitle) (\(titles); a normal window's: \(main))"))
                self.check(QuoteLink.optOut(.init(url: base + "/quote", isPrivate: true)) == .privateWindow,
                           label("hook-level: a private page's quote copy would be a plain link"))
                done()
            }
        }
        run { privateWindow?.closeWindow() }
        wait(1.0)

        run { [self] in
            WindowController.linkPasteboard = oldLinkBoard
            if let sharedBefore { app?.settings.values.sharedQuotes = sharedBefore }
            board.releaseGlobally()
            server?.stop()
        }
    }
}
#endif
