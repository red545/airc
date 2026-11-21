// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import AircKit

/// Tidy by site (no model) and the sidebar tidy card's rules (AI/TidyBySite.swift).
final class TidyBySiteTests: XCTestCase {
    private func open(_ s: SpacesStore, _ pages: [(String, String)]) throws -> [String] {
        var ids: [String] = []
        for (url, title) in pages.reversed() {
            ids.insert(try s.openTab(url: url, inSpace: s.selectedSpace.id, title: title).id, at: 0)
        }
        return ids
    }

    func testGroupsBySiteInTodayOrderAndUndoes() async throws {
        let s = try SpacesStore(path: nil)
        let sid = s.selectedSpace.id
        let ids = try open(s, [
            ("https://news.example.com/a", "A"), ("https://shop.example.net/1", "One"),
            ("https://www.news.example.com/b", "B"), ("https://lone.example.org/", "Lone"),
            ("https://shop.example.net/2", "Two"), ("https://news.example.com/a#top", "A again"),
        ])
        let before = s.todayRows(ofSpace: sid).map(\.id)
        let outcome = await TidyTabsPlanner.plan(spaceID: sid, candidates: s.tidyCandidates(inSpace: sid), model: TidyTabsBySite())
        guard case .plan(let plan) = outcome else { return XCTFail("no plan: \(outcome)") }
        XCTAssertEqual(plan.folders.map(\.name), ["news.example.com", "shop.example.net"])
        XCTAssertEqual(plan.folders[0].tabIDs, [ids[0], ids[5], ids[2]])   // a page's tabs go together
        XCTAssertEqual(plan.folders[1].tabIDs, [ids[1], ids[4]])
        XCTAssertNotNil(try s.applyTidyTabs(plan))
        XCTAssertNil(s.tab(ids[3])?.folderID)
        _ = try s.undo()
        XCTAssertEqual(s.todayRows(ofSpace: sid).map(\.id), before)
    }

    func testOneSitePageMakesNoFolder() async throws {
        let s = try SpacesStore(path: nil)
        _ = try open(s, [("https://a.example.com/", "A"), ("https://b.example.com/", "B"), ("https://a.example.com/#x", "A2")])
        let outcome = await TidyTabsPlanner.plan(spaceID: s.selectedSpace.id, candidates: s.tidyCandidates(inSpace: s.selectedSpace.id),
                                                 model: TidyTabsBySite())
        XCTAssertEqual(outcome, .noFolders)
    }

    func testLongHostName() {
        XCTAssertEqual(TidyTabsBySite.folderName(host: "docs.example.com"), "docs.example.com")
        let long = "a-very-long-subdomain-name.region.example.com"
        XCTAssertEqual(TidyTabsBySite.folderName(host: long), "example.com")
        XCTAssertNotNil(TidyTabsRules.folderName(TidyTabsBySite.folderName(host: long)))
        XCTAssertNotNil(TidyTabsRules.folderName("news.example.com"))
    }

    func testThresholds() {
        XCTAssertFalse(TidyHintRules.isLong(looseTabs: 11, overflows: false))
        XCTAssertTrue(TidyHintRules.isLong(looseTabs: 12, overflows: false))
        XCTAssertTrue(TidyHintRules.isLong(looseTabs: 6, overflows: true))
        XCTAssertFalse(TidyHintRules.isLong(looseTabs: 5, overflows: true))
    }

    func testArchiveOfferPicksLongestAgeWithEnoughTabs() throws {
        let clock = TestClock(), s = try makeStore(clock)
        let now = clock.date
        var tabs: [LiveTab] = []
        for (n, hours) in [8.0, 7, 4, 2, 0.5].enumerated() {
            var t = try s.openTab(url: "https://site\(n).example.com/", inSpace: s.selectedSpace.id)
            t.lastActiveAt = now.addingTimeInterval(-hours * 3600)
            tabs.append(t)
        }
        let o = try XCTUnwrap(TidyHintRules.archiveOffer(tabs, now: now, protected: []))
        XCTAssertEqual(o.age, 3 * 3600)
        XCTAssertEqual(o.ids, [tabs[0].id, tabs[1].id, tabs[2].id])
        let p = try XCTUnwrap(TidyHintRules.archiveOffer(tabs, now: now, protected: [tabs[0].id]))
        XCTAssertEqual(p.age, 3600)
        XCTAssertEqual(p.ids, [tabs[1].id, tabs[2].id, tabs[3].id])
        XCTAssertNil(TidyHintRules.archiveOffer(Array(tabs.suffix(2)), now: now, protected: []))
        XCTAssertEqual(TidyHintRules.ageLabel(3600), "1 hour")
        XCTAssertEqual(TidyHintRules.ageLabel(6 * 3600), "6 hours")
    }

    func testPinSuggestions() throws {
        let s = try SpacesStore(path: nil)
        func tab(_ url: String, _ ago: TimeInterval) throws -> LiveTab {
            var t = try s.openTab(url: url, inSpace: s.selectedSpace.id)
            t.lastActiveAt = Date(timeIntervalSince1970: 1_000_000 - ago)
            return t
        }
        let tabs = [try tab("https://news.example.com/1", 50), try tab("https://news.example.com/2", 10),
                    try tab("https://www.shop.example.net/1", 5), try tab("https://shop.example.net/2", 60),
                    try tab("https://mail.example.org/", 1), try tab("https://mail.example.org/2", 2),
                    try tab("https://mail.example.org/3", 3), try tab("https://lone.example.com/", 0)]
        let p = TidyHintRules.pinSuggestions(tabs, favoriteHosts: [])
        XCTAssertEqual(p.map(\.host), ["mail.example.org", "shop.example.net"])
        XCTAssertEqual(p.map(\.tabID), [tabs[4].id, tabs[2].id])
        XCTAssertEqual(TidyHintRules.pinSuggestions(tabs, favoriteHosts: ["mail.example.org"]).map(\.host),
                       ["shop.example.net", "news.example.com"])
    }

    /// The tidy card's Undo checks its step by serial: the count stops growing at maxUndo.
    func testUndoSerialsGrowPastTheCap() throws {
        let s = try SpacesStore(path: nil)
        var serials: [Int] = []
        for n in 0..<(SpacesStore.maxUndo + 3) {
            let t = try s.openTab(url: "https://s\(n).example.com/", inSpace: s.selectedSpace.id)
            _ = try s.archiveTabs([t.id], reason: .manual, label: "Archive Old Tabs")
            serials.append(s.undoStack.last?.serial ?? -1)
        }
        XCTAssertEqual(s.undoStack.count, SpacesStore.maxUndo)
        XCTAssertEqual(serials, serials.sorted())
        XCTAssertEqual(Set(serials).count, serials.count)
    }

    func testDayKey() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(TidyHintRules.dayKey(Date(timeIntervalSince1970: 86400 * 3 + 10), calendar: cal), "1970-01-04")
    }
}
