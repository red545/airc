// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircImport

final class SidebarTests: XCTestCase {
    func fixture() throws -> Data { try Data(contentsOf: Bundle.module.url(forResource: "StorableSidebar.sample", withExtension: "json", subdirectory: "Fixtures")!) }
    func parse(_ object: Any, today: Bool = true) throws -> ImportPlan { try ArcSidebarParser.parse(JSONSerialization.data(withJSONObject: object), includeToday: today) }
    func mutated(_ change: (inout [String: Any]) -> Void) throws -> ImportPlan {
        var raw = try JSONSerialization.jsonObject(with: fixture()) as! [String: Any]
        change(&raw); return try parse(raw)
    }
    func testPredecessorFixture() throws {
        let p = try ArcSidebarParser.parse(fixture())
        XCTAssertEqual(p.spaces.map(\.name), ["Personal", "Work", "Personal"])
        XCTAssertEqual(p.spaces.map(\.emoji), ["🏠", "🎨", "💼"])
        XCTAssertEqual(p.spaces.prefix(2).map { $0.theme.color }, ["#8edcc0", "#f2cc8c"])
        XCTAssertEqual(p.spaces.map(\.profileID), ["default", "Profile 1", "default"])
        XCTAssertEqual(p.spaces[0].pinned.map { item in
            switch item { case .tab(let t): return t.title ?? t.pageTitle ?? ""; case .folder(let f): return "[\(f.title)]"; case .split(let x): return "{\(x.tabs.count)}" }
        }, ["Budget - Google Sheets", "Sam's Roadmap", "[Acme]", "Browser Tools", "octocat (The Octocat)", "localhost:3000/lp"])
        guard case .folder(let f) = p.spaces[0].pinned[2], case .folder(let sub) = f.children[1] else { return XCTFail("Missing folder") }
        XCTAssertEqual(f.children.count, 3)
        // SV-2: the pinned split view in the folder stays a split.
        guard case .split(let split) = f.children[2] else { return XCTFail("the split view was flattened") }
        XCTAssertEqual(split.tabs.map(\.url), ["https://example.com/left", "https://example.com/right"])
        XCTAssertEqual(split.axis, "horizontal")
        XCTAssertEqual(sub.children.flatMap(\.tabs).first?.url, "https://www.figma.com/file/xyz")
        XCTAssertEqual(p.spaces[0].pinned[1].tabs.first?.pageTitle, "Roadmap")
        XCTAssertEqual(p.spaces[1].pinned.flatMap(\.tabs).map(\.url), ["https://dashboard.stripe.com/"])
        XCTAssertEqual(p.spaces[2].pinned.flatMap(\.tabs).map(\.url), ["https://linear.app/team"])
        XCTAssertEqual(p.spaces[0].today.map(\.url), ["https://www.youtube.com/watch?v=rapid"])
        XCTAssertTrue(p.warnings.contains { $0.code == .easel })
        XCTAssertFalse(p.warnings.contains { $0.code == .splitView })
        XCTAssertNil(p.favoriteItems)
        XCTAssertEqual(p.favorites["default"]?.map(\.url), ["https://mail.google.com/mail/u/0/#inbox", "https://calendar.google.com/calendar/u/0/r"])
        XCTAssertEqual(p.favorites["Profile 1"]?.map(\.url), ["https://mail.google.com/mail/u/1/#inbox", "https://app.slack.com/client/T1"])
        // Native import intentionally preserves profile identity and account URLs.
        XCTAssertEqual(p, try ArcSidebarParser.parse(fixture()))
        XCTAssertTrue(try ArcSidebarParser.parse(fixture(), includeToday: false).spaces.allSatisfy { $0.today.isEmpty })
        XCTAssertEqual(try JSONDecoder().decode(ImportPlan.self, from: JSONEncoder().encode(p)), p)
    }
    func testSyncMirror() throws {
        let p = try mutated { raw in
            var sidebar = obj(raw["sidebar"]); var containers = sidebar["containers"] as! [Any]
            var main = obj(containers[3]); main["topAppsContainerIDs"] = []; containers[3] = main; sidebar["containers"] = containers; raw["sidebar"] = sidebar
            raw["sidebarSyncState"] = [
                "container": ["value": ["topAppsContainerIDs": [["default": [:]], "R"]]],
                "items": ["R", ["value": ["id": "R", "childrenIds": ["T"]]], "T", ["value": ["id": "T", "data": ["tab": ["savedURL": "https://example.test/"]]]]]
            ]
        }
        XCTAssertEqual(p.favorites["default"]?.first?.url, "https://example.test/")
    }
    func simple(items: [Any] = [], spaces: [Any] = []) -> [String: Any] {
        ["version": 999, "sidebar": ["containers": [["global": [:]], ["items": items, "spaces": spaces]]]]
    }
    func testEmptyNewerAndInvalid() throws {
        let p = try parse(simple())
        XCTAssertEqual(Set(p.warnings.map(\.code)), [.newerVersion, .emptySpaces, .emptyItems])
        XCTAssertThrowsError(try parse(["hello": 1]))
        XCTAssertThrowsError(try parse([1, 2]))
        XCTAssertThrowsError(try ArcSidebarParser.parse(Data("broken".utf8)))
    }
    func testUnknownDeepCyclesMissingTitlesAndRoots() throws {
        var items: [Any] = [["id": "R", "childrenIds": ["T", "U", "MISSING", "F0", "BAD"]], ["id": "T", "data": ["tab": ["savedURL": "https://example.test"]]], ["id": "BAD", "data": ["tab": [:]]], ["id": "U", "data": ["futureKind": [:]], "childrenIds": ["R"]]]
        for n in 0..<70 { items.append(["id": "F\(n)", "data": ["list": [:]], "childrenIds": ["F\(n + 1)"]]) }
        let p = try parse(simple(items: items, spaces: [["id": "S", "containerIDs": ["pinned", "wrong"], "newContainerIDs": [["pinned": [:]], "R"]]]))
        XCTAssertEqual(p.spaces[0].name, "Space 1")
        XCTAssertEqual(p.spaces[0].theme.color, "#8edcc0")
        XCTAssertNil(p.spaces[0].pinned.first?.tabs.first?.pageTitle)
        for code: ImportWarning.Code in [.unsupportedItem, .missingItem, .cycle, .depthLimit, .invalidTab] { XCTAssertTrue(p.warnings.contains { $0.code == code }) }
        guard case .folder(let folder) = p.spaces[0].pinned.last else { return XCTFail() }
        XCTAssertEqual(folder.title, "Folder")
    }
    /// The import step names what changed: Notes and Easels left out, live folders made plain, a tab group's tabs in
    /// its place with its kind named; Arc's welcome tab and stray containers say nothing.
    func testWarningsNameWhatChanged() throws {
        let items: [Any] = [
            ["id": "R", "childrenIds": ["N", "E", "L", "G", "W", "C"]],
            ["id": "N", "data": ["arcDocument": [:]]],
            ["id": "E", "data": ["easel": [:]]],
            ["id": "L", "data": ["list": [:]], "automaticLiveFolderData": [:], "childrenIds": ["T1"]],
            ["id": "T1", "data": ["tab": ["savedURL": "https://example.com/1"]]],
            ["id": "G", "data": ["tabGroup": [:]], "childrenIds": ["T2"]],
            ["id": "T2", "data": ["tab": ["savedURL": "https://example.com/2"]]],
            ["id": "W", "data": ["welcomeToArc": [:]]],
            ["id": "C", "data": ["itemContainer": [:]], "childrenIds": ["T3"]],
            ["id": "T3", "data": ["tab": ["savedURL": "https://example.com/3"]]],
        ]
        let p = try parse(simple(items: items, spaces: [["id": "S", "newContainerIDs": [["pinned": [:]], "R"]]]))
        XCTAssertEqual(p.warnings.map(\.code).filter { $0 != .newerVersion }, [.note, .easel, .liveFolder, .unsupportedItem])
        XCTAssertEqual(p.warnings.last?.kind, "tabGroup")
        XCTAssertEqual(p.spaces[0].pinned.flatMap(\.tabs).map(\.url), ["https://example.com/1", "https://example.com/2", "https://example.com/3"])
    }
    func testGradientLossless() throws {
        let theme: [String: Any] = ["background": ["baseColors": [["red": 1, "green": 0, "blue": 0], ["red": 0, "green": 0, "blue": 1]], "intensityFactor": 0.81, "noise": true]]
        let p = try parse(simple(spaces: [["id": "S", "customInfo": ["windowTheme": theme]]]))
        XCTAssertEqual(p.spaces[0].theme.colors, ["#ff0000", "#0000ff"])
        XCTAssertEqual(p.spaces[0].theme.raw, jsonValue(theme))
    }
    func testProfileDiscovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let user = root.appendingPathComponent("User Data")
        try FileManager.default.createDirectory(at: user.appendingPathComponent("Default"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: user.appendingPathComponent("Profile 2"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["profile": ["info_cache": ["Default": ["name": "Synthetic", "avatar_icon": "avatar", "profile_color": 123], "Profile 1": ["name": "Missing"]]]]).write(to: user.appendingPathComponent("Local State"))
        let p = try ArcImporter.discoverProfiles(at: root)
        XCTAssertEqual(p.map(\.directory), ["Default", "Profile 1", "Profile 2"])
        XCTAssertEqual(p[0].name, "Synthetic")
        XCTAssertEqual(p[0].id, "default")
        XCTAssertEqual(p[0].avatar, "avatar")
        XCTAssertEqual(p[0].color, .number(123))
        XCTAssertFalse(p[1].isAvailable)
        XCTAssertThrowsError(try validateDirectory("../escape"))
        try Data("invalid".utf8).write(to: user.appendingPathComponent("Local State"))
        XCTAssertThrowsError(try ArcImporter.discoverProfiles(at: root)) { error in
            XCTAssertEqual(error as? ImportError, .invalidLocalState)
        }
    }
    /// SV-2: Arc's split views (SidebarSplitViewData) in pinned tabs and Favorites stay splits, with their orientation,
    /// width factors and focused tab; in Today they're flattened with a warning; past four tabs the rest stay tabs.
    func testSplitViewsInPinnedFavoritesAndToday() throws {
        func tab(_ id: String) -> [Any] { [id, ["id": id, "data": ["tab": ["savedURL": "https://\(id.lowercased()).test/"]]] as [String: Any]] }
        var items: [Any] = [
            "PIN", ["id": "PIN", "childrenIds": ["SV-P"]],
            "SV-P", ["id": "SV-P", "title": "Docs", "childrenIds": ["A", "B"],
                     "data": ["splitView": ["layoutOrientation": "vertical", "itemWidthFactors": ["A", 0.3, "B", 0.7], "focusItemID": "B"]]],
            "TODAY", ["id": "TODAY", "childrenIds": ["SV-T"]],
            "SV-T", ["id": "SV-T", "childrenIds": ["C", "D"], "data": ["splitView": ["layoutOrientation": ["horizontal": [:]]]]],
            "FAV", ["id": "FAV", "childrenIds": ["E", "SV-F"]],
            "SV-F", ["id": "SV-F", "childrenIds": ["F", "G", "H", "I", "J"], "data": ["splitView": ["itemWidthFactors": ["F": 2.0]]]],
        ]
        for id in ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J"] { items += tab(id) }
        let space: [String: Any] = ["id": "S", "containerIDs": ["pinned", "PIN", ["unpinned": [String: Any]()], "TODAY"] as [Any]]
        let main: [String: Any] = ["items": items, "spaces": [space], "topAppsContainerIDs": [["default": [String: Any]()], "FAV"] as [Any]]
        let containers: [Any] = [["global": [String: Any]()], main]
        let p = try parse(["sidebar": ["containers": containers]] as [String: Any])
        guard case .split(let pinned)? = p.spaces[0].pinned.first else { return XCTFail("no pinned split") }
        XCTAssertEqual(pinned.title, "Docs")
        XCTAssertEqual(pinned.axis, "vertical")
        XCTAssertEqual(pinned.shares, [0.3, 0.7])
        XCTAssertEqual(pinned.focusedID, "B")
        XCTAssertEqual(pinned.tabs.map(\.id), ["A", "B"])
        XCTAssertEqual(p.spaces[0].today.map(\.id), ["C", "D"])
        XCTAssertEqual(p.warnings.filter { $0.code == .splitView }.count, 1)
        XCTAssertEqual(p.favorites["default"]?.map(\.id), ["E", "F", "G", "H", "I", "J"])
        guard let favs = p.favoriteItems?["default"], favs.count == 3, case .split(let fav) = favs[1] else {
            return XCTFail("Favorites lost their split: \(String(describing: p.favoriteItems))")
        }
        XCTAssertEqual(fav.tabs.map(\.id), ["F", "G", "H", "I"])
        XCTAssertEqual(fav.shares, [2, 0, 0, 0])
        XCTAssertEqual(fav.axis, "horizontal")
        XCTAssertEqual(favs[2].tabs.map(\.id), ["J"])
        XCTAssertEqual(try JSONDecoder().decode(ImportPlan.self, from: JSONEncoder().encode(p)), p)
    }
}
