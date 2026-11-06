// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// Part of `--script events`: SB-1's history menus. A tab goes One → Two → Three (loopback pages); Back's menu lists
/// Two, One (nearest first) and choosing One goes there; Forward's menu then lists Two, Three; ⌘-click on Forward opens
/// Two in a background tab. The menus' items are chosen through the menu (a real context menu would hold the scripted
/// run in its tracking loop); the ⌘-click is a real press and release.
extension SnapshotRunner {
    func historyMenuCheck() {
        var server: LocalPageServer?
        var base = ""
        var tabID = ""
        let page = { self.c.engineTab(for: tabID) }
        step { [self] done in
            server = LocalPageServer(responses: ["/one": .init(body: "<title>One</title><p>1</p>"),
                                                 "/two": .init(body: "<title>Two</title><p>2</p>"),
                                                 "/three": .init(body: "<title>Three</title><p>3</p>")])
            server?.start { port in
                base = port.map { "http://127.0.0.1:\($0)" } ?? ""
                if base.isEmpty { self.check(false, "history menu: the loopback server starts") }
                done()
            }
        }
        func visit(_ path: String, _ title: String) {
            step { [self] done in
                guard !base.isEmpty else { return done() }
                if tabID.isEmpty {
                    guard let t = try? c.store.openTab(url: base + path, inSpace: c.currentSpaceID, title: title) else { return done() }
                    tabID = t.id
                    c.reloadAll(animated: false)
                    c.show(t.id, focus: false)
                } else {
                    page()?.load(URL(string: base + path)!)
                }
                waitUntil({ page()?.title == title && page()?.isLoading == false }, timeout: 6) { done() }
            }
        }
        func titles(_ menu: NSMenu?) -> [String] { menu?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? [] }
        visit("/one", "One")
        visit("/two", "Two")
        visit("/three", "Three")
        step { [self] done in
            let menu = c.historyMenu(forward: false)
            check(titles(menu) == ["Two", "One"] && c.historyMenu(forward: true) == nil,
                  "history menu: Back lists the pages behind, nearest first (\(titles(menu))); Forward has none")
            if let menu, let i = menu.items.firstIndex(where: { $0.title == "One" }) { menu.performActionForItem(at: i) }
            waitUntil({ page()?.title == "One" && page()?.isLoading == false }, timeout: 6) {
                let forward = titles(self.c.historyMenu(forward: true))
                self.check(page()?.title == "One" && forward == ["Two", "Three"],
                           "history menu: choosing One goes two pages back (now \(page()?.title ?? "-")); Forward lists \(forward)")
                done()
            }
        }
        // ⌘-click on Forward (a real press and release with ⌘, through the window): Two opens in a background tab and
        // One stays on screen.
        var before = 0
        step { [self] done in
            if let why = realEventsBlocked { skip("history menu: ⌘-click on Forward: \(why)"); return done() }
            let header = c.sidebar.header
            before = c.store.todayTabs(ofSpace: c.currentSpaceID).count
            let f = header.forward
            let p = f.convert(NSPoint(x: f.bounds.midX, y: f.bounds.midY), to: nil)
            let w = c.window
            for (type, delay) in [(NSEvent.EventType.leftMouseDown, 0.0), (.leftMouseUp, 0.06)] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                  pressure: type == .leftMouseUp ? 0 : 1) { NSApp.postEvent(e, atStart: false) }
                }
            }
            waitUntil({ self.c.store.todayTabs(ofSpace: self.c.currentSpaceID).count > before }, timeout: 2) {
                let opened = self.c.store.todayTabs(ofSpace: self.c.currentSpaceID).first { $0.url.hasSuffix("/two") && $0.id != tabID }
                self.check(opened != nil && self.c.shownTabID == tabID && page()?.title == "One",
                           "history menu: ⌘-click on Forward opens Two in a background tab (\(opened != nil)), One stays shown (\(page()?.title ?? "-"))")
                if let opened { self.c.closeTab(opened.id) }
                done()
            }
        }
        run { [self] in
            if !tabID.isEmpty { c.closeTab(tabID) }
            server?.stop()
        }
    }
}
#endif
