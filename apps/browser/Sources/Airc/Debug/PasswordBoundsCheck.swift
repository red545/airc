// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING && canImport(AircCore)
import AppKit
import AircKit

extension SnapshotRunner {
    /// Geometry-only regression: no HID input, app activation, capture, or real credentials.
    /// CDP measures the DOM independently; the picker MUST use the engine's bounds, even under CSP.
    func passwordBoundsScenario() {
        guard let engine = app?.engine as? ChromiumEngine else { return }
        var server: LocalPageServer?
        var base = "", tabID = ""
        let page = { self.c.engineTab(for: tabID) }
        let picker = { self.c.prompts.passwords }
        let form = """
            <form action="/submitted" method="post">
            <input id="username" name="username" autocomplete="username">
            <input id="password" name="password" type="password" autocomplete="current-password">
            <button id="submit">Sign in</button></form>
            """
        let style = "<style>body{margin:0}form{margin:80px 60px}input{display:block;box-sizing:border-box;width:260px;height:36px;margin:16px 0}</style>"
        step { [self] done in
            server = LocalPageServer(responses: [
                "/login": .init(body: "<title>login</title>" + style + form),
                "/csp": .init(headers: ["Content-Security-Policy": "script-src 'none'"],
                              body: "<title>csp</title>" + style + form + "<script>document.title='CSP FAILED'</script>"),
                "/scrolled": .init(body: "<title>scrolled</title>" + style + "<div style='height:700px'></div>" + form + "<div style='height:1500px'></div>"),
                "/iframe": .init(body: "<title>iframe</title><iframe id='frame' src='/login' style='position:absolute;left:91px;top:67px;width:500px;height:400px;border:7px solid gray'></iframe>"),
                "/submitted": .init(body: "<title>submitted</title>Saved fixture")
            ])
            guard let server else { check(false, "pwbounds: server created"); return done() }
            server.start { port in
                if let port { base = "http://127.0.0.1:\(port)" }
                self.check(port != nil, "pwbounds: loopback server started")
                done()
            }
        }
        func open(_ path: String, title: String) {
            run { [self] in
                guard let t = try? c.store.openTab(url: base + path, inSpace: c.currentSpaceID, title: title) else { return }
                tabID = t.id
                c.reloadAll(animated: false)
                c.show(t.id, focus: false)
            }
            step { [self] done in
                waitUntil({ page()?.title == title && page()?.isLoading == false }, timeout: 8) {
                    self.check(page()?.title == title, "pwbounds: \(title) loaded")
                    done()
                }
            }
            wait(0.5)
        }
        func js(_ expression: String) {
            step { [self] done in
                guard let p = page() else { check(false, "pwbounds: page exists"); return done() }
                engine.devToolsCall("Runtime.evaluate", params: ["expression": expression, "userGesture": true, "returnByValue": true], in: p) { reply, error in
                    self.check(error == nil && reply?["exceptionDetails"] == nil, "pwbounds: fixture action")
                    done()
                }
            }
        }
        open("/login", title: "login")
        for (id, text) in [("username", "airc-bounds-fixture"), ("password", "Only-A-Bounds-Fixture-42!")] {
            js("document.getElementById('\(id)').focus()")
            step { done in
                guard let p = page() else { return done() }
                engine.devToolsCall("Input.insertText", params: ["text": text], in: p) { _, _ in done() }
            }
        }
        js("document.getElementById('submit').click()")
        step { [self] done in
            waitUntil({ page().map { engine.passwordPrompt(for: $0)?["state"] as? String == "save" } ?? false }, timeout: 8) {
                guard let p = page() else { return done() }
                self.check(engine.passwordPrompt(for: p)?["state"] as? String == "save", "pwbounds: synthetic login offered for save")
                engine.resolvePasswordPrompt(in: p, action: "save")
                done()
            }
        }
        wait(0.7)

        func measure(_ name: String, iframe: Bool = false) {
            var expected = NSRect.zero
            // Read the field independently of PasswordChoice, including the iframe's border and page zoom.
            let doc = iframe ? "document.getElementById('frame').contentDocument" : "document"
            js("var d=\(doc); d.getElementById('username').value=''; d.getElementById('password').value=''; d.getElementById('username').focus()")
            step { [self] done in
                guard let p = page() else { return done() }
                let offset = iframe ? "var f=document.getElementById('frame'),b=f.getBoundingClientRect();x+=b.x+f.clientLeft;y+=b.y+f.clientTop;" : ""
                engine.devToolsCall("Runtime.evaluate", params: ["expression": "(()=>{var r=(\(doc)).getElementById('username').getBoundingClientRect();var x=r.x,y=r.y;\(offset)return [x,y,r.width,r.height]})()", "returnByValue": true], in: p) { reply, _ in
                    guard let v = (reply?["result"] as? [String: Any])?["value"] as? [Double], v.count == 4 else {
                        self.check(false, "pwbounds: \(name) independent field measurement"); return done()
                    }
                    let zoom = (p as? EnginePageCommands)?.zoomFactor ?? 1
                    expected = NSRect(x: v[0]*zoom, y: v[1]*zoom, width: v[2]*zoom, height: v[3]*zoom)
                    // CDP input takes CSS pixels and applies browser zoom itself. Geometry above is in DIPs.
                    // Tab-scoped input only: no hardware event injection or focus-taking.
                    let params: [String: Any] = ["type": "mousePressed", "x": v[0]+v[2]/2, "y": v[1]+v[3]/2, "button": "left", "clickCount": 1]
                    engine.devToolsCall("Input.dispatchMouseEvent", params: params, in: p) { _, _ in
                        var up = params; up["type"] = "mouseReleased"
                        engine.devToolsCall("Input.dispatchMouseEvent", params: up, in: p) { _, _ in done() }
                    }
                }
            }
            wait(0.4)
            step { [self] done in
                if picker().view == nil, let p = page() { engine.showAutofillSuggestions(in: p, passwords: true) }
                waitUntil({ picker().view != nil }, timeout: 5) { done() }
            }
            wait(0.2)
            run { [self] in
                guard let p = page(), let view = picker().view, let actual = picker().choices.first?.fieldRect else {
                    return check(false, "pwbounds: \(name) engine bounds and saved-password list present (source \(picker().anchorSource))")
                }
                let error = max(abs(actual.minX-expected.minX), abs(actual.minY-expected.minY), abs(actual.width-expected.width), abs(actual.height-expected.height))
                check(picker().anchorSource == "engine" && error <= 2,
                      "pwbounds: \(name) field within 2 pt; engine \(NSStringFromRect(actual)), DOM \(NSStringFromRect(expected)), error \(error)")
                let local = p.view.isFlipped ? expected : NSRect(x: expected.minX, y: p.view.bounds.height-expected.maxY, width: expected.width, height: expected.height)
                let field = c.root.convert(local, from: p.view)
                let dx = abs(view.frame.minX-field.minX), dy = abs(view.frame.minY-field.maxY-PasswordPicker.gap)
                check(dx <= 2 && dy <= 2, "pwbounds: \(name) list under field within 2 pt; list \(NSStringFromRect(view.frame)), field \(NSStringFromRect(field)), delta \(dx),\(dy)")
                check(picker().choices.contains { $0.username == "airc-bounds-fixture" }, "pwbounds: \(name) saved scratch login offered")
                engine.hideAutofillSuggestions(in: p)
            }
        }
        open("/login", title: "login")
        measure("normal")
        open("/csp", title: "csp")
        measure("strict CSP")
        run { [self] in check(page()?.title == "csp", "pwbounds: CSP blocked inline script") }
        open("/iframe", title: "iframe")
        measure("iframe", iframe: true)
        open("/login", title: "login")
        run { (page() as? EnginePageCommands)?.zoom(step: 1); (page() as? EnginePageCommands)?.zoom(step: 1) }
        wait(0.5)
        run { [self] in check(abs(((page() as? EnginePageCommands)?.zoomFactor ?? 0)-1.25) < 0.01, "pwbounds: actual browser zoom is 125%") }
        measure("125% zoom")
        run { (page() as? EnginePageCommands)?.zoom(step: 0) }
        open("/scrolled", title: "scrolled")
        js("window.scrollTo(0,650)")
        wait(0.4)
        measure("scrolled")
        open("/login", title: "login")
        var original = NSRect.zero
        run { [self] in
            original = c.window.frame
            if let second = NSScreen.screens.first(where: { $0.backingScaleFactor != c.window.backingScaleFactor }) {
                c.window.setFrameOrigin(NSPoint(x: second.visibleFrame.minX+30, y: second.visibleFrame.minY+30))
                note("pwbounds: moved scratch window to display with scale \(second.backingScaleFactor)")
            } else {
                skip("pwbounds: second display with a different scale is not connected; checking a moved window on the available display")
                c.window.setFrameOrigin(NSPoint(x: original.minX+47, y: original.minY+31))
            }
        }
        wait(0.5)
        measure("moved window")
        run { [self] in c.window.setFrame(original, display: true); server?.stop() }
    }
}
#endif
