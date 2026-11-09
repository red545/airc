// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// Part of `--script capture` (P08a, docs/user/capture.md), on loopback pages:
///   - Capture Full Page of a long page (30 bands of 160 px in 30 colours, a fixed header and footer, a sticky bar):
///     every band once, in order, at its height × zoom × pixels per point; the fixed and sticky parts once; nothing of
///     the window around the page; at 2× in several tiles, at 150 % page zoom, and at 1×; Copy's PNG at that size and
///     resolution; the bar's Full Page, F and View › Capture Full Page;
///   - a page too long for one picture: taken at fewer pixels per point and cut at the limit, which the overlay says;
///   - Esc while a full page is being taken: nothing copied, nothing left; Save into a folder that isn't there: it says
///     so and the Capture stays;
///   - a split of two pages, a split with a note, a Peek: each part of the card as shown; a region at 150 % zoom.
extension SnapshotRunner {
    func captureParityChecks(board: NSPasteboard, scratch: URL, usedCount: @escaping () -> Int) {
        var server: LocalPageServer?
        var base = ""
        var longTab = "", veryLongTab = "", leftTab = "", rightTab = ""
        let active = { CaptureSession.active(in: self.c.window) }
        // Colours 70 apart (an RGB grid), each at least 80 from the fixed header (black), footer (magenta), sticky bar
        // (cyan) and white; neighbours far apart.
        let bands: [UInt32] = [0x641EAA, 0x64641E, 0xAAF0F0, 0xAAAA1E, 0xF01EAA, 0xF01E1E, 0x64F01E, 0x1EAAAA, 0xAA6464, 0xAAAAF0,
                               0xAA1E64, 0x64F0F0, 0xAA64AA, 0x1E1EAA, 0xF0AA64, 0x1EF0AA, 0x641E1E, 0x1EAAF0, 0x641EF0, 0x64F064,
                               0x646464, 0xAA1EF0, 0xAA1E1E, 0x64AAF0, 0x1E1EF0, 0x641E64, 0x1E64F0, 0xF0641E, 0xAAAAAA, 0x6464F0]
        let bandCSS = 160.0, headCSS = 40.0, footCSS = 24.0, stickyCSS = 30.0
        let pageCSS = bandCSS * Double(bands.count) + stickyCSS
        let hex = { (c: UInt32) in String(format: "#%06X", c) }
        var long = "<title>Long</title><style>html,body{margin:0}.b{height:\(Int(bandCSS))px}"
            + "#head{position:fixed;top:0;left:0;right:0;height:\(Int(headCSS))px;background:#000}"
            + "#foot{position:fixed;bottom:0;left:0;right:0;height:\(Int(footCSS))px;background:#F0F}"
            + "#stick{position:sticky;top:\(Int(headCSS))px;height:\(Int(stickyCSS))px;background:#0FF}</style><div id=head></div>"
        for (i, c) in bands.enumerated() {
            long += "<div class=b style=\"background:\(hex(c))\"></div>"
            if i == 2 { long += "<div id=stick></div>" }
        }
        long += "<div id=foot></div>"
        let veryLong = "<title>Very long</title><style>html,body{margin:0}.r{height:400px;background:#e53935}.b{height:400px;background:#1e88e5}</style>"
            + String(repeating: "<div class=r></div><div class=b></div>", count: 250)
        let left = "<title>Left</title><style>html,body{margin:0;height:100%;background:#e53935}</style>"
        let right = "<title>Right</title><style>html,body{margin:0;height:100%;background:#1e88e5}</style>"

        typealias RGB = (r: Int, g: Int, b: Int)
        func rgb(_ c: UInt32) -> RGB { (Int(c >> 16 & 0xFF), Int(c >> 8 & 0xFF), Int(c & 0xFF)) }
        func decode(_ image: CGImage?) -> (w: Int, h: Int, px: [UInt8])? {
            guard let img = image else { return nil }
            let w = img.width, h = img.height
            var px = [UInt8](repeating: 0, count: w * h * 4)
            guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return (w, h, px)
        }
        func decodePNG(_ data: Data?) -> (w: Int, h: Int, px: [UInt8])? {
            guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return decode(CGImageSourceCreateImageAtIndex(src, 0, nil))
        }
        func pixel(_ d: (w: Int, h: Int, px: [UInt8]), _ x: Int, _ y: Int) -> (RGB, Int) {
            let i = (min(d.h - 1, max(0, y)) * d.w + min(d.w - 1, max(0, x))) * 4
            return ((Int(d.px[i]), Int(d.px[i + 1]), Int(d.px[i + 2])), Int(d.px[i + 3]))
        }
        func dist(_ a: RGB, _ b: RGB) -> Int { abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) }
        /// The labelled runs down the column at `fx` of the picture: "head", "foot", "sticky", "b0"…"b29", "?" (blends).
        func runs(_ d: (w: Int, h: Int, px: [UInt8]), fx: Double = 0.5) -> [(label: String, rows: Int)] {
            var known: [(String, RGB)] = [("head", (0, 0, 0)), ("foot", (255, 0, 255)), ("sticky", (0, 255, 255)), ("white", (255, 255, 255))]
            known += bands.enumerated().map { ("b\($0.offset)", rgb($0.element)) }
            var out: [(label: String, rows: Int)] = []
            let x = Int(Double(d.w) * fx)
            for y in 0..<d.h {
                let c = pixel(d, x, y).0
                let best = known.min { dist($0.1, c) < dist($1.1, c) }!
                let label = dist(best.1, c) <= 60 ? best.0 : "?"
                if out.last?.label == label { out[out.count - 1].rows += 1 } else { out.append((label, 1)) }
            }
            // A blend row between two parts isn't a part.
            return out.filter { !($0.label == "?" && $0.rows <= 2) }.reduce(into: []) { acc, r in
                if acc.last?.label == r.label { acc[acc.count - 1].rows += r.rows } else { acc.append(r) }
            }
        }
        /// The 12 CSS px just above the fixed footer are the page's own, row for row (the footer covers nothing there).
        func aboveFooter(_ d: (w: Int, h: Int, px: [UInt8]), scale: Double, footTop: Double) -> (ok: Bool, why: String) {
            var known: [(String, RGB)] = [("head", (0, 0, 0)), ("foot", (255, 0, 255)), ("sticky", (0, 255, 255))]
            known += bands.enumerated().map { ("b\($0.offset)", rgb($0.element)) }
            func underneath(_ y: Double) -> String {
                if y < 3 * bandCSS { return "b\(Int(y / bandCSS))" }
                if y < 3 * bandCSS + stickyCSS { return "sticky" }
                return "b\(min(bands.count - 1, 3 + Int((y - 3 * bandCSS - stickyCSS) / bandCSS)))"
            }
            var edges = [footTop, 3 * bandCSS, 3 * bandCSS + stickyCSS]
            edges += (1..<bands.count).map { i in Double(i) * bandCSS + (i >= 3 ? stickyCSS : 0) }
            var rows = 0, wrong: [String] = []
            for fx in [0.02, 0.5, 0.98] {
                let x = Int(Double(d.w) * fx)
                for row in Int(((footTop - 12) * scale).rounded())..<Int((footTop * scale).rounded()) where row >= 0 && row < d.h {
                    let y = (Double(row) + 0.5) / scale
                    if edges.contains(where: { abs($0 - y) * scale <= 2 }) { continue }
                    let c = pixel(d, x, row).0
                    let best = known.min { dist($0.1, c) < dist($1.1, c) }!
                    let got = dist(best.1, c) <= 60 ? best.0 : "?"
                    rows += 1
                    if got != underneath(y), wrong.count < 4 { wrong.append("row \(row) at \(Int(fx * 100)) %: \(got), not \(underneath(y))") }
                }
            }
            return (wrong.isEmpty && rows > 0, "\(rows) rows checked" + (wrong.isEmpty ? "" : ": " + wrong.joined(separator: "; ")))
        }
        func summary(_ r: [(label: String, rows: Int)]) -> String { r.map { "\($0.label) \($0.rows)" }.joined(separator: ", ") }
        /// What each row should be: the bands and the sticky bar where they are in the page, the fixed header over the
        /// top and the fixed footer over `footTop` (CSS pixels; Chromium paints it where the window's foot is, WebKit at
        /// the page's foot). Rows within 2 px of an edge between parts aren't judged (they blend). Every band once and
        /// in order follows from every row matching.
        func judge(_ d: (w: Int, h: Int, px: [UInt8]), fx: Double, scale: Double, footTop: Double, footSlack: Double = 0) -> (ok: Bool, why: String) {
            var known: [(String, RGB)] = [("head", (0, 0, 0)), ("foot", (255, 0, 255)), ("sticky", (0, 255, 255))]
            known += bands.enumerated().map { ("b\($0.offset)", rgb($0.element)) }
            func underneath(_ y: Double) -> String {
                if y < 3 * bandCSS { return "b\(Int(y / bandCSS))" }
                if y < 3 * bandCSS + stickyCSS { return "sticky" }
                return "b\(min(bands.count - 1, 3 + Int((y - 3 * bandCSS - stickyCSS) / bandCSS)))"
            }
            func expected(_ y: Double) -> String {
                if y < headCSS { return "head" }
                if y >= footTop, y < footTop + footCSS { return "foot" }
                return underneath(y)
            }
            var footRows = 0
            var edges = [headCSS, footTop, footTop + footCSS, 3 * bandCSS, 3 * bandCSS + stickyCSS]
            edges += (1..<bands.count).map { i in Double(i) * bandCSS + (i >= 3 ? stickyCSS : 0) }
            let x = Int(Double(d.w) * fx)
            var wrong: [String] = []
            for row in 0..<d.h {
                let y = (Double(row) + 0.5) / scale
                if edges.contains(where: { abs($0 - y) * scale <= 2 }) { continue }
                let c = pixel(d, x, row).0
                let best = known.min { dist($0.1, c) < dist($1.1, c) }!
                let got = dist(best.1, c) <= 60 ? best.0 : "?"
                if got == "foot" { footRows += 1 }
                // Where WebKit's parts draw the footer short of the part's foot: below its top, it or the page under it
                // (never above its top: the page there must be row-exact, see `aboveFooter`).
                if footSlack > 0, y >= footTop, y < footTop + footCSS + footSlack, got == "foot" || got == underneath(y) { continue }
                if got != expected(y), wrong.count < 6 { wrong.append("row \(row): \(got), not \(expected(y))") }
                else if got != expected(y) { wrong.append("…") ; break }
            }
            if footSlack > 0, footRows == 0 || Double(footRows) > (footCSS + footSlack) * scale { wrong.append("the footer \(footRows) rows") }
            return (wrong.isEmpty, wrong.joined(separator: "; "))
        }
        func fullPage(_ name: String, tab: @escaping () -> String, zoomSteps: Int = 0, scale: CGFloat? = nil, start: @escaping () -> Void) {
            run { [self] in
                CaptureSession.scaleOverride = scale
                if let p = c.engineTab(for: tab()) { for _ in 0..<zoomSteps { p.zoom(step: 1) } }
            }
            wait(zoomSteps > 0 ? 0.8 : 0.1)
            run { start() }
            step { [self] done in waitUntil({ active()?.picturesReady == true }, timeout: 8) { done() } }
            run { [self] in
                guard let s = active() else { return }
                if s.phase == .selecting { s.captureFullPage() }
                if s.phase == .capturing {
                    check(s.overlay.bar.mode == .capturing
                          && s.overlay.subviews.contains { ($0 as? CapturePill)?.text == CaptureOverlayView.progressText && !$0.isHidden },
                          "capture full page (\(name)): \"Capture in Progress\" while it's taken")
                } else {
                    note("capture full page (\(name)): done before the progress could be looked at")
                }
            }
            step { [self] done in waitUntil({ active()?.phase != .capturing }, timeout: 45) { done() } }
            run { [self] in
                guard let s = active(), let picture = s.fullPagePicture, let page = c.engineTab(for: tab()) else {
                    let diag = FullPageCapture.lastDiagnostics.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", ")
                    return check(false, "capture full page (\(name)): a picture (session \(active() != nil), phase \(String(describing: active()?.phase)); \(diag))")
                }
                let zoom = page.zoomFactor
                let px = picture.scale
                let d = zoom * Double(px)
                let viewportPt = page.view.bounds.width
                let diag = FullPageCapture.lastDiagnostics.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", ")
                note("capture full page (\(name)): \(picture.image.width)×\(picture.image.height) px at \(px)×, zoom \(zoom); \(diag)")
                let wantH = (pageCSS * d).rounded()
                check(abs(Double(picture.image.height) - wantH) <= 2 && abs(CGFloat(picture.image.width) - viewportPt * px) <= 2 * px
                      && picture.pagePoints.height == (pageCSS * zoom).rounded() && !picture.truncated,
                      "capture full page (\(name)): the page's whole length, \(picture.image.width) × \(picture.image.height) px "
                      + "(want about \(Int(viewportPt * px)) × \(Int(wantH)): the page area only, no sidebar or toolbar)")
                if let img = decode(picture.image) {
                    // Chromium paints a fixed footer where the window's foot is (the page at its top), WebKit at the page's foot,
                    // or at the foot of its first part when it takes the page in parts.
                    let parts = (FullPageCapture.lastDiagnostics["pdfParts"] as? Int) ?? 1
                    let footTop = page is WebKitTab ? (parts > 1 ? Double(FullPageCapture.pdfChunk) / zoom : pageCSS) - footCSS
                        : Double(page.view.bounds.height) / zoom - footCSS
                    let slack = page is WebKitTab && parts > 1 ? 12.0 : 0
                    let verdict = judge(img, fx: 0.5, scale: d, footTop: footTop, footSlack: slack)
                    let edge = judge(img, fx: 0.02, scale: d, footTop: footTop, footSlack: slack)
                    let above = aboveFooter(img, scale: d, footTop: footTop)
                    check(above.ok, "capture full page (\(name)): the 12 px above the fixed footer are the page's own, row for row (\(above.why))")
                    check(verdict.ok && edge.ok, "capture full page (\(name)): every part once, in order, at its size (footer at \(Int(footTop)) px "
                          + (page is WebKitTab ? "on WebKit" : "on Chromium") + "): " + (verdict.ok && edge.ok ? summary(runs(img)) : verdict.why + " | left edge: " + edge.why + " — " + summary(runs(img))))
                }
                check(s.overlay.previewFrame.map { s.overlay.bounds.contains($0) && $0.height > 100 } == true && s.overlay.bar.mode == .confirmed
                      && !s.overlay.bar.copyButton.isHidden,
                      "capture full page (\(name)): shown scaled to fit (\(s.overlay.previewFrame.map(NSStringFromRect) ?? "none")), with Copy, Save and Share")
                let n = board.changeCount
                s.overlay.bar.copyButton.action?()
                let png = board.data(forType: .png)
                let copied = decodePNG(png)
                let pts = png.flatMap(NSImage.init(data:))?.size
                check(board.changeCount != n && copied?.w == picture.image.width && copied?.h == picture.image.height
                      && pts.map { abs($0.width - CGFloat(picture.image.width) / px) < 1 } == true,
                      "capture full page (\(name)): Copy puts it on the clipboard at \(copied.map { "\($0.w) × \($0.h)" } ?? "-") px, "
                      + "\(pts.map { "\(Int($0.width)) × \(Int($0.height))" } ?? "-") pt")
                check(active() == nil && c.toast.shownText == "Copied Capture", "capture full page (\(name)): Copy closes it")
            }
            run { [self] in
                CaptureSession.scaleOverride = nil
                if zoomSteps > 0 { c.engineTab(for: tab())?.zoom(step: 0) }
            }
            wait(zoomSteps > 0 ? 0.8 : 0.1)
        }
        func selectRegion(_ s: CaptureSession, _ size: CGSize) {
            let o = s.overlay
            let a = CGPoint(x: (o.bounds.midX - size.width / 2).rounded(), y: (o.bounds.midY - size.height / 2).rounded())
            o.pressed(at: a)
            o.dragged(to: CGPoint(x: a.x + size.width, y: a.y + size.height))
            o.released(at: CGPoint(x: a.x + size.width, y: a.y + size.height))
        }

        step { [self] done in
            server = LocalPageServer(responses: ["/long.html": .init(body: long), "/verylong.html": .init(body: veryLong),
                                                 "/left.html": .init(body: left), "/right.html": .init(body: right)])
            server?.start { port in
                base = port.map { "http://localhost:\($0)" } ?? ""
                done()
            }
        }
        run { [self] in
            guard !base.isEmpty else { return check(false, "capture parity: a loopback server") }
            longTab = (try? c.store.openTab(url: base + "/long.html", inSpace: c.currentSpaceID, title: "Long"))?.id ?? ""
            c.reloadAll(animated: false)
            c.show(longTab, focus: false)
        }
        step { [self] done in waitUntil({ self.c.engineTab(for: longTab).map { !$0.isLoading && $0.title == "Long" } == true }, timeout: 15) { done() } }
        wait(1.0)

        // The bar before a selection, and the menus.
        run { [self] in
            let item = NSApp.mainMenu?.item(withTitle: "View")?.submenu?.items.first { $0.title == "Capture Full Page" }
            check(item != nil && c.commandActions().contains { $0.title == "Capture Full Page" },
                  "capture full page: View › Capture Full Page and the Command Bar's Capture Full Page")
            c.startCapture()
        }
        step { [self] done in waitUntil({ active()?.picturesReady == true }, timeout: 8) { done() } }
        run { [self] in
            let o = active()?.overlay
            check(o?.bar.mode == .start && o?.bar.isHidden == false && o?.bar.fullPageButton.isHidden == false && o?.bar.visibleButton.isHidden == false,
                  "capture: before a selection, the bar offers Visible Page and Full Page")
            active()?.cancel()
        }
        // Several tiles (1 024 px each on Chromium, PDF parts of 1 000 pt on WebKit), started from the bar's Full Page.
        run {
            FullPageCapture.tileHeight = 1024
            FullPageCapture.pdfChunk = 1000
        }
        fullPage("2×, in parts", tab: { longTab }) { [self] in
            c.startCapture()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
                if let s = active(), s.picturesReady { s.overlay.bar.fullPageButton.action?() } else { active()?.captureFullPage() }
            }
        }
        run {
            FullPageCapture.tileHeight = 4096
            FullPageCapture.pdfChunk = 14_000
        }
        // 150 % page zoom, from View › Capture Full Page.
        fullPage("150 % zoom", tab: { longTab }, zoomSteps: 3) { [self] in
            let item = NSApp.mainMenu?.item(withTitle: "View")?.submenu?.items.first { $0.title == "Capture Full Page" }
            if let item = item as? CommandMenuItem { item.fire() } else { c.startCapture(fullPage: true) }
        }
        // 1× (a Retina display stands in for a plain one), with F.
        fullPage("1×", tab: { longTab }, scale: 1) { [self] in
            c.startCapture()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
                let f = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: c.window.windowNumber,
                                         context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)!
                _ = active()?.handleKey(f)
            }
        }

        // Scrolled half way down first: the same picture (the page as at its top), and the page back where it was.
        run { [self] in c.engineTab(for: longTab)?.evaluate("window.scrollTo(0, 1500); window.scrollY", completion: nil) }
        wait(0.6)
        fullPage("scrolled to 1500 px", tab: { longTab }) { [self] in c.startCapture(fullPage: true) }
        step { [self] done in
            c.engineTab(for: longTab)?.evaluate("window.scrollY") { [self] value in
                let y = (value as? NSNumber)?.doubleValue ?? -1
                check(abs(y - 1500) < 2, "capture full page: the page is scrolled back where it was (\(Int(y)) px)")
                c.engineTab(for: longTab)?.evaluate("window.scrollTo(0, 0)", completion: nil)
                done()
            }
        }

        // A region at 1× and at 150 % zoom: page zoom changes what's in it, not its pixels.
        for (zoom, scale) in [(0, CGFloat(1)), (3, CGFloat(2))] {
            run { [self] in
                CaptureSession.scaleOverride = scale == 1 ? 1 : nil
                if let p = c.engineTab(for: longTab) { for _ in 0..<zoom { p.zoom(step: 1) } }
            }
            wait(0.8)
            run { [self] in c.startCapture() }
            step { [self] done in waitUntil({ active()?.picturesReady == true }, timeout: 8) { done() } }
            run { [self] in
                guard let s = active() else { return check(false, "capture region (\(scale)×, zoom \(zoom)): Capture starts") }
                selectRegion(s, CGSize(width: 200, height: 120))
                s.confirm()
                let n = board.changeCount
                s.overlay.bar.copyButton.action?()
                let png = board.data(forType: .png), img = decodePNG(png)
                let pts = png.flatMap(NSImage.init(data:))?.size
                let px = scale == 1 ? 1 : c.window.backingScaleFactor
                let zoomFactor = c.engineTab(for: longTab)?.zoomFactor ?? 1
                check(board.changeCount != n && img?.w == Int(200 * px) && img?.h == Int(120 * px) && pts == CGSize(width: 200, height: 120),
                      "capture region at \(px)×, page zoom \(Int(zoomFactor * 100)) %: \(img.map { "\($0.w) × \($0.h)" } ?? "-") px, "
                      + "\(pts.map { "\(Int($0.width)) × \(Int($0.height))" } ?? "-") pt")
                CaptureSession.scaleOverride = nil
                if zoom > 0 { c.engineTab(for: longTab)?.zoom(step: 0) }
            }
            wait(0.6)
        }

        // Save into a folder that isn't there: it says so, and the Capture stays.
        run { [self] in
            CaptureSession.downloadsDirectory = { scratch.appendingPathComponent("not here/nor here", isDirectory: true) }
            c.startCapture()
        }
        step { [self] done in waitUntil({ active()?.picturesReady == true }, timeout: 8) { done() } }
        run { [self] in
            guard let s = active() else { return check(false, "capture save failure: Capture starts") }
            let counted = usedCount()
            s.toggleFullPage()
            s.confirm()
            s.save()
            check(active() === s && s.phase == .confirmed && c.toast.shownText == "Couldn't save the Capture" && usedCount() == counted,
                  "capture: Save into a missing folder says \"\(c.toast.shownText ?? "nothing")\", keeps the Capture and counts nothing")
            s.cancel()
            CaptureSession.downloadsDirectory = { scratch }
        }

        // A page too long for one picture.
        run { [self] in
            veryLongTab = (try? c.store.openTab(url: base + "/verylong.html", inSpace: c.currentSpaceID, title: "Very long"))?.id ?? ""
            c.show(veryLongTab, focus: false)
        }
        step { [self] done in waitUntil({ self.c.engineTab(for: veryLongTab).map { !$0.isLoading && $0.title == "Very long" } == true }, timeout: 15) { done() } }
        wait(0.8)
        var startedAt = 0.0
        run { [self] in
            startedAt = ProcessInfo.processInfo.systemUptime
            c.startCapture(fullPage: true)
        }
        step { [self] done in waitUntil({ active()?.picturesReady == true && active()?.phase != .capturing }, timeout: 60) { done() } }
        run { [self] in
            guard let s = active(), let p = s.fullPagePicture else { return check(false, "capture full page (very long): a picture") }
            let w = p.image.width, h = p.image.height
            let took = ProcessInfo.processInfo.systemUptime - startedAt
            check(p.truncated && w * h <= FullPageCapture.maxPixels && h <= FullPageCapture.maxHeight && p.scale >= 1
                  && p.pagePoints.height >= 199_000 * CGFloat(c.engineTab(for: veryLongTab)?.zoomFactor ?? 1),
                  "capture full page (very long): \(w) × \(h) px at \(String(format: "%.2f", Double(p.scale)))×, within \(FullPageCapture.maxPixels / 1_000_000) MP "
                  + "and \(FullPageCapture.maxHeight) px, the first \(Int(p.capturedPoints.height)) of \(Int(p.pagePoints.height)) pt (\(String(format: "%.1f", took)) s)")
            check(s.overlay.subviews.contains { ($0 as? CapturePill)?.text.hasPrefix("Full page · the first") == true && !$0.isHidden },
                  "capture full page (very long): the overlay says it's the first part of a longer page")
            if let img = decode(p.image) {
                // Red and blue stripes of 400 CSS px: each once, none doubled or lost at the tiles' seams.
                var stripes = 0, last: Bool?
                var heights: [Int] = [], rows = 0
                for y in 0..<img.h {
                    let px = pixel(img, img.w / 2, y).0
                    let isRed = px.r > px.b
                    if isRed != last { stripes += 1; if last != nil { heights.append(rows) }; rows = 0; last = isRed }
                    rows += 1
                }
                let zoom = c.engineTab(for: veryLongTab)?.zoomFactor ?? 1
                let want = Int((Double(p.capturedPoints.height) / zoom / 400).rounded(.up))
                let stripePx = 400 * zoom * Double(p.scale)
                let even = heights.allSatisfy { abs(Double($0) - stripePx) <= 2 }
                check(abs(stripes - want) <= 1 && even,
                      "capture full page (very long): \(stripes) stripes of \(Int(stripePx)) px down it (want \(want)), each once"
                      + (even ? "" : " — heights \(Set(heights).sorted())"))
            }
            s.cancel()
        }

        // Esc while it's being taken.
        run { [self] in c.startCapture(fullPage: true) }
        step { [self] done in waitUntil({ active()?.phase == .capturing }, timeout: 8) { done() } }
        var copiedBefore = 0
        run { [self] in
            copiedBefore = board.changeCount
            let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: c.window.windowNumber,
                                       context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            _ = active()?.handleKey(esc)
            check(active() == nil, "capture full page: Esc stops it at once")
        }
        wait(3.0)
        run { [self] in
            check(active() == nil && board.changeCount == copiedBefore && c.toast.shownText != "Couldn't capture the full page"
                  && !c.root.subviews.contains { $0 is CaptureOverlayView },
                  "capture full page: after Esc nothing is copied, said or left behind")
            if !veryLongTab.isEmpty { c.closeTab(veryLongTab) }
        }

        // A split of two pages: each half as shown.
        run { [self] in
            leftTab = (try? c.store.openTab(url: base + "/left.html", inSpace: c.currentSpaceID, title: "Left"))?.id ?? ""
            rightTab = (try? c.store.openTab(url: base + "/right.html", inSpace: c.currentSpaceID, title: "Right"))?.id ?? ""
            c.show(leftTab, focus: false)
        }
        step { [self] done in waitUntil({ self.c.engineTab(for: leftTab)?.isLoading == false }, timeout: 15) { done() } }
        run { [self] in
            c.addPane(rightTab, nextTo: leftTab, axis: .horizontal)
        }
        step { [self] done in waitUntil({ self.c.shownSplitID != nil && self.c.engineTab(for: rightTab)?.isLoading == false }, timeout: 15) { done() } }
        wait(1.0)
        func captureCard(_ name: String, _ judge: @escaping ((w: Int, h: Int, px: [UInt8])) -> (Bool, String)) {
            run { [self] in c.startCapture() }
            step { [self] done in waitUntil({ active()?.picturesReady == true }, timeout: 8) { done() } }
            run { [self] in
                guard let s = active() else { return check(false, "capture \(name): Capture starts") }
                s.toggleFullPage()
                s.confirm()
                s.overlay.bar.copyButton.action?()
                guard let img = decodePNG(board.data(forType: .png)) else { return check(false, "capture \(name): a picture") }
                let (ok, why) = judge(img)
                check(ok, "capture \(name): \(why)")
            }
        }
        captureCard("split of two pages") { [self] img in
            guard c.shownSplitID != nil else { return (false, "no split shown") }
            let l = pixel(img, img.w / 4, img.h / 2), r = pixel(img, img.w * 3 / 4, img.h / 2)
            let ok = dist(l.0, (229, 57, 53)) < 60 && dist(r.0, (30, 136, 229)) < 60 && l.1 == 255 && r.1 == 255
            return (ok, "left pane red, right pane blue (rgb \(l.0.r),\(l.0.g),\(l.0.b) and \(r.0.r),\(r.0.g),\(r.0.b))")
        }
        // A note beside the page (New Note in Split): taken as it's drawn.
        run { [self] in
            if let x = c.store.split(containing: leftTab) { try? c.store.separateSplit(x.id) }
            c.show(leftTab, focus: false)
        }
        wait(0.6)
        var splitNote = ""
        run { [self] in
            c.newNoteInSplit(source: .commandBar)
            splitNote = c.shownTabID ?? ""
            c.shownNote?.textView.insertText("Beside the page", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        wait(1.0)
        captureCard("split with a note") { [self] img in
            guard c.shownSplitID != nil, c.store.isNoteTab(splitNote) else { return (false, "no note in a split") }
            let l = pixel(img, img.w / 4, img.h / 2), r = pixel(img, img.w * 3 / 4, img.h * 3 / 4)
            let ok = dist(l.0, (229, 57, 53)) < 60 && r.1 == 255 && dist(r.0, (229, 57, 53)) > 120
            return (ok, "the page's pane red, the note's pane as drawn (rgb \(l.0.r),\(l.0.g),\(l.0.b) and \(r.0.r),\(r.0.g),\(r.0.b), alpha \(r.1))")
        }
        run { [self] in
            if let x = c.store.split(containing: leftTab) { try? c.store.separateSplit(x.id) }
            if let id = NoteURL.noteID(c.store.tab(splitNote)?.url) { c.store.updateNote(id, document: NoteDocument()) }
            if !splitNote.isEmpty { _ = try? c.store.closeTab(splitNote) }
            c.show(leftTab, focus: false)
        }
        wait(0.6)
        // Peek over the page: its page on top.
        run { [self] in
            if let opener = c.engineTab(for: leftTab), let url = URL(string: base + "/right.html") { c.openPeek(url, from: opener) }
        }
        step { [self] done in waitUntil({ self.c.peek?.page.title == "Right" && self.c.peek?.page.isLoading == false }, timeout: 10) { done() } }
        wait(0.8)
        run { [self] in if c.peek == nil { skip("capture with Peek: this engine opens no Peek (a new tab instead)") } }
        captureCard("with Peek open") { [self] img in
            guard c.peek != nil else { return (true, "no Peek on this engine") }
            // Peek sits over the middle of the card: its page (blue) is on top of the page under it (red).
            let p = pixel(img, img.w / 2, img.h / 2), corner = pixel(img, 6, img.h - 6)
            return (dist(p.0, (30, 136, 229)) < 60 && p.1 == 255,
                    "Peek's page on top in the middle (rgb \(p.0.r),\(p.0.g),\(p.0.b)), the page under it at the edge (rgb \(corner.0.r),\(corner.0.g),\(corner.0.b))")
        }
        run { [self] in
            c.closePeek()
            for t in [leftTab, rightTab, longTab] where !t.isEmpty { c.closeTab(t) }
            server?.stop()
        }
        wait(0.5)
    }
}
#endif
