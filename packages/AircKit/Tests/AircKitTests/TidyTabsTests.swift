// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import AircKit

/// Sorts tabs by a table of title → folder name, records every request, and can be slow (ignoring cancellation, as a
/// stuck model would), decline or fail.
final class FakeTabsModel: TidyTabsModel, @unchecked Sendable {
    private let lock = NSLock()
    private var _asked: [TidyTabsRequest] = []
    var topics: [String: String]
    var slow: TimeInterval = 0
    var declines = false
    var fails = false
    /// Answers as given, instead of from `topics`.
    var raw: [TidyTabsFolderAnswer]?
    /// Folders in reverse order of first appearance (the plan mustn't depend on it).
    var reversed = false

    init(_ topics: [String: String] = [:]) { self.topics = topics }

    var asked: [TidyTabsRequest] { lock.withLock { _asked } }

    func folders(for request: TidyTabsRequest) async throws -> [TidyTabsFolderAnswer] {
        lock.withLock { _asked.append(request) }
        if slow > 0 {
            let end = Date().addingTimeInterval(slow)
            while Date() < end { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        if declines { throw AIRequestDeclined(.guardrail) }
        if fails { throw URLError(.cannotParseResponse) }
        if let raw { return raw }
        var order: [String] = []
        var numbers: [String: [Int]] = [:]
        for t in request.tabs {
            guard let topic = topics[t.title] else { continue }
            if numbers[topic] == nil { order.append(topic) }
            numbers[topic, default: []].append(t.number)
        }
        let out = order.map { TidyTabsFolderAnswer(name: $0, tabs: numbers[$0]!) }
        return reversed ? out.reversed() : out
    }
}

final class TidyTabsTests: XCTestCase {
    private var store: SpacesStore!
    private var spaceID = ""

    override func setUpWithError() throws {
        store = try SpacesStore(path: nil)
        spaceID = store.selectedSpace.id
    }

    /// Opens Today tabs (the first given ends up at the top), returning their IDs in Today order.
    @discardableResult
    private func open(_ pages: [(String, String)], in space: String? = nil) throws -> [String] {
        var ids: [String] = []
        for (url, title) in pages.reversed() {
            ids.insert(try store.openTab(url: url, inSpace: space ?? spaceID, title: title).id, at: 0)
        }
        return ids
    }

    private static let trip = [
        ("https://travel.example.com/lisbon/flights?from=BER&token=abc", "Flights to Lisbon (2) - Example Travel"),
        ("https://hotels.example.org/lisbon", "Alfama hotels - Example Hotels"),
        ("https://docs.example.dev/swift/concurrency#actors", "Concurrency - The Swift Language"),
        ("https://forum.example.dev/t/actors/42", "Actor isolation question - Swift Forums"),
        ("https://travel.example.com/lisbon/flights?from=BER&token=abc#top", "Flights to Lisbon (2) - Example Travel"),
        ("https://weather.example.net/today", "Weather today"),
    ]

    private static let topics = [
        "Flights to Lisbon - Example Travel": "Lisbon Trip",
        "Alfama hotels - Example Hotels": "Lisbon Trip",
        "Concurrency - The Swift Language": "Swift Concurrency",
        "Actor isolation question - Swift Forums": "Swift Concurrency",
    ]

    private func plan(_ model: FakeTabsModel, space: String? = nil, options: TidyTabsPlanner.Options = .init()) async -> TidyTabsOutcome {
        let sid = space ?? spaceID
        return await TidyTabsPlanner.plan(spaceID: sid, candidates: store.tidyCandidates(inSpace: sid), model: model, options: options)
    }

    // MARK: Grouping

    func testGroupsByTopicInTodayOrderWithDuplicatesTogether() async throws {
        let ids = try open(Self.trip)
        let model = FakeTabsModel(Self.topics)
        guard case .plan(let p) = await plan(model) else { return XCTFail("no plan") }
        XCTAssertEqual(p.folders, [
            .init(name: "Lisbon Trip", tabIDs: [ids[0], ids[4], ids[1]]),
            .init(name: "Swift Concurrency", tabIDs: [ids[2], ids[3]]),
        ])
        // The duplicate (same page, another fragment) is asked about once; the weather page stays out of every folder.
        XCTAssertEqual(model.asked.count, 1)
        XCTAssertEqual(model.asked[0].tabs.map(\.number), [1, 2, 3, 4, 5])
        XCTAssertEqual(model.asked[0].tabs.map(\.title), ["Flights to Lisbon - Example Travel", "Alfama hotels - Example Hotels",
                                                          "Concurrency - The Swift Language", "Actor isolation question - Swift Forums",
                                                          "Weather today"])
    }

    func testTheSameTabsMakeTheSamePlan() async throws {
        try open(Self.trip)
        let a = await plan(FakeTabsModel(Self.topics))
        let b = await plan(FakeTabsModel(Self.topics))
        let reversed = FakeTabsModel(Self.topics)
        reversed.reversed = true
        let c = await plan(reversed)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, c, "folders go in Today order, whatever order the model names them in")
    }

    func testEmptyAndSingleTabListsDoNothing() async throws {
        let model = FakeTabsModel(Self.topics)
        let empty = await plan(model)
        XCTAssertEqual(empty, .tooFewTabs)
        try open([Self.trip[0]])
        let one = await plan(model)
        XCTAssertEqual(one, .tooFewTabs)
        // Two tabs of one page are one page.
        try open([Self.trip[4]])
        let same = await plan(model)
        XCTAssertEqual(same, .tooFewTabs)
        // New tabs, Airc's own pages and files aren't web pages.
        try open([("", "New Tab"), ("about:blank", ""), ("airc://settings", "Settings"), ("file:///tmp/a.html", "A file")])
        let blank = await plan(model)
        XCTAssertEqual(blank, .tooFewTabs)
        XCTAssertTrue(model.asked.isEmpty)
        XCTAssertNil(try store.applyTidyTabs(TidyTabsPlan(spaceID: spaceID, folders: [])))
        XCTAssertFalse(store.canUndo)
    }

    func testAnswersAreCheckedNotTrusted() async throws {
        let ids = try open(Self.trip)
        let model = FakeTabsModel()
        model.raw = [
            .init(name: "  \"lisbon trip\". ", tabs: [1, 2, 99, 0, -3]),
            .init(name: "Swift", tabs: [2, 3]),            // 2 is taken: one page left, no folder
            .init(name: "someone@example.com", tabs: [3, 4]),
            .init(name: "<b>Weather</b>", tabs: [5, 3]),
            .init(name: "A name that is far too long to be a folder name", tabs: [3, 4]),
            .init(name: "LISBON TRIP", tabs: [5]),          // the same folder again: merged
        ]
        guard case .plan(let p) = await plan(model) else { return XCTFail("no plan") }
        XCTAssertEqual(p.folders, [.init(name: "Lisbon trip", tabIDs: [ids[0], ids[4], ids[1], ids[5]])])
        model.raw = [.init(name: "Odds", tabs: [1]), .init(name: "", tabs: [2, 3])]
        let none = await plan(model)
        XCTAssertEqual(none, .noFolders)
    }

    func testFolderNames() {
        XCTAssertEqual(TidyTabsRules.folderName("Folder: **Kitchen renovation**"), "Kitchen renovation")
        XCTAssertEqual(TidyTabsRules.folderName("swift concurrency\nand more"), "Swift concurrency")
        XCTAssertEqual(TidyTabsRules.folderName("Reise nach Lissabon"), "Reise nach Lissabon")
        for bad in ["", "  ", "2024", "One two three four five", "a@b.co", "{json}", String(repeating: "x", count: 40)] {
            XCTAssertNil(TidyTabsRules.folderName(bad), bad)
        }
    }

    func testFailuresChangeNothing() async throws {
        try open(Self.trip)
        let model = FakeTabsModel(Self.topics)
        model.declines = true
        let declined = await plan(model)
        XCTAssertEqual(declined, .declined(.guardrail))
        model.declines = false
        model.fails = true
        let failed = await plan(model)
        XCTAssertEqual(failed, .failed)
        model.fails = false
        model.slow = 1
        var o = TidyTabsPlanner.Options()
        o.timeout = 0.1
        let timeout = await plan(model, options: o)
        XCTAssertEqual(timeout, .timeout)
        XCTAssertTrue(store.pinnedRoots(ofSpace: spaceID).isEmpty)
    }

    // MARK: Long lists

    func testALongListIsAskedInPartsThatShareFolderNames() async throws {
        var pages: [(String, String)] = []
        var topics: [String: String] = [:]
        for i in 0..<70 {
            let topic = ["Recipes", "Running", "Tax Return"][i % 3]
            let title = "\(topic) page number \(i) with a fairly long descriptive title - Example Site \(i % 7)"
            pages.append(("https://site\(i % 7).example.com/\(topic.lowercased())/\(i)", title))
            topics[TidyTabsRules.promptTitle(title, url: "")] = topic
        }
        let ids = try open(pages)
        let model = FakeTabsModel(topics)
        guard case .plan(let p) = await plan(model) else { return XCTFail("no plan") }
        XCTAssertGreaterThanOrEqual(model.asked.count, 3)
        for r in model.asked {
            XCTAssertLessThanOrEqual(r.tabs.count, TidyTabsRules.pagesPerRequest)
            let tokens = r.tabs.reduce(0) { $0 + AITokens.estimate("\($1.number). \($1.title) (\($1.host))") + 1 }
            XCTAssertLessThanOrEqual(tokens, TidyTabsRules.tokensPerRequest)
            XCTAssertEqual(r.tabs.map(\.number), Array(1...r.tabs.count))
        }
        XCTAssertEqual(model.asked[0].topics, [])
        XCTAssertEqual(model.asked[1].topics, ["Recipes", "Running", "Tax Return"])
        XCTAssertEqual(p.folders.map(\.name), ["Recipes", "Running", "Tax Return"])
        XCTAssertEqual(p.folders[0].tabIDs, stride(from: 0, to: 70, by: 3).map { ids[$0] })
        XCTAssertEqual(p.tabCount, 70)
        XCTAssertEqual(Set(model.asked.flatMap(\.tabs).map(\.title)).count, 70)
    }

    func testAtMostMaxPagesAreSorted() {
        let many = (0..<300).map { TidyTabsCandidate(tabID: "t\($0)", page: "https://e.example/\($0)", title: "T \($0)", host: "e.example") }
        let chunks = TidyTabsRules.chunks(many)
        XCTAssertEqual(chunks.reduce(0) { $0 + $1.count }, TidyTabsRules.maxPages)
        XCTAssertEqual(chunks.flatMap { $0 }.map(\.tabID), (0..<TidyTabsRules.maxPages).map { "t\($0)" })
    }

    // MARK: Applying, pinned and Favorites

    private struct Snapshot: Equatable {
        var tabs: [String: LiveTab]
        var items: [String: Item]
    }

    private func snapshot() -> Snapshot { Snapshot(tabs: store.state.tabs, items: store.state.items) }

    /// A pinned tab renamed by hand, a folder with a tab, and a Favorite, all made before the Today tabs.
    private func makePinnedAndFavorites() throws -> (renamed: String, folder: String, favorite: String) {
        let pinned = try store.openTab(url: "https://mail.example.com/inbox", inSpace: spaceID, title: "Inbox (4) - Mail")
        try store.togglePin(pinned.id, inSpace: spaceID)
        let renamed = store.tab(pinned.id)!.itemID!
        try store.renameItem(renamed, to: "My Mail")
        let inFolder = try store.openTab(url: "https://travel.example.com/lisbon/visa", inSpace: spaceID, title: "Visa - Example Travel")
        let folder = try store.createFolder(named: "Paperwork", inSpace: spaceID, containing: [.tab(inFolder.id)])
        let fav = try store.openTab(url: "https://calendar.example.com", inSpace: spaceID, title: "Calendar")
        try store.move(.tab(fav.id), to: .favorites(profileID: store.profile(ofSpace: spaceID).id, index: 0))
        return (renamed, folder.id, store.tab(fav.id)!.itemID!)
    }

    /// The tabs loose in Today (not in a split or a Today folder), top first.
    private func looseToday() -> [String] {
        store.todayRootRows(ofSpace: spaceID).compactMap { if case .today(let t) = $0 { t.id } else { nil } }
    }

    func testApplyMakesFoldersAtTheTopOfTodayAndLeavesPinnedAndFavoritesAlone() async throws {
        let mine = try makePinnedAndFavorites()
        let pinnedBefore = store.state.items
        let ids = try open(Self.trip)
        let candidates = store.tidyCandidates(inSpace: spaceID)
        XCTAssertEqual(candidates.map(\.tabID), ids, "only Today tabs are read")
        let model = FakeTabsModel(Self.topics)
        guard case .plan(let p) = await plan(model) else { return XCTFail("no plan") }
        for leak in ["Mail", "Inbox", "Visa", "Calendar", "My Mail"] {
            XCTAssertFalse(model.asked.flatMap(\.tabs).contains { $0.title.contains(leak) }, leak)
        }
        let record = try XCTUnwrap(store.applyTidyTabs(p))
        XCTAssertEqual(store.undoLabel, "Tidy Tabs")
        // Every item that was there is as it was.
        for (id, item) in pinnedBefore { XCTAssertEqual(store.item(id), item, id) }
        XCTAssertEqual(store.item(mine.renamed)?.title, "My Mail")
        // Pinned is as it was; the folders are Today folders at the top of Today, in the plan's order.
        XCTAssertEqual(store.pinnedRoots(ofSpace: spaceID).map(\.id), [mine.renamed, mine.folder])
        let roots = store.todayRootRows(ofSpace: spaceID)
        XCTAssertEqual(roots.prefix(2).map { $0.item?.title }, ["Lisbon Trip", "Swift Concurrency"])
        XCTAssertEqual(roots.prefix(2).map(\.id), record.folderIDs)
        XCTAssertTrue(record.folderIDs.allSatisfy { store.item($0)?.container == .today(spaceID: spaceID) })
        let lisbon = store.todayFolderTabs(record.folderIDs[0])
        XCTAssertEqual(lisbon.map(\.id), [ids[0], ids[4], ids[1]])
        // The tabs stay Today tabs with their pages' titles, and the one that fits nowhere stays loose in Today.
        XCTAssertTrue(lisbon.allSatisfy { $0.isToday && $0.folderID == record.folderIDs[0] })
        XCTAssertEqual(lisbon.first?.title, "Flights to Lisbon (2) - Example Travel")
        XCTAssertEqual(looseToday(), [ids[5]])
        XCTAssertEqual(store.todayTabs(ofSpace: spaceID).count, 6, "every tab is still a Today tab")
        XCTAssertEqual(record.moved.filter { $0.folderID == record.folderIDs[0] }.map(\.before.id).sorted(),
                       [ids[0], ids[1], ids[4]].sorted())
        XCTAssertTrue(record.moved.allSatisfy { $0.itemID == nil && $0.folderID.map(record.folderIDs.contains) == true })
        XCTAssertEqual(store.favorites(ofProfile: store.profile(ofSpace: spaceID).id).map(\.id), [mine.favorite])
    }

    func testTabsThatChangedWhileTheModelWorkedAreLeftOut() async throws {
        let ids = try open(Self.trip)
        guard case .plan(let p) = await plan(FakeTabsModel(Self.topics)) else { return XCTFail("no plan") }
        // While the model worked: a Swift tab closed, a Lisbon tab pinned by hand.
        _ = try store.closeTab(ids[3])
        try store.togglePin(ids[1], inSpace: spaceID)
        // Lisbon is left with one page (two tabs of it): not a folder; Swift with one tab: not a folder either. Nothing
        // changes, and there's nothing to undo.
        let before = snapshot()
        XCTAssertNil(try store.applyTidyTabs(p))
        XCTAssertEqual(snapshot(), before)
        XCTAssertEqual(store.pinnedRoots(ofSpace: spaceID).filter { $0.kind == .folder }.count, 0)
        XCTAssertEqual(store.todayFolders(ofSpace: spaceID).count, 0)
        XCTAssertNil(store.tidyUndo(inSpace: spaceID))
    }

    func testAFolderStillMadeWhenSomeOfItsTabsChanged() async throws {
        let ids = try open(Self.trip)
        guard case .plan(let p) = await plan(FakeTabsModel(Self.topics)) else { return XCTFail("no plan") }
        // The duplicate Lisbon tab closes: Lisbon keeps two pages, so it's still a folder, of the tabs that are left.
        _ = try store.closeTab(ids[4])
        let record = try XCTUnwrap(try store.applyTidyTabs(p))
        XCTAssertEqual(record.moved.map(\.before.id), [ids[0], ids[1], ids[2], ids[3]])
        XCTAssertEqual(looseToday(), [ids[5]])
    }

    func testTidyShowsOnlyForPagesLooseInToday() throws {
        // Six tabs (six pages) in Today folders and one loose: nothing for Tidy to do.
        var inFolders: [String] = []
        for n in 0..<6 {
            inFolders.append(try store.openTab(url: "https://site\(n).example.com/page", inSpace: spaceID, title: "Page \(n)").id)
        }
        _ = try store.createTodayFolder(named: "A", inSpace: spaceID, containing: inFolders.prefix(3).map { .tab($0) })
        _ = try store.createTodayFolder(named: "B", inSpace: spaceID, containing: inFolders.suffix(3).map { .tab($0) })
        _ = try store.openTab(url: "https://loose.example.com/one", inSpace: spaceID, title: "Loose one")
        XCTAssertFalse(TidyTabsRules.hasEnoughPages(in: store.todayRows(ofSpace: spaceID)))
        XCTAssertEqual(store.tidyCandidates(inSpace: spaceID).count, 1)
        // Another loose page: Tidy shows.
        _ = try store.openTab(url: "https://loose.example.com/two", inSpace: spaceID, title: "Loose two")
        XCTAssertTrue(TidyTabsRules.hasEnoughPages(in: store.todayRows(ofSpace: spaceID)))
    }

    func testSplitsAreNotSorted() throws {
        let ids = try open(Self.trip)
        _ = try store.createSplit([ids[0], ids[2]], inSpace: spaceID)
        XCTAssertFalse(store.tidyCandidates(inSpace: spaceID).contains { [ids[0], ids[2]].contains($0.tabID) })
    }

    // MARK: Undo

    func testOneUndoRestoresTheExactOrderAndFolders() async throws {
        _ = try makePinnedAndFavorites()
        try open(Self.trip)
        let before = snapshot()
        guard case .plan(let p) = await plan(FakeTabsModel(Self.topics)) else { return XCTFail("no plan") }
        try store.applyTidyTabs(p)
        XCTAssertNotEqual(snapshot(), before)
        XCTAssertEqual(try store.undo(), .restored(label: "Tidy Tabs", movedTabs: []))
        XCTAssertEqual(snapshot(), before)
        // The record is out of date now: the next ⌘Z has nothing of the tidy's to do.
        XCTAssertNil(store.tidyUndo(inSpace: spaceID))
    }

    func testUndoAfterARelaunch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("airc-tidytabs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("spaces.sqlite").path
        var before: Snapshot
        do {
            store = try SpacesStore(path: path)
            spaceID = store.selectedSpace.id
            _ = try makePinnedAndFavorites()
            try open(Self.trip)
            try store.flush()
            // As the file has it (dates at the precision SQLite keeps), which is what a relaunched app starts from.
            store = try SpacesStore(path: path)
            before = snapshot()
            guard case .plan(let p) = await plan(FakeTabsModel(Self.topics)) else { return XCTFail("no plan") }
            try store.applyTidyTabs(p)
            try store.flush()
        }
        store = try SpacesStore(path: path)
        XCTAssertFalse(store.canUndo, "the store's own undo doesn't outlive the app")
        let record = try XCTUnwrap(store.tidyUndo(inSpace: spaceID))
        let restored = try store.undoTidyTabs(record)
        XCTAssertEqual(restored.count, 5)
        XCTAssertEqual(snapshot(), before)
        XCTAssertNil(store.tidyUndo(inSpace: spaceID))
        try store.flush()
        XCTAssertEqual(try SpacesStore(path: path).state.tabs, before.tabs)
    }

    func testUndoAfterARelaunchKeepsWhatChangedSince() async throws {
        let ids = try open(Self.trip)
        guard case .plan(let p) = await plan(FakeTabsModel(Self.topics)) else { return XCTFail("no plan") }
        let record = try XCTUnwrap(try store.applyTidyTabs(p))
        // Since: a tab moved on to another page, one dragged out of its folder by hand, a folder renamed.
        store.updateTab(ids[2], url: "https://docs.example.dev/swift/sendable", title: "Sendable - The Swift Language")
        try store.move(.tab(ids[3]), to: .pinned(spaceID: spaceID, parentID: nil, index: 0))
        try store.renameItem(record.folderIDs[0], to: "Holiday")
        let restored = try store.undoTidyTabs(try XCTUnwrap(store.tidyUndo(inSpace: spaceID)))
        XCTAssertEqual(Set(restored), Set([ids[0], ids[1], ids[2], ids[4]]))
        XCTAssertEqual(store.todayTabs(ofSpace: spaceID).map(\.id), [ids[0], ids[1], ids[2], ids[4], ids[5]])
        XCTAssertEqual(store.tab(ids[2])?.url, "https://docs.example.dev/swift/sendable")
        // The tab put elsewhere by hand stays there; the emptied folders go.
        XCTAssertNotNil(store.tab(ids[3])?.itemID)
        XCTAssertEqual(store.pinnedRoots(ofSpace: spaceID).filter { $0.kind == .folder }.count, 0)
        XCTAssertEqual(store.todayFolders(ofSpace: spaceID).count, 0)
    }

    func testCancellingWhileTheModelWorksChangesNothing() async throws {
        try open(Self.trip)
        let before = snapshot()
        let model = FakeTabsModel(Self.topics)
        model.slow = 2
        let candidates = store.tidyCandidates(inSpace: spaceID)
        let sid = spaceID
        let task = Task { await TidyTabsPlanner.plan(spaceID: sid, candidates: candidates, model: model) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let started = Date()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "a cancel ends the wait at once, even with a stuck model")
        XCTAssertEqual(snapshot(), before)
        XCTAssertFalse(store.canUndo)
        XCTAssertNil(store.tidyUndo(inSpace: spaceID))
    }

    // MARK: Privacy

    func testTheModelSeesOnlyCleanTitlesAndHosts() async throws {
        try open([
            ("https://mail.example.com/mail/u/0/?token=secret#inbox", "Inbox (3) - someone@example.com - Mail"),
            ("https://bank.example.org/accounts/12345?session=xyz", "Accounts | 3 new items | Example Bank"),
        ])
        let model = FakeTabsModel()
        _ = await plan(model)
        let prompt = TidyTabsPrompt.prompt(for: try XCTUnwrap(model.asked.first))
        XCTAssertEqual(prompt, "Tabs:\n1. Inbox - Mail (mail.example.com)\n2. Accounts - Example Bank (bank.example.org)")
        for leak in ["someone", "@", "token", "secret", "/mail/", "(3)", "#inbox", "12345", "session", "3 new"] {
            XCTAssertFalse(prompt.contains(leak), leak)
        }
    }

    func testOnlyThisSpacesTodayTabsAreRead() async throws {
        let other = try store.createSpace(name: "Other", profileID: store.selectedSpace.profileID)
        try open([("https://secret.example.com/a", "Other Space secret"), ("https://secret.example.com/b", "Other Space secret 2")],
                 in: other.id)
        try open(Self.trip)
        let model = FakeTabsModel(Self.topics)
        _ = await plan(model)
        XCTAssertFalse(model.asked.flatMap(\.tabs).contains { $0.title.contains("secret") || $0.host.contains("secret") })
        XCTAssertEqual(store.todayTabs(ofSpace: other.id).count, 2)
    }

    func testTheUndoRecordStaysOnThisMac() async throws {
        try open(Self.trip)
        guard case .plan(let p) = await plan(FakeTabsModel(Self.topics)) else { return XCTFail("no plan") }
        try store.applyTidyTabs(p)
        XCTAssertNotNil(store.tidyUndo(inSpace: spaceID))
        let export = String(decoding: try store.exportJSON(), as: UTF8.self)
        XCTAssertFalse(export.contains("tidyTabs.undo"))
        XCTAssertFalse(try store.operations().contains { $0.id.contains("tidyTabs") })
    }
}
