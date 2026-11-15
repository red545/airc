// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit
import UniformTypeIdentifiers
import WebKit

/// P19d, "Add to Airc" for a shared Easel link, on either engine, with real driver input (AIRC_REAL_KEYS=1, a dedicated
/// session under the UI lock):
///   - A fixture Easel (text with marks and a link, a PNG and a JPEG picture, shapes, an arrow, a link card with a
///     picture, a Capture) is published to the configured sharing service (AIRC_SHARING_BASE: the local sharing-dev
///     server or a Preview; never aircbrowser.com). Its /e/<id> page has Add to Airc → airc://easel/<id>.
///   - Typed into a new tab with real keys, the link opens the import sheet over its page: the board loads in the
///     preview (pictures loaded, no scripts), nothing is added yet. A real click on Add Easel adds it.
///   - The local Easel shows the same items: its blocks, shared again, are exactly the published form; its pictures
///     are the bytes published; the canvas draws them (the red picture and the shape's fill where they are). It's the
///     person's own: a new id, no link record, not live; ⌘Z (real key) takes the row back.
///   - airc://easel/<id> from another app (the app's own handler, as a GURL event) opens the sheet; a real Escape cancels
///     and nothing is added. A link that was taken back says so, and Add Easel stays off.
extension SnapshotRunner {
    func parityP19dScenario() {
        // Off-main watchdog: a check app never outlives its check (common.md, 06:50).
        let file = dir.appendingPathComponent("log.txt"), name = script
        DispatchQueue.global().asyncAfter(deadline: .now() + 280) {
            let previous = (try? String(contentsOf: file, encoding: .utf8)).map { $0 + "\n" } ?? ""
            try? (previous + "[\(name)]\nFAIL \(name): the main thread was stuck past 280 s (off-main watchdog quit the app)").write(to: file, atomically: true, encoding: .utf8)
            exit(70)
        }
        parityP19dMain()
    }

    private final class P19d {
        var published: EaselPublic?
        var pictures: [String: Data] = [:]
        var link: SharingService.Published?
        var added = ""
        var pinnedBefore = 0
        var easelsBefore = 0
        var probe: [String: Any] = [:]
        var page = ""
        var undoBefore = ""
    }

    /// A solid picture `w`×`h` of (r, g, b) as `type`.
    private func p19dPicture(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ w: Int, _ h: Int, _ type: UTType) -> Data? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        guard let img = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// The fixture: every kind of item a shared Easel can hold, in the public form, with its pictures by name.
    private func p19dFixture() -> (EaselPublic, [String: Data])? {
        guard let red = p19dPicture(0.9, 0.1, 0.1, 400, 240, .png), let blue = p19dPicture(0.1, 0.3, 0.95, 320, 200, .jpeg),
              let rn = EaselPublic.pictureName(red), let bn = EaselPublic.pictureName(blue) else { return nil }
        let ra = "a" + String(rn.dropFirst()), ba = "b" + String(bn.dropFirst())
        var d = EaselDocument(id: "p19d-fixture", title: "Shared trip board", palette: .chill)
        let text = NoteDocument(blocks: [NoteBlock(kind: .heading1, runs: [NoteRun("Lisbon", marks: [.bold])]),
                                         NoteBlock(kind: .checkbox, checked: true, runs: [NoteRun("Book the "), NoteRun("tram", marks: [.italic], link: "https://example.com/tram")]),
                                         NoteBlock(kind: .bullet, indent: 1, runs: [NoteRun("Pastéis de nata")])])
        d.add(EaselBlock(frame: EaselRect(x: 0, y: 0, width: 300, height: 120), content: .text(EaselText(text, size: 20, color: .darkBlue))))
        d.add(EaselBlock(frame: EaselRect(x: 340, y: 0, width: 200, height: 120), rotation: 0.15,
                         content: .image(EaselImage(asset: ra, pixelWidth: 400, pixelHeight: 240, altText: "Red tram"))))
        d.add(EaselBlock(frame: EaselRect(x: 0, y: 160, width: 160, height: 100), content: .shape(EaselShape(.rectangle, fill: .lightGreen, cornerRadius: 12))))
        d.add(EaselBlock(frame: EaselRect(x: 180, y: 160, width: 100, height: 100), content: .shape(EaselShape(.ellipse, stroke: .pink, strokeWidth: 4))))
        d.add(EaselBlock(frame: .init(x: 0, y: 0, width: 1, height: 1),
                         content: .line(EaselLine(from: EaselPoint(300, 200), to: EaselPoint(420, 260), endHead: true, color: .red, width: 4))))
        d.add(EaselBlock(frame: EaselRect(x: 0, y: 300, width: 320, height: 96),
                         content: .link(EaselLink(url: "https://example.com/doc?id=7", title: "Itinerary", detail: "Day one\nDay two", image: ba))))
        d.add(EaselBlock(frame: EaselRect(x: 360, y: 300, width: 320, height: 200),
                         content: .capture(EaselCapture(asset: ba, pixelWidth: 320, pixelHeight: 200, url: "https://example.com/map", title: "Map"))))
        var (p, report) = EaselPublic.make(d)
        p = p.settingPictures([ra: .init(name: rn, size: red.count), ba: .init(name: bn, size: blue.count)], report: &report)
        return (p, [rn: red, bn: blue])
    }

    private static let p19dProbe = """
    JSON.stringify({ board: !!document.querySelector('.easel'), blocks: document.querySelectorAll('.easel .b').length,
      imgs: document.images.length, loaded: [...document.images].filter(i => i.complete && i.naturalWidth > 0).length,
      scripts: document.scripts.length })
    """

    private func parityP19dMain() {
        let s = P19d()
        let service = SharingCenter.shared.service
        let base = service.base
        var sheet: EaselImportSheet? { EaselImportSheet.active[ObjectIdentifier(c.window)] }
        let files = EaselCenter.shared.files
        func pinnedCount() -> Int { c.store.children(of: .pinned(spaceID: c.currentSpaceID), parent: nil).count }
        func easelCount() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: files.root.path))?.count ?? 0 }

        guard base.host?.hasSuffix("aircbrowser.com") == false else {
            run { [self] in check(false, "p19d: set AIRC_SHARING_BASE to a local server or a Preview (never Production)") }
            return
        }
        guard UIDriverClient.available, ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1" else {
            run { [self] in note("FAIL-ENV p19d: real input needs AIRC_REAL_KEYS=1, the stable UI driver and AIRC_UI_DEDICATED_SESSION=1") }
            return
        }
        func activate() {
            step { [self] done in
                NSApp.activate(ignoringOtherApps: true)
                c.window.makeKeyAndOrderFront(nil)
                waitUntil({ NSApp.isActive && self.c.window.isKeyWindow }, timeout: 3) {
                    if !(NSApp.isActive && self.c.window.isOnActiveSpace) {
                        self.note("FAIL-ENV p19d: real input needs the window key (active \(NSApp.isActive), key \(self.c.window.isKeyWindow), Space \(self.c.window.isOnActiveSpace))")
                    }
                    done()
                }
            }
        }
        /// Real keys to this app (PID-targeted, foreground only).
        func keys(_ combos: [String], _ what: String) {
            step { [self] done in
                UIDriverClient.press(combos, pid: getpid()) { ok, out in
                    self.check(ok, "p19d [real keys, PID-targeted] \(what)\(ok ? "" : ": \(out)")")
                    done()
                }
            }
        }
        /// A real click on the sheet's control `anchor`.
        func click(_ anchor: String, _ what: String) {
            step { [self] done in
                guard let sh = sheet, let host = sh.sheet.contentView, let f = TestAnchors.frame(anchor, in: host) else {
                    check(false, "p19d [real click] \(what): \(anchor) is on screen"); return done()
                }
                let p = host.convert(NSPoint(x: f.midX, y: f.midY), to: nil)
                sh.sheet.makeKey()
                waitUntil({ sh.sheet.isKeyWindow && NSApp.isActive }, timeout: 2) {
                    guard let primary = NSScreen.screens.first, sh.sheet.isKeyWindow else {
                        self.check(false, "p19d [real click] \(what): the sheet is the key window"); return done()
                    }
                    // A real move onto the button first, then a real click there (no modifiers).
                    UIDriverClient.move(p, in: sh.sheet) { moved, mout in
                        let g = sh.sheet.convertPoint(toScreen: p)
                        UIDriverClient.run(["--click", String(Double(g.x)), String(Double(primary.frame.maxY - g.y))]) { ok, out in
                            self.check(moved && ok, "p19d [real move and click] \(what)\(moved && ok ? "" : ": \(mout) \(out)")")
                            done()
                        }
                    }
                }
            }
        }

        // MARK: The fixture, published
        step { [self] done in
            note("p19d: sharing service \(base.absoluteString)")
            guard let (p, pictures) = p19dFixture() else { check(false, "p19d: the fixture's pictures"); return done() }
            s.published = p
            s.pictures = pictures
            Task { @MainActor in
                do {
                    s.link = try await service.publishEasel(p, pictures: pictures)
                } catch {
                    self.check(false, "p19d: the fixture is published (\(error.localizedDescription))")
                }
                done()
            }
        }
        step { [self] done in
            guard let l = s.link else { return done() }
            check(HostedEaselLink.id(from: l.url, service: base) == l.id, "p19d: the fixture's link is an Easel link of the service (\(l.url.absoluteString))")
            var r = URLRequest(url: l.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            r.httpShouldHandleCookies = false
            for (k, v) in service.extraHeaders { r.setValue(v, forHTTPHeaderField: k) }
            URLSession(configuration: .ephemeral).dataTask(with: r) { data, _, _ in
                let text = String(decoding: data ?? Data(), as: UTF8.self)
                DispatchQueue.main.async {
                    s.page = text
                    done()
                }
            }.resume()
        }
        run { [self] in
            guard let l = s.link else { return }
            check(s.page.contains("<a class=\"btn-open\" href=\"airc://easel/\(l.id)\">Add to Airc</a>"), "p19d page: /e/<id> has Add to Airc → airc://easel/<id>")
            check(!s.page.lowercased().contains("<script"), "p19d page: …and still no scripts")
            s.pinnedBefore = pinnedCount()
            s.easelsBefore = easelCount()
        }

        // MARK: Typed into a new tab, with real keys
        activate()
        step { [self] done in
            guard let l = s.link, let typed = UIDriverClient.keys(typing: l.url.absoluteString) else {
                check(false, "p19d: the link can be typed on this layout (\(UIDriverClient.layoutName))"); return done()
            }
            UIDriverClient.press(["cmd+t"] + typed + ["return"], pid: getpid()) { ok, out in
                self.check(ok, "p19d [real keys, PID-targeted] ⌘T, the link, Return (\(UIDriverClient.layoutName))\(ok ? "" : ": \(out)")")
                done()
            }
        }
        step { [self] done in waitUntil({ sheet?.phase == .ready }, timeout: 20) { done() } }
        step { [self] done in
            guard let sh = sheet else {
                check(false, "p19d open: the typed link opens the import sheet (tab \(c.store.tab(c.shownTabID)?.url ?? "-"), error \(EaselImportSheet.lastError ?? "-"))")
                return done()
            }
            check(sh.phase == .ready && sh.easel == s.published, "p19d open: the sheet holds exactly the shared Easel, checked (\(sh.summary))")
            check(sh.title == "Shared trip board" && sh.summary == "7 items · 2 pictures", "p19d open: its title and summary (\(sh.title), \(sh.summary))")
            check(c.store.tab(c.shownTabID)?.url.hasSuffix("/e/\(s.link?.id ?? "?")") == true, "p19d open: …over the link's page in the new tab")
            check(pinnedCount() == s.pinnedBefore && easelCount() == s.easelsBefore, "p19d open: nothing is added before Add Easel")
            // Poll until every picture has loaded (or 8 s), so a slow decode isn't read as a missing picture.
            let deadline = Date().addingTimeInterval(8)
            func probe() {
                sh.preview.evaluateJavaScript(Self.p19dProbe) { r, _ in
                    s.probe = (r as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
                    let imgs = s.probe["imgs"] as? Int ?? 0, loaded = s.probe["loaded"] as? Int ?? -1
                    if (imgs >= 3 && loaded == imgs) || Date() > deadline { return done() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: probe)
                }
            }
            waitUntil({ !sh.preview.isLoading && sh.preview.url != nil }, timeout: 5) { probe() }
        }
        wait(0.6)
        run { [self] in
            let p = s.probe
            check(p["board"] as? Bool == true && p["blocks"] as? Int == 7, "p19d preview: the board as the shared page draws it (\(p))")
            check((p["imgs"] as? Int ?? 0) >= 3 && p["loaded"] as? Int == p["imgs"] as? Int, "p19d preview: every picture loaded from the checked bytes")
            check(p["scripts"] as? Int == 0 && sheet?.preview.configuration.defaultWebpagePreferences.allowsContentJavaScript == false,
                  "p19d preview: no scripts, JavaScript off")
            check(sheet?.destination == c.currentSpaceID, "p19d preview: it goes to this Space unless another is picked")
        }

        // MARK: Add Easel, a real click
        click("easelImport.add", "Add Easel")
        step { [self] done in waitUntil({ sheet == nil && EaselImportSheet.lastAdded != nil }, timeout: 5) { done() } }
        wait(0.8)
        run { [self] in
            guard let id = EaselImportSheet.lastAdded else { return check(false, "p19d add: Add Easel adds it (\(sheet?.message ?? "no message"))") }
            s.added = id
            check(sheet == nil, "p19d add: the sheet closed")
            check(pinnedCount() == s.pinnedBefore + 1 && easelCount() == s.easelsBefore + 1, "p19d add: one new pinned row and one new Easel folder")
            let row = c.store.tab(c.shownTabID)
            check(EaselURL.easelID(row?.url) == id && row?.title == "Shared trip board", "p19d add: the new Easel is shown, named as shared (\(row?.title ?? "-"))")
            check(c.shownEasel?.easelID == id, "p19d add: …its canvas in the page card")
        }
        run { [self] in
            guard let p = s.published, !s.added.isEmpty else { return }
            let doc = EaselCenter.shared.existingEditor(s.added)?.document ?? files.load(s.added).document
            check(doc.blocks.count == 7 && Set(doc.stacked.map(\.content.type)) == ["text", "image", "shape", "line", "link", "capture"],
                  "p19d same: the local Easel has the same 7 items (\(doc.stacked.map(\.content.type)))")
            var assets: [String: EaselPublic.Asset] = [:]
            var bytesSame = true
            for a in p.assets {
                let d = files.assetURL(s.added, a.name).flatMap { try? Data(contentsOf: $0) }
                bytesSame = bytesSame && d == s.pictures[a.name]
                assets[a.name] = .init(name: a.name, size: d?.count ?? 0)
            }
            check(bytesSame, "p19d same: its pictures are the bytes that were shared (\(p.assets.count))")
            var (again, report) = EaselPublic.make(doc)
            again = again.settingPictures(assets, report: &report)
            check(again == p, "p19d same: shared again, it's exactly the shared form (text, marks, links, colours, frames, turns)")
            check(doc.id != "p19d-fixture" && doc.id == s.added && SharingCenter.shared.links(of: s.added).isEmpty && doc.liveBlocks.isEmpty,
                  "p19d own: a new id, no link of its own, nothing live: not linked to the original")
        }
        // The canvas draws them: a picture of the Easel, the red picture and the green shape where they are.
        step { [self] done in
            guard let e = c.shownEasel, e.easelID == s.added else { check(false, "p19d draw: the canvas"); return done() }
            let png = FileManager.default.temporaryDirectory.appendingPathComponent("p19d-\(UUID().uuidString).png")
            e.write(.png1, ids: nil, to: png) { ok in
                defer { try? FileManager.default.removeItem(at: png) }
                guard ok, let data = try? Data(contentsOf: png), let src = CGImageSourceCreateWithData(data as CFData, nil),
                      let img = CGImageSourceCreateImageAtIndex(src, 0, nil), let bounds = e.document.contentBounds else {
                    self.check(false, "p19d draw: a picture of the local Easel"); return done()
                }
                var b = [UInt8](repeating: 0, count: img.width * img.height * 4)
                let ctx = CGContext(data: &b, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                ctx?.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
                func at(_ x: Double, _ y: Double) -> (Int, Int, Int) {
                    let xi = Int(x - bounds.x + EaselPicture.margin), yi = Int(y - bounds.y + EaselPicture.margin)
                    guard xi >= 0, yi >= 0, xi < img.width, yi < img.height else { return (-1, -1, -1) }
                    let i = (yi * img.width + xi) * 4
                    return (Int(b[i]), Int(b[i + 1]), Int(b[i + 2]))
                }
                let red = at(440, 60), green = at(80, 210), lg = e.look.color(.lightGreen).usingColorSpace(.sRGB)!
                self.check(abs(red.0 - 230) <= 14 && red.1 <= 40 && red.2 <= 40, "p19d draw: the red picture is drawn where it was shared (\(red))")
                self.check(abs(green.0 - Int(lg.redComponent * 255)) <= 12 && abs(green.1 - Int(lg.greenComponent * 255)) <= 12,
                           "p19d draw: the shape's light green fill (\(green))")
                done()
            }
        }
        // ⌘Z, a real key, takes the row back.
        run { [self] in
            s.undoBefore = c.store.undoLabel ?? "-"
            note("p19d undo: after Add, first responder \(c.window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")
            check(s.undoBefore == "Add Easel", "p19d undo: the add is the store's last undo step (\(s.undoBefore))")
        }
        run { [self] in c.window.makeFirstResponder(nil) }
        activate()
        run { [self] in note("p19d undo: first responder \(c.window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"), next undo \(c.store.undoLabel ?? "-")") }
        keys(["cmd+z"], "⌘Z")
        wait(0.6)
        run { [self] in
            check(!s.added.isEmpty && pinnedCount() == s.pinnedBefore, "p19d undo: ⌘Z (focus off the canvas) takes the added row back (\(pinnedCount()) rows, \(s.pinnedBefore) before the add; next undo then \(c.store.undoLabel ?? "-"))")
            check(files.exists(s.added), "p19d undo: …and the Easel itself stays on this Mac (Library › Easels)")
        }

        // MARK: airc://easel/<id> from another app; a real Escape cancels
        run { [self] in
            guard let l = s.link, let u = HostedEaselLink.appURL(id: l.id) else { return }
            s.pinnedBefore = pinnedCount()
            s.easelsBefore = easelCount()
            EaselImportSheet.lastAdded = nil
            app?.openFromOtherApp([u], source: "p19d-check")
        }
        step { [self] done in waitUntil({ sheet?.phase == .ready }, timeout: 15) { done() } }
        run { [self] in check(sheet?.easel == s.published, "p19d app link: airc://easel/<id> from another app opens the same sheet") }
        step { [self] done in
            guard let sh = sheet else { return done() }
            sh.sheet.makeKey()
            waitUntil({ sh.sheet.isKeyWindow }, timeout: 2) { done() }
        }
        keys(["escape"], "Escape")
        step { [self] done in waitUntil({ sheet == nil }, timeout: 3) { done() } }
        run { [self] in
            check(sheet == nil && EaselImportSheet.lastAdded == nil && pinnedCount() == s.pinnedBefore && easelCount() == s.easelsBefore,
                  "p19d app link: Escape cancels, and nothing is added")
        }

        // MARK: Taken back
        step { [self] done in
            guard let l = s.link else { return done() }
            Task { @MainActor in
                try? await service.revokeEasel(id: l.id, token: l.token)
                EaselImportSheet.lastError = nil
                ShareLinkImport.open(l.url, in: self.c)
                done()
            }
        }
        step { [self] done in waitUntil({ if case .failed = sheet?.phase { true } else { false } }, timeout: 15) { done() } }
        run { [self] in
            if case .failed(let why)? = sheet?.phase {
                check(why == SharingService.Failure.notFound.localizedDescription, "p19d gone: a link that was taken back says so (\(why))")
            } else {
                check(false, "p19d gone: a link that was taken back is refused (\(String(describing: sheet?.phase)))")
            }
            check(sheet?.easel == nil && pinnedCount() == s.pinnedBefore && easelCount() == s.easelsBefore, "p19d gone: …nothing from it can be added")
            sheet?.close()
        }
    }
}
#endif
