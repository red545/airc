// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit

/// `--script capture` (both engines): CB-5 Capture on a loopback page of four colour blocks (red, green, blue and yellow
/// quarters, with a dark box in the red one). Everything goes through Capture's own handlers: the overlay's press, drag
/// and release, the keys through the app's key monitor (posted key events), the bar's buttons. Copy writes to a
/// pasteboard of the run's own (never the owner's clipboard), Save to a scratch folder, Share to a recorded sheet.
///   - ⇧⌘2, the View menu item and the Command Bar action; the overlay covers the page card only, never the sidebar;
///   - a dragged rectangle: its size readout in points, Return, Copy: the PNG's pixel size at the backing scale and
///     the colour of each quarter; its resolution says that scale (144 dpi at 2×), so it reads back (NSImage, as a
///     Note does) at its size on screen, the TIFF too, as do the saved and shared files;
///   - Space for the whole visible page, Save: the file's name and size, its corners the page's colours (the sidebar on
///     the left, then on the right);
///   - moving and resizing by the handles; Esc cancels with nothing written, copied or counted;
///   - Share hands the sheet one PNG file; ⌘ picks the element under the pointer;
///   - an empty Space has nothing to capture; a private window captures but counts nothing;
///   - telemetry: copy, save and share only;
///   - Capture Full Page, 1×, page zoom, a save that fails, splits, a note in a split and Peek (CaptureParityCheck.swift);
///   - Capture in Portrait Mode (PortraitCaptureCheck.swift).
extension SnapshotRunner {
    func captureScenario() {
        var server: LocalPageServer?
        var base = ""
        var tabID = ""
        let scratch = dir.appendingPathComponent("capture-downloads", isDirectory: true)
        let board = NSPasteboard(name: NSPasteboard.Name("org.airc.test.capture.\(getpid())"))
        var used: [TelemetryFeature.CaptureAction] = []
        var shared: [Any] = []
        var session: CaptureSession?
        var privateWindow: PrivateWindowController?
        let active = { CaptureSession.active(in: self.c.window) }
        let overlay = { active()?.overlay }
        let scale = { self.c.window.backingScaleFactor }
        let page = """
        <title>Blocks</title><style>html,body{margin:0;height:100%;overflow:hidden}
        div{position:fixed;width:50vw;height:50vh}
        #r{left:0;top:0;background:#e53935}#g{right:0;top:0;background:#43a047}
        #b{left:0;bottom:0;background:#1e88e5}#y{right:0;bottom:0;background:#fdd835}
        #box{left:40px;top:40px;width:120px;height:80px;background:#111}</style>
        <div id=r></div><div id=g></div><div id=b></div><div id=y></div><div id=box></div>
        """
        typealias RGB = (r: Int, g: Int, b: Int)
        let red: RGB = (229, 57, 53), green: RGB = (67, 160, 71), blue: RGB = (30, 136, 229), yellow: RGB = (253, 216, 53)

        /// The pixels of a PNG in sRGB, top-left first.
        func decode(_ data: Data?) -> (w: Int, h: Int, px: [UInt8])? {
            guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            let w = img.width, h = img.height
            var px = [UInt8](repeating: 0, count: w * h * 4)
            guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return (w, h, px)
        }
        func color(_ d: (w: Int, h: Int, px: [UInt8]), _ fx: Double, _ fy: Double) -> RGB {
            let x = min(d.w - 1, max(0, Int(Double(d.w) * fx))), y = min(d.h - 1, max(0, Int(Double(d.h) * fy)))
            let i = (y * d.w + x) * 4
            return (Int(d.px[i]), Int(d.px[i + 1]), Int(d.px[i + 2]))
        }
        func near(_ a: RGB, _ b: RGB) -> Bool { abs(a.r - b.r) <= 40 && abs(a.g - b.g) <= 40 && abs(a.b - b.b) <= 40 }
        func describe(_ c: RGB) -> String { "rgb(\(c.r),\(c.g),\(c.b))" }
        /// The size an image file reads back at in points (NSImage honours its resolution, as a Note does), and its dpi.
        func points(_ data: Data?) -> CGSize? { data.flatMap(NSImage.init(data:))?.size }
        func dpi(_ data: Data?) -> String {
            guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return "-" }
            return "\(p[kCGImagePropertyDPIWidth] ?? "none") dpi"
        }
        func pt(_ s: CGSize?) -> String { s.map { "\($0.width) × \($0.height) pt" } ?? "-" }
        /// Each quarter of `d` (sampled at its quarter points) has the page's colour.
        func quarters(_ d: (w: Int, h: Int, px: [UInt8]), _ f: Double = 0.25) -> (Bool, String) {
            let got = [color(d, f, f), color(d, 1 - f, f), color(d, f, 1 - f), color(d, 1 - f, 1 - f)]
            let ok = zip(got, [red, green, blue, yellow]).allSatisfy { near($0, $1) }
            return (ok, got.map(describe).joined(separator: " "))
        }
        func files() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []).sorted() }
        /// The overlay as it looks (the window's root without page pixels, then the overlay's layers with the frozen page).
        func shoot(_ name: String) {
            guard let o = overlay(), let layer = o.layer else { return }
            let root = c.root
            o.isHidden = true
            let back = render(root)
            o.isHidden = false
            let size = root.bounds.size, s: CGFloat = 2
            guard let ctx = CGContext(data: nil, width: Int(size.width * s), height: Int(size.height * s), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            ctx.scaleBy(x: s, y: s)
            if let back, let cg = back.cgImage(forProposedRect: nil, context: nil, hints: nil) { ctx.draw(cg, in: CGRect(origin: .zero, size: size)) }
            ctx.saveGState()
            ctx.translateBy(x: o.frame.minX, y: size.height - o.frame.minY)
            ctx.scaleBy(x: 1, y: -1)
            MainActor.assumeIsolated { AircSnapshot.withoutDuplicates(in: o) { layer.render(in: ctx) } }
            ctx.restoreGState()
            if let img = ctx.makeImage() {
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
                note("wrote \(name).png")
            }
        }
        func start(_ how: String) {
            run { [self] in
                switch how {
                case "key": postKey("@", keyCode: 19, modifiers: [.command, .shift])
                case "View menu":
                    let item = NSApp.mainMenu?.item(withTitle: "View")?.submenu?.items.first { $0.title == "Capture…" }
                    (item as? CommandMenuItem)?.fire()
                case "Command Bar": c.commandActions().first { $0.title == "Capture…" }?.run()
                default: c.startCapture()
                }
            }
            step { [self] done in waitUntil({ active()?.picturesReady == true }, timeout: 8) { done() } }
            run { [self] in
                session = active()
                check(session != nil && session?.picturesReady == true && session?.shots.contains { $0.image != nil } == true,
                      "capture (\(how)): starts with the page's picture" + (session.map { s in
                          ", \(s.shots.count) page(s), picture \(s.shots.first?.image.map { "\($0.width)×\($0.height) px" } ?? "none")" } ?? ""))
            }
        }
        /// A drag through the overlay's own handlers, from `a` to `b` (overlay points).
        func drag(_ a: @escaping () -> CGPoint, _ b: @escaping () -> CGPoint) {
            run {
                guard let o = overlay() else { return }
                let p = a(), q = b()
                o.pressed(at: p)
                for k in 1...6 { o.dragged(to: CGPoint(x: p.x + (q.x - p.x) * CGFloat(k) / 6, y: p.y + (q.y - p.y) * CGFloat(k) / 6)) }
                o.released(at: q)
            }
        }

        // Setup: a loopback page, Capture's scratch places, recorded telemetry.
        step { [self] done in
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            CaptureSession.downloadsDirectory = { scratch }
            CaptureSession.pasteboard = { board }
            CaptureSession.recordUse = { used.append($0) }
            CaptureSession.presentShare = { _, items, _ in shared = items }
            server = LocalPageServer(responses: ["/blocks.html": .init(body: page)])
            server?.start { port in
                base = port.map { "http://localhost:\($0)" } ?? ""
                done()
            }
        }
        run { [self] in
            // A Capture's PNG at 2× and 1× (no window needed): its resolution is the scale, so it reads back at pixels / scale.
            let px = CGContext(data: nil, width: 400, height: 240, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
            let two = px.flatMap { CaptureSession.png($0, scale: 2) }, one = px.flatMap { CaptureSession.png($0, scale: 1) }
            check(decode(two).map { $0.w == 400 && $0.h == 240 } == true && points(two) == CGSize(width: 200, height: 120)
                  && points(one) == CGSize(width: 400, height: 240),
                  "capture: a 400 × 240 px Capture written at 2× reads back at \(pt(points(two))) (\(dpi(two))), at 1× "
                  + "\(pt(points(one))) (\(dpi(one)))")
        }
        run { [self] in
            guard !base.isEmpty else { return check(false, "capture: a loopback server") }
            tabID = (try? c.store.openTab(url: base + "/blocks.html", inSpace: c.currentSpaceID, title: "Blocks"))?.id ?? ""
            c.reloadAll(animated: false)
            c.show(tabID, focus: false)
        }
        step { [self] done in
            waitUntil({ self.c.engineTab(for: tabID)?.isLoading == false && self.c.engineTab(for: tabID)?.title == "Blocks" }, timeout: 10) { done() }
        }
        wait(1.0)
        run { [self] in
            let item = NSApp.mainMenu?.item(withTitle: "View")?.submenu?.items.first { $0.title == "Capture…" }
            check(item?.keyEquivalent == "2" && item?.keyEquivalentModifierMask == [.command, .shift], "capture: View › Capture… with ⇧⌘2")
            let action = c.commandActions().first { $0.title == "Capture…" }
            check(action?.hint == "⇧⌘2" && action?.keywords.contains("screenshot") == true, "capture: the Command Bar's Capture… action (⇧⌘2)")
            check(KeyReservation.of(KeyCombo("2", [.shift, .command])) == nil, "capture: ⇧⌘2 isn't a reserved key")
        }

        // 1. ⇧⌘2 (a posted key through the key monitor): the overlay over the card only.
        start("key")
        run { [self] in
            guard let o = overlay() else { return check(false, "capture: the overlay is up") }
            let sidebar = c.sidebar.frame
            check(o.superview === c.root && o.frame == c.card.frame && !o.frame.intersects(sidebar),
                  "capture: the overlay covers the page card \(NSStringFromRect(o.frame)), not the sidebar \(NSStringFromRect(sidebar))")
            check(c.window.firstResponder === o, "capture: the overlay has the keyboard (the page gets no keys)")
            let shot = session?.shots.first
            let expected = shot.map { CGSize(width: $0.frame.width * scale(), height: $0.frame.height * scale()) }
            check(shot?.image.map { CGSize(width: $0.width, height: $0.height) } == expected,
                  "capture: the engine's picture is the page at the backing scale (\(scale())×, \(expected.map { "\(Int($0.width))×\(Int($0.height))" } ?? "-"))")
        }
        // 2. A rectangle across the four blocks, its size, Return, Copy.
        drag({ CGPoint(x: (overlay()?.bounds.midX ?? 0) - 100, y: (overlay()?.bounds.midY ?? 0) - 60) },
             { CGPoint(x: (overlay()?.bounds.midX ?? 0) + 100, y: (overlay()?.bounds.midY ?? 0) + 60) })
        run { [self] in
            let sel = overlay()?.selection
            check(sel?.size == CGSize(width: 200, height: 120), "capture: the drag selects 200 × 120 pt (\(sel.map(NSStringFromRect) ?? "none"))")
            check(overlay()?.bar.isHidden == false && overlay()?.bar.captureButton.isHidden == false, "capture: the Capture button under the selection")
        }
        run { shoot("capture-selecting") }
        // Resize by a handle, move, then back.
        run { [self] in
            guard let o = overlay(), let sel = o.selection else { return }
            o.pressed(at: CGPoint(x: sel.maxX, y: sel.maxY))
            o.dragged(to: CGPoint(x: sel.maxX + 40, y: sel.maxY + 20))
            o.released(at: CGPoint(x: sel.maxX + 40, y: sel.maxY + 20))
            let resized = o.selection
            o.pressed(at: CGPoint(x: sel.midX, y: sel.midY))
            o.dragged(to: CGPoint(x: sel.midX + 30, y: sel.midY + 10))
            o.released(at: CGPoint(x: sel.midX + 30, y: sel.midY + 10))
            let moved = o.selection
            check(resized?.size == CGSize(width: 240, height: 140) && resized?.origin == sel.origin
                  && moved?.size == resized?.size && moved?.origin == CGPoint(x: sel.minX + 30, y: sel.minY + 10),
                  "capture: the corner handle resizes (\(resized.map(NSStringFromRect) ?? "-")) and a drag inside moves it (\(moved.map(NSStringFromRect) ?? "-"))")
            o.selection = sel
            o.update()
        }
        key("\r", 36)
        run { [self] in
            check(session?.phase == .confirmed && overlay()?.bar.copyButton.isHidden == false && overlay()?.bar.shareButton.isHidden == false,
                  "capture: Return confirms; the bar offers Copy, Save and Share")
        }
        run { shoot("capture-confirmed") }
        var copyCount = 0
        run { [self] in
            copyCount = board.changeCount
            overlay()?.bar.copyButton.action?()
        }
        wait(0.3)
        run { [self] in
            let png = board.data(forType: .png)
            let d = decode(png)
            let s = scale()
            check(board.changeCount != copyCount && d?.w == Int(200 * s) && d?.h == Int(120 * s),
                  "capture: Copy puts a \(d.map { "\($0.w)×\($0.h)" } ?? "no") px PNG on the pasteboard (200 × 120 pt at \(s)×)")
            if let d {
                let (ok, got) = quarters(d)
                check(ok, "capture: the copied picture's quarters are red, green, blue and yellow (\(got))")
            }
            check(board.types?.contains(.tiff) == true, "capture: TIFF offered too, for older apps")
            let tiff = board.data(forType: .tiff)
            check(points(png) == CGSize(width: 200, height: 120) && points(tiff) == CGSize(width: 200, height: 120),
                  "capture: the copied PNG reads back at its size on screen, \(pt(points(png))) (\(dpi(png)) at \(s)×), "
                  + "the TIFF too (\(pt(points(tiff))))")
            try? png?.write(to: dir.appendingPathComponent("capture-copied.png"))
            check(active() == nil && c.toast.shownText == "Copied Capture", "capture: Copy closes Capture with \"\(c.toast.shownText ?? "no toast")\"")
            check(used == [.copy], "capture: feature.used capture copy (\(used.map(\.rawValue)))")
        }
        wait(0.3)
        run { [self] in check(!c.root.subviews.contains { $0 is CaptureOverlayView }, "capture: the overlay is gone") }

        // 3. Space for the whole page, Save to (scratch) Downloads.
        for side in ["left", "right"] {
            run { [self] in if side == "right" { app?.setSidebarOnRight(true) } }
            wait(side == "right" ? 0.8 : 0)
            start(side == "left" ? "View menu" : "command")
            key(" ", 49)
            run { [self] in
                check(overlay()?.selection == overlay()?.bounds, "capture: Space selects the whole visible page (sidebar on the \(side))")
            }
            key("\r", 36)
            var before: [String] = []
            run { [self] in
                before = files()
                overlay()?.bar.saveButton.action?()
            }
            wait(0.3)
            run { [self] in
                let new = files().filter { !before.contains($0) }
                let s = scale()
                let d = new.first.flatMap { try? Data(contentsOf: scratch.appendingPathComponent($0)) }.flatMap(decode)
                let card = c.card.frame.size
                check(new.count == 1 && new.first?.hasPrefix("Capture localhost ") == true && new.first?.hasSuffix(".png") == true,
                      "capture: Save writes one file to Downloads: \(new.first ?? "none")")
                check(d?.w == Int(card.width * s) && d?.h == Int(card.height * s),
                      "capture: the whole page is the card's size at \(s)× (\(d.map { "\($0.w)×\($0.h)" } ?? "-") px), nothing beside it")
                let saved = new.first.flatMap { try? Data(contentsOf: scratch.appendingPathComponent($0)) }
                check(points(saved) == card, "capture: the saved file reads back at the card's size, \(pt(points(saved))) (\(dpi(saved)))")
                if let d {
                    // The corners are the page's own colours: no sidebar, no window background at either edge.
                    let (ok, got) = quarters(d, 0.004)
                    check(ok, "capture: the saved picture's edges are the page's (sidebar on the \(side)): \(got)")
                    let (inner, innerGot) = quarters(d, 0.25)
                    check(inner, "capture: and its quarters too: \(innerGot)")
                }
                check(active() == nil && c.toast.shownText == "Saved to Downloads", "capture: Save closes with \"\(c.toast.shownText ?? "no toast")\"")
                if side == "right" { app?.setSidebarOnRight(false) }
            }
            wait(side == "right" ? 0.8 : 0.2)
        }
        run { [self] in check(used == [.copy, .save, .save], "capture: two saves counted (\(used.map(\.rawValue)))") }

        // 4. Esc cancels: nothing written, copied or counted.
        start("Command Bar")
        drag({ CGPoint(x: 30, y: 30) }, { CGPoint(x: 230, y: 130) })
        var snapshotBefore: (files: [String], board: Int, used: Int) = ([], 0, 0)
        run { snapshotBefore = (files(), board.changeCount, used.count) }
        key("\u{1b}", 53)
        wait(0.3)
        run { [self] in
            check(active() == nil && !c.root.subviews.contains { $0 is CaptureOverlayView } && c.window.firstResponder !== session?.overlay,
                  "capture: Esc cancels and the overlay goes")
            check(files() == snapshotBefore.files && board.changeCount == snapshotBefore.board && used.count == snapshotBefore.used,
                  "capture: Esc writes, copies and counts nothing")
        }
        // ⇧⌘2 twice ends it too.
        start("key")
        run { [self] in postKey("@", keyCode: 19, modifiers: [.command, .shift]) }
        wait(0.3)
        run { [self] in check(active() == nil, "capture: ⇧⌘2 again ends it") }
        // Another ⌘ shortcut ends it and runs as usual.
        start("key")
        run { [self] in postKey("t", keyCode: 17, modifiers: [.command]) }
        wait(0.4)
        run { [self] in
            check(active() == nil && c.commandBar != nil, "capture: ⌘T ends Capture and opens the Command Bar")
            c.closeCommandBar()
        }

        start("key")
        run { [self] in
            let center = ShortcutCenter.shared
            _ = center.update { $0.assign(KeyCombo("9", [.option, .command]), to: "view.capture") }
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.option, .command], timestamp: 0,
                windowNumber: c.window.windowNumber, context: nil, characters: "9", charactersIgnoringModifiers: "9", isARepeat: false, keyCode: 25)!
            check(active()?.handleKey(event) == true && active() == nil, "capture: remapped shortcut closes without restarting")
            _ = center.update { $0.reset("view.capture") }
        }

        // 5. Share: one PNG file for the sheet; dismissing it keeps the selection.
        start("key")
        drag({ CGPoint(x: 20, y: 20) }, { CGPoint(x: 160, y: 100) })
        run { [self] in
            shared = []
            overlay()?.bar.captureButton.action?()
            overlay()?.bar.shareButton.action?()
            let url = shared.first as? URL
            let file = url.flatMap { try? Data(contentsOf: $0) }
            let d = decode(file)
            check(shared.count == 1 && url?.pathExtension == "png" && url?.lastPathComponent.hasPrefix("Capture localhost ") == true
                  && d?.w == Int(140 * scale()) && d?.h == Int(80 * scale()),
                  "capture: Share hands the sheet one PNG file (\(url?.lastPathComponent ?? "none"), \(d.map { "\($0.w)×\($0.h)" } ?? "-") px)")
            check(points(file) == CGSize(width: 140, height: 80), "capture: the shared file reads back at 140 × 80 pt (\(pt(points(file))), \(dpi(file)))")
            if let s = session { s.sharingServicePicker(NSSharingServicePicker(items: []), didChoose: nil) }
            check(active() != nil && session?.phase == .confirmed, "capture: closing the share sheet keeps the capture")
            check(url.map { !FileManager.default.fileExists(atPath: $0.path) } == true, "capture: dismissed share removes temporary PNG")
            session?.share()
            let completed = session?.sharedFile
            session?.didShare()
            check(completed.map { !FileManager.default.fileExists(atPath: $0.path) } == true, "capture: completed share removes temporary PNG")
            check(active() == nil && used.last == .share && c.toast.shownText == "Shared Capture", "capture: a share closes and counts share")
        }
        wait(0.3)

        // 6. ⌘ held: the element under the pointer.
        start("key")
        let boxCentre = { CGPoint(x: 100, y: 80) }   // the dark box at CSS (40, 40), 120 × 80, at 100 % zoom
        run { [self] in
            guard let o = overlay(), let shot = session?.shots.first else { return }
            let p = CGPoint(x: shot.frame.minX + boxCentre().x, y: shot.frame.minY + boxCentre().y)
            let w = o.convert(p, to: nil)
            if let e = NSEvent.mouseEvent(with: .mouseMoved, location: w, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                o.mouseMoved(with: e)
            }
        }
        step { [self] done in waitUntil({ overlay()?.element != nil }, timeout: 4) { done() } }
        run { [self] in
            guard let o = overlay(), let shot = session?.shots.first else { return check(false, "capture: ⌘ element (no overlay)") }
            let expect = CGRect(x: shot.frame.minX + 40, y: shot.frame.minY + 40, width: 120, height: 80)
            check(o.element == expect, "capture: ⌘ highlights the element under the pointer (\(o.element.map(NSStringFromRect) ?? "none"))")
            o.pressed(at: CGPoint(x: expect.midX, y: expect.midY), command: true)
            o.released(at: CGPoint(x: expect.midX, y: expect.midY))
            check(o.selection == expect, "capture: ⌘-click selects it")
            let img = session?.render(selection: expect)
            let d = img.flatMap { CaptureSession.png($0, scale: scale()) }.flatMap(decode)
            check(d.map { near(color($0, 0.5, 0.5), (17, 17, 17)) } == true, "capture: the element's picture is the dark box")
        }
        key("\u{1b}", 53)

        // 7. An empty Space has nothing to capture.
        run { [self] in
            _ = try? c.store.createSpace(name: "Empty for Capture", icon: .emoji("📷"), profileID: c.store.profile(ofSpace: c.currentSpaceID).id,
                                         after: c.currentSpaceID)
            c.switchSpace(offset: 1)
        }
        wait(0.6)
        run { [self] in
            c.startCapture()
            check(active() == nil && c.toast.shownText == "There's no page to capture", "capture: an empty Space says there's no page (\(c.toast.shownText ?? "no toast"))")
            c.switchSpace(offset: -1)
        }
        wait(0.6)

        // 8. A private window captures, and nothing is counted.
        step { [self] done in
            guard let app else { return done() }
            PrivateBrowsing.shared.open(app: app) { w in
                privateWindow = w
                w?.openPage(URL(string: base + "/blocks.html"))
                done()
            }
        }
        step { [self] done in waitUntil({ privateWindow?.shownPage?.isLoading == false && privateWindow?.shownPage?.title == "Blocks" }, timeout: 10) { done() } }
        wait(1.0)
        var privatePictureRequests = 0
        run { [self] in
            guard let p = privateWindow else { return check(false, "capture: private window exists") }
            CaptureSession.pictureRequest = { tab, reply in
                if tab === p.shownPage {
                    privatePictureRequests += 1
                    if privatePictureRequests == 1 { reply(nil); return }
                }
                tab.snapshot(completion: reply)
            }
            // Exercise the private keyboard hook; it must not target the main window or depend on being key.
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
                windowNumber: p.window.windowNumber, context: nil, characters: "@", charactersIgnoringModifiers: "@", isARepeat: false, keyCode: 19)!
            check(p.handleKey(event), "capture: private Shift-Command-2 is handled by its own window")
            // Two checks, so a failure says which half broke (17:40 run, 2026-11-07: one red, not reproduced).
            check(CaptureSession.active(in: p.window) != nil, "capture: private session starts in the private window")
            check(CaptureSession.active(in: c.window) == nil,
                  "capture: private session starts independently of the main/key window (no main-window session)")
        }
        step { [self] done in waitUntil({ CaptureSession.active(in: privateWindow?.window)?.picturesReady == true }, timeout: 8) { done() } }
        run { [self] in
            CaptureSession.pictureRequest = nil
            check(privatePictureRequests >= 2, "capture: retries an empty first surface reply")
        }
        var countBefore = 0
        run { [self] in
            guard let p = privateWindow, let s = CaptureSession.active(in: p.window) else { return check(false, "capture: private window: Capture starts") }
            check(s.overlay.frame == p.card.frame && !s.overlay.frame.intersects(p.sidebar.frame), "capture: private window: over its page card only")
            countBefore = used.count
            s.toggleFullPage()
            s.confirm()
            let n = board.changeCount
            s.overlay.bar.copyButton.action?()
            let d = decode(board.data(forType: .png))
            check(board.changeCount != n && d?.w == Int(p.card.frame.width * p.window.backingScaleFactor), "capture: private window: Copy works (\(d.map { "\($0.w)×\($0.h)" } ?? "-") px)")
            check(used.count == countBefore, "capture: private window: nothing counted")
            p.closeWindow()
        }
        wait(0.5)

        // 9. P08a: Capture Full Page, 1×, page zoom, save failure, split, a note in a split, Peek (CaptureParityCheck.swift).
        captureParityChecks(board: board, scratch: scratch, usedCount: { used.count })
        // 10. P08b: Capture in Portrait Mode (PortraitCaptureCheck.swift).
        portraitCaptureChecks(board: board, scratch: scratch, usedCount: { used.count })

        run { [self] in
            board.releaseGlobally()
            server?.stop()
            note("capture: the run's files: \(files().joined(separator: ", "))")
        }
    }
}
#endif
