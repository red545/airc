// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit
import UniformTypeIdentifiers
import WebKit

/// P19c, an Easel out of Airc (parity N08) and P19b's leftovers (L05, undo of a row copy), on either engine:
///   - Export: a PNG of the whole Easel at 1× and 2× (its size in pixels and points, each block's colour where it is,
///     a live Capture as its last picture without the Live chip) and of a selection; Copy Image (PNG and TIFF, 2×);
///     a web page ZIP (index.html, easel.json, assets/) whose pictures are PNG/JPEG (the HEIC one converted), with no
///     session token, password or profile id in it, opened offline from its folder in a WebKit view and in this
///     window's engine: the board drawn, every picture loaded, no scripts, links open in a new tab.
///   - Share Link: the sheet shows the page as it will be published (its pictures loaded) and what's left out; Create
///     Link publishes to the configured sharing service (AIRC_SHARING_BASE: `vercel dev`, a Preview or the local
///     sharing-dev server; never aircbrowser.com) — the /e/<id> page renders the blocks, its pictures are the bytes
///     sent, the API's Easel is exactly the one sent; the token is held; the link is listed when the sheet opens again;
///     Take Back makes the page, its pictures and the API 404 and forgets the token.
///   - File › Export Easel… and Share Easel… (enabled only with an Easel shown), the Command Bar's entries, the canvas
///     and toolbar menus.
///   - L05: a Today Easel row's menu has no Add Split View (a web tab's still has); Library › Easels has Export… and
///     Share Link….
///   - Undoing an ⌥-drag copy of an Easel row deletes the copied Easel (folder gone, its editor gone, not in
///     Library › Easels, and not written back by a later save).
extension SnapshotRunner {
    func parityP19cScenario() {
        // Off-main watchdog: a check app never outlives its check (common.md, 06:50).
        let file = dir.appendingPathComponent("log.txt"), name = script
        DispatchQueue.global().asyncAfter(deadline: .now() + 280) {
            let previous = (try? String(contentsOf: file, encoding: .utf8)).map { $0 + "\n" } ?? ""
            try? (previous + "[\(name)]\nFAIL \(name): the main thread was stuck past 280 s (off-main watchdog quit the app)").write(to: file, atomically: true, encoding: .utf8)
            exit(70)
        }
        parityP19cMain()
    }

    private final class P19c {
        var easelID = ""
        var easelTab = ""
        var ids: [String: String] = [:]
        var tmp: URL!
        var outgoing: EaselOutgoing?
        var record: SharedLinkRecord?
        var web: WKWebView?
        var results: [String: Any] = [:]
        var fetched: [String: (Int, Data, String, String)] = [:]
    }

    /// A solid picture `w`×`h` of `color` as `type` (PNG, JPEG, HEIC).
    private func p19cPicture(_ color: NSColor, _ w: Int, _ h: Int, _ type: UTType = .png) -> Data? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        guard let img = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// A picture's pixels as sRGB bytes (RGBA, rows from the top), decoded through ImageIO with its own profile.
    /// (NSBitmapImageRep.colorAt reads 8-bit PNGs in a calibrated space, which shifts sRGB midtones.)
    private struct P19cPixels {
        let width: Int, height: Int, bytes: [UInt8]
        init?(_ data: Data?) {
            guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            width = img.width
            height = img.height
            var b = [UInt8](repeating: 0, count: width * height * 4)
            guard let ctx = CGContext(data: &b, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
            bytes = b
        }
        func at(_ x: Double, _ y: Double) -> (Int, Int, Int)? {
            let xi = Int(x), yi = Int(y)
            guard xi >= 0, yi >= 0, xi < width, yi < height else { return nil }
            let i = (yi * width + xi) * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
        }
    }

    /// The colour at pixel (x, y) from the top left, as sRGB components 0–255.
    private func p19cPixel(_ px: P19cPixels?, _ x: Double, _ y: Double) -> (Int, Int, Int)? { px?.at(x, y) }

    private func p19cNear(_ p: (Int, Int, Int)?, _ r: Int, _ g: Int, _ b: Int, _ tolerance: Int = 12) -> Bool {
        guard let p else { return false }
        return abs(p.0 - r) <= tolerance && abs(p.1 - g) <= tolerance && abs(p.2 - b) <= tolerance
    }

    private func p19cNear(_ p: (Int, Int, Int)?, _ q: (Int, Int, Int)?, _ tolerance: Int = 12) -> Bool {
        guard let q else { return false }
        return p19cNear(p, q.0, q.1, q.2, tolerance)
    }

    /// The middle pixel of an Easel asset, decoded the same way.
    private func p19cAssetPixel(_ easelID: String, _ asset: String?) -> (Int, Int, Int)? {
        guard let asset, let url = EaselCenter.shared.files.assetURL(easelID, asset), let px = P19cPixels(try? Data(contentsOf: url)) else { return nil }
        return px.at(Double(px.width / 2), Double(px.height / 2))
    }

    /// GET with the service's test headers (a Preview's protection bypass); status, body, Content-Type and CSP.
    private func p19cFetch(_ url: URL, _ done: @escaping (Int, Data, String, String) -> Void) {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        r.httpShouldHandleCookies = false
        for (k, v) in SharingCenter.shared.service.extraHeaders { r.setValue(v, forHTTPHeaderField: k) }
        URLSession(configuration: .ephemeral).dataTask(with: r) { data, response, _ in
            let h = response as? HTTPURLResponse
            let out = (h?.statusCode ?? 0, data ?? Data(), h?.value(forHTTPHeaderField: "Content-Type") ?? "",
                       h?.value(forHTTPHeaderField: "Content-Security-Policy") ?? "")
            DispatchQueue.main.async { done(out.0, out.1, out.2, out.3) }
        }.resume()
    }

    private static let p19cProbe = """
    JSON.stringify({ board: !!document.querySelector('.easel'), blocks: document.querySelectorAll('.easel .b').length,
      imgs: document.images.length, loaded: [...document.images].filter(i => i.complete && i.naturalWidth > 0).length,
      scripts: document.scripts.length, blank: [...document.querySelectorAll('.easel a')].every(a => a.target === '_blank' && /noopener/.test(a.rel)),
      links: [...document.querySelectorAll('.easel a')].map(a => a.getAttribute('href')), width: document.querySelector('.easel')?.getBoundingClientRect().width ?? 0 })
    """

    private func parityP19cMain() {
        let s = P19c()
        var doc: EaselDocument { EaselCenter.shared.existingEditor(s.easelID)?.document ?? EaselDocument() }
        var editor: EaselEditor? { EaselCenter.shared.existingEditor(s.easelID) }
        let profile = { [self] in c.store.profile(ofSpace: c.currentSpaceID).id }
        let secrets = ["s3cr3t-p19c", "t0k3n-p19c", "hunter2-p19c"]
        let base = SharingCenter.shared.service.base
        let canPublish = base.host?.hasSuffix("aircbrowser.com") == false

        run { [self] in
            s.tmp = FileManager.default.temporaryDirectory.appendingPathComponent("p19c-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: s.tmp, withIntermediateDirectories: true)
            note("p19c: sharing service \(base.absoluteString)\(canPublish ? "" : " (Production: links not published)")")
            guard let id = c.newEasel(title: "Trip board") else { return check(false, "p19c: a new Easel") }
            s.easelID = id
            s.easelTab = c.shownTabID ?? ""
            c.window.makeFirstResponder(nil)
        }
        wait(0.4)

        // MARK: An Easel with every kind of block
        run { [self] in
            guard let e = editor else { return check(false, "p19c: the Easel's editor") }
            s.ids["text"] = e.addText(EaselText(plain: "Lisbon\nPastéis de nata", size: 22), at: EaselPoint(0, 0))
            if let d = p19cPicture(.systemRed.usingColorSpace(.sRGB)!, 400, 240), let img = EaselCenter.shared.storePicture(d, ext: "png", in: id(s)) {
                s.ids["red"] = e.addImage(img, at: EaselPoint(420, 60))
            }
            if let d = p19cPicture(NSColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 1), 300, 200, .heic), let img = EaselCenter.shared.storePicture(d, ext: "heic", in: id(s)) {
                s.ids["heic"] = e.addImage(img, at: EaselPoint(700, 60))
            } else {
                note("p19c: this Mac can't write HEIC; the conversion case is skipped")
            }
            s.ids["shape"] = e.add(.shape(EaselShape(.rectangle, fill: .lightGreen)), frame: EaselRect(x: 0, y: 200, width: 160, height: 100), name: "Add Shape")
            let line = EaselLine(from: EaselPoint(200, 220), to: EaselPoint(320, 300))
            s.ids["line"] = e.add(.line(line), frame: line.bounds, name: "Add Line")
            s.ids["link"] = e.addLink(URL(string: "https://user:hunter2-p19c@example.com/doc?id=7&session=s3cr3t-p19c")!, title: "Doc", at: EaselPoint(560, 260))
            if let d = p19cPicture(NSColor(srgbRed: 0.1, green: 0.3, blue: 0.95, alpha: 1), 640, 400), let img = EaselCenter.shared.storePicture(d, ext: "png", in: id(s)) {
                let live = EaselLiveSource(url: "https://example.com/stats?token=t0k3n-p19c", profileID: profile(), rect: EaselRect(x: 0, y: 0, width: 320, height: 200),
                                           viewportWidth: 1200, viewportHeight: 800, mode: .live, refreshedAt: Date())
                s.ids["capture"] = e.addCapture(img, url: live.url, title: "Stats", live: live)
            }
            e.selection = []
            check(doc.blocks.count == 7 || (s.ids["heic"] == nil && doc.blocks.count == 6), "p19c: the Easel has text, pictures, a shape, a line, a link and a live Capture (\(doc.blocks.count) blocks)")
            check(doc.liveBlocks.count == 1, "p19c: …one of them a live Capture")
            e.saveNow(wait: true)
        }

        // MARK: PNG, 2× and 1×, and a selection
        run { [self] in
            guard let e = editor, let bounds = doc.contentBounds else { return check(false, "p19c: export needs the Easel") }
            let png2 = s.tmp.appendingPathComponent("board@2x.png"), png1 = s.tmp.appendingPathComponent("board.png"), sel = s.tmp.appendingPathComponent("shape.png")
            var ok = [Bool]()
            e.write(.png2, ids: nil, to: png2) { ok.append($0) }
            e.write(.png1, ids: nil, to: png1) { ok.append($0) }
            e.write(.png1, ids: [s.ids["shape"] ?? ""], to: sel) { ok.append($0) }
            check(ok == [true, true, true], "p19c png: the whole Easel at 2× and 1× and a selection are written")
            let r2 = NSBitmapImageRep(data: (try? Data(contentsOf: png2)) ?? Data()), r1 = NSBitmapImageRep(data: (try? Data(contentsOf: png1)) ?? Data())
            let px2 = P19cPixels(try? Data(contentsOf: png2))
            let w = bounds.width + 2 * EaselPicture.margin, h = bounds.height + 2 * EaselPicture.margin
            check(abs(Double(r2?.pixelsWide ?? 0) - (w * 2).rounded(.up)) <= 1 && abs(Double(r2?.pixelsHigh ?? 0) - (h * 2).rounded(.up)) <= 1,
                  "p19c png: 2× is the content's size in pixels at 2 per point (\(r2?.pixelsWide ?? 0)×\(r2?.pixelsHigh ?? 0) for \(Int(w))×\(Int(h)) pt)")
            check(abs(Double(r1?.pixelsWide ?? 0) - w.rounded(.up)) <= 1 && abs((r2?.size.width ?? 0) - w) <= 1,
                  "p19c png: 1× is one pixel per point, and the 2× file says its size in points (\(Int(r2?.size.width ?? 0)) pt)")
            func at(_ key: String, _ fx: Double = 0.5, _ fy: Double = 0.5, inset: Double = 0) -> (Int, Int, Int)? {
                guard let b = s.ids[key].flatMap({ doc.block($0) }) else { return nil }
                let x = b.frame.x + b.frame.width * fx + (fx > 0.5 ? -inset : inset), y = b.frame.y + b.frame.height * fy + (fy > 0.5 ? -inset : inset)
                return p19cPixel(px2, (x - bounds.x + EaselPicture.margin) * 2, (y - bounds.y + EaselPicture.margin) * 2)
            }
            func asset(_ key: String) -> String? {
                switch s.ids[key].flatMap({ doc.block($0) })?.content {
                case .image(let i)?: i.asset
                case .capture(let c)?: c.asset
                default: nil
                }
            }
            let red = p19cAssetPixel(s.easelID, asset("red")), blue = p19cAssetPixel(s.easelID, asset("capture"))
            check(p19cNear(at("red"), red), "p19c png: the red picture is where it is (\(String(describing: at("red"))) for \(String(describing: red)))")
            check(p19cNear(at("capture"), blue), "p19c png: the live Capture shows its last picture (\(String(describing: at("capture"))) for \(String(describing: blue)))")
            check(p19cNear(at("capture", 1, 0, inset: 30), blue),
                  "p19c png: …without the Live chip in its corner (\(String(describing: at("capture", 1, 0, inset: 30))))")
            let green = EaselLook(palette: .chill, dark: false).color(.lightGreen).usingColorSpace(.sRGB)!
            let look = e.look
            let lg = look.color(.lightGreen).usingColorSpace(.sRGB)!
            check(p19cNear(at("shape"), Int(lg.redComponent * 255), Int(lg.greenComponent * 255), Int(lg.blueComponent * 255)),
                  "p19c png: the shape's fill (\(String(describing: at("shape"))), light green \(Int(green.redComponent * 255)))")
            let rs = NSBitmapImageRep(data: (try? Data(contentsOf: sel)) ?? Data()), pxs = P19cPixels(try? Data(contentsOf: sel))
            check(rs?.pixelsWide == 208 && rs?.pixelsHigh == 148, "p19c png: a selection is its own size (\(rs?.pixelsWide ?? 0)×\(rs?.pixelsHigh ?? 0) for 160×100 pt + margins)")
            check(p19cNear(p19cPixel(pxs, 104, 74), Int(lg.redComponent * 255), Int(lg.greenComponent * 255), Int(lg.blueComponent * 255)),
                  "p19c png: …and holds only it")
        }

        // MARK: Copy Image
        run { [self] in
            let before = NSPasteboard.general.changeCount
            editor?.selection = []
            editor?.copyImage()
            let pb = NSPasteboard.general
            let png = pb.data(forType: .png).flatMap(NSBitmapImageRep.init(data:))
            check(pb.changeCount != before && png != nil && pb.data(forType: .tiff) != nil,
                  "p19c copy: Copy Image puts PNG and TIFF on the clipboard (change \(before)→\(pb.changeCount))")
            if let b = doc.contentBounds { check(abs(Double(png?.pixelsWide ?? 0) - ((b.width + 48) * 2).rounded(.up)) <= 1, "p19c copy: …the whole Easel at 2× (\(png?.pixelsWide ?? 0) px)") }
        }

        // MARK: The web page ZIP
        step { [self] done in
            let zip = s.tmp.appendingPathComponent("board.zip")
            editor?.write(.html, ids: nil, to: zip) { ok in
                self.check(ok, "p19c html: the web page ZIP is written")
                done()
            }
        }
        run { [self] in
            let zip = (try? Data(contentsOf: s.tmp.appendingPathComponent("board.zip"))) ?? Data()
            guard let entries = ZipReader.entries(zip) else { return check(false, "p19c html: the ZIP reads back (CRCs good)") }
            let names = entries.map(\.name)
            check(names.first == "Trip board/index.html" && names.contains("Trip board/easel.json") && names.allSatisfy { ZipWriter.isSafeName($0) && $0.hasPrefix("Trip board/") },
                  "p19c html: one folder named after the Easel with index.html, easel.json and assets/ (\(names.count) files)")
            let pictures = entries.filter { $0.name.hasPrefix("Trip board/assets/") }
            check(pictures.count == (s.ids["heic"] == nil ? 2 : 3) && pictures.allSatisfy { ["png", "jpg"].contains(EaselPublic.pictureType($0.data) ?? "") && $0.name.hasSuffix(EaselPublic.pictureName($0.data) ?? "?") },
                  "p19c html: its pictures are PNG or JPEG named by their bytes (HEIC converted: \(pictures.map { $0.name.split(separator: ".").last ?? "" }))")
            let json = entries.first { $0.name.hasSuffix("easel.json") }.flatMap { try? JSONDecoder().decode(EaselPublic.self, from: $0.data) }
            check(json?.blocks.count == doc.blocks.count && json?.blocks.contains { $0.content.type == "capture" && $0.content.url == "https://example.com/stats" } == true,
                  "p19c html: easel.json has every block; the live Capture is its picture and its page's address")
            let text = String(decoding: zip, as: UTF8.self)
            let leaks = (secrets + [profile(), "profileID", "Cookie"]).filter { text.contains($0) }
            check(leaks.isEmpty, "p19c html: no session token, password, profile or cookie anywhere in the ZIP (found: \(leaks))")
            // Unzipped, as anyone would.
            let folder = s.tmp.appendingPathComponent("unzipped", isDirectory: true)
            for e in entries {
                let u = folder.appendingPathComponent(e.name)
                try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? e.data.write(to: u)
            }
            s.ids["index"] = folder.appendingPathComponent("Trip board/index.html").path
        }
        // Offline, in a WebKit view of its own (no network, no data).
        step { [self] done in
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: config)
            s.web = web
            let index = URL(fileURLWithPath: s.ids["index"] ?? "/")
            web.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
            waitUntil({ !web.isLoading && web.url != nil }, timeout: 10) { DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: done) }
        }
        step { [self] done in
            s.web?.evaluateJavaScript(Self.p19cProbe) { r, _ in
                s.results["webkit"] = (r as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
                done()
            }
        }
        run { [self] in
            let r = s.results["webkit"] as? [String: Any] ?? [:]
            let imgs = r["imgs"] as? Int ?? -1
            check(r["board"] as? Bool == true && (r["blocks"] as? Int ?? 0) >= doc.blocks.count && imgs >= 2 && r["loaded"] as? Int == imgs && r["scripts"] as? Int == 0,
                  "p19c html: opened offline from its folder (WebKit), the board has every block and all \(imgs) pictures load; no scripts (\(r))")
            check(r["blank"] as? Bool == true && (r["links"] as? [String] ?? []).contains("https://example.com/doc?id=7"),
                  "p19c html: links open in a new tab without a referrer, cleaned of their password and session")
            s.web = nil
        }
        // In this window's engine, too (a tab on the file).
        run { [self] in
            guard let t = try? c.store.openTab(url: URL(fileURLWithPath: s.ids["index"] ?? "/").absoluteString, inSpace: c.currentSpaceID, title: "index.html") else { return }
            s.ids["fileTab"] = t.id
            c.reloadAll(animated: false)
            c.show(t.id, focus: false)
        }
        step { [self] done in waitUntil({ self.c.engineTab(for: s.ids["fileTab"] ?? "")?.isLoading == false }, timeout: 10) { DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: done) } }
        step { [self] done in
            guard let t = c.engineTab(for: s.ids["fileTab"] ?? "") else { check(false, "p19c html: the engine tab on the file"); return done() }
            t.evaluate(Self.p19cProbe) { r in
                s.results["engine"] = (r as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
                done()
            }
        }
        run { [self] in
            let r = s.results["engine"] as? [String: Any] ?? [:]
            let imgs = r["imgs"] as? Int ?? -1
            check(r["board"] as? Bool == true && imgs >= 2 && r["loaded"] as? Int == imgs && (r["width"] as? Double ?? 0) > 100,
                  "p19c html: …and in this window's engine (\(LaunchOptions.current.engine)), every picture loaded (\(r))")
            if let t = s.ids["fileTab"] { c.closeTab(t) }
            c.show(s.easelTab, focus: false)
        }
        wait(0.4)

        // MARK: Menus: File, the Command Bar, the canvas and the toolbar
        run { [self] in
            let file = NSApp.mainMenu?.items.first { $0.submenu?.title == "File" }?.submenu
            file?.update()
            let export = file?.items.first { $0.title == "Export Easel…" }, share = file?.items.first { $0.title == "Share Easel…" }
            check(export?.isEnabled == true && share?.isEnabled == true, "p19c menus: File › Export Easel… and Share Easel… with an Easel shown")
            let cmd = c.noteCommandActions().map(\.title)
            check(cmd.contains("Share Easel…") && cmd.contains("Export Easel…"), "p19c menus: the Command Bar offers Share Easel… and Export Easel…")
            let canvas = editor?.view.canvas
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            let titles = event.flatMap { canvas?.menu(for: $0) }?.items.map(\.title) ?? []
            check(titles.contains("Copy Easel as Image") && titles.contains("Export as Image…") && titles.contains("Export as Web Page…")
                  && titles.contains("Share Link…"), "p19c menus: the canvas menu has Copy as Image, Arc's Export as Image… and Export as Web Page…, and Share Link…")
            check(editor?.view.toolbar.subviews.first.map { $0.subviews.contains { $0.accessibilityIdentifier() == "easel.share" } } == true,
                  "p19c menus: the toolbar has Share and Export")
            // A web page: none of them.
            guard let t = try? c.store.openTab(url: "about:blank", inSpace: c.currentSpaceID, title: "Blank") else { return }
            s.ids["web"] = t.id
            c.reloadAll(animated: false)
            c.show(t.id, focus: false)
            file?.update()
            check(export?.isEnabled == false && share?.isEnabled == false && !c.noteCommandActions().map(\.title).contains("Share Easel…"),
                  "p19c menus: …not on a web page")
        }

        // MARK: L05: a Today Easel row's menu has no Add Split View
        run { [self] in
            guard let today = try? c.store.reopenEasel(s.easelID, title: "Trip board", inSpace: c.currentSpaceID), let web = s.ids["web"].flatMap({ c.store.tab($0) }) else {
                return check(false, "p19c L05: a Today row of the Easel")
            }
            s.ids["todayEasel"] = today.id
            let easelMenu = c.menu(for: .today(today)).items.map(\.title), webMenu = c.menu(for: .today(web)).items.map(\.title)
            check(!easelMenu.contains("Add Split View") && easelMenu.contains("Duplicate"), "p19c L05: a Today Easel row's menu has no Add Split View (\(easelMenu.prefix(8)))")
            check(webMenu.contains("Add Split View"), "p19c L05: …a web page's Today row still has it")
            c.closeTab(web.id)
            c.show(s.easelTab, focus: false)
        }
        wait(0.3)

        // MARK: Library › Easels: Share Link… (and Export…) open the Easel and its sheet
        run { [self] in
            guard let sum = EaselCenter.shared.files.list().first(where: { $0.id == s.easelID }) else { return check(false, "p19c library: the Easel is listed") }
            check(LibraryEasels.export(sum, in: c, link: true), "p19c library: Share Link… from Library › Easels opens the Easel")
        }
        step { [self] done in waitUntil({ EaselShareSheet.active[ObjectIdentifier(self.c.window)]?.easelID == s.easelID }, timeout: 5) { done() } }
        run { [self] in
            check(EaselShareSheet.active[ObjectIdentifier(c.window)]?.easelID == s.easelID && c.shownEasel?.easelID == s.easelID,
                  "p19c library: …with its Share sheet over it")
            EaselShareSheet.active[ObjectIdentifier(c.window)]?.close()
        }
        wait(0.4)

        // MARK: Share Link…
        if canPublish {
            run { [self] in editor?.shareLink() }
            step { [self] done in waitUntil({ EaselShareSheet.active[ObjectIdentifier(self.c.window)]?.phase == .preview }, timeout: 15) { DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: done) } }
            step { [self] done in
                guard let sheet = EaselShareSheet.active[ObjectIdentifier(c.window)] else { check(false, "p19c share: the sheet opens"); return done() }
                s.outgoing = sheet.outgoing
                sheet.preview.evaluateJavaScript(Self.p19cProbe) { r, _ in
                    s.results["preview"] = (r as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
                    done()
                }
            }
            run { [self] in
                guard let sheet = EaselShareSheet.active[ObjectIdentifier(c.window)], let out = s.outgoing else { return check(false, "p19c share: the sheet has what it will publish") }
                let r = s.results["preview"] as? [String: Any] ?? [:]
                let imgs = r["imgs"] as? Int ?? -1
                check(sheet.problem == nil && r["board"] as? Bool == true && imgs >= 2 && r["loaded"] as? Int == imgs,
                      "p19c share: the preview is the page as it will be published, its pictures loaded (\(r))")
                check(sheet.leftOutText.contains("2 addresses lost their sign-in or session parts") && sheet.leftOutText.contains("1 Live Capture goes as its last picture"),
                      "p19c share: it says what's changed and left out (\(sheet.leftOutText))")
                let json = String(decoding: (try? out.easel.encoded()) ?? Data(), as: UTF8.self)
                check(!secrets.contains { json.contains($0) } && !json.contains(profile()), "p19c share: nothing private in what will be sent")
                check(SharingCenter.shared.links(of: s.easelID).isEmpty, "p19c share: nothing is sent before Create Link")
            }
            capture("p19c-share-preview")
            run { [self] in EaselShareSheet.active[ObjectIdentifier(c.window)]?.create() }
            step { [self] done in waitUntil({ EaselShareSheet.active[ObjectIdentifier(self.c.window)]?.published != nil || EaselShareSheet.active[ObjectIdentifier(self.c.window)]?.message != nil }, timeout: 45) { done() } }
            run { [self] in
                let sheet = EaselShareSheet.active[ObjectIdentifier(c.window)]
                s.record = sheet?.published
                check(s.record != nil, "p19c share: Create Link publishes (\(sheet?.message ?? "ok"))")
                if let r = s.record {
                    check(r.kind == .easel && r.sourceID == s.easelID && r.url.path == "/e/\(r.id)" && SharingCenter.shared.holdsToken(for: r.id),
                          "p19c share: the link is /e/<id>, recorded for this Easel, its token held (\(r.url.absoluteString))")
                }
            }
            capture("p19c-share-published")
            step { [self] done in
                guard let r = s.record else { return done() }
                p19cFetch(r.url) { st, d, type, csp in
                    s.fetched["page"] = (st, d, type, csp)
                    let api = base.appendingPathComponent("api/easel").absoluteString + "?id=\(r.id)"
                    self.p19cFetch(URL(string: api)!) { st, d, type, csp in
                        s.fetched["api"] = (st, d, type, csp)
                        let name = s.outgoing?.easel.assets.first?.name ?? ""
                        self.p19cFetch(r.url.appendingPathComponent("a").appendingPathComponent(name)) { st, d, type, csp in
                            s.fetched["picture"] = (st, d, type, csp)
                            done()
                        }
                    }
                }
            }
            run { [self] in
                guard s.record != nil, let out = s.outgoing else { return }
                let page = s.fetched["page"], html = String(decoding: page?.1 ?? Data(), as: UTF8.self)
                check(page?.0 == 200 && html.contains("Shared Easel") && html.contains("Trip board") && html.contains("Pastéis de nata")
                      && html.contains("href=\"https://example.com/doc?id=7\"")
                      && html.components(separatedBy: "src=\"/e/\(s.record?.id ?? "")/a/").count - 1 == out.easel.blocks.filter { $0.content.asset != nil }.count,
                      "p19c share: the /e page renders the Easel's blocks as HTML (status \(page?.0 ?? 0), \(html.count) chars)")
                check(!secrets.contains { html.contains($0) } && !html.contains("<script") && page?.3.contains("default-src 'none'") == true,
                      "p19c share: …no secrets, no scripts, a strict CSP")
                let pic = s.fetched["picture"], name = out.easel.assets.first?.name ?? ""
                check(pic?.0 == 200 && pic?.1 == out.pictures[name] && (pic?.2 ?? "").hasPrefix("image/"), "p19c share: its pictures are the bytes sent (\(pic?.2 ?? ""), \(pic?.1.count ?? 0) bytes)")
                let api = s.fetched["api"]
                let top = api.flatMap { try? JSONSerialization.jsonObject(with: $0.1) as? [String: Any] }
                let easel = (top?["easel"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { try? JSONDecoder().decode(EaselPublic.self, from: $0) }
                check(api?.0 == 200 && easel == out.easel, "p19c share: the service holds exactly the Easel sent (round trip)")
                EaselShareSheet.active[ObjectIdentifier(c.window)]?.close()
            }
            wait(0.4)
            // Opened again: the link is listed; Take Back from there.
            run { [self] in editor?.shareLink() }
            step { [self] done in waitUntil({ EaselShareSheet.active[ObjectIdentifier(self.c.window)]?.phase == .preview }, timeout: 15) { done() } }
            run { [self] in
                guard let sheet = EaselShareSheet.active[ObjectIdentifier(c.window)], let r = s.record else { return check(false, "p19c share: the sheet opens again") }
                check(sheet.earlier.map(\.id) == [r.id], "p19c share: the sheet lists the link made earlier")
                sheet.takeBack(r, confirmed: true)
            }
            step { [self] done in waitUntil({ EaselShareSheet.active[ObjectIdentifier(self.c.window)]?.earlier.isEmpty == true }, timeout: 20) { done() } }
            step { [self] done in
                guard let r = s.record else { return done() }
                p19cFetch(r.url) { st, d, type, csp in
                    s.fetched["page2"] = (st, d, type, csp)
                    let name = s.outgoing?.easel.assets.first?.name ?? ""
                    self.p19cFetch(r.url.appendingPathComponent("a").appendingPathComponent(name)) { st, d, type, csp in
                        s.fetched["picture2"] = (st, d, type, csp)
                        self.p19cFetch(URL(string: base.appendingPathComponent("api/easel").absoluteString + "?id=\(r.id)")!) { st, d, type, csp in
                            s.fetched["api2"] = (st, d, type, csp)
                            done()
                        }
                    }
                }
            }
            run { [self] in
                guard let r = s.record else { return }
                check(s.fetched["page2"]?.0 == 404 && String(decoding: s.fetched["page2"]?.1 ?? Data(), as: UTF8.self).contains("taken back")
                      && s.fetched["picture2"]?.0 == 404 && s.fetched["api2"]?.0 == 404,
                      "p19c share: Take Back makes the page, its pictures and the API 404 (\(s.fetched["page2"]?.0 ?? 0), \(s.fetched["picture2"]?.0 ?? 0), \(s.fetched["api2"]?.0 ?? 0))")
                check(!SharingCenter.shared.holdsToken(for: r.id) && SharingCenter.shared.links(of: s.easelID).isEmpty, "p19c share: …and this Mac forgets the link and its token")
                EaselShareSheet.active[ObjectIdentifier(c.window)]?.close()
            }
        }

        // MARK: Undoing an ⌥-drag copy of an Easel row deletes the copied Easel
        run { [self] in
            guard let t = s.ids["todayEasel"], let made = try? c.store.copy(.tab(t), to: .today(spaceID: c.currentSpaceID, index: 0)),
                  let copy = EaselURL.easelID(c.store.tab(made)?.url), copy != s.easelID else { return check(false, "p19c undo: ⌥-drag copies the Easel row") }
            s.ids["copy"] = copy
            c.reloadAll(animated: false)
            c.show(made, focus: false)
            check(EaselCenter.shared.files.exists(copy), "p19c undo: the copy has an Easel of its own on disk")
        }
        wait(0.6)
        run { [self] in
            check(EaselCenter.shared.existingEditor(s.ids["copy"] ?? "") != nil, "p19c undo: …shown, with an editor")
            c.undo()
        }
        wait(2.5)   // past the editor's save delay: nothing writes it back
        run { [self] in
            let copy = s.ids["copy"] ?? ""
            check(!FileManager.default.fileExists(atPath: EaselCenter.shared.files.folder(copy).path), "p19c undo: ⌘Z of the copy deletes the copied Easel's folder")
            check(EaselCenter.shared.existingEditor(copy) == nil && !EaselCenter.shared.files.list().contains { $0.id == copy } && EaselCenter.shared.files.exists(s.easelID),
                  "p19c undo: …its editor is gone, Library › Easels doesn't list it, the original stays")
        }

        // The board, for the record.
        run { [self] in
            if let t = s.ids["todayEasel"] { c.closeTab(t) }
            c.show(s.easelTab, focus: false)
            editor?.selection = []
            editor?.view.canvas.zoomToFit(animated: false)
        }
        wait(0.6)
        capture("p19c-board")
        run { [self] in
            if let tmp = s.tmp { try? FileManager.default.removeItem(at: tmp) }
        }
    }

    private func id(_ s: P19c) -> String { s.easelID }
}
#endif
