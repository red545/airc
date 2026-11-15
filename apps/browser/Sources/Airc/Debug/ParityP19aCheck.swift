// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// P19a, Arc's Easels (parity N07, L05), both engines, loopback pages only. Mouse and keys are posted NSEvents through
/// the app's own queue (the check helpers' drag and click), never HID; pasting uses a private pasteboard.
///   - `parityp19a`: ⌃⇧E (Arc's key) makes an Easel (title ready; ⌃E in the title still moves to the line's end); real
///     drags and clicks add a rectangle, an ellipse, an arrow and a line, the text tool types a text block; pasting adds
///     a picture and a link card; Capture's "Add to Easel" adds a Capture block; a move snaps to another block's edge
///     with a guide; a handle resizes, the rotate handle turns; arrows nudge (1 pt, ⇧ 10), ⌘D duplicates, ⌫ deletes,
///     ⌘A, ⌘G groups (a click selects the group), ⇧⌘G ungroups, a marquee selects; ⌘Z / ⇧⌘Z undo and redo (the
///     Easel's own history, not Reopen Closed Tab); zoom keys; copy and paste between Easels with the pictures;
///     Library › Easels lists them, archives and restores; a damaged file opens what still reads and says so; the files
///     on disk (JSON, .bak, assets, history).
///   - `parityp19a-relaunch` (same data folder): the Easel is there as it was left, and ⌘Z undoes the last session's
///     last step.
///   - `parityp19a-perf`: 500 blocks, panned for 600 display frames: the frame rate.
extension SnapshotRunner {
    private static let p19aState = "p19a-state.json"

    func parityP19aScenario() {
        switch script {
        case "parityp19a-relaunch": parityP19aRelaunch()
        case "parityp19a-perf": parityP19aPerf()
        default: parityP19aMain()
        }
    }

    // MARK: Helpers

    private final class P19a {
        var easelID = ""
        var easelTab = ""
        var second = ""
        var ids: [String: String] = [:]
    }

    private func p19aSetup(_ pasteboard: NSPasteboard) {
        run { [self] in
            EaselEditor.pasteboard = { pasteboard }
            c.window.makeFirstResponder(nil)
            note("p19a: window key \(c.window.isKeyWindow), on the active Space \(c.window.isOnActiveSpace)")
            Self.emulateKeyWindow(c) { [weak self] in self?.note($0) }
            let keyWindowOrder = KeyMonitor.testKeyWindowDispatch
            KeyMonitor.testKeyWindowDispatch = { [weak self] e in
                if keyWindowOrder?(e) == true { return true }
                guard let self, e.type == .keyDown, e.window === self.c.window, let r = self.c.window.firstResponder else { return false }
                r.keyDown(with: e)
                return true
            }
        }
    }

    /// A key through the app's event path (the key monitor, then the window), as the keyboard makes it.
    private func p19aKey(_ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags = [], ignoring: String? = nil) {
        step { [self] done in
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: c.window.windowNumber, context: nil, characters: chars,
                                               charactersIgnoringModifiers: ignoring ?? chars, isARepeat: false, keyCode: code) else { continue }
                NSApp.sendEvent(e)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: done)
        }
    }

    private func p19aType(_ s: String) { for ch in s { p19aKey(String(ch), 0) } }

    private func p19aEditor(_ id: String) -> EaselEditor? { EaselCenter.shared.existingEditor(id) }

    private func p19aCanvas(_ id: String) -> EaselCanvasView? { p19aEditor(id)?.view.canvas }

    /// A plane point of Easel `id` in window coordinates.
    private func p19aPoint(_ id: String, _ x: Double, _ y: Double) -> NSPoint {
        p19aCanvas(id)?.windowPoint(plane: EaselPoint(x, y)) ?? .zero
    }

    private func p19aDescribe(_ r: EaselRect?) -> String {
        r.map { String(format: "%.1f, %.1f, %.1f × %.1f", $0.x, $0.y, $0.width, $0.height) } ?? "none"
    }

    private func p19aNear(_ a: EaselRect?, _ b: EaselRect, _ tol: Double = 1.5) -> Bool {
        guard let a else { return false }
        return abs(a.x - b.x) <= tol && abs(a.y - b.y) <= tol && abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
    }

    private func p19aPNG(_ w: Int, _ h: Int, hue: CGFloat) -> Data {
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { r in
            NSColor(hue: hue, saturation: 0.55, brightness: 0.9, alpha: 1).setFill()
            r.fill()
            NSColor(hue: hue + 0.1, saturation: 0.7, brightness: 0.6, alpha: 1).setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: r.width * 0.25, dy: r.height * 0.25)).fill()
            return true
        }
        let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }

    // MARK: The main run

    private func parityP19aMain() {
        let s = P19a()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("org.airc.test.easel.\(ProcessInfo.processInfo.processIdentifier)"))
        var server: LocalPageServer?
        var base = ""
        var doc: EaselDocument { p19aEditor(s.easelID)?.document ?? EaselDocument() }
        func block(_ id: String?) -> EaselBlock? { id.flatMap { doc.block($0) } }
        func newest(_ type: String) -> EaselBlock? { doc.stacked.last { $0.content.type == type } }
        func sel() -> Set<String> { p19aEditor(s.easelID)?.selection ?? [] }
        func wp(_ x: Double, _ y: Double) -> NSPoint { p19aPoint(s.easelID, x, y) }

        step { [self] done in
            server = LocalPageServer(pages: [
                "/trip.html": "<title>Lisbon trip</title><style>body{margin:0;background:#f4efe6;font:32px Georgia}</style><h1 style='padding:40px'>Lisbon, four days</h1><div style='margin:40px;height:300px;background:linear-gradient(135deg,#e07a5f,#3d405b)'></div>",
            ])
            server?.start { port in
                base = port.map { "http://localhost:\($0)" } ?? ""
                done()
            }
        }
        p19aSetup(pasteboard)

        // ⌃⇧E: a new Easel, its title ready.
        let before = EaselCenter.shared.files.list().count
        p19aKey("\u{05}", 14, [.control, .shift], ignoring: "E")
        wait(0.5)
        run { [self] in
            let t = c.store.tab(c.shownTabID)
            s.easelTab = t?.id ?? ""
            s.easelID = EaselURL.easelID(t?.url) ?? ""
            check(!s.easelID.isEmpty && c.shownEasel != nil, "p19a: ⌃⇧E makes a new Easel, shown in the card")
            check(EaselCenter.shared.files.exists(s.easelID) && EaselCenter.shared.files.list().count == before + 1,
                  "p19a: its document is on disk from the start (Easels/<id>/easel.json)")
            let fieldEditor = c.window.firstResponder as? NSTextView
            check(fieldEditor?.delegate === p19aEditor(s.easelID)?.view.titleField, "p19a: its title is ready to type")
            let item = t?.itemID.flatMap { c.store.item($0) }
            check(item?.savedURL == EaselURL.make(s.easelID) && item?.container == .pinned(spaceID: c.currentSpaceID),
                  "p19a: the Easel is a pinned row of the Space, like a note")
            check(item.map(SyncStoreAdapter.isLocalOnly) == true, "p19a: an Easel's row stays on this Mac (local-only in Sync)")
        }
        p19aType("Trip board")
        p19aKey("\u{05}", 14, .control, ignoring: "e")
        run { [self] in
            let r = (c.window.firstResponder as? NSTextView)?.selectedRange()
            check(r?.location == 10 && EaselCenter.shared.files.list().count == before + 1,
                  "p19a: ⌃E in the title field moves to the line's end and makes nothing (caret \(r.map { "\($0.location)" } ?? "-"))")
        }
        p19aKey("\r", 36)
        wait(0.3)
        run { [self] in
            check(c.window.firstResponder === p19aCanvas(s.easelID), "p19a: Return leaves the title for the canvas")
            let item = c.store.tab(s.easelTab)?.itemID.flatMap { c.store.item($0) }
            check(doc.title == "Trip board" && c.store.tab(s.easelTab)?.title == "Trip board" && item?.pageTitle == "Trip board",
                  "p19a: the title names the Easel and its row (\(doc.title))")
            p19aCanvas(s.easelID)?.restoreViewport(EaselViewport(centerX: 300, centerY: 250, zoom: 1))
        }

        // Blocks, with real drags and clicks.
        p19aKey("r", 15)
        step { [self] done in drag(from: wp(0, 0), to: wp(200, 120), done) }
        wait(0.45)   // the canvas has no tracking loop: the helper's release comes after its done
        run { [self] in
            let r = newest("shape")
            s.ids["rect"] = r?.id
            check(p19aNear(r?.frame, EaselRect(x: 0, y: 0, width: 200, height: 120)), "p19a: R, then a drag draws a rectangle there (\(p19aDescribe(r?.frame)))")
            check(p19aCanvas(s.easelID)?.tool == .select, "p19a: the tool goes back to Select after drawing")
        }
        p19aKey("o", 31)
        step { [self] done in click(at: wp(460, 60), in: c.window, done) }
        run { [self] in
            let e = newest("shape")
            s.ids["ellipse"] = e?.id
            if case .shape(let sh)? = e?.content { check(sh.kind == .ellipse, "p19a: O makes an ellipse") }
            check(p19aNear(e?.frame, EaselRect(x: 380, y: 5, width: 160, height: 110)), "p19a: a click makes one of its usual size there (\(p19aDescribe(e?.frame)))")
        }
        p19aKey("a", 0)
        step { [self] done in drag(from: wp(0, 260), to: wp(220, 260), done) }
        wait(0.45)   // the canvas has no tracking loop: the helper's release comes after its done
        run { [self] in
            let a = newest("line")
            s.ids["arrow"] = a?.id
            check(a?.line?.isArrow == true && abs((a?.line?.length ?? 0) - 220) < 2, "p19a: A, then a drag draws an arrow from start to end (\(a?.line.map { String(format: "%.0f", $0.length) } ?? "-") pt)")
        }
        p19aKey("l", 37)
        step { [self] done in drag(from: wp(260, 260), to: wp(380, 320), modifiers: [], done) }
        wait(0.45)   // the canvas has no tracking loop: the helper's release comes after its done
        run { [self] in
            let l = newest("line")
            s.ids["line"] = l?.id
            check(l?.line?.isArrow == false && l?.id != s.ids["arrow"], "p19a: L draws a plain line")
        }
        p19aKey("t", 17)
        step { [self] done in click(at: wp(0, 380), in: c.window, done) }
        run { [self] in check(p19aCanvas(s.easelID)?.isEditingText == true, "p19a: T, then a click opens a text block to type in") }
        p19aType("Hello Easel")
        p19aKey("\u{1b}", 53)
        wait(0.2)
        run { [self] in
            let t = newest("text")
            s.ids["text"] = t?.id
            if case .text(let x)? = t?.content { check(x.plainText == "Hello Easel", "p19a: the typed text is the block's (\(x.plainText))") } else { check(false, "p19a: a text block was made") }
            check(p19aCanvas(s.easelID)?.isEditingText == false, "p19a: Esc ends typing")
            pasteboard.clearContents()
            pasteboard.setData(p19aPNG(320, 200, hue: 0.05), forType: .png)
            p19aCanvas(s.easelID)?.restoreViewport(EaselViewport(centerX: 300, centerY: 700, zoom: 1))
        }
        p19aKey("v", 9, .command)
        run { [self] in
            let i = newest("image")
            s.ids["image"] = i?.id
            if case .image(let img)? = i?.content {
                let url = EaselCenter.shared.files.assetURL(s.easelID, img.asset)
                check(url.map { FileManager.default.fileExists(atPath: $0.path) } == true && img.pixelWidth == 320,
                      "p19a: ⌘V with a picture from another app adds an image block, its file in the Easel's assets")
            } else { check(false, "p19a: ⌘V with a picture adds an image block") }
            pasteboard.clearContents()
            pasteboard.setString("https://example.com/guides/lisbon", forType: .string)
        }
        p19aKey("v", 9, .command)
        run { [self] in
            let l = newest("link")
            s.ids["link"] = l?.id
            if case .link(let x)? = l?.content { check(x.url == "https://example.com/guides/lisbon" && x.host == "example.com", "p19a: ⌘V with an address adds a link card") } else { check(false, "p19a: ⌘V with an address adds a link card") }
            pasteboard.clearContents()
            pasteboard.setString("Pastéis de Belém before nine", forType: .string)
        }
        p19aKey("v", 9, .command)
        run { [self] in
            let t = newest("text")
            if case .text(let x)? = t?.content { check(x.plainText == "Pastéis de Belém before nine", "p19a: ⌘V with text from another app adds a text block") }
            // The paste is selected: delete it again (⌫), keeping the board small.
        }
        p19aKey("\u{7f}", 51)
        run { [self] in check(doc.blocks.filter { $0.content.type == "text" }.count == 1, "p19a: ⌫ deletes the selection") }

        // A drop from a page (a dragged link and its title).
        run { [self] in
            let pb = NSPasteboard(name: NSPasteboard.Name("org.airc.test.easel.drop.\(getpid())"))
            pb.clearContents()
            pb.writeObjects([URL(string: "https://example.org/menu")! as NSURL])
            pb.setString("Menu", forType: NSPasteboard.PasteboardType("public.url-name"))
            if let e = p19aEditor(s.easelID) { _ = EaselDrops.drop(pb, on: e, at: EaselPoint(700, 300)) }
            check(newest("link").flatMap { if case .link(let l) = $0.content { return l.title }; return nil } == "Menu",
                  "p19a: a link dropped from a page becomes a link card with its title")
            pb.releaseGlobally()
        }

        // Capture → Add to Easel (a static Capture block).
        run { [self] in
            guard !base.isEmpty, let t = try? c.store.openTab(url: base + "/trip.html", inSpace: c.currentSpaceID, title: "Lisbon trip") else { return }
            s.ids["page"] = t.id
            c.reloadAll(animated: false)
            c.show(t.id, focus: false)
        }
        step { [self] done in waitUntil({ self.c.engineTab(for: s.ids["page"] ?? "")?.isLoading == false }, timeout: 10) { done() } }
        wait(0.6)
        run { [self] in c.startCapture() }
        step { [self] done in waitUntil({ CaptureSession.active(in: self.c.window)?.picturesReady == true }, timeout: 8) { done() } }
        run { [self] in
            guard let cap = CaptureSession.active(in: c.window) else { return note("FAIL-ENV p19a: Capture didn't start (no picture of the page)") }
            cap.toggleFullPage()
            let id = cap.addToEasel(s.easelID)
            check(id == s.easelID, "p19a: Capture's Add to Easel puts the picture on the Easel")
            let b = newest("capture")
            if case .capture(let x)? = b?.content {
                check(x.url?.hasSuffix("/trip.html") == true && EaselCenter.shared.files.assetURL(s.easelID, x.asset).map { FileManager.default.fileExists(atPath: $0.path) } == true,
                      "p19a: the Capture block has the page's address and its picture in the assets")
            } else { check(false, "p19a: a Capture block was added") }
            if let p = s.ids["page"] { c.closeTab(p) }
            c.show(s.easelTab, focus: true)
        }
        wait(0.4)
        run { [self] in
            c.window.makeFirstResponder(p19aCanvas(s.easelID))
            p19aCanvas(s.easelID)?.restoreViewport(EaselViewport(centerX: 300, centerY: 250, zoom: 1))
            p19aEditor(s.easelID)?.selection = []
        }

        // Move with a snap guide: the ellipse's left edge 3 pt from the rectangle's right one.
        step { [self] done in click(at: wp(460, 60), in: c.window, done) }
        run { [self] in check(sel() == [s.ids["ellipse"] ?? "-"], "p19a: a click selects a block") }
        step { [self] done in drag(from: wp(460, 60), to: wp(460 - 177, 60 + 40), done) }
        wait(0.45)   // the canvas has no tracking loop: the helper's release comes after its done
        run { [self] in
            let e = block(s.ids["ellipse"])
            let guides = p19aCanvas(s.easelID)?.lastGuides ?? []
            check(abs((e?.frame.minX ?? 0) - 200) < 0.01, "p19a: a move snaps to another block's edge (left at \(String(format: "%.2f", e?.frame.minX ?? -1)))")
            check(guides.contains { $0.axis == .vertical && abs($0.at - 200) < 0.01 }, "p19a: the snap shows its guide")
        }
        // Resize with a handle.
        step { [self] done in click(at: wp(100, 60), in: c.window, done) }
        step { [self] done in drag(from: wp(200, 120), to: wp(250, 150), modifiers: .command, done) }
        wait(0.45)   // the canvas has no tracking loop: the helper's release comes after its done
        run { [self] in
            let r = block(s.ids["rect"])
            check(p19aNear(r?.frame, EaselRect(x: 0, y: 0, width: 250, height: 150)), "p19a: dragging a corner handle resizes (\(p19aDescribe(r?.frame)))")
        }
        // Rotate with its handle (22 pt above the top's middle).
        step { [self] done in drag(from: wp(125, -22), to: wp(225, 75), done) }
        wait(0.45)   // the canvas has no tracking loop: the helper's release comes after its done
        run { [self] in
            let r = block(s.ids["rect"])
            check(abs(r?.rotation ?? 0) > 0.3, "p19a: the rotate handle turns a block (\(String(format: "%.2f", r?.rotation ?? 0)) rad)")
        }
        p19aKey("z", 6, .command)
        run { [self] in check(block(s.ids["rect"])?.rotation == 0, "p19a: ⌘Z undoes the turn (the Easel's own undo, not Reopen Closed Tab)") }
        // Keys.
        var f0 = EaselRect(x: 0, y: 0, width: 0, height: 0)
        run { [self] in f0 = block(s.ids["rect"])?.frame ?? f0 }
        p19aKey(String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)), 124)
        p19aKey(String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), 125, .shift)
        run { [self] in
            let f = block(s.ids["rect"])?.frame
            check(f.map { abs($0.x - f0.x - 1) < 0.01 && abs($0.y - f0.y - 10) < 0.01 } == true, "p19a: → nudges 1 pt, ⇧↓ 10 pt")
        }
        var count = 0
        run { [self] in count = doc.blocks.count }
        p19aKey("d", 2, .command)
        run { [self] in
            check(doc.blocks.count == count + 1 && sel().count == 1 && !sel().contains(s.ids["rect"] ?? ""), "p19a: ⌘D duplicates the selection, the copy selected")
        }
        p19aKey("\u{7f}", 51)
        run { [self] in check(doc.blocks.count == count, "p19a: ⌫ deletes the copy") }
        p19aKey("z", 6, .command)
        run { [self] in check(doc.blocks.count == count + 1, "p19a: ⌘Z brings it back") }
        p19aKey("z", 6, [.command, .shift])
        run { [self] in check(doc.blocks.count == count, "p19a: ⇧⌘Z deletes it again") }
        p19aKey("a", 0, .command)
        run { [self] in check(sel().count == doc.blocks.count && count > 5, "p19a: ⌘A selects every block (\(sel().count))") }
        p19aKey("\u{1b}", 53)
        // Group: the rectangle and the ellipse, by shift-click.
        step { [self] done in click(at: wp(60, 40), in: c.window, done) }
        step { [self] done in
            let p = wp(300, 100)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: .shift, timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.postEvent(e, atStart: false) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: done)
        }
        run { [self] in check(sel() == [s.ids["rect"] ?? "-", s.ids["ellipse"] ?? "-"], "p19a: ⇧-click adds to the selection (\(sel().count))") }
        p19aKey("g", 5, .command)
        run { [self] in
            let g = block(s.ids["rect"])?.group
            check(g != nil && g == block(s.ids["ellipse"])?.group, "p19a: ⌘G groups them")
            p19aEditor(s.easelID)?.selection = []
        }
        step { [self] done in click(at: wp(60, 40), in: c.window, done) }
        run { [self] in check(sel().count == 2, "p19a: a click on one selects its group") }
        p19aKey("g", 5, [.command, .shift])
        run { [self] in check(block(s.ids["rect"])?.group == nil, "p19a: ⇧⌘G ungroups") }
        p19aKey("z", 6, .command)
        run { [self] in check(block(s.ids["rect"])?.group != nil, "p19a: ⌘Z regroups") }
        // A marquee from empty plane over the arrow and the line.
        step { [self] done in drag(from: wp(-40, 230), to: wp(400, 340), done) }
        wait(0.45)   // the canvas has no tracking loop: the helper's release comes after its done
        run { [self] in
            check(sel() == [s.ids["arrow"] ?? "-", s.ids["line"] ?? "-"], "p19a: a marquee selects what it touches (\(sel().count))")
        }
        // Zoom keys.
        p19aKey("=", 24, .command)
        wait(0.4)
        run { [self] in check(abs((p19aCanvas(s.easelID)?.zoom ?? 0) - 1.25) < 0.01, "p19a: ⌘= zooms in (\(p19aCanvas(s.easelID)?.zoom ?? 0))") }
        p19aKey("0", 29, .command)
        wait(0.4)
        run { [self] in check(abs((p19aCanvas(s.easelID)?.zoom ?? 0) - 1) < 0.01, "p19a: ⌘0 is actual size") }
        p19aKey("!", 18, .shift, ignoring: "1")
        wait(0.4)
        run { [self] in
            let cv = p19aCanvas(s.easelID)
            let box = doc.contentBounds
            let v = cv?.visibleRect_
            check(box != nil && v != nil && v!.minX <= box!.minX && v!.maxX >= box!.maxX && v!.minY <= box!.minY && v!.maxY >= box!.maxY,
                  "p19a: ⇧1 fits everything in view (zoom \(String(format: "%.2f", cv?.zoom ?? 0)))")
        }
        p19aKey("0", 29, .command)
        wait(0.4)

        // Copy and paste between Easels, pictures with them.
        run { [self] in p19aEditor(s.easelID)?.selection = [s.ids["image"] ?? "", s.ids["text"] ?? ""] }
        p19aKey("c", 8, .command)
        p19aKey("v", 9, .command)
        run { [self] in check(doc.blocks.filter { $0.content.type == "image" }.count == 2, "p19a: ⌘C ⌘V pastes copies in the same Easel") }
        p19aKey("z", 6, .command)
        run { [self] in
            c.window.makeFirstResponder(nil)
            s.second = c.newEasel(title: "Second board") ?? ""
        }
        wait(0.4)
        run { [self] in c.window.makeFirstResponder(p19aCanvas(s.second)) }
        p19aKey("v", 9, .command)
        run { [self] in
            let d = p19aEditor(s.second)?.document
            let img = d?.blocks.first { $0.content.type == "image" }
            let asset = img?.content.assets.first
            check(d?.blocks.count == 2, "p19a: ⌘V in another Easel pastes the blocks there (\(d?.blocks.count ?? 0))")
            check(asset.flatMap { EaselCenter.shared.files.assetURL(s.second, $0) }.map { FileManager.default.fileExists(atPath: $0.path) } == true,
                  "p19a: the picture's file comes with it")
        }

        // Library › Easels: both listed; a Today Easel archived and restored from there.
        var today = ""
        run { [self] in
            today = newID()
            try? EaselCenter.shared.files.save(EaselDocument(id: today, title: "Loose ideas"))
            _ = try? c.store.createEasel(today, inSpace: c.currentSpaceID, pinned: false, title: "Loose ideas")
            c.reloadAll(animated: false)
            EaselCenter.shared.saveAll(wait: true)
        }
        var listed: [EaselFiles.Summary] = []
        step { done in EaselCenter.shared.summaries { listed = $0; done() } }
        run { [self] in
            check(Set([s.easelID, s.second, today]).isSubset(of: Set(listed.map(\.id))), "p19a: Library › Easels lists every Easel (\(listed.count))")
            if let e = listed.first(where: { $0.id == today }) {
                let archived = c.store.tabs(showingEasel: today).contains { $0.itemID == nil } && LibraryEasels.archive(e, in: c)
                check(archived && c.store.tabs(showingEasel: today).isEmpty && !c.store.archiveEntries(ofEasel: today).isEmpty,
                      "p19a: Archive from the Library puts a Today Easel in the Archive")
                check(LibraryEasels.open(e, in: c) && c.store.tabs(showingEasel: today).count == 1, "p19a: Open restores it")
            }
            c.library?.model.section = .easels
            if c.library == nil { c.toggleLibrary() }
            c.library?.model.section = .easels
        }
        wait(0.8)
        run { [self] in
            check(TestAnchors.frames.keys.contains("library.easel.\(s.easelID)"), "p19a: Library › Easels shows the Easel's row")
            if c.library != nil { c.toggleLibrary() }
            if let t = c.store.tabs(showingEasel: s.easelID).first { c.show(t.id, focus: true) }
        }
        wait(0.4)

        // A damaged file: what reads opens, the rest is reported, the file is kept.
        var damaged = ""
        run { [self] in
            damaged = newID()
            var d = EaselDocument(id: damaged, title: "Damaged")
            for i in 0..<3 { d.add(EaselBlock(id: "ok\(i)", frame: EaselRect(x: Double(i) * 120, y: 0, width: 100, height: 80), content: .shape(EaselShape(.rectangle)))) }
            let files = EaselCenter.shared.files
            try? files.save(d)
            if var json = (try? Data(contentsOf: files.documentURL(damaged))).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
               var blocks = json["blocks"] as? [[String: Any]] {
                blocks[1]["frame"] = "broken"
                json["blocks"] = blocks
                try? JSONSerialization.data(withJSONObject: json).write(to: files.documentURL(damaged))
            }
            if let t = try? c.store.createEasel(damaged, inSpace: c.currentSpaceID, pinned: false, title: "Damaged") {
                c.reloadAll(animated: false)
                c.show(t.id)
            }
        }
        wait(0.5)
        run { [self] in
            let e = p19aEditor(damaged)
            check(e?.document.blocks.count == 2 && e?.recoveryMessage?.contains("1 item left out") == true,
                  "p19a: a damaged Easel opens what still reads and says what was left out (\(e?.recoveryMessage ?? "-"))")
            let kept = (try? FileManager.default.contentsOfDirectory(atPath: EaselCenter.shared.files.folder(damaged).path))?.contains { $0.hasPrefix("easel.json.damaged-") } == true
            check(kept, "p19a: the damaged file is kept beside it")
            if let t = c.store.tabs(showingEasel: s.easelID).first { c.show(t.id, focus: true) }
        }
        wait(0.3)

        // On disk: JSON, its .bak, the history; the state the relaunch checks.
        run { [self] in
            EaselCenter.shared.saveAll(wait: true)
            let files = EaselCenter.shared.files
            let fm = FileManager.default
            check(fm.fileExists(atPath: files.documentURL(s.easelID).path) && fm.fileExists(atPath: files.backupURL(s.easelID).path)
                  && fm.fileExists(atPath: files.historyURL(s.easelID).path), "p19a: easel.json, its .bak and history.json are on disk")
            let r = files.load(s.easelID)
            check(r.source == .document && r.document.blocks.count == doc.blocks.count, "p19a: the file reads back whole (\(r.document.blocks.count) blocks)")
            let state: [String: Any] = ["easel": s.easelID, "blocks": doc.blocks.count, "undo": p19aEditor(s.easelID)?.history.undoName ?? "",
                                        "rect": s.ids["rect"] ?? "", "rectGroup": block(s.ids["rect"])?.group ?? ""]
            try? JSONSerialization.data(withJSONObject: state).write(to: AppPaths.dataDirectory.appendingPathComponent(Self.p19aState))
            note("p19a: \(doc.blocks.count) blocks, undo \(p19aEditor(s.easelID)?.history.undoStack.count ?? 0) steps, last “\(p19aEditor(s.easelID)?.history.undoName ?? "")”")
            server?.stop()
        }
        run { [self] in
            c.window.makeFirstResponder(nil)
            p19aCanvas(s.easelID)?.zoomToFit(animated: false)
        }
        wait(0.8)
        capture("p19a-easel")
    }

    // MARK: Relaunch

    private func parityP19aRelaunch() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("org.airc.test.easel.\(ProcessInfo.processInfo.processIdentifier)"))
        var state: [String: Any] = [:]
        var id = ""
        p19aSetup(pasteboard)
        run { [self] in
            state = (try? Data(contentsOf: AppPaths.dataDirectory.appendingPathComponent(Self.p19aState)))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            id = state["easel"] as? String ?? ""
            guard let t = c.store.tabs(showingEasel: id).first else { return check(false, "p19a relaunch: the Easel's row is still there") }
            c.show(t.id, focus: true)
        }
        wait(0.5)
        run { [self] in
            let e = p19aEditor(id)
            check(e?.document.blocks.count == state["blocks"] as? Int && e?.document.title == "Trip board",
                  "p19a relaunch: the Easel is as it was left (\(e?.document.blocks.count ?? -1) blocks)")
            check(e?.history.undoName == state["undo"] as? String && e?.history.canUndo == true,
                  "p19a relaunch: the last session's undo history is there (“\(e?.history.undoName ?? "-")”)")
            c.window.makeFirstResponder(e?.view.canvas)
        }
        p19aKey("z", 6, .command)
        run { [self] in
            let e = p19aEditor(id)
            let rect = state["rect"] as? String ?? ""
            // The last session ended on its ⌘G (a later paste was undone): ⌘Z now ungroups.
            check(e?.document.block(rect)?.group == nil && e?.history.redoName == state["undo"] as? String,
                  "p19a relaunch: ⌘Z undoes the last session's last step (“\(e?.history.redoName ?? "-")”)")
        }
        p19aKey("z", 6, [.command, .shift])
        run { [self] in
            let e = p19aEditor(id)
            let rect = state["rect"] as? String ?? ""
            check(e?.document.block(rect)?.group == state["rectGroup"] as? String && e?.document.blocks.count == state["blocks"] as? Int,
                  "p19a relaunch: ⇧⌘Z redoes it")
            EaselCenter.shared.saveAll(wait: true)
        }
    }

    // MARK: Performance

    private func parityP19aPerf() {
        var id = ""
        var results: [String] = []
        run { [self] in
            c.window.makeFirstResponder(nil)
            id = c.newEasel(title: "Five hundred") ?? ""
        }
        wait(0.5)
        run { [self] in
            guard let e = p19aEditor(id) else { return check(false, "p19a perf: an Easel") }
            var pictures: [EaselImage] = []
            for i in 0..<10 {
                if let img = EaselCenter.shared.storePicture(p19aPNG(600, 400, hue: CGFloat(i) / 10), ext: "png", in: id) { pictures.append(img) }
            }
            let colors = EaselColor.allCases
            e.change("Fill") { d in
                for i in 0..<500 {
                    let x = Double(i % 25) * 180, y = Double(i / 25) * 140
                    let f = EaselRect(x: x, y: y, width: 150, height: 110)
                    let content: EaselContent
                    switch i % 10 {
                    case 0, 1, 2, 3: content = .shape(EaselShape(i % 2 == 0 ? .rectangle : .ellipse, fill: colors[i % colors.count], stroke: i % 3 == 0 ? .black : nil, cornerRadius: 10))
                    case 4, 5, 6: content = .text(EaselText(plain: "Block \(i)\nwith two lines", size: 15))
                    case 7: content = .line(EaselLine(from: EaselPoint(x, y), to: EaselPoint(x + 150, y + 110), endHead: true, color: .darkBlue))
                    case 8: content = .link(EaselLink(url: "https://example.com/\(i)", title: "Link \(i)", detail: "A page"))
                    default: content = pictures.isEmpty ? .shape(EaselShape(.rectangle)) : .image(pictures[i % pictures.count])
                    }
                    d.add(EaselBlock(frame: f, rotation: i % 17 == 0 ? 0.1 : 0, content: content))
                }
            }
            check(e.document.blocks.count == 500 && e.view.canvas.layerCount == 500, "p19a perf: 500 blocks, one layer each")
            e.view.canvas.restoreViewport(EaselViewport(centerX: 2250, centerY: 1400, zoom: 1))
        }
        wait(2.0)
        for (label, zoom) in [("100 %", 1.0), ("fit", 0.0)] {
            run { [self] in
                guard let cv = p19aCanvas(id) else { return }
                if zoom == 0 { cv.zoomToFit(animated: false) } else { cv.setZoom(zoom, about: nil) }
            }
            wait(1.5)
            step { [self] done in
                guard let cv = p19aCanvas(id) else { return done() }
                let screens = NSScreen.screens.map { "\($0.localizedName) \($0.maximumFramesPerSecond) Hz" }.joined(separator: ", ")
                let visible = (p19aEditor(id)?.document.blocks.filter { $0.bounds.intersects(cv.visibleRect_) }.count) ?? 0
                cv.measurePan(frames: 600, step: 6) { intervals in
                    let n = Double(intervals.count)
                    let total = intervals.reduce(0, +)
                    let fps = n / max(0.001, total)
                    let sorted = intervals.sorted()
                    let p95 = sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)]
                    let nominal = sorted.isEmpty ? 1.0 / 60 : sorted[sorted.count / 2]
                    let dropped = intervals.filter { $0 > nominal * 1.5 }.count
                    let line = String(format: "PERF p19a pan %@: %d frames, %.1f fps, median %.2f ms, p95 %.2f ms, max %.2f ms, %d long (>1.5× median), %d blocks on screen of 500, display %@, zoom %.2f",
                                      label, intervals.count, fps, nominal * 1000, p95 * 1000, (sorted.last ?? 0) * 1000, dropped, visible, screens, cv.zoom)
                    results.append(line)
                    self.note(line)
                    let refresh = 1 / nominal
                    self.check(fps >= min(58, refresh * 0.95) && Double(dropped) <= n * 0.02,
                               String(format: "p19a perf: 500 blocks pan at %.1f fps (%@, display at %.0f Hz; ≥ 58 fps and ≤ 2 %% long frames)", fps, label, refresh))
                    done()
                }
            }
        }
        run { [self] in
            try? results.joined(separator: "\n").write(to: AppPaths.dataDirectory.appendingPathComponent("p19a-perf.txt"), atomically: true, encoding: .utf8)
        }
    }
}
#endif
