// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// docs/rebase.md's acceptance items that no other script covered (chromeaccept, Chromium 156.0.8078.109). Both engines,
/// loopback pages only, no camera, microphone or input-source change.
///   chromeaccept-write / chromeaccept-read (one `--data-dir`, two launches): a persistent cookie and localStorage in
///     Space A (profile A), Space B (its own profile B) and Space C (profile A again); a private window sets its own.
///     After the restart each profile reads only its own value, Space C shares A's, and nothing of the private
///     window is left in any profile.
///   chromeaccept: renderer crash recovery (Chromium chrome://kill and chrome://crash, WebKit's web content process
///     killed): the tab reports no page, a page of another site keeps running, a reload brings the page back; GPU
///     process crash (Chromium chrome://gpucrash): WebGL and frames still work afterwards; the PDF viewer shows a PDF
///     in the tab (no download); IME composition through the page view's NSTextInputClient (marked text, then commit),
///     as an input method sends it. No input source is added: that would change the Mac's settings.
extension SnapshotRunner {
    static let chromeAcceptPort: UInt16 = 18593

    func chromeAcceptScenario(_ script: String) {
        let chromium = app?.engine.name.hasPrefix("Chromium") == true
        let tag = "chromeaccept (\(chromium ? "Chromium" : "WebKit"))"
        var server: LocalPageServer?
        step { [self] done in
            server = LocalPageServer(responses: [:], port: Self.chromeAcceptPort)
            server?.requestHandler = { req in Self.chromeAcceptPage(req) }
            guard let server else { check(false, "\(tag): the loopback server starts"); return done() }
            server.start { p in
                self.check(p == Self.chromeAcceptPort, "\(tag): the loopback server listens on \(Self.chromeAcceptPort) (\(p.map(String.init) ?? "none"))")
                done()
            }
        }
        switch script {
        case "chromeaccept-write": chromeAcceptIsolationWrite(tag)
        case "chromeaccept-read": chromeAcceptIsolationRead(tag)
        default:
            chromeAcceptCrash(tag, chromium: chromium)
            if chromium { chromeAcceptGPU(tag) }
            chromeAcceptPDF(tag, chromium: chromium)
            chromeAcceptIME(tag)
        }
        run { _ = server }   // keeps the server for the whole run
    }

    private static var base: String { "http://127.0.0.1:\(chromeAcceptPort)" }

    private static func chromeAcceptPage(_ req: LocalPageServer.Request) -> LocalPageServer.Page? {
        let query = req.target.split(separator: "?").dropFirst().first.map(String.init) ?? ""
        switch req.path {
        case "/set":
            // v=<value>: a persistent cookie (a day) and localStorage, then the title says so.
            return .init(headers: ["Cache-Control": "no-store"], body: """
                <!doctype html><title>setting</title><script>
                const v = new URLSearchParams(location.search).get('v');
                document.cookie = 'iso=' + v + '; Max-Age=86400; Path=/';
                localStorage.setItem('iso', v);
                document.title = 'set ' + v;
                </script>
                """)
        case "/read":
            return .init(headers: ["Cache-Control": "no-store"], body: "<!doctype html><title>read</title><p>reader</p>")
        case "/page":
            return .init(headers: ["Cache-Control": "no-store"], body: """
                <!doctype html><title>page \(query)</title><body style="background:#3b6cf0;color:#fff;font:40px sans-serif">
                <p>chromeaccept \(query)</p><input id=ime style="font-size:30px"><canvas id=gl width=200 height=120></canvas>
                <script>
                window.frames_ = 0; (function tick() { window.frames_++; requestAnimationFrame(tick); })();
                window.ime_ = [];
                const f = document.getElementById('ime');
                for (const t of ['compositionstart', 'compositionupdate', 'compositionend'])
                  f.addEventListener(t, e => window.ime_.push(t + ':' + e.data));
                </script>
                """)
        case "/doc.pdf":
            return .init(headers: ["Content-Type": "application/pdf", "Cache-Control": "no-store"], body: "",
                         data: chromeAcceptPDFData())
        case "/favicon.ico":
            return .init(status: "404 Not Found", body: "")
        default:
            return nil
        }
    }

    /// A one-page PDF with a line of text, byte offsets computed for its xref table.
    private static func chromeAcceptPDFData() -> Data {
        let content = "BT /F1 36 Tf 60 700 Td (Airc PDF fixture) Tj ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]
        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, o) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(o)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { out += String(format: "%010ld 00000 n \n", o) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }

    // MARK: Profile isolation across a restart

    private var chromeAcceptStateURL: URL { AppPaths.dataDirectory.appendingPathComponent("chromeaccept-spaces.json") }

    /// Opens `url` in a new tab of `spaceID`, shows it, and waits for `title`.
    private func chromeAcceptOpen(_ url: String, in spaceID: @escaping () -> String, title: String, _ what: String,
                                  tab: @escaping (String) -> Void) {
        var id = ""
        step { [self] done in
            let space = spaceID()
            guard !space.isEmpty, let t = try? c.store.openTab(url: url, inSpace: space, activate: true, title: "") else {
                check(false, what + ": no tab"); return done()
            }
            id = t.id
            tab(t.id)
            c.reloadAll(animated: false)
            c.switchToSpace(space, animated: false)
            c.show(t.id, focus: false)
            waitUntil({ self.c.engineTab(for: id)?.title == title && self.c.engineTab(for: id)?.isLoading == false }, timeout: 20) {
                self.check(self.c.engineTab(for: id)?.title == title, what + " (\(self.c.engineTab(for: id)?.title ?? "no page"))")
                done()
            }
        }
    }

    /// The page's cookie and localStorage value, as "cookie|storage".
    private func chromeAcceptRead(_ tab: @escaping () -> EngineTab?, _ then: @escaping (String) -> Void) {
        step { done in
            guard let t = tab() else { then("no page|"); return done() }
            t.evaluate("document.cookie + '|' + (localStorage.getItem('iso') || '')") { v in
                then((v as? String) ?? "no answer|")
                done()
            }
        }
    }

    private func chromeAcceptIsolationWrite(_ tag: String) {
        var spaceA = "", spaceB = "", spaceC = ""
        var tabA = "", tabC = ""
        run { [self] in
            spaceA = c.currentSpaceID
            guard let profileA = c.store.state.spaces[spaceA]?.profileID,
                  let b = try? c.profiles.createProfile(name: "Accept B", emoji: "", color: nil) else {
                return check(false, "\(tag): the second profile is created")
            }
            spaceB = (try? c.store.createSpace(name: "Accept B", icon: .emoji("🅱️"), profileID: b.id).id) ?? ""
            spaceC = (try? c.store.createSpace(name: "Accept A2", icon: .emoji("🅰️"), profileID: profileA).id) ?? ""
            check(!spaceB.isEmpty && !spaceC.isEmpty && b.id != profileA,
                  "\(tag): Space B has its own profile, Space C shares Space A's (\(profileA) / \(b.id))")
            let saved: [String: String] = ["A": spaceA, "B": spaceB, "C": spaceC]
            try? JSONSerialization.data(withJSONObject: saved).write(to: chromeAcceptStateURL)
        }
        chromeAcceptOpen(Self.base + "/set?v=A", in: { spaceA }, title: "set A", "\(tag) write: Space A sets its cookie and storage") { tabA = $0 }
        chromeAcceptOpen(Self.base + "/set?v=B", in: { spaceB }, title: "set B", "\(tag) write: Space B (profile B) sets its own") { _ in }
        chromeAcceptOpen(Self.base + "/read", in: { spaceC }, title: "read", "\(tag) write: Space C (profile A) opens a reader") { tabC = $0 }
        chromeAcceptRead({ self.c.engineTab(for: tabC) }) { [self] v in
            check(v == "iso=A|A", "\(tag) write: Space C sees profile A's cookie and storage, not B's (\(v))")
        }
        // The private window: its own cookie and storage, which must not reach any profile.
        var priv: PrivateWindowController?
        step { [self] done in
            guard let app else { return done() }
            PrivateBrowsing.shared.open(app: app) { w in priv = w; done() }
        }
        step { [self] done in
            guard let w = priv else { check(false, "\(tag) write: a private window opens"); return done() }
            let t = w.openPage(URL(string: Self.base + "/set?v=P"))
            waitUntil({ t.title == "set P" && !t.isLoading }, timeout: 15) {
                self.check(t.title == "set P", "\(tag) write: the private window sets its cookie and storage (\(t.title))")
                t.evaluate("document.cookie + '|' + localStorage.getItem('iso')") { v in
                    self.check((v as? String) == "iso=P|P", "\(tag) write: the private page sees only its own (\(v as? String ?? "-"))")
                    done()
                }
            }
        }
        chromeAcceptRead({ self.c.engineTab(for: tabA) }) { [self] v in
            check(v == "iso=A|A", "\(tag) write: Space A still has only its own while the private window is open (\(v))")
        }
        step { [self] done in
            priv?.closeWindow()
            let pid = priv?.profileID ?? ""
            waitUntil({ PrivateBrowsing.shared.windows.isEmpty && PrivateBrowsing.shared.sessionEnded(pid, app: self.app) }, timeout: 10) {
                self.check(PrivateBrowsing.shared.windows.isEmpty, "\(tag) write: the private window closes and its session ends")
                done()
            }
        }
        run { [self] in try? c.store.flush() }
        wait(1)
    }

    private func chromeAcceptIsolationRead(_ tag: String) {
        var spaces: [String: String] = [:]
        var tabs: [String: String] = [:]
        run { [self] in
            spaces = (try? Data(contentsOf: chromeAcceptStateURL))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
            check(spaces.count == 3 && spaces.values.allSatisfy { c.store.state.spaces[$0] != nil },
                  "\(tag) read: the three Spaces came back after the restart (\(spaces.count))")
        }
        for key in ["A", "B", "C"] {
            chromeAcceptOpen(Self.base + "/read", in: { spaces[key] ?? "" }, title: "read",
                             "\(tag) read: Space \(key) opens a reader after the restart") { tabs[key] = $0 }
        }
        let expected = ["A": "iso=A|A", "B": "iso=B|B", "C": "iso=A|A"]
        for key in ["A", "B", "C"] {
            chromeAcceptRead({ self.c.engineTab(for: tabs[key] ?? "") }) { [self] v in
                check(v == expected[key], "\(tag) read: Space \(key) has its profile's persistent cookie and storage only, nothing of the private window (\(v))")
            }
        }
        // A fresh private window starts empty.
        var priv: PrivateWindowController?
        step { [self] done in
            guard let app else { return done() }
            PrivateBrowsing.shared.open(app: app) { w in priv = w; done() }
        }
        step { [self] done in
            guard let w = priv else { check(false, "\(tag) read: a private window opens"); return done() }
            let t = w.openPage(URL(string: Self.base + "/read"))
            waitUntil({ t.title == "read" && !t.isLoading }, timeout: 15) {
                t.evaluate("document.cookie + '|' + (localStorage.getItem('iso') || '')") { v in
                    self.check((v as? String) == "|", "\(tag) read: a new private window after the restart has no cookie or storage (\(v as? String ?? "-"))")
                    w.closeWindow()
                    done()
                }
            }
        }
        wait(1)
    }

    // MARK: Renderer and GPU process crashes

    private func chromeAcceptCrash(_ tag: String, chromium: Bool) {
        var main = "", other = ""
        let space = { self.c.currentSpaceID }
        chromeAcceptOpen("http://localhost:\(Self.chromeAcceptPort)/page?other", in: space, title: "page other",
                         "\(tag): a page of another site loads") { other = $0 }
        run { [self] in c.engineTab(for: other)?.evaluate("window.mark_ = 'other'", completion: nil) }
        let kinds = chromium ? ["kill", "crash"] : ["webcontent"]
        for kind in kinds {
            chromeAcceptOpen(Self.base + "/page?\(kind)", in: space, title: "page \(kind)", "\(tag) \(kind): the page loads") { main = $0 }
            step { [self] done in
                guard let t = c.engineTab(for: main) else { return done() }
                t.evaluate("window.mark_ = 'before'") { _ in
                    if chromium {
                        t.load(URL(string: "chrome://\(kind)")!)
                    } else {
                        self.check(t.endDeveloperProcess(), "\(tag) \(kind): the tab's web content process is ended")
                    }
                    done()
                }
            }
            wait(2)
            capture("chromeaccept-\(kind)-gone")
            step { [self] done in
                guard let t = c.engineTab(for: main) else { check(false, "\(tag) \(kind): the tab survives"); return done() }
                check(!t.isClosed, "\(tag) \(kind): the tab survives its renderer (not closed, app running)")
                // Chromium keeps the crashed page until a reload (no BrowserView, so no sad-tab view); WebKit reloads
                // the page itself (webViewWebContentProcessDidTerminate).
                if chromium { t.reload() }
                waitUntil({ t.title == "page \(kind)" && !t.isLoading }, timeout: 15) {
                    t.evaluate("JSON.stringify({mark: window.mark_ || 'fresh', frames: window.frames_})") { v in
                        let s = v as? String ?? ""
                        self.check(s.contains("\"mark\":\"fresh\""),
                                   "\(tag) \(kind): \(chromium ? "a reload" : "the engine's own reload") brings the page back in a new renderer (\(s.isEmpty ? "no answer" : s))")
                        done()
                    }
                }
            }
            step { [self] done in
                guard let o = c.engineTab(for: other) else { check(false, "\(tag) \(kind): the other site's tab is there"); return done() }
                o.evaluate("window.mark_") { v in
                    self.check(v as? String == "other", "\(tag) \(kind): the other site's page kept running (\(v as? String ?? "no answer"))")
                    done()
                }
            }
        }
        capture("chromeaccept-crash-recovered")
    }

    private func chromeAcceptGPU(_ tag: String) {
        var main = "", gpu = ""
        let space = { self.c.currentSpaceID }
        chromeAcceptOpen(Self.base + "/page?gpu", in: space, title: "page gpu", "\(tag) gpu: the page loads") { main = $0 }
        var before = 0
        step { [self] done in
            guard let t = c.engineTab(for: main) else { return done() }
            t.evaluate("window.frames_") { v in before = (v as? NSNumber)?.intValue ?? 0; done() }
        }
        step { [self] done in
            guard let t = try? c.store.openTab(url: "chrome://gpucrash", inSpace: c.currentSpaceID, activate: false, title: "") else { return done() }
            gpu = t.id
            c.reloadAll(animated: false)
            c.show(t.id, focus: false)
            done()
        }
        wait(5)
        step { [self] done in
            c.show(main, focus: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let t = self.c.engineTab(for: main) else { self.check(false, "\(tag) gpu: the page's tab survives"); return done() }
                t.evaluate("JSON.stringify({frames: window.frames_, gl: !!document.getElementById('gl').getContext('webgl')})") { v in
                    let s = v as? String ?? ""
                    let frames = (try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])?["frames"] as? Int ?? 0
                    self.check(frames > before && s.contains("\"gl\":true"),
                               "\(tag) gpu: after chrome://gpucrash the page still draws frames and gets a WebGL context (\(before) → \(s))")
                    done()
                }
            }
        }
        step { [self] done in
            guard let t = c.engineTab(for: main) else { return done() }
            t.snapshot { image in
                let (ok, why) = Self.chromeAcceptPainted(image)
                self.check(ok, "\(tag) gpu: the page paints after the GPU process restarts (\(why))")
                done()
            }
        }
        capture("chromeaccept-gpu-recovered")
        run { [self] in c.engineTab(for: gpu)?.close() }
    }

    /// Whether a snapshot has the fixture's blue background (not blank, not uniform white or black).
    static func chromeAcceptPainted(_ image: NSImage?) -> (Bool, String) {
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return (false, "no snapshot") }
        let rep = NSBitmapImageRep(cgImage: cg)
        var blue = 0, total = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: max(1, rep.pixelsHigh / 20)) {
            for x in stride(from: 0, to: rep.pixelsWide, by: max(1, rep.pixelsWide / 20)) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += 1
                if c.blueComponent > 0.7 && c.redComponent < 0.4 { blue += 1 }
            }
        }
        return (total > 0 && blue * 2 > total, "\(blue)/\(total) samples blue, \(rep.pixelsWide)×\(rep.pixelsHigh)")
    }

    // MARK: PDF viewer

    private func chromeAcceptPDF(_ tag: String, chromium: Bool) {
        var tab = ""
        step { [self] done in
            guard let t = try? c.store.openTab(url: Self.base + "/doc.pdf", inSpace: c.currentSpaceID, activate: true, title: "") else { return done() }
            tab = t.id
            c.reloadAll(animated: false)
            c.show(t.id, focus: false)
            waitUntil({ self.c.engineTab(for: tab)?.isLoading == false && self.c.engineTab(for: tab)?.url?.path == "/doc.pdf" }, timeout: 15) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: done)
            }
        }
        step { [self] done in
            guard let t = c.engineTab(for: tab) else { check(false, "\(tag) pdf: the tab is there"); return done() }
            check(t.url?.path == "/doc.pdf", "\(tag) pdf: the PDF stays in its tab, not a download (\(t.url?.absoluteString ?? "-"), title \(t.title))")
            t.evaluate("JSON.stringify({type: document.contentType, embed: !!document.querySelector('embed, iframe')})") { v in
                let s = v as? String ?? ""
                if chromium {
                    // The viewer's frames aren't in the main document with OOPIF PDF; the next step checks it paints.
                    self.check(s.contains("application/pdf"),
                               "\(tag) pdf: Chromium's PDF viewer hosts the document (\(s.isEmpty ? "no answer" : s))")
                } else {
                    self.note("\(tag) pdf: WebKit document answer: \(s.isEmpty ? "none (PDF plugin page)" : s)")
                }
                done()
            }
        }
        step { [self] done in
            guard let t = c.engineTab(for: tab) else { return done() }
            t.snapshot { image in
                guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    self.check(false, "\(tag) pdf: a snapshot of the PDF tab"); return done()
                }
                let rep = NSBitmapImageRep(cgImage: cg)
                var colours = Set<Int>()
                for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
                    for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                        if let c = rep.colorAt(x: x, y: y) { colours.insert(Int(c.brightnessComponent * 16)) }
                    }
                }
                self.check(colours.count > 2, "\(tag) pdf: the viewer paints the document (\(colours.count) brightness levels, \(rep.pixelsWide)×\(rep.pixelsHigh))")
                done()
            }
        }
        capture("chromeaccept-pdf")
    }

    // MARK: IME

    private func chromeAcceptIME(_ tag: String) {
        var tab = ""
        chromeAcceptOpen(Self.base + "/page?ime", in: { self.c.currentSpaceID }, title: "page ime", "\(tag) ime: the page loads") { tab = $0 }
        step { [self] done in
            guard let t = c.engineTab(for: tab) else { return done() }
            c.show(tab, focus: true)
            t.focus()
            t.evaluate("document.getElementById('ime').focus(); document.activeElement.id") { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: done)
            }
        }
        var client: NSTextInputClient?
        step { [self] done in
            guard let t = c.engineTab(for: tab), let w = t.view.window else { check(false, "\(tag) ime: the page has a window"); return done() }
            var r = w.firstResponder as? NSView
            while let v = r, !(v is NSTextInputClient) { r = v.superview }
            client = r as? NSTextInputClient
            check(client != nil && (r?.isDescendant(of: t.view) == true || r === t.view),
                  "\(tag) ime: the page view is the first responder and an NSTextInputClient (\(w.firstResponder.map { String(describing: type(of: $0)) } ?? "none"), key \(w.isKeyWindow))")
            client?.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: done)
        }
        step { [self] done in
            guard let t = c.engineTab(for: tab) else { return done() }
            // WKWebView answers hasMarkedText from its web process's editor state, which can lag: only Chromium's is checked.
            let marked = (client?.hasMarkedText() ?? false) || !(self.app?.engine.name.hasPrefix("Chromium") ?? false)
            t.evaluate("JSON.stringify({value: document.getElementById('ime').value, events: window.ime_})") { v in
                let s = v as? String ?? ""
                self.check(marked && s.contains("\"value\":\"にほん\"") && s.contains("compositionstart") && s.contains("compositionupdate:にほん"),
                           "\(tag) ime: marked text starts a composition in the field (marked \(marked), \(s.isEmpty ? "no answer" : s))")
                client?.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: done)
            }
        }
        step { [self] done in
            guard let t = c.engineTab(for: tab) else { return done() }
            let marked = client?.hasMarkedText() ?? true
            t.evaluate("JSON.stringify({value: document.getElementById('ime').value, events: window.ime_})") { v in
                let s = v as? String ?? ""
                self.check(!marked && s.contains("\"value\":\"日本\"") && s.contains("compositionend:日本"),
                           "\(tag) ime: committing replaces the composition with the chosen text (marked \(marked), \(s.isEmpty ? "no answer" : s))")
                done()
            }
        }
        capture("chromeaccept-ime")
    }
}
#endif
