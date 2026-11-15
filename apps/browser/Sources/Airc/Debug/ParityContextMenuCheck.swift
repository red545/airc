// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
#if canImport(AircCore)
import AircCore
#endif
extension SnapshotRunner {
    func parityContextMenuScenario() {
        var server: LocalPageServer?, tabID = ""
        let titles = ["Capture", "Capture Full Page", "Capture in Portrait Mode"]
        let page = { self.c.engineTab(for: tabID) }
        let styleStore = PortraitStyle.storage, wallpaper = PortraitCapture.wallpaper
        let suite = "Airc.ParityContextMenu." + UUID().uuidString
        var wallpaperReads = 0
        run {
            PortraitStyle.storage = { UserDefaults(suiteName: suite)! }
            PortraitCapture.wallpaper = { _, _ in wallpaperReads += 1; return nil }
        }
        step { [self] done in
            server = LocalPageServer(pages: ["/menu": """
                <title>Page menus</title><style>body{margin:0}div,a,img,p{display:block;height:80px;width:400px;margin:0}</style>
                <div>Page</div><a href='/link'>Link</a>
                <img src='data:image/svg+xml,%3Csvg xmlns="http://www.w3.org/2000/svg" width="400" height="80"%3E%3Crect width="400" height="80" fill="blue"/%3E%3C/svg%3E'>
                <p id='selection'>Selected text</p>
                """])
            server?.start { port in
                guard let port, let tab = try? c.store.openTab(url: "http://127.0.0.1:\(port)/menu", inSpace: c.currentSpaceID) else {
                    check(false, "contextmenu: loopback page"); done(); return
                }
                tabID = tab.id; c.reloadAll(animated: false); c.show(tab.id, focus: false)
                waitUntil({ page()?.title == "Page menus" && page()?.isLoading == false }, timeout: 15) { done() }
            }
        }
        wait(1)
        for (index, context) in ["page", "link", "image", "selection"].enumerated() {
            for action in ["Capture", "Capture in Portrait Mode"] {
                step { [self] done in
                    guard let tab = page() else { check(false, "contextmenu: missing tab"); done(); return }
                    let clickY = index * 80 + (index == 3 ? 8 : 25)
                    tab.evaluate(index == 3 ? "var r=document.createRange();r.selectNodeContents(document.querySelector('p'));getSelection().removeAllRanges();getSelection().addRange(r)" : "getSelection().removeAllRanges()") { _ in
                        #if canImport(AircCore)
                        if let cr = tab as? ChromiumTab, let engine = self.app?.engine as? ChromiumEngine {
                            var observed = false
                            cr.testPageMenu = { menu in
                                observed = true
                                let details = cr.testPageContext
                                let hasLink = !(details["linkURL"] as? String ?? "").isEmpty
                                let hasMedia = (details["mediaType"] as? Int ?? 0) != 0
                                let hasSelection = !(details["selection"] as? String ?? "").isEmpty
                                let matches = index == 0 ? (!hasLink && !hasMedia && !hasSelection) :
                                    index == 1 ? hasLink : index == 2 ? hasMedia : hasSelection
                                self.check(matches, "contextmenu Chromium \(context): native context matches target")
                                let items = menu["items"] as? [[String: Any]] ?? []
                                let labels = items.filter { $0["enabled"] as? Bool == true }.compactMap { $0["label"] as? String }
                                self.check(titles.allSatisfy(labels.contains), "contextmenu Chromium \(context): capture items (\(labels))")
                                guard let item = items.first(where: { $0["label"] as? String == action }), let command = item["id"] else { return nil }
                                return ["command": command]
                            }
                            engine.devToolsCall("Input.dispatchMouseEvent", params: ["type": "mousePressed", "x": 35, "y": clickY, "button": "right", "clickCount": 1], in: tab) { _, _ in
                                engine.devToolsCall("Input.dispatchMouseEvent", params: ["type": "mouseReleased", "x": 35, "y": clickY, "button": "right", "clickCount": 1], in: tab) { _, _ in
                                    self.waitUntil({ observed }, timeout: 5) {
                                        self.check(observed, "contextmenu Chromium \(context): native menu callback"); done()
                                    }
                                }
                            }
                            return
                        }
                        #endif
                        if let wk = tab as? WebKitTab, let view = wk.webView as? PageMenuWebView {
                            var observed = false
                            view.testMenuOpened = { menu in
                                observed = true
                                let nativeTitles = menu.items.map(\.title)
                                let matches: Bool
                                switch index {
                                case 0: matches = nativeTitles.contains { $0.contains("Reload") }
                                case 1: matches = nativeTitles.contains { $0.contains("Link") }
                                case 2: matches = nativeTitles.contains { $0.contains("Image") }
                                default: matches = nativeTitles.contains("Copy")
                                }
                                self.check(matches, "contextmenu WebKit \(context): native context matches target (\(nativeTitles))")
                                self.check(titles.allSatisfy(menu.items.filter(\.isEnabled).map(\.title).contains), "contextmenu WebKit \(context): native menu has capture items")
                                DispatchQueue.main.async {
                                    menu.cancelTracking()
                                    if let item = menu.items.first(where: { $0.title == action }), let selector = item.action {
                                        NSApp.sendAction(selector, to: item.target, from: item)
                                    }
                                }
                            }
                            let y = CGFloat(clickY)
                            let point = view.convert(NSPoint(x: 35, y: view.isFlipped ? y : view.bounds.height - y), to: nil)
                            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: self.c.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                            let cancellation = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
                                guard let menu = note.object as? NSMenu else { return }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { menu.cancelTracking() }
                            }
                            DispatchQueue.main.async { self.c.window.sendEvent(event) }
                            self.waitUntil({ observed }, timeout: 5) {
                                NotificationCenter.default.removeObserver(cancellation)
                                self.check(observed, "contextmenu WebKit \(context): native willOpenMenu callback")
                                done()
                            }
                            return
                        }
                        done()
                    }
                }
                step { [self] done in
                    let portrait = action == "Capture in Portrait Mode"
                    func ready() -> Bool {
                        guard let session = CaptureSession.active(in: c.window) else { return false }
                        return portrait ? session.portrait != nil && session.phase == .confirmed :
                            session.picturesReady && session.phase == .selecting
                    }
                    waitUntil(ready, timeout: portrait ? 40 : 10) {
                        check(ready(), "contextmenu \(context): \(action) starts the expected Capture mode")
                        CaptureSession.active(in: c.window)?.cancel(); done()
                    }
                }
                wait(0.4)
            }
        }
        run { [self] in
            check(wallpaperReads == 0, "contextmenu: default Portrait never reads the system wallpaper")
            PortraitStyle.storage = styleStore; PortraitCapture.wallpaper = wallpaper
            UserDefaults.standard.removePersistentDomain(forName: suite)
            server?.stop(); finish()
        }
    }
}
#endif
