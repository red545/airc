// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// P17a: share links (docs/dev/share-links.md): round trips, and every way a hostile link is refused whole.
final class ShareLinksTests: XCTestCase {
    override class func setUp() { super.setUp(); TestSuffixes.installForClass() }
    override class func tearDown() { TestSuffixes.restoreAfterClass(); super.tearDown() }

    let trip = ShareSnapshot(.space(name: "Trip to Lisbon", icon: "🧳", items: [
        .tab(ShareTab(url: "https://www.visitlisboa.com/", title: "Visit Lisboa")),
        .folder(name: "Food — pastéis 🥮", items: [
            .tab(ShareTab(url: "https://example.com/pasteis?x=1&y=2#top")),
            .folder(name: "Empty", items: []),
        ]),
        .split(axis: .vertical, tabs: [ShareTab(url: "https://maps.example.com/", title: "Map"),
                                       ShareTab(url: "http://example.org/plan", title: "Plan")]),
    ]))

    /// A link carrying `json` as it is (deflated and encoded as the format says), for hostile payloads.
    func link(json: String, version: String = "v1") -> URL {
        let packed = BoostLink.deflate(Data(json.utf8))!
        return URL(string: "https://aircbrowser.com/s#\(version).\(BoostLink.base64url(packed))")!
    }

    func failure(_ url: URL) -> ShareLink.Failure? {
        do { _ = try ShareLink.snapshot(from: url); return nil } catch { return error as? ShareLink.Failure }
    }

    // MARK: Round trips

    func testASpaceRoundTripsWithOrderNestingSplitsAndText() throws {
        let url = try ShareLink.url(for: trip)
        XCTAssertEqual(url.host, "aircbrowser.com")
        XCTAssertEqual(url.path, "/s")
        XCTAssertTrue(url.fragment!.hasPrefix("v1."))
        XCTAssertNil(url.query)
        XCTAssertEqual(try ShareLink.snapshot(from: url), trip)
        let counts = trip.counts
        XCTAssertEqual([counts.tabs, counts.folders, counts.splits], [4, 2, 1])
        // The app's link and www. read the same.
        XCTAssertEqual(try ShareLink.snapshot(from: ShareLink.appURL(for: url)!), trip)
        XCTAssertEqual(try ShareLink.snapshot(from: URL(string: url.absoluteString.replacingOccurrences(of: "//aircbrowser", with: "//www.aircbrowser"))!), trip)
    }

    func testAFolderAndABoostRoundTrip() throws {
        let folder = ShareSnapshot(.folder(name: "Reading", icon: nil, items: [.tab(ShareTab(url: "https://example.com/a"))]))
        XCTAssertEqual(try ShareLink.snapshot(from: ShareLink.url(for: folder)), folder)
        var f = BoostFile(boost: Boost(domain: "alice.github.io", colors: .init(tint: 0.2), css: "body { color: purple }",
                                       created: Date(timeIntervalSince1970: 1700000000)), name: "Quiet reading")
        f.preview = Data([0xFF, 0xD8, 0xFF]).base64EncodedString()
        guard case .boost(let back) = try ShareLink.snapshot(from: ShareLink.url(for: ShareSnapshot(.boost(f)))).kind else {
            return XCTFail("not a Boost")
        }
        XCTAssertNil(back.preview, "a link never carries the picture")
        XCTAssertEqual(back.name, "Quiet reading")
        XCTAssertEqual(back.css, "body { color: purple }")
    }

    // MARK: Hostile links

    func testOnlyShareLinksAndKnownVersionsAreRead() throws {
        let good = try ShareLink.url(for: trip)
        let payload = good.fragment!.dropFirst(3)
        for s in ["https://evil.example/s#v1.\(payload)", "http://aircbrowser.com/s#v1.\(payload)", "https://aircbrowser.com/x#v1.\(payload)",
                  "https://aircbrowser.com.evil.example/s#v1.\(payload)", "airc://other#v1.\(payload)"] {
            XCTAssertFalse(ShareLink.isLink(URL(string: s)), s)
            XCTAssertEqual(failure(URL(string: s)!), .damaged, s)
        }
        XCTAssertEqual(failure(URL(string: "https://aircbrowser.com/s#v2.\(payload)")!), .newerVersion)
        XCTAssertEqual(failure(URL(string: "https://aircbrowser.com/s#v99.\(payload)")!), .newerVersion)
        for tag in ["v0", "v01", "vx", "v", "v-1", "v1x", "v1234567890"] {
            XCTAssertEqual(failure(URL(string: "https://aircbrowser.com/s#\(tag).\(payload)")!), .damaged, tag)
        }
        XCTAssertEqual(failure(URL(string: "https://aircbrowser.com/s#v1.")!), .damaged)
        XCTAssertEqual(failure(URL(string: "https://aircbrowser.com/s#v1.ab+c/d==")!), .damaged, "only base64url, no padding")
        XCTAssertEqual(failure(URL(string: "https://aircbrowser.com/s#v1.AAAAAAAA")!), .damaged, "not a DEFLATE stream")
    }

    func testSizeIsCheckedBeforeDecodingAndInflatingStopsAtTheCap() throws {
        let long = String(repeating: "A", count: ShareLink.maximumPayload + 1)
        XCTAssertEqual(failure(URL(string: "https://aircbrowser.com/s#v1.\(long)")!), .tooLarge)
        // A zip bomb: a few kilobytes of payload that would inflate to 4 MB.
        let bomb = "{\"kind\":\"folder\",\"name\":\"a\",\"items\":[]" + String(repeating: " ", count: 4_000_000) + "}"
        let url = link(json: bomb)
        XCTAssertLessThan(url.absoluteString.count, ShareLink.maximumPayload)
        XCTAssertEqual(failure(url), .tooLarge)
        // Deep brackets never reach the JSON parser.
        let deep = "{\"kind\":\"folder\",\"name\":\"a\",\"items\":" + String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000) + "}"
        XCTAssertEqual(failure(link(json: deep)), .tooLarge)
    }

    func testCountAndDepthLimits() throws {
        func folder(depth: Int) -> String {
            depth == 0 ? "{\"type\":\"tab\",\"url\":\"https://example.com/\"}"
                : "{\"type\":\"folder\",\"name\":\"f\",\"items\":[\(folder(depth: depth - 1))]}"
        }
        XCTAssertNoThrow(try ShareLink.snapshot(from: link(json: "{\"kind\":\"space\",\"name\":\"s\",\"items\":[\(folder(depth: ShareLink.maximumDepth))]}")))
        XCTAssertEqual(failure(link(json: "{\"kind\":\"space\",\"name\":\"s\",\"items\":[\(folder(depth: ShareLink.maximumDepth + 1))]}")), .tooLarge)
        let tab = "{\"type\":\"tab\",\"url\":\"https://example.com/\"}"
        let many = Array(repeating: tab, count: ShareLink.maximumTabs + 1).joined(separator: ",")
        XCTAssertEqual(failure(link(json: "{\"kind\":\"space\",\"name\":\"s\",\"items\":[\(many)]}")), .tooLarge)
        let folders = Array(repeating: "{\"type\":\"folder\",\"name\":\"f\",\"items\":[]}", count: ShareLink.maximumNodes) .joined(separator: ",")
        XCTAssertEqual(failure(link(json: "{\"kind\":\"space\",\"name\":\"s\",\"items\":[\(tab),\(folders)]}")), .tooLarge)
        XCTAssertEqual(failure(link(json: "{\"kind\":\"space\",\"name\":\"s\",\"items\":[]}")), .damaged, "nothing to add")
        XCTAssertEqual(failure(link(json: "{\"kind\":\"space\",\"name\":\"s\",\"items\":[{\"type\":\"folder\",\"name\":\"f\",\"items\":[]}]}")), .damaged,
                       "folders without a tab")
    }

    func testOnlyWebAddressesAreAccepted() throws {
        for url in ["javascript:alert(1)", "JAVASCRIPT:alert(1)", "data:text/html,<b>x</b>", "file:///etc/hosts", "blob:https://a/1",
                    "about:blank", "chrome://settings", "airc://share#v1.x", "https://user:pw@example.com/", "https://user@example.com/",
                    "http:/example.com", "https://", " https://example.com/", "https://exa mple.com/", "https://example.com/\u{0007}",
                    "ftp://example.com/x", "https://example.com/" + String(repeating: "a", count: 4_100)] {
            XCTAssertFalse(ShareLink.isSafeAddress(url), url)
            let json = "{\"kind\":\"folder\",\"name\":\"f\",\"items\":[{\"type\":\"tab\",\"url\":\(String(data: try JSONSerialization.data(withJSONObject: [url]), encoding: .utf8)!.dropFirst().dropLast())}]}"
            XCTAssertEqual(failure(link(json: json)), .unsafeAddress, url)
        }
        XCTAssertTrue(ShareLink.isSafeAddress("HTTPS://Example.com:8443/a?b=c#d"))
        XCTAssertEqual(ShareLink.shareable("https://user:secret@example.com/x"), "https://example.com/x", "credentials are dropped when sharing")
        XCTAssertNil(ShareLink.shareable("airc-note:1234"))
        XCTAssertThrowsError(try ShareLink.url(for: ShareSnapshot(.folder(name: "f", icon: nil, items: [.tab(ShareTab(url: "javascript:1"))]))),
                             "a link Airc makes is read back first")
    }

    func testTheSchemaIsExact() throws {
        let tab = "{\"type\":\"tab\",\"url\":\"https://example.com/\"}"
        let bad = [
            "[]", "\"x\"", "{}", "not json",
            "{\"kind\":\"space\",\"name\":\"s\",\"items\":[\(tab)],\"extra\":1}",
            "{\"kind\":\"space\",\"name\":\"s\",\"items\":[{\"type\":\"tab\",\"url\":\"https://example.com/\",\"cookies\":\"x\"}]}",
            "{\"kind\":\"space\",\"name\":null,\"items\":[\(tab)]}",
            "{\"kind\":\"space\",\"name\":\"s\",\"icon\":null,\"items\":[\(tab)]}",
            "{\"kind\":\"space\",\"name\":\"s\",\"icon\":\"AB\",\"items\":[\(tab)]}",
            "{\"kind\":\"space\",\"name\":\"\",\"items\":[\(tab)]}",
            "{\"kind\":\"space\",\"name\":\"   \",\"items\":[\(tab)]}",
            "{\"kind\":\"space\",\"name\":\"a\\u0000b\",\"items\":[\(tab)]}",
            "{\"kind\":\"space\",\"name\":\"\(String(repeating: "n", count: 201))\",\"items\":[\(tab)]}",
            "{\"kind\":\"space\",\"name\":\"s\",\"items\":[{\"type\":\"tab\",\"url\":\"https://example.com/\",\"title\":\"a\\u001bb\"}]}",
            "{\"kind\":\"space\",\"name\":\"s\",\"items\":[{\"type\":\"tab\",\"url\":\"https://example.com/\",\"title\":\"\(String(repeating: "t", count: 501))\"}]}",
            "{\"kind\":\"space\",\"name\":\"s\",\"items\":[{\"type\":\"tab\",\"url\":42}]}",
            "{\"kind\":\"space\",\"name\":\"s\",\"items\":[{\"type\":\"note\",\"text\":\"x\"}]}",
            "{\"kind\":\"space\",\"name\":\"s\",\"items\":[{\"type\":\"split\",\"items\":[\(tab)]}]}",
            "{\"kind\":\"space\",\"name\":\"s\",\"items\":[{\"type\":\"split\",\"items\":[\(tab),\(tab),\(tab),\(tab),\(tab)]}]}",
            "{\"kind\":\"space\",\"name\":\"s\",\"items\":[{\"type\":\"split\",\"items\":[\(tab),{\"type\":\"folder\",\"name\":\"f\",\"items\":[]}]}]}",
            "{\"kind\":\"space\",\"name\":\"s\",\"items\":[{\"type\":\"split\",\"axis\":\"diagonal\",\"items\":[\(tab),\(tab)]}]}",
            "{\"kind\":\"notes\",\"name\":\"s\",\"items\":[\(tab)]}",
            "{\"kind\":\"boost\",\"boost\":{\"version\":2}}",
        ]
        for json in bad { XCTAssertEqual(failure(link(json: json)), .damaged, json) }
    }

    // MARK: The sidebar

    func store() throws -> SpacesStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("airc-share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return try SpacesStore(path: dir.appendingPathComponent("store.sqlite").path)
    }

    func testShareSpaceTakesThePinnedTreeOnlyAndAddingItBackKeepsIt() throws {
        let s = try store()
        let sid = try s.createSpace(name: "Work", icon: .emoji("🛠️")).id
        func pin(_ url: String, parent: String? = nil) throws -> String {
            let t = try s.openTab(url: url, inSpace: sid)
            try s.move(.tab(t.id), to: .pinned(spaceID: sid, parentID: parent, index: 99))
            return s.tab(t.id)?.itemID ?? ""
        }
        _ = try pin("https://user:pw@example.com/one")
        let folder = try s.createFolder(named: "Docs", inSpace: sid)
        _ = try pin("https://example.com/two", parent: folder.id)
        _ = try pin("airc-note:abc", parent: folder.id)
        _ = try s.openTab(url: "https://example.com/today", inSpace: sid)
        let draft = try XCTUnwrap(s.shareDraft(ofSpace: sid))
        XCTAssertEqual(draft.leftOut, 1, "the note isn't shared")
        XCTAssertEqual(draft.todayTabs, 1, "Today tabs aren't in a Space link")
        guard case .space(let name, let icon, let items) = draft.snapshot.kind else { return XCTFail() }
        XCTAssertEqual(name, "Work")
        XCTAssertEqual(icon, "🛠️")
        XCTAssertEqual(items, [.tab(ShareTab(url: "https://example.com/one")),
                               .folder(name: "Docs", items: [.tab(ShareTab(url: "https://example.com/two"))])])
        // Read back from its link and added as a new Space: the same tree, unloaded, one undo step.
        let back = try ShareLink.snapshot(from: ShareLink.url(for: draft.snapshot))
        let before = s.orderedSpaces.count
        let added = try s.addSharedSpace(back, profileID: nil, after: sid)
        XCTAssertEqual(s.orderedSpaces.count, before + 1)
        XCTAssertEqual(s.shareDraft(ofSpace: added.id)?.snapshot, draft.snapshot)
        XCTAssertTrue(s.todayTabs(ofSpace: added.id).isEmpty)
        XCTAssertNil(s.children(of: .pinned(spaceID: added.id), parent: nil).compactMap { s.liveTab(forItem: $0.id) }.first, "nothing opens")
        _ = try s.undo()
        XCTAssertEqual(s.orderedSpaces.count, before)
    }

    func testAFolderAndASplitComeBackIntoAnotherSpace() throws {
        let s = try store()
        let sid = try s.createSpace(name: "Plans").id
        let snapshot = ShareSnapshot(.folder(name: "Plan", icon: "🗺️", items: [
            .split(axis: .vertical, tabs: [ShareTab(url: "https://a.example/", title: "A"), ShareTab(url: "https://b.example/")]),
            .folder(name: "Inner", items: [.tab(ShareTab(url: "https://c.example/", title: "C"))]),
        ]))
        let folder = try s.addSharedFolder(snapshot, toSpace: sid)
        XCTAssertEqual(folder.title, "Plan")
        XCTAssertEqual(s.shareDraft(ofFolder: folder.id)?.snapshot.items, snapshot.items)
        let split = try XCTUnwrap(s.children(of: .pinned(spaceID: sid), parent: folder.id).first)
        XCTAssertEqual(split.kind, .split)
        XCTAssertEqual(split.splitLayout?.axis, .vertical)
        XCTAssertEqual(s.panes(ofSplitItem: split.id).map(\.savedURL), ["https://a.example/", "https://b.example/"])
    }

    func testAWrongKindOrAMissingSpaceAddsNothing() throws {
        let s = try store()
        let items = s.state.items.count, spaces = s.orderedSpaces.count
        XCTAssertThrowsError(try s.addSharedSpace(ShareSnapshot(.folder(name: "f", icon: nil, items: [.tab(ShareTab(url: "https://a.example/"))])),
                                                  profileID: nil, after: nil))
        XCTAssertThrowsError(try s.addSharedFolder(ShareSnapshot(.folder(name: "f", icon: nil, items: [.tab(ShareTab(url: "https://a.example/"))])),
                                                   toSpace: "missing"))
        XCTAssertEqual(s.state.items.count, items)
        XCTAssertEqual(s.orderedSpaces.count, spaces)
    }
}
