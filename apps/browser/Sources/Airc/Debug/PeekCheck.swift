// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

#if canImport(AircCore)
/// Part of `--script events` (Chromium; WebKit has no link routing): PK-1 Peek on loopback pages. Clicks on page links
/// are trusted DevTools mouse events (Input.dispatchMouseEvent), the way the engine's own checks click.
///   - ⇧-click opens the link in Peek, over the page, in the opener's profile, with no new tab; Esc closes it; ⌘Z
///     brings it back; ⌘O makes it a Today tab (the same page);
///   - a pinned tab's target=_blank link to another site opens in Peek; a click outside the card closes it.
extension SnapshotRunner {
    func peekCheck() {
        guard let engine = app?.engine as? ChromiumEngine else { return run { self.note("peek: Chromium only") } }
        var server: LocalPageServer?
        var base = ""
        var source = ""
        var peeked: EngineTab?
        var todayBefore = 0
        let page = { self.c.engineTab(for: source) }
        // The links go to 127.0.0.1 from a localhost page: another site, on the same loopback server.
        let sourcePage = "<title>source</title><p><a id=\"w\">plain link</a></p><p><a id=\"b\" target=\"_blank\">new-tab link</a></p>"
            + "<script>var o=location.protocol+'//127.0.0.1:'+location.port;document.getElementById('w').href=o+'/target';"
            + "document.getElementById('b').href=o+'/target2'</script>"

        step { [self] done in
            server = LocalPageServer(responses: [
                "/source": .init(body: sourcePage),
                "/target": .init(body: "<title>target</title><p>Peeked</p>"),
                "/target2": .init(body: "<title>target2</title><p>Peeked from a pinned tab</p>"),
            ])
            server?.start { port in
                base = port.map { "http://localhost:\($0)" } ?? ""
                done()
            }
        }
        run { [self] in
            guard !base.isEmpty, let t = try? c.store.openTab(url: base + "/source", inSpace: c.currentSpaceID, title: "source") else {
                return check(false, "peek: a source page")
            }
            source = t.id
            c.reloadAll(animated: false)
            c.show(t.id, focus: false)
        }
        step { [self] done in waitUntil({ page()?.title == "source" && page()?.isLoading == false }, timeout: 6) { done() } }

        /// A trusted click on the link `id`, with ⇧ when `shift`.
        func clickLink(_ id: String, shift: Bool) {
            step { [self] done in
                guard let p = page() else { return done() }
                p.evaluate("var r=document.getElementById('\(id)').getBoundingClientRect();[r.left+r.width/2,r.top+r.height/2]") { v in
                    let xy = (v as? [Double]) ?? []
                    guard xy.count == 2 else { self.check(false, "peek: the link \(id) is on the page"); return done() }
                    var params: [String: Any] = ["x": xy[0], "y": xy[1], "button": "left", "clickCount": 1, "modifiers": shift ? 8 : 0]
                    params["type"] = "mousePressed"
                    engine.devToolsCall("Input.dispatchMouseEvent", params: params, in: p) { _, _ in
                        params["type"] = "mouseReleased"
                        engine.devToolsCall("Input.dispatchMouseEvent", params: params, in: p) { _, _ in done() }
                    }
                }
            }
        }
        func expectPeek(_ name: String, title: String) {
            step { [self] done in
                waitUntil({ self.c.peek?.page.title == title }, timeout: 6) {
                    let p = self.c.peek
                    let opener = page()
                    let overPage = p.map { $0.view.superview === self.c.root && $0.view.frame == self.c.card.frame } ?? false
                    let sameProfile = p?.page.profile === opener?.profile
                    let noNewTab = self.c.store.todayTabs(ofSpace: self.c.currentSpaceID).count == todayBefore
                    peeked = p?.page
                    self.check(p != nil && overPage && sameProfile && noNewTab,
                               "peek: \(name) opens in Peek (\(p?.page.title ?? "none")), over the page \(overPage), in the opener's profile "
                               + "\(sameProfile), no new tab \(noNewTab)")
                    done()
                }
            }
        }

        // ⇧-click.
        run { [self] in todayBefore = c.store.todayTabs(ofSpace: c.currentSpaceID).count }
        clickLink("w", shift: true)
        expectPeek("a ⇧-clicked link", title: "target")
        capture("peek")
        key("\u{1b}", 53)
        step { [self] done in
            waitUntil({ self.c.peek == nil }, timeout: 3) {
                self.check(self.c.peek == nil && peeked?.isClosed != false, "peek: Esc closes it (page closed \(peeked?.isClosed ?? false))")
                done()
            }
        }
        key("z", 6, .command)
        expectPeek("⌘Z after closing", title: "target")
        key("o", 31, .command)
        step { [self] done in
            waitUntil({ self.c.peek == nil }, timeout: 3) {
                let tab = self.c.store.todayTabs(ofSpace: self.c.currentSpaceID).first { $0.url.hasSuffix("/target") }
                let same = tab.flatMap { self.c.engineTab(for: $0.id) } === peeked && peeked != nil
                self.check(tab != nil && self.c.shownTabID == tab?.id && same,
                           "peek: ⌘O makes it a Today tab, shown (\(tab != nil && self.c.shownTabID == tab?.id)), the same page (\(same))")
                done()
            }
        }

        // A pinned tab's new-tab link to another site.
        run { [self] in
            try? c.store.togglePin(source, inSpace: c.currentSpaceID)
            c.show(source, focus: false)
            todayBefore = c.store.todayTabs(ofSpace: c.currentSpaceID).count
        }
        wait(0.5)
        clickLink("b", shift: false)
        expectPeek("a pinned tab's link to another site", title: "target2")
        // A Peek opened over another (a tab preview card's Peek): the first one's page closes, not left loaded unseen.
        step { [self] done in
            let first = c.peek?.page
            guard let opener = page(), let url = URL(string: base + "/target") else { return done() }
            c.openPeek(url, from: opener)
            waitUntil({ first?.isClosed == true && self.c.peek?.page.title == "target" }, timeout: 6) {
                self.check(first?.isClosed == true && self.c.peek?.page !== first && self.c.peek?.page.title == "target",
                           "peek: a Peek over another closes the first one's page (closed \(first?.isClosed ?? false), "
                           + "on top \(self.c.peek?.page.title ?? "none"))")
                done()
            }
        }
        step { [self] done in
            guard let v = c.peek?.view else { return done() }
            // In the scrim, left of the card.
            let p = v.convert(NSPoint(x: v.card.frame.minX / 2, y: v.bounds.midY), to: nil)
            self.click(at: p, in: c.window) {
                self.waitUntil({ self.c.peek == nil }, timeout: 3) {
                    self.check(self.c.peek == nil, "peek: a click outside the card closes it")
                    server?.stop()
                    done()
                }
            }
        }
    }
}
#endif
#endif
