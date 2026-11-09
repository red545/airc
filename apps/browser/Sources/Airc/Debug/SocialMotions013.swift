// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit

// social-needs: bde185a (Airc 0.1.3's source: tools/social/mac-frames.sh builds this file into that release and later)

/// The social studio's motions of features that shipped in Airc 0.1.3 (SocialMotions.swift has 0.1.2's, SocialNext.swift
/// those of no release yet). A build of an older release's source leaves this file out:
///   - notes: a new note in Travel typed a letter at a time (a frame every three, about twelve letters a second): its
///     name, a line, `## ` becoming a heading and `[] ` a checklist as they're typed, then a Capture of the demo trip
///     page pasted in with ⌘V;
///   - sitesearch: ⌘T in Travel, "wiki" typed a letter at a time ("Search Wikipedia · Press Tab"), Tab, then "Belém Tower"
///     typed into Wikipedia's search (as MarketingParityP07.swift sets it up);
///   - fullpage: ⇧⌘2 on the demo's long itinerary, then Full Page: "Capture in Progress", then the whole page;
///   - themes: Wikipedia with a Boost that uses only Arc's palette variables, the Space's theme changed through a few
///     presets: the page follows each one (ThemeShots.swift's Boost);
///   - devtabs: a local preview of our own (MarketingDeveloperMode.swift's Fieldwork page), in Developer Mode by itself
///     (localhost, as in Arc) with its errors counted; then swift.org, a plain tab until ⌃D (its toast), then Site
///     Controls' switch.
extension SnapshotRunner: Social013Motions {
    func social013Motion(_ motion: String) -> Bool {
        switch motion {
        case "notes": socialNotes()
        case "sitesearch": socialSiteSearch()
        case "fullpage": socialFullPage()
        case "themes": socialThemes()
        case "devtabs": socialDevTabs()
        default: return false
        }
        return true
    }

    // MARK: Notes

    func socialNotes() {
        let reel = SocialReel("notes")
        let server = socialServer()
        let board = NSPasteboard(name: NSPasteboard.Name("org.airc.social.notes.\(getpid())"))
        var pageTab = "", noteTab = ""
        // First a Capture of the demo trip page's picture on the run's own pasteboard (as MarketingNotes.swift makes it).
        run { [self] in
            guard let travel = socialSpace("Travel") else { return note("social: MISSING Space Travel") }
            c.switchToSpace(travel, animated: false)
            CaptureSession.pasteboard = { board }
            CaptureSession.recordUse = { _ in }
            pageTab = (try? c.store.openTab(url: MarketingDemo.site("trips", "/lisbon"), inSpace: travel, title: "Lisbon, four days"))?.id ?? ""
            c.reloadAll(animated: false)
            c.show(pageTab, focus: false)
        }
        mkSettleShown()
        run { [self] in c.startCapture() }
        step { [self] done in waitUntil({ CaptureSession.active(in: self.c.window)?.picturesReady == true }, timeout: 8) { done() } }
        step { [self] done in
            guard let s = CaptureSession.active(in: c.window), let page = s.shots.first else {
                note("social: MISSING notes: Capture didn't start")
                return done()
            }
            s.tab(page.tab, evaluate: "(function(){var r=document.querySelector('.sky').getBoundingClientRect();return [r.left,r.top,r.width,r.height]})()") { box in
                let o = s.overlay
                let fallback = CGRect(x: page.frame.minX + 50, y: page.frame.minY + 150, width: page.frame.width * 0.5, height: 400)
                o.selection = (box.flatMap { CaptureGeometry.elementRect(css: $0, in: page.frame, zoom: page.tab.zoomFactor, bounds: o.bounds) } ?? fallback).integral
                o.update()
                s.confirm()
                o.bar.copyButton.action?()
                done()
            }
        }
        wait(0.6)
        run { [self] in
            CaptureSession.active(in: c.window)?.cancel()
            // As ⌃⇧N makes one (WindowController.newAircNote: its first line a title), without its usage event.
            guard let t = try? c.store.createNote(inSpace: c.currentSpaceID, document: NoteDocument(blocks: [NoteBlock(kind: .heading1)])) else {
                return note("social: MISSING notes: no note")
            }
            noteTab = t.id
            if !pageTab.isEmpty { c.closeTab(pageTab); pageTab = "" }
            c.show(noteTab, focus: false)
            if let tv = c.shownNote?.textView {
                // What's typed stays as typed: place names aren't misspelled, and no automatic replacements.
                tv.isContinuousSpellCheckingEnabled = false
                tv.isAutomaticSpellingCorrectionEnabled = false
                tv.isAutomaticTextReplacementEnabled = false
                tv.isAutomaticDashSubstitutionEnabled = false
                tv.isAutomaticQuoteSubstitutionEnabled = false
            }
            c.reloadAll(animated: false)
        }
        wait(3.0)   // the "Copied" toast fades first
        socialFrame(reel, hold: 0.7, label: "new")
        // What's typed, a letter at a time as the keyboard would (the editor's Markdown reacts to the space typed after
        // `## ` or `[] `), with a frame every three letters, about twelve a second. Each label is the caption. The first
        // line is the note's name, a heading of its own.
        let parts: [(text: String, label: String)] = [
            ("Lisbon plan\n", "title"),
            ("Trams, tiles and the long light over the Tagus.\n", "text"),
            ("## Before we go\n", "heading"),
            ("[] Book the Sintra train\nTram 28 before nine\n\n", "checklist"),
        ]
        for part in parts {
            var pending = 0
            let chars = Array(part.text)
            for (n, ch) in chars.enumerated() {
                run { [self] in
                    guard let tv = c.shownNote?.textView else { return }
                    if ch == "\n" { tv.insertNewline(nil) } else { tv.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
                }
                pending += 1
                if pending == 3 || ch == "\n" || n == chars.count - 1 {
                    wait(0.05)
                    socialFrame(reel, hold: ch == "\n" ? 0.2 : Double(pending) / 12, label: part.label)
                    pending = 0
                }
            }
        }
        socialFrame(reel, hold: 0.6, label: "checklist")
        run { [self] in
            guard let tv = c.shownNote?.textView else { return }
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            if !tv.readSelection(from: board) { note("social: MISSING notes: no Capture to paste") }
            tv.scrollToBeginningOfDocument(nil)
            c.window.makeFirstResponder(nil)
        }
        wait(1.2)
        socialFrame(reel, hold: 2.4, label: "paste")
        socialWrite(reel)
        run { [self] in
            if !noteTab.isEmpty, let item = c.store.tab(noteTab)?.itemID { c.forgetPage(noteTab, close: true); try? c.store.deleteItem(item) }
            server.value?.stop()
        }
    }

    // MARK: Site Search

    func socialSiteSearch() {
        let reel = SocialReel("sitesearch")
        run { [self] in
            // Two made-up visits to Belém's pages, as the shot has, and Wikipedia's icon fetched once for the pill.
            if let h = c.app?.history {
                for (url, title) in [("https://en.wikipedia.org/wiki/Bel%C3%A9m_Tower", "Belém Tower – Wikipedia"),
                                     ("https://en.wikipedia.org/wiki/Jer%C3%B3nimos_Monastery", "Jerónimos Monastery – Wikipedia")] {
                    for _ in 0..<2 { h.recordVisit(profileID: c.store.defaultProfile.id, url: url, title: title, typed: false) }
                }
            }
            if let key = SiteSearchSettings.defaults.first(where: { $0.name == "Wikipedia" })?.homeURL.flatMap(FaviconCache.guess(for:)) {
                FaviconCache.shared.load(key) { _ in }
            }
        }
        socialShow("Travel", "wikipedia.org/wiki/Lisbon")
        socialFrame(reel, hold: 0.7, label: "page")
        run { [self] in c.openCommandBar(mode: .newTab) }
        wait(0.8)
        socialFrame(reel, hold: 0.4, label: "page")
        let short = "wiki"
        for n in 1...short.count {
            run { [self] in c.commandBar?.type(String(short.prefix(n))) }
            wait(0.5)
            socialFrame(reel, hold: n == short.count ? 1.4 : 0.14, label: "shortcut")
        }
        run { [self] in
            guard let bar = c.commandBar, let s = bar.siteCandidate else { return note("social: MISSING sitesearch: no site for “wiki”") }
            bar.enterScope(.site(s))
        }
        wait(0.6)
        socialFrame(reel, hold: 0.8, label: "tab")
        let query = "Belém Tower"
        var n = 0
        while n < query.count {
            n = min(query.count, n + 2)
            let typed = String(query.prefix(n))
            run { [self] in c.commandBar?.type(typed) }
            wait(0.45)
            if n == query.count {
                run { [self] in c.commandBar?.update(allowCompletion: false) }   // the rows again, with the icon cached
                wait(0.4)
            }
            socialFrame(reel, hold: n == query.count ? 2.2 : 2.0 / 12, label: "query")
        }
        socialWrite(reel)
        run { [self] in c.closeCommandBar() }
    }

    // MARK: Capture Full Page (SocialNext.swift's portrait starts the same way)

    func socialTripTab(_ path: String, _ title: String) -> SocialBox<String> {
        let tab = SocialBox<String>()
        run { [self] in
            guard let s = socialSpace("Personal") else { return note("social: MISSING Space Personal") }
            c.switchToSpace(s, animated: false)
            tab.value = (try? c.store.openTab(url: MarketingDemo.site("trips", path), inSpace: s, title: title))?.id
            c.reloadAll(animated: false)
            if let t = tab.value { c.show(t, focus: false) }
        }
        mkSettleShown()
        return tab
    }

    func socialFullPage() {
        let reel = SocialReel("fullpage")
        let server = socialServer()
        run { MarketingServer.extraPages["/lisbon/days"] = Self.mkCaptureDaysPage }
        let tab = socialTripTab("/lisbon/days", "Lisbon, day by day")
        socialOverlayFrame(reel, hold: 1.0, label: "page")
        run { [self] in c.startCapture() }
        step { [self] done in waitUntil({ CaptureSession.active(in: self.c.window)?.picturesReady == true }, timeout: 8) { done() } }
        wait(0.5)
        socialOverlayFrame(reel, hold: 0.9, label: "capture")
        run { [self] in CaptureSession.active(in: c.window)?.captureFullPage() }
        wait(0.15)
        socialOverlayFrame(reel, hold: 0.7, label: "progress")
        step { [self] done in
            waitUntil({ CaptureSession.active(in: self.c.window).map { $0.phase != .capturing } ?? true }, timeout: 40) { done() }
        }
        wait(0.5)
        socialOverlayFrame(reel, hold: 2.6, label: "done")
        socialWrite(reel)
        run { [self] in
            CaptureSession.active(in: c.window)?.cancel()
            MarketingServer.extraPages["/lisbon/days"] = nil
            if let t = tab.value { c.closeTab(t) }
            server.value?.stop()
        }
    }

    // MARK: Space colours on pages

    func socialThemes() {
        let reel = SocialReel("themes")
        // ThemeShots.swift's Boost: Wikipedia's own colour tokens pointed at the Space's palette.
        let css = """
            :root {
              --background-color-base: var(--arc-palette-background) !important;
              --background-color-neutral-subtle: var(--arc-palette-backgroundExtra) !important;
              --background-color-interactive-subtle: var(--arc-palette-backgroundExtra) !important;
              --background-color-interactive: var(--arc-palette-backgroundExtra) !important;
              --background-color-interactive--hover: var(--arc-palette-hover) !important;
              --color-progressive--active: var(--arc-palette-foregroundPrimary) !important;
              --color-base: var(--arc-palette-foregroundPrimary) !important;
              --color-emphasized: var(--arc-palette-foregroundPrimary) !important;
              --color-subtle: var(--arc-palette-foregroundSecondary) !important;
              --color-progressive: var(--arc-palette-focus) !important;
              --color-progressive--hover: var(--arc-palette-focus) !important;
              --border-color-base: var(--arc-palette-hover) !important;
              --border-color-subtle: var(--arc-palette-hover) !important;
            }
            html, body { background: var(--arc-palette-background) !important; color: var(--arc-palette-foregroundPrimary) !important; }
            a, a:visited { color: var(--arc-palette-foregroundPrimary) !important; text-decoration: underline !important;
                           text-decoration-color: var(--arc-palette-focus) !important; text-decoration-thickness: 2px !important; }
            .cdx-button, .vector-pinnable-header-toggle-button { color: var(--arc-palette-foregroundPrimary) !important; }
            """
        socialShow("Personal", "wikipedia.org/wiki/Typography")
        var space = ""
        var original: AircKit.SpaceTheme?
        run { [self] in
            space = c.currentSpaceID
            original = c.store.space(space)?.theme
            BoostCenter.shared?.update(domain: "wikipedia.org") { $0.name = "Space colors"; $0.css = css }
        }
        wait(1.4)
        socialFrame(reel, hold: 1.3, label: "theme")
        let presets = ["peach", "sky", "lilac", "grape", "forest"]
        for (i, preset) in presets.enumerated() {
            run { [self] in try? c.store.updateSpace(space) { $0.theme = DesignTheme.preset(preset)!.model } }
            wait(1.0)   // the page's variables follow, without a reload
            socialFrame(reel, hold: i == presets.count - 1 ? 2.0 : 1.1, label: "theme")
        }
        socialWrite(reel)
        run { [self] in
            if let original { try? c.store.updateSpace(space) { $0.theme = original } }
            BoostCenter.shared?.remove(domain: "wikipedia.org", page: nil)
        }
    }

    // MARK: Developer Mode (Arc's Dev Tabs)

    /// `name`: devtabs from 0.1.3's source (its strip: Inspect, Hard Reload, the errors); SocialNext.swift's devtoolbar
    /// draws the same from main, whose toolbar adds Network.
    func socialDevTabs(_ name: String = "devtabs") {
        let reel = SocialReel(name)
        var server: LocalPageServer?, port: UInt16 = 0
        var tab = ""
        // MarketingDeveloperMode.swift's page: a local preview of a made-up app, its bundle logging two errors.
        let mark = "<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'><rect width='32' height='32' rx='8' fill='#2f5d48'/>"
            + "<path d='M11 23V9h11v3.2h-7.4v2.6h6.4V18h-6.4v5z' fill='#f5f3ed'/></svg>"
        let icon = "<link rel=icon href='data:image/svg+xml;base64,\(Data(mark.utf8).base64EncodedString())'>"
        step { done in
            server = LocalPageServer(pages: ["/": """
            <!doctype html><title>Fieldwork · Local preview</title>\(icon)
            <style>
            *{box-sizing:border-box}body{margin:0;background:#f5f3ed;color:#243d32;font:17px -apple-system}
            nav{padding:34px 52px;border-bottom:1px solid #dce1d8;display:flex;justify-content:space-between}
            .tag{font:12px ui-monospace;color:#627567}main{padding:80px 70px}h1{font:64px Georgia;letter-spacing:-2px;margin:22px 0}
            p{max-width:560px;line-height:1.7;color:#69766c}.cards{display:flex;gap:22px;margin-top:60px}.card{padding:30px;background:#fff;border-radius:18px;flex:1;min-height:165px}.n{font:42px Georgia;margin:20px 0}.dot{color:#709477}
            </style><nav><b>Fieldwork</b><span class=tag>WORKSPACE / LOCAL PREVIEW</span></nav>
            <main><span class=tag>YOUR NEXT CHAPTER</span><h1>A little room to grow.</h1><p>A calm place for the projects taking shape.<br>Built here, one thoughtful detail at a time.</p>
            <div class=cards><div class=card><span class=tag>IN PROGRESS</span><div class=n>04</div><span class=dot>●</span> Making steady progress</div><div class=card><span class=tag>THIS WEEK</span><div class=n>12</div>Small things, shipped</div><div class=card><span class=tag>UP NEXT</span><div class=n>Friday</div>A fresh perspective</div></div></main>
            <script src="/app.js"></script>
            """])
            server?.handler = { path in
                guard path == "/app.js" else { return nil }
                return .init(headers: ["Content-Type": "text/javascript"],
                             body: "console.error('Synthetic demo: preview API is offline'); console.error('Synthetic demo: missing preview image');",
                             delay: 0.2)
            }
            server?.start { port = $0 ?? 0; done() }
            if server == nil { done() }
        }
        socialShow("Personal", "www.swift.org")
        run { [self] in
            // Arc: localhost is in Developer Mode by itself (the default; set, as MarketingDeveloperMode.swift does).
            if let app { DeveloperMode.shared.setAutomatic(true, app: app) }
            c.setSidebarWidth(300)
            if port > 0, let t = try? c.store.openTab(url: "http://localhost:\(port)/", inSpace: c.currentSpaceID) {
                tab = t.id
                c.reloadAll(animated: false)
                c.show(t.id, focus: false)
            } else {
                note("social: MISSING devtabs: no local page")
            }
        }
        mkSettleShown()
        wait(0.8)
        // On by itself for localhost (Arc): the address with its port, Inspect, Network, Reload and the errors counted.
        socialFrame(reel, hold: 2.0, label: "local")
        // Any other site is a plain tab until ⌃D.
        socialShow("Personal", "www.swift.org")
        socialFrame(reel, hold: 1.2, label: "site")
        run { [self] in c.toggleDeveloperModeForSite() }
        wait(0.8)
        socialFrame(reel, hold: 1.8, label: "ctrld")
        run { [self] in if c.siteControls == nil { c.toggleSiteControls() } }
        wait(0.8)
        socialFrame(reel, hold: 2.0, label: "controls")
        socialWrite(reel)
        run { [self] in
            if c.siteControls != nil { c.toggleSiteControls() }
            if let app { DeveloperMode.shared.set("https://www.swift.org/", on: false, app: app) }
            if !tab.isEmpty { c.closeTab(tab) }
            server?.stop()
        }
    }
}
#endif
