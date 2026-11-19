// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import WebKit
#if canImport(AircCore)
import AircCore
#endif

/// `--script devtools [--remote-debugging-port=<scratch port>]`: DevTools docked in the window they inspect, as in
/// Chrome (Chromium) and Safari (WebKit's Web Inspector attached). Fixture pages on loopback only.
/// Chromium cases: ⌥⌘I opens DevTools docked in the page's own card (not another window); the ⋮ menu's Dock side
/// buttons; every panel's tab, clicked, shows that panel with content (root view size > 0, a non-blank picture);
/// the splitter drag; ⌘⇧D; the tab strip's » at the narrow right dock; light and dark pictures; undock to a window and
/// dock again; DevTools follow the tab (switch away and back); a split's focused pane; Little Airc; the agent pane
/// beside them; ⌥⌘J (Console), ⌥⌘C (element picker) and ⌥⌘I (close).
/// WebKit cases: ⌥⌘I attaches Web Inspector to the window; each Inspector tab, clicked, shows its content; dock to
/// right / bottom; follows the tab; closes.
/// Real driver keys and clicks with the UI driver in a dedicated session (`AIRC_REAL_KEYS=1`, `AIRC_LA_AS_OWNER=1`);
/// otherwise the cases that need them are skipped, and said so. The frontend is read over the scratch process's own
/// remote-debugging port (Chromium) or by script in the Inspector's page (WebKit).
extension SnapshotRunner {
    func devToolsDockScenario() {
        MainActor.assumeIsolated {
            let k = DevToolsDockCheck(runner: self)
            for body in k.cases { step { done in Task { @MainActor in await body(); done() } } }
            run { MainActor.assumeIsolated { k.finish() } }
        }
    }
}

extension SnapshotRunner {
    /// The card's picture with DevTools docked in it: the frontend's picture over the whole card, the page's in its own
    /// rect. False (nothing called) when the page has no docked DevTools.
    func dockedDevToolsPicture(_ page: EngineTab, _ done: @escaping (NSImage?) -> Void) -> Bool {
        #if canImport(AircCore)
        guard let t = page as? ChromiumTab, let tools = t.core.devToolsView, let host = t.core.view.superview,
              tools.superview === host, !tools.isHidden else { return false }
        let size = host.bounds.size
        let pageRect = t.core.view.frame   // host coordinates
        t.core.copyDevToolsPicture(5) { frontend in
            page.snapshot { shot in
                let out = NSImage(size: size)
                out.lockFocus()
                if let frontend { NSImage(cgImage: frontend, size: size).draw(in: NSRect(origin: .zero, size: size)) }
                // Image space isn't flipped; a flipped host's rect is mirrored.
                let r = host.isFlipped ? NSRect(x: pageRect.minX, y: size.height - pageRect.maxY, width: pageRect.width, height: pageRect.height) : pageRect
                shot?.draw(in: r)
                out.unlockFocus()
                done(out)
            }
        }
        return true
        #else
        return false
        #endif
    }
}

@MainActor
final class DevToolsDockCheck {
    unowned let runner: SnapshotRunner
    var app: AppDelegate { runner.app! }
    var c: WindowController { runner.c }
    var engine = "?"
    var real = false
    var server: LocalPageServer?
    var base = ""
    var tabA = "", tabB = ""
    init(runner: SnapshotRunner) { self.runner = runner }

    var isWebKit: Bool { app.engine is WebKitEngine }
    var cases: [() async -> Void] {
        var list: [() async -> Void] = [setUp]
        #if canImport(AircCore)
        if !isWebKit {
            list += [chromiumOpen, chromiumDockMenu, chromiumPanels, chromiumContextMenus, chromiumSplitter, chromiumToggleSide, chromiumOverflow,
                     chromiumDark, chromiumUndock, chromiumFollowTab, chromiumShortcuts, chromiumSplit, chromiumLittle,
                     chromiumAgentPane, chromiumClose]
        }
        #endif
        if isWebKit { list += [webKitOpen, webKitTabs, webKitSides, webKitFollowTab, webKitClose] }
        return list
    }

    // MARK: Helpers

    func note(_ s: String) { runner.note(s) }
    func check(_ ok: Bool, _ what: String) { note((ok ? "PASS " : "FAIL ") + "devtools \(engine): " + what) }
    func skip(_ what: String) { note("SKIP devtools \(engine): " + what) }
    func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
    @discardableResult func until(_ timeout: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return true }; await sleep(0.05) }
        return cond()
    }
    func driver(_ args: [String]) async -> (Bool, String) {
        await withCheckedContinuation { k in UIDriverClient.run(args) { ok, out in k.resume(returning: (ok, out)) } }
    }
    /// A real key press to this app (PID-targeted, foreground only).
    @discardableResult func key(_ combo: String) async -> Bool {
        let (ok, out) = await driver(["--key", combo, "--pid", "\(getpid())"])
        if !ok { note("devtools \(engine): driver --key \(combo): \(out)") }
        await sleep(0.25)
        return ok
    }
    /// Quartz global top-left points for a point in `window`.
    func global(_ p: NSPoint, in window: NSWindow) -> CGPoint {
        let s = window.convertPoint(toScreen: p)
        return CGPoint(x: s.x.rounded(), y: ((NSScreen.screens.first?.frame.maxY ?? 0) - s.y).rounded())
    }
    @discardableResult func click(_ p: NSPoint, in window: NSWindow) async -> Bool {
        let g = global(p, in: window)
        let (ok, out) = await driver(["--click", "\(Int(g.x))", "\(Int(g.y))"])
        if !ok { note("devtools \(engine): driver --click: \(out)") }
        await sleep(0.3)
        return ok
    }
    @discardableResult func drag(_ a: NSPoint, _ b: NSPoint, in window: NSWindow) async -> Bool {
        let ga = global(a, in: window), gb = global(b, in: window)
        let (ok, out) = await driver(["--drag", "\(Int(ga.x))", "\(Int(ga.y))", "\(Int(gb.x))", "\(Int(gb.y))"])
        if !ok { note("devtools \(engine): driver --drag: \(out)") }
        await sleep(0.4)
        return ok
    }
    /// A point given in a view's top-left coordinates (CSS pixels of the page it shows), in its window.
    func windowPoint(_ x: Double, _ y: Double, in view: NSView) -> NSPoint {
        let p = view.isFlipped ? NSPoint(x: x, y: y) : NSPoint(x: x, y: view.bounds.height - y)
        return view.convert(p, to: nil)
    }
    func front() async -> Bool {
        guard real else { return false }
        NSApp.activate(ignoringOtherApps: true)
        c.window.makeKeyAndOrderFront(nil)
        return await until(6) { NSApp.isActive && self.c.window.isKeyWindow }
    }
    var page: EngineTab? { c.shownTabID.flatMap { c.engineTab(for: $0) } }
    /// Top-left rect of `v` in `host`.
    func tl(_ r: NSRect, in host: NSView) -> NSRect {
        host.isFlipped ? r : NSRect(x: r.minX, y: host.bounds.height - r.maxY, width: r.width, height: r.height)
    }
    func fmt(_ r: NSRect) -> String { String(format: "%.0f,%.0f %.0f×%.0f", r.minX, r.minY, r.width, r.height) }

    /// A picture's spread: distinct colours on a 24×24 grid (a blank frame has 1–2).
    static func colours(_ image: CGImage?) -> Int {
        guard let image else { return 0 }
        let w = 24, h = 24
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var set = Set<UInt32>()
        for i in stride(from: 0, to: px.count, by: 4) {
            set.insert(UInt32(px[i] >> 3) << 10 | UInt32(px[i + 1] >> 3) << 5 | UInt32(px[i + 2] >> 3))
        }
        return set.count
    }

    /// The window as drawn: our views, then each page and frontend picture in its own rect (fixture pages only).
    func picture(_ name: String, parts: [(NSView, CGImage?)]) {
        let root = c.root
        root.layoutSubtreeIfNeeded()
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: rep)
        let size = root.bounds.size
        let out = NSImage(size: size)
        out.lockFocus()
        rep.draw(in: NSRect(origin: .zero, size: size))
        // Largest first: a docked frontend fills the card, and the page sits on top of it.
        for (view, image) in parts.sorted(by: { $0.0.bounds.width * $0.0.bounds.height > $1.0.bounds.width * $1.0.bounds.height }) {
            guard let image else { continue }
            let r = root.convert(view.convert(view.bounds, to: nil), from: nil)
            let flipped = NSRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height)
            NSImage(cgImage: image, size: r.size).draw(in: root.isFlipped ? flipped : r)
        }
        out.unlockFocus()
        if let tiff = out.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff), let png = bmp.representation(using: .png, properties: [:]) {
            try? png.write(to: runner.dir.appendingPathComponent(name + ".png"))
            note("wrote \(name).png")
        }
    }
    func snapshot(_ tab: EngineTab?) async -> CGImage? {
        guard let tab else { return nil }
        let image: NSImage? = await withCheckedContinuation { k in tab.snapshot { k.resume(returning: $0) } }
        return image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    // MARK: Set up

    static func fixture(_ title: String, _ color: String) -> String {
        """
        <!doctype html><title>\(title)</title><style>body{font:15px -apple-system;margin:0;padding:24px;background:\(color)}
        .card{border:1px solid #ccc;border-radius:8px;padding:12px;margin:8px 0;background:#fff}</style>
        <h1 id=target>\(title)</h1><div class=card id=card>A fixture page for DevTools.</div>
        <ul>\((1...12).map { "<li>Item \($0)</li>" }.joined())</ul>
        <script>console.log('devtools-fixture \(title)'); localStorage.setItem('devtools-fixture','1');
        fetch('/data.json').then(r => r.json()).then(d => console.log('fetched', d.ok));</script>
        """
    }

    func setUp() async {
        engine = isWebKit ? "webkit" : "chromium"
        let env = ProcessInfo.processInfo.environment
        real = UIDriverClient.available && env["AIRC_UI_DEDICATED_SESSION"] == "1" && env["AIRC_LA_AS_OWNER"] == "1"
        note("devtools \(engine): input \(real ? "real (UI driver)" : "none (posted runs skip the real-input cases)")")
        let s = LocalPageServer(pages: ["/a": Self.fixture("DevTools A", "#f4f7fb"), "/b": Self.fixture("DevTools B", "#fbf4f4"),
                                        "/data.json": "{\"ok\":true}"])
        server = s
        let port: UInt16? = await withCheckedContinuation { k in
            guard let s else { return k.resume(returning: nil) }
            s.start { k.resume(returning: $0) }
        }
        base = port.map { "http://127.0.0.1:\($0)" } ?? ""
        check(!base.isEmpty, "fixture server on loopback")
        let profile = c.store.profile(ofSpace: c.currentSpaceID)
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            app.profiles.whenLoaded(profile.id, { _ in k.resume() }, failed: { k.resume() })
        }
        // A wide window, so every panel's tab fits at the bottom dock.
        if let screen = c.window.screen?.visibleFrame {
            let w = min(1500, screen.width - 160), h = min(940, screen.height - 160)
            c.window.setFrame(NSRect(x: screen.minX + 80, y: screen.minY + 80, width: w, height: h), display: true)
        }
        c.navigate(to: URL(string: base + "/b")!, newTab: true)
        await until(8) { self.page?.title == "DevTools B" && self.page?.isLoading == false }
        tabB = c.shownTabID ?? ""
        c.navigate(to: URL(string: base + "/a")!, newTab: true)
        await until(8) { self.page?.title == "DevTools A" && self.page?.isLoading == false }
        tabA = c.shownTabID ?? ""
        check(!tabA.isEmpty && !tabB.isEmpty && tabA != tabB, "two fixture tabs (A shown)")
        if real { check(await front(), "the window is key for real input") }
    }

    // MARK: Chromium

    #if canImport(AircCore)
    var chromium: ChromiumTab? { page as? ChromiumTab }
    func tools(_ t: ChromiumTab?) -> NSView? { t?.core.devToolsView }

    struct Layout { var host = NSRect.zero, page = NSRect.zero, tools = NSRect.zero; var inWindow = false, sameHost = false
        var side: String {
            guard inWindow, sameHost else { return "none" }
            if page.width < host.width - 40, page.minX < 2 { return "right" }
            if page.width < host.width - 40, page.minX > 40 { return "left" }
            if page.height < host.height - 40, page.minY < 2 { return "bottom" }
            return "full"
        }
    }
    func layout(_ t: ChromiumTab?, in window: NSWindow? = nil) -> Layout {
        var l = Layout()
        guard let t, let host = t.core.view.superview, let tv = tools(t) else { return l }
        l.host = host.bounds
        l.page = tl(t.core.view.frame, in: host)
        l.inWindow = tv.window === (window ?? c.window) && tv.window != nil && !tv.isHiddenOrHasHiddenAncestor
        l.sameHost = tv.superview === host
        if l.sameHost { l.tools = tl(tv.frame, in: host) }
        return l
    }
    func describe(_ t: ChromiumTab?) -> String {
        let l = layout(t)
        var place = "no window"
        if let w = tools(t)?.window { place = w === c.window ? "the page's window" : "another window \"" + w.title + "\" " + fmt(w.frame) }
        return "side \(l.side), host \(fmt(l.host)), page \(fmt(l.page)), frontend \(fmt(l.tools)) in " + place
    }

    /// Bounded CDP evaluation in the DevTools frontend (the scratch process's own remote-debugging port).
    func frontend(_ expression: String) async -> Any? {
        guard let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--remote-debugging-port=") }),
              let port = Int(flag.split(separator: "=").last ?? "") else {
            note("FAIL-ENV devtools \(engine): the frontend read needs --remote-debugging-port"); return nil
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/json/version")!)
            guard let info = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ws = (info["webSocketDebuggerUrl"] as? String).flatMap(URL.init(string:)) else { return nil }
            let socket = URLSession.shared.webSocketTask(with: ws)
            socket.resume()
            let timeout = DispatchWorkItem { socket.cancel(with: .goingAway, reason: nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
            defer { timeout.cancel(); socket.cancel(with: .goingAway, reason: nil) }
            var serial = 0
            func call(_ method: String, _ params: [String: Any], session: String? = nil) async throws -> [String: Any] {
                serial += 1; let id = serial
                var message: [String: Any] = ["id": id, "method": method, "params": params]
                if let session { message["sessionId"] = session }
                try await socket.send(.string(String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)))   // CDP takes text frames only
                while true {
                    let response = try await socket.receive()
                    let bytes: Data
                    switch response { case .string(let text): bytes = Data(text.utf8); case .data(let d): bytes = d; @unknown default: continue }
                    guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { continue }
                    if object["id"] as? Int == id { return object["result"] as? [String: Any] ?? object }
                }
            }
            let targets = try await call("Target.getTargets", ["filter": [[:]]])
            // The frontend's page target ("other"); its "tab" target has no Runtime domain.
            let list = (targets["targetInfos"] as? [[String: Any]] ?? []).filter {
                ($0["url"] as? String)?.hasPrefix("devtools://") == true && $0["type"] as? String != "tab" }
            guard let id = list.last?["targetId"] as? String else { return nil }
            let attached = try await call("Target.attachToTarget", ["targetId": id, "flatten": true])
            let reply = try await call("Runtime.evaluate", ["expression": expression, "returnByValue": true, "awaitPromise": true],
                                       session: attached["sessionId"] as? String)
            if let ex = reply["exceptionDetails"] { note("devtools \(engine): frontend script threw: \(ex)") }
            return (reply["result"] as? [String: Any])?["value"]
        } catch { note("devtools \(engine): frontend read: \(error)"); return nil }
    }
    /// Shared frontend helpers: deep queries through shadow roots, rects in CSS pixels.
    static let js = """
    const UI = await import('./ui/legacy/legacy.js');
    const deep = (root, sel, out = []) => { for (const e of root.querySelectorAll('*')) { if (e.matches(sel)) out.push(e); if (e.shadowRoot) deep(e.shadowRoot, sel, out); } return out; };
    const rect = e => { const b = e.getBoundingClientRect(); return [b.x, b.y, b.width, b.height]; };
    const tp = UI.InspectorView.InspectorView.instance().tabbedPane;
    """
    /// The main tab strip: each visible tab's rect, the selected one, and the » button's rect (if shown).
    func strip() async -> (tabs: [String: [Double]], ids: [String], selected: String, more: [Double]?)? {
        let v = await frontend("(async () => {\(Self.js)" + """
          const header = tp.headerElement();
          const tabs = {};
          for (const e of header.querySelectorAll('.tabbed-pane-header-tab')) { const r = rect(e); if (r[2] > 0 && r[3] > 0) tabs[e.id.replace(/^tab-/, '')] = r; }
          const more = header.querySelector('.tabbed-pane-header-tabs-drop-down-container');
          const mr = more ? rect(more) : null;
          return {tabs, ids: tp.tabIds(), selected: tp.selectedTabId, more: mr && mr[2] > 0 && !more.classList.contains('hidden') ? mr : null};
        })()
        """) as? [String: Any]
        guard let v else { return nil }
        return ((v["tabs"] as? [String: [Double]]) ?? [:], (v["ids"] as? [String]) ?? [], (v["selected"] as? String) ?? "", v["more"] as? [Double])
    }
    /// The selected panel's root view: its size and how many elements it has (shadow roots too).
    func panelState() async -> (id: String, w: Double, h: Double, elements: Int)? {
        let v = await frontend("(async () => {\(Self.js)" + """
          const view = tp.visibleView; if (!view) return {id: tp.selectedTabId, w: 0, h: 0, n: 0};
          const r = rect(view.element);
          return {id: tp.selectedTabId, w: r[2], h: r[3], n: deep(view.element, '*').length};
        })()
        """) as? [String: Any]
        guard let v else { return nil }
        return ((v["id"] as? String) ?? "", (v["w"] as? Double) ?? 0, (v["h"] as? Double) ?? 0, (v["n"] as? Int) ?? 0)
    }
    /// Rect of the first element (deep) matching `selector`, optionally with exact trimmed text.
    func element(_ selector: String, text: String? = nil) async -> [Double]? {
        let sel = String(data: try! JSONSerialization.data(withJSONObject: [selector, text ?? ""]), encoding: .utf8)!
        return await frontend("(async () => {\(Self.js)" + """
          const [sel, text] = \(sel);
          const e = deep(document, sel).find(e => { const r = rect(e); return r[2] > 0 && r[3] > 0 && (!text || e.textContent.trim() === text); });
          return e ? rect(e) : null;
        })()
        """) as? [Double]
    }
    func clickFrontend(_ r: [Double], tools tv: NSView) async -> Bool {
        guard r.count == 4, let w = tv.window else { return false }
        return await click(windowPoint(r[0] + r[2] / 2, r[1] + r[3] / 2, in: tv), in: w)
    }
    func devToolsPicture(_ t: ChromiumTab?) async -> CGImage? {
        guard let t else { return nil }
        return await withCheckedContinuation { k in t.core.copyDevToolsPicture(5) { k.resume(returning: $0) } }
    }

    func chromiumOpen() async {
        guard real else { return skip("⌥⌘I needs real keys") }
        let t = chromium
        // DevTools remember their side per profile: start at the default with a scratch profile.
        check(await key("cmd+opt+i"), "⌥⌘I pressed (real key, PID-targeted)")
        let opened = await until(8) { self.tools(t) != nil && self.layout(t).inWindow }
        note("devtools \(engine): after ⌥⌘I: \(describe(t))")
        check(opened, "⌥⌘I opens DevTools docked in the page's own window")
        let l = layout(t)
        check(l.sameHost && l.tools == l.host && ["right", "bottom", "left"].contains(l.side),
              "the frontend fills the page's card and the page sits beside it (\(l.side))")
        let w = tools(t)?.window
        check(w === c.window && NSApp.windows.filter({ $0.isVisible && $0.title == "Developer Tools" }).isEmpty,
              "no separate Developer Tools window")
    }

    /// ⋮ › Dock side › Dock to bottom (the frontend's own menu), with real clicks.
    func dock(_ label: String) async -> Bool {
        guard let t = chromium, let tv = tools(t) else { return false }
        guard let menu = await element("[aria-label=\"Customize and control DevTools\"]") else {
            note("devtools \(engine): no ⋮ button found"); return false }
        guard await clickFrontend(menu, tools: tv) else { return false }
        await sleep(0.4)
        var found = await element("[aria-label=\"\(label)\"]")
        if found == nil { found = await element("[title=\"\(label)\"]") }
        guard let button = found else {
            note("devtools \(engine): the ⋮ menu has no \"\(label)\""); _ = await key("escape"); return false }
        return await clickFrontend(button, tools: tv)
    }

    func chromiumDockMenu() async {
        guard real, let t = chromium, tools(t) != nil else { return skip("dock menu: DevTools aren't docked") }
        let right = await dock("Dock to right")
        let r = await until(3) { self.layout(t).side == "right" }
        check(right && r, "⋮ › Dock side › Dock to right (real clicks): \(describe(t))")
        let bottom = await dock("Dock to bottom")
        let b = await until(3) { self.layout(t).side == "bottom" }
        check(bottom && b, "⋮ › Dock side › Dock to bottom (real clicks): \(describe(t))")
    }

    static let panels: [(id: String, name: String)] = [("elements", "Elements"), ("console", "Console"), ("sources", "Sources"),
        ("network", "Network"), ("timeline", "Performance"), ("heap-profiler", "Memory"), ("resources", "Application"),
        ("security", "Security"), ("lighthouse", "Lighthouse")]

    func chromiumPanels() async {
        guard real, let t = chromium, let tv = tools(t) else { return skip("panels: DevTools aren't docked") }
        guard let s = await strip() else { return check(false, "the frontend's tab strip can be read") }
        note("devtools \(engine): tab strip ids \(s.ids), visible \(s.tabs.keys.sorted()), » \(s.more != nil)")
        for (id, name) in Self.panels {
            guard s.ids.contains(id) else {
                if id == "lighthouse" { skip("\(name): this build's DevTools have no \(name) panel") } else { check(false, "\(name): the tab strip has it") }
                continue
            }
            var clicked = false
            if let r = (await strip())?.tabs[id] { clicked = await clickFrontend(r, tools: tv) }
            else if let more = (await strip())?.more, await clickFrontend(more, tools: tv) {
                // In the » menu (a soft menu in the frontend).
                await sleep(0.3)
                if let item = await element(".soft-context-menu-item", text: name) { clicked = await clickFrontend(item, tools: tv) }
            }
            await sleep(0.8)   // let it draw
            let p = await panelState()
            let pic = await devToolsPicture(t)
            let spread = Self.colours(pic)
            let w: Double = p?.w ?? 0, h: Double = p?.h ?? 0, n: Int = p?.elements ?? 0
            let selected: Bool = p?.id == id
            let sized: Bool = w > 100 && h > 50 && n > 10
            check(clicked && selected && sized && spread > 6,
                  "\(name): its tab, clicked, shows the panel (selected \(p?.id ?? "-"), root \(Int(w))×\(Int(h)), \(n) elements, picture \(spread) colours)")
            if id == "network" || id == "elements" {
                picture("devtools-chromium-panel-\(id)", parts: [(t.core.view, await snapshot(t)), (tv, pic)])
            }
        }
        _ = tv
    }

    /// Native menus in the docked frontend: a real ⌃-click (the driver has no right button) in Elements, Console and
    /// Sources opens Chrome's context menu with DevTools' own items; Esc closes it.
    func chromiumContextMenus() async {
        guard real, let t = chromium, let tv = tools(t) else { return skip("context menus: DevTools aren't docked") }
        menuTitles = nil
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { [weak self] n in
            guard let m = n.object as? NSMenu, m !== NSApp.mainMenu, m.supermenu == nil else { return }
            MainActor.assumeIsolated { self?.menuTitles = m.items.map(\.title).filter { !$0.isEmpty } }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        // Where to ⌃-click in each panel, and an item DevTools puts in that menu.
        let cases: [(id: String, name: String, target: String, item: String)] = [
            ("elements", "Elements", ".elements-disclosure li.selected", "Copy"),
            ("console", "Console", ".console-message-wrapper, #console-messages", "Clear console"),
            ("sources", "Sources", ".navigator-tabbed-pane .tree-outline li, .navigator-tabbed-pane", "")]
        for c in cases {
            if let r = (await strip())?.tabs[c.id] { _ = await clickFrontend(r, tools: tv) }
            await sleep(0.8)
            guard let r = await element(c.target), r.count == 4, let w = tv.window else { check(false, "\(c.name): something to ⌃-click in the panel"); continue }
            menuTitles = nil
            let g = global(windowPoint(r[0] + min(r[2], 120) / 2, r[1] + min(r[3], 16) / 2, in: tv), in: w)
            let (ok, out) = await driver(["--click", "\(Int(g.x))", "\(Int(g.y))", "--mods", "ctrl"])
            if !ok { note("devtools \(engine): driver ⌃-click: \(out)") }
            // Elements builds its menu after resolving the node: give it time.
            await until(8) { self.menuTitles != nil }
            let titles = menuTitles ?? []
            note("devtools \(engine): \(c.name) context menu: \(titles.prefix(12))")
            if menuTitles != nil { _ = await key("escape") }
            await sleep(0.4)
            check(ok && !titles.isEmpty && (c.item.isEmpty || titles.contains { $0.hasPrefix(c.item) }),
                  "\(c.name): a real ⌃-click opens DevTools' context menu (\(titles.count) items\(c.item.isEmpty ? "" : ", \"" + c.item + "\" among them"))")
        }
    }

    func chromiumSplitter() async {
        guard real, let t = chromium, let tv = tools(t), let host = t.core.view.superview, let w = host.window else { return skip("splitter: DevTools aren't docked") }
        let before = layout(t)
        guard before.side == "bottom" else { return check(false, "splitter: docked at the bottom first (\(before.side))") }
        // The frontend's own resizer between the page and DevTools (a wide, thin element at its top edge); else the top
        // edge right of the tabs.
        let resizer = await frontend("(async () => {\(Self.js) const r = deep(document, '[class*=\"resizer\"]').map(rect).filter(r => r[2] > 300 && r[3] > 0 && r[3] <= 16 && Math.abs(r[1] - \(Int(before.page.maxY))) < 24); return r[0] || null; })()") as? [Double]
        let resizerText = resizer.map { r in r.map { String(Int($0)) }.joined(separator: ",") } ?? "not found"
        note("devtools \(engine): splitter: resizer \(resizerText)")
        let x = resizer.map { $0[0] + $0[2] / 2 } ?? (before.host.width - 260)
        let y = resizer.map { $0[1] + $0[3] / 2 } ?? (before.page.maxY + 2)
        let a = windowPoint(x, y, in: host), b = windowPoint(x, y - 120, in: host)
        let dragged = await drag(a, b, in: w)
        let moved = await until(3) { self.layout(t).page.height < before.page.height - 80 }
        let after = layout(t)
        check(dragged && moved && after.side == "bottom",
              "the splitter drags (real drag): page \(Int(before.page.height)) → \(Int(after.page.height)) pt tall, DevTools \(Int(before.host.height - before.page.height)) → \(Int(after.host.height - after.page.height)) pt")
        picture("devtools-chromium-bottom-light", parts: [(t.core.view, await snapshot(t)), (tv, await devToolsPicture(t))])
    }

    func chromiumToggleSide() async {
        guard real, let t = chromium, let tv = tools(t) else { return skip("⌘⇧D: DevTools aren't docked") }
        // The keyboard in DevTools first (a click on the Console tab).
        if let r = (await strip())?.tabs["console"] { _ = await clickFrontend(r, tools: tv) }
        let from = layout(t).side
        check(ChromiumKeyboardProbe.devToolsHasKeyboard(c.window), "a click in DevTools gives them the keyboard")
        _ = await key("cmd+shift+d")
        let switched = await until(3) { let s = self.layout(t).side; return s != from && s != "none" && s != "full" }
        check(switched, "⌘⇧D in DevTools switches the dock side (\(from) → \(layout(t).side))")
        if layout(t).side != "right" { _ = await dock("Dock to right"); await until(3) { self.layout(t).side == "right" } }
        picture("devtools-chromium-right-light", parts: [(t.core.view, await snapshot(t)), (tv, await devToolsPicture(t))])
    }

    func chromiumOverflow() async {
        guard real, let t = chromium, let tv = tools(t) else { return skip("»: DevTools aren't docked") }
        // Narrow DevTools at the right: drag the resizer (its left edge) toward the right.
        let l = layout(t)
        if l.side == "right", let host = t.core.view.superview, let w = host.window, l.host.width - l.page.width > 420 {
            let x = l.page.maxX + 3
            _ = await drag(windowPoint(x, l.host.midY, in: host), windowPoint(l.host.width - 380, l.host.midY, in: host), in: w)
        }
        guard let s = await strip() else { return check(false, "»: the tab strip can be read") }
        check(s.more != nil && s.tabs.count < s.ids.count,
              "the tab strip shows » for the panels that don't fit (\(s.tabs.count) of \(s.ids.count) visible, DevTools \(Int(layout(t).host.width - layout(t).page.width)) pt wide)")
        // » opens Chrome's native menu (or DevTools' own soft menu): record a native one's items as it opens.
        menuTitles = nil
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { [weak self] n in
            guard let m = n.object as? NSMenu, m !== NSApp.mainMenu, m.supermenu == nil else { return }
            MainActor.assumeIsolated { self?.menuTitles = m.items.map(\.title) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let hidden = Self.panels.first { s.ids.contains($0.id) && s.tabs[$0.id] == nil }
        if let more = s.more, let hidden, await clickFrontend(more, tools: tv) {
            await until(3) { self.menuTitles != nil }
            if let titles = menuTitles {
                // A native menu: choose the item with real keys (type-select, then Return).
                note("devtools \(engine): » menu (native): \(titles)")
                for k in UIDriverClient.keys(typing: hidden.name) ?? [] { _ = await key(k) }
                _ = await key("return")
                await sleep(0.8)
                let p = await panelState()
                check(titles.contains(hidden.name) && p?.id == hidden.id,
                      "» lists the hidden panels (\(titles.count) items, \(hidden.name) among them), and choosing \(hidden.name) shows it (\(p?.id ?? "-"))")
            } else if let item = await element(".soft-context-menu-item", text: hidden.name) {
                let ok = await clickFrontend(item, tools: tv)
                await sleep(0.5)
                let p = await panelState()
                check(ok && p?.id == hidden.id, "» lists \(hidden.name), and choosing it shows that panel (\(p?.id ?? "-"))")
            } else { check(false, "» opens a list of the hidden panels (no menu appeared)"); _ = await key("escape") }
        }
    }
    var menuTitles: [String]?

    func chromiumDark() async {
        guard real, let t = chromium, let tv = tools(t) else { return skip("dark: DevTools aren't docked") }
        // macOS's appearance as the app sees it (the real setting is never touched), as darkfix does.
        let mode = app.settings.values.appearance
        AppAppearance.simulatedSystem = true
        AppAppearance.apply(mode)
        await sleep(1.5)
        let dark = await frontend("(async () => document.documentElement.classList.contains('theme-with-dark-background') || matchMedia('(prefers-color-scheme: dark)').matches)()") as? Bool
        note("devtools \(engine): dark appearance: frontend dark \(dark.map(String.init) ?? "?")")
        check(dark == true, "DevTools follow Airc's dark appearance")
        picture("devtools-chromium-right-dark", parts: [(t.core.view, await snapshot(t)), (tv, await devToolsPicture(t))])
        _ = await dock("Dock to bottom"); await until(3) { self.layout(t).side == "bottom" }
        picture("devtools-chromium-bottom-dark", parts: [(t.core.view, await snapshot(t)), (tv, await devToolsPicture(t))])
        AppAppearance.simulatedSystem = nil
        AppAppearance.apply(mode)
        await sleep(0.8)
    }

    func chromiumUndock() async {
        guard real, let t = chromium, let docked = tools(t) else { return skip("undock: DevTools aren't docked") }
        weak var view = docked
        let undocked = await dock("Undock into separate window")
        // Undocked, Chrome keeps only its device-mode toolbox in the tab (GetInTabWebContents), never the frontend.
        let gone = await until(5) { view?.window != nil && view?.window !== self.c.window && self.tools(t) !== view }
        let host = t.core.view.superview
        let fills = await until(2) { host.map { t.core.view.frame == $0.bounds } == true }
        check(undocked && gone && fills,
              "⋮ › Undock: DevTools move to their own window and the page fills its card again (clicked \(undocked), window \(view?.window.map { fmt($0.frame) } ?? "-"), page \(fmt(t.core.view.frame)))")
        check(t.isDevToolsOpen, "undocked DevTools still count as open")
        // Dock again from that window: ⌘⇧D with the keyboard in it (Chrome's "last docking position").
        if let w = view?.window, let v = view {
            w.makeKeyAndOrderFront(nil)
            await until(2) { w.isKeyWindow }
            if let r = (await strip())?.tabs["console"] { _ = await clickFrontend(r, tools: v) }
            _ = await key("cmd+shift+d")
        }
        let back = await until(5) { self.layout(t).inWindow && ["bottom", "right", "left"].contains(self.layout(t).side) }
        check(back, "⌘⇧D in the DevTools window docks them back into the page's window: \(describe(t))")
        if !back, view?.window != nil { _ = await dock("Dock to bottom") }
        _ = await front()
    }

    func chromiumFollowTab() async {
        guard real, let a = chromium, tools(a) != nil, let b = c.engineTab(for: tabB) as? ChromiumTab else { return skip("follow: DevTools aren't docked") }
        let before = layout(a)
        c.show(tabB, focus: true)
        await sleep(0.6)
        let aTools = tools(a)
        check(aTools.map { $0.isHiddenOrHasHiddenAncestor || $0.window == nil } ?? true,
              "switching to another tab hides the first tab's DevTools")
        let bHost = b.core.view.superview
        check(tools(b) == nil && bHost.map { b.core.view.frame == $0.bounds } == true,
              "the other tab has no DevTools and fills the card (\(fmt(b.core.view.frame)))")
        c.show(tabA, focus: true)
        let back = await until(3) { self.layout(a).inWindow && self.layout(a).side == before.side }
        check(back && abs(layout(a).page.height - before.page.height) < 2 && abs(layout(a).page.width - before.page.width) < 2,
              "back on the first tab, its DevTools are there again, same side and size (\(describe(a)))")
    }

    func chromiumShortcuts() async {
        guard real, let t = chromium else { return skip("shortcuts need real keys") }
        if t.isDevToolsOpen { _ = await key("cmd+opt+i"); await until(4) { !t.isDevToolsOpen } }
        check(!t.isDevToolsOpen && t.core.view.superview.map { t.core.view.frame == $0.bounds } == true, "⌥⌘I closes DevTools; the page fills the card")
        _ = await key("cmd+opt+j")
        let opened = await until(8) { self.layout(t).inWindow }
        await sleep(0.8)
        let p = await panelState()
        check(opened && p?.id == "console", "⌥⌘J opens DevTools on the Console (\(p?.id ?? "-"))")
        _ = await front()
        _ = await key("cmd+opt+j")
        await until(4) { !t.isDevToolsOpen }
        _ = await key("cmd+opt+c")
        await until(8) { self.layout(t).inWindow }
        await sleep(0.8)
        var picking: [String: Any]?
        for _ in 0..<8 {
            picking = await frontend("(async () => {\(Self.js) const bs = deep(document, '[aria-label^=\"Select an element\"], [title^=\"Select an element\"]'); const on = bs.some(b => b.getAttribute('aria-pressed') === 'true' || b.hasAttribute('toggled') || b.toggled === true || b.classList.contains('toggled-on') || b.classList.contains('toggled')); return {panel: tp.selectedTabId, on, buttons: bs.length}; })()") as? [String: Any]
            if picking?["on"] as? Bool == true { break }
            await sleep(0.4)
        }
        check(picking?["panel"] as? String == "elements" && picking?["on"] as? Bool == true,
              "⌥⌘C opens Elements with the element picker on (\(picking ?? [:]))")
        _ = await key("escape")
    }

    func chromiumSplit() async {
        guard real else { return skip("split needs real keys") }
        if chromium?.isDevToolsOpen == true { chromium?.closeDevTools(); await sleep(0.5) }
        let sid = c.currentSpaceID
        guard (try? c.store.createSplit([tabA, tabB], inSpace: sid, focused: tabB)) != nil else { return check(false, "split: a split of A and B") }
        c.show(tabB, focus: true)
        await sleep(1.0)
        guard let b = c.engineTab(for: tabB) as? ChromiumTab, let a = c.engineTab(for: tabA) as? ChromiumTab else { return check(false, "split: both panes") }
        _ = await front()
        // A real click into pane B focuses it, as a person would.
        if let host = b.core.view.superview { _ = await click(windowPoint(host.bounds.midX, host.bounds.midY, in: host), in: c.window) }
        note("devtools \(engine): split: shown \(c.shownTabID == tabB ? "B" : c.shownTabID == tabA ? "A" : "-"), B in window \(b.core.view.window != nil), B visible \(b.core.pageVisible)")
        _ = await key("cmd+opt+i")
        let ok = await until(8) { self.layout(b).inWindow }
        let lb = layout(b)
        let paneHost = b.core.view.superview
        check(ok && lb.sameHost && tools(a) == nil && a.core.view.superview !== paneHost,
              "split: ⌥⌘I docks DevTools in the focused pane only (B: \(describe(b)); A has DevTools \(tools(a) != nil))")
        if let tv = tools(b) { picture("devtools-chromium-split", parts: [(a.core.view, await snapshot(a)), (b.core.view, await snapshot(b)), (tv, await devToolsPicture(b))]) }
        b.closeDevTools()
        await sleep(0.4)
        c.separateShownSplit()
        c.show(tabA, focus: true)
        await sleep(0.6)
    }

    func chromiumLittle() async {
        guard real else { return skip("Little Airc needs real keys") }
        guard let little = app.openLittleArc(url: URL(string: base + "/b")) else { return check(false, "Little Airc opens") }
        let w = little.window
        await until(8) { little.page?.title == "DevTools B" && little.page?.isLoading == false }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        await until(3) { w.isKeyWindow }
        guard let t = little.page as? ChromiumTab else { w.close(); return check(false, "Little Airc's page is Chromium") }
        _ = await key("cmd+opt+i")
        let ok = await until(8) { self.layout(t, in: w).inWindow }
        check(ok && layout(t, in: w).sameHost, "Little Airc: ⌥⌘I docks DevTools in its own window (\(fmt(layout(t, in: w).page)) page in \(fmt(layout(t, in: w).host)))")
        t.closeDevTools()
        await sleep(0.4)
        w.close()
        await sleep(0.5)
        _ = await front()
    }

    func chromiumAgentPane() async {
        guard real, let t = chromium else { return skip("agent pane needs real keys") }
        AgentUI.forcedForTesting = true
        let pane = AgentPaneController.show(c)
        await sleep(0.8)
        if !t.isDevToolsOpen { _ = await key("cmd+opt+i") }
        let ok = await until(8) { self.layout(t).inWindow }
        let tv = tools(t)
        let toolsRect = tv.map { c.root.convert($0.convert($0.bounds, to: nil), from: nil) } ?? .zero
        let paneRect = pane.card.map { c.root.convert($0.convert($0.bounds, to: nil), from: nil) } ?? .zero
        check(ok && !paneRect.isEmpty && !toolsRect.intersects(paneRect.insetBy(dx: 1, dy: 1)),
              "the agent pane sits beside docked DevTools, never over them (DevTools \(fmt(toolsRect)), pane \(fmt(paneRect)))")
        pane.close()
        AgentUI.forcedForTesting = nil
        await sleep(0.4)
    }

    func chromiumClose() async {
        guard real, let t = chromium else { return skip("close needs real keys") }
        if !t.isDevToolsOpen { _ = await key("cmd+opt+i"); await until(8) { self.layout(t).inWindow } }
        _ = await front()
        _ = await key("cmd+opt+i")
        let closed = await until(5) { !t.isDevToolsOpen && self.tools(t) == nil }
        check(closed && t.core.view.superview.map { t.core.view.frame == $0.bounds } == true, "⌥⌘I closes DevTools and the page fills the card again")
    }
    #endif

    // MARK: WebKit

    var webKit: WebKitTab? { page as? WebKitTab }
    func inspector(_ t: WebKitTab?) -> NSObject? {
        guard let t, t.webView.responds(to: NSSelectorFromString("_inspector")) else { return nil }
        return t.webView.value(forKey: "_inspector") as? NSObject
    }
    /// WebKit's inspector page (its own WKWebView subclass) next to the inspected page, if attached in this window.
    func inspectorView(_ t: WebKitTab?) -> WKWebView? {
        guard let t else { return nil }
        if let i = inspector(t), i.responds(to: NSSelectorFromString("inspectorWebView")), let v = i.value(forKey: "inspectorWebView") as? WKWebView { return v }
        return t.webView.superview?.subviews.compactMap { $0 as? WKWebView }.first { $0 !== t.webView && NSStringFromClass(type(of: $0)).contains("Inspector") }
    }
    func webKitAttached(_ t: WebKitTab?) -> (attached: Bool, side: String, page: NSRect, inspector: NSRect) {
        guard let t, let iv = inspectorView(t), let host = t.webView.superview, iv.window === c.window, !iv.isHiddenOrHasHiddenAncestor,
              iv.superview === host else { return (false, "none", .zero, .zero) }
        let p = tl(t.webView.frame, in: host), i = tl(iv.frame, in: host)
        let side = i.minY > p.maxY - 2 ? "bottom" : i.minX > p.maxX - 2 ? "right" : i.maxX < p.minX + 2 ? "left" : "overlap"
        return (true, side, p, i)
    }
    func webKitParts(_ t: WebKitTab) async -> [(NSView, CGImage?)] {
        func shot(_ v: WKWebView) async -> CGImage? {
            let image: NSImage? = await withCheckedContinuation { k in v.takeSnapshot(with: nil) { img, _ in k.resume(returning: img) } }
            return image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        var parts: [(NSView, CGImage?)] = [(t.webView, await shot(t.webView))]
        if let iv = inspectorView(t), webKitAttached(t).attached { parts.append((iv, await shot(iv))) }
        return parts
    }
    func inspectorJS(_ t: WebKitTab?, _ script: String) async -> Any? {
        guard let iv = inspectorView(t) else { return nil }
        return await withCheckedContinuation { k in
            iv.evaluateJavaScript(script) { v, e in
                if let e { self.note("devtools \(self.engine): Inspector script: \(e.localizedDescription)") }
                k.resume(returning: v)
            }
        }
    }

    func webKitOpen() async {
        guard real else { return skip("⌥⌘I needs real keys") }
        let t = webKit
        check(await key("cmd+opt+i"), "⌥⌘I pressed (real key, PID-targeted)")
        let ok = await until(8) { self.webKitAttached(t).attached }
        let a = webKitAttached(t)
        note("devtools \(engine): after ⌥⌘I: attached \(a.attached) side \(a.side) page \(fmt(a.page)) inspector \(fmt(a.inspector)); windows \(NSApp.windows.filter { $0.isVisible }.map { $0.title })")
        check(ok && a.side != "overlap", "⌥⌘I attaches Web Inspector to the page's window (\(a.side))")
        check(NSApp.windows.filter({ $0.isVisible && $0.title.hasPrefix("Web Inspector") }).isEmpty, "no separate Web Inspector window")
    }

    func webKitTabs() async {
        guard real, let t = webKit, webKitAttached(t).attached, let iv = inspectorView(t) else { return skip("Inspector tabs: not attached") }
        // Bottom, so every tab fits.
        if webKitAttached(t).side != "bottom", let i = inspector(t), i.responds(to: NSSelectorFromString("attachBottom")) { i.perform(NSSelectorFromString("attachBottom")) }
        await sleep(0.8)
        let list = await inspectorJS(t, "JSON.stringify(WI.tabBar.tabBarItems.filter(i => i.representedObject && i.element.offsetWidth > 0).map(i => { const r = i.element.getBoundingClientRect(); return {type: i.representedObject.type || i.representedObject.constructor.Type, title: i.title, r: [r.x, r.y, r.width, r.height]}; }))") as? String
        let items = (list.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [[String: Any]]) ?? []
        check(!items.isEmpty, "the Inspector's tab bar can be read (\(items.compactMap { $0["title"] as? String }))")
        for item in items {
            guard let r = item["r"] as? [Double], r.count == 4, let type = item["type"] as? String else { continue }
            let title = (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? type
            let clicked = await click(windowPoint(r[0] + r[2] / 2, r[1] + r[3] / 2, in: iv), in: c.window)
            await sleep(0.7)
            let state = await inspectorJS(t, "JSON.stringify((() => { const v = WI.tabBrowser.selectedTabContentView; const r = v.element.getBoundingClientRect(); return {type: v.type || v.constructor.Type, w: r.width, h: r.height, n: v.element.querySelectorAll('*').length}; })())") as? String
            let s = (state.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]) ?? [:]
            let image: NSImage? = await withCheckedContinuation { k in iv.takeSnapshot(with: nil) { img, _ in k.resume(returning: img) } }
            let spread = Self.colours(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let shownType: String = s["type"] as? String ?? "-"
            let w: Double = s["w"] as? Double ?? 0, h: Double = s["h"] as? Double ?? 0, n: Int = s["n"] as? Int ?? 0
            let sized: Bool = w > 100 && h > 30 && n > 5
            check(clicked && shownType == type && sized && spread > 3,
                  "\(title): its tab, clicked, shows its content (\(shownType), \(Int(w))×\(Int(h)), \(n) elements, picture \(spread) colours)")
        }
        picture("devtools-webkit-bottom-light", parts: await webKitParts(t))
    }

    func webKitSides() async {
        guard real, let t = webKit, webKitAttached(t).attached, let iv = inspectorView(t) else { return skip("Inspector sides: not attached") }
        // The Inspector's own dock buttons (real clicks).
        func button(_ label: String) async -> [Double]? {
            let s = await inspectorJS(t, "JSON.stringify((() => { const e = [...document.querySelectorAll('[title], [aria-label]')].find(e => (e.getAttribute('title') === '\(label)' || e.getAttribute('aria-label') === '\(label)') && e.offsetWidth > 0); if (!e) return null; const r = e.getBoundingClientRect(); return [r.x, r.y, r.width, r.height]; })())") as? String
            return s.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [Double]
        }
        for (label, side) in [("Dock to right of window", "right"), ("Dock to bottom of window", "bottom")] {
            guard let r = await button(label), let v = inspectorView(t) else { check(false, "the Inspector has \"\(label)\""); continue }
            let ok = await click(windowPoint(r[0] + r[2] / 2, r[1] + r[3] / 2, in: v), in: c.window)
            let moved = await until(3) { self.webKitAttached(t).side == side }
            check(ok && moved, "\(label) (real click): \(webKitAttached(t).side)")
            picture("devtools-webkit-\(side)-light", parts: await webKitParts(t))
        }
        _ = iv
    }

    func webKitFollowTab() async {
        guard real, let a = webKit, webKitAttached(a).attached, let b = c.engineTab(for: tabB) as? WebKitTab else { return skip("follow: not attached") }
        let iv = inspectorView(a)
        c.show(tabB, focus: true)
        await sleep(0.6)
        check(iv.map { $0.isHiddenOrHasHiddenAncestor || $0.window == nil } ?? true, "switching tabs hides the first tab's Web Inspector")
        check(b.webView.superview.map { b.webView.frame == $0.bounds } == true, "the other tab fills the card (\(fmt(b.webView.frame)))")
        c.show(tabA, focus: true)
        let back = await until(3) { self.webKitAttached(a).attached }
        check(back, "back on the first tab, its Web Inspector is attached again (\(webKitAttached(a).side))")
    }

    func webKitClose() async {
        guard real, let t = webKit else { return skip("close needs real keys") }
        _ = await front()
        _ = await key("cmd+opt+i")
        let closed = await until(5) { !t.isDevToolsOpen }
        check(closed && t.webView.superview.map { abs(t.webView.frame.height - $0.bounds.height) < 1 && abs(t.webView.frame.width - $0.bounds.width) < 1 } == true,
              "⌥⌘I closes Web Inspector and the page fills the card again (\(fmt(t.webView.frame)))")
    }

    func finish() {
        server?.stop()
        runner.finish()
    }
}

#if canImport(AircCore)
/// Whether docked DevTools have the keyboard, read without new API (the check also builds on trees before the dock).
enum ChromiumKeyboardProbe {
    static func devToolsHasKeyboard(_ window: NSWindow) -> Bool {
        guard let r = window.firstResponder as? NSView else { return false }
        var v: NSView? = r
        while let x = v {
            if let tab = (NSApp.delegate as? AppDelegate)?.controller(for: window)?.shownTabID
                .flatMap({ (NSApp.delegate as? AppDelegate)?.controller(for: window)?.engineTab(for: $0) as? ChromiumTab }),
               let tv = tab.core.devToolsView, x === tv { return true }
            v = x.superview
        }
        return false
    }
}
#endif
#endif
