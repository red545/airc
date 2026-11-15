// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
@testable import AircKit
import XCTest

/// P19b: live Captures (the source, its geometry, refresh outcomes, the schedule, undo across refreshes), Easels kept
/// out of splits, and a duplicated Easel row getting an Easel of its own.
final class EaselLiveTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("easel-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        EaselFiles.shared = nil
        try? FileManager.default.removeItem(at: root)
    }

    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func source(mode: EaselLiveSource.Mode = .live) -> EaselLiveSource {
        EaselLiveSource(url: "https://example.com/stats", profileID: "p1", rect: EaselRect(x: 100, y: 900, width: 300, height: 200),
                        scrollX: 0, scrollY: 800, viewportWidth: 1200, viewportHeight: 800, zoom: 1, mode: mode, refreshedAt: t0)
    }

    func liveDoc() -> EaselDocument {
        var d = EaselDocument(id: "e1", title: "Board")
        d.add(EaselBlock(id: "c", frame: EaselRect(x: 0, y: 0, width: 300, height: 200),
                         content: .capture(EaselCapture(asset: String(repeating: "a", count: 64) + ".png", pixelWidth: 600, pixelHeight: 400,
                                                        url: "https://example.com/stats", title: "Stats", capturedAt: t0, live: source()))))
        d.add(EaselBlock(id: "s", frame: EaselRect(x: 400, y: 0, width: 50, height: 50), content: .shape(EaselShape(.rectangle))))
        return d
    }

    // MARK: The source

    func testOnlyWebPagesOfAProfileCanBeLive() {
        XCTAssertTrue(EaselLiveSource.isLiveableURL("https://example.com/a"))
        XCTAssertTrue(EaselLiveSource.isLiveableURL("http://127.0.0.1:8080/"))
        for bad in ["airc-note:x", "airc-easel:e1", "file:///etc/hosts", "about:blank", "javascript:alert(1)", "data:text/html,x", "chrome://settings", "", "https://"] {
            XCTAssertFalse(EaselLiveSource.isLiveableURL(bad), bad)
        }
        let page = EaselLiveGeometry.PageMetrics(scrollX: 0, scrollY: 0, innerWidth: 1000, innerHeight: 700)
        let sel = EaselRect(x: 10, y: 10, width: 100, height: 100)
        XCTAssertNil(EaselLiveGeometry.source(selection: sel, viewWidth: 1000, page: page, url: "file:///x.html", profileID: "p1"))
        // No profile (a private window's page has none): never live.
        XCTAssertNil(EaselLiveGeometry.source(selection: sel, viewWidth: 1000, page: page, url: "https://example.com", profileID: ""))
        XCTAssertNotNil(EaselLiveGeometry.source(selection: sel, viewWidth: 1000, page: page, url: "https://example.com", profileID: "p1"))
    }

    func testTheRegionIsInCSSPixelsSoItSurvivesZoomAndScroll() throws {
        // The same region of the page captured at 100 %, 125 % and 50 %, and pinch-zoomed: one rect in CSS pixels.
        let expected = EaselRect(x: 150, y: 1020, width: 200, height: 80)
        for (zoom, pinch) in [(1.0, 1.0), (1.25, 1.0), (0.5, 1.0), (1.0, 2.0)] {
            let viewWidth = 1200.0
            let inner = viewWidth / zoom
            let scrollY = 1000.0
            let vvLeft = 100.0, vvTop = scrollY
            let page = EaselLiveGeometry.PageMetrics(scrollX: 0, scrollY: scrollY, innerWidth: inner, innerHeight: 800 / zoom,
                                                     visualScale: pinch, visualLeft: pinch == 1 ? 0 : vvLeft, visualTop: vvTop)
            let k = zoom * pinch
            let left = pinch == 1 ? 0 : vvLeft
            let sel = EaselRect(x: (expected.x - left) * k, y: (expected.y - vvTop) * k, width: expected.width * k, height: expected.height * k)
            let s = try XCTUnwrap(EaselLiveGeometry.source(selection: sel, viewWidth: viewWidth, page: page, url: "https://example.com/", profileID: "p1"))
            XCTAssertEqual(s.rect.x, expected.x, accuracy: 0.001, "zoom \(zoom) pinch \(pinch)")
            XCTAssertEqual(s.rect.y, expected.y, accuracy: 0.001)
            XCTAssertEqual(s.rect.width, expected.width, accuracy: 0.001)
            XCTAssertEqual(s.rect.height, expected.height, accuracy: 0.001)
            XCTAssertEqual(s.zoom, zoom, accuracy: 0.0001)
            XCTAssertEqual(s.viewportWidth, inner, accuracy: 0.0001)
        }
        // A layout width the engine rounded still reads as the zoom step.
        XCTAssertEqual(EaselLiveGeometry.zoom(viewWidth: 1200, innerWidth: 960.4), 1.25)
    }

    func testCropFindsTheRegionInAViewportPictureAfterReload() throws {
        let s = source()
        // A reload laid out at the same width and scrolled back: 2 px per CSS pixel.
        let page = EaselLiveGeometry.PageMetrics(scrollX: 0, scrollY: 800, innerWidth: 1200, innerHeight: 800)
        let c = try XCTUnwrap(EaselLiveGeometry.crop(s, pixelWidth: 2400, pixelHeight: 1600, page: page))
        XCTAssertEqual(c, EaselRect(x: 200, y: 200, width: 600, height: 400))
        // The page came back shorter, so the scroll stopped early: the region is lower in the picture, cut at the edge.
        let short = EaselLiveGeometry.PageMetrics(scrollX: 0, scrollY: 400, innerWidth: 1200, innerHeight: 800)
        let cut = try XCTUnwrap(EaselLiveGeometry.crop(s, pixelWidth: 2400, pixelHeight: 1600, page: short))
        XCTAssertEqual(cut, EaselRect(x: 200, y: 1000, width: 600, height: 400))
        // Gone from the page (scrolled nowhere near it): no picture rather than the wrong one.
        let far = EaselLiveGeometry.PageMetrics(scrollX: 0, scrollY: 0, innerWidth: 1200, innerHeight: 800)
        XCTAssertNil(EaselLiveGeometry.crop(s, pixelWidth: 2400, pixelHeight: 1600, page: far))
        // Scroll target: the captured scroll shows the region, so it's used as is.
        XCTAssertEqual(EaselLiveGeometry.scrollTarget(s).y, 800)
        var off = s
        off.scrollY = 0
        XCTAssertEqual(EaselLiveGeometry.scrollTarget(off).y, 884)
    }

    func testPageMetricsReadTheScriptsAnswer() throws {
        let m = try XCTUnwrap(EaselLiveGeometry.PageMetrics("[0,120.5,1280,720,1,0,120.5]"))
        XCTAssertEqual(m.scrollY, 120.5)
        XCTAssertEqual(m.innerWidth, 1280)
        XCTAssertNil(EaselLiveGeometry.PageMetrics("[0,0,0,720]"))
        XCTAssertNil(EaselLiveGeometry.PageMetrics("nonsense"))
        XCTAssertNil(EaselLiveGeometry.PageMetrics(nil))
    }

    func testSignedOutPagesAreRecognised() {
        let a = "https://app.example.com/dashboard"
        XCTAssertTrue(EaselLiveGeometry.looksSignedOut(captured: a, landed: a, httpStatus: 401))
        XCTAssertTrue(EaselLiveGeometry.looksSignedOut(captured: a, landed: a, httpStatus: 403))
        XCTAssertTrue(EaselLiveGeometry.looksSignedOut(captured: a, landed: "https://app.example.com/login?next=/dashboard", httpStatus: 200))
        XCTAssertTrue(EaselLiveGeometry.looksSignedOut(captured: a, landed: "https://accounts.google.com/v3/signin/identifier", httpStatus: 200))
        XCTAssertFalse(EaselLiveGeometry.looksSignedOut(captured: a, landed: a, httpStatus: 200))
        XCTAssertFalse(EaselLiveGeometry.looksSignedOut(captured: "https://example.com/login", landed: "https://example.com/login", httpStatus: 200))
        XCTAssertFalse(EaselLiveGeometry.looksSignedOut(captured: a, landed: "https://example.com/dashboard/", httpStatus: 200))
    }

    // MARK: The document

    func testTheSourceRoundTripsAndOldOrDamagedOnesStayPictures() throws {
        let d = liveDoc()
        let back = try EaselFiles.decoder().decode(EaselDocument.self, from: EaselFiles.encode(d))
        XCTAssertEqual(back, d)
        XCTAssertEqual(back.liveSource("c")?.rect, source().rect)
        // A P19a file (no `live`) reads as a static Capture.
        var old = d
        old.setLive(nil, for: "c")
        let oldBack = try EaselFiles.decoder().decode(EaselDocument.self, from: EaselFiles.encode(old))
        XCTAssertNil(oldBack.liveSource("c"))
        // A source that makes no sense (hand-edited, a newer build's) leaves the block, as a static picture.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: EaselFiles.encode(d)) as? [String: Any])
        var blocks = try XCTUnwrap(json["blocks"] as? [[String: Any]])
        let ci = try XCTUnwrap(blocks.firstIndex { $0["id"] as? String == "c" })
        var content = try XCTUnwrap(blocks[ci]["content"] as? [String: Any])
        content["live"] = ["url": "file:///etc/passwd", "profileID": "p1", "rect": ["x": 0, "y": 0, "width": 10, "height": 10],
                           "viewportWidth": 100, "viewportHeight": 100, "mode": "hologram"]
        blocks[ci]["content"] = content
        json["blocks"] = blocks
        let damaged = try EaselFiles.decoder().decode(EaselDocument.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(damaged.blocks.count, 2)
        XCTAssertNil(damaged.liveSource("c"))
        // An unknown mode alone reads as Manual (never refreshes by itself).
        content["live"] = ["url": "https://example.com", "profileID": "p1", "rect": ["x": 0, "y": 0, "width": 10, "height": 10],
                           "viewportWidth": 100, "viewportHeight": 100, "mode": "hologram", "status": "quantum"]
        blocks[ci]["content"] = content
        json["blocks"] = blocks
        let newer = try EaselFiles.decoder().decode(EaselDocument.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(newer.liveSource("c")?.mode, .manual)
        XCTAssertEqual(newer.liveSource("c")?.status, .ok)
    }

    func testOutcomesKeepTheLastPictureAndALateAnswerNeverLands() throws {
        var d = liveDoc()
        let sid = try XCTUnwrap(d.liveSource("c")?.id)
        let t1 = t0.addingTimeInterval(3600)
        // Signed out, offline, an error: the picture stays, the state says why, failures count.
        XCTAssertTrue(d.applyLive(.signedOut, blockID: "c", sourceID: sid, at: t1))
        guard case .capture(let c1)? = d.block("c")?.content else { return XCTFail() }
        XCTAssertEqual(c1.asset, String(repeating: "a", count: 64) + ".png")
        XCTAssertEqual(c1.live?.status, .signedOut)
        XCTAssertEqual(c1.live?.problem, "Sign in to refresh")
        XCTAssertEqual(c1.live?.failures, 1)
        XCTAssertEqual(c1.live?.refreshedAt, t0)
        d.applyLive(.offline, blockID: "c", sourceID: sid, at: t1)
        d.applyLive(.failed("Page not found (404)"), blockID: "c", sourceID: sid, at: t1)
        XCTAssertEqual(d.liveSource("c")?.problem, "Page not found (404)")
        XCTAssertEqual(d.liveSource("c")?.failures, 3)
        // A new picture: swapped in, the state cleared.
        let newAsset = String(repeating: "b", count: 64) + ".png"
        XCTAssertTrue(d.applyLive(.picture(asset: newAsset, pixelWidth: 500, pixelHeight: 333), blockID: "c", sourceID: sid, at: t1))
        guard case .capture(let c2)? = d.block("c")?.content else { return XCTFail() }
        XCTAssertEqual(c2.asset, newAsset)
        XCTAssertEqual(c2.pixelWidth, 500)
        XCTAssertEqual(c2.capturedAt, t1)
        XCTAssertEqual(c2.live?.status, .ok)
        XCTAssertEqual(c2.live?.failures, 0)
        XCTAssertEqual(d.block("c")?.frame, EaselRect(x: 0, y: 0, width: 300, height: 200), "the block stays where it is")
        // Detached while a refresh ran: its answer is dropped. The same after the source was set again.
        var detached = d
        detached.setLive(nil, for: "c")
        XCTAssertFalse(detached.applyLive(.picture(asset: newAsset, pixelWidth: 1, pixelHeight: 1), blockID: "c", sourceID: sid))
        var reset = d
        reset.setLive(source(), for: "c")
        XCTAssertFalse(reset.applyLive(.offline, blockID: "c", sourceID: sid))
        var deleted = d
        deleted.remove(["c"])
        XCTAssertFalse(deleted.applyLive(.offline, blockID: "c", sourceID: sid))
        // Not a capture, or an invalid source: refused.
        XCTAssertFalse(d.setLive(source(), for: "s"))
        var bad = source()
        bad.url = "file:///x"
        XCTAssertFalse(d.setLive(bad, for: "c"))
    }

    func testTheScheduleRefreshesStaleLiveBlocksAndBacksOff() throws {
        var d = liveDoc()
        let sid = try XCTUnwrap(d.liveSource("c")?.id)
        XCTAssertEqual(d.dueLiveBlocks(now: t0.addingTimeInterval(60)), [])
        XCTAssertEqual(d.dueLiveBlocks(now: t0.addingTimeInterval(EaselLivePolicy.staleAfter)), ["c"])
        // Manual blocks never refresh by themselves.
        d.setLiveMode(.manual, for: "c")
        XCTAssertEqual(d.dueLiveBlocks(now: t0.addingTimeInterval(86400)), [])
        d.setLiveMode(.live, for: "c")
        // Two failures: the next try waits 15 min × 2.
        let t1 = t0.addingTimeInterval(3600)
        d.applyLive(.offline, blockID: "c", sourceID: sid, at: t1)
        d.applyLive(.offline, blockID: "c", sourceID: sid, at: t1)
        XCTAssertEqual(EaselLivePolicy.backoff(failures: 2), 30 * 60)
        XCTAssertEqual(d.dueLiveBlocks(now: t1.addingTimeInterval(29 * 60)), [])
        XCTAssertEqual(d.dueLiveBlocks(now: t1.addingTimeInterval(30 * 60)), ["c"])
        XCTAssertEqual(EaselLivePolicy.backoff(failures: 40), EaselLivePolicy.maximumBackoff)
        // A gone profile waits for a person.
        d.applyLive(.unavailable, blockID: "c", sourceID: sid, at: t1)
        XCTAssertEqual(d.dueLiveBlocks(now: t1.addingTimeInterval(86400 * 9)), [])
        XCTAssertEqual(EaselLivePolicy.age(source(), now: t0.addingTimeInterval(5 * 60)), "Updated 5 min ago")
        XCTAssertEqual(EaselLivePolicy.age(source(), now: t0.addingTimeInterval(2 * 86400)), "Updated 2 days ago")
    }

    func testUndoAfterARefreshKeepsTheNewPicture() throws {
        var d = liveDoc()
        var h = EaselHistory()
        let sid = try XCTUnwrap(d.liveSource("c")?.id)
        // Move the capture (an undo step), then a refresh lands (no step).
        let before = d
        d.move(["c"], dx: 50, dy: 0)
        h.record("Move", from: before, to: d)
        let newAsset = String(repeating: "c", count: 64) + ".png"
        d.applyLive(.picture(asset: newAsset, pixelWidth: 640, pixelHeight: 400), blockID: "c", sourceID: sid, at: t0.addingTimeInterval(900))
        h.carryLive(of: d.block("c")!)
        // Undo the move: back where it was, with the new picture.
        XCTAssertNotNil(h.undo(&d))
        XCTAssertEqual(d.block("c")?.frame.x, 0)
        guard case .capture(let c)? = d.block("c")?.content else { return XCTFail() }
        XCTAssertEqual(c.asset, newAsset)
        XCTAssertEqual(c.live?.refreshedAt, t0.addingTimeInterval(900))
        // Redo too.
        XCTAssertNotNil(h.redo(&d))
        guard case .capture(let r)? = d.block("c")?.content else { return XCTFail() }
        XCTAssertEqual(r.asset, newAsset)
        XCTAssertEqual(d.block("c")?.frame.x, 50)
        // Detach is an undo step; undoing it brings the source back (and a carry never re-attaches a detached step).
        let live = d
        d.setLive(nil, for: "c")
        h.record("Detach", from: live, to: d)
        XCTAssertNil(d.liveSource("c"))
        h.undo(&d)
        XCTAssertEqual(d.liveSource("c")?.id, sid)
    }

    func testASourceThatArrivesLateIsPartOfTheAddStep() throws {
        var d = EaselDocument(id: "e1")
        var h = EaselHistory()
        let before = d
        let asset = String(repeating: "d", count: 64) + ".png"
        d.add(EaselBlock(id: "c", frame: EaselRect(x: 0, y: 0, width: 100, height: 50),
                         content: .capture(EaselCapture(asset: asset, pixelWidth: 200, pixelHeight: 100, url: "https://example.com/stats"))))
        h.record("Add Capture", from: before, to: d)
        let s = source()
        d.setLive(s, for: "c")
        h.attachLive(s, to: "c")
        h.undo(&d)
        XCTAssertNil(d.block("c"))
        h.redo(&d)
        XCTAssertEqual(d.liveSource("c")?.id, s.id, "redoing the Add brings the block back live")
    }

    // MARK: Rows

    func testADuplicatedEaselRowGetsAnEaselOfItsOwn() throws {
        let f = EaselFiles(root: root)
        EaselFiles.shared = f
        let s = try makeStore()
        let space = s.selectedSpace.id
        var d = liveDoc()
        d.id = "e1"
        try f.save(d)
        let asset = String(repeating: "a", count: 64) + ".png"
        try FileManager.default.createDirectory(at: f.assetsFolder("e1"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: f.assetURL("e1", asset)!)
        let t = try s.createEasel("e1", inSpace: space, pinned: false, title: "Board")
        let dup = try s.duplicateTab(t.id)
        let copyID = try XCTUnwrap(EaselURL.easelID(dup.url))
        XCTAssertNotEqual(copyID, "e1")
        let copy = f.load(copyID)
        XCTAssertEqual(copy.source, .document)
        XCTAssertEqual(copy.document.title, "Board")
        XCTAssertEqual(copy.document.blocks.map(\.id), d.blocks.map(\.id))
        XCTAssertEqual(try Data(contentsOf: f.assetURL(copyID, asset)!), Data([1, 2, 3]))
        // ⌥-drag and a pinned row's Duplicate: each its own too.
        let dragged = try s.copy(.tab(t.id), to: .today(spaceID: space, index: 0))
        try s.togglePin(t.id, inSpace: space)
        let item = try XCTUnwrap(s.tab(t.id)?.itemID)
        let dupItem = try s.duplicateItem(item)
        let ids = [copyID, EaselURL.easelID(s.tab(dragged)?.url), EaselURL.easelID(dupItem.savedURL)].compactMap { $0 }
        XCTAssertEqual(Set(ids).count, 3)
        XCTAssertFalse(ids.contains("e1"))
        // Editing the original leaves the copy alone.
        d.title = "Changed"
        try f.save(d)
        XCTAssertEqual(f.load(copyID).document.title, "Board")
        // Without the app's folder (or nothing on disk to copy) the address stays.
        EaselFiles.shared = nil
        XCTAssertEqual(EaselURL.easelID(try s.duplicateTab(t.id).url), "e1")
        EaselFiles.shared = f
        let ghost = try s.createEasel("e404", inSpace: space, pinned: false)
        XCTAssertEqual(EaselURL.easelID(try s.duplicateTab(ghost.id).url), "e404")
    }

    func testEaselsAreNeverSplitPanes() throws {
        let s = try makeStore()
        let space = s.selectedSpace.id
        let page = try s.openTab(url: "https://example.com", inSpace: space)
        let page2 = try s.openTab(url: "https://example.org", inSpace: space)
        let easel = try s.createEasel("e1", inSpace: space, pinned: false)
        let pinnedEasel = try s.createEasel("e2", inSpace: space)
        XCTAssertFalse(s.canBeSplitPane(easel.id))
        XCTAssertFalse(s.canBeSplitPane(pinnedEasel.id))
        XCTAssertTrue(s.canBeSplitPane(page.id))
        // New split, ⌥-click (createSplit), a drop onto a row either way, one more pane.
        XCTAssertThrowsError(try s.createSplit([page.id, easel.id], inSpace: space))
        XCTAssertThrowsError(try s.createSplit([pinnedEasel.id, page.id], inSpace: space))
        XCTAssertThrowsError(try s.move(.tab(easel.id), to: .split(spaceID: space, target: page.id, leading: false)))
        XCTAssertThrowsError(try s.move(.tab(page.id), to: .split(spaceID: space, target: easel.id, leading: true)))
        let x = try s.createSplit([page.id, page2.id], inSpace: space)
        XCTAssertThrowsError(try s.addToSplit(x.id, tabID: easel.id))
        XCTAssertThrowsError(try s.move(.tab(easel.id), to: .split(spaceID: space, target: x.id, leading: false)))
        XCTAssertEqual(s.split(x.id)?.tabIDs, [page.id, page2.id])
        // A selection's "Open in Split View" isn't offered with an Easel in it.
        let loose = try s.openTab(url: "https://example.edu", inSpace: space)
        let loose2 = try s.openTab(url: "https://example.info", inSpace: space)
        XCTAssertNotNil(s.splitCandidates([.tab(loose.id), .tab(loose2.id)]))
        XCTAssertNil(s.splitCandidates([.tab(loose.id), .tab(easel.id)]))
        XCTAssertThrowsError(try s.openInSplit([.tab(easel.id), .item(try XCTUnwrap(pinnedEasel.itemID))], inSpace: space))
        // A pinned split: no Easel pane either.
        let note = try s.createNote(inSpace: space, pinned: false)
        let y = try s.createSplit([note.id, page.id], inSpace: space)
        _ = try s.move(.split(y.id), to: .pinned(spaceID: space, parentID: nil, index: 0))
        let splitItem = try XCTUnwrap(s.state.items.values.first { $0.kind == .split })
        XCTAssertThrowsError(try s.addToSplit(splitItem.id, tabID: easel.id))
        // Notes still split (P13b).
        let note2 = try s.createNote(inSpace: space, pinned: false)
        let page3 = try s.openTab(url: "https://example.net", inSpace: space)
        XCTAssertNoThrow(try s.createSplit([note2.id, page3.id], inSpace: space))
    }
}
