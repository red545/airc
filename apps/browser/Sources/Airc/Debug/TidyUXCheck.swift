// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// `--script tidyux` (both engines; AI/TidyHint.swift, docs/user/sidebar.md "Keeping your sidebar tidy"): the sidebar's
/// tidy card on a synthetic Space of 22 Today tabs on made-up example.* sites, with real driver clicks
/// (AIRC_REAL_KEYS=1, the stable UI driver, AIRC_UI_DEDICATED_SESSION=1) on every card button and every toast Undo:
///   1. the card appears once (redraws don't count again), with Tidy, Archive old tabs, Pin to Favorites, the
///      auto-archive choice (Settings' four) and Not now; the Today header's Tidy and Clear explain themselves;
///   2. Tidy (Apple Intelligence on, a scripted model) previews its folders and moves nothing; Apply makes them; the
///      toast's Undo restores the exact layout;
///   3. Archive old tabs archives exactly the tabs not viewed in 3 hours; Undo brings them all back;
///   4. Not now: no card again that day, also with more tabs; the next day it's back;
///   5. Pin to Favorites makes the most-used site a Favorite; Undo puts it back in Today;
///   6. Apple Intelligence off: Tidy groups by site without asking any model; Cancel moves nothing; the header's Tidy
///      previews too, Apply, and a real ⌘Z restores the layout;
///   7. Archive Today tabs after changes the profile's setting (the popup's item chosen in-app, labelled posted);
///   8. Clear leaves "Archived N tabs" with Undo (and the first time where they went); Undo restores them.
extension SnapshotRunner {
    private static let tuSites: [(host: String, pages: [String])] = [
        ("news.example.com", ["Morning briefing", "Harbour bridge reopens", "Weekend weather", "Local elections", "Market report"]),
        ("shop.example.net", ["Trail running shoes", "Rain jacket", "Basket", "Order history"]),
        ("recipes.example.org", ["Lemon risotto", "Weeknight curry", "Sourdough starter", "Shopping list"]),
        ("docs.example.com", ["Getting started", "Configuration", "Release notes"]),
        ("maps.example.com", ["Ferry timetable"]), ("music.example.net", ["Focus playlist"]),
        ("photos.example.org", ["Album: Coast walk"]), ("forum.example.com", ["Thread: tent advice"]),
        ("bank.example.net", ["Statements"]), ("calendar.example.org", ["Week view"]),
    ]
    private static let tuTopics: [String: String] = [
        "Lemon risotto": "Dinner Ideas", "Weeknight curry": "Dinner Ideas", "Sourdough starter": "Dinner Ideas", "Shopping list": "Dinner Ideas",
        "Trail running shoes": "Running Gear", "Rain jacket": "Running Gear", "Basket": "Running Gear",
        "Getting started": "Project Docs", "Configuration": "Project Docs", "Release notes": "Project Docs",
    ]

    @MainActor private func tuLayout(_ space: String) -> String {
        let s = c.store
        let profile = s.profile(ofSpace: space).id
        let favorites = Set(s.favorites(ofProfile: profile).map(\.id))
        let items = s.state.items.values.filter { $0.spaceID == space || favorites.contains($0.id) }
        let itemIDs = Set(items.map(\.id))
        let tabs = s.state.tabs.values.filter { $0.spaceID == space || $0.itemID.map(itemIDs.contains) == true }
        return (tabs.sorted { $0.id < $1.id }.map { "tab \($0.id) item=\($0.itemID ?? "-") folder=\($0.folderID ?? "-") order=\($0.order) today=\($0.isToday)" }
            + items.sorted { $0.id < $1.id }.map { "item \($0.id) \($0.kind) parent=\($0.parentID ?? "-") order=\($0.order) title=\($0.title ?? "-")" })
            .joined(separator: "\n")
    }

    @MainActor func tidyUXScenario() {
        let engine = app?.engine is WebKitEngine ? "WebKit" : "Chromium"
        let tag = "tidyux (\(engine))"
        guard UIDriverClient.available, ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1" else {
            run { [self] in note("FAIL-ENV \(tag): real input needs AIRC_REAL_KEYS=1, the stable UI driver and AIRC_UI_DEDICATED_SESSION=1") }
            return
        }
        let fake = P18bTabsModel(Self.tuTopics)
        var space = "", ids: [String] = [], old: [String] = [], before = ""
        var archiveAfter: ArchiveInterval = .twelveHours
        func card() -> TidyHintCardView? { c.pageView(for: space)?.rows["tidyhint"] as? TidyHintCardView }
        func divider() -> DividerRowView? { c.pageView(for: space)?.rows["divider"] as? DividerRowView }
        func folders() -> [Item] { c.store.todayRootRows(ofSpace: space).compactMap { if case .folder(let f, _) = $0 { f } else { nil } } }
        func reload() { run { [self] in c.reloadAll(animated: false); c.pageView(for: space)?.layoutSubtreeIfNeeded() } }
        func newDay(_ d: String) { run { TidyHint.dayOverride = d; TidyHint.reloadAll() }; wait(0.4); reload() }
        func activate() {
            step { [self] done in
                NSApp.activate(ignoringOtherApps: true)
                c.window.makeKeyAndOrderFront(nil)
                waitUntil({ NSApp.isActive && self.c.window.isKeyWindow }, timeout: 3) { done() }
            }
        }
        /// A real driver click at a view's centre (Quartz global coordinates, top-left origin; no --mods).
        func realClick(_ what: String, settle: Double = 0.6, _ view: @escaping () -> NSView?) {
            step { [self] done in
                c.pageView(for: space)?.layoutSubtreeIfNeeded()
                guard let v = view(), let w = v.window, let primary = NSScreen.screens.first, !v.isHidden, v.bounds.width > 4 else {
                    check(false, "\(tag) [real click] \(what): on screen")
                    return done()
                }
                // Inside the window's visible content (a row scrolled out would land on the sidebar's drag area).
                let inWindow = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
                guard w.contentView?.bounds.contains(inWindow) == true else {
                    check(false, "\(tag) [real click] \(what): inside the window (\(NSStringFromPoint(inWindow)))")
                    return done()
                }
                let g = w.convertPoint(toScreen: inWindow)
                UIDriverClient.run(["--click", String(Double(g.x.rounded())), String(Double((primary.frame.maxY - g.y).rounded()))]) { ok, out in
                    if !ok { self.note("FAIL-ENV \(tag) [real click] \(what): \(out)") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: done)
                }
            }
        }
        func clickCard(_ key: String, _ what: String) { realClick(what) { card()?.button(key) } }
        func clickUndo(_ what: String) { realClick(what, settle: 0.8) { [self] in c.toast.actionButton } }

        run { [self] in
            var o = TidyTabsPlanner.Options()
            o.timeout = 6
            TidyTabsFeature.options = o
            TidyTabsFeature.testOverride = (true, fake)
            TidyHint.dayOverride = "2031-03-01"
            TidyHint.allowedInScripts = true
            c.store.setLocalValue(TidyHint.dayKey, nil)
            c.window.setFrame(NSRect(x: 80, y: 60, width: 1200, height: 860), display: true)
            let s = c.store
            do {
                let sp = try s.createSpace(name: "Tidy UX", profileID: s.selectedSpace.profileID)
                space = sp.id
                archiveAfter = s.profile(ofSpace: sp.id).archiveAfter
                // Five hours ago: the first page of each of the first eight sites (the archive offer's tabs).
                let realNow = s.now
                var pages: [(url: String, title: String, old: Bool)] = []
                for (n, site) in Self.tuSites.enumerated() {
                    for (i, title) in site.pages.enumerated() {
                        pages.append(("https://\(site.host)/\(i)/\(title.lowercased().replacingOccurrences(of: " ", with: "-"))", title, i == 0 && n < 8))
                    }
                }
                for p in pages.reversed() {
                    if p.old { let t = realNow().addingTimeInterval(-5 * 3600); s.now = { t } }
                    let tab = try s.openTab(url: p.url, inSpace: sp.id, activate: false, title: p.title)
                    s.now = realNow
                    ids.insert(tab.id, at: 0)
                    if p.old { old.append(tab.id) }
                }
                c.switchToSpace(sp.id, animated: false)
                c.reloadAll(animated: false)
                // The archive offer never takes the page on screen.
                old.removeAll { c.visibleTabIDs.contains($0) }
            } catch {
                check(false, "\(tag): made the synthetic Space (\(error))")
                return finish()
            }
        }
        activate()
        wait(0.8)
        reload()

        // 1. The card appears once, with what it offers; the header explains Tidy and Clear.
        run { [self] in
            let k = card()
            let titles = ["tidy", "archive", "pin0", "pin1", "notnow"].map { k?.button($0)?.titleText ?? "-" }
            let popup = k?.archivePopUp.itemTitles ?? []
            check(k?.mode == .offer && titles[0] == "Tidy 22 tabs into folders" && titles[1] == "Archive \(old.count) tabs idle 3 h"
                    && titles[2] == "Pin news.example.com" && titles[3] == "Pin shop.example.net"
                    && titles[4] == "Not now" && popup == ArchiveInterval.allCases.map(\.label)
                    && k?.archivePopUp.titleOfSelectedItem == archiveAfter.label,
                  "\(tag): with 22 Today tabs the card offers Tidy, Archive, two Pin to Favorites, Settings' archive choices and Not now "
                    + "(\(titles.joined(separator: " | ")); \(popup.joined(separator: ", ")))")
            c.pageView(for: space)?.sidebarHovered = true
            let d = divider()
            d?.layoutSubtreeIfNeeded()
            check(d?.tidy.isHidden == false && d?.tidy.toolTip?.contains("Shows the folders first") == true
                    && d?.clearToolTip?.contains("Undo brings them back") == true,
                  "\(tag): the header's Tidy and Clear say what they do (\(d?.tidy.toolTip ?? "-") / \(d?.clearToolTip ?? "-"))")
            c.pageView(for: space)?.sidebarHovered = false
        }
        reload()
        reload()
        run { [self] in
            check(TidyHint.appearances[space] == 1, "\(tag): the card appeared once over three redraws (\(TidyHint.appearances[space] ?? 0))")
            before = tuLayout(space)
        }

        // 2. Tidy → preview (nothing moved) → Apply → Undo restores exactly.
        clickCard("tidy", "Tidy 22 tabs")
        step { [self] done in waitUntil({ TidyHint.previews[space] != nil }, timeout: 8) { done() } }
        reload()
        run { [self] in
            let p = TidyHint.previews[space]
            check(card()?.mode == .preview && p?.plan.folders.map(\.name) == ["Running Gear", "Dinner Ideas", "Project Docs"]
                    && p?.bySite == false && tuLayout(space) == before && card()?.button("apply") != nil,
                  "\(tag): Tidy previews three topic folders and moves nothing yet (\(p?.plan.folders.map(\.name) ?? []))")
        }
        clickCard("apply", "Apply")
        run { [self] in
            check(folders().map(\.title) == ["Running Gear", "Dinner Ideas", "Project Docs"] && TidyHint.previews[space] == nil
                    && c.toast.shownText == "Grouped 10 tabs into 3 folders" && c.toast.actionButton?.title == "Undo",
                  "\(tag): Apply makes the folders and leaves a toast with Undo (\(folders().map { $0.title ?? "-" }); \(c.toast.shownText ?? "-"))")
        }
        clickUndo("Undo the tidy")
        run { [self] in
            check(tuLayout(space) == before && folders().isEmpty, "\(tag): the toast's Undo restores the exact layout after a tidy")
            check(card() == nil, "\(tag): after a choice the card stays away today")
        }

        // 3. Archive old tabs → Undo.
        newDay("2031-03-02")
        run { [self] in check(card()?.mode == .offer && TidyHint.appearances[space] == 2, "\(tag): the next day the card is back") }
        clickCard("archive", "Archive 8 tabs")
        run { [self] in
            let gone = ids.filter { c.store.tab($0) == nil }
            check(Set(gone) == Set(old) && old.count >= 7 && c.toast.shownText == "Archived \(old.count) tabs"
                    && c.store.archivedEntries.filter { e in old.contains(e.tab.id) }.count == old.count,
                  "\(tag): exactly the \(old.count) tabs not viewed in 3 hours went to the Archive (\(gone.count) gone; \(c.toast.shownText ?? "-"))")
        }
        clickUndo("Undo the archive")
        run { [self] in check(tuLayout(space) == before, "\(tag): Undo brings the archived tabs back exactly") }

        // 4. Not now: no card for the day, also with more tabs.
        newDay("2031-03-03")
        clickCard("notnow", "Not now")
        run { [self] in
            for n in 0..<3 { _ = try? c.store.openTab(url: "https://extra.example.com/\(n)", inSpace: space, activate: false, title: "Extra \(n)") }
        }
        reload()
        run { [self] in
            check(card() == nil && c.store.localValue(TidyHint.dayKey) == "2031-03-03",
                  "\(tag): Not now hides the card for the rest of the day, also with 25 tabs")
            for t in c.store.todayRowTabs(ofSpace: space) where t.url.hasPrefix("https://extra.example.com/") { _ = try? c.store.closeTab(t.id) }
        }
        newDay("2031-03-04")
        run { [self] in
            check(card()?.mode == .offer, "\(tag): a new day brings it back")
            before = tuLayout(space)
        }

        // 5. Pin to Favorites → Undo.
        var favoritesBefore = 0
        run { [self] in favoritesBefore = c.store.favorites(ofProfile: c.store.profile(ofSpace: space).id).count }
        clickCard("pin0", "Pin news.example.com")
        run { [self] in
            let favs = c.store.favorites(ofProfile: c.store.profile(ofSpace: space).id)
            let hosts = favs.compactMap { (c.store.liveTab(forItem: $0.id)?.url ?? $0.savedURL).map(TidyTabsRules.host(of:)) }
            check(favs.count == favoritesBefore + 1 && hosts.contains("news.example.com")
                    && c.toast.shownText == "Added news.example.com to Favorites",
                  "\(tag): Pin to Favorites adds news.example.com to the grid (\(favoritesBefore) → \(favs.count); \(c.toast.shownText ?? "-"))")
        }
        clickUndo("Undo the pin")
        run { [self] in check(tuLayout(space) == before, "\(tag): Undo puts the Favorite back in Today exactly") }

        // 6. Apple Intelligence off: by site, no model; Cancel; the header's Tidy; Apply; a real ⌘Z.
        newDay("2031-03-05")
        var asked = 0
        run { [self] in
            asked = fake.asked.count
            TidyTabsFeature.testOverride = (false, fake)
            c.reloadAll(animated: false)
        }
        clickCard("tidy", "Tidy by site")
        step { [self] done in waitUntil({ TidyHint.previews[space] != nil }, timeout: 8) { done() } }
        reload()
        run { [self] in
            let p = TidyHint.previews[space]
            check(p?.bySite == true && p?.plan.folders.map(\.name) == ["news.example.com", "shop.example.net", "recipes.example.org", "docs.example.com"]
                    && fake.asked.count == asked && tuLayout(space) == before,
                  "\(tag): without Apple Intelligence Tidy previews folders by site and asks no model (\(p?.plan.folders.map(\.name) ?? []))")
        }
        clickCard("cancel", "Cancel")
        run { [self] in
            check(TidyHint.previews[space] == nil && tuLayout(space) == before && card() == nil, "\(tag): Cancel moves nothing")
            c.pageView(for: space)?.sidebarHovered = true
            divider()?.layoutSubtreeIfNeeded()
        }
        realClick("the header's Tidy") { divider()?.tidy }
        step { [self] done in waitUntil({ TidyHint.previews[space] != nil }, timeout: 8) { done() } }
        run { [self] in c.pageView(for: space)?.sidebarHovered = false }
        reload()
        run { [self] in check(card()?.mode == .preview, "\(tag): the Today header's Tidy shows the same preview (card \(card() != nil))") }
        clickCard("apply", "Apply by site")
        run { [self] in check(folders().count == 4, "\(tag): Apply makes the four site folders (\(folders().count))") }
        step { [self] done in
            UIDriverClient.run(["--key", "cmd+z", "--pid", "\(getpid())"]) { ok, out in
                if !ok { self.note("FAIL-ENV \(tag) [real key] ⌘Z: \(out)") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: done)
            }
        }
        run { [self] in check(tuLayout(space) == before, "\(tag): a real ⌘Z restores the exact layout after a tidy by site") }

        // 7. Archive Today tabs after (the popup's menu chosen in-app: posted).
        newDay("2031-03-06")
        run { [self] in
            guard let k = card() else { return check(false, "\(tag): card for the archive choice") }
            let target: ArchiveInterval = archiveAfter == .sevenDays ? .twentyFourHours : .sevenDays
            k.archivePopUp.selectItem(withTitle: target.label)
            k.archivePopUp.sendAction(k.archivePopUp.action, to: k.archivePopUp.target)
            let now = c.store.profile(ofSpace: space).archiveAfter
            check(now == target, "\(tag) [posted]: Archive Today tabs after sets the profile's auto-archive (\(now.label)), as Settings › Profiles does")
            try? c.store.updateProfile(c.store.profile(ofSpace: space).id) { $0.archiveAfter = archiveAfter }
        }

        // 8. Clear → "Archived N tabs" with Undo → restored (the page on screen, if any, stays, as Clear keeps it).
        var kept = Set<String>(), cleared = 0
        run { [self] in
            c.store.setLocalValue("tidyHint.clearExplained", nil)
            before = tuLayout(space)
            kept = c.visibleTabIDs
            cleared = c.store.todayRowTabs(ofSpace: space).filter { !kept.contains($0.id) }.count
            c.clearToday()
        }
        run { [self] in
            check(c.store.todayRowTabs(ofSpace: space).allSatisfy { kept.contains($0.id) } && cleared >= 21
                    && c.toast.shownText == "Archived \(cleared) tabs"
                    && c.toast.shownDetail == "Clear moves Today’s tabs to Library › Archive",
                  "\(tag): Clear archives Today and says so, the first time with where they went (\(c.toast.shownText ?? "-") · \(c.toast.shownDetail ?? "-"))")
        }
        clickUndo("Undo Clear")
        run { [self] in check(tuLayout(space) == before, "\(tag): Undo after Clear restores Today exactly") }

        run { [self] in
            TidyTabsFeature.testOverride = nil
            TidyTabsFeature.options = TidyTabsPlanner.Options()
            TidyHint.dayOverride = nil
            TidyHint.allowedInScripts = false
        }
    }
}
#endif
