// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
@testable import AircKit
import XCTest

/// P19a: the Easel document (N07): every block kind round-trips, unknown kinds and keys survive, groups, z-order,
/// geometry, snapping, and undo/redo as diffs.
final class EaselDocumentTests: XCTestCase {
    func sample() -> EaselDocument {
        var d = EaselDocument(title: "Trip")
        let rich = NoteDocument(blocks: [NoteBlock(kind: .heading1, runs: [NoteRun("Lisbon")]),
                                         NoteBlock(kind: .paragraph, runs: [NoteRun("tram ", marks: [.bold]), NoteRun("28", link: "https://example.com/28")])])
        d.add(EaselBlock(frame: EaselRect(x: 10, y: 20, width: 300, height: 80), content: .text(EaselText(rich, font: .fancy, size: 21, color: .darkBlue, alignment: .center))))
        d.add(EaselBlock(frame: EaselRect(x: -400, y: -200, width: 200, height: 150), rotation: 0.3,
                         content: .image(EaselImage(asset: String(repeating: "a", count: 64) + ".png", pixelWidth: 400, pixelHeight: 300, source: "https://example.com/a.png"))))
        d.add(EaselBlock(frame: EaselRect(x: 0, y: 300, width: 120, height: 120), content: .shape(EaselShape(.rectangle, fill: .yellow, stroke: .black, cornerRadius: 8))))
        d.add(EaselBlock(frame: EaselRect(x: 200, y: 300, width: 90, height: 60), content: .shape(EaselShape(.ellipse))))
        d.add(EaselBlock(frame: .init(x: 0, y: 0, width: 0, height: 0), content: .line(EaselLine(from: EaselPoint(50, 500), to: EaselPoint(250, 450), startHead: true))))
        d.add(EaselBlock(frame: EaselRect(x: 400, y: 0, width: 320, height: 96), content: .link(EaselLink(url: "https://www.example.com/x", title: "Example", detail: "A page"))))
        d.add(EaselBlock(frame: EaselRect(x: 400, y: 200, width: 300, height: 200),
                         content: .capture(EaselCapture(asset: String(repeating: "b", count: 64) + ".png", pixelWidth: 600, pixelHeight: 400, url: "https://example.com/", title: "Example", capturedAt: Date(timeIntervalSince1970: 1_800_000_000)))))
        d.viewport = EaselViewport(centerX: 100, centerY: 200, zoom: 1.5)
        return d
    }

    func testEveryBlockKindRoundTrips() throws {
        let d = sample()
        let data = try EaselFiles.encode(d)
        let back = try EaselFiles.decoder().decode(EaselDocument.self, from: data)
        XCTAssertEqual(back, d)
        XCTAssertEqual(Set(back.blocks.map(\.content.type)), ["text", "image", "shape", "line", "link", "capture"])
        XCTAssertEqual(back.assets.count, 2)
        XCTAssertEqual(back.plainText, "Lisbon\ntram 28")
        // A line's frame is the box its ends span, and it never rotates.
        let line = try XCTUnwrap(back.blocks.first { $0.content.isLine })
        XCTAssertEqual(line.frame, EaselRect(x: 50, y: 450, width: 200, height: 50))
        XCTAssertEqual(line.rotation, 0)
    }

    func testUnknownKindsAndKeysSurviveAnOlderBuild() throws {
        let json = #"""
        {"formatVersion": 4, "id": "e1", "title": "From the future", "palette": "vibrant", "hologram": {"fps": 60},
         "blocks": [{"id": "a", "frame": {"x": 0, "y": 0, "width": 10, "height": 10}, "z": 1,
                     "content": {"type": "sticker", "emoji": "🐙", "spin": [1, 2]}},
                    {"id": "b", "frame": {"x": 5, "y": 5, "width": 10, "height": 10}, "z": 2, "content": {"type": "shape", "kind": "ellipse"}}]}
        """#
        var d = try EaselFiles.decoder().decode(EaselDocument.self, from: Data(json.utf8))
        XCTAssertEqual(d.blocks.count, 2)
        guard case .unknown(let type, let fields) = d.block("a")?.content else { return XCTFail("unknown kind lost") }
        XCTAssertEqual(type, "sticker")
        XCTAssertEqual(fields["emoji"], .string("🐙"))
        d.move(["a"], dx: 10, dy: 0)
        let again = try EaselFiles.decoder().decode(EaselDocument.self, from: EaselFiles.encode(d))
        XCTAssertEqual(again.formatVersion, 4)
        XCTAssertEqual(again.extra["hologram"], .object(["fps": .number(60)]))
        XCTAssertEqual(again.block("a")?.content, d.block("a")?.content)
        XCTAssertEqual(again.block("a")?.frame.x, 10)
    }

    func testDuplicateIDsInAFileAreMadeUnique() throws {
        let json = #"{"id": "e", "blocks": [{"id": "x", "frame": {"x": 0, "y": 0, "width": 1, "height": 1}, "content": {"type": "shape"}}, {"id": "x", "frame": {"x": 2, "y": 0, "width": 1, "height": 1}, "content": {"type": "shape"}}]}"#
        let d = try EaselFiles.decoder().decode(EaselDocument.self, from: Data(json.utf8))
        XCTAssertEqual(Set(d.blocks.map(\.id)).count, 2)
    }

    func testZOrderAndGroups() {
        var d = EaselDocument()
        for i in 0..<4 { d.add(EaselBlock(id: "b\(i)", frame: EaselRect(x: Double(i) * 10, y: 0, width: 50, height: 50), content: .shape(EaselShape(.rectangle)))) }
        XCTAssertEqual(d.stacked.map(\.id), ["b0", "b1", "b2", "b3"])
        d.bringToFront(["b0"])
        XCTAssertEqual(d.stacked.map(\.id), ["b1", "b2", "b3", "b0"])
        d.sendToBack(["b3"])
        XCTAssertEqual(d.stacked.map(\.id), ["b3", "b1", "b2", "b0"])
        d.bringForward(["b1"])
        XCTAssertEqual(d.stacked.map(\.id), ["b3", "b2", "b1", "b0"])
        d.sendBackward(["b0"])
        XCTAssertEqual(d.stacked.map(\.id), ["b3", "b2", "b0", "b1"])

        let g = d.group(["b0", "b1"])
        XCTAssertNotNil(g)
        XCTAssertEqual(d.expandingGroups(["b0"]), ["b0", "b1"])
        // Grouping a group with another block merges them.
        let g2 = d.group(["b1", "b2"])
        XCTAssertEqual(d.expandingGroups(["b2"]), ["b0", "b1", "b2"])
        XCTAssertNotEqual(g, g2)
        XCTAssertNil(d.group(["b3"]))
        // Copies of a group are a new group of their own.
        let made = d.duplicate(["b0", "b1", "b2"])
        XCTAssertEqual(made.count, 3)
        let copyGroups = Set(made.compactMap { d.block($0)?.group })
        XCTAssertEqual(copyGroups.count, 1)
        XCTAssertNotEqual(copyGroups.first, g2)
        XCTAssertEqual(Set(made.compactMap { d.block($0)?.frame.x }), Set(["b0", "b1", "b2"].compactMap { d.block($0).map { $0.frame.x + EaselMetrics.copyOffset } }))
        d.ungroup(["b0"])
        XCTAssertNil(d.block("b2")?.group)
        XCTAssertEqual(d.expandingGroups(["b0"]), ["b0"])
    }

    func testMoveResizeRotateAndHit() throws {
        var d = EaselDocument()
        d.add(EaselBlock(id: "r", frame: EaselRect(x: 0, y: 0, width: 100, height: 50), content: .shape(EaselShape(.rectangle))))
        d.add(EaselBlock(id: "l", frame: EaselRect(x: 0, y: 0, width: 0, height: 0), content: .line(EaselLine(from: EaselPoint(0, 100), to: EaselPoint(100, 200)))))
        d.move(["r", "l"], dx: 10, dy: -5)
        XCTAssertEqual(d.block("r")?.frame, EaselRect(x: 10, y: -5, width: 100, height: 50))
        XCTAssertEqual(d.block("l")?.line?.from, EaselPoint(10, 95))
        let box = try XCTUnwrap(d.contentBounds)
        XCTAssertEqual(box, EaselRect(x: 10, y: -5, width: 100, height: 200))
        d.resize(["r", "l"], from: box, to: EaselRect(x: 10, y: -5, width: 200, height: 400))
        XCTAssertEqual(d.block("r")?.frame, EaselRect(x: 10, y: -5, width: 200, height: 100))
        XCTAssertEqual(d.block("l")?.line?.to, EaselPoint(210, 395))
        XCTAssertTrue(d.block("l")!.hit(EaselPoint(110, 295)))
        XCTAssertFalse(d.block("l")!.hit(EaselPoint(180, 100)))
        // A quarter turn about its own centre: its frame stays, its bounds turn.
        let c = d.block("r")!.frame.center
        d.rotate(["r"], by: .pi / 2, about: c)
        XCTAssertEqual(d.block("r")!.rotation, .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(d.block("r")!.bounds.width, 100, accuracy: 1e-6)
        XCTAssertEqual(d.block("r")!.bounds.height, 200, accuracy: 1e-6)
        XCTAssertTrue(d.block("r")!.hit(EaselPoint(c.x, c.y + 90)))
        XCTAssertFalse(d.block("r")!.hit(EaselPoint(c.x + 90, c.y)))
        XCTAssertEqual(d.hit(EaselPoint(c.x, c.y))?.id, "r")
        XCTAssertEqual(d.blocks(in: EaselRect(x: 100, y: 300, width: 20, height: 20)).map(\.id), ["l"])
    }

    func testSnappingToEdgesAndCentresWithGuides() {
        let other = EaselRect(x: 100, y: 100, width: 100, height: 100)
        // Left edge 4 pt from the other's right edge, middle 3 pt off its middle.
        let r = EaselSnapping.snap(EaselRect(x: 204, y: 103, width: 50, height: 100), to: [other], distance: 6)
        XCTAssertEqual(r.dx, -4)
        XCTAssertEqual(r.dy, -3)
        XCTAssertEqual(Set(r.guides.map(\.axis)), [.vertical, .horizontal])
        XCTAssertEqual(r.guides.first { $0.axis == .vertical }?.at, 200)
        // Centre to centre.
        let c = EaselSnapping.snap(EaselRect(x: 127, y: 400, width: 50, height: 10), to: [other], distance: 6)
        XCTAssertEqual(c.dx, -2)   // its centre 152 → 150
        XCTAssertEqual(c.dy, 0)
        // Too far: nothing.
        XCTAssertEqual(EaselSnapping.snap(EaselRect(x: 300, y: 300, width: 10, height: 10), to: [other], distance: 6).guides, [])
        // A dragged right edge snaps to the other's left.
        let e = EaselSnapping.snapEdges(EaselRect(x: 0, y: 0, width: 96, height: 30), left: false, right: true, top: false, bottom: false, to: [other], distance: 6)
        XCTAssertEqual(e.box.maxX, 100)
        XCTAssertEqual(e.guides.count, 1)
    }

    func testUndoAndRedoAreDiffs() {
        var d = sample()
        var h = EaselHistory()
        let start = d
        var before = d
        d.move([d.blocks[0].id], dx: 30, dy: 0)
        XCTAssertTrue(h.record("Move", from: before, to: d))
        let moved = d
        before = d
        let doomed = Set(d.blocks.prefix(2).map(\.id))
        d.remove(doomed)
        h.record("Delete", from: before, to: d)
        before = d
        d.title = "Renamed"
        d.palette = .vibrant
        h.record("Rename", from: before, to: d)
        XCTAssertFalse(h.record("Nothing", from: d, to: d))
        XCTAssertEqual(h.undoStack.map(\.name), ["Move", "Delete", "Rename"])
        // Each step keeps only what changed.
        XCTAssertEqual(h.undoStack[0].changes.count, 1)
        XCTAssertEqual(h.undoStack[1].changes.count, 2)

        let end = d
        XCTAssertEqual(h.undo(&d)?.name, "Rename")
        XCTAssertEqual(d.title, "Trip")
        XCTAssertEqual(h.undo(&d)?.touched(forward: false), doomed)
        XCTAssertEqual(Set(d.blocks.map(\.id)), Set(moved.blocks.map(\.id)))
        h.undo(&d)
        XCTAssertEqual(d.blocks.sorted { $0.id < $1.id }, start.blocks.sorted { $0.id < $1.id })
        XCTAssertNil(h.undo(&d))
        h.redo(&d); h.redo(&d); h.redo(&d)
        XCTAssertEqual(d.blocks.sorted { $0.id < $1.id }, end.blocks.sorted { $0.id < $1.id })
        XCTAssertEqual(d.title, "Renamed")
        // A new change after an undo drops the redo stack.
        h.undo(&d)
        before = d
        d.move([d.blocks[0].id], dx: 1, dy: 1)
        h.record("Nudge", from: before, to: d)
        XCTAssertFalse(h.canRedo)
    }

    func testHistoryIsCappedAndCodable() throws {
        var d = EaselDocument()
        d.add(EaselBlock(id: "x", frame: EaselRect(x: 0, y: 0, width: 10, height: 10), content: .shape(EaselShape(.rectangle))))
        var h = EaselHistory()
        for _ in 0..<(EaselHistory.limit + 20) {
            let b = d
            d.move(["x"], dx: 1, dy: 0)
            h.record("Nudge", from: b, to: d)
        }
        XCTAssertEqual(h.undoStack.count, EaselHistory.limit)
        h.revision = "r1"
        let back = try EaselFiles.decoder().decode(EaselHistory.self, from: EaselFiles.encoder().encode(h))
        XCTAssertEqual(back, h)
    }
}
