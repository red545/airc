// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// Sorts tabs by a table of prompt title → folder name, records every request, and can be slow (ignoring cancellation,
/// as a stuck model would).
final class P18bTabsModel: TidyTabsModel, @unchecked Sendable {
    private let lock = NSLock()
    private var _asked: [TidyTabsRequest] = []
    private var _topics: [String: String]
    private var _slow: TimeInterval = 0

    init(_ topics: [String: String]) { _topics = topics }

    var asked: [TidyTabsRequest] { lock.withLock { _asked } }
    var topics: [String: String] {
        get { lock.withLock { _topics } }
        set { lock.withLock { _topics = newValue } }
    }
    var slow: TimeInterval {
        get { lock.withLock { _slow } }
        set { lock.withLock { _slow = newValue } }
    }

    func folders(for request: TidyTabsRequest) async throws -> [TidyTabsFolderAnswer] {
        let (topics, slow) = lock.withLock { () -> ([String: String], TimeInterval) in
            _asked.append(request)
            return (_topics, _slow)
        }
        if slow > 0 {
            let end = Date().addingTimeInterval(slow)
            while Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
        var order: [String] = []
        var numbers: [String: [Int]] = [:]
        for t in request.tabs {
            guard let topic = topics[t.title] else { continue }
            if numbers[topic] == nil { order.append(topic) }
            numbers[topic, default: []].append(t.number)
        }
        return order.map { TidyTabsFolderAnswer(name: $0, tabs: numbers[$0]!) }
    }
}

/// `--script parityp18b` (P18b, audit row A06, docs/user/ai.md): Tidy Tabs, on both engines, with a scripted model.
///
/// - Without Apple Intelligence: no Tidy in the Today header, no Tidy Tabs in the Command Bar, no model call.
/// - With it: Tidy shows left of Clear while the pointer is over the sidebar ("Organize Today Tabs"), and the Command
///   Bar offers Tidy Tabs.
/// - Tidy (the label pressed, as VoiceOver and a click do) makes topic folders at the top of Today (Today folders, as in
///   Arc), in Today order, with the duplicate page's tabs together; the tabs in them are still Today tabs, so they still
///   auto-archive and Clear still sees them; the pinned tab renamed by hand, the folder and the Favorite are exactly as
///   they were; the page that fits nowhere stays loose in Today; a private window's page is never asked about.
/// - While the model works the label reads "Tidying…" (shown without the pointer too) and the Command Bar offers Stop
///   Tidying Tabs; pressing it stops the tidy and nothing changes, also once the model's late answer arrives.
/// - One ⌘Z (WindowController.undo, as the key and the menu run it) restores the exact previous order and folders.
/// - The Command Bar's Tidy Tabs does the same; "No tab groups found" when the model finds none, nothing changed.
///
/// `parityp18b-write` then `parityp18b-read` (one data folder, not ephemeral): a tidy, a relaunch, then one ⌘Z restores
/// the order and folders from before the tidy. `parityp18b-real`: Apple's on-device model on synthetic tabs (only
/// where Apple Intelligence is on), logged for a person to judge, run twice to compare.
extension SnapshotRunner {
    private static let p18bTabs: [(url: String, title: String)] = [
        ("https://travel.example.com/lisbon/flights?from=BER", "Flights to Lisbon (2) - Example Travel"),
        ("https://docs.example.dev/swift/concurrency#actors", "Concurrency - The Swift Language"),
        ("https://hotels.example.org/lisbon/alfama", "Alfama hotels - Example Hotels"),
        ("https://weather.example.net/today", "Weather today"),
        ("https://forum.example.dev/t/actors/42", "Actor isolation question - Swift Forums"),
        ("https://travel.example.com/lisbon/flights?from=BER#return", "Flights to Lisbon (2) - Example Travel"),
        ("https://wiki.example.org/Trams_in_Lisbon", "Trams in Lisbon - Example Wiki"),
    ]
    private static let p18bTopics = [
        "Flights to Lisbon - Example Travel": "Lisbon Trip",
        "Alfama hotels - Example Hotels": "Lisbon Trip",
        "Trams in Lisbon - Example Wiki": "Lisbon Trip",
        "Concurrency - The Swift Language": "Swift Concurrency",
        "Actor isolation question - Swift Forums": "Swift Concurrency",
        "Private Lisbon plans - secret@example.com": "Lisbon Trip",
    ]

    /// The Space's layout and the profile's Favorites: each tab's place (Today order or its item) and each item's folder,
    /// order and name. Page titles and addresses aren't in it (a page on screen may load meanwhile).
    @MainActor private func p18bLayout(_ space: String) -> String {
        let s = c.store
        let profile = s.profile(ofSpace: space).id
        let favorites = Set(s.favorites(ofProfile: profile).map(\.id))
        let items = s.state.items.values.filter { $0.spaceID == space || favorites.contains($0.id) }
        let itemIDs = Set(items.map(\.id))
        let tabs = s.state.tabs.values.filter { $0.spaceID == space || $0.itemID.map(itemIDs.contains) == true }
        let tabLines = tabs.sorted { $0.id < $1.id }.map {
            "tab \($0.id) item=\($0.itemID ?? "-") folder=\($0.folderID ?? "-") order=\($0.order) icon=\($0.icon ?? "-")"
        }
        let itemLines = items.sorted { $0.id < $1.id }.map {
            "item \($0.id) \($0.kind) \($0.container) parent=\($0.parentID ?? "-") order=\($0.order) title=\($0.title ?? "-") url=\($0.savedURL ?? "-")"
        }
        return (tabLines + itemLines).joined(separator: "\n")
    }

    /// A Space of its own with a pinned tab renamed by hand, a folder with a tab, a Favorite, and the Today tabs (the
    /// first listed on top). Returns the Space and the Today tab IDs in Today order.
    @MainActor private func p18bMakeSpace(_ name: String, today: [(url: String, title: String)]) -> (space: String, ids: [String])? {
        let s = c.store
        do {
            let sp = try s.createSpace(name: name, profileID: s.selectedSpace.profileID)
            let pinned = try s.openTab(url: "https://mail.example.com/inbox", inSpace: sp.id, activate: false, title: "Inbox (4) - Mail")
            try s.togglePin(pinned.id, inSpace: sp.id)
            if let item = s.tab(pinned.id)?.itemID { try s.renameItem(item, to: "My Mail") }
            let visa = try s.openTab(url: "https://travel.example.com/lisbon/visa", inSpace: sp.id, activate: false, title: "Visa - Example Travel")
            _ = try s.createFolder(named: "Paperwork", inSpace: sp.id, containing: [.tab(visa.id)])
            let fav = try s.openTab(url: "https://calendar.example.com/", inSpace: sp.id, activate: false, title: "Calendar")
            try s.move(.tab(fav.id), to: .favorites(profileID: s.profile(ofSpace: sp.id).id, index: 0))
            var ids: [String] = []
            for t in today.reversed() {
                ids.insert(try s.openTab(url: t.url, inSpace: sp.id, activate: false, title: t.title).id, at: 0)
            }
            c.switchToSpace(sp.id, animated: false)
            c.reloadAll(animated: false)
            return (sp.id, ids)
        } catch {
            check(false, "parityp18b: the test Space is made (\(error))")
            return nil
        }
    }

    @MainActor private func p18bDivider(_ space: String) -> DividerRowView? {
        guard let p = c.pageView(for: space) else { return nil }
        p.layoutSubtreeIfNeeded()
        return p.rows["divider"] as? DividerRowView
    }

    @MainActor private func p18bCommands() -> [String] {
        ParityCommandCatalog.cache = nil
        return c.menuCommandActions(excluding: []).map(\.title)
    }

    @MainActor func parityP18bScenario() {
        switch script {
        case "parityp18b-write": return p18bRelaunch(write: true)
        case "parityp18b-read": return p18bRelaunch(write: false)
        case "parityp18b-real": return p18bReal()
        default: break
        }
        let tag = app?.engine is WebKitEngine ? "parityp18b (WebKit)" : "parityp18b (Chromium)"
        let fake = P18bTabsModel(Self.p18bTopics)
        var space = "", ids: [String] = []
        var before = ""
        var pinnedBefore: [String: Item] = [:]
        var server: LocalPageServer?
        var privateWindow: PrivateWindowController?
        let privateTitle = "Private Lisbon plans (3) - secret@example.com"
        // Tidy's folders: the Today folders at the top of Today (AircKit's TodayFolders.swift).
        func folders() -> [Item] { c.store.todayRootRows(ofSpace: space).compactMap { if case .folder(let f, _) = $0 { f } else { nil } } }
        func inFolder(_ f: Item) -> [String] { c.store.todayFolderTabs(f.id).map(\.id) }
        func press() { _ = p18bDivider(space)?.tidy.accessibilityPerformPress() }
        func waitIdle(_ timeout: Double = 8) {
            step { [self] done in waitUntil({ !TidyTabsFeature.isRunning(space) }, timeout: timeout) { done() } }
        }

        run {
            var o = TidyTabsPlanner.Options()
            o.timeout = 6
            TidyTabsFeature.options = o
            TidyTabsFeature.testOverride = (false, fake)
        }
        run { [self] in
            guard let made = p18bMakeSpace("Tidy", today: Self.p18bTabs) else { return finish() }
            (space, ids) = made
            pinnedBefore = Dictionary(uniqueKeysWithValues: c.store.state.items.values.filter { $0.spaceID == space }.map { ($0.id, $0) })
        }
        wait(0.6)

        // 1. Without Apple Intelligence: nothing.
        run { [self] in
            c.pageView(for: space)?.sidebarHovered = true
            let d = p18bDivider(space)
            d?.layoutSubtreeIfNeeded()
            let commands = p18bCommands()
            press()
            check(d != nil && d?.tidy.isHidden == true && !commands.contains("Tidy Tabs") && !TidyTabsFeature.isRunning(space)
                    && fake.asked.isEmpty,
                  "\(tag): without Apple Intelligence the Today header has no Tidy and the Command Bar no Tidy Tabs (divider \(d != nil), "
                    + "hidden \(d?.tidy.isHidden ?? false), asked \(fake.asked.count))")
        }

        // 2. With it: Tidy left of Clear while the pointer is over the sidebar, and in the Command Bar.
        run { [self] in
            TidyTabsFeature.testOverride = (true, fake)
            let page = c.pageView(for: space)
            page?.sidebarHovered = false
            let d = p18bDivider(space)
            let hiddenAway = d?.tidy.isHidden == true
            page?.sidebarHovered = true
            d?.layoutSubtreeIfNeeded()
            let t = d?.tidy
            let width = d?.bounds.width ?? 0
            let placed = t.map { $0.frame.width > 10 && $0.frame.maxX < width - 20 && $0.frame.minX > width / 2 } ?? false
            let commands = p18bCommands()
            check(hiddenAway && t?.isHidden == false && t?.toolTip == "Organize Today Tabs" && placed && commands.contains("Tidy Tabs"),
                  "\(tag): with Apple Intelligence, Tidy shows left of Clear on hover (\(t.map { NSStringFromRect($0.frame) } ?? "none") in "
                    + "width \(width), away hidden \(hiddenAway)) and the Command Bar has Tidy Tabs")
        }

        // A private window's page, open through all that follows.
        step { [self] done in
            server = LocalPageServer(pages: ["/private.html": "<!doctype html><title>\(privateTitle)</title><h1>Private</h1>"])
            server?.start { port in
                guard let port, let app = self.app else { return done() }
                PrivateBrowsing.shared.open(app: app) { w in
                    privateWindow = w
                    _ = w?.openPage(URL(string: "http://127.0.0.1:\(port)/private.html"))
                    done()
                }
            }
        }
        step { [self] done in waitUntil({ privateWindow?.shownPage?.title == privateTitle }, timeout: 10) { done() } }

        // 3. Stopped while the model works: nothing changes, also when its answer comes after all.
        run { [self] in
            fake.slow = 2.5
            before = p18bLayout(space)
            press()
        }
        wait(0.4)
        run { [self] in
            c.pageView(for: space)?.sidebarHovered = false
            let t = p18bDivider(space)?.tidy
            let commands = p18bCommands()
            check(TidyTabsFeature.isRunning(space) && t?.isHidden == false && t?.isWorking == true && t?.toolTip == "Stop tidying"
                    && commands.contains("Stop Tidying Tabs") && !commands.contains("Tidy Tabs"),
                  "\(tag): while the model works the label reads Tidying… without the pointer, and the Command Bar offers Stop Tidying Tabs")
            press()
            check(!TidyTabsFeature.isRunning(space) && TidyTabsFeature.lastOutcome[space] == .cancelled && p18bLayout(space) == before,
                  "\(tag): pressing Tidying… stops it at once and nothing changes")
        }
        wait(3)
        run { [self] in
            check(p18bLayout(space) == before && c.store.undoLabel != SpacesStore.tidyTabsLabel && c.store.tidyUndo(inSpace: space) == nil
                    && p18bDivider(space)?.tidy.isWorking == false,
                  "\(tag): the stopped tidy's late answer changes nothing (\(fake.asked.count) requests)")
            fake.slow = 0
            c.pageView(for: space)?.sidebarHovered = true
            before = p18bLayout(space)
            press()
        }

        // 4. Tidy.
        waitIdle()
        run { [self] in
            let f = folders()
            let lisbon = f.first.map(inFolder) ?? [], swift = f.dropFirst().first.map(inFolder) ?? []
            let roots = c.store.pinnedRoots(ofSpace: space)
            let pinnedSame = pinnedBefore.allSatisfy { c.store.item($0.key) == $0.value } && roots.count == 2
            let renamed = roots.first.map { $0.title == "My Mail" } ?? false
            let favorite = c.store.favorites(ofProfile: c.store.profile(ofSpace: space).id).count == 1
            let top = c.store.todayRootRows(ofSpace: space)
            let loose = top.compactMap { if case .today(let t) = $0 { t.id } else { nil } }
            c.pageView(for: space)?.layoutSubtreeIfNeeded()
            let foldersShown = f.allSatisfy { c.pageView(for: space)?.rows[$0.id] is FolderRowView }
            check(f.map(\.title) == ["Lisbon Trip", "Swift Concurrency"] && lisbon == [ids[0], ids[5], ids[2], ids[6]]
                    && swift == [ids[1], ids[4]] && loose == [ids[3]] && top.prefix(2).map(\.id) == f.map(\.id)
                    && f.allSatisfy { $0.container == .today(spaceID: space) },
                  "\(tag): Tidy makes Lisbon Trip and Swift Concurrency at the top of Today, in Today order, the duplicate page's tabs "
                    + "together, Weather left loose in Today (\(f.map { "\($0.title ?? "") \(inFolder($0).compactMap { ids.firstIndex(of: $0) })" }), "
                    + "loose \(loose.count))")
            // Tabs in Today folders are Today tabs: Clear sees them, and auto-archive takes them by their own age (the
            // store's clock read 13 hours on, a pure query: nothing is archived here).
            let realNow = c.store.now
            c.store.now = { realNow().addingTimeInterval(13 * 3600) }
            let due = Set(c.store.dueForAutoArchive())
            c.store.now = realNow
            let grouped = lisbon + swift
            check(grouped.allSatisfy { c.store.tab($0)?.isToday == true && due.contains($0) }
                    && Set(c.store.todayRowTabs(ofSpace: space).map(\.id)) == Set(ids),
                  "\(tag): the tidied tabs are still Today tabs: Clear sees all \(ids.count) and 12 hours idle archives them "
                    + "(\(grouped.filter(due.contains).count) of \(grouped.count) due)")
            check(pinnedSame && renamed && favorite && foldersShown,
                  "\(tag): the renamed pinned tab, the Paperwork folder and the Favorite are exactly as they were; the folders are drawn "
                    + "(pinned \(pinnedSame), renamed \(renamed), favorite \(favorite), drawn \(foldersShown))")
            let asked = fake.asked.flatMap(\.tabs)
            check(!asked.contains { $0.title.contains("Private") || $0.title.contains("secret") || $0.title.contains("Mail")
                                    || $0.title.contains("Visa") || $0.title.contains("Calendar") }
                    && !asked.contains { $0.title.contains("(2)") },
                  "\(tag): the model saw only this Space's Today pages, cleaned up; never the private window's \"\(privateTitle)\", "
                    + "pinned tabs or Favorites (\(Set(asked.map(\.title)).sorted()))")
            check(c.store.undoLabel == SpacesStore.tidyTabsLabel && TidyTabsFeature.lastMessage == "Grouped 6 tabs into 2 folders. ⌘Z to undo",
                  "\(tag): one undo step, Tidy Tabs (\(TidyTabsFeature.lastMessage ?? "-"))")
        }

        // 5. One ⌘Z.
        run { [self] in
            c.undo()
            check(p18bLayout(space) == before && c.store.tidyUndo(inSpace: space) == nil,
                  "\(tag): one ⌘Z restores the exact previous order and folders")
        }

        // 6. The Command Bar's Tidy Tabs, then ⌘Z again.
        run { [self] in
            ParityCommandCatalog.cache = nil
            c.menuCommandActions(excluding: []).first { $0.title == "Tidy Tabs" }?.run()
        }
        waitIdle()
        run { [self] in
            check(folders().map(\.title) == ["Lisbon Trip", "Swift Concurrency"], "\(tag): the Command Bar's Tidy Tabs tidies too")
            c.undo()
            check(p18bLayout(space) == before, "\(tag): …and ⌘Z puts it back")
        }

        // 7. No groups.
        run { [self] in
            fake.topics = [:]
            press()
        }
        waitIdle()
        run { [self] in
            check(TidyTabsFeature.lastMessage == "No tab groups found" && p18bLayout(space) == before
                    && TidyTabsFeature.lastOutcome[space] == .noFolders,
                  "\(tag): when the model finds no groups: \"No tab groups found\" and nothing changes")
        }

        // Eligibility follows model changes even when the pointer stays over
        // the sidebar; cached render state must not leave a stale Tidy button.
        var eligibilitySpace = "", eligibilityTabs: [String] = []
        run { [self] in
            guard let made = p18bMakeSpace("Tidy eligibility", today: [
                ("https://one.example.com/", "First page"),
                ("https://two.example.com/", "Second page"),
            ]) else { return }
            (eligibilitySpace, eligibilityTabs) = made
            c.pageView(for: eligibilitySpace)?.sidebarHovered = true
            check(p18bDivider(eligibilitySpace)?.tidy.isHidden == false,
                  "\(tag): two distinct Today pages show Tidy while hovered")
            if let id = eligibilityTabs.first { _ = try? c.store.closeTab(id) }
        }
        wait(0.3)
        run { [self] in
            check(p18bDivider(eligibilitySpace)?.tidy.isHidden == true,
                  "\(tag): closing one of two pages hides Tidy without changing hover")
            c.undo()
        }
        wait(0.3)
        run { [self] in
            check(p18bDivider(eligibilitySpace)?.tidy.isHidden == false,
                  "\(tag): undo restores Tidy eligibility without changing hover")
        }

        run {
            privateWindow?.closeWindow()
            server?.stop()
            TidyTabsFeature.testOverride = nil
        }
        wait(0.5)
        run { [self] in finish() }
    }

    /// The tidy before the relaunch (write) and the ⌘Z after it (read).
    @MainActor private func p18bRelaunch(write: Bool) {
        let tag = (app?.engine is WebKitEngine ? "parityp18b (WebKit)" : "parityp18b (Chromium)") + (write ? " write" : " read")
        let file = AppPaths.dataDirectory.appendingPathComponent("p18b-before.txt")
        if write {
            let fake = P18bTabsModel(Self.p18bTopics)
            var space = "", before = ""
            run { TidyTabsFeature.testOverride = (true, fake) }
            run { [self] in
                guard let made = p18bMakeSpace("Tidy", today: Self.p18bTabs) else { return finish() }
                space = made.space
                before = p18bLayout(space)
                TidyTabsFeature.start(in: c, spaceID: space)
            }
            step { [self] done in waitUntil({ !TidyTabsFeature.isRunning(space) }, timeout: 8) { done() } }
            run { [self] in
                let ok = c.store.tidyUndo(inSpace: space) != nil && c.store.undoLabel == SpacesStore.tidyTabsLabel
                try? (space + "\n" + before).write(to: file, atomically: true, encoding: .utf8)
                try? c.store.flush()
                check(ok, "\(tag): tidied, with the undo record kept on this Mac")
                TidyTabsFeature.testOverride = nil
                finish()
            }
        } else {
            run { [self] in
                guard let saved = try? String(contentsOf: file, encoding: .utf8), let nl = saved.firstIndex(of: "\n") else {
                    check(false, "\(tag): the write run's layout is there")
                    return finish()
                }
                let space = String(saved[..<nl]), before = String(saved[saved.index(after: nl)...])
                c.switchToSpace(space, animated: false)
                let fresh = !c.store.canUndo && c.store.tidyUndo(inSpace: space) != nil && p18bLayout(space) != before
                c.undo()
                check(fresh && p18bLayout(space) == before && c.store.tidyUndo(inSpace: space) == nil,
                      "\(tag): after a relaunch (the store's undo empty, fresh \(fresh)) one ⌘Z restores the exact order and folders")
                finish()
            }
        }
    }

    /// Apple's on-device model on synthetic tabs: what it makes, how long it takes, and whether a second run makes the
    /// same folders. Logged for a person to judge; FAIL only when it makes nothing usable.
    @MainActor private func p18bReal() {
        let tag = "parityp18b-real (\(app?.engine is WebKitEngine ? "WebKit" : "Chromium"))"
        let tabs: [(url: String, title: String)] = [
            ("https://travel.example.com/flights/ber-lis", "Cheap flights Berlin to Lisbon - Example Travel"),
            ("https://recipes.example.org/sourdough-starter", "How to make a sourdough starter - Example Recipes"),
            ("https://docs.example.dev/swift/concurrency", "Concurrency - The Swift Programming Language"),
            ("https://hotels.example.org/lisbon/alfama", "Boutique hotels in Alfama, Lisbon - Example Hotels"),
            ("https://forum.example.dev/t/actor-reentrancy", "Actor reentrancy explained - Swift Forums"),
            ("https://running.example.com/plans/half-marathon", "12-week half marathon training plan - Example Running"),
            ("https://recipes.example.org/focaccia", "Rosemary focaccia recipe - Example Recipes"),
            ("https://wiki.example.org/Trams_in_Lisbon", "Trams in Lisbon - Example Wiki"),
            ("https://video.example.com/watch?v=sendable", "Sendable and data races in Swift 6 - Example Video"),
            ("https://shop.example.com/running-shoes", "Best running shoes 2026 - Example Shop"),
            ("https://recipes.example.org/bread-flour", "Choosing bread flour for baking - Example Recipes"),
            ("https://weather.example.net/lisbon", "Lisbon 10-day weather forecast - Example Weather"),
            ("https://news.example.com/markets", "Markets today - Example News"),
            ("https://running.example.com/blog/tempo-runs", "What are tempo runs? - Example Running"),
            ("https://docs.example.dev/swift/macros", "Macros - The Swift Programming Language"),
        ]
        var space = "", ids: [String] = []
        var firstRun: [String] = []
        var started: CFTimeInterval = 0
        func describe(_ outcome: TidyTabsOutcome?) -> [String] {
            guard case .plan(let p) = outcome else { return ["\(String(describing: outcome))"] }
            return p.folders.map { f in
                "\(f.name): " + f.tabIDs.map { id in
                    tabs[ids.firstIndex(of: id) ?? 0].title.components(separatedBy: " - ").first ?? ""
                }.joined(separator: "; ")
            }
        }
        run { [self] in
            TidyTabsFeature.testOverride = nil
            var o = TidyTabsPlanner.Options()
            o.timeout = 60
            TidyTabsFeature.options = o
            note("\(tag): Apple Intelligence \(AppleIntelligence.availability.label)")
            guard TidyTabsFeature.isAvailable else {
                note("SKIP \(tag): Apple Intelligence isn't available on this Mac (\(AppleIntelligence.availability.label))")
                return finish()
            }
            guard let made = p18bMakeSpace("Tidy (real)", today: tabs) else { return finish() }
            (space, ids) = made
        }
        for round in 1...2 {
            run { [self] in
                started = CACurrentMediaTime()
                TidyTabsFeature.start(in: c, spaceID: space)
            }
            step { [self] done in waitUntil({ !TidyTabsFeature.isRunning(space) }, timeout: 120) { done() } }
            run { [self] in
                let seconds = CACurrentMediaTime() - started
                let outcome = TidyTabsFeature.lastOutcome[space]
                let lines = describe(outcome)
                note("\(tag): round \(round), \(String(format: "%.1f", seconds)) s, \(TidyTabsFeature.lastMessage ?? "-")")
                for l in lines { note("\(tag):   \(l)") }
                if round == 1 {
                    firstRun = lines
                    var made = false
                    if case .plan(let p) = outcome { made = !p.folders.isEmpty }
                    check(made, "\(tag): the on-device model sorted \(tabs.count) synthetic tabs into \(lines.count) folders in "
                            + String(format: "%.1f s", seconds))
                } else {
                    check(lines == firstRun, "\(tag): the same tabs make the same folders the second time (greedy sampling)")
                }
                c.undo()
            }
        }
        run { [self] in
            TidyTabsFeature.options = TidyTabsPlanner.Options()
            finish()
        }
    }
}
#endif
