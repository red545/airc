// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AircImport
import AircKit
import AppKit
import Network

/// Every file is generated under the test's directory. No real Arc discovery or credential import.
enum ArcImport2Fixture {
    static let extensionID = String(repeating: "a", count: 32)
    static func write(_ root: URL) throws {
        let fm = FileManager.default
        func json(_ path: String, _ value: Any) throws {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: value).write(to: url)
        }
        let spaces: [[String: Any]] = [
            ["id": "im-personal", "title": "Personal", "profile": ["default": [:]], "containerIDs": ["pinned", "im-pin", "unpinned", "im-today"]],
            ["id": "im-work", "title": "Work", "profile": ["custom": ["_0": ["directoryBasename": "Profile 1"]]], "containerIDs": []]
        ]
        // Personal's Today holds folders, as Arc's can: Loose A, [Reading: R1, [Later: L1]], Loose B. Seen a minute ago,
        // so nothing auto-archives during the check.
        let now = Date().timeIntervalSinceReferenceDate
        func tab(_ id: String, _ parent: String) -> [Any] {
            [id, ["id": id, "parentID": parent, "childrenIds": [], "title": NSNull(), "createdAt": now - 120,
                  "data": ["tab": ["savedURL": "https://example.com/today/\(id)", "savedTitle": id, "timeLastActiveAt": now - 60]]] as [String: Any]]
        }
        func container(_ id: String, _ children: [String], parent: String? = nil, folder: String? = nil) -> [Any] {
            var o: [String: Any] = ["id": id, "childrenIds": children, "createdAt": now - 300,
                                    "data": folder == nil ? ["itemContainer": ["containerType": ["spaceItems": ["_0": "im-personal"]]]] : ["list": [:]]]
            if let parent { o["parentID"] = parent }
            if let folder { o["title"] = folder }
            return [id, o]
        }
        let items: [Any] = container("im-pin", []) + container("im-today", ["im-loose-a", "im-reading", "im-loose-b"])
            + tab("im-loose-a", "im-today") + container("im-reading", ["im-r1", "im-later"], parent: "im-today", folder: "Reading")
            + tab("im-r1", "im-reading") + container("im-later", ["im-l1"], parent: "im-reading", folder: "Later")
            + tab("im-l1", "im-later") + tab("im-loose-b", "im-today")
        try json("StorableSidebar.json", ["version": 1, "sidebar": ["containers": [["global": [:]], ["spaces": spaces, "items": items]]]])
        for p in ["Default", "Profile 1"] {
            try json("User Data/\(p)/Preferences", ["extensions": ["settings": [extensionID: ["manifest": ["name": "__MSG_title__", "version": "1"], "path": extensionID + "/1_0", "location": 1, "state": p == "Default" ? 1 : 0]]]])
            let extensionRoot = "User Data/\(p)/Extensions/\(extensionID)/1_0"
            try json(extensionRoot + "/manifest.json", ["name": "__MSG_title__", "default_locale": "en"])
            try json(extensionRoot + "/_locales/en/messages.json", ["title": ["message": "Localized Reader"]])
            let t = Int64((Date().timeIntervalSince1970 + 11_644_473_600 - 3600) * 1_000_000)
            _ = try BrowserFixtures.sqlite(root.appendingPathComponent("User Data/\(p)/History"), """
            CREATE TABLE urls(url TEXT, title TEXT, visit_count INTEGER, typed_count INTEGER, last_visit_time INTEGER, hidden INTEGER);
            INSERT INTO urls VALUES('https://example.com/\(p == "Default" ? "personal" : "work")','Synthetic Arc constellation',3,1,\(t),0);
            """)
        }
    }
}

extension SnapshotRunner {
    /// The imported Personal Space's Today as a tree: "im-loose-a [Reading: im-r1 [Later: im-l1]] im-loose-b".
    func arcImport2Today(_ result: ImportResult) -> String {
        guard let sid = result.spaceIDs["arc-space:im-personal"] else { return "no Space" }
        func describe(_ rows: [SidebarEntry]) -> String {
            rows.map { e -> String in
                if let t = e.liveTab { return t.title }
                if let f = e.item, c.store.todayFolder(f.id) != nil { return "[\(f.displayTitle): " + describe(c.store.todayFolderContents(f.id)) + "]" }
                return "?"
            }.joined(separator: " ")
        }
        return describe(c.store.todayRootRows(ofSpace: sid))
    }

    static let arcImport2Tree = "im-loose-a [Reading: im-r1 [Later: im-l1]] im-loose-b"

    /// A click on a checklist button. SwiftUI buttons ignore a posted press and release when the real pointer rests
    /// where no tracking area reports it (eventscancel, checkreal2), so: the UI driver's real click when the run has it
    /// (AIRC_REAL_KEYS=1, dedicated session); otherwise posted moves onto the button, then the posted click.
    /// AIRC_ARCIMPORT2_CLICK picks one way for a diagnosis: `posted-bare` (the press and release alone), `posted-pointer-on`
    /// (the real pointer moved onto the button first, then the press and release alone), `posted-moves`, `real`.
    /// `done` gets how it was made and what the point hit.
    func arcImport2Click(_ name: String, in host: NSView, _ done: @escaping (String) -> Void) {
        guard let w = host.window else { return done("no window") }
        if !w.isKeyWindow { w.makeKey() }
        host.layoutSubtreeIfNeeded()
        guard let p = anchorPoint(name, in: host) else { return done("\(name) not on screen") }
        let screen = w.convertPoint(toScreen: p)
        let frame = w.contentView?.superview
        let hit = frame.flatMap { $0.hitTest($0.convert(p, from: nil)) }
        let pointer = NSEvent.mouseLocation
        let state = String(format: "(%.0f, %.0f) hits %@ %@; pointer (%.0f, %.0f) %@; key %@, active %@", p.x, p.y, Self.describe(hit),
                           hit.map { $0 === host || $0.isDescendant(of: host) } == true ? "in the card" : "outside the card",
                           pointer.x, pointer.y, w.frame.contains(pointer) ? "in the window" : "outside the window",
                           "\(w.isKeyWindow)", "\(NSApp.isActive)")
        let real = UIDriverClient.available && ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1"
        let mode = ProcessInfo.processInfo.environment["AIRC_ARCIMPORT2_CLICK"] ?? (real ? "real" : "posted-moves")
        func post(_ type: NSEvent.EventType, _ at: NSPoint) {
            if let e = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                NSApp.postEvent(e, atStart: false)
            }
        }
        switch mode {
        case "real":
            guard real, let primary = NSScreen.screens.first else { return done("real click requested without the driver; \(state)") }
            guard NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0) == w.windowNumber else {
                return done("real click refused: another window is at the point; \(state)")
            }
            UIDriverClient.run(["--click", String(Double(screen.x)), String(Double(primary.frame.maxY - screen.y))]) { ok, out in
                done((ok ? "real driver click" : "real driver click failed: \(out.prefix(120))") + "; " + state)
            }
        case "posted-pointer-on":
            UIDriverClient.move(p, in: w) { ok, out in
                let moved = ok ? "real pointer moved onto it" : "real move failed: \(out.prefix(80))"
                self.click(at: p, in: w) { done("posted press and release alone, \(moved); \(state)") }
            }
        case "posted-bare":
            click(at: p, in: w) { done("posted press and release alone; \(state)") }
        default:
            for dx in [-30.0, -15.0, 0.0] { post(.mouseMoved, NSPoint(x: p.x + dx, y: p.y)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.click(at: p, in: w) { done("posted, after posted moves onto it; \(state)") }
            }
        }
    }

    /// Whether anchor `name` shows whole: inside the checklist's list, the list inside the card's content, and that
    /// above the Back/Continue footer. With where each one is, for the message.
    func arcImport2Shows(_ name: String, in host: NSView) -> (Bool, String) {
        guard let b = TestAnchors.frame(name, in: host), let list = TestAnchors.frame("arcimport2.list", in: host),
              let content = TestAnchors.frame("onboarding.content", in: host),
              let footer = TestAnchors.frame("onboarding.primary", in: host) else { return (false, "no frame for \(name)") }
        // Anchor frames are flipped (y down), as the card's.
        let ok = list.insetBy(dx: -1, dy: -1).contains(b) && content.insetBy(dx: -1, dy: -1).contains(list) && list.maxY <= footer.minY
        return (ok, String(format: "%@ x %.0f–%.0f y %.0f–%.0f, list x %.0f–%.0f y %.0f–%.0f, content x %.0f–%.0f ends %.0f, footer starts %.0f",
                           name.hasPrefix("arcimport2.store.") ? "button" : "row", b.minX, b.maxX, b.minY, b.maxY, list.minX, list.maxX,
                           list.minY, list.maxY, content.minX, content.maxX, content.maxY, footer.minY))
    }

    /// A scroll of `lines` over `p` in `w`. The UI driver has no scroll wheel, so: the real pointer goes onto the list
    /// first when the run has the driver; then wheel events are posted to this process (CGEvent postToPid, aimed at
    /// the window). If `moved` says the list didn't move, the same wheel events go to the scroll view under the point
    /// (NSScrollView.scrollWheel). `done` says which one moved it.
    func arcImport2Scroll(at p: NSPoint, in w: NSWindow, lines: Int32, moved: @escaping () -> Bool, _ done: @escaping (String) -> Void) {
        func events() -> [CGEvent] {
            guard let primary = NSScreen.screens.first else { return [] }
            let s = w.convertPoint(toScreen: p)
            return (0..<abs(lines)).compactMap { _ in
                let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines < 0 ? -1 : 1, wheel2: 0, wheel3: 0)
                e?.location = CGPoint(x: s.x, y: primary.frame.maxY - s.y)
                e?.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(w.windowNumber))
                e?.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(w.windowNumber))
                return e
            }
        }
        func wheel(_ how: String) {
            let posted = events()
            posted.forEach { $0.postToPid(ProcessInfo.processInfo.processIdentifier) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if moved() { return done("\(how), then \(posted.count) posted scroll-wheel lines (CGEvent to this process; the driver has no wheel)") }
                let frame = w.contentView?.superview
                let hit = frame.flatMap { $0.hitTest($0.convert(p, from: nil)) }
                var v = hit
                while let x = v, !(x is NSScrollView) { v = x.superview }
                guard let scroller = v as? NSScrollView else { return done("\(how); posted wheel didn't move the list, and no scroll view under the point (\(Self.describe(hit)))") }
                events().compactMap { NSEvent(cgEvent: $0) }.forEach { scroller.scrollWheel(with: $0) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    done("\(how); \(posted.count) posted wheel lines didn't move it, so the same wheel events went to the list's NSScrollView"
                         + (moved() ? "" : " and it still didn't move"))
                }
            }
        }
        let real = UIDriverClient.available && ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1"
        guard real else { return wheel("no driver: pointer not moved") }
        UIDriverClient.move(p, in: w) { ok, out in wheel(ok ? "real pointer moved onto the list" : "real move failed (\(out.prefix(60)))") }
    }

    func arcImport2Scenario(marketing: Bool = false) {
        let root = dir.appendingPathComponent("synthetic-arc")
        var server: ArcImport2Server?
        var storeClick = "not clicked"
        run { [self] in
            do { try ArcImport2Fixture.write(root) } catch { check(false, "arcimport2: synthetic tree written") }
            OnboardingController.testArcDirectory = root
            app?.startOnboarding(mode: .rerun, atImport: true)
        }
        step { [self] done in
            let started = Date()
            waitUntil({ self.app?.onboarding?.model.hasArc == true }, timeout: 30) {
                self.note("arcimport2: discovery finished after \(Date().timeIntervalSince(started)) s; stage \(self.app?.onboarding?.model.arcReadProgress ?? "none")")
                done()
            }
        }
        run { [self] in
            check(app?.onboarding?.model.hasArc == true, "arcimport2: onboarding reads the synthetic Arc tree")
            app?.onboarding?.model.includeLogins = false
            app?.onboarding?.model.onImportEverything?()
        }
        step { [self] done in
            waitUntil({ self.app?.onboarding?.model.result != nil }, timeout: 30, then: done)
        }
        run { [self] in
            guard let app, let m = app.onboarding?.model, let result = m.result else { return check(false, "arcimport2: imported") }
            check(m.historyImported == 2, "arcimport2: summary counts two history entries")
            for key in ["arc-profile:Default", "arc-profile:Profile 1"] {
                guard let pid = result.profileIDs[key] else { check(false, "arcimport2: mapped profile"); continue }
                let hits = app.history.search("constellation", profileID: pid)
                check(hits.count == 1 && hits.first?.entry.url.hasSuffix(key.hasSuffix("Default") ? "personal" : "work") == true,
                      "arcimport2: command bar history search is isolated per imported profile")
            }
            check(TestAnchors.frames["arcimport2.checklist"] != nil, "arcimport2: checklist visible after import")
            check(ArcExtensionChecklist.shared.rows.count == 2, "arcimport2: extensions stay per profile")
            check(ArcExtensionChecklist.shared.rows.allSatisfy { $0.extensionInfo.name == "Localized Reader" },
                  "arcimport2: checklist resolves manifest locale names")
            check(ArcExtensionChecklist().rows.count == 2, "arcimport2: checklist survives reload")
            // Arc's Today folders come over as Today folders, in order and nested, their tabs Today tabs that keep
            // Arc's last-active time (auto-archive), not flattened into loose tabs.
            let tree = arcImport2Today(result)
            check(tree == Self.arcImport2Tree, "arcimport2: Today folders import as Today folders, in order and nested (\(tree))")
            if let sid = result.spaceIDs["arc-space:im-personal"] {
                let tabs = c.store.todayTabs(ofSpace: sid)
                check(tabs.count == 4 && tabs.allSatisfy { $0.isToday && Date().timeIntervalSince($0.lastActiveAt) < 600 },
                      "arcimport2: Today folders' tabs are Today tabs with Arc's last-active time (\(tabs.count) tabs)")
                check(c.store.todayFolders(ofSpace: sid).count == 2 && c.store.pinnedRoots(ofSpace: sid).isEmpty,
                      "arcimport2: two Today folders and nothing pinned")
            }
            if let pid = result.profileIDs["arc-profile:Default"] {
                ArcExtensionChecklist.testInstalled[pid] = [ArcImport2Fixture.extensionID]
            }
        }
        wait(2.2)
        run { [self] in
            guard let app else { return }
            let rows = ArcExtensionChecklist.shared.rows
            check(rows.filter { ArcExtensionChecklist.installed($0, app: app) }.count == 1,
                  "arcimport2: installed status belongs only to the matching destination profile")
            check(rows.contains { TestAnchors.frames["arcimport2.installed." + $0.id] != nil }, "arcimport2: installed extension is marked in the checklist")
        }
        step { [self] done in
            guard let w = app?.onboarding?.window else { return done() }
            if marketing { captureWindow(w, name: "arc-import-checklist", rounded: 24, done) }
            else { captureWindow(w, name: "arcimport2-checklist", rounded: 24, done) }
        }
        if marketing {
            run { [self] in app?.onboarding?.requestClose(); OnboardingController.testArcDirectory = nil; try? FileManager.default.removeItem(at: root) }
            // P22: the login results, with what didn't come over and why, and Try Again (ImportAcceptanceCheck.swift).
            arcImportLoginsShot()
            return
        }
        // Import a second time through onboarding: unchanged visit counts, profiles and checklist rows.
        run { [self] in app?.onboarding?.requestClose(); app?.startOnboarding(mode: .rerun, atImport: true) }
        step { [self] done in
            waitUntil({ self.app?.onboarding?.model.hasArc == true }, timeout: 30) {
                self.check(self.app?.onboarding?.model.hasArc == true, "arcimport2: reimport discovery completes")
                done()
            }
        }
        run { [self] in app?.onboarding?.model.includeLogins = false; app?.onboarding?.model.onImportEverything?() }
        step { [self] done in
            waitUntil({ self.app?.onboarding?.model.result != nil }, timeout: 30) {
                self.check(self.app?.onboarding?.model.result != nil, "arcimport2: reimport completes")
                done()
            }
        }
        run { [self] in
            guard let app, let result = app.onboarding?.model.result else { return }
            check(result.profilesCreated.isEmpty && result.spacesCreated == 0, "arcimport2: reimport creates no profiles or Spaces")
            let tree = arcImport2Today(result)
            let folders = result.spaceIDs["arc-space:im-personal"].map { c.store.todayFolders(ofSpace: $0).count } ?? 0
            check(tree == Self.arcImport2Tree && folders == 2, "arcimport2: reimport keeps Today folders without duplicates (\(folders): \(tree))")
            check(result.profileIDs.values.allSatisfy { app.history.entries(ofProfile: $0).count == 1 && app.history.entries(ofProfile: $0).first?.visitCount == 3 }, "arcimport2: reimport dedupes history and visit counts")
        }
        step { done in
            server = try? ArcImport2Server()
            guard let server else { return done() }
            server.start { port in
                #if canImport(AircCore)
                ArcExtensionChecklist.testStoreBase = URL(string: "http://chromewebstore.google.com:\(port)")
                #else
                ArcExtensionChecklist.testStoreBase = URL(string: "http://127.0.0.1:\(port)")
                #endif
                done()
            }
        }
        run { [self] in
            guard let app, let row = ArcExtensionChecklist.shared.rows.first(where: { !($0.extensionInfo.enabled) }) else { return }
            check(row.extensionInfo.storeURL.absoluteString == "https://chromewebstore.google.com/detail/" + ArcImport2Fixture.extensionID, "arcimport2: production Web Store URL")
        }
        step { [self] done in
            guard let o = app?.onboarding, let row = ArcExtensionChecklist.shared.rows.first(where: { !$0.extensionInfo.enabled }),
                  let host = MainActor.assumeIsolated({ o.window.contentContainer.subviews.first }) else { return done() }
            // The button has to be on screen without scrolling: two rows fit the 540 pt card whole (checkreal2: since
            // Install all, the card squeezed the list to one row and the second row's button was clipped, so no click,
            // real or posted, reached it). SwiftUI clips the list without the anchor view knowing, so this compares
            // frames, not visibleRect: the button inside the list, the list inside the card's content, above the footer.
            let name = "arcimport2.store." + row.id
            let rows = ArcExtensionChecklist.shared.rows
            // Re-entering the step slides its content in 14 pt (OnboardingRoot's transition): measure once it's settled.
            waitUntil({ host.layoutSubtreeIfNeeded(); return self.arcImport2Shows(name, in: host).0 }, timeout: 1.5) { [self] in
                let (shown, where0) = arcImport2Shows(name, in: host)
                check(shown, "arcimport2: the pending extension’s Web Store button shows in the checklist without scrolling (\(where0))")
                let all = rows.allSatisfy { arcImport2Shows("arcimport2.row." + $0.id, in: host).0 }
                check(all, "arcimport2: both extension rows show whole, with no scrolling")
                arcImport2Click(name, in: host) { storeClick = $0; done() }
            }
        }
        wait(0.5)
        run { [self] in
            guard let row = ArcExtensionChecklist.shared.rows.first(where: { !$0.extensionInfo.enabled }) else { return }
            check(c.store.profile(ofSpace: c.currentSpaceID).id == row.profileID, "arcimport2: Web Store action selects the extension’s profile Space (\(storeClick))")
            check(c.store.todayTabs(ofSpace: c.currentSpaceID).contains { $0.url == ArcExtensionChecklist.testStoreBase!.appendingPathComponent("detail/" + row.extensionInfo.id).absoluteString }, "arcimport2: Web Store action opens the expected URL (\(storeClick))")
        }
        // A long checklist (7 rows): the list keeps two whole rows and a faded peek of the next, the footer stays,
        // and the last row's Web Store button is reached by scrolling the list, then clicked.
        var saved: [ArcExtensionRow] = []
        var longClick = "not clicked", longScroll = "not scrolled"
        let longIDs = (0..<7).map { String(repeating: String(Character(UnicodeScalar(UInt8(98 + $0)))), count: 32) }  // b…h ×32
        run { [self] in
            guard let o = app?.onboarding, let pid = o.model.result?.profileIDs["arc-profile:Default"] else { return check(false, "arcimport2: long list set up") }
            saved = ArcExtensionChecklist.shared.rows
            let long = longIDs.enumerated().compactMap { i, id -> ArcExtensionRow? in
                let json = #"{"id":"\#(id)","name":"Synthetic Extension \#(i + 1)","enabled":true}"#
                return (try? JSONDecoder().decode(ImportedExtension.self, from: Data(json.utf8))).map { ArcExtensionRow(profileID: pid, extensionInfo: $0) }
            }
            ArcExtensionChecklist.shared.testShow(long)
            o.window.makeKeyAndOrderFront(nil)
        }
        wait(1.0)
        step { [self] done in
            guard let o = app?.onboarding, let last = ArcExtensionChecklist.shared.rows.last,
                  let host = MainActor.assumeIsolated({ o.window.contentContainer.subviews.first }) else { return done() }
            host.layoutSubtreeIfNeeded()
            let first = ArcExtensionChecklist.shared.rows.prefix(2).allSatisfy { arcImport2Shows("arcimport2.row." + $0.id, in: host).0 }
            let (lastShown, lastWhere) = arcImport2Shows("arcimport2.store." + last.id, in: host)
            let list = TestAnchors.frame("arcimport2.list", in: host) ?? .zero
            check(first && !lastShown && list.height > 0 && list.height < 140,
                  String(format: "arcimport2: with 7 extensions the list shows two whole rows and scrolls (list %.0f pt high; last %@)", list.height, lastWhere))
            check(TestAnchors.frame("onboarding.primary", in: host).map { host.bounds.insetBy(dx: -1, dy: -1).contains($0) } == true,
                  "arcimport2: Continue stays on the card with 7 extensions")
            let w = o.window
            captureWindow(w, name: "arcimport2-long", rounded: 24) {
                guard let p = self.anchorPoint("arcimport2.list", in: host) else { return done() }
                let before = TestAnchors.frame("arcimport2.store." + last.id, in: host)
                self.arcImport2Scroll(at: p, in: w, lines: -30, moved: {
                    host.layoutSubtreeIfNeeded()
                    return TestAnchors.frame("arcimport2.store." + last.id, in: host) != before
                }) { longScroll = $0; done() }
            }
        }
        wait(0.8)
        step { [self] done in
            guard let o = app?.onboarding, let last = ArcExtensionChecklist.shared.rows.last,
                  let host = MainActor.assumeIsolated({ o.window.contentContainer.subviews.first }) else { return done() }
            host.layoutSubtreeIfNeeded()
            let name = "arcimport2.store." + last.id
            let (shown, at) = arcImport2Shows(name, in: host)
            check(shown, "arcimport2: scrolling the list brings the last row’s Web Store button into view (\(at); \(longScroll))")
            captureWindow(o.window, name: "arcimport2-long-scrolled", rounded: 24) {
                guard shown else { return done() }
                self.arcImport2Click(name, in: host) { longClick = $0; done() }
            }
        }
        wait(0.6)
        run { [self] in
            guard let last = ArcExtensionChecklist.shared.rows.last else { return }
            let url = ArcExtensionChecklist.testStoreBase?.appendingPathComponent("detail/" + last.extensionInfo.id).absoluteString
            check(c.store.todayTabs(ofSpace: c.currentSpaceID).contains { $0.url == url },
                  "arcimport2: the last row’s Web Store button, scrolled to, opens its page (\(longClick))")
            ArcExtensionChecklist.shared.testShow(saved)
        }
        wait(3)
        run { [self] in
            check(server?.requested == true, "arcimport2: loopback Web Store stand-in received the page request (\(storeClick))")
            app?.onboarding?.requestClose()
            c.openCommandBar(mode: .newTab)
            c.commandBar?.type("constellation")
            server?.stop()
            ArcExtensionChecklist.testStoreBase = nil
            ArcExtensionChecklist.testInstalled = [:]
            OnboardingController.testArcDirectory = nil
            try? FileManager.default.removeItem(at: root)
        }
        wait(0.8)
        run { [self] in
            check(c.commandBar?.resultTitles.contains(where: { $0.hasPrefix("Synthetic Arc constellation (") }) == true, "arcimport2: ⌘T renders the imported synthetic page")
            c.closeCommandBar()
            TestAnchors.frames["arcimport2.checklist"] = nil
            app?.showSettings(page: .importing)
        }
        wait(0.8)
        run { [self] in check(TestAnchors.frames["arcimport2.checklist"] != nil, "arcimport2: checklist available in Settings Import") }
    }
}

private final class ArcImport2Server {
    let listener: NWListener
    var requested = false
    init() throws {
        let p = NWParameters.tcp
        p.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        p.acceptLocalOnly = true
        listener = try NWListener(using: p)
    }
    func start(_ ready: @escaping (UInt16) -> Void) {
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let port = self?.listener.port { ready(port.rawValue) }
        }
        listener.newConnectionHandler = { [weak self] c in
            c.start(queue: .main)
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                if String(decoding: data ?? Data(), as: UTF8.self).contains("/detail/" + ArcImport2Fixture.extensionID) { self?.requested = true }
                let body = "<title>Synthetic Web Store</title>Reinstall your extension"
                c.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8), completion: .contentProcessed { _ in c.cancel() })
            }
        }
        listener.start(queue: .main)
    }
    func stop() { listener.cancel() }
}
#endif
