// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit
#if canImport(AircCore)
import AircCore
#endif

/// `--script marketing`: product shots of the real app for the homepage and launch posts (assets/screenshots/). Not a
/// check and not part of the suite: it loads real public websites and waits for them, so run it only through
/// scripts/marketing-shots.sh, which builds, runs each part on the Chromium bundle and writes both image sets.
///
/// The demo is synthetic and believable: four Spaces in Airc's presets, two profiles, Favorites, pinned folders and Today
/// tabs on real public pages that look good logged out. Nobody's names, accounts or data; nothing signs in. The call, the
/// film, the radio and the shared folder are pages of our own (MarketingServer), reached as *.aircbrowser.com.
///
/// `AIRC_MARKETING_PART` picks one part per launch (each has the runner's four minutes): browser, views, media, calls,
/// settings, onboarding. Each shot is `<name>.png` at 2× in the snapshot folder; `marketing: MISSING <name>: why` says
/// what couldn't be taken.
protocol MarketingExtraShots {
    /// Shots of features still in flight in other files (MarketingPending.swift), queued at the end of `part`.
    func marketingExtraShots(part: String, demo: MarketingDemo)
}

final class MarketingDemo {
    var server: MarketingServer?
    var serverUp = false
    var personal = "", work = ""
    var space: [String: String] = [:]
    var tab: [String: String] = [:]
    var downloads: URL?

    /// One of our demo pages, by its *.aircbrowser.com name.
    static func site(_ host: String, _ path: String) -> String { "http://\(host).aircbrowser.com\(path)" }
}

extension SnapshotRunner {
    func marketingScenario() {
        let part = ProcessInfo.processInfo.environment["AIRC_MARKETING_PART"] ?? "browser"
        let d = MarketingDemo()
        note("marketing: part \(part)")
        mkPrepare(d)
        if part == "onboarding" {
            mkOnboardingShots()
        } else {
            mkSeed(d)
            switch part {
            case "browser": mkBrowserShots(d)
            case "views": mkViewShots(d)
            case "media": mkMediaShots(d)
            case "calls": mkCallShots(d)
            case "settings": mkSettingsShots(d)
            case "drm": mkDRMShots(d)
            case "basics": mkBasicsShots(d)
            case "previews": mkPreviewShots(d)
            case "windows": mkWindowsShots(d)
            case "sidebarright": mkSidebarRightShots(d)
            case "shortcuts": mkShortcutsShots(d)
            default: note("marketing: unknown part \(part)")
            }
        }
        (self as Any as? MarketingExtraShots)?.marketingExtraShots(part: part, demo: d)
        run { [self] in
            NSApp.appearance = nil
            d.server?.stop()
            note("marketing: \(part) done")
        }
    }

    // MARK: Setup

    /// The window at a MacBook's 1440 × 900, opaque (the blur can't be photographed), drawn as the active window, and
    /// the demo pages' server.
    private func mkPrepare(_ d: MarketingDemo) {
        run { [self] in
            NSApp.appearance = NSAppearance(named: .aqua)
            c.applyTranslucency(.off)
            // Off the owner's screen unless asked otherwise: our views and the engine's snapshots don't need it there.
            let onScreen = ProcessInfo.processInfo.environment["AIRC_MARKETING_ONSCREEN"] == "1"
            let origin = onScreen ? NSPoint(x: 40, y: 40) : NSPoint(x: -6000, y: -3000)
            c.window.setFrame(NSRect(origin: origin, size: NSSize(width: 1440, height: 900)), display: true)
            note("marketing: window \(NSStringFromRect(c.window.frame)) on screen \(c.window.screen != nil)")
        }
        step { [self] done in
            let port = UInt16(ProcessInfo.processInfo.environment["AIRC_MARKETING_PORT"] ?? "") ?? 0
            guard port > 0, let s = MarketingServer(port: port) else {
                note("marketing: no AIRC_MARKETING_PORT; the demo pages (call, film, radio, files) are skipped")
                return done()
            }
            d.server = s
            s.start { ok in
                d.serverUp = ok
                self.note("marketing: demo pages on 127.0.0.1:\(port) \(ok ? "up" : "FAILED")")
                done()
            }
        }
    }

    /// Four Spaces, two profiles, Favorites, folders, pinned and Today tabs. Only the shown pages load.
    private func mkSeed(_ d: MarketingDemo) {
        run { [self] in
            do {
                let store = c.store
                let personal = store.defaultProfile
                // Work is made in the store, not from the warm spare, so its download folder is set before it loads.
                let work = try store.createProfile(name: "Work", emoji: "💼", color: type(of: c.profiles).designedColor(RGBA(hex: "7EB6D5")!))
                d.personal = personal.id
                d.work = work.id
                let folder = Self.mkEngineData.appendingPathComponent(work.engineDirectory, isDirectory: true)
                let downloads = AppPaths.dataDirectory.appendingPathComponent("Marketing downloads", isDirectory: true)
                try? FileManager.default.removeItem(at: downloads)
                try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let prefs = ["download": ["default_directory": downloads.path, "prompt_for_download": false, "directory_upgrade": true],
                             "savefile": ["default_directory": downloads.path]]
                try JSONSerialization.data(withJSONObject: prefs).write(to: folder.appendingPathComponent("Preferences"))
                d.downloads = downloads

                let preset = { (name: String) in DesignTheme.preset(name)!.model }
                let first = store.selectedSpace
                try store.updateSpace(first.id) {
                    $0.name = "Personal"
                    $0.icon = .emoji("🏡")
                    $0.theme = preset("mint")
                }
                let travel = try store.createSpace(name: "Travel", icon: .emoji("✈️"), theme: preset("sky"), profileID: personal.id, after: first.id)
                let studio = try store.createSpace(name: "Studio", icon: .emoji("🎨"), theme: preset("peach"), profileID: personal.id, after: travel.id)
                let workSpace = try store.createSpace(name: "Work", icon: .emoji("💼"), theme: preset("grape"), profileID: work.id, after: studio.id)
                d.space = ["personal": first.id, "travel": travel.id, "studio": studio.id, "work": workSpace.id]

                // Favorites belong to the profile.
                for (url, title, icon) in [
                    ("https://mail.google.com/mail/u/0/#inbox", "Inbox (3) – Gmail", nil),
                    ("https://calendar.google.com/calendar/u/0/r", "Google Calendar", nil),
                    ("https://www.youtube.com/", "YouTube", "https://www.youtube.com/favicon.ico"),
                    ("https://drive.google.com/drive/my-drive", "My Drive – Google Drive", nil),
                ] as [(String, String, String?)] {
                    try favorite(url, title: title, icon: icon, profile: personal.id, space: first.id)
                }
                for (url, title, icon) in [
                    ("https://mail.google.com/mail/u/1/#inbox", "Inbox (12) – Gmail", nil),
                    ("https://calendar.google.com/calendar/u/1/r", "Google Calendar", nil),
                    ("https://app.slack.com/client", "Slack", "https://a.slack-edge.com/80588/marketing/img/meta/favicon-32.png"),
                    ("https://linear.app/papertrail/team/WEB/active", "Linear", "https://linear.app/favicon.ico"),
                    ("https://github.com/papertrail", "papertrail", "https://github.githubassets.com/favicons/favicon-dark.png"),
                    ("https://www.figma.com/files/team/papertrail", "Figma", "https://static.figma.com/app/icon/1/favicon.png"),
                ] as [(String, String, String?)] {
                    try favorite(url, title: title, icon: icon, profile: work.id, space: workSpace.id)
                }

                // Personal.
                try pin("https://docs.google.com/spreadsheets/d/demo", title: "Budget 2027 – Google Sheets", icon: nil, space: first.id)
                let recipes = try store.createFolder(named: "Recipes", inSpace: first.id)
                try pin("https://en.wikipedia.org/wiki/Pastel_de_nata", title: "Pastel de nata", icon: nil, space: first.id, parent: recipes.id)
                try pin("https://en.wikipedia.org/wiki/Shakshouka", title: "Shakshouka", icon: nil, space: first.id, parent: recipes.id)
                let reading = try store.createFolder(named: "Reading list", inSpace: first.id)
                try pin("https://en.wikipedia.org/wiki/Calm_technology", title: "Calm technology", icon: nil, space: first.id, parent: reading.id)
                try store.toggleFolder(reading.id)
                d.tab["news"] = try store.openTab(url: "https://www.nytimes.com/section/travel", inSpace: first.id, activate: false,
                                                  title: "Travel – The New York Times").id
                d.tab["natoday"] = try store.openTab(url: "https://en.wikipedia.org/wiki/Typography", inSpace: first.id, activate: false,
                                                     title: "Typography – Wikipedia").id
                d.tab["swift"] = try store.openTab(url: "https://www.swift.org/", inSpace: first.id, activate: false, title: "Swift.org").id
                d.tab["kyoto"] = try store.openTab(url: "https://en.wikivoyage.org/wiki/Kyoto", inSpace: first.id, activate: false,
                                                   title: "Kyoto – Travel guide at Wikivoyage").id
                // The UK page: the build Mac is in the UK, and apple.com asks a UK visitor to switch.
                d.tab["apple"] = try store.openTab(url: "https://www.apple.com/uk/", inSpace: first.id, title: "Apple (United Kingdom)").id

                // Travel.
                let lisbon = try store.createFolder(named: "Lisbon, March", inSpace: travel.id)
                try pin("https://www.google.com/travel/flights", title: "Flights to Lisbon", icon: nil, space: travel.id, parent: lisbon.id)
                try pin("https://www.airbnb.com/rooms/demo", title: "Alfama loft · Airbnb", icon: nil, space: travel.id, parent: lisbon.id)
                try pin("https://en.wikipedia.org/wiki/Bel%C3%A9m_Tower", title: "Belém Tower", icon: nil, space: travel.id, parent: lisbon.id)
                try pin("https://www.notion.so/demo-packing-list", title: "Packing list", icon: nil, space: travel.id)
                d.tab["trams"] = try store.openTab(url: "https://en.wikipedia.org/wiki/Trams_in_Lisbon", inSpace: travel.id, activate: false,
                                                   title: "Trams in Lisbon – Wikipedia").id
                d.tab["map"] = try store.openTab(url: "https://www.openstreetmap.org/#map=15/38.7118/-9.1366", inSpace: travel.id, activate: false,
                                                 title: "OpenStreetMap").id
                d.tab["lisbon"] = try store.openTab(url: "https://en.wikipedia.org/wiki/Lisbon", inSpace: travel.id, title: "Lisbon – Wikipedia").id

                // Studio.
                try pin("https://www.figma.com/files/demo-press", title: "Press kit – Figma", icon: "https://static.figma.com/app/icon/1/favicon.png",
                        space: studio.id)
                let inspiration = try store.createFolder(named: "Inspiration", inSpace: studio.id)
                try pin("https://en.wikipedia.org/wiki/Dieter_Rams", title: "Dieter Rams", icon: nil, space: studio.id, parent: inspiration.id)
                try pin("https://en.wikipedia.org/wiki/International_Typographic_Style", title: "Swiss Style", icon: nil, space: studio.id,
                        parent: inspiration.id)
                d.tab["color"] = try store.openTab(url: "https://en.wikipedia.org/wiki/Color_theory", inSpace: studio.id, activate: false,
                                                   title: "Color theory – Wikipedia").id
                d.tab["hig"] = try store.openTab(url: "https://developer.apple.com/design/", inSpace: studio.id, title: "Design – Apple Developer").id

                // Work.
                let launch = try store.createFolder(named: "Launch", inSpace: workSpace.id)
                try pin("https://linear.app/papertrail/project/launch", title: "Launch checklist", icon: "https://linear.app/favicon.ico",
                        space: workSpace.id, parent: launch.id)
                try pin("https://www.notion.so/demo-q4-roadmap", title: "Q4 roadmap", icon: nil, space: workSpace.id, parent: launch.id)
                try pin("https://github.com/papertrail/web", title: "papertrail/web", icon: "https://github.githubassets.com/favicons/favicon-dark.png",
                        space: workSpace.id)
                d.tab["swiftui"] = try store.openTab(url: "https://developer.apple.com/documentation/swiftui", inSpace: workSpace.id, activate: false,
                                                     title: "SwiftUI | Apple Developer Documentation").id
                d.tab["linear"] = try store.openTab(url: "https://linear.app/", inSpace: workSpace.id,
                                                    title: "Linear – Plan and build products").id
                d.tab["github"] = try store.openTab(url: "https://github.com/swiftlang/swift", inSpace: workSpace.id, activate: false,
                                                    title: "swiftlang/swift").id

                // A little history per profile, for the Command Bar.
                if let h = c.app?.history {
                    for (url, title, n) in [("https://en.wikipedia.org/wiki/Lisbon", "Lisbon – Wikipedia", 5),
                                            ("https://www.visitlisboa.com/en", "Visit Lisboa", 3),
                                            ("https://en.wikipedia.org/wiki/Lisbon_Cathedral", "Lisbon Cathedral – Wikipedia", 1),
                                            ("https://www.apple.com/", "Apple", 6)] {
                        for _ in 0..<n { h.recordVisit(profileID: personal.id, url: url, title: title, typed: n > 3) }
                    }
                    for (url, title, n) in [("https://linear.app/", "Linear – Plan and build products", 6),
                                            ("https://github.com/papertrail/web/pulls", "Pull requests · papertrail/web", 4),
                                            ("https://en.wikipedia.org/wiki/Lisbon", "Lisbon – Wikipedia", 2)] {
                        for _ in 0..<n { h.recordVisit(profileID: work.id, url: url, title: title, typed: n > 3) }
                    }
                }
                c.reloadAll(animated: false)
                c.switchToSpace(first.id, animated: false)
                c.show(d.tab["apple"]!, focus: false)
                note("marketing: seeded \(store.state.profiles.count) profiles, \(store.state.spaces.count) Spaces, \(store.state.tabs.count) tabs")
            } catch {
                note("marketing: MISSING all: the demo didn't seed (\(error))")
            }
        }
        // Work's engine profile loads now, with its download folder set.
        step { [self] done in
            c.profiles.whenLoaded(d.work, { _ in done() }, failed: { self.note("marketing: the Work profile didn't load"); done() })
        }
        mkWarmFavicons()
    }

    /// Every row's and tile's icon in the favicon cache before anything is shot, with retries: a row asks once, so an icon
    /// whose first fetch failed would stay blank for the whole part. Then the sidebar draws them.
    private func mkWarmFavicons() {
        step { [self] done in
            var keys = Set<String>()
            for i in c.store.state.items.values {
                if let k = i.faviconURL ?? i.savedURL.flatMap(FaviconCache.guess(for:)) { keys.insert(k) }
            }
            for t in c.store.state.tabs.values {
                if let k = t.faviconURL ?? FaviconCache.guess(for: t.url) { keys.insert(k) }
            }
            var left = keys.count, failed: [String] = [], finished = false
            func finish() {
                guard !finished else { return }
                finished = true
                note("marketing: favicons \(keys.count - failed.count - left) of \(keys.count)" + (failed.isEmpty ? "" : "; failed: " + failed.sorted().joined(separator: " ")))
                let shown = c.shownTabID
                c.reloadAll(animated: false)
                if let shown { c.show(shown, focus: false) }
                done()
            }
            guard left > 0 else { return finish() }
            func attempt(_ k: String, _ tries: Int) {
                FaviconCache.shared.load(k) { img in
                    if img == nil, tries > 0 { return DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { attempt(k, tries - 1) } }
                    if img == nil { failed.append(k) }
                    left -= 1
                    if left == 0 { finish() }
                }
            }
            keys.forEach { attempt($0, 2) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { finish() }
        }
    }

    static var mkEngineData: URL {
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--user-data-dir=") }) {
            return URL(fileURLWithPath: String(arg.dropFirst("--user-data-dir=".count)), isDirectory: true)
        }
        return AppPaths.chromium
    }

    // MARK: Moving around

    func mkShow(_ d: MarketingDemo, _ space: String, _ tab: String?) {
        run { [self] in
            guard let sid = d.space[space] else { return }
            if c.currentSpaceID != sid { c.switchToSpace(sid, animated: false) }
            if let t = tab.flatMap({ d.tab[$0] }) { c.show(t, focus: false) }
        }
    }

    /// Waits until the pages have loaded, their visible images too (or `timeout`), tidies away cookie and fundraising
    /// banners (as a visitor who dismissed them sees the page), then lets them paint.
    func mkSettle(_ tabs: @escaping () -> [EngineTab?], timeout: Double = 15, extra: Double = 1.4) {
        step { [self] done in
            let deadline = Date().addingTimeInterval(timeout)
            let started = Date()
            func poll() {
                let pages = tabs().compactMap { $0 }
                var left = pages.count
                var ready = Date().timeIntervalSince(started) > 0.8
                guard left > 0 else { return DispatchQueue.main.asyncAfter(deadline: .now() + extra, execute: done) }
                for p in pages {
                    p.evaluate(Self.mkProbe) { v in
                        let s = (v as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
                        let complete = s["state"] as? String == "complete" && (s["href"] as? String ?? "about:blank") != "about:blank"
                        if p.isLoading || !complete || (s["pending"] as? Int ?? 1) > 0 { ready = false }
                        left -= 1
                        guard left == 0 else { return }
                        if ready || Date() > deadline {
                            if !ready { self.note("marketing: pages not settled after \(Int(timeout)) s: " + pages.map { $0.url?.host ?? "-" }.joined(separator: ", ")) }
                            var tidy = pages.count
                            for q in pages {
                                q.evaluate(Self.mkTidy) { _ in
                                    tidy -= 1
                                    if tidy == 0 { DispatchQueue.main.asyncAfter(deadline: .now() + extra, execute: done) }
                                }
                            }
                        } else {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: poll)
                        }
                    }
                }
            }
            poll()
        }
    }

    func mkSettleShown(timeout: Double = 15, extra: Double = 1.4) {
        mkSettle({ [self] in
            if c.shownSplitID != nil { return c.splitContainer.panes.map { c.engineTab(for: $0.tabID) } }
            return [c.shownTabID.flatMap { c.engineTab(for: $0) }]
        }, timeout: timeout, extra: extra)
    }

    static let mkProbe = """
    JSON.stringify({state: document.readyState, href: location.href,
      pending: Array.from(document.images).filter(function(i){ var r = i.getBoundingClientRect();
        return r.bottom > 0 && r.top < innerHeight && r.width > 0 && !i.complete; }).length})
    """

    static let mkTidy = """
    (function(){
      var sel = ['#onetrust-consent-sdk', '#onetrust-banner-sdk', '#CybotCookiebotDialog', '.cookie-banner', '#cookie-banner',
        'cookie-consent-banner', '#ghcc', '.js-cookie-consent', '#siteNotice', '#centralNotice', '.cn-fundraising', '.frb',
        '#ac-gn-segmentbar', '.ac-gn-segmentbar', '#globalnav-segmentbar', '.globalnav-segmentbar', 'aside[role=region][aria-label*=ookie]'];
      document.querySelectorAll('#sidebar .welcome .btn-close, #sidebar .sidebar-close-controls .btn-close').forEach(function(b){ b.click(); });
      sel.forEach(function(s){ try { document.querySelectorAll(s).forEach(function(e){ e.style.setProperty('display', 'none', 'important'); }); } catch (e) {} });
      document.querySelectorAll('aside, section, div, nav').forEach(function(e){
        var r = e.getBoundingClientRect();
        if (r.top < 4 && r.height > 0 && r.height < 160 && /choose another country or region/i.test(e.textContent || '')) e.style.setProperty('display', 'none', 'important');
      });
      document.querySelectorAll('body *').forEach(function(e){
        var st = getComputedStyle(e); if (st.position !== 'fixed' && st.position !== 'sticky') return;
        var c = typeof e.className === 'string' ? e.className : '';
        if (/cookie|consent|gdpr|privacy-banner/i.test((e.id || '') + ' ' + c + ' ' + (e.getAttribute('aria-label') || ''))) e.style.setProperty('display', 'none', 'important');
      });
      return true;
    })()
    """

    // MARK: Capturing

    /// Our windows drawn as the active one (full grain), as the owner sees them when they use Airc.
    func mkActiveLook(_ w: NSWindow?) {
        guard let top = w?.contentView?.superview ?? w?.contentView else { return }
        MainActor.assumeIsolated {
            var views = [top]
            while let v = views.popLast() {
                if let b = v as? SpaceBackgroundView, b.isWindowActiveOverride != true { b.isWindowActiveOverride = true }
                views += v.subviews
            }
        }
    }

    /// The traffic lights' centres in `w`'s own points (origin bottom-left), where they're shown.
    func mkLights(_ w: NSWindow) -> [NSPoint] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { w.standardWindowButton($0) }
            .filter { !$0.isHidden && $0.alphaValue > 0.5 }
            .map { $0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: nil) }
    }

    /// The browser window as captureNow draws it (sidebar, pages, panes, Peek and overlays), as an image.
    func mkWindowImage(_ done: @escaping (NSImage?) -> Void) {
        mkActiveLook(c.window)
        c.root.needsDisplay = true
        let raw = "_raw-" + UUID().uuidString.prefix(8)
        captureNow(raw) { [self] in
            let url = dir.appendingPathComponent(raw + ".png")
            let img = (try? Data(contentsOf: url)).flatMap(NSImage.init(data:))
            try? FileManager.default.removeItem(at: url)
            done(img)
        }
    }

    /// An image of one of our windows from the window server (call and PiP windows: the page is in them), or nil.
    func mkServerImage(_ w: NSWindow) -> NSImage? {
        let raw = "_raw-" + UUID().uuidString.prefix(8)
        captureOwnWindow(w, name: raw)
        let url = dir.appendingPathComponent(raw + ".png")
        let img = (try? Data(contentsOf: url)).flatMap(NSImage.init(data:))
        try? FileManager.default.removeItem(at: url)
        return img
    }

    func mkWrite(_ name: String, canvas: NSSize, dark: Bool, _ layers: [MarketingStudio.Layer]) {
        let ok = MarketingStudio.write(MarketingStudio.render(canvas: canvas, dark: dark, layers: layers),
                                       to: dir.appendingPathComponent(name + ".png"))
        note(ok ? "marketing: shot \(name)" : "marketing: MISSING \(name): couldn't write the image")
    }

    /// The browser window, alone on the desktop; `more` adds layers (canvas points) once the window is placed.
    func mkWindowShot(_ name: String, dark: Bool = false, more: ((NSRect) -> [MarketingStudio.Layer])? = nil) {
        step { [self] done in
            mkWindowImage { img in
                guard let img else { self.note("marketing: MISSING \(name): no capture"); return done() }
                let size = self.c.root.bounds.size
                let (canvas, origin) = MarketingStudio.canvas(around: size)
                let frame = NSRect(origin: origin, size: size)
                let window = MarketingStudio.Layer(image: img, frame: frame, dark: self.mkIsDark(), lights: self.mkLights(self.c.window))
                self.mkWrite(name, canvas: canvas, dark: dark, [window] + (more?(frame) ?? []))
                done()
            }
        }
    }

    /// Whether the shown Space draws dark (its window edge).
    func mkIsDark() -> Bool {
        c.palette(for: c.store.space(c.currentSpaceID) ?? c.store.selectedSpace).isDark
    }
}
#endif
