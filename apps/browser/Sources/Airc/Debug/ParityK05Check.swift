// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// `--script parityk05` (K05): Find and Replace and the Services menu, on a loopback page of inputs, a textarea, a
/// contenteditable area, a password field, a read-only field, an email field, a same-origin frame and a frame of
/// another origin. No real service is invoked: the requestor API is called with a private pasteboard.
///   1. ⌥⌘F with a field focused replaces in that field only: Replace (a real click) takes the next match, ⌘Z in the
///      page undoes it (the page's own undo stack), All is one undo step, the page saw input events.
///   2. With no field focused (or the password field focused), every editable field on the page and in its same-origin
///      frame: Replace All changes inputs, the textarea, contenteditable text and the frame's fields; never the password
///      field, the read-only one, plain text or the other origin's frame.
///   3. Services: the app menu's Services is NSApp.servicesMenu; the page view is a requestor for its selection (text
///      written to a pasteboard), and takes a service's text back into an editable selection.
extension SnapshotRunner {
    func parityK05Scenario() {
        let chromium = app?.engine.name.hasPrefix("Chromium") == true
        let tag = chromium ? "chromium" : "webkit"
        final class Box { var port: UInt16 = 0 }
        let box = Box()
        var server: LocalPageServer?
        var tabID = ""
        let page = { self.c.engineTab(for: tabID) }
        let bar = { self.c.findBar }

        func form(port: UInt16) -> String {
            """
            <!doctype html><html><head><title>form</title><link rel="icon" href="data:,">
            <style>body { font: 15px -apple-system, sans-serif; margin: 16px } input, textarea { display: block; margin: 6px 0; width: 340px }
            [contenteditable] { border: 1px solid #ccc; padding: 4px; width: 340px } iframe { width: 360px; height: 90px; border: 1px solid #ddd }</style>
            </head><body>
            <p id="plain">findme in plain text</p>
            <input id="name" value="Hello findme world findme">
            <textarea id="notes">findme one
            findme two</textarea>
            <div id="rich" contenteditable="true"><p>findme here</p><p>and <b>findme</b> there</p></div>
            <input id="pw" type="password" value="findme secret">
            <input id="ro" readonly value="findme read-only">
            <input id="mail" type="email" value="findme@mail.example">
            <iframe id="same" src="/frame?n=same"></iframe>
            <iframe id="cross" src="http://localhost:\(port)/frame?n=cross"></iframe>
            <script>
            window.__inputs = 0; document.addEventListener('input', function () { window.__inputs++; }, true);
            window.__probes = {};
            addEventListener('message', function (e) { if (e.data && e.data.kind === 'probe') window.__probes[e.data.n] = e.data; });
            function probeAll() { for (var i = 0; i < frames.length; i++) frames[i].postMessage('probe', '*'); }
            function values() {
              var o = {};
              ['name', 'notes', 'pw', 'ro', 'mail'].forEach(function (id) { o[id] = document.getElementById(id).value; });
              o.rich = document.getElementById('rich').textContent; o.plain = document.getElementById('plain').textContent;
              return JSON.stringify(o);
            }
            </script></body></html>
            """
        }
        let frame = """
            <!doctype html><html><head><title>frame</title></head><body>
            <input id="fin" value="findme in frame"><div id="frich" contenteditable="true">findme rich frame</div>
            <script>addEventListener('message', function (e) { if (e.data === 'probe') parent.postMessage({ kind: 'probe',
              n: new URLSearchParams(location.search).get('n'), fin: document.getElementById('fin').value,
              frich: document.getElementById('frich').textContent }, '*'); });</script></body></html>
            """
        func answer(_ path: String) -> LocalPageServer.Page? {
            switch path.components(separatedBy: "?").first ?? path {
            case "/form": return .init(body: form(port: box.port))
            case "/frame": return .init(body: frame)
            default: return nil
            }
        }
        /// Evaluates `code` until `ok` (or the timeout), then checks it.
        func expectJS(_ code: String, _ what: String, timeout: Double = 4, _ ok: @escaping (String) -> Bool) {
            step { [self] done in
                let deadline = Date().addingTimeInterval(timeout)
                func poll() {
                    guard let p = page() else { check(false, "parityk05 (\(tag)): \(what) (no page)"); return done() }
                    p.evaluate(code) { v in
                        let got = v.map { "\($0)" } ?? "nil"
                        if ok(got) || Date() > deadline { self.check(ok(got), "parityk05 (\(tag)): \(what) (\(got))"); return done() }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: poll)
                    }
                }
                poll()
            }
        }
        func js(_ code: String) { step { done in page()?.evaluate(code) { _ in done() } } }
        func values(_ v: String) -> [String: String] {
            ((try? JSONSerialization.jsonObject(with: Data(v.utf8))) as? [String: String]) ?? [:]
        }
        /// Opens Find and Replace and waits for the page to say what it replaces in.
        func openReplace() {
            run { [self] in
                if c.findBar != nil { c.closeFind(refocusPage: false) }
            }
            wait(0.3)
            run { [self] in c.showFindAndReplace() }
            step { [self] done in waitUntil({ bar()?.replaceScope != "auto" }, timeout: 3, then: done) }
        }

        step { [self] done in
            server = LocalPageServer(responses: [:])
            server?.handler = answer
            guard let server else { check(false, "parityk05: the loopback server starts"); return done() }
            server.start { p in
                box.port = p ?? 0
                self.check(box.port != 0, "parityk05 (\(tag)): the loopback server starts")
                done()
            }
        }
        run { [self] in
            guard box.port != 0, let t = try? c.store.openTab(url: "http://127.0.0.1:\(box.port)/form", inSpace: c.currentSpaceID, title: "form") else { return }
            tabID = t.id
            c.reloadAll(animated: false)
            c.show(t.id, focus: false)
        }
        step { [self] done in
            waitUntil({ page()?.title == "form" && page()?.isLoading == false }, timeout: 15) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: done) }
        }

        // The menu: Edit › Find › Find and Replace, ⌥⌘F.
        run { [self] in
            func find(_ menu: NSMenu?) -> NSMenuItem? {
                for i in menu?.items ?? [] {
                    if i.title == "Find and Replace" { return i }
                    if let hit = find(i.submenu) { return hit }
                }
                return nil
            }
            let item = find(NSApp.mainMenu)
            check(item?.keyEquivalent == "f" && item?.keyEquivalentModifierMask.intersection([.command, .option, .shift, .control]) == [.command, .option],
                  "parityk05 (\(tag)): Edit › Find › Find and Replace is ⌥⌘F, as in Arc (\(item?.keyEquivalent ?? "none"))")
        }

        // MARK: 1. The field with the keyboard

        js("(function () { var e = document.getElementById('name'); e.focus(); e.setSelectionRange(0, 0); return true })()")
        openReplace()
        run { [self] in
            guard let b = bar() else { return check(false, "parityk05 (\(tag)): ⌥⌘F opens the find bar") }
            check(b.isReplacing && b.replaceScope == "field" && b.replaceField.placeholderString == "Replace in this field" && !b.replaceField.isHidden,
                  "parityk05 (\(tag)): ⌥⌘F with a field focused: the Replace row, for that field (\(b.replaceField.placeholderString ?? "-"))")
            b.field.stringValue = "findme"
            b.replaceField.stringValue = "FOUND"
            b.find(forward: true)
        }
        wait(0.5)
        capture("parityk05-find-replace")
        // Replace: a real click on the button, its action if the click can't reach the window.
        step { [self] done in
            guard let b = bar(), let w = b.window else { return done() }
            let p = b.replaceButton.convert(NSPoint(x: b.replaceButton.bounds.midX, y: b.replaceButton.bounds.midY), to: nil)
            click(at: p, in: w) {
                self.waitUntil({ b.lastReplace != nil }, timeout: 2) {
                    if b.lastReplace == nil { self.note("parityk05 (\(tag)): the click didn't reach the button (\(self.realEventsBlocked ?? "window not key")); its action"); b.replacePressed() }
                    done()
                }
            }
        }
        expectJS("values()", "Replace takes the next match in that field only") {
            let v = values($0)
            return v["name"] == "Hello FOUND world findme" && v["notes"]?.hasPrefix("findme one") == true && v["rich"]?.hasPrefix("findme here") == true
        }
        expectJS("window.__inputs", "the page saw the change as input (an input event)") { (Int($0) ?? 0) >= 1 }
        expectJS("(function () { var e = document.getElementById('name'); e.focus(); document.execCommand('undo'); return e.value })()",
                 "⌘Z in the page undoes it: the page's own undo stack") { $0 == "Hello findme world findme" }
        js("(function () { var e = document.getElementById('name'); e.focus(); e.setSelectionRange(0, 0); return true })()")
        run { [self] in bar()?.replaceAllPressed() }
        expectJS("document.getElementById('name').value", "All replaces every match in the field") { $0 == "Hello FOUND world FOUND" }
        expectJS("(function () { var e = document.getElementById('name'); e.focus(); document.execCommand('undo'); return e.value })()",
                 "…and one ⌘Z takes it all back") { $0 == "Hello findme world findme" }

        // MARK: 2. Every editable field on the page

        js("(function () { var e = document.getElementById('pw'); e.focus(); return true })()")
        openReplace()
        run { [self] in
            check(bar()?.replaceScope == "page" && bar()?.replaceField.placeholderString == "Replace in the page's fields",
                  "parityk05 (\(tag)): with the password field focused, it's never the field: every editable field instead")
        }
        js("(function () { if (document.activeElement) document.activeElement.blur(); return true })()")
        openReplace()
        run { [self] in
            guard let b = bar() else { return }
            check(b.replaceScope == "page", "parityk05 (\(tag)): with no field focused, Find and Replace is for the page's fields")
            b.field.stringValue = "findme"
            b.replaceField.stringValue = "FOUND"
            b.replaceAllPressed()
        }
        step { [self] done in waitUntil({ bar()?.lastReplace != nil }, timeout: 4, then: done) }
        run { [self] in
            let r = bar()?.lastReplace
            check(r?.replaced == 9 && r?.frames == 1 && r?.field == false,
                  "parityk05 (\(tag)): All on the page replaced 9 (the fields, the rich text, the same-origin frame's two) in 1 frame (\(r?.replaced ?? -1), \(r?.frames ?? -1))")
        }
        capture("parityk05-replaced")
        expectJS("values()", "inputs, the textarea, the email field and rich text changed; password, read-only and plain text didn't") {
            let v = values($0)
            return v["name"] == "Hello FOUND world FOUND" && v["notes"] == "FOUND one\nFOUND two" && v["rich"] == "FOUND hereand FOUND there"
                && v["mail"] == "FOUND@mail.example" && v["pw"] == "findme secret" && v["ro"] == "findme read-only" && v["plain"] == "findme in plain text"
        }
        expectJS("(probeAll(), JSON.stringify([window.__probes.same || null, window.__probes.cross || null]))",
                 "the same-origin frame's fields changed, the other origin's frame didn't") {
            $0.contains("\"fin\":\"FOUND in frame\"") && $0.contains("\"frich\":\"FOUND rich frame\"") && $0.contains("\"fin\":\"findme in frame\"")
        }

        // MARK: 3. Services

        run { [self] in
            let services = NSApp.mainMenu?.items.first?.submenu?.items.first { $0.title == "Services" }?.submenu
            check(services != nil && services === NSApp.servicesMenu, "parityk05 (\(tag)): the app menu has Services, the Mac's own (NSApp.servicesMenu)")
            c.closeFind(refocusPage: false)
        }
        /// The engine's own view of the page (WebKit's WKWebView, Chromium's render widget view), made the window's first
        /// responder as a click into the page makes it: Services asks the first responder's chain.
        func engineView() -> NSView? {
            guard let p = page() else { return nil }
            if let web = (p as? WebKitTab)?.webView { return web }
            func find(_ v: NSView) -> NSView? {
                if NSStringFromClass(type(of: v)).contains("RenderWidgetHostView") { return v }
                for s in v.subviews { if let hit = find(s) { return hit } }
                return nil
            }
            return find(p.view)
        }
        var serviceTook = false
        /// What Services gets from the first responder's chain, as AppKit asks it: any object, sent the requestor's
        /// methods by selector (AppKit never needs the protocol declared, and the engines' views don't all declare it).
        func requestor(send: NSPasteboard.PasteboardType, back: NSPasteboard.PasteboardType?) -> NSObject? {
            let first = c.window.firstResponder
            // As AppKit asks: each registered type in turn (Chromium answers the modern one, WebKit the legacy one).
            let legacy = NativeEditingMenus.legacyString
            let raw = (first?.validRequestor(forSendType: send, returnType: back)
                ?? first?.validRequestor(forSendType: legacy, returnType: back.map { _ in legacy })) as? NSObject
            note("parityk05 (\(tag)): first responder \(first.map { NSStringFromClass(type(of: $0)) } ?? "none"), engine view "
                 + "\(engineView().map { NSStringFromClass(type(of: $0)) } ?? "none"), its requestor \(raw.map { NSStringFromClass(type(of: $0)) } ?? "none"), "
                 + "window key \(c.window.isKeyWindow), app active \(NSApp.isActive)")
            return raw
        }
        func write(_ r: NSObject?, _ pb: NSPasteboard) -> Bool {
            let sel = NSSelectorFromString("writeSelectionToPasteboard:types:")
            guard let r, r.responds(to: sel) else { return false }
            typealias Write = @convention(c) (AnyObject, Selector, NSPasteboard, NSArray) -> Bool
            let types = [NSPasteboard.PasteboardType.string.rawValue, NativeEditingMenus.legacyString.rawValue] as NSArray
            return unsafeBitCast(r.method(for: sel), to: Write.self)(r, sel, pb, types)
        }
        func read(_ r: NSObject?, _ pb: NSPasteboard) -> Bool {
            let sel = NSSelectorFromString("readSelectionFromPasteboard:")
            guard let r, r.responds(to: sel) else { return false }
            typealias Read = @convention(c) (AnyObject, Selector, NSPasteboard) -> Bool
            return unsafeBitCast(r.method(for: sel), to: Read.self)(r, sel, pb)
        }
        // The find session ends first (its last match is the page's selection until then); the page has the keyboard before
        // the selection is made, as when a person selects text: Chromium's view learns a selection from a focused page.
        wait(0.8)
        run { [self] in if let v = engineView() { c.window.makeFirstResponder(v) }; page()?.focus() }
        wait(0.5)
        js("(function () { var r = document.createRange(); r.selectNodeContents(document.getElementById('plain')); var s = getSelection(); s.removeAllRanges(); s.addRange(r); return true })()")
        wait(0.8)
        run { [self] in
            let req = requestor(send: .string, back: nil)
            let pb = NSPasteboard(name: .init("org.airc.check.parityk05"))
            pb.clearContents()
            let wrote = write(req, pb)
            let text = pb.string(forType: .string) ?? ""
            // Every engine view has the requestor's methods (AppKit sends them by selector).
            let methods = ["validRequestorForSendType:returnType:", "writeSelectionToPasteboard:types:", "readSelectionFromPasteboard:"]
            let view = engineView()
            check(view != nil && methods.allSatisfy { view!.responds(to: NSSelectorFromString($0)) },
                  "parityk05 (\(tag)): the page view (\(view.map { NSStringFromClass(type(of: $0)) } ?? "none")) is a Services requestor: validRequestor, writeSelection, readSelection")
            if c.window.isKeyWindow {
                check(req != nil && wrote && text == "findme in plain text", "parityk05 (\(tag)): the page view hands a service its selection (\(text))")
            } else if req != nil {
                check(wrote && !text.isEmpty, "parityk05 (\(tag)): the page view hands a service the page's selection (\(text))")
                if text != "findme in plain text" {
                    skip("parityk05 (\(tag)): the exact selected text: an engine updates the selection it reports with the window's drawing, and this run's window isn't key (open -g); it gave \"\(text)\"")
                }
            } else {
                skip("parityk05 (\(tag)): the page view hands a service its selection: this engine learns a page's selection only in the key window, and this run's window isn't key (launched with open -g)")
            }
        }
        run { [self] in if let v = engineView() { c.window.makeFirstResponder(v) }; page()?.focus() }
        wait(0.5)
        js("(function () { var e = document.getElementById('name'); e.focus(); e.setSelectionRange(6, 11); return true })()")
        wait(0.8)
        run { [self] in
            let req = requestor(send: .string, back: .string)
            let pb = NSPasteboard(name: .init("org.airc.check.parityk05"))
            pb.clearContents()
            pb.setString("from a service", forType: .string)
            let took = read(req, pb)
            if req == nil && !c.window.isKeyWindow {
                skip("parityk05 (\(tag)): an editable selection takes a service's text back: this engine learns the page's selection only in the key window, and this run's window isn't key")
            } else {
                check(req != nil && took, "parityk05 (\(tag)): an editable selection takes a service's text back (requestor \(req != nil), read \(took))")
            }
            serviceTook = took
        }
        step { [self] done in
            guard serviceTook else { return done() }
            page()?.evaluate("document.getElementById('name').value") { v in
                self.check((v as? String) == "Hello from a service world FOUND", "parityk05 (\(tag)): …into the field (\(v ?? "nil"))")
                done()
            }
        }

        run {
            server?.stop()
            NSPasteboard(name: .init("org.airc.check.parityk05")).releaseGlobally()
        }
    }
}
#endif
