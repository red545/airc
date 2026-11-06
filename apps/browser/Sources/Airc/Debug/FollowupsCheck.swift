// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit
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
///     Stay on the second keeps the split open (the first pane loads again); then Leave closes it and its row stays.
/// Writes followups-overlap-<width>.png and followups-library-<width>.png.
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
