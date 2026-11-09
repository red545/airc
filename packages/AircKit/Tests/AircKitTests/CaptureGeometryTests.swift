// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import CoreGraphics
import XCTest

final class CaptureGeometryTests: XCTestCase {
    typealias G = CaptureGeometry
    /// One page filling an 800 × 600 pt card, pictured at `scale`.
    func page(_ scale: CGFloat, frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600)) -> G.Page {
        G.Page(frame: frame, pixelSize: CGSize(width: frame.width * scale, height: frame.height * scale))
    }

    func testBackingScaleSetsTheOutputPixels() {
        let sel = CGRect(x: 100, y: 50, width: 200, height: 100)
        for scale: CGFloat in [1, 2, 3] {
            let plan = G.plan(selection: sel, pages: [page(scale)], scale: scale)
            XCTAssertEqual(plan?.pixelSize, CGSize(width: 200 * scale, height: 100 * scale), "\(scale)×")
            XCTAssertEqual(plan?.pieces, [G.Piece(page: 0, source: CGRect(x: 100 * scale, y: 50 * scale, width: 200 * scale, height: 100 * scale),
                                                  destination: CGRect(x: 0, y: 0, width: 200 * scale, height: 100 * scale))])
        }
    }

    func testAPictureAtAnotherScaleIsResampledToTheScreens() {
        // A 1× picture of a page on a 2× screen: read from 1× pixels, written at 2×.
        let plan = G.plan(selection: CGRect(x: 10, y: 20, width: 30, height: 40), pages: [page(1)], scale: 2)
        XCTAssertEqual(plan?.pixelSize, CGSize(width: 60, height: 80))
        XCTAssertEqual(plan?.pieces.first?.source, CGRect(x: 10, y: 20, width: 30, height: 40))
        XCTAssertEqual(plan?.pieces.first?.destination, CGRect(x: 0, y: 0, width: 60, height: 80))
    }

    func testPageOffsetInsideTheCardAndGapsBetweenPanes() {
        // Two split panes with the 6 pt margin between them; the selection crosses the gap.
        let left = page(2, frame: CGRect(x: 0, y: 0, width: 397, height: 600))
        let right = page(2, frame: CGRect(x: 403, y: 0, width: 397, height: 600))
        let sel = CGRect(x: 300, y: 100, width: 200, height: 50)
        let plan = G.plan(selection: sel, pages: [left, right], scale: 2)
        XCTAssertEqual(plan?.pixelSize, CGSize(width: 400, height: 100))
        XCTAssertEqual(plan?.pieces, [
            G.Piece(page: 0, source: CGRect(x: 600, y: 200, width: 194, height: 100), destination: CGRect(x: 0, y: 0, width: 194, height: 100)),
            G.Piece(page: 1, source: CGRect(x: 0, y: 200, width: 194, height: 100), destination: CGRect(x: 206, y: 0, width: 194, height: 100)),
        ])
    }

    func testTheSidebarSideDoesntMoveTheCrop() {
        // The overlay is the card's own space: the card at x 250 (sidebar on the left) or x 10 (on the right) gives the
        // same pixels for the same place on the page, and the whole page never reaches past the card into the sidebar.
        let card = CGRect(x: 0, y: 0, width: 800, height: 600)
        for cardInWindow in [CGRect(x: 250, y: 10, width: 800, height: 600), CGRect(x: 10, y: 10, width: 800, height: 600)] {
            let windowSel = CGRect(x: cardInWindow.minX + 40, y: cardInWindow.minY + 30, width: 120, height: 90)
            let sel = windowSel.offsetBy(dx: -cardInWindow.minX, dy: -cardInWindow.minY)
            XCTAssertEqual(G.plan(selection: sel, pages: [page(2)], scale: 2)?.pieces.first?.source, CGRect(x: 80, y: 60, width: 240, height: 180))
            let full = G.fullPage([page(2)], in: card)
            XCTAssertEqual(full, card)
            XCTAssertEqual(G.plan(selection: full!, pages: [page(2)], scale: 2)?.pixelSize, CGSize(width: 1600, height: 1200))
        }
        // A selection dragged out over where the sidebar is stops at the card's edge.
        XCTAssertEqual(G.clamp(CGRect(x: -120, y: 10, width: 200, height: 50), to: card), CGRect(x: 0, y: 10, width: 80, height: 50))
        XCTAssertEqual(G.clamp(CGRect(x: 700, y: 10, width: 300, height: 50), to: card), CGRect(x: 700, y: 10, width: 100, height: 50))
    }

    func testPageZoomOnlyMovesElementBoxes() {
        // ⌘+ at 150 %: the picture is still device pixels (the crop is unchanged), CSS boxes grow by the zoom.
        let p = CGRect(x: 0, y: 0, width: 800, height: 600)
        let sel = CGRect(x: 30, y: 45, width: 150, height: 75)
        XCTAssertEqual(G.plan(selection: sel, pages: [page(2)], scale: 2)?.pieces.first?.source, CGRect(x: 60, y: 90, width: 300, height: 150))
        XCTAssertEqual(G.elementRect(css: CGRect(x: 20, y: 30, width: 100, height: 50), in: p, zoom: 1.5, bounds: p), sel)
        XCTAssertEqual(G.cssPoint(CGPoint(x: 30, y: 45), in: p, zoom: 1.5), CGPoint(x: 20, y: 30))
        // In a pane further right, and an element half off screen is cut to the page.
        let pane = CGRect(x: 403, y: 0, width: 397, height: 600)
        XCTAssertEqual(G.elementRect(css: CGRect(x: -50, y: 10, width: 100, height: 20), in: pane, zoom: 1, bounds: p),
                       CGRect(x: 403, y: 10, width: 50, height: 20))
        XCTAssertNil(G.elementRect(css: CGRect(x: 900, y: 10, width: 100, height: 20), in: pane, zoom: 1, bounds: p))
    }

    func testNoPlanForNothing() {
        XCTAssertNil(G.plan(selection: .zero, pages: [page(2)], scale: 2))
        XCTAssertNil(G.plan(selection: CGRect(x: 10, y: 10, width: 50, height: 50), pages: [], scale: 2))
        XCTAssertNil(G.plan(selection: CGRect(x: 10, y: 10, width: 50, height: 50), pages: [page(2)], scale: 0))
        // The selection in a gap between panes covers no page.
        XCTAssertNil(G.plan(selection: CGRect(x: 398, y: 10, width: 4, height: 50),
                            pages: [page(2, frame: CGRect(x: 0, y: 0, width: 397, height: 600)),
                                    page(2, frame: CGRect(x: 403, y: 0, width: 397, height: 600))], scale: 2))
    }

    func testResizeMoveAndHandles() {
        let b = CGRect(x: 0, y: 0, width: 800, height: 600)
        let r = CGRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertEqual(G.handle(at: CGPoint(x: 301, y: 99), on: r), .topRight)
        XCTAssertEqual(G.handle(at: CGPoint(x: 200, y: 203), on: r), .bottom)
        XCTAssertNil(G.handle(at: CGPoint(x: 200, y: 150), on: r))
        XCTAssertEqual(G.resize(r, handle: .bottomRight, to: CGPoint(x: 350.4, y: 260), in: b), CGRect(x: 100, y: 100, width: 250, height: 160))
        // Past the opposite side it flips.
        XCTAssertEqual(G.resize(r, handle: .left, to: CGPoint(x: 340, y: 0), in: b), CGRect(x: 300, y: 100, width: 40, height: 100))
        XCTAssertEqual(G.resize(r, handle: .topLeft, to: CGPoint(x: -20, y: -20), in: b), CGRect(x: 0, y: 0, width: 300, height: 200))
        XCTAssertEqual(G.move(r, by: CGVector(dx: 650, dy: -10), in: b), CGRect(x: 600, y: 90, width: 200, height: 100))
        XCTAssertEqual(G.move(r, by: CGVector(dx: -500, dy: 900), in: b), CGRect(x: 0, y: 500, width: 200, height: 100))
    }

    func testFileName() {
        let date = Date(timeIntervalSince1970: 1_794_045_932)   // 2026-11-07 10:05:32 UTC
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(CaptureFileName.make(url: URL(string: "https://www.example.com/a"), date: date, timeZone: utc),
                       "Capture example.com 2026-11-07 at 10.05.32.png")
        XCTAssertEqual(CaptureFileName.make(url: URL(string: "http://127.0.0.1:8080/x"), date: date, timeZone: utc),
                       "Capture 127.0.0.1 2026-11-07 at 10.05.32.png")
        XCTAssertEqual(CaptureFileName.make(url: URL(string: "about:blank"), date: date, timeZone: utc), "Capture 2026-11-07 at 10.05.32.png")
        XCTAssertEqual(CaptureFileName.make(url: nil, date: date, timeZone: utc), "Capture 2026-11-07 at 10.05.32.png")
        var taken: Set<String> = ["Capture example.com 2026-11-07 at 10.05.32.png", "Capture example.com 2026-11-07 at 10.05.32 2.png"]
        XCTAssertEqual(CaptureFileName.make(url: URL(string: "https://example.com"), date: date, timeZone: utc, exists: { taken.contains($0) }),
                       "Capture example.com 2026-11-07 at 10.05.32 3.png")
        taken = []
        XCTAssertEqual(CaptureFileName.site(of: URL(string: "https://EXAMPLE.org")), "example.org")
    }
}
