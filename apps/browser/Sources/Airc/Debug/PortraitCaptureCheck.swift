// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit
import ImageIO

/// Part of `--script capture` (P08b, docs/user/capture.md "Portrait"): Capture in Portrait Mode on loopback pages, with
/// the run's own pasteboard, folder and preferences suite. The desktop picture is a synthetic one given through
/// PortraitCapture.wallpaper: the owner's is never read.
///   - the bar's Portrait, P and the Command Bar; the page centred with Arc's proportions (0.357 × its width at each
///     side, 0.168 × above and below), at the window's pixels per point (the PNG's dpi says so) and at 1×;
///   - the default background (the slider at 85 %), another slider colour, the website's colour (a themed page), the
///     desktop picture: the background's corners are the colours Arc's two-way gradient gives;
///   - rounded corners, the shadow under the page, the mark in its corner and hidden;
///   - the choices remembered; ⌥ on Portrait copies at once in them;
///   - Share and Save write the same picture, and Copy the same pixels; no metadata but the resolution;
///   - ⌥ on Full Page: a full-page portrait; Esc leaves nothing behind.
extension SnapshotRunner {
    func portraitCaptureChecks(board: NSPasteboard, scratch: URL, usedCount: @escaping () -> Int) {
        var server: LocalPageServer?
        var base = ""
        var quartersTab = "", themedTab = "", tallTab = ""
        var shared: [Any] = []
        var wallpaperReads = 0
        let suiteName = "org.airc.test.portrait.\(getpid())"
        let realWallpaper = PortraitCapture.wallpaper
        let active = { CaptureSession.active(in: self.c.window) }
        let quarters = """
        <title>Quarters</title><style>html,body{margin:0;height:100%;overflow:hidden}div{position:fixed;width:50vw;height:50vh}
        #r{left:0;top:0;background:#e53935}#g{right:0;top:0;background:#43a047}#b{left:0;bottom:0;background:#1e88e5}
        #y{right:0;bottom:0;background:#fdd835}</style><div id=r></div><div id=g></div><div id=b></div><div id=y></div>
        """
        let themed = "<title>Themed</title><meta name=theme-color content='#2f80ed'><style>html,body{margin:0;height:100%;background:#2f80ed}</style>"
        let tall = "<title>Tall</title><style>html,body{margin:0}div{height:600px}</style>"
            + "<div style='background:#e53935'></div><div style='background:#43a047'></div><div style='background:#1e88e5'></div>"

        typealias RGB = (r: Int, g: Int, b: Int)
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
        func at(_ d: (w: Int, h: Int, px: [UInt8]), _ x: Int, _ y: Int) -> RGB {
            let i = (min(d.h - 1, max(0, y)) * d.w + min(d.w - 1, max(0, x))) * 4
            return (Int(d.px[i]), Int(d.px[i + 1]), Int(d.px[i + 2]))
        }
        func dist(_ a: RGB, _ b: RGB) -> Int { max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b)) }
        func rgb(_ c: PortraitCapture.HSL) -> RGB { let v = c.rgb; return (Int((v.0 * 255).rounded()), Int((v.1 * 255).rounded()), Int((v.2 * 255).rounded())) }
        func str(_ c: RGB) -> String { "rgb(\(c.r),\(c.g),\(c.b))" }
        func lum(_ c: RGB) -> Double { 0.2126 * Double(c.r) + 0.7152 * Double(c.g) + 0.0722 * Double(c.b) }
        /// The background's corners against Arc's gradient around `base` (2 px in from each corner; the mark's corner
        /// is outside its square).
        func corners(_ d: (w: Int, h: Int, px: [UInt8]), _ base: PortraitCapture.HSL) -> (Bool, String) {
            let want = PortraitCapture.corners(base)
            let got = [at(d, 2, 2), at(d, d.w - 3, 2), at(d, 2, d.h - 3), at(d, d.w - 3, d.h - 3)]
            let exp = [rgb(want.topLeft), rgb(want.topRight), rgb(want.bottomLeft), rgb(want.bottomRight)]
            let ok = zip(got, exp).allSatisfy { dist($0, $1) <= 12 }
            return (ok, zip(got, exp).map { "\(str($0)) want \(str($1))" }.joined(separator: ", "))
        }
        func load(_ path: String, _ title: String, _ set: @escaping (String) -> Void) {
            run { [self] in
                let id = (try? c.store.openTab(url: base + path, inSpace: c.currentSpaceID, title: title))?.id ?? ""
                set(id)
                c.show(id, focus: false)
            }
            step { [self] done in
                waitUntil({ CaptureSession.active(in: self.c.window) == nil && self.c.shownTabID.flatMap { self.c.engineTab(for: $0) }.map { !$0.isLoading && $0.title == title } == true },
                          timeout: 15) { done() }
            }
            wait(0.8)
        }
        /// Starts a portrait the way `how` says and waits for it.
        func portrait(_ how: String, fullPage: Bool = false) {
            run { [self] in
                switch how {
                case "Command Bar": c.commandActions().first { $0.title == "Capture in Portrait Mode" }?.run()
                case "P":
                    c.startCapture()
                default: c.startCapture(fullPage: fullPage, portrait: true)
                }
            }
            step { [self] done in waitUntil({ active()?.picturesReady == true }, timeout: 8) { done() } }
            run { [self] in
                guard let s = active() else { return }
                if how == "P" {
                    let p = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: c.window.windowNumber,
                                             context: nil, characters: "p", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35)!
                    _ = s.handleKey(p)
                }
            }
            step { [self] done in waitUntil({ active().map { $0.phase == .confirmed && $0.portrait != nil } ?? true }, timeout: 40) { done() } }
        }

        step { [self] done in
            UserDefaults().removePersistentDomain(forName: suiteName)
            PortraitStyle.storage = { UserDefaults(suiteName: suiteName)! }
            PortraitCapture.wallpaper = { _, _ in
                wallpaperReads += 1
                // A synthetic desktop picture: purple, orange, teal and gold quarters.
                let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                // Top left, top right, bottom left, bottom right (CG counts from the bottom).
                for (col, rect) in [(0x7B1FA2, CGRect(x: 0, y: 150, width: 200, height: 150)), (0xF57C00, CGRect(x: 200, y: 150, width: 200, height: 150)),
                                    (0x00897B, CGRect(x: 0, y: 0, width: 200, height: 150)), (0xFBC02D, CGRect(x: 200, y: 0, width: 200, height: 150))] {
                    ctx.setFillColor(CGColor(srgbRed: CGFloat(col >> 16 & 0xFF) / 255, green: CGFloat(col >> 8 & 0xFF) / 255, blue: CGFloat(col & 0xFF) / 255, alpha: 1))
                    ctx.fill(rect)
                }
                return ctx.makeImage()
            }
            CaptureSession.presentShare = { _, items, _ in shared = items }
            server = LocalPageServer(responses: ["/quarters.html": .init(body: quarters), "/themed.html": .init(body: themed), "/tall.html": .init(body: tall)])
            server?.start { port in
                base = port.map { "http://localhost:\($0)" } ?? ""
                done()
            }
        }
        load("/quarters.html", "Quarters") { quartersTab = $0 }

        // The bar's Portrait: the default frame.
        run { [self] in
            check(c.commandActions().contains { $0.title == "Capture in Portrait Mode" }, "capture portrait: the Command Bar has Capture in Portrait Mode")
            c.startCapture()
        }
        step { [self] done in waitUntil({ active()?.picturesReady == true }, timeout: 8) { done() } }
        run { [self] in
            guard let s = active() else { return check(false, "capture portrait: Capture starts") }
            check(s.overlay.bar.mode == .start && !s.overlay.bar.portraitButton.isHidden, "capture portrait: before a selection, the bar offers Portrait")
            s.overlay.bar.portraitButton.action?()
        }
        step { [self] done in waitUntil({ active().map { $0.phase == .confirmed && $0.portrait != nil } ?? true }, timeout: 10) { done() } }
        run { [self] in
            guard let s = active(), let p = s.portrait, let layout = p.layout, let img = s.result, let d = decode(img) else {
                return check(false, "capture portrait: a portrait (session \(active() != nil))")
            }
            let page = CGSize(width: CGFloat(p.content.width) / p.contentScale, height: CGFloat(p.content.height) / p.contentScale)
            let px = s.resultScale
            check(p.style == PortraitStyle() && page.width >= 300 && layout.page.minX == (0.357 * page.width).rounded()
                  && layout.page.minY == (0.168 * page.width).rounded() && layout.canvas.width == page.width + 2 * layout.page.minX
                  && abs(CGFloat(img.width) - layout.canvas.width * px) <= 1 && abs(CGFloat(img.height) - layout.canvas.height * px) <= 1,
                  "capture portrait: the page (\(Int(page.width)) × \(Int(page.height)) pt) centred in \(Int(layout.canvas.width)) × \(Int(layout.canvas.height)) pt, "
                  + "\(img.width) × \(img.height) px at \(px)×, Arc's proportions")
            let (ok, why) = corners(d, PortraitCapture.sliderColor(0.85))
            check(ok, "capture portrait: the default background is Arc's gradient around the slider's cyan (\(why))")
            // The page's quarters in their places; its corner rounded; a shadow under it; the mark in its corner.
            let r = CGRect(x: layout.page.minX * px, y: layout.page.minY * px, width: layout.page.width * px, height: layout.page.height * px)
            let q = [at(d, Int(r.minX + r.width * 0.25), Int(r.minY + r.height * 0.25)), at(d, Int(r.minX + r.width * 0.75), Int(r.minY + r.height * 0.25)),
                     at(d, Int(r.minX + r.width * 0.25), Int(r.minY + r.height * 0.75)), at(d, Int(r.minX + r.width * 0.75), Int(r.minY + r.height * 0.75))]
            let wantQ: [RGB] = [(229, 57, 53), (67, 160, 71), (30, 136, 229), (253, 216, 53)]
            check(zip(q, wantQ).allSatisfy { dist($0, $1) <= 30 }, "capture portrait: the page's quarters in their places (\(q.map(str).joined(separator: " ")))")
            let corner = at(d, Int(r.minX) + 1, Int(r.minY) + 1), inside = at(d, Int(r.minX + layout.cornerRadius * px * 2), Int(r.minY + layout.cornerRadius * px * 2))
            check(dist(corner, (229, 57, 53)) > 60 && dist(inside, (229, 57, 53)) <= 30,
                  "capture portrait: rounded corners (\(Int(layout.cornerRadius)) pt): the very corner is background \(str(corner)), inside it the page \(str(inside))")
            let under = at(d, Int(r.midX), Int(r.maxY + 0.02 * layout.page.width * px)), aside = at(d, Int(r.minX * 0.5), Int(r.maxY + 0.02 * layout.page.width * px))
            check(lum(under) < lum(aside) - 8, "capture portrait: a shadow under the page (\(str(under)) against \(str(aside)) beside it)")
            let wm = CGRect(x: layout.watermark.minX * px, y: layout.watermark.minY * px, width: layout.watermark.width * px, height: layout.watermark.height * px)
            let mark = at(d, Int(wm.midX), Int(wm.midY)), markEdge = at(d, Int(wm.minX + 2 * px), Int(wm.minY + 2 * px))
            let bgThere = at(d, Int(wm.maxX + 4 * px), Int(wm.midY))
            check(dist(mark, bgThere) > 20 || dist(markEdge, bgThere) > 4, "capture portrait: Airc's mark in the bottom-left corner (\(str(mark)) on \(str(bgThere)))")
            check(!s.overlay.portraitControls.isHidden && s.overlay.previewFrame != nil && s.overlay.bar.mode == .confirmed,
                  "capture portrait: shown with its controls, then Copy, Save and Share")
            check(PortraitStyle.storage().object(forKey: "portraitCaptureBackground") == nil, "capture portrait: nothing remembered until a choice is made")
        }
        // The controls: the mark off, another colour, the website's colour, the desktop picture; each remembered.
        run { [self] in
            guard let s = active(), let before = s.result else { return }
            s.overlay.portraitControls.toggleWatermark()
            guard let p = s.portrait, let layout = p.layout, let d = decode(s.result), let d0 = decode(before) else { return check(false, "capture portrait: hiding the mark") }
            let px = s.resultScale
            let wm = CGRect(x: layout.watermark.minX * px, y: layout.watermark.minY * px, width: layout.watermark.width * px, height: layout.watermark.height * px)
            let now = at(d, Int(wm.midX), Int(wm.midY)), was = at(d0, Int(wm.midX), Int(wm.midY)), bg = at(d, Int(wm.maxX + 4 * px), Int(wm.midY))
            check(PortraitStyle.saved.hidesWatermark && dist(now, bg) <= 12 && dist(now, was) > 4,
                  "capture portrait: hiding the mark leaves the background there (\(str(now)), was \(str(was))) and is remembered")
            s.overlay.portraitControls.pickColor(0.2)
            let (ok, why) = decode(s.result).map { corners($0, PortraitCapture.sliderColor(0.2)) } ?? (false, "-")
            check(ok && PortraitStyle.saved.background == .color && abs(PortraitStyle.saved.colorPercentage - 0.2) < 0.001,
                  "capture portrait: the slider at 20 % (orange) gives its gradient, remembered (\(why))")
            let reads = wallpaperReads
            s.overlay.portraitControls.pick(.wallpaper)
            if let d = decode(s.result) {
                let got = [at(d, 2, 2), at(d, d.w - 3, 2), at(d, 2, d.h - 3), at(d, d.w - 3, d.h - 3)]
                let want: [RGB] = [(0x7B, 0x1F, 0xA2), (0xF5, 0x7C, 0x00), (0x00, 0x89, 0x7B), (0xFB, 0xC0, 0x2D)]
                check(wallpaperReads == reads + 1 && zip(got, want).allSatisfy { dist($0, $1) <= 16 } && PortraitStyle.saved.background == .wallpaper,
                      "capture portrait: Use Desktop Wallpaper fills the background with the desktop picture, read once when picked (\(got.map(str).joined(separator: " ")))")
            }
            s.cancel()
            check(wallpaperReads == reads + 1, "capture portrait: the desktop picture is read only once it's picked")
        }
        // The website's colour, on a themed page.
        load("/themed.html", "Themed") { themedTab = $0 }
        portrait("P")
        run { [self] in
            guard let s = active(), s.portrait != nil else { return check(false, "capture portrait (P): a portrait") }
            s.overlay.portraitControls.pick(.website)
            let website = s.portrait.map { PortraitCapture.HSL($0.website) }
            let (ok, why) = decode(s.result).map { corners($0, website ?? PortraitCapture.HSL(h: 0, s: 0, l: 1)) } ?? (false, "-")
            check(ok && website.map { abs($0.h - 214) < 6 && $0.s > 0.6 } == true,
                  "capture portrait: Use Website Color takes the page's colour (hue \(Int(website?.h ?? -1))°) for Arc's gradient (\(why))")
            s.cancel()
        }
        // Remembered: ⌥ on Portrait copies at once in the last choices (the website's colour, the mark hidden).
        run { [self] in c.startCapture() }
        step { [self] done in waitUntil({ active()?.picturesReady == true }, timeout: 8) { done() } }
        var quickCopy: Data?
        run { [self] in
            guard let s = active() else { return }
            let n = board.changeCount
            s.capturePortrait(quick: true)
            quickCopy = board.data(forType: .png)
            check(board.changeCount != n && quickCopy != nil && active() == nil && c.toast.shownText == "Copied Capture",
                  "capture portrait: ⌥ on Portrait copies at once (\(c.toast.shownText ?? "no toast"))")
        }
        // Share and Save: the same file; Copy the same pixels; nothing in it but its pixels and resolution.
        portrait("button")
        run { [self] in
            guard let s = active(), let style = s.portrait?.style else { return check(false, "capture portrait: a portrait for Share and Save") }
            check(style.background == .website && style.hidesWatermark, "capture portrait: a new portrait opens in the remembered choices")
            s.share()
            let sharedData = (shared.first as? URL).flatMap { try? Data(contentsOf: $0) }
            let before = Set((try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? [])
            s.save()
            let after = Set((try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? [])
            let saved = after.subtracting(before).first.map { scratch.appendingPathComponent($0) }
            let savedData = saved.flatMap { try? Data(contentsOf: $0) }
            // The same picture: pixel for pixel (the PNG's bytes are reported too).
            let a = decodePNG(sharedData), b = decodePNG(savedData)
            let samePixels = a != nil && b != nil && a!.w == b!.w && a!.h == b!.h && a!.px == b!.px
            check(samePixels, "capture portrait: Share and Save hand over the same picture, pixel for pixel "
                  + "(\(a.map { "\($0.w) × \($0.h)" } ?? "-"); PNG \(sharedData?.count ?? 0) and \(savedData?.count ?? 0) bytes, "
                  + (sharedData == savedData ? "identical" : "not byte-identical") + ")")
            if let a = decodePNG(savedData), let b = decodePNG(quickCopy) {
                let same = a.w == b.w && a.h == b.h && zip(a.px, b.px).allSatisfy { abs(Int($0) - Int($1)) <= 2 }
                check(same, "capture portrait: Copy's picture is the same pixels (\(a.w) × \(a.h) and \(b.w) × \(b.h) px)")
            }
            if let data = savedData, let src = CGImageSourceCreateWithData(data as CFData, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                let keys = Set(props.keys.map { $0 as String })
                let dicts = keys.filter { $0.hasPrefix("{") }
                // PNG chunks other than the picture's own and its resolution (text, time, Exif) would carry metadata.
                var chunks: [String] = []
                var i = 8
                while i + 8 <= data.count {
                    let len = Int(data[i]) << 24 | Int(data[i + 1]) << 16 | Int(data[i + 2]) << 8 | Int(data[i + 3])
                    chunks.append(String(decoding: data[(i + 4)..<(i + 8)], as: UTF8.self))
                    i += 12 + len
                }
                // ImageIO writes the resolution twice, as pHYs and as an eXIf chunk: that one may hold only the
                // resolution and the pixel size (measured: X/YResolution, ResolutionUnit, PixelX/YDimension).
                let extra = chunks.filter { !["IHDR", "IDAT", "IEND", "pHYs", "iCCP", "sRGB", "cHRM", "gAMA", "iDOT", "eXIf"].contains($0) }
                let exif = Set(((props[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]).keys.map { $0 as String })
                let tiff = Set(((props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]).keys.map { $0 as String })
                let okExif = exif.isSubset(of: [kCGImagePropertyExifPixelXDimension as String, kCGImagePropertyExifPixelYDimension as String,
                                                kCGImagePropertyExifColorSpace as String])
                let okTIFF = tiff.isSubset(of: [kCGImagePropertyTIFFXResolution as String, kCGImagePropertyTIFFYResolution as String,
                                                kCGImagePropertyTIFFResolutionUnit as String])
                let dpi = (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 0
                check(extra.isEmpty && dicts.subtracting(["{PNG}", "{Exif}", "{TIFF}"]).isEmpty && okExif && okTIFF && abs(dpi - 72 * Double(s.resultScale)) < 1,
                      "capture portrait: no private metadata: its pixels, colour profile and \(Int(dpi)) dpi only (chunks \(Set(chunks).sorted().joined(separator: " ")); "
                      + "Exif \(exif.sorted().joined(separator: " ")); TIFF \(tiff.sorted().joined(separator: " ")))")
                let pts = NSImage(data: data)?.size
                let canvas = s.portrait?.layout?.canvas
                check(pts != nil && canvas != nil && abs(pts!.width - canvas!.width) < 1 && abs(pts!.height - canvas!.height) < 1,
                      "capture portrait: it reads back at its size in points (\(pts.map { "\(Int($0.width)) × \(Int($0.height))" } ?? "-"))")
            }
        }
        // At 1×: the same frame, one pixel per point.
        run { [self] in
            CaptureSession.scaleOverride = 1
            c.show(quartersTab, focus: false)
        }
        wait(0.6)
        portrait("Command Bar")
        run { [self] in
            guard let s = active(), let layout = s.portrait?.layout, let img = s.result else { return check(false, "capture portrait (1×): a portrait") }
            check(s.resultScale == 1 && abs(CGFloat(img.width) - layout.canvas.width) <= 1 && abs(CGFloat(img.height) - layout.canvas.height) <= 1,
                  "capture portrait (1×, from the Command Bar): \(img.width) × \(img.height) px for \(Int(layout.canvas.width)) × \(Int(layout.canvas.height)) pt")
            s.cancel()
            CaptureSession.scaleOverride = nil
        }
        // ⌥ on Full Page: a portrait of the whole page.
        load("/tall.html", "Tall") { tallTab = $0 }
        run { [self] in c.startCapture() }
        step { [self] done in waitUntil({ active()?.picturesReady == true }, timeout: 8) { done() } }
        run { [self] in active()?.capturePortrait(fullPage: true) }
        step { [self] done in waitUntil({ active().map { $0.phase == .confirmed && $0.portrait != nil } ?? true }, timeout: 40) { done() } }
        run { [self] in
            guard let s = active(), let p = s.portrait, let layout = p.layout else { return check(false, "capture portrait (full page): a portrait") }
            let zoom = c.engineTab(for: tallTab)?.zoomFactor ?? 1
            check(abs(layout.page.height - 1800 * zoom) <= 1 && layout.canvas.height == layout.page.height + 2 * layout.page.minY,
                  "capture portrait (full page, ⌥ on Full Page): the whole \(Int(layout.page.height)) pt page framed, \(Int(layout.canvas.width)) × \(Int(layout.canvas.height)) pt")
        }
        // Esc: nothing copied, saved or left.
        var escState = (0, 0, 0, 0)
        run { [self] in
            let files = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path))?.count ?? 0
            let n = board.changeCount, counted = usedCount()
            // The temporary folder is the user's, shared with other Airc processes: what matters is that this one adds nothing.
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("Airc Captures", isDirectory: true)
            let tmpBefore = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path))?.count ?? 0
            let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: c.window.windowNumber,
                                       context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            _ = active()?.handleKey(esc)
            escState = (files, n, counted, tmpBefore)
        }
        // The overlay fades before it goes.
        wait(1.0)
        run { [self] in
            let (files, n, counted, tmpBefore) = escState
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("Airc Captures", isDirectory: true)
            let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: tmp.path))?.count ?? 0) - tmpBefore
            check(active() == nil && board.changeCount == n && usedCount() == counted
                  && ((try? FileManager.default.contentsOfDirectory(atPath: scratch.path))?.count ?? 0) == files && leftovers <= 0
                  && !c.root.subviews.contains { $0 is CaptureOverlayView },
                  "capture portrait: Esc leaves nothing copied, saved, counted or behind (\(leftovers) temporary files)")
        }
        run { [self] in
            for t in [quartersTab, themedTab, tallTab] where !t.isEmpty { c.closeTab(t) }
            UserDefaults().removePersistentDomain(forName: suiteName)
            PortraitStyle.storage = { .standard }
            PortraitCapture.wallpaper = realWallpaper
            server?.stop()
        }
        wait(0.4)
    }
}
#endif
