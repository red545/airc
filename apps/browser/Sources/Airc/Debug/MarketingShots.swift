// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit
#if canImport(AircCore)
import AircCore
#endif

/// The parts of `--script marketing` (MarketingScenario.swift): which feature each shot shows, in the demo setup.
/// assets/screenshots/README.md lists them.
extension SnapshotRunner {
    // MARK: browser: the window, the Command Bar, Spaces, profiles

    func mkBrowserShots(_ d: MarketingDemo) {
        // The hero, light: Personal (Mint) on apple.com.
        mkShow(d, "personal", "apple")
        mkSettleShown()
        mkWindowShot("hero-light")

        // The hero, dark: Work (Grape, the Work profile) on linear.app, with the system dark so pages are too.
        run { NSApp.appearance = NSAppearance(named: .darkAqua) }
        mkShow(d, "work", "linear")
        mkSettleShown()
        wait(0.8)
        mkWindowShot("hero-dark", dark: true)
        run { [self] in
            c.openCommandBar(mode: .newTab)
            c.commandBar?.type("linear")
        }
        wait(1.2)
        mkWindowShot("command-bar-dark", dark: true)
        run { [self] in
            note("marketing: command bar rows: " + (c.commandBar?.resultTitles.joined(separator: " | ") ?? "-"))
            c.closeCommandBar()
            NSApp.appearance = NSAppearance(named: .aqua)
        }
        wait(0.6)

        // Spaces: the four sidebars side by side, each in its own colour.
        var strips: [(image: NSImage, lights: [NSPoint], dark: Bool)] = []
        for (space, tab) in [("personal", "apple"), ("travel", "lisbon"), ("studio", "hig"), ("work", "linear")] {
            mkShow(d, space, tab)
            mkSettleShown(timeout: 10, extra: 0.8)
            step { [self] done in
                // Without the page card, whose shadow would show along the cut.
                c.card.isHidden = true
                mkWindowImage { img in
                    self.c.card.isHidden = false
                    if let img { strips.append((img, self.mkLights(self.c.window), self.mkIsDark())) }
                    done()
                }
            }
        }
        step { [self] done in
            defer { done() }
            guard strips.count == 4 else { return note("marketing: MISSING spaces: \(strips.count) of 4 sidebars") }
            let window = c.root.bounds.size
            // The sidebar and the margin up to the page card.
            let strip = NSSize(width: c.card.frame.minX, height: window.height)
            let gap: CGFloat = 40
            let (canvas, origin) = MarketingStudio.canvas(around: NSSize(width: 4 * strip.width + 3 * gap, height: strip.height))
            let layers = strips.enumerated().map { pair -> MarketingStudio.Layer in
                let (i, s) = pair
                let crop = Self.mkCrop(s.image, NSRect(x: 0, y: 0, width: strip.width, height: strip.height), of: window)
                return MarketingStudio.Layer(image: crop, frame: NSRect(x: origin.x + CGFloat(i) * (strip.width + gap), y: origin.y,
                                                                        width: strip.width, height: strip.height),
                                             dark: s.dark, lights: s.lights)
            }
            mkWrite("spaces", canvas: canvas, dark: false, layers)
        }

        // The Command Bar, light: Travel, "lisbon": history, open tabs and search suggestions, the top hit completed inline.
        mkShow(d, "travel", "lisbon")
        wait(0.4)
        run { [self] in
            c.openCommandBar(mode: .newTab)
            c.commandBar?.type("lisbon")
        }
        wait(1.2)
        mkWindowShot("command-bar-light")
        run { [self] in c.closeCommandBar() }

        // The Command Bar's built-in sites: "spot", a site this demo has no history of, completes to spotify.com and
        // the Spotify row comes first with its own favicon (fetched once, then cached; the wait lets it replace the
        // letter tile).
        run { [self] in
            c.openCommandBar(mode: .newTab)
            c.commandBar?.type("spot")
        }
        wait(1.2)
        mkWindowShot("command-bar-sites-light")
        run { [self] in
            note("marketing: command bar sites rows: " + (c.commandBar?.resultTitles.joined(separator: " | ") ?? "-"))
            c.closeCommandBar()
        }

        // Profiles: a new profile for some of the Spaces (Create Profile, step 2), over Studio.
        mkShow(d, "studio", "hig")
        mkSettleShown(timeout: 8, extra: 0.6)
        run { [self] in
            c.openCreateProfile(forSpace: d.space["studio"])
            guard let pm = c.createProfilePanel?.model else { return note("marketing: MISSING profiles: no Create Profile card") }
            pm.name = "Side project"
            pm.emoji = "🌱"
            pm.colorIndex = 6
        }
        wait(0.5)
        run { [self] in
            guard let pm = c.createProfilePanel?.model else { return }
            pm.step = .spaces
            if let s = d.space["studio"] { pm.chosen.insert(s) }
            if let s = d.space["travel"] { pm.chosen.insert(s) }
        }
        wait(0.7)
        mkWindowShot("profiles")
        run { [self] in c.createProfilePanel?.model.onCancel?() }
        wait(0.3)
    }

    /// The part of a window image (points, origin bottom-left) as its own image at 2×.
    static func mkCrop(_ img: NSImage, _ rect: NSRect, of window: NSSize) -> NSImage {
        let k = img.size.width / window.width
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width * 2), pixelsHigh: Int(rect.height * 2), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = rect.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(origin: .zero, size: rect.size),
                 from: NSRect(x: rect.minX * k, y: rect.minY * k, width: rect.width * k, height: rect.height * k),
                 operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let sharp = NSImage(size: rect.size)
        sharp.addRepresentation(rep)
        return sharp
    }

    // MARK: views: Split View, pinned and Favorite splits, Peek, Little Arc

    func mkViewShots(_ d: MarketingDemo) {
        // Peek: a link from the Lisbon article opens over the page, the map of Belém.
        mkShow(d, "travel", "lisbon")
        mkSettleShown()
        run { [self] in
            guard let opener = c.shownTabID.flatMap({ c.engineTab(for: $0) }) else { return note("marketing: MISSING peek: no page") }
            c.openPeek(URL(string: "https://www.openstreetmap.org/#map=16/38.6916/-9.2160")!, from: opener)
        }
        mkSettle({ [self] in [c.peek?.page] })
        wait(0.6)
        mkWindowShot("peek")
        run { [self] in c.closePeek() }
        wait(0.6)

        // Split View, three panes: the map, the city and its trams.
        run { [self] in
            guard let sid = d.space["travel"], let a = d.tab["map"], let b = d.tab["lisbon"], let t = d.tab["trams"],
                  (try? c.store.createSplit([a, b, t], inSpace: sid, focused: b)) != nil else { return note("marketing: MISSING split-view-3: no split") }
            c.reloadAll(animated: false)
            c.show(b, focus: false)
        }
        mkSettleShown()
        mkWindowShot("split-view-3")

        // Split View, two panes: Apple's design pages beside Color theory.
        run { [self] in
            guard let sid = d.space["studio"], let a = d.tab["hig"], let b = d.tab["color"],
                  (try? c.store.createSplit([a, b], inSpace: sid, focused: a)) != nil else { return note("marketing: MISSING split-view-2: no split") }
            c.switchToSpace(sid, animated: false)
            c.reloadAll(animated: false)
            c.show(a, focus: false)
        }
        mkSettleShown()
        mkWindowShot("split-view-2")

        // A pinned split: Bauhaus | Helvetica, one row in Studio's pinned section.
        run { [self] in
            guard let sid = d.space["studio"],
                  let a = try? c.store.openTab(url: "https://en.wikipedia.org/wiki/Bauhaus", inSpace: sid, activate: false, title: "Bauhaus – Wikipedia"),
                  let b = try? c.store.openTab(url: "https://en.wikipedia.org/wiki/Helvetica", inSpace: sid, activate: false, title: "Helvetica – Wikipedia"),
                  let x = try? c.store.createSplit([a.id, b.id], inSpace: sid, focused: a.id) else { return note("marketing: MISSING pinned-split: no split") }
            do {
                _ = try c.store.move(.split(x.id), to: .pinned(spaceID: sid, parentID: nil, index: 1))
            } catch { return note("marketing: MISSING pinned-split: \(error)") }
            c.reloadAll(animated: false)
            c.show(a.id, focus: false)
        }
        mkSettleShown()
        mkWindowShot("pinned-split")

        // A Favorite split: Linear | SwiftUI as one tile in Work's Favorites (dark).
        run { [self] in
            NSApp.appearance = NSAppearance(named: .darkAqua)
            guard let sid = d.space["work"], let a = d.tab["linear"], let b = d.tab["swiftui"],
                  let x = try? c.store.createSplit([a, b], inSpace: sid, focused: a) else { return note("marketing: MISSING favorite-split: no split") }
            do {
                _ = try c.store.move(.split(x.id), to: .favorites(profileID: d.work, index: 2))
            } catch { return note("marketing: MISSING favorite-split: \(error)") }
            c.switchToSpace(sid, animated: false)
            c.reloadAll(animated: false)
            c.show(a, focus: false)
        }
        mkSettleShown()
        wait(0.6)
        mkWindowShot("favorite-split", dark: true)
        // A Favorite split can have its own icon (Arc; Change Icon… in its menu): the tile whole, with the emoji.
        run { [self] in
            guard let x = c.store.favorites(ofProfile: d.work).first(where: { $0.kind == .split }) else {
                return note("marketing: MISSING favorite-split-icon: no Favorite split")
            }
            try? c.store.setItemIcon(x.id, to: "🛠️")
        }
        wait(0.5)
        mkWindowShot("favorite-split-icon", dark: true)
        run { NSApp.appearance = NSAppearance(named: .aqua) }

        // Little Arc: a link from another app opens in a small window of its own, over Personal.
        mkShow(d, "personal", "apple")
        mkSettleShown(timeout: 8, extra: 0.6)
        var little: LittleArcController?
        run { [self] in
            little = c.app?.openLittleArc(url: URL(string: "https://en.wikipedia.org/wiki/Pastel_de_nata")!, spaceID: d.space["personal"])
            if let w = little?.window { w.setFrameOrigin(NSPoint(x: c.window.frame.minX + 200, y: c.window.frame.minY + 100)) }
        }
        mkSettle({ [little?.page] })
        step { [self] done in
            guard let l = little else { note("marketing: MISSING little-arc: no window"); return done() }
            mkActiveLook(l.window)
            mkLittleArcImage(l) { small in
                self.mkWindowImage { big in
                    guard let small, let big else { self.note("marketing: MISSING little-arc: no capture"); return done() }
                    let size = self.c.root.bounds.size
                    let (canvas, origin) = MarketingStudio.canvas(around: size)
                    let frame = NSRect(origin: origin, size: size)
                    let s = l.root.bounds.size
                    let lf = NSRect(x: frame.maxX - s.width - 96, y: frame.minY + 64, width: s.width, height: s.height)
                    self.mkWrite("little-arc", canvas: canvas, dark: false, [
                        MarketingStudio.Layer(image: big, frame: frame, dark: self.mkIsDark(), lights: []),
                        MarketingStudio.Layer(image: small, frame: lf, lights: self.mkLights(l.window)),
                    ])
                    // The chip's chevron: Arc's Open In menu, the Spaces in their colours, the pointer on Travel.
                    l.showOpenInMenu()
                    guard let m = l.openInMenu else {
                        self.note("marketing: MISSING little-arc-menu: no menu")
                        l.window.close()
                        return done()
                    }
                    if let travel = d.space["travel"] { m.highlight(.space(travel)) }
                    m.content.layoutSubtreeIfNeeded()
                    let menu = self.render(m.content)
                    self.mkLittleArcImage(l) { open in
                        defer { m.close(); l.window.close(); done() }
                        guard let open, let menu else { return self.note("marketing: MISSING little-arc-menu: no capture") }
                        // Under the chip, its right edge with the chip's (window points, origin bottom-left).
                        let chip = l.chip.convert(l.chip.bounds, to: nil), ms = m.panel.frame.size
                        let mf = NSRect(x: lf.minX + chip.maxX - ms.width, y: lf.minY + chip.minY - LittleArcOpenInMenu.Metrics.gap - ms.height,
                                        width: ms.width, height: ms.height)
                        self.mkWrite("little-arc-menu", canvas: canvas, dark: false, [
                            MarketingStudio.Layer(image: big, frame: frame, dark: self.mkIsDark(), lights: []),
                            MarketingStudio.Layer(image: open, frame: lf, lights: self.mkLights(l.window)),
                            MarketingStudio.Layer(image: menu, frame: mf, radius: LittleArcOpenInMenu.Metrics.radius, dark: m.palette.isDark, shadow: .panel),
                        ])
                    }
                }
            }
        }
        // P04: a folder dropped on the sidebar (MarketingFiles.swift).
        mkFilesShots(d)
    }

    /// A Little Arc window as the screen shows it: our views, and the page from the engine's snapshot.
    func mkLittleArcImage(_ l: LittleArcController, _ done: @escaping (NSImage?) -> Void) {
        l.root.layoutSubtreeIfNeeded()
        let base = render(l.root.superview ?? l.root)
        let cardFrame = l.card.frame, size = l.root.bounds.size
        guard let page = l.page else { return done(base) }
        page.snapshot { img in
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            base?.draw(in: NSRect(origin: .zero, size: size))
            if let img {
                let r = NSRect(x: cardFrame.minX, y: size.height - cardFrame.maxY, width: cardFrame.width, height: cardFrame.height)
                NSBezierPath(roundedRect: r, xRadius: l.card.cornerRadius, yRadius: l.card.cornerRadius).addClip()
                img.draw(in: r)
            }
            NSGraphicsContext.restoreGraphicsState()
            let out = NSImage(size: size)
            out.addRepresentation(rep)
            done(out)
        }
    }

    // MARK: media: the tray, Live Calendar, Site Controls, picture in picture, downloads, the call window

    func mkMediaShots(_ d: MarketingDemo) {
        let lib = MediaLibrary.shared

        // Media controls: the radio keeps playing in a tab you've left; its controls are in the sidebar.
        run { [self] in
            guard d.serverUp, let sid = d.space["personal"],
                  let t = try? c.store.openTab(url: MarketingDemo.site("radio", "/radio"), inSpace: sid, title: "Slow Tide – Harbour Lights") else {
                return note("marketing: MISSING media-controls: no demo pages")
            }
            d.tab["radio"] = t.id
            c.reloadAll(animated: false)
            c.show(t.id, focus: false)
        }
        mkSettleShown(timeout: 8, extra: 0.4)
        step { [self] done in
            waitUntil({ d.tab["radio"].flatMap { lib.media?.sessions[$0]?.session.playback } == .playing }, timeout: 6) {
                if let id = d.tab["radio"] { self.note("marketing: radio \(lib.media?.sessions[id].map { "\($0.session.playback) \($0.session.title)" } ?? "no session")") }
                // Autoplay doesn't always start it: Play through the Media Session, as the tray's button does.
                if let id = d.tab["radio"], let page = self.c.engineTab(for: id), lib.media?.sessions[id]?.session.playback != .playing {
                    (self.app?.engine as? EngineMedia)?.performMediaAction("play", value: 0, in: page)
                }
                if let a = d.tab["kyoto"] { self.c.show(a, focus: false) }
                self.waitUntil({ !(lib.media?.players.isEmpty ?? true) && self.c.sidebar.tray.height > 30 }, timeout: 4) { done() }
            }
        }
        mkSettleShown(timeout: 10, extra: 1.2)
        mkWindowShot("media-controls")
        run { [self] in
            if let id = d.tab["radio"] {
                c.engineTab(for: id)?.evaluate("document.getElementById('a').pause()", completion: nil)
                c.closeTab(id)
            }
        }
        wait(0.6)

        mkShow(d, "personal", "apple")
        mkSettleShown(timeout: 8, extra: 0.4)
        // Live Calendar: the Calendar Favorite counts down to the next meeting; its card lists the day with Join.
        let calendar = CalendarCenter.shared
        var offset: TimeInterval = 0
        var start = Date()
        var calendarItem = ""
        func tile() -> FavoriteTileView? {
            guard let p = c.pageView(for: c.currentSpaceID) else { return nil }
            p.layoutSubtreeIfNeeded()
            return p.favorites.subviews.compactMap { $0 as? FavoriteTileView }.first { $0.item?.id == calendarItem }
        }
        run { [self] in
            guard let source = calendar.source as? SyntheticCalendarSource else { return note("marketing: MISSING calendar: not the synthetic calendar") }
            calendar.now = { Date().addingTimeInterval(offset) }
            let t0 = Date()
            start = t0.addingTimeInterval(5 * 60)
            func at(_ m: Double) -> Date { t0.addingTimeInterval(m * 60) }
            source.set([
                CalendarEvent(id: "review", title: "Design review", start: start, end: at(35),
                              link: MeetingLink(url: URL(string: "https://meet.google.com/abc-mnop-xyz")!, service: .meet)),
                CalendarEvent(id: "sync", title: "1:1 with Jonas", start: at(50), end: at(80),
                              link: MeetingLink(url: URL(string: "https://zoom.us/j/5550100")!, service: .zoom)),
                CalendarEvent(id: "lunch", title: "Lunch at Time Out Market", start: at(110), end: at(170)),
            ])
            calendarItem = c.store.favorites(ofProfile: d.personal).first { CalendarSites.isCalendarFavorite($0.savedURL ?? "") }?.id ?? ""
            calendar.setEnabled(true)
            calendar.clockMoved()
            c.reloadAll(animated: false)
        }
        step { [self] done in waitUntil({ calendar.tileLabel != nil }, timeout: 3) { done() } }
        wait(0.4)
        run { [self] in
            guard let t = tile() else { return note("marketing: MISSING calendar: no Calendar Favorite") }
            CalendarCard.shared.show(beside: t)
        }
        wait(0.6)
        mkWindowShot("calendar")
        run { [self] in
            CalendarCard.shared.hide()
            offset = start.addingTimeInterval(-40).timeIntervalSinceNow
            calendar.clockMoved()
        }
        wait(0.6)
        mkWindowShot("calendar-join")
        run { calendar.setEnabled(false) }

        // Site Controls from the URL field, on swift.org.
        mkShow(d, "personal", "swift")
        mkSettleShown(timeout: 10, extra: 0.6)
        run { [self] in if c.siteControls == nil { c.toggleSiteControls() } }
        wait(0.8)
        mkWindowShot("site-controls")
        run { [self] in if c.siteControls != nil { c.toggleSiteControls() } }
        wait(0.4)

        // The update button: a downloaded update waiting above the footer (a fake one: nothing installs).
        mkShow(d, "personal", "apple")
        let fakeUpdate = FakeReadyUpdate(version: "1.1 (202611200100)")
        run { UpdateCenter.shared.setReady(fakeUpdate) }
        wait(0.6)
        mkWindowShot("update-button")
        run { UpdateCenter.shared.setReady(nil) }
        wait(0.3)

        mkDownloads(d)
    }

    // MARK: calls: picture in picture with Airc's controls, a call's PiP, Meet's Document PiP bar, the call window

    func mkMedia2Shots(_ d: MarketingDemo) {
        mkPiP(d, name: "mini-player-hidden", page: MarketingDemo.site("video", "/golden-hour"), title: "Golden Hour", space: "travel",
              under: "lisbon", size: NSSize(width: 480, height: 270), kind: "video")
        mkPiP(d, name: "mini-player-pill", page: MarketingDemo.site("video", "/golden-hour"), title: "Golden Hour", space: "travel",
              under: "lisbon", size: NSSize(width: 480, height: 270), kind: "video")
        mkPiP(d, name: "picture-in-picture-call", page: MarketingDemo.site("meet", "/weekly-sync"), title: "Weekly design sync", space: "work",
              under: "linear", size: NSSize(width: 400, height: 225), kind: "video")
    }

    func mkCallShots(_ d: MarketingDemo) {
        mkPiP(d, name: "picture-in-picture", page: MarketingDemo.site("video", "/golden-hour"), title: "Golden Hour", space: "travel",
              under: "lisbon", size: NSSize(width: 480, height: 270), kind: "video")
        mkPiP(d, name: "mini-player-pill", page: MarketingDemo.site("video", "/golden-hour"), title: "Golden Hour", space: "travel",
              under: "lisbon", size: NSSize(width: 480, height: 270), kind: "video")
        mkPiP(d, name: "picture-in-picture-call", page: MarketingDemo.site("meet", "/weekly-sync"), title: "Weekly design sync", space: "work",
              under: "linear", size: NSSize(width: 400, height: 225), kind: "video")
        // Chromium validates Document PiP's URL in the browser too: a renderer
        // secure-context override cannot qualify an ordinary HTTP origin.
        mkPiP(d, name: "picture-in-picture-meet", page: "http://meet.localhost/weekly-sync?pip=document", title: "Weekly design sync",
              space: "work", under: "linear", size: nil, kind: "document")
        mkCall(d)
    }

    /// Picture in picture over another page, with Airc's controls showing (a video's or a call's), or a page's own
    /// Document PiP (`kind` "document", like Meet's) under Airc's slim top bar. Opened the way the suite's
    /// `--script pipcontrols` opens them (the host's entry, or the Media Session's enterpictureinpicture); the PiP window
    /// comes from the window server, which needs the screen unlocked.
    private func mkPiP(_ d: MarketingDemo, name: String, page url: String, title: String, space: String, under: String, size: NSSize?, kind: String) {
        #if canImport(AircCore)
        var id = ""
        let isFilm = url.contains("golden-hour")
        func page() -> EngineTab? { c.engineTab(for: id) }
        func pipWindow(_ chromium: ChromiumEngine) -> NSWindow? { page().flatMap { PiPEngineOverlay.state($0, in: chromium)?["window"] as? NSWindow } }
        run { [self] in
            guard d.serverUp, let sid = d.space[space], let t = try? c.store.openTab(url: url, inSpace: sid, title: title) else {
                return note("marketing: MISSING \(name): no demo pages")
            }
            id = t.id
            c.switchToSpace(sid, animated: false)
            c.reloadAll(animated: false)
            c.show(t.id, focus: false)
        }
        mkSettleShown(timeout: 8, extra: 0.4)
        step { [self] done in
            guard let chromium = app?.engine as? ChromiumEngine, let p = page() else { return done() }
            func open() {
                if kind == "document" {
                    // Leaving the call asks its registered handler through the
                    // normal call-window path. A second explicit request here
                    // would race that entry and replace the site's new window.
                    note("marketing: \(name): waiting for the site's automatic entry")
                } else {
                    chromium.enterPictureInPictureForHost(p) { route, opened in self.note("marketing: \(name): host entry \(route) \(opened)") }
                }
                waitUntil({ (PiPEngineOverlay.state(p, in: chromium)?["kind"] as? String) == kind && pipWindow(chromium)?.isVisible == true }, timeout: 6) {
                    guard let w = pipWindow(chromium) else {
                        p.evaluate("JSON.stringify(typeof state === 'function' ? state() : {})") { v in
                            self.note("marketing: \(name): no PiP; engine \(PiPEngineOverlay.state(p, in: chromium).map { "\($0)" } ?? "none"), page \(v ?? "-")")
                            done()
                        }
                        return
                    }
                    if let size {
                        let f = w.frame, v = w.screen?.visibleFrame.insetBy(dx: 20, dy: 20) ?? .infinite
                        let x = min(max(f.minX, v.minX), v.maxX - size.width), y = min(max(f.maxY - size.height, v.minY), v.maxY - size.height)
                        w.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
                    }
                    // The page it floats over, while the compositor draws the new size.
                    if let t = d.tab[under] {
                        if let s = d.space[space], self.c.currentSpaceID != s { self.c.switchToSpace(s, animated: false) }
                        self.c.show(t, focus: false)
                    }
                    // A hidden tab's video pauses when the tab is left; the PiP's Play (the Media Session) resumes it.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        if isFilm, MediaLibrary.shared.media?.sessions[id]?.session.playback != .playing {
                            self.note("marketing: \(name): paused after the tab switch; resuming through the Media Session")
                            chromium.performMediaAction("play", value: 0, in: p)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: done)
                    }
                }
            }
            func go() {
                // Meet opens its own PiP when you leave its tab: leave it first, then the Media Session's action.
                if kind == "document" {
                    if let t = d.tab[under] { c.show(t, focus: false) }
                    return DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: open)
                }
                // The film plays first (play needs a gesture), once its clip is recorded.
                guard isFilm else { return open() }
                waitUntil({ p.title.contains("ready") }, timeout: 10) {
                    chromium.devToolsCall("Runtime.evaluate", params: ["expression": "start()", "userGesture": true, "awaitPromise": true, "returnByValue": true],
                                          in: p) { _, _ in DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: open) }
                }
            }
            // A call's video plays once its peer connection is up; the host's entry takes a playing video.
            func whenPlaying(_ n: Int) {
                p.evaluate("JSON.stringify(typeof state === 'function' ? state() : {playing: true})") { v in
                    let st = (v as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
                    if (st["playing"] as? Bool) == true || n > 40 { return go() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { whenPlaying(n + 1) }
                }
            }
            isFilm ? go() : whenPlaying(0)
        }
        mkSettleShown(timeout: 10, extra: 0.8)
        step { [self] done in
            guard let chromium = app?.engine as? ChromiumEngine, let p = page(), let w = pipWindow(chromium) else {
                note("marketing: MISSING \(name): no PiP window"); return done()
            }
            if name == "mini-player-hidden" {
                PiPOverlays.shared.controls(for: p)?.hide.action?()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.mkWindowShotNow(name, dark: self.mkIsDark(), done) }
                return
            }
            PiPOverlays.shared.controls(for: p)?.pointerMoved()
            if name == "mini-player-pill" { PiPOverlays.shared.controls(for: p)?.miniPlayer.setMinimized(true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard let small = self.mkServerImage(w) else {
                    self.note("marketing: MISSING \(name): the window server gave no image (screen locked?)")
                    return done()
                }
                self.mkWindowImage { big in
                    guard let big else { self.note("marketing: MISSING \(name): no capture"); return done() }
                    let size = self.c.root.bounds.size
                    let (canvas, origin) = MarketingStudio.canvas(around: size)
                    let frame = NSRect(origin: origin, size: size)
                    let s = small.size.width > 0 ? NSSize(width: w.frame.width, height: w.frame.width * small.size.height / small.size.width) : w.frame.size
                    let dark = self.mkIsDark()
                    self.mkWrite(name, canvas: canvas, dark: dark, [
                        MarketingStudio.Layer(image: big, frame: frame, dark: dark, lights: self.mkLights(self.c.window)),
                        MarketingStudio.Layer(image: small, frame: NSRect(x: frame.maxX - s.width - 32, y: frame.minY + 32, width: s.width, height: s.height),
                                              radius: 10, dark: true, shadow: .panel),
                    ])
                    done()
                }
            }
        }
        step { [self] done in
            guard let chromium = app?.engine as? ChromiumEngine, let p = page() else { return done() }
            chromium.closePictureInPicture(p)
            waitUntil({ PiPEngineOverlay.state(p, in: chromium) == nil }, timeout: 4) {
                p.evaluate("typeof hangup === 'function' && hangup()", completion: nil)
                self.c.closeTab(id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: done)
            }
        }
        #else
        note("marketing: MISSING \(name): Chromium only")
        #endif
    }

    /// Downloads: the sidebar's progress row while a film downloads, then the Library's list. Into the run's own folder.
    private func mkDownloads(_ d: MarketingDemo) {
        let center = { MediaLibrary.shared.downloads }
        var aborted = false
        func item(_ name: String) -> DownloadCenter.Item? { center()?.items.first { $0.download.fileName == name } }
        run { [self] in
            guard d.serverUp, let sid = d.space["work"],
                  let t = try? c.store.openTab(url: MarketingDemo.site("files", "/shared"), inSpace: sid, title: "Launch assets") else {
                aborted = true
                return note("marketing: MISSING downloads: no demo pages")
            }
            d.tab["files"] = t.id
            DownloadCenter.finishedLinger = 0.3
            c.switchToSpace(sid, animated: false)
            c.reloadAll(animated: false)
            c.show(t.id, focus: false)
        }
        mkSettleShown(timeout: 8, extra: 0.4)
        let quick = MarketingServer.files.filter { $0.slowAfter == nil }
        for f in quick {
            run { [self] in
                guard !aborted, let id = d.tab["files"], let page = c.engineTab(for: id) else { return }
                page.load(URL(string: MarketingDemo.site("files", "/files/" + (f.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? f.name)))!)
            }
            step { [self] done in
                waitUntil({ aborted || item(f.name)?.download.state == .complete }, timeout: 6) {
                    guard !aborted else { return done() }
                    guard let i = item(f.name), let path = i.download.path, let folder = d.downloads?.path, path.hasPrefix(folder) else {
                        // Never into anyone's folders: stop it and everything after.
                        if let i = item(f.name) { _ = center()?.perform(.cancel, i) }
                        aborted = true
                        self.note("marketing: MISSING downloads: \(f.name) didn't download into the run's folder (\(item(f.name)?.download.path ?? "no path"))")
                        return done()
                    }
                    done()
                }
            }
        }
        wait(0.8)
        run { [self] in
            guard !aborted, let id = d.tab["files"], let page = c.engineTab(for: id), let film = MarketingServer.files.first(where: { $0.slowAfter != nil }) else { return }
            page.load(URL(string: MarketingDemo.site("files", "/files/" + (film.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? film.name)))!)
        }
        step { [self] done in
            let film = MarketingServer.files.first { $0.slowAfter != nil }!
            waitUntil({ aborted || (item(film.name)?.download.received ?? 0) > Int64(film.slowAfter!) }, timeout: 12) {
                // Enough samples for a steady "time left" (the fast first part weighs on the average for a while).
                DispatchQueue.main.asyncAfter(deadline: .now() + 9) { done() }
            }
        }
        step { [self] done in
            guard !aborted else { return done() }
            if let i = item("Launch film (4K).mov") { note("marketing: downloading \(DownloadCenter.status(i, host: false))") }
            done()
        }
        run { NSApp.appearance = NSAppearance(named: .darkAqua) }
        wait(0.5)
        step { [self] done in aborted ? done() : mkWindowShotNow("downloads", dark: true, done) }
        run { [self] in
            guard !aborted else { return }
            c.toggleLibrary()
            c.library?.model.section = .downloads
        }
        wait(0.9)
        step { [self] done in aborted ? done() : mkWindowShotNow("downloads-library", dark: true, done) }
        run { [self] in
            if c.library != nil { c.toggleLibrary() }
            if let i = item("Launch film (4K).mov"), i.download.state == .inProgress { _ = center()?.perform(.cancel, i) }
            NSApp.appearance = NSAppearance(named: .aqua)
        }
        wait(0.6)
    }

    /// The call window: a call keeps going in a floating window when you leave its tab; its controls are in the sidebar.
    private func mkCall(_ d: MarketingDemo) {
        let lib = MediaLibrary.shared
        let calls = lib.calls
        run { [self] in
            guard d.serverUp, let sid = d.space["work"],
                  let t = try? c.store.openTab(url: MarketingDemo.site("meet", "/weekly-sync"), inSpace: sid, title: "Weekly design sync") else {
                return note("marketing: MISSING call-window: no demo pages")
            }
            d.tab["call"] = t.id
            CallWindowController.followsWindowVisibility = false
            c.switchToSpace(sid, animated: false)
            c.reloadAll(animated: false)
            c.show(t.id, focus: false)
        }
        mkSettleShown(timeout: 8, extra: 0.6)
        step { [self] done in
            waitUntil({ d.tab["call"].flatMap { lib.media?.sessions[$0]?.session.isCall } == true }, timeout: 6) {
                self.note("marketing: call session \(d.tab["call"].flatMap { lib.media?.sessions[$0] }.map { "call \($0.session.isCall)" } ?? "none")")
                if let g = d.tab["linear"] { self.c.show(g, focus: false) }
                self.waitUntil({ calls.isShowing }, timeout: 4) { done() }
            }
        }
        run { NSApp.appearance = NSAppearance(named: .darkAqua) }
        mkSettleShown(timeout: 8, extra: 1.2)
        step { [self] done in
            guard calls.isShowing, let w = calls.window else { note("marketing: MISSING call-window: no call window"); return done() }
            (w as? CallPanel)?.view.flashControls()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard let small = self.mkServerImage(w) else {
                    self.note("marketing: MISSING call-window: the window server gave no image (screen locked?)")
                    return done()
                }
                self.mkWindowImage { big in
                    guard let big else { self.note("marketing: MISSING call-window: no capture"); return done() }
                    let size = self.c.root.bounds.size
                    let (canvas, origin) = MarketingStudio.canvas(around: size)
                    let frame = NSRect(origin: origin, size: size)
                    let s = w.frame.size
                    self.mkWrite("call-window", canvas: canvas, dark: true, [
                        MarketingStudio.Layer(image: big, frame: frame, dark: self.mkIsDark(), lights: self.mkLights(self.c.window)),
                        MarketingStudio.Layer(image: small, frame: NSRect(x: frame.maxX - s.width - 28, y: frame.minY + 28, width: s.width, height: s.height),
                                              radius: 14, shadow: .panel),
                    ])
                    done()
                }
            }
        }
        run { [self] in
            if let id = d.tab["call"] {
                c.engineTab(for: id)?.evaluate("hangup()", completion: nil)
                c.closeTab(id)
            }
            NSApp.appearance = NSAppearance(named: .aqua)
        }
        wait(0.6)
    }

    /// `mkWindowShot` from inside a step.
    func mkWindowShotNow(_ name: String, dark: Bool, _ done: @escaping () -> Void) {
        mkWindowImage { img in
            guard let img else { self.note("marketing: MISSING \(name): no capture"); return done() }
            let size = self.c.root.bounds.size
            let (canvas, origin) = MarketingStudio.canvas(around: size)
            self.mkWrite(name, canvas: canvas, dark: dark, [
                MarketingStudio.Layer(image: img, frame: NSRect(origin: origin, size: size), dark: self.mkIsDark(), lights: self.mkLights(self.c.window)),
            ])
            done()
        }
    }

    // MARK: settings: Appearance, Privacy and "See what Airc sends"

    func mkSettingsShots(_ d: MarketingDemo) {
        // Something to show in "See what Airc sends": a few ordinary actions.
        run { [self] in c.openCommandBar(mode: .newTab) }
        wait(0.3)
        run { [self] in c.closeCommandBar() }
        mkShow(d, "travel", "lisbon")
        mkShow(d, "personal", "apple")
        wait(0.4)
        let pages: [(SettingsPage, String, Bool)] = [(.appearance, "settings-appearance-light", false), (.appearance, "settings-appearance-dark", true),
                                                     (.privacy, "settings-privacy", false)]
        for (page, name, dark) in pages {
            run { [self] in
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                c.app?.showSettings(page: page)
                if let w = c.app?.settingsWindow?.window { w.setFrameOrigin(NSPoint(x: -6000, y: 200)) }
            }
            wait(0.9)
            step { [self] done in
                defer { done() }
                guard let w = c.app?.settingsWindow?.window, let view = w.contentView, let img = mkContentImage(w) else {
                    return note("marketing: MISSING \(name): no Settings window")
                }
                let (canvas, origin) = MarketingStudio.canvas(around: view.bounds.size)
                mkWrite(name, canvas: canvas, dark: dark, [
                    MarketingStudio.Layer(image: img, frame: NSRect(origin: origin, size: view.bounds.size), dark: dark, lights: mkLights(w)),
                ])
            }
        }
        run { [self] in
            NSApp.appearance = NSAppearance(named: .aqua)
            c.app?.showSettings(page: .privacy)
        }
        wait(0.6)
        run { TelemetrySheetState.shared.showingEvents = true }
        step { [self] done in
            waitUntil({ self.c.app?.settingsWindow?.window.attachedSheet != nil }, timeout: 3) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    defer { done() }
                    guard let w = self.c.app?.settingsWindow?.window, let sheet = w.attachedSheet, let view = w.contentView,
                          let img = self.mkContentImage(w), let card = self.mkContentImage(sheet) else {
                        return self.note("marketing: MISSING settings-privacy-events: no sheet")
                    }
                    let (canvas, origin) = MarketingStudio.canvas(around: view.bounds.size)
                    let frame = NSRect(origin: origin, size: view.bounds.size)
                    let sf = sheet.frame, wf = w.frame
                    self.mkWrite("settings-privacy-events", canvas: canvas, dark: false, [
                        MarketingStudio.Layer(image: img, frame: frame, lights: self.mkLights(w)),
                        MarketingStudio.Layer(image: card, frame: NSRect(x: frame.minX + sf.minX - wf.minX, y: frame.minY + sf.minY - wf.minY,
                                                                         width: sf.width, height: sf.height), radius: 16, shadow: .panel),
                    ])
                }
            }
        }
        run {
            TelemetrySheetState.shared.showingEvents = false
            NSApp.appearance = NSAppearance(named: .aqua)
        }
        wait(0.4)
        run { [self] in c.app?.settingsWindow?.window.orderOut(nil) }
    }

    /// A window's content (SwiftUI included) as an image.
    func mkContentImage(_ w: NSWindow) -> NSImage? {
        guard let view = w.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        return render(view)
    }

    // MARK: onboarding: the Arc import, Space colours, the default browser

    func mkOnboardingShots() {
        let fake = FakeDefaultBrowser()
        var o: OnboardingController?
        // IM-4: the import step's picker lists other browsers: synthetic ones (BrowserFixtures), never the Mac's own.
        let browsers = FileManager.default.temporaryDirectory.appendingPathComponent("AircMarketingBrowsers-\(UUID().uuidString)")
        var fixture: BrowserFixtures.Written?
        step { [self] done in
            guard let app else { return done() }
            fixture = try? BrowserFixtures.write(to: browsers, holdHistory: false, publicSites: true)
            BrowserImportLocator.testHome = fixture?.home
            DefaultBrowser.shared.system = fake
            app.settings.values.defaultBrowser = DefaultBrowserState()
            let ob = OnboardingController(app: app, mode: .rerun, fixture: OnboardingFixture.plan())
            o = ob
            onboarding = ob
            ob.present(focus: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                ob.window.setFrameOrigin(NSPoint(x: -6000, y: 300))
                done()
            }
        }
        wait(1.0)
        mkOnboardingShot("onboarding-welcome", { o })
        run { o?.model.onNext?() }
        wait(3.4)
        mkOnboardingShot("onboarding-import", { o })
        // Chrome on the same step: its profiles with their colours and what each brings.
        run { o?.model.onSelectSource?(.browser("chrome")) }
        wait(2.6)
        mkOnboardingShot("onboarding-import-browsers", { o })
        run { o?.model.onSelectSource?(.arc) }
        wait(2.4)
        run { o?.model.onImportEverything?() }
        wait(0.3)
        run {
            guard let m = o?.model else { return }
            m.hoveredProfile = "arc-profile:Profile 1"
            if let i = m.previewSpaces.firstIndex(where: { $0.profileSourceID == "arc-profile:Profile 1" }) { m.focusedSpace = i }
        }
        wait(1.6)
        mkOnboardingShot("onboarding-profiles", { o })
        run {
            o?.model.hoveredProfile = nil
            o?.model.onNext?()
        }
        wait(0.7)
        run { o?.model.onSkipLogins?() }
        wait(0.7)
        run {
            guard let m = o?.model, m.previewSpaces.count > 2 else { return }
            m.focusedSpace = 2
            m.themes[m.previewSpaces[2].sourceID] = DesignTheme.preset("ember")!.model
            m.onThemeChange?()
        }
        wait(0.7)
        mkOnboardingShot("onboarding-colours", { o })
        run { [self] in
            o?.model.onNext?()
            note("marketing: onboarding step after the colours: \(o.map { "\($0.model.step)" } ?? "-")")
        }
        wait(0.8)
        mkOnboardingShot("onboarding-default-browser", { o })
        run { o?.model.onDefaultNotNow?() }
        wait(0.8)
        mkOnboardingShot("onboarding-done", { o })
        run { [self] in
            o?.window.orderOut(nil)
            onboarding = nil
            DefaultBrowser.shared.system = SystemDefaultBrowser()
            BrowserImportLocator.testHome = nil
            try? FileManager.default.removeItem(at: browsers)
        }
    }

    func mkOnboardingShot(_ name: String, _ o: @escaping () -> OnboardingController?) {
        step { [self] done in
            defer { done() }
            guard let w = o()?.window, let view = w.contentView, let img = mkContentImage(w) else { return note("marketing: MISSING \(name): no onboarding window") }
            let (canvas, origin) = MarketingStudio.canvas(around: view.bounds.size)
            mkWrite(name, canvas: canvas, dark: false, [
                MarketingStudio.Layer(image: img, frame: NSRect(origin: origin, size: view.bounds.size), radius: AircMetrics.Onboarding.windowRadius),
            ])
        }
    }
}
#endif
