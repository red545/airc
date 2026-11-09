// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit
#if canImport(AircCore)
import AircCore
#endif

/// Part of `--script events` (both engines): SB-43 auto-archive waits for "Leave site?" the way Clear Today does, and
/// never force-closes a page. Three idle Today tabs on synthetic pages, through the real archive timer:
///   - a page without unload handlers is archived;
///   - a page whose beforeunload handler runs but doesn't ask is archived once its page has closed;
///   - a page the person used whose handler would ask isn't asked (no question shows) and stays; when it no longer
///     asks, the retry archives it.
extension SnapshotRunner {
    func autoArchiveLeaveCheck() {
        var plain = "", quiet = "", asks = "", keeper = ""
        var activated = false
        var oldBackupFolder: String?
        let custom = dir.appendingPathComponent("custom-backups", isDirectory: true)
        func page(_ title: String, _ script: String) -> String {
            let html = "<title>\(title)</title><body style='margin:0;height:600px'><p style='margin:40px'>\(title)</p><script>\(script)</script></body>"
            return "data:text/html," + (html.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        }
        run { [self] in
            oldBackupFolder = app?.settings.values.backupFolder
            app?.settings.values.backupFolder = custom.path
            let sid = c.currentSpaceID
            func open(_ t: String, _ js: String) -> String {
                (try? c.store.openTab(url: page(t, js), inSpace: sid, activate: false, title: t))?.id ?? ""
            }
            plain = open("Idle plain", "")
            quiet = open("Idle quiet", "addEventListener('beforeunload',function(){window.__ran=1})")
            asks = open("Idle asks", "window.__ask=true;addEventListener('beforeunload',function(e){if(window.__ask){e.preventDefault();e.returnValue=''}})")
            keeper = open("Keeper", "")
            WindowController.autoArchiveRetry = 2
            c.reloadAll(animated: false)
            c.show(asks, focus: true)
        }
        waitForPage()
        // The person uses the asking page (sticky activation: Chromium only asks on a page that was used).
        step { [self] done in
            func checkActivation() {
                c.engineTab(for: asks)?.evaluate("navigator.userActivation ? navigator.userActivation.hasBeenActive : true") { v in
                    activated = (v as? Bool) == true
                    self.note("auto-archive: the asking page was used: \(activated)")
                    done()
                }
            }
            #if canImport(AircCore)
            if let engine = app?.engine as? ChromiumEngine, let p = c.engineTab(for: asks) {
                var params: [String: Any] = ["x": 60, "y": 60, "button": "left", "clickCount": 1, "type": "mousePressed"]
                engine.devToolsCall("Input.dispatchMouseEvent", params: params, in: p) { _, _ in
                    params["type"] = "mouseReleased"
                    engine.devToolsCall("Input.dispatchMouseEvent", params: params, in: p) { _, _ in checkActivation() }
                }
                return
            }
            #endif
            let p = c.card.convert(NSPoint(x: c.card.bounds.midX, y: c.card.bounds.midY), to: nil)
            click(at: p, in: c.window) { checkActivation() }
        }
        run { [self] in
            c.show(keeper, focus: false)
            for id in [plain, quiet, asks] { c.loadPageInBackground(id) }
        }
        wait(1.5)
        // Idle for 13 hours: due (the profile's interval is 12 hours). The real one-shot timer runs it.
        run { [self] in
            let idle = Date().addingTimeInterval(-13 * 3600)
            try? c.store.perform(nil) {
                for id in [plain, quiet, asks] {
                    if var t = c.store.tab(id) { t.lastActiveAt = idle; c.store.put(t) }
                }
            }
            c.scheduleArchive()
        }
        step { [self] done in
            waitUntil({ self.c.store.tab(plain) == nil && self.c.store.tab(quiet) == nil
                        && (!activated || self.c.autoArchiveRetryAt[asks] != nil) }, timeout: 8) { done() }
        }
        run { [self] in
            let archived = { (id: String) in c.store.state.archive.values.contains { $0.tab.id == id && $0.reason == .auto } }
            check(archived(plain), "auto-archive: an idle page without unload handlers goes to the Archive")
            check(archived(quiet), "auto-archive: an idle page whose beforeunload handler doesn't ask goes to the Archive once it has closed")
            let page = c.engineTab(for: asks)
            if activated {
                check(c.store.tab(asks) != nil && page?.isClosed == false && !c.autoArchiveClosing.contains(asks)
                      && c.autoArchiveRetryAt[asks] != nil && c.window.attachedSheet == nil,
                      "auto-archive: a used page that would ask \"Leave site?\" isn't asked or closed; it stays, to be tried again "
                      + "(tab \(c.store.tab(asks) != nil), page open \(page?.isClosed == false), retry \(c.autoArchiveRetryAt[asks] != nil))")
            } else {
                skip("auto-archive: a used page that would ask: the click didn't count as use here (window never key), so it wouldn't ask")
            }
        }
        // It no longer asks: the retry archives it.
        run { [self] in c.engineTab(for: asks)?.evaluate("window.__ask=false", completion: nil) }
        step { [self] done in waitUntil({ self.c.store.tab(asks) == nil }, timeout: 8) { done() } }
        run { [self] in
            check(c.store.tab(asks) == nil && c.store.state.archive.values.contains { $0.tab.id == asks && $0.reason == .auto },
                  "auto-archive: once it no longer asks, the retry archives it")
            check(c.store.tab(keeper) != nil, "auto-archive: the tab on screen stays")
            WindowController.autoArchiveRetry = 30 * 60
            let files = (try? FileManager.default.contentsOfDirectory(at: custom, includingPropertiesForKeys: nil)) ?? []
            check(files.contains { $0.lastPathComponent.hasPrefix("airc-backup-") && $0.pathExtension == "json" },
                  "auto-archive: daily backup lands in the selected custom folder")
            app?.settings.values.backupFolder = oldBackupFolder
        }
    }
}
#endif
