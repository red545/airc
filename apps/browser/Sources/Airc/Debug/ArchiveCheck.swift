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
/// SET-3: the pass's daily backup goes to the chosen backup folder; one that's read-only or gone falls back to the
/// default folder (and stays chosen), and Back Up says so.
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
            // A chosen folder exists (Settings' Choose… picks one); a made-up path would test the fallback instead.
            try? FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
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
        }
        // SET-3 fallback: the chosen folder read-only, then gone (under a folder that can't be written, like a drive
        // that isn't plugged in). The auto-archive pass still backs up, to the default folder; the choice stays.
        run { [self] in
            let fm = FileManager.default
            let readOnly = dir.appendingPathComponent("readonly-backups", isDirectory: true)
            let gone = readOnly.appendingPathComponent("unplugged/Backups", isDirectory: true)
            try? fm.createDirectory(at: readOnly, withIntermediateDirectories: true)
            try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
            for (name, folder) in [("read-only", readOnly), ("gone", gone)] {
                for f in dailyBackups(AppPaths.backups) { try? fm.removeItem(at: AppPaths.backups.appendingPathComponent(f)) }
                app?.settings.values.backupFolder = folder.path
                c.runAutoArchive()
                let fallback = dailyBackups(AppPaths.backups)
                check(fallback.count == 1 && dailyBackups(folder).isEmpty && app?.settings.values.backupFolder == folder.path,
                      "auto-archive: a \(name) chosen backup folder falls back to the default folder and stays chosen "
                      + "(default \(fallback), chosen \(dailyBackups(folder)))")
                if name == "read-only", let backups = app?.settings {
                    let url = try? backups.backUp(c.store, purpose: .manual)
                    check(url.map(backups.isFallbackBackup) == true,
                          "auto-archive: Back Up with a read-only chosen folder saves to the default folder and says so")
                }
            }
            check(!fm.fileExists(atPath: gone.path), "auto-archive: a gone chosen folder isn't recreated")
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path)
            app?.settings.values.backupFolder = oldBackupFolder
        }
    }

    /// The daily backups' file names in `folder` (airc-backup-YYYY-MM-DD.json).
    private func dailyBackups(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.range(of: #"^airc-backup-[0-9]{4}-[0-9]{2}-[0-9]{2}\.json$"#, options: .regularExpression) != nil }
    }
}
#endif
