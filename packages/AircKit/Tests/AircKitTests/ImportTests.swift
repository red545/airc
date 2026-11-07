// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// A synthetic import: three source profiles, four Spaces, a folder, Favorites and Today tabs.
func sampleBlueprint() -> ImportBlueprint {
    typealias B = ImportBlueprint
    let tab = { (id: String, url: String) in B.Tab(sourceID: "arc-item:" + id, url: url, pageTitle: id) }
    return B(
        profiles: [
            .init(sourceID: "arc-profile:Default", name: "Personal", emoji: "🏡", isSourceDefault: true),
            .init(sourceID: "arc-profile:Profile 1", name: "Acme", emoji: "💼", color: RGBA(hex: "3B82F6")),
            .init(sourceID: "arc-profile:Profile 2", name: "Launch", emoji: "🚀"),
            .init(sourceID: "arc-profile:Profile 9", name: "Unused"),
        ],
        spaces: [
            .init(sourceID: "arc-space:S1", name: "Personal", icon: .emoji("🏡"), theme: .single("90DDC1"),
                  profileSourceID: "arc-profile:Default",
                  pinned: [.tab(tab("P1", "https://docs.example.com/budget")),
                           .folder(.init(sourceID: "arc-item:F1", title: "Trips", children: [
                               .tab(tab("P2", "https://maps.example.com/")),
                               .folder(.init(sourceID: "arc-item:F2", title: "Ideas", children: [.tab(tab("P3", "https://wiki.example.com/"))])),
                           ]))],
                  today: [tab("T1", "https://news.example.com/")]),
            .init(sourceID: "arc-space:S2", name: "Studio", icon: .emoji("🎨"), profileSourceID: "arc-profile:Default"),
            .init(sourceID: "arc-space:S3", name: "Work", icon: .emoji("💼"), theme: .single("7EB6D5"),
                  profileSourceID: "arc-profile:Profile 1", pinned: [.tab(tab("P4", "https://git.example.com/acme"))]),
            .init(sourceID: "arc-space:S4", name: "Launch", icon: .emoji("🚀"), profileSourceID: "arc-profile:Profile 2"),
        ],
        favorites: [
            "arc-profile:Default": [tab("V1", "https://mail.example.com/"), tab("V2", "https://cal.example.com/")],
            "arc-profile:Profile 1": [tab("V3", "https://chat.example.com/")],
        ]
    )
}

final class ImportTests: XCTestCase {
    func testFirstRunImportTakesOverTheEmptySpaceAndMapsProfiles() throws {
        let s = try makeStore()
        let pristine = s.orderedSpaces[0].id
        let r = try s.applyImport(sampleBlueprint())

        XCTAssertEqual(s.orderedSpaces.map(\.name), ["Personal", "Studio", "Work", "Launch"])
        XCTAssertEqual(s.orderedSpaces[0].id, pristine, "the fresh install's empty Space is reused, not left behind")
        // Arc's default profile is Airc's default profile; the other two used ones are created, the unused one is not.
        XCTAssertEqual(s.state.profiles.count, 3)
        XCTAssertEqual(r.profilesCreated.count, 2)
        XCTAssertEqual(s.defaultProfile.sourceID, "arc-profile:Default")
        XCTAssertEqual(s.defaultProfile.emoji, "🏡")
        let acme = try XCTUnwrap(s.profile(sourceID: "arc-profile:Profile 1"))
        XCTAssertEqual(acme.name, "Acme")
        XCTAssertEqual(acme.color.hex, "#3B82F6")
        XCTAssertNotEqual(acme.engineDirectory, s.defaultProfile.engineDirectory)
        XCTAssertEqual(s.space(sourceID: "arc-space:S3")?.profileID, acme.id)
        XCTAssertEqual(s.space(sourceID: "arc-space:S1")?.theme, .single("90DDC1"))

        // Pinned tree with nested folders, in order.
        let personal = try XCTUnwrap(s.space(sourceID: "arc-space:S1"))
        let roots = s.pinnedRoots(ofSpace: personal.id)
        XCTAssertEqual(roots.map(\.displayTitle), ["P1", "Trips"])
        let trips = s.children(of: .pinned(spaceID: personal.id), parent: roots[1].id)
        XCTAssertEqual(trips.map(\.displayTitle), ["P2", "Ideas"])
        XCTAssertEqual(s.children(of: .pinned(spaceID: personal.id), parent: trips[1].id).map(\.savedURL), ["https://wiki.example.com/"])
        XCTAssertEqual(r.pinnedTabs, 4)
        XCTAssertEqual(r.folders, 2)

        // Favorites stay per profile (SB-10).
        XCTAssertEqual(s.favorites(ofProfile: s.defaultProfile.id).compactMap(\.savedURL), ["https://mail.example.com/", "https://cal.example.com/"])
        XCTAssertEqual(s.favorites(ofProfile: acme.id).count, 1)
        XCTAssertEqual(r.favorites, 3)

        // Today tabs come over unloaded.
        XCTAssertEqual(s.todayTabs(ofSpace: personal.id).map(\.url), ["https://news.example.com/"])
        XCTAssertEqual(r.todayTabs, 1)
    }

    func testReimportIsIdempotent() throws {
        let s = try makeStore()
        try s.applyImport(sampleBlueprint())
        let counts = (s.state.profiles.count, s.state.spaces.count, s.state.items.count, s.state.tabs.count)
        var b = sampleBlueprint()
        b.spaces[2].name = "Acme Work"
        let r = try s.applyImport(b)
        XCTAssertEqual(counts.0, s.state.profiles.count)
        XCTAssertEqual(counts.1, s.state.spaces.count)
        XCTAssertEqual(counts.2, s.state.items.count)
        XCTAssertEqual(counts.3, s.state.tabs.count)
        XCTAssertEqual(r.profilesCreated, [])
        XCTAssertEqual(r.spacesCreated, 0)
        XCTAssertEqual(s.space(sourceID: "arc-space:S3")?.name, "Acme Work", "a re-import updates in place")
    }

    func testImportIntoAUsedStoreKeepsWhatIsThere() throws {
        let s = try makeStore()
        let mine = s.orderedSpaces[0]
        _ = try s.openTab(url: "https://mine.example.com", inSpace: mine.id)
        _ = try s.createProfile(name: "Acme")   // name clash with the import
        try s.applyImport(sampleBlueprint())
        XCTAssertEqual(s.orderedSpaces.first?.id, mine.id)
        XCTAssertEqual(s.orderedSpaces.count, 5)
        XCTAssertNotNil(s.state.profiles.values.first { $0.name == "Acme 2" }, "clashing names get a number")
    }

    func testChooseOnlySomeSpaces() throws {
        let s = try makeStore()
        let r = try s.applyImport(sampleBlueprint(), options: .init(spaces: ["arc-space:S3"], includeToday: false))
        XCTAssertEqual(s.orderedSpaces.map(\.name), ["Work"])
        XCTAssertEqual(r.profilesCreated.count, 1, "only the profile the chosen Space needs")
        XCTAssertEqual(s.state.profiles.count, 2)
        XCTAssertEqual(r.favorites, 1, "that profile's Favorites come along")
    }

    func testImportIsOneUndoStep() throws {
        let s = try makeStore()
        try s.applyImport(sampleBlueprint())
        XCTAssertEqual(s.undoLabel, "Import")
        try s.undo()
        XCTAssertEqual(s.state.spaces.count, 1)
        XCTAssertEqual(s.state.profiles.count, 1)
        XCTAssertNil(s.defaultProfile.sourceID)
    }

    func testFavoritesCapAtTwelve() throws {
        let s = try makeStore()
        var b = sampleBlueprint()
        b.favorites["arc-profile:Default"] = (0..<15).map { .init(sourceID: "arc-item:fav\($0)", url: "https://f\($0).example.com/") }
        let r = try s.applyImport(b)
        XCTAssertEqual(s.favorites(ofProfile: s.defaultProfile.id).count, SpacesStore.maxFavorites)
        XCTAssertEqual(r.favoritesSkipped, 3)
    }

    func testSourceIDsSurviveReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("airc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("spaces.sqlite").path
        do {
            let s = try SpacesStore(path: path)
            try s.applyImport(sampleBlueprint())
            try s.flush()
        }
        let s = try SpacesStore(path: path)
        XCTAssertEqual(s.state.spaces.count, 4)
        let r = try s.applyImport(sampleBlueprint())
        XCTAssertEqual(r.spacesCreated, 0)
        XCTAssertEqual(s.state.spaces.count, 4)
    }

    func testBlueprintCounts() {
        let b = sampleBlueprint()
        XCTAssertEqual(b.pinnedTabCount, 4)
        XCTAssertEqual(b.todayTabCount, 1)
        XCTAssertEqual(b.favoriteCount, 3)
        XCTAssertEqual(b.usedProfiles.map(\.name), ["Personal", "Acme", "Launch"])
    }
}

final class ArcThemeTests: XCTestCase {
    func json(_ s: String) -> Any { try! JSONSerialization.jsonObject(with: Data(s.utf8)) }

    func testGradientWithModifiers() {
        let raw = json("""
        {"background":{"single":{"_0":{"style":{"color":{"_0":{"blendedGradient":{"_0":{
          "baseColors":[{"red":1,"green":0,"blue":0,"alpha":1},{"color":{"red":0,"green":0,"blue":1,"alpha":1}}],
          "overlayColors":[{"red":0,"green":1,"blue":0,"alpha":1}],
          "modifiers":{"intensityFactor":0.5,"noiseFactor":0.3,"overlay":{"grain":{}}}}}}}}}}}}
        """)
        let t = ArcTheme.theme(from: raw)
        XCTAssertEqual(t.colors.map(\.hex), ["#FF0000", "#0000FF", "#00FF00"])
        XCTAssertEqual(t.intensity, 0.5, accuracy: 1e-9)
        XCTAssertEqual(t.grain, 0.3, accuracy: 1e-9)
    }

    func testSingleColor() {
        let raw = json("""
        {"background":{"single":{"_0":{"style":{"color":{"_0":{"blendedSingleColor":{"_0":{"color":{"red":0.95,"green":0.8,"blue":0.55,"alpha":1}}}}}}}}}}
        """)
        let t = ArcTheme.theme(from: raw)
        XCTAssertEqual(t.colors.count, 1)
        XCTAssertEqual(t.intensity, SpaceTheme.defaultIntensity)
    }

    func testMidToneFallbackAndHexFallback() {
        let t = ArcTheme.theme(from: json(#"{"primaryColorPalette":{"midTone":{"red":0.557,"green":0.863,"blue":0.753,"alpha":1}}}"#))
        XCTAssertEqual(t.colors.first?.hex, "#8EDCC0")
        XCTAssertEqual(ArcTheme.theme(from: nil, fallbackColors: ["#112233"]).colors.first?.hex, "#112233")
        XCTAssertEqual(ArcTheme.theme(from: nil), .neutral)
    }

    func testChromiumProfileColor() {
        // -16776961 is 0xFF0000FF as a signed ARGB integer: opaque blue.
        XCTAssertEqual(ArcTheme.chromiumColor(-16776961)?.hex, "#0000FF")
        XCTAssertNil(ArcTheme.chromiumColor("x"))
    }
}

final class HistoryTests: XCTestCase {
    func testVisitsArePerProfileAndRanked() throws {
        let h = try HistoryStore(path: nil)
        for _ in 0..<5 { h.recordVisit(profileID: "work", url: "https://github.com/acme/web", title: "acme/web") }
        h.recordVisit(profileID: "work", url: "https://gitlab.example.com/", title: "GitLab")
        h.recordVisit(profileID: "home", url: "https://github.com/me", title: "me")
        h.recordVisit(profileID: "work", url: "about:blank")
        XCTAssertEqual(h.entries(ofProfile: "work").count, 2, "about: pages aren't history")
        let r = h.search("git", profileID: "work")
        XCTAssertEqual(r.first?.entry.url, "https://github.com/acme/web")
        XCTAssertFalse(h.search("git", profileID: "work").contains { $0.entry.url == "https://github.com/me" })
        XCTAssertEqual(h.entry(profileID: "work", url: "https://github.com/acme/web")?.visitCount, 5)
    }

    /// IM-4: another browser's history merges into Airc's; importing it again changes nothing.
    func testImportedVisitsMergeWithoutDoubling() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("airc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("history.sqlite").path
        let then = Date(timeIntervalSince1970: 1_790_000_000)
        let later = then.addingTimeInterval(3600)
        do {
            let h = try HistoryStore(path: path)
            h.now = { then }
            h.recordVisit(profileID: "work", url: "https://example.com/", typed: true)
            let visits = [
                HistoryEntry(profileID: "work", url: "https://example.com/", title: "Example", visitCount: 12, typedCount: 0, lastVisit: later),
                HistoryEntry(profileID: "work", url: "https://docs.example.com/", title: "Docs", visitCount: 2, lastVisit: then),
                HistoryEntry(profileID: "work", url: "chrome://settings/", title: "Settings", visitCount: 9, lastVisit: then),
            ]
            let first = h.importVisits(visits)
            XCTAssertEqual(first.added, 1)
            XCTAssertEqual(first.updated, 1)
            let again = h.importVisits(visits)
            XCTAssertEqual(again.added + again.updated, 0, "the same history again changes nothing")
            XCTAssertEqual(h.search("docs", profileID: "work").first?.entry.url, "https://docs.example.com/", "⌘T finds imported pages")
            XCTAssertTrue(h.entries(ofProfile: "home").isEmpty, "only the profile it went into")
        }
        let h = try HistoryStore(path: path)
        let e = try XCTUnwrap(h.entry(profileID: "work", url: "https://example.com/"))
        XCTAssertEqual(e.visitCount, 12, "the higher count, never the sum")
        XCTAssertEqual(e.typedCount, 1)
        XCTAssertEqual(e.title, "Example")
        XCTAssertEqual(e.lastVisit, later)
        XCTAssertEqual(h.entries(ofProfile: "work").count, 2, "chrome:// pages aren't history")
    }

    func testFrecencyDecays() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = HistoryEntry(profileID: "p", url: "https://a", visitCount: 2, lastVisit: now)
        let old = HistoryEntry(profileID: "p", url: "https://b", visitCount: 10, lastVisit: now.addingTimeInterval(-200 * 86400))
        XCTAssertGreaterThan(fresh.frecency(now: now), old.frecency(now: now))
    }

    func testPersistsAndClears() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("airc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("history.sqlite").path
        do {
            let h = try HistoryStore(path: path)
            h.recordVisit(profileID: "p", url: "https://example.com/", title: "Example")
            h.updateTitle(profileID: "p", url: "https://example.com/", title: "Example Domain")
        }
        let h = try HistoryStore(path: path)
        XCTAssertEqual(h.entry(profileID: "p", url: "https://example.com/")?.title, "Example Domain")
        h.clear(profileID: "p")
        XCTAssertTrue(try HistoryStore(path: path).entries(ofProfile: "p").isEmpty)
    }

    func testInlineCompletion() {
        let c: [(url: String, weight: Double)] = [
            ("https://github.com/acme/web", 3), ("https://github.com/acme/api", 3), ("https://gitlab.com/x", 4),
            ("https://www.google.com/search?q=x", 1),
        ]
        // Pages on the same host add up: github.com (6) beats gitlab.com (4).
        XCTAssertEqual(InlineCompletion.complete("gi", candidates: c)?.text, "github.com")
        XCTAssertEqual(InlineCompletion.complete("gi", candidates: c)?.suffix, "thub.com")
        XCTAssertEqual(InlineCompletion.complete("gi", candidates: c)?.url, "https://github.com/")
        XCTAssertEqual(InlineCompletion.complete("Gitl", candidates: c)?.text, "Gitlab.com", "keeps what was typed")
        XCTAssertEqual(InlineCompletion.complete("www.goo", candidates: c)?.text, "www.google.com")
        XCTAssertEqual(InlineCompletion.complete("github.com/acme/w", candidates: c)?.text, "github.com/acme/web")
        XCTAssertNil(InlineCompletion.complete("github.com", candidates: c), "nothing left to complete")
        XCTAssertNil(InlineCompletion.complete("git hub", candidates: c), "a phrase is a search")
        XCTAssertNil(InlineCompletion.complete("hub", candidates: c), "prefix only, never the middle")
    }

    func testSearchSuggestionParsing() {
        let data = Data(#"["wiki",["wiki","wikipedia","Wikipedia ","wiki how",""],[],{}]"#.utf8)
        XCTAssertEqual(SearchSuggestions.parse(data, query: "wiki"), ["wikipedia", "wiki how"])
        XCTAssertEqual(SearchSuggestions.parse(Data("nope".utf8), query: "x"), [])
        XCTAssertEqual(SearchSuggestions.url(for: "a b&c", engine: .google)?.absoluteString,
                       "https://suggestqueries.google.com/complete/search?client=firefox&q=a%20b%26c")
        XCTAssertNil(SearchSuggestions.url(for: "x", engine: .kagi))
    }
}

final class GoogleAccountsTests: XCTestCase {
    func testListAccounts() {
        let text = #"["gaia.l.a.r",[["gaia.l.a",1,"Alex","alex@example.com","https://x/photo",1,1,0,null,1,"1",null,null,null,null,1],["gaia.l.a",1,"Old","old@example.com","",1,1,0,null,0,"2"]]]"#
        XCTAssertEqual(GoogleAccounts.emails(fromListAccounts: text), ["alex@example.com"])
        XCTAssertEqual(GoogleAccounts.emails(fromListAccounts: "<html>"), [])
        // Name and picture; nil (no answer) is not the same as [] (signed out); a JSON viewer's words around it.
        XCTAssertEqual(GoogleAccounts.accounts(fromListAccounts: text),
                       [GoogleAccount(name: "Alex", email: "alex@example.com", photoURL: "https://x/photo")])
        XCTAssertEqual(GoogleAccounts.accounts(fromListAccounts: #"["gaia.l.a.r",[]]"#), [])
        XCTAssertNil(GoogleAccounts.accounts(fromListAccounts: "<html><body>Sign in</body></html>"))
        XCTAssertEqual(GoogleAccounts.accounts(fromListAccounts: "Pretty-print\n" + text)?.map(\.email), ["alex@example.com"])
    }
}

final class DeferredWriteTests: XCTestCase {
    /// A Space switch writes its selection and the viewed tab lazily; the next flush persists both.
    func testDeferredSelectionAndActivationPersistOnFlush() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("airc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("spaces.sqlite").path
        var second = "", tab = ""
        do {
            let s = try SpacesStore(path: path)
            second = try s.createSpace(name: "Two").id
            tab = try s.openTab(url: "https://example.com", inSpace: second).id
            var notified = 0
            s.observe { c in if c.windowStateChanged { notified += 1 } }
            s.selectSpace(second, deferred: true)
            try s.activate(tab, inSpace: second)
            XCTAssertEqual(notified, 0, "a deferred selection notifies no one")
            XCTAssertTrue(s.hasPendingWrites)
            try s.flush()
            XCTAssertFalse(s.hasPendingWrites)
        }
        let s = try SpacesStore(path: path)
        XCTAssertEqual(s.selectedSpace.id, second)
        XCTAssertEqual(s.lastActiveTab(ofSpace: second)?.id, tab)
    }
}
