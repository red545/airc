// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit
import SwiftUI
#if canImport(AircCore)
import AircCore
#endif

/// `--script followups` (both engines; on Chromium under the dialog test gate, `--airc-test=modalDialogs`): follow-ups
/// to the 0.1.0 features, on loopback pages and synthetic state only.
///   - the Library's back button sits exactly where the footer's Library button is, at the sidebar's minimum and maximum
///     widths, alone and with the update pill and the downloads card showing; a real click on that spot opens the
///     Library and a second one there closes it;
///   - the downloads card (with the tray empty) and the update pill ("New Airc Version Available", a fake ready update)
///     don't overlap at either width, with the card's 12 pt above the pill's content, and both take clicks;
///   - favicons: a server that fails each icon's first request (503); the pinned row in a folder, the Favorite tile and
///     the unloaded Today row show their icons after FaviconCache's retry, two requests each, no more;
///   - a reused favicon view: a slow icon asked for by its previous content doesn't land over the image or cached icon
///     it was given since (cbsites: Spiegel's icon on Spotify's row);
///   - a Today tab dragged onto a pinned split's row joins it as one more pane (the row's right half: last);
///   - closing a pinned split whose two panes both have unsaved changes asks "Leave site?" for each of them, in turn;
///     Stay on the second keeps the split open (the first pane loads again); then Leave closes it and its row stays;
///   - with the sidebar hidden and revealed, the downloads card sits above the floating sidebar's update pill, inside
///     its column, both taking clicks, and goes back to the page's bottom-left when the sidebar leaves;
///   - the "still running" card shows both its buttons' whole labels, for one download and for several;
///   - a Today tab dragged onto the middle of a Favorite split's tile joins it as its last pane (the tile's edge still
///     places a tab between Favorites).
/// Writes followups-overlap-<width>.png, followups-library-<width>.png, followups-revealed-card.png,
/// followups-still-running-<n>.png and followups-favorite-split-drop.png.
extension SnapshotRunner {
    func followupsScenario() {
        var server: LocalPageServer?
        var base = ""
        let run0 = UUID().uuidString.prefix(8)
        let counts = RequestCounts()
        var sid = ""

        step { [self] done in
            let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32' viewBox='0 0 32 32'>"
                + "<rect width='32' height='32' rx='8' fill='#3B7BE0'/><circle cx='16' cy='16' r='7' fill='white'/></svg>"
            func page(_ title: String, _ extra: String = "") -> String {
                "<head><title>\(title)</title></head><body style='margin:0;font:20px -apple-system'><h1 style='margin:40px'>\(title)</h1>\(extra)</body>"
            }
            let leave = "<input id=f style='margin:40px'><script>onbeforeunload=function(e){e.preventDefault();e.returnValue=''}</script>"
            server = LocalPageServer(responses: [
                "/page": .init(body: page("Page")), "/s1": .init(body: page("One")), "/s2": .init(body: page("Two")),
                "/s3": .init(body: page("Three")), "/leave-a": .init(body: page("Draft A", leave)),
                "/leave-b": .init(body: page("Draft B", leave)), "/slow.svg": .init(body: svg, delay: 1.5),
                "/icon.svg": .init(body: svg),
            ])
            // Each /fail-*.svg answers 503 the first time, then the icon.
            server?.handler = { path in
                guard path.hasPrefix("/fail-") else { return nil }
                return counts.add(path) == 1 ? .init(status: "503 Service Unavailable", body: "try later") : .init(body: svg)
            }
            server?.start { port in
                if let port { base = "http://127.0.0.1:\(port)" } else { self.check(false, "followups: a loopback page server") }
                done()
            }
        }
        run { [self] in
            let home = c.currentSpaceID
            guard let s = try? c.store.createSpace(name: "Follow-ups", profileID: c.store.profile(ofSpace: home).id, after: home) else {
                return check(false, "followups: a Space for the checks")
            }
            sid = s.id
            c.switchToSpace(sid, animated: false)
        }
        followupsFavicons(base: { base }, tag: String(run0), counts: counts, space: { sid })
        followupsLibraryAndOverlap()
        followupsSplitDrop(base: { base }, space: { sid })
        followupsLeaveSite(base: { base }, space: { sid })
        followupsRevealedCard()
        followupsStillRunningButtons()
        followupsFavoriteSplitDrop(base: { base }, space: { sid })
        run { server?.stop() }
    }

    /// Requests per path, counted on the server's queue.
    final class RequestCounts {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        func add(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; counts[path, default: 0] += 1; return counts[path]! }
        func count(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[path] ?? 0 }
    }

    private func pinnedRow(_ itemID: String, in p: SpacePageView) -> TabRowView? {
        p.layoutSubtreeIfNeeded()
        return p.list.subviews.compactMap { $0 as? TabRowView }.first { $0.kind == .pinned(itemID: itemID) }
    }

    private func tile(_ itemID: String, in p: SpacePageView) -> FavoriteTileView? {
        p.layoutSubtreeIfNeeded()
        return p.favorites.subviews.compactMap { $0 as? FavoriteTileView }.first { $0.item?.id == itemID }
    }

    // MARK: Favicons

    private func followupsFavicons(base: @escaping () -> String, tag: String, counts: RequestCounts, space: @escaping () -> String) {
        var pinnedID = "", favoriteID = "", todayID = ""
        run { [self] in
            let sid = space(), b = base()
            guard !b.isEmpty, !sid.isEmpty else { return }
            let pid = c.store.profile(ofSpace: sid).id
            do {
                let folder = try c.store.createFolder(named: "Icons", inSpace: sid)
                try pin(b + "/page?pin", title: "Pinned", icon: b + "/fail-pin.svg?\(tag)", space: sid, parent: folder.id)
                pinnedID = c.store.children(of: .pinned(spaceID: sid), parent: folder.id).first?.id ?? ""
                try favorite(b + "/page?fav", title: "Favorite", icon: b + "/fail-fav.svg?\(tag)", profile: pid, space: sid)
                favoriteID = c.store.favorites(ofProfile: pid).first { $0.faviconURL?.contains("fail-fav") == true }?.id ?? ""
                let t = try c.store.openTab(url: b + "/page?today", inSpace: sid, activate: false, title: "Today")
                c.store.updateTab(t.id, faviconURL: b + "/fail-today.svg?\(tag)")
                todayID = t.id
            } catch {
                check(false, "favicons: the pinned row, Favorite and Today tab are set up (\(error))")
            }
            c.reloadAll(animated: false)
        }
        step { [self] done in
            func icons() -> (pin: Bool, fav: Bool, today: Bool) {
                guard let p = c.pageView(for: space()) else { return (false, false, false) }
                return (pinnedRow(pinnedID, in: p)?.dragFavicon != nil, tile(favoriteID, in: p)?.dragFavicon != nil,
                        todayRow(todayID, in: p)?.dragFavicon != nil)
            }
            let start = Date()
            waitUntil({ let i = icons(); return i.pin && i.fav && i.today }, timeout: 15) {
                let i = icons(), took = Date().timeIntervalSince(start)
                let n = ["/fail-pin.svg", "/fail-fav.svg", "/fail-today.svg"].map { counts.count($0) }
                self.check(i.pin && i.fav && i.today && took >= 2,
                           "favicons: after a failed first fetch (503) the icons appear on retry: pinned row in a folder \(i.pin), "
                           + "Favorite tile \(i.fav), unloaded Today row \(i.today), after \(String(format: "%.1f", took)) s")
                // A row that asks again (a reload of the sidebar) is answered from the cache: still two requests each.
                self.c.reloadAll(animated: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    let again = ["/fail-pin.svg", "/fail-fav.svg", "/fail-today.svg"].map { counts.count($0) }
                    self.check(n == [2, 2, 2] && again == n,
                               "favicons: one failure and one retry per icon, nothing more (requests \(n), after a sidebar reload \(again))")
                    done()
                }
            }
        }
        // A reused view: the image (or cached icon) it was given wins over a slow icon its previous content asked for.
        step { [self] done in
            let b = base(), palette = c.currentPalette
            let given = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in NSColor.systemRed.setFill(); r.fill(); return true }
            let first = FaviconView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
            let second = FaviconView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
            let cachedKey = b + "/fail-pin.svg?\(tag)"
            let cached = FaviconCache.shared.cached(cachedKey)
            first.set(image: nil, url: b + "/slow.svg?a\(tag)", fallbackPage: nil, palette: palette)
            first.set(image: given, url: nil, fallbackPage: nil, palette: palette)
            second.set(image: nil, url: b + "/slow.svg?b\(tag)", fallbackPage: nil, palette: palette)
            second.set(image: nil, url: cachedKey, fallbackPage: nil, palette: palette)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                let slowArrived = FaviconCache.shared.cached(b + "/slow.svg?a\(tag)") != nil
                self.check(first.shownImage === given && cached != nil && second.shownImage === cached && slowArrived,
                           "favicons: a reused view keeps the image it was given (\(first.shownImage === given)) and the cached icon "
                           + "(\(cached != nil && second.shownImage === cached)) when a slow icon for its previous content arrives (\(slowArrived))")
                done()
            }
        }
    }

    // MARK: The Library's back button and the downloads card over the update pill

    private func followupsLibraryAndOverlap() {
        let fake = FakeReadyUpdate(version: "1.0 (209901010000)")
        var savedWidth: CGFloat = 0
        run { [self] in savedWidth = c.sidebarWidth }
        func frameInRoot(_ v: NSView) -> NSRect { c.root.convert(v.bounds, from: v) }
        func centre(_ v: NSView) -> NSPoint { v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil) }
        func hit(_ p: NSPoint) -> NSView? {
            guard let frame = c.window.contentView?.superview else { return nil }
            return frame.hitTest(frame.convert(p, from: nil))
        }
        /// Opens the Library with a real click on the footer's button, compares the back button's frame with it, and
        /// closes it with a second click on the same spot.
        func library(_ label: String) {
            var spot = NSPoint.zero, footerFrame = NSRect.zero
            step { [self] done in
                let button = c.sidebar.footer.libraryButton
                c.root.layoutSubtreeIfNeeded()
                spot = centre(button)
                footerFrame = frameInRoot(button)
                if let why = realEventsBlocked {
                    note("library (\(label)): \(why): opened without a click")
                    c.toggleLibrary()
                    return done()
                }
                let reaches = hit(spot) === button
                click(at: spot, in: c.window) {
                    if !reaches { self.note("library (\(label)): the click at the Library button reached \(Self.describe(hit(spot)))") }
                    done()
                }
            }
            step { [self] done in
                waitUntil({ self.c.libraryFraction == 1 }, timeout: 3) {
                    self.c.root.layoutSubtreeIfNeeded()
                    guard let back = self.c.library?.back else {
                        self.check(false, "library (\(label)): the Library opens"); return done()
                    }
                    let f = frameInRoot(back)
                    let same = f == footerFrame
                    self.check(same && hit(spot) === back,
                               "library (\(label)): the back button is exactly where the Library button was (back \(NSStringFromRect(f)), "
                               + "Library button \(NSStringFromRect(footerFrame))) and the same spot reaches it (\(hit(spot) === back))")
                    self.captureNow("followups-library-\(label.replacingOccurrences(of: " ", with: "-"))") { done() }
                }
            }
            step { [self] done in
                if realEventsBlocked != nil {
                    c.toggleLibrary()
                    return waitUntil({ self.c.library == nil }, timeout: 3) { done() }
                }
                click(at: spot, in: c.window) {
                    self.waitUntil({ self.c.library == nil }, timeout: 3) {
                        self.check(self.c.library == nil, "library (\(label)): a second click on the same spot closes it")
                        done()
                    }
                }
            }
        }
        for (name, width) in [("min", AircMetrics.Sidebar.minWidth), ("max", AircMetrics.Sidebar.maxWidth)] {
            run { [self] in
                c.sidebarWidth = width
                c.layoutRoot()
                c.root.layoutSubtreeIfNeeded()
            }
            library("\(name) width")
            // The fake update and the card (its "still running" form; the risky-file one is laid out the same way).
            run { [self] in
                UpdateCenter.shared.setReady(fake)
                MediaLibrary.shared.showDownloadCardForTesting(count: 1)
            }
            step { [self] done in
                let u = c.sidebar.update
                waitUntil({ u.isShowing && abs(u.height - (UpdateButtonView.topInset + UpdateButtonView.pillHeight + UpdateButtonView.bottomInset)) < 0.5
                            && MediaLibrary.shared.promptView != nil }, timeout: 3) {
                    self.c.root.layoutSubtreeIfNeeded()
                    guard let card = MediaLibrary.shared.promptView else {
                        self.check(false, "download card (\(name) width): the card shows"); return done()
                    }
                    let pill = self.c.root.convert(u.pillRect, from: u), cardFrame = card.frame
                    let apart = !cardFrame.intersects(pill), gap = pill.minY - cardFrame.maxY
                    let pillHit = hit(u.convert(NSPoint(x: u.pillRect.midX, y: u.pillRect.midY), to: nil)) === u
                    let cardHit = hit(centre(card)).map { $0 === card || $0.isDescendant(of: card) } ?? false
                    self.check(apart && gap >= 12 - 0.5 && pillHit && cardHit && self.c.sidebar.tray.height == 0,
                               "download card (\(name) width, sidebar \(Int(width)) pt): the card and the update pill don't overlap "
                               + "(card \(NSStringFromRect(cardFrame)), pill \(NSStringFromRect(pill)), gap \(gap) pt) and both take clicks "
                               + "(pill \(pillHit), card \(cardHit))")
                    self.captureNow("followups-overlap-\(name)") { done() }
                }
            }
            library("\(name) width, update and card")
            run { [self] in
                MediaLibrary.shared.promptView?.model.onAnswer?(.keepDownloading)
                UpdateCenter.shared.setReady(nil)
            }
            wait(0.6)
        }
        run { [self] in
            c.sidebarWidth = savedWidth
            c.layoutRoot()
        }
    }

    // MARK: Pinned splits

    /// Two Today tabs as a split, pinned; returns the split's ID (now its item's).
    private func makePinnedSplit(_ urls: [String], titles: [String], in sid: String) -> (split: String, tabs: [String])? {
        let tabs = zip(urls, titles).compactMap { try? c.store.openTab(url: $0, inSpace: sid, activate: false, title: $1).id }
        guard tabs.count == urls.count, let x = try? c.store.createSplit(tabs, inSpace: sid, focused: tabs[0]),
              (try? c.store.move(.split(x.id), to: .pinned(spaceID: sid, parentID: nil, index: 0))) != nil,
              c.store.item(x.id)?.kind == .split else { return nil }
        return (x.id, tabs)
    }

    private func followupsSplitDrop(base: @escaping () -> String, space: @escaping () -> String) {
        var split = "", third = ""
        run { [self] in
            let sid = space(), b = base()
            guard let made = makePinnedSplit([b + "/s1", b + "/s2"], titles: ["One", "Two"], in: sid),
                  let t = try? c.store.openTab(url: b + "/s3", inSpace: sid, activate: false, title: "Three") else {
                return check(false, "split drop: a pinned split and a Today tab")
            }
            split = made.split
            third = t.id
            c.reloadAll(animated: false)
            c.show(made.tabs[0], focus: false)
        }
        waitForPage()
        step { [self] done in
            let sid = space()
            guard let p = c.pageView(for: sid), let row = (p.list.subviews.compactMap { $0 as? SplitRowView }.first { $0.splitItem?.id == split }),
                  let today = todayRow(third, in: p) else {
                check(false, "split drop: the pinned split's row and the Today row are shown"); return done()
            }
            let finish = {
                self.waitUntil({ self.c.store.panes(ofSplitItem: split).count == 3 }, timeout: 3) {
                    let urls = self.c.store.panes(ofSplitItem: split).map { $0.savedURL.flatMap { URL(string: $0)?.path } ?? "-" }
                    let pane = self.c.store.splitItem(ofPane: self.c.store.tab(third)?.itemID)?.id == split
                    self.check(urls == ["/s1", "/s2", "/s3"] && pane && self.c.store.tab(third)?.isToday == false,
                               "split drop: a Today tab dropped on a pinned split's row (right half) is its last pane (panes \(urls), "
                               + "a pane of it \(pane))")
                    done()
                }
            }
            if let why = realEventsBlocked {
                note("split drop: \(why): dropped through performDrop")
                c.performDrop(.tab(third), to: .split(spaceID: sid, target: split, leading: false))
                return finish()
            }
            let start = today.convert(NSPoint(x: 40, y: today.bounds.midY), to: nil)
            let end = row.convert(NSPoint(x: row.bounds.maxX - 18, y: row.bounds.midY), to: nil)
            drag(from: start, to: end) { finish() }
        }
    }

    // MARK: The downloads card over the revealed sidebar, the "still running" card's buttons

    private func windowHit(_ p: NSPoint) -> NSView? {
        guard let frame = c.window.contentView?.superview else { return nil }
        return frame.hitTest(frame.convert(p, from: nil))
    }

    private func takesClick(_ v: NSView) -> Bool {
        windowHit(v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)).map { $0 === v || $0.isDescendant(of: v) } ?? false
    }

    /// `capture`, then `views` drawn again over it at their place, in order: the page's snapshot is drawn over everything
    /// above the page (the floating sidebar, a card that reaches over the page).
    private func captureOnTop(_ name: String, _ views: @escaping () -> [NSView]) {
        step { [self] done in
            captureNow(name) { [self] in
                defer { done() }
                let url = dir.appendingPathComponent(name + ".png"), size = c.root.bounds.size
                guard let window = NSImage(contentsOf: url),
                      let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
                rep.size = size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                window.draw(in: NSRect(origin: .zero, size: size))
                for v in views() where v.window === c.window {
                    guard let image = render(v) else { continue }
                    let f = c.root.convert(v.bounds, from: v)
                    image.draw(in: NSRect(x: f.minX, y: size.height - f.maxY, width: f.width, height: f.height))
                }
                NSGraphicsContext.restoreGraphicsState()
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
    }

    /// SB-61 with the downloads card ("still running", as the risky-file card is laid out the same way) and a fake ready
    /// update: hidden, the card is at the page's bottom-left; revealed, it sits 12 pt above the floating sidebar's pill,
    /// at the sidebar's row inset, over the sidebar, and both take clicks; hidden again, it's back at the page.
    private func followupsRevealedCard() {
        let fake = FakeReadyUpdate(version: "1.0 (209901010001)")
        var shown: [NSView] = []
        func atPage(_ label: String) {
            run { [self] in
                guard let card = MediaLibrary.shared.promptView else { return check(false, "download card (\(label)): the card shows") }
                let page = c.card.frame
                check(card.frame.minX <= page.minX + AircMetrics.Sidebar.inset + 0.5 && card.frame.maxY <= page.maxY
                      && card.frame.maxY >= page.maxY - 30 && takesClick(card),
                      "download card (\(label)): at the page's bottom-left, taking clicks (card \(NSStringFromRect(card.frame)), "
                      + "page \(NSStringFromRect(page)))")
            }
        }
        run { [self] in
            if !c.sidebarHidden { c.toggleSidebar() }
            UpdateCenter.shared.setReady(fake)
            MediaLibrary.shared.showDownloadCardForTesting(count: 1)
        }
        wait(0.6)
        atPage("sidebar hidden")
        run { [self] in c.revealController?.reveal() }
        // The reveal is a spring on the display link: wait for the sidebar to arrive.
        step { [self] done in
            waitUntil({ (self.c.sidebar.superview.map { self.c.root.convert($0.bounds, from: $0).minX } ?? -1) >= AircMetrics.Sidebar.floatingInset - 0.5 },
                      timeout: 2) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: done) }
        }
        run { [self] in
            guard let card = MediaLibrary.shared.promptView, c.revealController?.isRevealed == true,
                  let floating = c.sidebar.superview, floating !== c.root else {
                return check(false, "download card (sidebar revealed): the card and the revealed sidebar show")
            }
            c.root.layoutSubtreeIfNeeded()
            let u = c.sidebar.update
            let side = c.root.convert(floating.bounds, from: floating), pill = c.root.convert(u.pillRect, from: u)
            let gap = pill.minY - card.frame.maxY
            let pillHit = windowHit(u.convert(NSPoint(x: u.pillRect.midX, y: u.pillRect.midY), to: nil)) === u
            check(!card.frame.intersects(pill) && gap >= 12 - 0.5 && gap <= 12 + 0.5
                  && abs(card.frame.minX - (side.minX + AircMetrics.Sidebar.inset)) < 0.5 && takesClick(card) && pillHit,
                  "download card (sidebar revealed): 12 pt above the floating sidebar's pill, at its row inset, over it, and both take "
                  + "clicks (card \(NSStringFromRect(card.frame)), sidebar \(NSStringFromRect(side)), pill \(NSStringFromRect(pill)), "
                  + "gap \(gap) pt, card \(takesClick(card)), pill \(pillHit))")
        }
        run { [self] in shown = [c.sidebar.superview, MediaLibrary.shared.promptView as NSView?].compactMap { $0 } }
        captureOnTop("followups-revealed-card", { shown })
        run { [self] in c.revealController?.hide() }
        step { [self] done in waitUntil({ self.c.revealController?.isRevealed == false }, timeout: 2) { done() } }
        wait(0.2)
        atPage("sidebar hidden again")
        run { [self] in
            MediaLibrary.shared.promptView?.model.onAnswer?(.keepDownloading)
            UpdateCenter.shared.setReady(nil)
            if c.sidebarHidden { c.toggleSidebar() }
        }
        wait(0.6)
    }

    /// The "still running" card (one download, then several): both buttons at least as wide as their whole labels need
    /// (each measured on its own in the same style), apart, inside the card.
    private func followupsStillRunningButtons() {
        for n in [1, 3] {
            run {
                TestAnchors.frames["download.closeAnyway"] = nil
                TestAnchors.frames["download.keepDownloading"] = nil
                MediaLibrary.shared.showDownloadCardForTesting(count: n)
            }
            wait(0.5)
            run { [self] in
                guard let card = MediaLibrary.shared.promptView else { return check(false, "still running (\(n)): the card shows") }
                card.hostingView.layoutSubtreeIfNeeded()
                let theme = card.model.theme
                func whole(_ title: String, _ kind: AircButtonStyle.Kind) -> CGFloat {
                    NSHostingView(rootView: Button(title) {}.buttonStyle(.airc(kind)).aircTheme(theme)).fittingSize.width
                }
                let cancelTitle = n == 1 ? "Cancel Download" : "Cancel Downloads"
                let need = (whole(cancelTitle, .secondary), whole("Keep Downloading", .primary))
                guard let cancel = TestAnchors.frames["download.closeAnyway"], let keep = TestAnchors.frames["download.keepDownloading"] else {
                    return check(false, "still running (\(n)): both buttons are laid out")
                }
                let inside = card.hostingView.bounds.insetBy(dx: -0.5, dy: -0.5)
                check(cancel.width >= need.0 - 0.5 && keep.width >= need.1 - 0.5 && !cancel.intersects(keep)
                      && inside.contains(cancel) && inside.contains(keep),
                      "still running (\(n)): “\(cancelTitle)” and “Keep Downloading” show whole (\(Int(cancel.width)) of \(Int(need.0)) pt, "
                      + "\(Int(keep.width)) of \(Int(need.1)) pt), apart, inside the card (\(NSStringFromRect(card.frame)))")
            }
            captureOnTop("followups-still-running-\(n)", { [MediaLibrary.shared.promptView].compactMap { $0 } })
            run { MediaLibrary.shared.promptView?.model.onAnswer?(.keepDownloading) }
            wait(0.4)
        }
    }

    // MARK: Favorite splits

    /// SV-2: a Today tab onto a Favorite split's tile. Where the drop would land (the tile's middle, its edge), then a
    /// real drag onto the tile's right half: the tab is the split's last pane, no longer in Today, and the split shows.
    private func followupsFavoriteSplitDrop(base: @escaping () -> String, space: @escaping () -> String) {
        var split = "", third = ""
        run { [self] in
            let sid = space(), b = base(), pid = c.store.profile(ofSpace: sid).id
            let tabs = zip([b + "/s1", b + "/s2"], ["One", "Two"]).compactMap { try? c.store.openTab(url: $0, inSpace: sid, activate: false, title: $1).id }
            guard tabs.count == 2, let x = try? c.store.createSplit(tabs, inSpace: sid, focused: tabs[0]),
                  (try? c.store.move(.split(x.id), to: .favorites(profileID: pid, index: 0))) != nil, c.store.item(x.id)?.kind == .split,
                  let t = try? c.store.openTab(url: b + "/s3", inSpace: sid, activate: false, title: "Three") else {
                return check(false, "favorite split drop: a Favorite split and a Today tab")
            }
            split = x.id
            third = t.id
            c.reloadAll(animated: false)
            c.show(tabs[0], focus: false)
        }
        waitForPage()
        step { [self] done in
            let sid = space()
            guard let p = c.pageView(for: sid), let t = tile(split, in: p), let today = todayRow(third, in: p) else {
                check(false, "favorite split drop: the Favorite split's tile and the Today row are shown"); return done()
            }
            func at(_ fx: CGFloat) -> NSPoint { t.convert(NSPoint(x: t.bounds.width * fx, y: t.bounds.midY), to: nil) }
            func joins(_ d: DropDestination?, leading: Bool) -> Bool {
                if case .split(_, let target, let l)? = d { return target == split && l == leading }
                return false
            }
            let right = p.paneDropDestination(third, at: at(0.65)), left = p.paneDropDestination(third, at: at(0.35))
            let edge = p.paneDropDestination(third, at: at(0.05))
            p.endPaneDrag()
            let between: Bool = { if case .favorites? = edge { return true }; return false }()
            func says(_ d: DropDestination?) -> String {
                switch d {
                case .split(_, let target, let leading)?: target == split ? (leading ? "first pane" : "last pane") : "another split"
                case .favorites(_, let i)?: "Favorite \(i)"
                case nil: "nothing"
                default: "elsewhere"
                }
            }
            check(joins(right, leading: false) && joins(left, leading: true) && between,
                  "favorite split drop: a Favorite split's tile takes a tab on its middle (left half first, right half last); its edge "
                  + "places it between Favorites (right half: \(says(right)), left half: \(says(left)), edge: \(says(edge)))")
            let finish = {
                self.waitUntil({ self.c.store.panes(ofSplitItem: split).count == 3 }, timeout: 3) {
                    let urls = self.c.store.panes(ofSplitItem: split).map { $0.savedURL.flatMap { URL(string: $0)?.path } ?? "-" }
                    let pane = self.c.store.splitItem(ofPane: self.c.store.tab(third)?.itemID)?.id == split
                    let shown = self.c.shownSplitID != nil && self.c.store.tab(self.c.shownTabID ?? "")?.itemID == self.c.store.tab(third)?.itemID
                    self.check(urls == ["/s1", "/s2", "/s3"] && pane && self.c.store.tab(third)?.isToday == false && shown,
                               "favorite split drop: a Today tab dropped on a Favorite split's tile (right half) is its last pane, shown in the "
                               + "split (panes \(urls), a pane of it \(pane), shown \(shown))")
                    self.captureNow("followups-favorite-split-drop") { done() }
                }
            }
            if let why = realEventsBlocked {
                note("favorite split drop: \(why): dropped through performDrop where the tile said")
                if let right { c.performDrop(.tab(third), to: right) }
                return finish()
            }
            let start = today.convert(NSPoint(x: 40, y: today.bounds.midY), to: nil)
            drag(from: start, to: at(0.65)) { finish() }
        }
    }

    private func followupsLeaveSite(base: @escaping () -> String, space: @escaping () -> String) {
        var split = "", tabs: [String] = []
        run { [self] in
            let b = base()
            guard let made = makePinnedSplit([b + "/leave-a", b + "/leave-b"], titles: ["Draft A", "Draft B"], in: space()) else {
                return check(false, "leave site: a pinned split of two pages")
            }
            (split, tabs) = made
            c.reloadAll(animated: false)
            c.show(tabs[0], focus: false)
        }
        waitForPage()
        wait(0.8)
        #if canImport(AircCore)
        if let engine = app?.engine as? ChromiumEngine {
            func page(_ k: Int) -> EngineTab? { tabs.count > k ? c.engineTab(for: tabs[k]) : nil }
            /// The engine lists a window's dialogs, whichever pane they're for: pane `k` asks when exactly one dialog is
            /// up and the close is waiting on that pane (the app's queue), its page still open.
            func dialogs() -> Int { page(0).flatMap { (engine.modalDialogState(for: $0)["dialogs"] as? [Any])?.count } ?? page(1).flatMap { (engine.modalDialogState(for: $0)["dialogs"] as? [Any])?.count } ?? 0 }
            func asking(_ k: Int) -> Bool {
                dialogs() == 1 && tabs.count > k && c.paneCloseQueue?.current == tabs[k] && page(k).map { !$0.isClosed } ?? false
            }
            func state() -> String {
                "dialogs \(dialogs()), waiting on \(c.paneCloseQueue?.current.map { $0 == tabs.first ? "the first" : $0 == tabs.last ? "the second" : $0 } ?? "none"), "
                + "pages \(page(0) == nil ? "-" : "first") \(page(1) == nil ? "-" : "second")"
            }
            /// Leave: the dialog's own Accept handler (the engine's test gate; ChromiumEngine exposes only Cancel).
            func leave(_ k: Int) -> Bool {
                guard let p = page(k) ?? page(1 - k), let core = Mirror(reflecting: p).children.first(where: { $0.label == "core" })?.value as? AircTab else { return false }
                return core.respondToModalDialog(forTesting: true)
            }
            var gate = false
            step { [self] done in
                gate = page(0).map { engine.modalDialogState(for: $0)["registeredHost"] != nil } ?? false
                guard gate else { skip("leave site: the dialog test gate is off (--airc-test=modalDialogs)"); return done() }
                // Chromium asks only pages the person used: a DevTools user gesture on each pane, and typed input.
                var left = 2
                for k in 0..<2 {
                    guard let p = page(k) else { left -= 1; continue }
                    engine.devToolsCall("Runtime.evaluate", params: ["expression": "document.getElementById('f').value='draft';navigator.userActivation.isActive",
                                                                     "userGesture": true, "returnByValue": true], in: p) { _, _ in
                        left -= 1
                        if left == 0 { done() }
                    }
                }
                if left == 0 { done() }
            }
            // 1. Close (keeps it pinned): the first pane asks; Leave; then the second asks too.
            step { [self] done in
                guard gate else { return done() }
                c.closeItemSplit(split)
                waitUntil({ asking(0) }, timeout: 5) {
                    let first = asking(0), secondOpen = page(1).map { !$0.isClosed } ?? false
                    self.check(first && secondOpen,
                               "leave site: closing a pinned split asks the first pane with unsaved changes, one question at a time (\(state()))")
                    let accepted = leave(0)
                    self.waitUntil({ asking(1) && page(0) == nil }, timeout: 5) {
                        self.check(accepted && asking(1) && page(0) == nil && self.c.store.item(split) != nil,
                                   "leave site: after Leave on the first pane, the second pane asks too (accepted \(accepted), \(state()))")
                        done()
                    }
                }
            }
            // 2. Stay on the second: the split stays open, the first pane loads again.
            step { [self] done in
                guard gate, let p = page(1) else { return done() }
                let cancelled = engine.cancelModalDialog(in: p)
                waitUntil({ self.c.paneCloseQueue == nil && page(0) != nil }, timeout: 4) {
                    let open = page(1).map { !$0.isClosed } ?? false
                    self.check(cancelled && self.c.paneCloseQueue == nil && open && page(0) != nil && self.c.store.paneTabs(ofSplitItem: split).count == 2
                               && self.c.shownSplitID == split,
                               "leave site: Stay on the second pane keeps the split open (second open \(open), first loaded again \(page(0) != nil), "
                               + "shown \(self.c.shownSplitID == split), \(state()))")
                    done()
                }
            }
            // 3. Close again: only the second still asks (the first reloaded untouched); Leave closes the split, the row stays.
            step { [self] done in
                guard gate else { return done() }
                c.closeItemSplit(split)
                waitUntil({ asking(1) }, timeout: 5) {
                    let asked = asking(1), accepted = leave(1)
                    self.waitUntil({ self.c.store.liveTab(forSplitItem: split) == nil }, timeout: 5) {
                        let closed = self.c.store.liveTab(forSplitItem: split) == nil && tabs.allSatisfy { self.c.engineTab(for: $0) == nil }
                        let row = self.c.store.pinnedRows(ofSpace: space()).contains { $0.id == split }
                        self.check(asked && accepted && closed && row,
                                   "leave site: Leave on the pane that asked closes the whole split (\(closed)) and its row stays (\(row))")
                        done()
                    }
                }
            }
            return
        }
        #endif
        // WebKit pages never ask before closing: the close still takes every pane and keeps the row.
        step { [self] done in
            c.closeItemSplit(split)
            waitUntil({ self.c.store.liveTab(forSplitItem: split) == nil }, timeout: 3) {
                let row = self.c.store.pinnedRows(ofSpace: space()).contains { $0.id == split }
                self.check(self.c.store.liveTab(forSplitItem: split) == nil && tabs.allSatisfy { self.c.engineTab(for: $0) == nil } && row,
                           "leave site: closing a pinned split closes every pane and keeps its row (WebKit never asks)")
                self.skip("leave site: \"Leave site?\" for every pane is a Chromium check")
                done()
            }
        }
    }
}
#endif
